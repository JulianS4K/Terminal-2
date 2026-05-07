// Supabase Edge Function: espn
//
// Aggregates ESPN's public API data for the Terminal UI. The Terminal opens an
// ESPN-style side panel ONLY when the selected event/performer has a row in
// public.team_xref — non-team performers (concerts, comedy, etc) are filtered
// upstream via the /espn/applicable endpoint.
//
// Routes:
//   GET /espn/applicable?event_id=N        -> { applicable: bool, league?, sport_slug?, espn_team_id? }
//   GET /espn/applicable?performer_id=N    -> { applicable: bool, league?, sport_slug?, espn_team_id? }
//   GET /espn/event/{tevo_event_id}        -> aggregated game data (header, leaders, odds, win-prob, injuries, last plays)
//   GET /espn/performer/{tevo_performer_id} -> aggregated team data (record, standings rank, schedule, news, injuries)
//   GET /espn/raw?path=apis/site/v2/...    -> pass-through to ESPN (allowlisted)
//
// All responses cached briefly by ESPN's CDN; we add no extra caching here.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// CORS — frontend on Railway calls this from a different origin
// ---------------------------------------------------------------------------

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

// ---------------------------------------------------------------------------
// ESPN helpers
// ---------------------------------------------------------------------------

const ESPN_BASES = [
  "site.api.espn.com",
  "sports.core.api.espn.com",
  "site.web.api.espn.com",
  "cdn.espn.com",
  "now.core.api.espn.com",
] as const;

async function espnGet(host: string, path: string, query?: Record<string, string>) {
  const url = new URL(`https://${host}${path.startsWith("/") ? path : "/" + path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const r = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url.pathname}`);
  return r.json();
}

const site = (path: string, query?: Record<string, string>) => espnGet("site.api.espn.com", path, query);
const core = (path: string, query?: Record<string, string>) => espnGet("sports.core.api.espn.com", path, query);

// ---------------------------------------------------------------------------
// Event ↔ ESPN event resolver (uses team_xref + (team, date))
// ---------------------------------------------------------------------------

interface XrefHit {
  performer_id: number;
  espn_team_id: string;
  espn_league: string;
  espn_slug: string;
  espn_abbr: string | null;
}

async function lookupTeamXref(db: any, performerId: number): Promise<XrefHit | null> {
  const { data } = await db.from("team_xref")
    .select("tevo_performer_id,espn_team_id,espn_league,espn_slug,espn_abbr")
    .eq("tevo_performer_id", performerId)
    .maybeSingle();
  if (!data) return null;
  return {
    performer_id: data.tevo_performer_id,
    espn_team_id: data.espn_team_id,
    espn_league: data.espn_league,
    espn_slug: data.espn_slug,
    espn_abbr: data.espn_abbr,
  };
}

async function getOrPopulateEventXref(db: any, tevoEventId: number): Promise<{ espn_event_id: string; espn_slug: string; espn_league: string } | null> {
  // 1. Cache hit?
  const { data: hit } = await db.from("event_xref")
    .select("espn_event_id,espn_slug,espn_league")
    .eq("tevo_event_id", tevoEventId)
    .maybeSingle();
  if (hit) return hit;

  // 2. Resolve from team + date
  const { data: ev } = await db.from("events")
    .select("id,name,occurs_at_local,primary_performer_id,performer_ids,venue_id")
    .eq("id", tevoEventId)
    .maybeSingle();
  if (!ev) return null;

  // Try primary performer first, then any other performer in performer_ids
  const candidates: number[] = [
    ev.primary_performer_id,
    ...((ev.performer_ids ?? []) as number[]),
  ].filter((x): x is number => typeof x === "number");

  let team: XrefHit | null = null;
  for (const pid of candidates) {
    team = await lookupTeamXref(db, pid);
    if (team) break;
  }
  if (!team) return null;

  // 3. Fetch the team's ESPN schedule, find an event within ±36h of our event
  let schedule: any;
  try {
    schedule = await site(`/apis/site/v2/sports/${team.espn_slug}/teams/${team.espn_team_id}/schedule`);
  } catch (_) { return null; }
  const ourTs = new Date(ev.occurs_at_local).getTime();
  if (isNaN(ourTs)) return null;
  const window = 36 * 3600 * 1000;
  const match = (schedule.events ?? []).find((e: any) => {
    const t = new Date(e.date).getTime();
    return !isNaN(t) && Math.abs(t - ourTs) < window;
  });
  if (!match) return null;

  // 4. Persist
  const row = {
    tevo_event_id: tevoEventId,
    espn_event_id: String(match.id),
    espn_league: team.espn_league,
    espn_slug: team.espn_slug,
    match_method: "team_date",
    meta: { matched_team: team.espn_team_id, espn_event_name: match.name, espn_event_date: match.date, tevo_event_local: ev.occurs_at_local },
  };
  try { await db.from("event_xref").upsert(row, { onConflict: "tevo_event_id" }); } catch (_) { /* best-effort */ }
  return { espn_event_id: row.espn_event_id, espn_slug: row.espn_slug, espn_league: row.espn_league };
}

