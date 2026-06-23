// axs-to-tevo-search-bridge (v1)
//
// COLD BRIDGE (AXS analogue of aq-to-tevo-search-bridge / sg-to-tevo-search-bridge):
// for unmapped AXS-primary events (axs_events.tevo_event_id IS NULL) whose latest
// snapshot carries name+venue+future-date, actively call TEvo /v9/events
// (venue+date, then name+date) to discover the canonical TEvo event, upsert it into
// public.events, then call axs_apply_aq() — which re-runs the existing AXS matcher
// (now finds the freshly-ingested event in public.events) and propagates
// tevo_event_id across the AXS snapshot/section/seat/registry rows.
//
// Why this exists: axs_aq_match only links to events ALREADY in public.events.
// The unmapped AXS shows (Wallen @ Clemson/Michigan Stadium, Van Andel arena
// shows, Geese club dates, …) are absent from public.events, so axs_aq_backfill()
// maps 0. Nothing searched TEvo on the AXS side. This closes that gap.
//
// Candidate selection is server-side (axs_tevo_search_candidates RPC), which
// anti-joins the attempt ledger and orders NEVER-TRIED-FIRST so it drains the
// whole backlog instead of starving on the nearest-dated front.
//
// The actual link is done by axs_apply_aq (one matching code path), NOT by writing
// tevo_event_id here — so the venue/date/name guards already baked into axs_aq_match
// (±48h window, score >= 0.45) still apply as a second gate after the TEvo search.
//
// GET /functions/v1/axs-to-tevo-search-bridge?limit=30&dry_run=false
//                                             &min_score=50&backoff_hours=24
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

// AXS event_name is a single performer/show title (no "A vs B" sports split), but
// keep the same token-overlap guard shape as the AQ bridge.
function scoreParts(candidate: any, q: { date: string; venue: string; tevo_venue_id: number | null }): { total: number; venue: number } {
  let venue = 0;
  if (q.tevo_venue_id && candidate.venue?.id === q.tevo_venue_id) venue = 50;
  else if (candidate.venue?.name && slug(candidate.venue.name) === slug(q.venue)) venue = 40;
  else if (candidate.venue?.name && (slug(candidate.venue.name).startsWith(slug(q.venue)) || slug(q.venue).startsWith(slug(candidate.venue.name)))) venue = 25;
  let s = venue;
  const qT = new Date(q.date).getTime();
  const candT = new Date(candidate.occurs_at).getTime();
  const hours = Math.abs((candT - qT) / 3600000);
  if (!isNaN(hours)) s += Math.max(0, 24 - hours);
  return { total: s, venue };
}

