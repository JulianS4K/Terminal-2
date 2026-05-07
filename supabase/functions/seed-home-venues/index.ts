// One-shot admin: seed performer_home_venues from TEvo for major leagues.
// POST { leagues?: string[] }   default = ["NBA","NHL","NFL","MLB","MLS","WNBA"]
//
// For each league:
//  1. /v9/categories?name=X to discover category_id.
//  2. /v9/performers?category_id=Y to paginate roster.
//  3. Extract each performer's home venue from .venue {id,name,location} (TEvo
//     populates this for sports teams). If absent, derive from the most-frequent
//     venue across that performer's recent events as a fallback.
//  4. Upsert into performer_home_venues.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;
const DEFAULT_LEAGUES = ["NBA", "NHL", "NFL", "MLB", "MLS", "WNBA"];

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

async function getCategoryId(token: string, secret: string, name: string): Promise<{ id: number | null; matched: any }>{
  const r = await tevoGet(token, secret, "/v9/categories", { name, per_page: 5, page: 1 });
  if (r.status !== 200) return { id: null, matched: { error: r.body.slice(0, 200) } };
  const parsed = JSON.parse(r.body);
  const cats = parsed.categories ?? [];
  const exact = cats.find((c: any) => String(c.name).toUpperCase() === name.toUpperCase()) ?? cats[0];
  if (!exact) return { id: null, matched: null };
  return { id: Number(exact.id), matched: { id: exact.id, name: exact.name, slug: exact.slug } };
}

async function getCategoryPerformers(token: string, secret: string, categoryId: number): Promise<any[]> {
  const out: any[] = [];
  for (let page = 1; page <= 5; page++) {
    const r = await tevoGet(token, secret, "/v9/performers", {
      category_id: categoryId,
      category_tree: true,
      only_with_upcoming_events: true,
      per_page: 100,
      page,
      order_by: "performers.popularity_score DESC",
    });
    if (r.status !== 200) throw new Error(`tevo /v9/performers failed: ${r.status} ${r.body.slice(0, 200)}`);
    const parsed = JSON.parse(r.body);
    const perfs = parsed.performers ?? [];
    if (perfs.length === 0) break;
    out.push(...perfs);
    if (out.length >= (parsed.total_entries ?? 0)) break;
  }
  return out;
}

async function getPerformerDetail(token: string, secret: string, id: number): Promise<any | null> {
  const r = await tevoGet(token, secret, `/v9/performers/${id}`, {});
  if (r.status !== 200) return null;
  try { return JSON.parse(r.body); } catch (_) { return null; }
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); } catch (_) {}
  const leagues: string[] = Array.isArray(body.leagues) && body.leagues.length ? body.leagues : DEFAULT_LEAGUES;
  const fillMissingFromDetail: boolean = body.detail_fallback !== false;

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: creds } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
  const m: any = {}; for (const r of creds ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({ error: "no tevo creds" }), { status: 500 });

  const summary: any[] = [];
  let totalUpserted = 0;
  let totalSkippedNoVenue = 0;

  for (const league of leagues) {
    const leagueSummary: any = { league };
    try {
      const cat = await getCategoryId(m.tevo_token, m.tevo_secret, league);
      leagueSummary.category = cat.matched;
      if (!cat.id) { leagueSummary.error = "category not found"; summary.push(leagueSummary); continue; }

      const perfs = await getCategoryPerformers(m.tevo_token, m.tevo_secret, cat.id);
      leagueSummary.performers_fetched = perfs.length;

      let upserts = 0, missing = 0, derived = 0;
      const rows: any[] = [];

      for (const p of perfs) {
        let venue: any = p.venue ?? p.home_venue ?? null;

        if (!venue?.id && fillMissingFromDetail) {
          const d = await getPerformerDetail(m.tevo_token, m.tevo_secret, p.id);
          venue = d?.venue ?? d?.home_venue ?? null;
          if (venue?.id) derived++;
        }

        if (!venue?.id) {
          const { data: vrow } = await db
            .from("events")
            .select("venue_id, venue_name, venue_location")
            .eq("primary_performer_id", p.id)
            .not("venue_id", "is", null);
          if (vrow && vrow.length) {
            const counts = new Map<number, { name: string; location: string; n: number }>();
            for (const ev of vrow) {
              const k = Number(ev.venue_id);
              const c = counts.get(k) ?? { name: ev.venue_name ?? "", location: ev.venue_location ?? "", n: 0 };
              c.n++; counts.set(k, c);
            }
            let bestId: number | null = null, bestN = 0, bestName = "", bestLoc = "";
            for (const [k, c] of counts) if (c.n > bestN) { bestId = k; bestN = c.n; bestName = c.name; bestLoc = c.location; }
            if (bestId != null) { venue = { id: bestId, name: bestName, location: bestLoc }; derived++; }
          }
        }

        if (!venue?.id) { missing++; continue; }

        rows.push({
          performer_id: p.id,
          performer_name: p.name,
          venue_id: Number(venue.id),
          venue_name: venue.name ?? null,
          venue_location: venue.location ?? venue.address?.locality ?? null,
          league,
          source: "tevo",
          set_at: new Date().toISOString(),
        });
      }

      if (rows.length) {
        for (let i = 0; i < rows.length; i += 200) {
          const chunk = rows.slice(i, i + 200);
          const { error } = await db.from("performer_home_venues").upsert(chunk, { onConflict: "performer_id" });
          if (error) { leagueSummary.upsert_error = error.message; break; }
          upserts += chunk.length;
        }
      }
      leagueSummary.upserts = upserts;
      leagueSummary.derived_via_detail_or_events = derived;
      leagueSummary.skipped_no_venue = missing;
      totalUpserted += upserts;
      totalSkippedNoVenue += missing;
    } catch (e) {
      leagueSummary.error = (e as Error).message;
    }
    summary.push(leagueSummary);
  }

  return new Response(JSON.stringify({
    leagues_processed: summary.length,
    total_upserted: totalUpserted,
    total_skipped_no_venue: totalSkippedNoVenue,
    summary,
  }, null, 2), { status: 200, headers: { "content-type": "application/json" } });
});
