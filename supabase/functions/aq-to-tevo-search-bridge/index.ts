// aq-to-tevo-search-bridge (v1)
//
// COLD BRIDGE (non-SG analogue of sg-to-tevo-search-bridge): for aq_event_map
// hub rows that carry a Ticketmaster / Vivid / ScoreBig(SH) id but NO sg_event_id
// and NO canonical tevo_event_id, actively call TEvo /v9/events (venue+date,
// then name+date) to discover the matching TEvo event and fill
// aq_event_map.tevo_event_id.
//
// Why this exists: TM/Vivid/SH rows only ever mapped *passively* before (when
// they coincided with an SG or order match). Nothing actively searched TEvo for
// them, leaving ~1,250 upcoming non-parking hub rows permanently unmapped.
//
// Candidate selection is server-side (aq_tevo_search_candidates RPC), which
// anti-joins the attempt ledger and orders NEVER-TRIED-FIRST — so it drains the
// whole backlog instead of starving on the nearest-dated front like the SG
// bridge's client-side date-LIMIT window does.
//
// GET /functions/v1/aq-to-tevo-search-bridge?limit=30&dry_run=false
//                                            &min_score=50
//                                            &backoff_hours=24
//
// Body-gated via requireCronSecret per PROJECT_BIBLE §1 rule #7.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

function qs(p: Record<string, unknown>): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

