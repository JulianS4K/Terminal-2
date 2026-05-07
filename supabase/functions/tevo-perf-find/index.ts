// One-shot admin lookup: search TEvo for a performer by name, optionally
// scoped to a category_id. Used to backfill performer_external_ids for
// teams missing from cowork's seed-home-venues.
//
// GET /functions/v1/tevo-perf-find?q=Boston+Bruins&category_id=68
//   -> { ok: true, query, hits: [{id, name, category, venue, popularity_score}] }
//
// Will be tombstoned after migration 15 lands.

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
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
  const token = Deno.env.get("TEVO_API_TOKEN") ?? "";
  const secret = Deno.env.get("TEVO_API_SECRET") ?? "";
  if (!token || !secret) return new Response(JSON.stringify({ ok: false, error: "missing TEvo creds" }), { status: 500 });

  const url = new URL(req.url);
  const q = url.searchParams.get("q");
  if (!q) return new Response(JSON.stringify({ ok: false, error: "missing q" }), { status: 400 });
  const categoryId = url.searchParams.get("category_id");
  const fuzzy = url.searchParams.get("fuzzy") === "true";

  // Try /v9/performers/search first
  const params: any = { q, per_page: 10, page: 1 };
  if (categoryId) params.category_id = categoryId;
  if (fuzzy) params.fuzzy = true;

  const r = await tevoGet(token, secret, "/v9/performers/search", params);
  if (r.status !== 200) {
    return new Response(JSON.stringify({ ok: false, status: r.status, body: r.body.slice(0, 500) }), { status: 502 });
  }
  const parsed = JSON.parse(r.body);
  const hits = (parsed.performers ?? []).map((p: any) => ({
    id: p.id,
    name: p.name,
    slug: p.slug,
    category: p.category?.name,
    category_slug: p.category?.slug,
    venue_id: p.venue?.id,
    venue_name: p.venue?.name,
    venue_location: p.venue?.location,
    popularity_score: p.popularity_score,
    upcoming_events_count: p.upcoming_events?.count,
  }));

  return new Response(JSON.stringify({ ok: true, query: q, hits }, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