// ---------------------------------------------------------------------------
// Aggregators — shape the ESPN response into terminal-friendly chunks
// ---------------------------------------------------------------------------

function pluckLeaders(summary: any) {
  // ESPN leaders[*] = per-team. Each has `leaders[*]` with categories (points, rebounds, assists).
  return (summary.leaders ?? []).map((teamLeaders: any) => ({
    team: { id: teamLeaders.team?.id, abbr: teamLeaders.team?.abbreviation, name: teamLeaders.team?.displayName },
    categories: (teamLeaders.leaders ?? []).map((c: any) => ({
      category: c.name,
      display: c.displayName,
      top: c.leaders?.[0] && {
        athlete: c.leaders[0].athlete?.displayName,
        athlete_id: c.leaders[0].athlete?.id,
        value: c.leaders[0].displayValue,
      },
    })),
  }));
}

function pluckHeader(summary: any) {
  const h = summary.header || {};
  const c = h.competitions?.[0] || {};
  const home = c.competitors?.find((x: any) => x.homeAway === "home");
  const away = c.competitors?.find((x: any) => x.homeAway === "away");
  return {
    name: h.name,
    short: h.shortName,
    status: c.status?.type?.shortDetail,
    state: c.status?.type?.state,            // 'pre' | 'in' | 'post'
    period: c.status?.period,
    clock: c.status?.displayClock,
    venue: summary.gameInfo?.venue?.fullName,
    attendance: summary.gameInfo?.attendance,
    network: c.broadcasts?.[0]?.media?.shortName,
    competitors: { home: simpleTeam(home), away: simpleTeam(away) },
    series: c.series && {
      type: c.series.type,
      title: c.series.title,
      summary: c.series.summary,
    },
  };
}

function simpleTeam(c: any) {
  if (!c) return null;
  return {
    id: c.team?.id,
    abbr: c.team?.abbreviation,
    name: c.team?.displayName,
    score: c.score,
    record: c.record?.find((r: any) => r.type === "total")?.summary,
    winner: c.winner ?? null,
    logo: c.team?.logo ?? c.team?.logos?.[0]?.href,
  };
}

function pluckOdds(summary: any) {
  const pc = summary.pickcenter?.[0];
  if (!pc) return null;
  return {
    provider: pc.provider?.name,
    spread: pc.details,
    over_under: pc.overUnder,
    home_ml: pc.homeTeamOdds?.moneyLine,
    away_ml: pc.awayTeamOdds?.moneyLine,
    home_spread_odds: pc.homeTeamOdds?.spreadOdds,
    away_spread_odds: pc.awayTeamOdds?.spreadOdds,
  };
}

function pluckWinProb(summary: any) {
  const wp = summary.winprobability ?? [];
  if (!wp.length) return null;
  const last = wp[wp.length - 1];
  // Sample 30 evenly spaced points so the frontend can sparkline cheaply
  const sampled = wp.length <= 60 ? wp : Array.from({ length: 60 }, (_, i) => wp[Math.floor(i * wp.length / 60)]);
  return {
    points: sampled.map((p: any) => ({ play_id: p.playId, home_win_pct: p.homeWinPercentage, tied_pct: p.tiePercentage })),
    current_home_win_pct: last.homeWinPercentage,
    total_points: wp.length,
  };
}

