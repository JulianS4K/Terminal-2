// Supabase Edge Function: chat
//
// Customer-facing retail chat. NO whitelist (anyone with the URL can use it).
// Deliberately narrow tool surface — broker-only data (S4K owned share,
// wholesale prices, exposure, internal zones) is NEVER exposed.
//
//   GET  /functions/v1/chat       → public HTML chat page
//   POST /functions/v1/chat       → { message | history } → { reply, trace }
//
// Reads ANTHROPIC_API_KEY from public.settings (with env fallback).
// TEvo creds same way.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TEVO_HOST = "api.ticketevolution.com";
const TEVO_BASE = `https://${TEVO_HOST}`;
const BOT_MODEL = Deno.env.get("WHATSAPP_BOT_MODEL") ?? "claude-sonnet-4-6";
const MAX_TURNS = parseInt(Deno.env.get("WHATSAPP_MAX_TURNS") ?? "6", 10);
const PUBLIC_EVENT_URL = (eid: number) => `https://www.ticketevolution.com/events/${eid}`;

const SYSTEM_PROMPT = `You are a friendly ticket-finder assistant for S4K Entertainment, helping customers locate seats for concerts, sports, and live events.

Style:
- Conversational and warm, but concise. 2-4 short lines per reply unless the customer asks for more detail.
- Plain text. No code blocks, no markdown tables. Use short bullets ("•") sparingly.
- When showing listings, format each one as one line: section, row, qty, price, link. Limit to ~5 options unless asked for more.
- Always finish with a "want me to find more / different price / different section?" style nudge when listings are returned.

You have these tools:
- search_events: look up an event we track by name/date. Use this first — it covers our most active markets.
- find_listings: get currently-available tickets for one event_id. Defaults to event-only seats (no parking). Filter by max_price or min_qty when the customer specifies a budget or group size.
- tevo_search_performers / tevo_search_venues: resolve a performer or venue by name when search_events returns nothing.

What you must NEVER do:
- Don't mention "S4K", "broker", "wholesale", "inventory ownership", or any seller-side terms — customers shouldn't think about who owns the listing.
- Don't expose internal pricing analytics (medians, percentiles, dispersion, market shares).
- If the user asks about wholesale prices or broker margins, politely redirect: "I just help find tickets — pricing is what's listed."
- Never invent prices or seats. If find_listings returns nothing matching the criteria, say so and offer alternatives.
- Don't claim a sale; the link goes to the marketplace where they can complete checkout.

If the customer asks something off-topic (weather, jokes, etc.), politely redirect to what you can help with.`;

async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

type Params = Record<string, string | number | boolean | null | undefined>;

function canonicalQuery(params: Params): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(params)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

