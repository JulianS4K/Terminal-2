// Supabase Edge Function: espn-collect
//
// Daily batch over team_xref + event_xref → snapshots into:
//   espn_team_snapshots, espn_injuries_snapshots, espn_news, espn_event_snapshots
// Logs each run to espn_runs.
//
// Auth: x-cron-secret (same value as collect-listings).
//
// Triggered by pg_cron once per day. Designed to be idempotent within the same
// captured_at minute so accidental double-fires don't dupe (unique indexes).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TEAM_LIMIT_PER_RUN = 80;       // safety cap
const EVENT_LOOKAHEAD_DAYS = 60;     // refresh game snapshots out this far
const ESPN_HOST = "site.api.espn.com";

async function get(path: string, query?: Record<string, string>) {
  const url = new URL(`https://${ESPN_HOST}${path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const r = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url.pathname}`);
  return r.json();
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

interface CollectorState {
  teams_processed: number;
  events_processed: number;
  team_snaps_inserted: number;
  injuries_inserted: number;
  news_inserted: number;
  event_snaps_inserted: number;
  errors: number;
  log: string[];
}

// ---------------------------------------------------------------------------
// Per-team: pull team detail + standings entry, emit team snapshot
// Plus league-wide injuries (cached per league since one call covers all teams)
// ---------------------------------------------------------------------------

async function collectTeams(db: any, state: CollectorState) {
  const { data: xref } = await db.from("team_xref")
    .select("espn_team_id,espn_league,espn_slug,espn_abbr,tevo_name")
    .order("espn_league");
  const teams = (xref ?? []) as any[];

  // Fetch standings + injuries once per (league, slug) and reuse across teams
  const leagueData: Record<string, { standings: any; injuries: any }> = {};
  for (const t of teams) {
    if (leagueData[t.espn_slug]) continue;
    try {
      const standingsPath = `/apis/v2/sports/${t.espn_slug}/standings`;
      const injuriesPath  = `/apis/site/v2/sports/${t.espn_slug}/injuries`;
      const [s, i] = await Promise.all([get(standingsPath).catch(() => null), get(injuriesPath).catch(() => null)]);
      leagueData[t.espn_slug] = { standings: s, injuries: i };
      state.log.push(`league ${t.espn_slug}: standings=${!!s} injuries=${!!i ? (i.injuries?.length ?? 0) + ' teams' : 'fail'}`);
      await sleep(120);  // be polite to ESPN
    } catch (e) {
      state.errors++;
      state.log.push(`league ${t.espn_slug} fetch FAIL: ${(e as Error).message}`);
    }
  }

  // Emit team snapshots
  for (const t of teams.slice(0, TEAM_LIMIT_PER_RUN)) {
    state.teams_processed++;
    const ld = leagueData[t.espn_slug];
    if (!ld) continue;
    const entry = findStandingsEntry(ld.standings, t.espn_team_id);
    if (entry) {
      const stats = Object.fromEntries((entry.stats ?? []).map((s: any) => [s.name, s]));
      const row = {
        espn_team_id: t.espn_team_id,
        espn_league: t.espn_league,
        wins:           num(stats.wins?.value),
        losses:         num(stats.losses?.value),
        ties:           num(stats.ties?.value),
        win_pct:        num(stats.winPercent?.value),
        games_back:     num(stats.gamesBehind?.value),
        playoff_seed:   num(stats.playoffSeed?.value),
        conference_rank:num(stats.divisionRanking?.value) || num(stats.conferenceRanking?.value),
        division_rank:  num(stats.divisionRanking?.value),
        record_summary:    stats.overall?.displayValue || `${num(stats.wins?.value) ?? '?'}-${num(stats.losses?.value) ?? '?'}`,
        standing_summary:  entry.team?.standingSummary,
        streak:            stats.streak?.displayValue,
      };
      const { error } = await db.from("espn_team_snapshots").insert(row);
      if (error && !/duplicate/i.test(error.message)) state.errors++;
      else state.team_snaps_inserted++;
    }

    // Emit per-team injuries from league-wide payload
    const teamInj = (ld.injuries?.injuries ?? []).find((x: any) => String(x.id) === String(t.espn_team_id));
    for (const inj of teamInj?.injuries ?? []) {
      const row = {
        espn_team_id: t.espn_team_id,
        espn_league: t.espn_league,
        athlete_id: inj.athlete?.id ? String(inj.athlete.id) : null,
        athlete_name: inj.athlete?.displayName ?? null,
        position: inj.athlete?.position?.abbreviation ?? null,
        status: inj.status ?? null,
        injury_type: inj.type?.description ?? inj.type ?? null,
        short_comment: inj.shortComment ?? null,
        long_comment: inj.longComment ?? null,
      };
      const { error } = await db.from("espn_injuries_snapshots").insert(row);
      if (error) state.errors++;
      else state.injuries_inserted++;
    }
  }
}

function findStandingsEntry(standings: any, espnTeamId: string): any | null {
  if (!standings) return null;
  // standings has nested children for conferences/divisions
  function walk(node: any): any | null {
    for (const e of node.standings?.entries ?? []) {
      if (String(e.team?.id) === String(espnTeamId)) return e;
    }
    for (const c of node.children ?? []) {
      const found = walk(c);
      if (found) return found;
    }
    return null;
  }
  return walk(standings);
}

const num = (v: any) => v == null || v === "" ? null : Number(v);

// ---------------------------------------------------------------------------
// Per-team news — pull each team's recent news once (5 per team)
// ---------------------------------------------------------------------------

async function collectNews(db: any, state: CollectorState) {
  const { data: teams } = await db.from("team_xref").select("espn_team_id,espn_league,espn_slug").limit(TEAM_LIMIT_PER_RUN);
  for (const t of (teams ?? []) as any[]) {
    let articles: any[] = [];
    try {
      const j = await get(`/apis/site/v2/sports/${t.espn_slug}/news`, { team: t.espn_team_id, limit: "5" });
      articles = j.articles ?? [];
    } catch (e) {
      state.errors++;
      state.log.push(`news ${t.espn_slug} ${t.espn_team_id} FAIL: ${(e as Error).message}`);
      continue;
    }
    for (const a of articles) {
      if (!a.id) continue;
      const row = {
        espn_article_id: String(a.id),
        espn_team_id: t.espn_team_id,
        espn_league: t.espn_league,
        headline: a.headline ?? null,
        description: a.description ?? null,
        published_at: a.published ? new Date(a.published).toISOString() : null,
        url: a.links?.web?.href ?? null,
        image_url: a.images?.[0]?.url ?? null,
        type: a.type ?? null,
      };
      const { error } = await db.from("espn_news")
        .upsert(row, { onConflict: "espn_article_id", ignoreDuplicates: true });
      if (error) state.errors++;
      else state.news_inserted++;
    }
    await sleep(80);
  }
}

// ---------------------------------------------------------------------------
// Per-event game snapshot — for events in event_xref happening within the lookahead window
// ---------------------------------------------------------------------------

/**
 * Backfill event_xref for any upcoming TEvo event whose primary performer has a team_xref
 * row but isn't yet in event_xref. Resolves by (espn_team_id, date ±36h) against the team's
 * ESPN schedule. Called before collectEventSnapshots so we always have a current map.
 */
async function backfillEventXref(db: any, state: CollectorState) {
  const today = new Date().toISOString().slice(0, 10);
  const cutoff = new Date(Date.now() + EVENT_LOOKAHEAD_DAYS * 86400 * 1000).toISOString().slice(0, 10);
  // Pull upcoming events that have a team_xref-matched primary performer but no event_xref row
  const { data: candidates, error } = await db.rpc("find_unmatched_team_events", { p_today: today, p_cutoff: cutoff });
  let evList: any[] = candidates ?? [];
  if (error) {
    // Fallback: do the join manually with two queries (RPC may not exist yet)
    const { data: tx } = await db.from("team_xref").select("tevo_performer_id,espn_team_id,espn_league,espn_slug");
    const txMap = Object.fromEntries((tx ?? []).map((r: any) => [r.tevo_performer_id, r]));
    const performerIds = Object.keys(txMap).map(Number);
    if (!performerIds.length) return;
    const { data: events } = await db.from("events")
      .select("id,occurs_at_local,primary_performer_id,name")
      .in("primary_performer_id", performerIds)
      .gte("occurs_at_local", today)
      .lte("occurs_at_local", cutoff)
      .limit(200);
    const { data: existing } = await db.from("event_xref").select("tevo_event_id");
    const known = new Set((existing ?? []).map((r: any) => r.tevo_event_id));
    evList = (events ?? []).filter((e: any) => !known.has(e.id)).map((e: any) => ({
      tevo_event_id: e.id, occurs_at_local: e.occurs_at_local, primary_performer_id: e.primary_performer_id, name: e.name,
      espn_team_id: txMap[e.primary_performer_id].espn_team_id,
      espn_slug: txMap[e.primary_performer_id].espn_slug,
      espn_league: txMap[e.primary_performer_id].espn_league,
    }));
  }

  // Cache schedules per team to avoid duplicate fetches
  const scheduleCache: Record<string, any> = {};
  let backfilled = 0;
  for (const ev of evList) {
    const cacheKey = `${ev.espn_slug}:${ev.espn_team_id}`;
    if (!scheduleCache[cacheKey]) {
      try {
        scheduleCache[cacheKey] = await get(`/apis/site/v2/sports/${ev.espn_slug}/teams/${ev.espn_team_id}/schedule`);
        await sleep(80);
      } catch (e) {
        scheduleCache[cacheKey] = null;
        state.log.push(`schedule fetch FAIL ${cacheKey}: ${(e as Error).message}`);
        continue;
      }
    }
    const sched = scheduleCache[cacheKey];
    if (!sched) continue;
    const ourTs = new Date(ev.occurs_at_local).getTime();
    if (isNaN(ourTs)) continue;
    const window = 36 * 3600 * 1000;
    const match = (sched.events ?? []).find((e: any) => {
      const t = new Date(e.date).getTime();
      return !isNaN(t) && Math.abs(t - ourTs) < window;
    });
    if (!match) continue;

    const { error: ue } = await db.from("event_xref").upsert({
      tevo_event_id: ev.tevo_event_id,
      espn_event_id: String(match.id),
      espn_league: ev.espn_league,
      espn_slug: ev.espn_slug,
      match_method: "team_date",
      meta: { espn_event_name: match.name, espn_event_date: match.date, tevo_event_local: ev.occurs_at_local, source: "espn-collect" },
    }, { onConflict: "tevo_event_id" });
    if (ue) state.errors++;
    else backfilled++;
  }
  state.log.push(`event_xref backfill: ${backfilled} new mappings (${evList.length} candidates)`);
}

async function collectEventSnapshots(db: any, state: CollectorState) {
  // Pull all event_xref rows joined with events (FK-based), filter upcoming events in lookahead window.
  // Lexical date-prefix filter on TEXT column.
  const today = new Date().toISOString().slice(0, 10);
  const cutoff = new Date(Date.now() + EVENT_LOOKAHEAD_DAYS * 86400 * 1000).toISOString().slice(0, 10);
  const { data: rows } = await db.from("event_xref")
    .select("tevo_event_id,espn_event_id,espn_slug,espn_league,events!inner(occurs_at_local)")
    .gte("events.occurs_at_local", today)
    .lte("events.occurs_at_local", cutoff)
    .limit(200);

  for (const r of (rows ?? []) as any[]) {
    state.events_processed++;
    let summary: any;
    try {
      summary = await get(`/apis/site/v2/sports/${r.espn_slug}/summary`, { event: r.espn_event_id });
    } catch (e) {
      state.errors++;
      state.log.push(`event ${r.espn_event_id} FAIL: ${(e as Error).message}`);
      continue;
    }
    const c = summary.header?.competitions?.[0];
    const home = c?.competitors?.find((x: any) => x.homeAway === "home");
    const away = c?.competitors?.find((x: any) => x.homeAway === "away");
    const pc = summary.pickcenter?.[0];
    const wp = summary.winprobability ?? [];
    const last = wp[wp.length - 1];
    const row = {
      espn_event_id: r.espn_event_id,
      espn_league: r.espn_league,
      state: c?.status?.type?.state ?? null,
      status_short: c?.status?.type?.shortDetail ?? null,
      home_team_id: home?.team?.id ? String(home.team.id) : null,
      away_team_id: away?.team?.id ? String(away.team.id) : null,
      home_score: home?.score != null ? Number(home.score) : null,
      away_score: away?.score != null ? Number(away.score) : null,
      odds_provider: pc?.provider?.name ?? null,
      spread: pc?.details ?? null,
      over_under: pc?.overUnder != null ? Number(pc.overUnder) : null,
      home_ml: pc?.homeTeamOdds?.moneyLine ?? null,
      away_ml: pc?.awayTeamOdds?.moneyLine ?? null,
      home_win_prob: last?.homeWinPercentage != null ? Number(last.homeWinPercentage) : null,
      attendance: summary.gameInfo?.attendance ?? null,
    };
    const { error } = await db.from("espn_event_snapshots").insert(row);
    if (error && !/duplicate/i.test(error.message)) state.errors++;
    else state.event_snaps_inserted++;
    await sleep(80);
  }
}

// ---------------------------------------------------------------------------
// Webhook
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (expected && req.headers.get("x-cron-secret") !== expected) {
    return new Response("unauthorized", { status: 401 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: runRow, error: runErr } = await db.from("espn_runs").insert({}).select().single();
  if (runErr) return new Response(JSON.stringify({ error: "could not open run", details: runErr }), { status: 500 });
  const runId = runRow.id;

  const state: CollectorState = {
    teams_processed: 0, events_processed: 0,
    team_snaps_inserted: 0, injuries_inserted: 0, news_inserted: 0, event_snaps_inserted: 0,
    errors: 0, log: [],
  };

  try {
    await collectTeams(db, state);
    await collectNews(db, state);
    await backfillEventXref(db, state);
    await collectEventSnapshots(db, state);
  } catch (e) {
    state.errors++;
    state.log.push(`fatal: ${(e as Error).message}`);
  }

  await db.from("espn_runs").update({
    finished_at: new Date().toISOString(),
    teams_processed: state.teams_processed,
    events_processed: state.events_processed,
    injuries_inserted: state.injuries_inserted,
    news_inserted: state.news_inserted,
    team_snaps_inserted: state.team_snaps_inserted,
    event_snaps_inserted: state.event_snaps_inserted,
    errors: state.errors,
    log: state.log.join("\n"),
  }).eq("id", runId);

  return new Response(JSON.stringify({ run_id: runId, ...state }, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
