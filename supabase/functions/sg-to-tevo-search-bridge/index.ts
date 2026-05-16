// sg-to-tevo-search-bridge (v4)
//
// COLD BRIDGE: for SG events that have no corresponding row in TEvo's local
// `events` table, actively call TEvo /v9/events search (with date+performer
// query) to discover the matching event. Upsert into events + write
// seatgeek_event_xref.
//
// Operator directive 2026-05-16:
//   - "auto-track any event we're tracking on SG on evo and vice versa"
//   - "use evo search to find events directly"
//   - "track all sg and evo events where our listings > 0 by default, then
//      expand beyond to track entire market. first wire to only track known."
//
// v4 (2026-05-16): added owned_first / owned_only modes. When ownedFirst (default
// true), prioritizes SG events that appear in seatgeek_seller_listings (we own
// inventory on them). In owned_only mode, ONLY scans those events — using an
// .in(ownedIds) filter so date-ordered pagination doesn't miss far-future events.
//
// GET /functions/v1/sg-to-tevo-search-bridge?limit=20&dry_run=false
//                                            &owned_first=true   (default ON)
//                                            &owned_only=true    (drain owned only)
//                                            &min_score=50
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
  if (r.status !== 200) return { ok: false, status: r.status, body: (await r.text()).slice(0, 300) };
  return { ok: true, body: await r.json() };
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const tokenSet = (s: string) => new Set(s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 1));