class Evo {
  constructor(private token: string, private secret: string) {}
  private async get(path: string, params: Params = {}): Promise<any> {
    const query = canonicalQuery(params);
    const sig = await hmacSha256Base64(this.secret, `GET ${TEVO_HOST}${path}?${query}`);
    const r = await fetch(`${TEVO_BASE}${path}?${query}`, {
      headers: { "X-Token": this.token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" },
    });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText} on ${path}`);
    return r.json();
  }
  ticketGroups(id: number) { return this.get("/v9/ticket_groups", { event_id: id }); }
  searchPerformers(q: string) { return this.get("/v9/performers", { q, per_page: 25 }); }
  searchVenues(q: string) { return this.get("/v9/venues", { q, per_page: 25 }); }
}

async function resolveTevoCreds(db: any) {
  try {
    const { data } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
    const m: Record<string, string> = {};
    for (const r of data ?? []) m[r.key] = r.value;
    if (m.tevo_token && m.tevo_secret) return { token: m.tevo_token, secret: m.tevo_secret };
  } catch (_) {}
  return null;
}

async function resolveSecret(db: any, key: string, env: string): Promise<string | null> {
  try {
    const { data } = await db.from("settings").select("value").eq("key", key).maybeSingle();
    if (data?.value) return data.value;
  } catch (_) {}
  return Deno.env.get(env) ?? null;
}

const TOOLS = [
  {
    name: "search_events",
    description: "Find an event we track by free-text name (e.g. 'Knicks', 'Taylor Swift'), optionally narrowed by date window. Returns id, name, occurs_at_local, venue_name. Defaults to upcoming only.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string" },
        days_ahead: { type: "integer", description: "Window length in days from today" },
        limit: { type: "integer", default: 8 },
      },
    },
  },
  {
    name: "find_listings",
    description: "Get currently-available ticket listings for one event. Defaults to seats only (excludes parking). Optional max_price (per ticket) and min_qty filters. Returns section, row, qty, retail_price per group, plus a public event link.",
    input_schema: {
      type: "object",
      required: ["event_id"],
      properties: {
        event_id: { type: "integer" },
        max_price: { type: "number" },
        min_qty: { type: "integer", default: 1 },
        limit: { type: "integer", default: 6 },
      },
    },
  },
  {
    name: "tevo_search_performers",
    description: "Look up a performer (artist/team) by name when search_events doesn't find them in our cache. Returns id, name, category.",
    input_schema: {
      type: "object",
      required: ["query"],
      properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } },
    },
  },
  {
    name: "tevo_search_venues",
    description: "Look up a venue by name. Returns id, name, city, state.",
    input_schema: {
      type: "object",
      required: ["query"],
      properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } },
    },
  },
];

async function toolSearchEvents(db: any, args: any) {
  const now = new Date();
  let q = db.from("events").select("id,name,occurs_at_local,venue_name");
  const todayPrefix = now.toISOString().slice(0, 10);
  q = q.gte("occurs_at_local", todayPrefix);
  if (args.days_ahead) {
    const cutoff = new Date(now.getTime() + (args.days_ahead + 1) * 86400000).toISOString().slice(0, 10);
    q = q.lte("occurs_at_local", cutoff);
  }
  if (args.query) q = q.ilike("name", `%${args.query}%`);
  const { data } = await q.order("occurs_at_local").limit(Math.min(args.limit ?? 8, 25));
  return { count: (data ?? []).length, events: data ?? [] };
}

async function toolFindListings(evo: Evo, args: any) {
  if (!evo) return { error: "ticket service unavailable, try again later" };
  try {
    const r = await evo.ticketGroups(args.event_id);
    let groups = (r.ticket_groups ?? [])
      .filter((g: any) => g.retail_price != null)
      // Hide parking/lounges/suites — retail flow is event seats only
      .filter((g: any) => (g.type ?? "event") === "event")
      .filter((g: any) => !/\b(vip lounge|hospitality|premium lounge|club lounge|suite|meet.{0,4}greet|parking|garage)\b/i.test(g.section ?? ""));
    if (args.max_price != null) groups = groups.filter((g: any) => Number(g.retail_price) <= Number(args.max_price));
    if (args.min_qty != null) groups = groups.filter((g: any) => (g.available_quantity ?? 0) >= Number(args.min_qty));
    groups.sort((a: any, b: any) => Number(a.retail_price) - Number(b.retail_price));
    const top = groups.slice(0, Math.min(args.limit ?? 6, 12));
    return {
      event_id: args.event_id,
      count: top.length,
      cheapest: groups.length ? Number(groups[0].retail_price) : null,
      most_expensive: groups.length ? Number(groups[groups.length - 1].retail_price) : null,
      // SCRUBBED: only customer-safe fields
      listings: top.map((g: any) => ({
        section: g.section,
        row: g.row,
        quantity: g.available_quantity,
        price_per_ticket: Number(g.retail_price),
        format: g.format,
        link: PUBLIC_EVENT_URL(Number(args.event_id)),
      })),
      total_matching_filters: groups.length,
    };
  } catch (e) {
    return { error: String((e as Error).message) };
  }
}

async function toolTevoSearchPerformers(evo: Evo, args: any) {
  if (!evo) return { error: "search unavailable" };
  try {
    const r = await evo.searchPerformers(args.query);
    const items = (r.performers ?? []).slice(0, args.limit ?? 5);
    return { count: items.length, performers: items.map((p: any) => ({ id: p.id, name: p.name, category: p.category?.name })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoSearchVenues(evo: Evo, args: any) {
  if (!evo) return { error: "search unavailable" };
  try {
    const r = await evo.searchVenues(args.query);
    const items = (r.venues ?? []).slice(0, args.limit ?? 5);
    return { count: items.length, venues: items.map((v: any) => ({ id: v.id, name: v.name, city: v.address?.locality, state: v.address?.region })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function dispatch(name: string, input: any, db: any, evo: Evo | null) {
  switch (name) {
    case "search_events": return await toolSearchEvents(db, input);
    case "find_listings": return await toolFindListings(evo!, input);
    case "tevo_search_performers": return await toolTevoSearchPerformers(evo!, input);
    case "tevo_search_venues": return await toolTevoSearchVenues(evo!, input);
    default: return { error: `unknown tool ${name}` };
  }
}

async function runClaudeLoop(apiKey: string, history: any[], db: any, evo: Evo | null): Promise<{ reply: string; trace: any[] }> {
  const messages = [...history];
  const trace: any[] = [];
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: BOT_MODEL, max_tokens: 1024, system: SYSTEM_PROMPT, tools: TOOLS, messages }),
    });
    if (!resp.ok) {
      const text = await resp.text();
      return { reply: `sorry, I'm having trouble right now (${resp.status}). try again in a moment?`, trace };
    }
    const data = await resp.json();
    if (data.stop_reason === "tool_use") {
      const tr: any[] = [];
      for (const block of data.content ?? []) {
        if (block.type !== "tool_use") continue;
        let result: any;
        try { result = await dispatch(block.name, block.input ?? {}, db, evo); }
        catch (e) { result = { error: `tool error: ${(e as Error).message}` }; }
        trace.push({ tool: block.name, input: block.input, result });
        tr.push({ type: "tool_result", tool_use_id: block.id, content: JSON.stringify(result) });
      }
      messages.push({ role: "assistant", content: data.content });
      messages.push({ role: "user", content: tr });
      continue;
    }
    const text = (data.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
    return { reply: text || "let me know what you're looking for!", trace };
  }
  return { reply: "I'm overthinking this — could you rephrase?", trace };
}

