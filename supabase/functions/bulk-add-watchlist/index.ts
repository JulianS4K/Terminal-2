// One-shot admin: bulk-add all performers in a TEvo category to the watchlist.
// POST { category_id?: number, label?: string }   default category_id=2 (NFL)
//
// Returns: { added, skipped, performers: [{id,name}] }

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
  const categoryId = body.category_id ?? 2;  // default NFL
  const labelPrefix = body.label ?? "";

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: creds } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
  const m: any = {}; for (const r of creds ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({ error: "no creds" }), { status: 500 });

  // Pull all performers in this category (paginate if needed)
  const allPerformers: any[] = [];
  for (let page = 1; page <= 5; page++) {
    const r = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/performers", {
      category_id: categoryId,
      category_tree: true,
      only_with_upcoming_events: true,
      per_page: 100,
      page,
      order_by: "performers.popularity_score DESC",
    });
    if (r.status !== 200) {
      return new Response(JSON.stringify({ error: "tevo_search_failed", status: r.status, body: r.body.slice(0, 400) }), { status: 500, headers: { "content-type": "application/json" } });
    }
    let parsed: any = {};
    try { parsed = JSON.parse(r.body); } catch (_) {}
    const perfs = parsed.performers ?? [];
    if (perfs.length === 0) break;
    allPerformers.push(...perfs);
    if (allPerformers.length >= (parsed.total_entries ?? 0)) break;
  }

  // Insert into watchlist (idempotent on conflict)
  let added = 0, skipped = 0;
  const results: any[] = [];
  for (const p of allPerformers) {
    const label = labelPrefix ? `${labelPrefix}${p.name}` : p.name;
    const { error } = await db.from("watchlist").upsert(
      { kind: "performer", ext_id: p.id, label },
      { onConflict: "kind,ext_id", ignoreDuplicates: false }
    );
    if (error) { skipped++; results.push({ id: p.id, name: p.name, error: error.message }); }
    else { added++; results.push({ id: p.id, name: p.name }); }
  }

  return new Response(JSON.stringify({
    category_id: categoryId,
    fetched: allPerformers.length,
    added,
    skipped,
    performers: results.slice(0, 100),
  }, null, 2), { status: 200, headers: { "content-type": "application/json" } });
});