async function tevoSearch(token: string, secret: string, params: Record<string, unknown>) {
  const path = "/v9/events";
  const queryStr = qs(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${queryStr}`);
  const r = await fetch(`${BASE}${path}?${queryStr}`, {
    headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" },
  });
  if (r.status !== 200) return { ok: false as const, status: r.status, body: (await r.text()).slice(0, 300) };
  return { ok: true as const, body: await r.json() };
}

const slug = (s: string) => (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
const tokenSet = (s: string) => new Set((s ?? "").toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 1));

// Split a hub event_name into competitor sides. Handles "A vs. B", "A vs B",
// "A v. B", "A at B" (sports). Returns [a, b] with b="" for single-name events
// (concerts / theatre).
function splitSides(name: string): [string, string] {
  const m = (name ?? "").split(/\s+(?:vs\.?|v\.?|at)\s+/i);
  if (m.length >= 2) return [m[0].trim(), m.slice(1).join(" ").trim()];
  return [(name ?? "").trim(), ""];
}

// Returns {total, venue}. `venue` is the venue-only contribution; acceptance
// requires venue >= 25 so a same-name/same-date hit at a DIFFERENT venue (e.g.
// a touring play with simultaneous productions) cannot pass on name+date alone.
function scoreParts(candidate: any, q: { date: string; venue: string; tevo_venue_id: number | null; team_a: string; team_b: string }): { total: number; venue: number } {
  let venue = 0;
  if (q.tevo_venue_id && candidate.venue?.id === q.tevo_venue_id) venue = 50;
  else if (candidate.venue?.name && slug(candidate.venue.name) === slug(q.venue)) venue = 40;
  else if (candidate.venue?.name && (slug(candidate.venue.name).startsWith(slug(q.venue)) || slug(q.venue).startsWith(slug(candidate.venue.name)))) venue = 25;
  let s = venue;
  const candidateTokens = tokenSet(candidate.name ?? "");
  let teamHits = 0;
  for (const t of tokenSet(q.team_b)) if (candidateTokens.has(t)) teamHits++;
  for (const t of tokenSet(q.team_a)) if (candidateTokens.has(t)) teamHits++;
  s += teamHits * 10;
  const qT = new Date(q.date).getTime();
  const candT = new Date(candidate.occurs_at).getTime();
  const hours = Math.abs((candT - qT) / 3600000);
  if (!isNaN(hours)) s += Math.max(0, 24 - hours);
  return { total: s, venue };
}

// aq_event_map.event_date is `timestamp without time zone` (naive local wall
// clock). Treat it as the event's local time; a ±24h date window around it is
// wide enough to absorb the tz skew for the TEvo occurs_at filter.
function dateWindow(eventDate: string): { gte: string; lte: string; ms: number } {
  const t = new Date((eventDate ?? "").replace(" ", "T")).getTime();
  return {
    gte: new Date(t - 24 * 3600000).toISOString().slice(0, 10),
    lte: new Date(t + 24 * 3600000).toISOString().slice(0, 10),
    ms: t,
  };
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const tevoToken = Deno.env.get("TEVO_TOKEN") ?? Deno.env.get("TEVO_API_TOKEN") ?? "";
  const tevoSecret = Deno.env.get("TEVO_SECRET") ?? Deno.env.get("TEVO_API_SECRET") ?? "";
  if (!tevoToken || !tevoSecret) return new Response(JSON.stringify({ ok: false, error: "missing TEvo creds" }), { status: 500, headers: { "content-type": "application/json" } });

  const url = new URL(req.url);
  const limit = Math.max(1, Math.min(200, Number(url.searchParams.get("limit") ?? "30")));
  const dryRun = url.searchParams.get("dry_run") === "true";
  const minScore = Number(url.searchParams.get("min_score") ?? "50");
  const backoffHours = Math.max(1, Number(url.searchParams.get("backoff_hours") ?? "24"));

  // Server-side candidate selection — anti-joins the ledger, never-tried-first.
  const { data: candidates, error: candErr } = await sb.rpc("aq_tevo_search_candidates", {
    p_limit: limit,
    p_backoff_hours: backoffHours,
  });
  if (candErr) return new Response(JSON.stringify({ ok: false, error: candErr.message }), { status: 500, headers: { "content-type": "application/json" } });
  const pool: any[] = candidates ?? [];

  // Resolve TEvo venue ids in parallel (independent read RPCs).
  const venueMap = new Map<number, number | null>();
  await Promise.all(
    pool.map(async (c: any) => {
      const { data } = await sb.rpc("cross_source_venue_resolve", {
        p_venue_name: c.venue_name,
        p_city: c.city,
        p_state: c.state,
      });
      venueMap.set(c.aq_id, data ?? null);
    }),
  );

  const samples: any[] = [];
  let matched = 0, noResults = 0, lowScore = 0, errored = 0;

  for (const c of pool) {
    const [teamA, teamB] = splitSides(c.event_name);
    const tevoVenueId = venueMap.get(c.aq_id) ?? null;
    const w = dateWindow(c.event_date);
    // Name query: home/away team for sports, else performer or full name.
    const nameQuery = (teamB || c.performer || teamA || c.event_name || "").trim();

    let resp = tevoVenueId
      ? await tevoSearch(tevoToken, tevoSecret, { venue_id: tevoVenueId, "occurs_at.gte": w.gte, "occurs_at.lte": w.lte, per_page: 25, page: 1 })
      : { ok: false as const, status: 0, body: null };

    // Fall back to name+date if venue search empty or unavailable.
    if ((resp.ok && (((resp.body as any).events ?? []) as any[]).length === 0) || !resp.ok) {
      resp = await tevoSearch(tevoToken, tevoSecret, { name: nameQuery, "occurs_at.gte": w.gte, "occurs_at.lte": w.lte, per_page: 25, page: 1 });
    }

    if (!resp.ok) {
      errored++;
      if (!dryRun) await sb.from("aq_tevo_search_attempts").upsert({ aq_id: c.aq_id, attempted_at: new Date().toISOString(), result: "errored", meta: { status: resp.status, body: resp.body, name: nameQuery } }, { onConflict: "aq_id" });
      samples.push({ aq_id: c.aq_id, error: resp.status });
      continue;
    }

    const events: any[] = ((resp.body as any).events ?? []) as any[];
    if (events.length === 0) {
      noResults++;
      if (!dryRun) await sb.from("aq_tevo_search_attempts").upsert({ aq_id: c.aq_id, attempted_at: new Date().toISOString(), result: "no_results", meta: { date_gte: w.gte, date_lte: w.lte, name: nameQuery, tevo_venue_id: tevoVenueId, src: c.src } }, { onConflict: "aq_id" });
      continue;
    }

    let best: any = null, bestScore = -1, bestVenue = 0;
    for (const ev of events) {
      const sc = scoreParts(ev, { date: c.event_date, venue: c.venue_name, tevo_venue_id: tevoVenueId, team_a: teamA, team_b: teamB });
      if (sc.total > bestScore) { bestScore = sc.total; bestVenue = sc.venue; best = ev; }
    }

    // Accept only with BOTH enough total score AND a real venue signal — guards
    // against same-name/same-date matches at a different venue.
    if (!best || bestScore < minScore || bestVenue < 25) {
      lowScore++;
      if (!dryRun) await sb.from("aq_tevo_search_attempts").upsert({ aq_id: c.aq_id, attempted_at: new Date().toISOString(), result: "low_score", meta: { best_score: bestScore, best_venue: bestVenue, best_id: best?.id, best_name: best?.name, top_n: events.length, name: nameQuery, src: c.src } }, { onConflict: "aq_id" });
      continue;
    }

    if (!dryRun) {
      const performances = best.performances ?? [];
      const primaryPerf = performances.find((p: any) => p.primary) ?? performances[0];
      await sb.from("events").upsert({
        id: best.id, name: best.name, occurs_at_local: best.occurs_at_local ?? best.occurs_at, state: best.state,
        venue_id: best.venue?.id ?? null, venue_name: best.venue?.name ?? null, venue_location: best.venue?.location ?? null,
        primary_performer_id: primaryPerf?.performer?.id ?? null, primary_performer_name: primaryPerf?.performer?.name ?? null,
        performer_ids: performances.map((p: any) => p.performer?.id).filter((x: any) => x),
        event_type: best.category?.slug ?? null, last_seen: new Date().toISOString(),
      }, { onConflict: "id" });

      // Canonical link: set the hub row's tevo_event_id.
      await sb.from("aq_event_map").update({ tevo_event_id: best.id }).eq("id", c.aq_id);

      await sb.from("aq_tevo_search_attempts").upsert({ aq_id: c.aq_id, attempted_at: new Date().toISOString(), result: "matched", meta: { tevo_event_id: best.id, score: bestScore, name: best.name, src: c.src } }, { onConflict: "aq_id" });
    }

    matched++;
    if (samples.length < 18) samples.push({ aq_id: c.aq_id, src: c.src, aq_name: c.event_name, aq_venue: c.venue_name, aq_date: c.event_date, matched_to: { id: best.id, name: best.name, venue: best.venue?.name, occurs_at: best.occurs_at_local ?? best.occurs_at }, score: bestScore });
  }

  return new Response(JSON.stringify({
    ok: true, dry_run: dryRun, limit, min_score: minScore, backoff_hours: backoffHours,
    attempted: pool.length, matched, no_results: noResults, low_score: lowScore, errored, samples,
  }, null, 2), { headers: { "content-type": "application/json" } });
});