const CHAT_HTML = `<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>Find Tickets</title>
<style>
:root{--bg:#fafafa;--card:#fff;--fg:#1a1a1a;--accent:#0066ff;--in:#eef1f5;--out:#0066ff;--muted:#7a7f87;--err:#c83232;--border:#e5e7eb}
*{box-sizing:border-box}
html,body{margin:0;padding:0;min-height:100%;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif}

/* ---- Hero (initial query screen) -------------------------------------- */
body.hero{height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(180deg,#fafafa 0%,#f0f4ff 100%)}
body.hero .wrap{display:none}
body.hero .hero{display:flex}
.hero{display:none;flex-direction:column;align-items:center;width:100%;max-width:680px;padding:24px;text-align:center}
.hero h1{font-size:42px;font-weight:700;margin:0 0 8px;letter-spacing:-0.5px}
.hero .tagline{font-size:17px;color:var(--muted);margin:0 0 36px}
.hero form{width:100%;max-width:560px;display:flex;gap:10px;background:#fff;padding:6px;border-radius:32px;border:1px solid var(--border);box-shadow:0 4px 24px rgba(0,0,0,.06);transition:border-color .15s,box-shadow .15s}
.hero form:focus-within{border-color:var(--accent);box-shadow:0 6px 28px rgba(0,102,255,.16)}
.hero input[type=text]{flex:1;background:transparent;border:0;outline:0;padding:14px 18px;font:inherit;font-size:16px;color:var(--fg)}
.hero button{background:var(--accent);color:#fff;border:0;border-radius:26px;padding:0 24px;font:inherit;font-size:15px;font-weight:600;cursor:pointer;transition:opacity .12s}
.hero button:hover{opacity:.9}
.hero button:disabled{opacity:.4;cursor:default}
.hero .pills{display:flex;flex-wrap:wrap;gap:8px;justify-content:center;margin-top:24px;max-width:560px}
.hero .pills button{background:#fff;color:var(--fg);border:1px solid var(--border);font:inherit;font-size:13px;border-radius:18px;padding:8px 14px;cursor:pointer;font-weight:400}
.hero .pills button:hover{border-color:var(--accent);color:var(--accent)}
.hero .footer{margin-top:32px;font-size:12px;color:var(--muted)}

/* ---- Chat (post first send) ------------------------------------------- */
.wrap{max-width:680px;margin:0 auto;height:100vh;display:flex;flex-direction:column;background:var(--card)}
header{padding:14px 20px;border-bottom:1px solid var(--border);background:var(--card);display:flex;align-items:center;justify-content:space-between}
header h2{margin:0;font-size:16px;font-weight:600}
header button.reset{background:transparent;border:0;color:var(--muted);font:inherit;font-size:13px;cursor:pointer;padding:4px 8px}
header button.reset:hover{color:var(--accent)}
#log{flex:1;overflow-y:auto;padding:18px;background:var(--bg)}
.bubble{max-width:82%;padding:11px 15px;border-radius:18px;margin:4px 0;white-space:pre-wrap;word-wrap:break-word;font-size:14.5px;line-height:1.45}
.in{background:var(--in);color:var(--fg);border-bottom-left-radius:6px}
.out{background:var(--out);color:#fff;border-bottom-right-radius:6px;margin-left:auto}
.err{background:#fde7e7;color:var(--err);border:1px solid #f4c2c2}
.bubble a{color:inherit;text-decoration:underline}
.row{display:flex;margin:6px 0}
.thinking{color:var(--muted);font-style:italic;padding:8px 14px;font-size:13px}
form.followup{display:flex;gap:10px;padding:14px;border-top:1px solid var(--border);background:var(--card)}
form.followup input[type=text]{flex:1;background:#fff;color:var(--fg);border:1px solid var(--border);border-radius:22px;padding:11px 16px;font:inherit;outline:none}
form.followup input[type=text]:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(0,102,255,.12)}
form.followup button{background:var(--accent);color:#fff;border:0;border-radius:22px;padding:0 20px;font:inherit;font-weight:600;cursor:pointer}
form.followup button:hover{opacity:.9}
@media (max-width:680px){.wrap{max-width:none}.hero h1{font-size:32px}.hero .tagline{font-size:15px}}
</style></head><body class="hero">

<!-- HERO: initial query screen -->
<div class="hero">
  <h1>🎟️ Find Tickets</h1>
  <p class="tagline">Tell me what you're looking for — game, concert, date, budget. I'll do the searching.</p>
  <form id="hero-f">
    <input id="hero-msg" type="text" placeholder="e.g. cheapest 2 tickets to Knicks tonight under $500" autocomplete="off" autofocus/>
    <button type="submit">Search</button>
  </form>
  <div class="pills" id="pills">
    <button>Knicks tonight</button>
    <button>Yankees this weekend</button>
    <button>Cheapest seats for tonight's Knicks game</button>
    <button>4 tickets to the next Taylor Swift show</button>
    <button>Best seats under $300 for any NBA game tonight</button>
  </div>
  <div class="footer">Powered by S4K Entertainment · live ticket inventory</div>
</div>

<!-- CHAT: appears after first message -->
<div class="wrap">
  <header>
    <h2>🎟️ Find Tickets</h2>
    <button class="reset" id="reset" title="Start over">↻ new search</button>
  </header>
  <div id="log"></div>
  <form class="followup" id="followup-f">
    <input id="msg" type="text" placeholder="Refine, ask follow-up, or search again…" autocomplete="off"/>
    <button type="submit">Send</button>
  </form>
</div>

<script>
const heroF = document.getElementById('hero-f');
const heroMsg = document.getElementById('hero-msg');
const pills = document.getElementById('pills');
const followF = document.getElementById('followup-f');
const followMsg = document.getElementById('msg');
const log = document.getElementById('log');
const reset = document.getElementById('reset');

function bubble(text, cls) {
  const row = document.createElement('div');
  row.className = 'row';
  const b = document.createElement('div');
  b.className = 'bubble ' + cls;
  const html = text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/(https?:\\/\\/[^\\s]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
  b.innerHTML = html;
  row.appendChild(b);
  if (cls === 'out' || cls === 'out err') row.style.justifyContent = 'flex-end';
  log.appendChild(row);
  log.scrollTop = log.scrollHeight;
}

let history = [];
let busy = false;

function transitionToChat() {
  if (!document.body.classList.contains('hero')) return;
  document.body.classList.remove('hero');
}

async function send(text) {
  if (busy || !text) return;
  busy = true;
  transitionToChat();
  bubble(text, 'in');
  history.push({ role: 'user', content: text });
  const thinking = document.createElement('div');
  thinking.className = 'thinking';
  thinking.textContent = 'Looking…';
  log.appendChild(thinking);
  log.scrollTop = log.scrollHeight;
  try {
    const r = await fetch(location.pathname, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ history }),
    });
    thinking.remove();
    const data = await r.json();
    if (!r.ok || data.error) {
      bubble(data.error || ('Something went wrong (' + r.status + ').'), 'out err');
    } else {
      bubble(data.reply, 'out');
      history.push({ role: 'assistant', content: data.reply });
    }
  } catch (e) {
    thinking.remove();
    bubble('Network error: ' + e.message, 'out err');
  } finally {
    busy = false;
    followMsg.focus();
  }
}

heroF.addEventListener('submit', (ev) => {
  ev.preventDefault();
  const text = heroMsg.value.trim();
  heroMsg.value = '';
  send(text);
});

followF.addEventListener('submit', (ev) => {
  ev.preventDefault();
  const text = followMsg.value.trim();
  followMsg.value = '';
  send(text);
});

pills.addEventListener('click', (ev) => {
  if (ev.target.tagName === 'BUTTON') {
    heroMsg.value = ev.target.textContent;
    heroF.requestSubmit();
  }
});

reset.addEventListener('click', () => {
  history = [];
  log.innerHTML = '';
  document.body.classList.add('hero');
  heroMsg.value = '';
  heroMsg.focus();
});
</script>
</body></html>`;