function pluckInjuries(summary: any, max = 8) {
  const out: any[] = [];
  for (const team of summary.injuries ?? []) {
    for (const inj of team.injuries ?? []) {
      out.push({
        team: team.team?.abbreviation ?? team.displayName,
        athlete: inj.athlete?.displayName,
        position: inj.athlete?.position?.abbreviation,
        status: inj.status,
        comment: inj.shortComment,
      });
      if (out.length >= max) return out;
    }
  }
  return out;
}

function pluckLastPlays(summary: any, n = 8) {
  const plays = summary.plays ?? [];
  return plays.slice(-n).reverse().map((p: any) => ({
    period: p.period?.number,
    clock: p.clock?.displayValue,
    text: p.text,
    score_home: p.homeScore,
    score_away: p.awayScore,
  }));
}

// ---------------------------------------------------------------------------
// /espn/applicable — boolean gate for the frontend
// ---------------------------------------------------------------------------

async function applicable(db: any, eventId?: number | null, performerId?: number | null) {
  if (performerId != null) {
    const t = await lookupTeamXref(db, performerId);
    return t
      ? { applicable: true, league: t.espn_league, sport_slug: t.espn_slug, espn_team_id: t.espn_team_id }
      : { applicable: false };
  }
  if (eventId != null) {
    const { data: ev } = await db.from("events").select("primary_performer_id,performer_ids").eq("id", eventId).maybeSingle();
    if (!ev) return { applicable: false };
    const candidates = [ev.primary_performer_id, ...((ev.performer_ids ?? []) as number[])].filter((x: any) => typeof x === "number");
    for (const pid of candidates) {
      const t = await lookupTeamXref(db, pid);
      if (t) return { applicable: true, league: t.espn_league, sport_slug: t.espn_slug, espn_team_id: t.espn_team_id, performer_id: pid };
    }
    return { applicable: false };
  }
  return { applicable: false, error: "provide event_id or performer_id" };
}

// ---------------------------------------------------------------------------
// /espn/event/{id} — aggregate
// ---------------------------------------------------------------------------

async function aggregateEvent(db: any, tevoEventId: number) {
  const xref = await getOrPopulateEventXref(db, tevoEventId);
  if (!xref) return { applicable: false, reason: "no team_xref or no schedule match (date/team)" };

  const summary = await site(`/apis/site/v2/sports/${xref.espn_slug}/summary`, { event: xref.espn_event_id });

  return {
    applicable: true,
    espn_event_id: xref.espn_event_id,
    league: xref.espn_league,
    sport_slug: xref.espn_slug,
    header: pluckHeader(summary),
    leaders: pluckLeaders(summary),
    odds: pluckOdds(summary),
    win_probability: pluckWinProb(summary),
    injuries: pluckInjuries(summary),
    last_plays: pluckLastPlays(summary),
    article: summary.article && {
      headline: summary.article.headline,
      description: summary.article.description,
      images: (summary.article.images ?? []).slice(0, 1).map((i: any) => i.url),
    },
    broadcasts: (summary.broadcasts ?? []).map((b: any) => ({ market: b.market, names: b.names })).slice(0, 3),
  };
}

// ---------------------------------------------------------------------------
// /espn/performer/{id} — aggregate team page
// ---------------------------------------------------------------------------