// occurs_at_local is offset-bearing AXS-local text ("YYYY-MM-DDTHH:MM:SS±HH:MM").
// A ±48h window (matching axs_aq_match) absorbs AXS-vs-TEvo reschedule/tz skew for
// the TEvo occurs_at filter.
function dateWindow(occursAtLocal: string): { gte: string; lte: string } {
  const t = new Date(occursAtLocal).getTime();
  return {
    gte: new Date(t - 48 * 3600000).toISOString().slice(0, 10),
    lte: new Date(t + 48 * 3600000).toISOString().slice(0, 10),
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

  const { data: candidates, error: candErr } = await sb.rpc("axs_tevo_search_candidates", {
    p_limit: limit,
    p_backoff_hours: backoffHours,
  });
  if (candErr) return new Response(JSON.stringify({ ok: false, error: candErr.message }), { status: 500, headers: { "content-type": "application/json" } });
  const pool: any[] = candidates ?? [];

  // Resolve TEvo venue ids: use the AXS-pegged tevo_venue_id when present, else
  // resolve from the venue name (AXS snapshots carry no city/state).
  const venueMap = new Map<string, number | null>();
  await Promise.all(
    pool.map(async (c: any) => {
      if (c.tevo_venue_id) { venueMap.set(c.axs_event_id, Number(c.tevo_venue_id)); return; }
      const { data } = await sb.rpc("cross_source_venue_resolve", { p_venue_name: c.venue_name, p_city: null, p_state: null });
      venueMap.set(c.axs_event_id, data ?? null);
    }),
  );

  const samples: any[] = [];
  let matched = 0, mappedConfirmed = 0, noResults = 0, lowScore = 0, errored = 0;

  for (const c of pool) {
    const tevoVenueId = venueMap.get(c.axs_event_id) ?? null;
    const w = dateWindow(c.occurs_at_local);
    const nameQuery = (c.event_name ?? "").trim();

    let resp = tevoVenueId
      ? await tevoSearch(tevoToken, tevoSecret, { venue_id: tevoVenueId, "occurs_at.gte": w.gte, "occurs_at.lte": w.lte, per_page: 25, page: 1 })
      : { ok: false as const, status: 0, body: null };

    if ((resp.ok && (((resp.body as any).events ?? []) as any[]).length === 0) || !resp.ok) {
      resp = await tevoSearch(tevoToken, tevoSecret, { name: nameQuery, "occurs_at.gte": w.gte, "occurs_at.lte": w.lte, per_page: 25, page: 1 });
    }

    if (!resp.ok) {
      errored++;
      if (!dryRun) await sb.from("axs_tevo_search_attempts").upsert({ axs_event_id: c.axs_event_id, attempted_at: new Date().toISOString(), result: "errored", meta: { status: resp.status, body: resp.body, name: nameQuery } }, { onConflict: "axs_event_id" });
      samples.push({ axs_event_id: c.axs_event_id, error: resp.status });
      continue;
    }

    const events: any[] = ((resp.body as any).events ?? []) as any[];
    if (events.length === 0) {
      noResults++;
      if (!dryRun) await sb.from("axs_tevo_search_attempts").upsert({ axs_event_id: c.axs_event_id, attempted_at: new Date().toISOString(), result: "no_results", meta: { date_gte: w.gte, date_lte: w.lte, name: nameQuery, tevo_venue_id: tevoVenueId } }, { onConflict: "axs_event_id" });
      continue;
    }

    let best: any = null, bestScore = -1, bestVenue = 0;
    for (const ev of events) {
      const sc = scoreParts(ev, { date: c.occurs_at_local, venue: c.venue_name, tevo_venue_id: tevoVenueId });
      if (sc.total > bestScore) { bestScore = sc.total; bestVenue = sc.venue; best = ev; }
    }

    // Accept only with enough total score AND a real venue signal AND >=1 shared
    // meaningful name token — same guard stack as the AQ/SG bridges. (axs_apply_aq
    // re-validates with the matcher's own ±48h/score>=0.45 gate as a second check.)
    const NAME_STOP = new Set(["the","and","at","of","a","an","to","in","on","for","with","vs","de","el","la","los"]);
    const bestNameTokens = best ? tokenSet(best.name ?? "") : new Set<string>();
    const axsNameTokens = tokenSet(c.event_name ?? "");
    let nameOverlap = 0;
    for (const t of axsNameTokens) if (!NAME_STOP.has(t) && bestNameTokens.has(t)) nameOverlap++;

    if (!best || bestScore < minScore || bestVenue < 25 || nameOverlap === 0) {
      lowScore++;
      const reason = (best && bestScore >= minScore && bestVenue >= 25 && nameOverlap === 0) ? "no_name_overlap" : "low_score";
      if (!dryRun) await sb.from("axs_tevo_search_attempts").upsert({ axs_event_id: c.axs_event_id, attempted_at: new Date().toISOString(), result: reason, meta: { best_score: bestScore, best_venue: bestVenue, best_id: best?.id, best_name: best?.name, name_overlap: nameOverlap, top_n: events.length, name: nameQuery } }, { onConflict: "axs_event_id" });
      continue;
    }

    matched++;
    let confirmedTevo: number | null = null;
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

      // Link via the existing matcher (one code path). Re-runs axs_aq_match — now
      // finds the freshly-ingested event — and propagates tevo_event_id across the
      // AXS snapshot/section/seat/registry rows. Returns the linked tevo id, or
      // null if the matcher's own ±48h/score gate rejected it (rare false TEvo hit).
      const { data: applied } = await sb.rpc("axs_apply_aq", { p_axs_event_id: c.axs_event_id });
      confirmedTevo = (applied as number | null) ?? null;
      if (confirmedTevo) mappedConfirmed++;

      await sb.from("axs_tevo_search_attempts").upsert({
        axs_event_id: c.axs_event_id, attempted_at: new Date().toISOString(),
        result: confirmedTevo ? "matched" : "low_score",
        meta: { tevo_event_id: best.id, applied_tevo_event_id: confirmedTevo, score: bestScore, venue_score: bestVenue, name_overlap: nameOverlap, name: best.name, matcher_confirmed: confirmedTevo != null },
      }, { onConflict: "axs_event_id" });
    }

    if (samples.length < 18) samples.push({ axs_event_id: c.axs_event_id, axs_name: c.event_name, axs_venue: c.venue_name, axs_date: c.occurs_at_local, matched_to: { id: best.id, name: best.name, venue: best.venue?.name, occurs_at: best.occurs_at_local ?? best.occurs_at }, score: bestScore, applied_tevo_event_id: confirmedTevo });
  }

  return new Response(JSON.stringify({
    ok: true, dry_run: dryRun, limit, min_score: minScore, backoff_hours: backoffHours,
    attempted: pool.length, matched, mapped_confirmed: mappedConfirmed, no_results: noResults, low_score: lowScore, errored, samples,
  }, null, 2), { headers: { "content-type": "application/json" } });
});