function jsonResponse(obj: any, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req) => {
  const method = req.method.toUpperCase();
  if (method === "GET") {
    return new Response(CHAT_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
  }
  if (method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const apiKey = await resolveSecret(db, "anthropic_api_key", "ANTHROPIC_API_KEY");
  if (!apiKey) return jsonResponse({ error: "service not configured" }, 503);

  let body: any = null;
  try { body = await req.json(); } catch (_) { return jsonResponse({ error: "expected JSON body" }, 400); }
  const history = Array.isArray(body?.history) ? body.history : (body?.message ? [{ role: "user", content: body.message }] : []);
  if (!history.length) return jsonResponse({ error: "history or message required" }, 400);

  const creds = await resolveTevoCreds(db);
  const evo = creds ? new Evo(creds.token, creds.secret) : null;

  // Audit-log to bot_messages with channel='web' and a synthetic phone marker
  const last = history[history.length - 1];
  const lastText = typeof last?.content === "string" ? last.content : "";
  try { await db.from("bot_messages").insert({ channel: "web", direction: "in", phone: "anon-retail", body: lastText }); } catch (_) {}

  let result: { reply: string; trace: any[] };
  try { result = await runClaudeLoop(apiKey, history, db, evo); }
  catch (e) { result = { reply: `sorry, something went wrong: ${(e as Error).message}`, trace: [] }; }

  try { await db.from("bot_messages").insert({ channel: "web", direction: "out", phone: "anon-retail", body: result.reply }); } catch (_) {}

  // For retail: don't return tool trace to the client (avoid leaking tool names / shape)
  return jsonResponse({ reply: result.reply });
});