function score(candidate: any, sg: { name: string; date: string; venue: string; tevo_venue_id: number | null; team_a: string; team_b: string }): number {
  let s = 0;
  if (sg.tevo_venue_id && candidate.venue?.id === sg.tevo_venue_id) s += 50;
  else if (candidate.venue?.name && slug(candidate.venue.name) === slug(sg.venue)) s += 40;
  else if (candidate.venue?.name && (slug(candidate.venue.name).startsWith(slug(sg.venue)) || slug(sg.venue).startsWith(slug(candidate.venue.name)))) s += 25;
  const candidateTokens = tokenSet(candidate.name ?? "");
  const teamBTokens = tokenSet(sg.team_b);
  const teamATokens = tokenSet(sg.team_a);
  let teamHits = 0;
  for (const t of teamBTokens) if (candidateTokens.has(t)) teamHits++;
  for (const t of teamATokens) if (candidateTokens.has(t)) teamHits++;
  s += teamHits * 10;
  const sgT = new Date(sg.date).getTime();
  const candT = new Date(candidate.occurs_at).getTime();
  const hours = Math.abs((candT - sgT) / 3600000);
  if (!isNaN(hours)) s += Math.max(0, 24 - hours);
  return s;
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const tevoToken = Deno.env.get("TEVO_TOKEN") ?? Deno.env.get("TEVO_API_TOKEN") ?? "";
  const tevoSecret = Deno.env.get("TEVO_SECRET") ?? Deno.env.get("TEVO_API_SECRET") ?? "";
  if (!tevoToken || !tevoSecret) return new Response(JSON.stringify({ ok: false, error: "missing TEvo creds" }), { status: 500, headers: { "content-type": "application/json" } });

  const url = new URL(req.url);
  const limit = Math.max(1, Math.min(200, Number(url.searchParams.get("limit") ?? "20")));
  const dryRun = url.searchParams.get("dry_run") === "true";
  const minScore = Number(url.searchParams.get("min_score") ?? "50");
  const ownedFirst = url.searchParams.get("owned_first") !== "false";  // default ON
  const ownedOnly = url.searchParams.get("owned_only") === "true";

  const cutoffIso = new Date(Date.now() - 24 * 3600000).toISOString();
  const { data: recentlyTried } = await sb.from("sg_tevo_search_attempts").select("sg_event_id").gte("attempted_at", cutoffIso);
  const triedSet = new Set((recentlyTried ?? []).map((r: any) => r.sg_event_id));

  let ownedIds: number[] = [];
  if (ownedFirst || ownedOnly) {
    const { data: ownedRows } = await sb.from("seatgeek_seller_listings").select("sg_event_id");
    ownedIds = Array.from(new Set((ownedRows ?? []).map((r: any) => r.sg_event_id)));
  }
  const ownedSet = new Set(ownedIds);

  // owned_only / owned_first: fetch owned events directly via .in() (no date pagination)
  let ownedCandidates: any[] = [];
  if ((ownedFirst || ownedOnly) && ownedIds.length > 0) {
    const { data: ownedPool } = await sb
      .from("sg_events_canonical")
      .select("sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_venue_city, sg_venue_state, sg_category")
      .is("tevo_event_id", null)
      .gt("sg_datetime_utc", new Date().toISOString())
      .in("sg_event_id", ownedIds)
      .order("sg_datetime_utc", { ascending: true });
    ownedCandidates = (ownedPool ?? [])
      .filter((c: any) => !triedSet.has(c.sg_event_id))
      .filter((c: any) => !/parking/i.test(c.sg_venue_name ?? "") && !/parking/i.test(c.sg_event_name ?? ""))
      .filter((c: any) => !['Parking','parking'].includes(c.sg_category ?? ''));
  }

  // General pool — only fetched when not owned_only
  let otherCandidates: any[] = [];
  if (!ownedOnly) {
    const { data: pool } = await sb
      .from("sg_events_canonical")
      .select("sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_venue_city, sg_venue_state, sg_category")
      .is("tevo_event_id", null)
      .gt("sg_datetime_utc", new Date().toISOString())
      .not("sg_category", "in", "(Parking,parking)")
      .order("sg_datetime_utc", { ascending: true })
      .limit(limit * 6);
    otherCandidates = (pool ?? [])
      .filter((c: any) => !triedSet.has(c.sg_event_id))
      .filter((c: any) => !ownedSet.has(c.sg_event_id))
      .filter((c: any) => !/parking/i.test(c.sg_venue_name ?? "") && !/parking/i.test(c.sg_event_name ?? ""));
  }

  const filtered: any[] = ownedOnly ? ownedCandidates.slice(0, limit)
                       : ownedFirst ? [...ownedCandidates, ...otherCandidates].slice(0, limit)
                                    : otherCandidates.slice(0, limit);

  const venueMap = new Map<number, number | null>();
  for (const c of filtered) {
    const { data } = await sb.rpc("cross_source_venue_resolve", { p_venue_name: c.sg_venue_name, p_city: c.sg_venue_city, p_state: c.sg_venue_state });
    venueMap.set(c.sg_event_id, data ?? null);
  }

  const samples: any[] = [];
  let matched = 0, noResults = 0, errored = 0, ownedAttempted = 0;

  for (const c of filtered) {
    if (ownedSet.has(c.sg_event_id)) ownedAttempted++;
    const teamA = (c.sg_event_name || "").split(" at ")[0]?.trim() || "";
    const teamB = (c.sg_event_name || "").split(" at ")[1]?.trim() || teamA;
    const tevoVenueId = venueMap.get(c.sg_event_id) ?? null;
    const sgT = new Date(c.sg_datetime_utc).getTime();
    const dateGte = new Date(sgT - 24 * 3600000).toISOString().slice(0, 10);
    const dateLte = new Date(sgT + 24 * 3600000).toISOString().slice(0, 10);

    let resp = tevoVenueId
      ? await tevoSearch(tevoToken, tevoSecret, { venue_id: tevoVenueId, "occurs_at.gte": dateGte, "occurs_at.lte": dateLte, per_page: 25, page: 1 })
      : { ok: false as const, status: 0, body: null };

    if (resp.ok && (((resp.body as any).events ?? []) as any[]).length === 0) {
      resp = await tevoSearch(tevoToken, tevoSecret, { name: teamB || teamA, "occurs_at.gte": dateGte, "occurs_at.lte": dateLte, per_page: 25, page: 1 });
    } else if (!resp.ok) {
      resp = await tevoSearch(tevoToken, tevoSecret, { name: teamB || teamA, "occurs_at.gte": dateGte, "occurs_at.lte": dateLte, per_page: 25, page: 1 });
    }

    if (!resp.ok) { errored++; samples.push({ sg_event_id: c.sg_event_id, error: resp.status, body: resp.body }); continue; }

    const events: any[] = ((resp.body as any).events ?? []) as any[];
    if (events.length === 0) {
      noResults++;
      await sb.from("sg_tevo_search_attempts").upsert({ sg_event_id: c.sg_event_id, attempted_at: new Date().toISOString(), result: "no_results", meta: { date_gte: dateGte, date_lte: dateLte, name: teamB || teamA, tevo_venue_id: tevoVenueId, owned: ownedSet.has(c.sg_event_id) } }, { onConflict: "sg_event_id" });
      continue;
    }

    let best: any = null;
    let bestScore = -1;
    for (const ev of events) {
      const sc = score(ev, { name: c.sg_event_name, date: c.sg_datetime_utc, venue: c.sg_venue_name, tevo_venue_id: tevoVenueId, team_a: teamA, team_b: teamB });
      if (sc > bestScore) { bestScore = sc; best = ev; }
    }

    if (!best || bestScore < minScore) {
      noResults++;
      await sb.from("sg_tevo_search_attempts").upsert({ sg_event_id: c.sg_event_id, attempted_at: new Date().toISOString(), result: "low_score", meta: { best_score: bestScore, best_id: best?.id, best_name: best?.name, top_n: events.length, owned: ownedSet.has(c.sg_event_id) } }, { onConflict: "sg_event_id" });
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

      await sb.from("seatgeek_event_xref").upsert({
        tevo_event_id: best.id, sg_event_id: c.sg_event_id, sg_event_name: c.sg_event_name,
        sg_event_location: c.sg_venue_name, sg_start_data: c.sg_datetime_utc,
        match_method: ownedSet.has(c.sg_event_id) ? "tevo_search_owned_priority" : "tevo_search_autotrack",
        match_confidence: bestScore >= 70 ? 0.95 : 0.80,
        matched_at: new Date().toISOString(),
      }, { onConflict: "tevo_event_id" });

      await sb.from("sg_events_canonical").update({
        tevo_event_id: best.id,
        match_method: ownedSet.has(c.sg_event_id) ? "tevo_search_owned_priority" : "tevo_search_autotrack",
        match_confidence: bestScore >= 70 ? 0.95 : 0.80,
        matched_at: new Date().toISOString(), updated_at: new Date().toISOString(),
      }).eq("sg_event_id", c.sg_event_id);

      await sb.from("sg_tevo_search_attempts").upsert({ sg_event_id: c.sg_event_id, attempted_at: new Date().toISOString(), result: "matched", meta: { tevo_event_id: best.id, score: bestScore, name: best.name, owned: ownedSet.has(c.sg_event_id) } }, { onConflict: "sg_event_id" });
    }

    matched++;
    if (samples.length < 18) samples.push({ sg_event_id: c.sg_event_id, sg_name: c.sg_event_name, sg_venue: c.sg_venue_name, sg_date: c.sg_event_date, owned: ownedSet.has(c.sg_event_id), matched_to: { id: best.id, name: best.name, venue: best.venue?.name, occurs_at: best.occurs_at_local }, score: bestScore });
  }

  return new Response(JSON.stringify({
    ok: true, dry_run: dryRun, limit, min_score: minScore,
    owned_first: ownedFirst, owned_only: ownedOnly,
    owned_pool_size: ownedCandidates.length, owned_attempted: ownedAttempted,
    attempted: filtered.length, matched, no_results: noResults, errored, samples,
  }, null, 2), { headers: { "content-type": "application/json" } });
});
