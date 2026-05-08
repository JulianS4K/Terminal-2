// One-shot diagnostic — find a TEvo event by query, then fetch ticket_groups
// and report counts at each filter step the retail chat applies.
// Usage: POST {} (defaults to morgan wallen) or {"query":"..."}

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

function qs(p: Record<string, any>): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

async function tevoGet(token: string, secret: string, path: string, params: any) {
  const q = qs(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${q}`);
  const r = await fetch(`${BASE}${path}?${q}`, {
    headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" },
  });
  return { status: r.status, body: await r.text() };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); } catch (_) {}
  const query = body.query ?? "morgan wallen";
  const wantDate = body.date ?? "2026-05-29";

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: creds } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
  const m: any = {}; for (const r of creds ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({ error: "no creds" }), { status: 500 });

  // Step 1: search events
  const eventsResp = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/events", { q: query, only_with_available_tickets: true, per_page: 10 });
  let events: any[] = [];
  try { events = JSON.parse(eventsResp.body).events ?? []; } catch (_) {}

  const matched = events.filter((e: any) => (e.occurs_at_local ?? "").startsWith(wantDate));
  const targetEvent = matched[0] ?? events[0];

  if (!targetEvent) {
    return new Response(JSON.stringify({
      step: "events_search",
      events_status: eventsResp.status,
      events_count: events.length,
      events_raw_head: eventsResp.body.slice(0, 400),
    }, null, 2), { status: 200, headers: { "content-type": "application/json" } });
  }

  // Step 2: ticket_groups for that event
  const tgResp = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/ticket_groups", { event_id: targetEvent.id });
  let groups: any[] = [];
  try { groups = JSON.parse(tgResp.body).ticket_groups ?? []; } catch (_) {}

  // Step 3: apply retail filters in order, tracking what each step removes
  const totalRaw = groups.length;
  const withRetail = groups.filter((g: any) => g.retail_price != null);
  const eventOnly = withRetail.filter((g: any) => (g.type ?? "event") === "event");
  const ANCILLARY = /\b(vip lounge|hospitality|premium lounge|club lounge|suite|meet.{0,4}greet|parking|garage)\b/i;
  const finalGroups = eventOnly.filter((g: any) => !ANCILLARY.test(g.section ?? ""));

  // Sample first 10 sections seen at each step + types breakdown
  const typeCounts: Record<string, number> = {};
  const sectionsRemovedByAncillary: string[] = [];
  for (const g of withRetail) {
    const t = String(g.type ?? "event");
    typeCounts[t] = (typeCounts[t] ?? 0) + 1;
  }
  for (const g of eventOnly) {
    if (ANCILLARY.test(g.section ?? "") && sectionsRemovedByAncillary.length < 20) {
      sectionsRemovedByAncillary.push(g.section);
    }
  }
  const sampleFinal = finalGroups.slice(0, 5).map((g: any) => ({
    section: g.section, row: g.row, qty: g.available_quantity, retail: g.retail_price, type: g.type,
  }));
  const sampleAllSections = Array.from(new Set(groups.slice(0, 50).map((g: any) => g.section))).slice(0, 30);

  return new Response(JSON.stringify({
    query, target_date: wantDate,
    event: { id: targetEvent.id, name: targetEvent.name, occurs_at_local: targetEvent.occurs_at_local, venue: targetEvent.venue?.name },
    ticket_groups_status: tgResp.status,
    counts: {
      total_raw: totalRaw,
      with_retail_price: withRetail.length,
      type_event_only: eventOnly.length,
      after_ancillary_filter: finalGroups.length,
    },
    type_breakdown: typeCounts,
    sample_sections_in_raw: sampleAllSections,
    sections_removed_by_ancillary_regex: sectionsRemovedByAncillary,
    sample_final_listings: sampleFinal,
  }, null, 2), { status: 200, headers: { "content-type": "application/json" } });
});