async function aggregatePerformer(db: any, tevoPerformerId: number) {
  const team = await lookupTeamXref(db, tevoPerformerId);
  if (!team) return { applicable: false, reason: "no team_xref entry" };

  const [teamData, schedule, news, leagueInjuries] = await Promise.all([
    site(`/apis/site/v2/sports/${team.espn_slug}/teams/${team.espn_team_id}`).catch(() => null),
    site(`/apis/site/v2/sports/${team.espn_slug}/teams/${team.espn_team_id}/schedule`).catch(() => null),
    site(`/apis/site/v2/sports/${team.espn_slug}/news`, { team: team.espn_team_id, limit: "5" }).catch(() => null),
    site(`/apis/site/v2/sports/${team.espn_slug}/injuries`).catch(() => null),
  ]);

  const t = teamData?.team;
  const myInjuries = (leagueInjuries?.injuries ?? []).find((x: any) => String(x.id) === team.espn_team_id);

  return {
    applicable: true,
    league: team.espn_league,
    sport_slug: team.espn_slug,
    team: t && {
      id: t.id,
      name: t.displayName,
      abbreviation: t.abbreviation,
      record: t.record?.items?.[0]?.summary,
      standing: t.standingSummary,
      venue: t.franchise?.venue?.fullName,
      logo: t.logos?.[0]?.href,
      color: t.color && `#${t.color}`,
      next_event: t.nextEvent?.[0] && {
        id: t.nextEvent[0].id,
        name: t.nextEvent[0].name,
        date: t.nextEvent[0].date,
      },
    },
    upcoming: (schedule?.events ?? [])
      .filter((e: any) => new Date(e.date).getTime() > Date.now())
      .slice(0, 5)
      .map((e: any) => ({ id: e.id, name: e.shortName, date: e.date, status: e.competitions?.[0]?.status?.type?.shortDetail })),
    recent: (schedule?.events ?? [])
      .filter((e: any) => new Date(e.date).getTime() <= Date.now())
      .slice(-3)
      .map((e: any) => ({ id: e.id, name: e.shortName, date: e.date, status: e.competitions?.[0]?.status?.type?.shortDetail })),
    news: (news?.articles ?? []).slice(0, 5).map((a: any) => ({
      headline: a.headline,
      description: a.description,
      published: a.published,
      link: a.links?.web?.href,
      image: a.images?.[0]?.url,
    })),
    injuries: (myInjuries?.injuries ?? []).map((i: any) => ({
      athlete: i.athlete?.displayName,
      position: i.athlete?.position?.abbreviation,
      status: i.status,
      comment: i.shortComment,
    })),
  };
}

// ---------------------------------------------------------------------------
// /espn/raw — allowlisted pass-through. Lets the frontend reach any endpoint
// without us writing a wrapper for each. Restricted to public ESPN domains.
// ---------------------------------------------------------------------------

async function rawProxy(targetPath: string) {
  // Accept full URL or just `apis/...` — rewrite to a known host.
  let host = "site.api.espn.com";
  let path = targetPath;
  if (/^https?:\/\//i.test(path)) {
    const u = new URL(path);
    if (!ESPN_BASES.includes(u.host as any)) {
      return { error: "host not allowed", allowed: ESPN_BASES };
    }
    host = u.host;
    path = u.pathname + (u.search || "");
  }
  if (path.startsWith("/v2/") || path.startsWith("/v3/")) {
    // sports.core.api.espn.com paths
    host = "sports.core.api.espn.com";
  } else if (path.startsWith("/apis/v2/") || path.startsWith("/apis/site/")) {
    host = "site.api.espn.com";
  }
  try {
    const data = await espnGet(host, path);
    return { ok: true, host, path, data };
  } catch (e) {
    return { ok: false, error: String((e as Error).message), host, path };
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const url = new URL(req.url);
  // Edge-runtime path looks like /espn or /espn/event/123 — normalize to the part after /espn
  const m = url.pathname.match(/\/espn(\/.*)?$/);
  const sub = (m?.[1] ?? "/").replace(/^\/+/, "/");

  try {
    if (sub === "/" || sub === "/health") {
      return json({ ok: true, function: "espn", version: 1 });
    }

    if (sub === "/applicable") {
      const eid = url.searchParams.get("event_id");
      const pid = url.searchParams.get("performer_id");
      const result = await applicable(db, eid ? Number(eid) : null, pid ? Number(pid) : null);
      return json(result);
    }

    let mm: RegExpMatchArray | null;
    if ((mm = sub.match(/^\/event\/(\d+)$/))) {
      const result = await aggregateEvent(db, Number(mm[1]));
      return json(result);
    }
    if ((mm = sub.match(/^\/performer\/(\d+)$/))) {
      const result = await aggregatePerformer(db, Number(mm[1]));
      return json(result);
    }

    if (sub === "/raw") {
      const path = url.searchParams.get("path");
      if (!path) return json({ error: "?path=apis/site/v2/... required" }, 400);
      const result = await rawProxy(path);
      return json(result);
    }

    return json({ error: "unknown route", path: sub, valid_routes: ["/applicable", "/event/{tevo_event_id}", "/performer/{tevo_performer_id}", "/raw?path=..."] }, 404);
  } catch (e) {
    return json({ error: String((e as Error).message) }, 500);
  }
});
