// Supabase Edge Function: espn-league-collect
//
// League-level ESPN data that is NOT team/event/roster-scoped (those live in
// espn-collect / espn-rosters). Daily cadence — slow-moving aggregate pages.
//
// Routes (via ?scope= query param):
//   ?scope=transactions  -> league roster-move ledger (append-only, deduped)
//   ?scope=attendance    -> per-team season attendance (change-only snapshots)
//   ?scope=stats         -> full-roster player stats (current-season snapshot)
//   ?scope=gamelog       -> per-game box-score lines (batched staleness rotation)
//
// Source endpoints (verified live 2026-07-04 from Supabase pg_net):
//   transactions: site.api.espn.com/apis/site/v2/sports/{sport}/{league}/transactions
//     -> { season, transactions: [{ date, description, team{ id, abbreviation,
//        displayName } }] }
//   attendance: www.espn.com/{league}/attendance/_/year/{Y}  (legacy HTML
//     tablehead; parsed). The /_/year/{Y} form is required — the bare URL renders
//     an empty page for a not-yet-started season in the offseason, so we request
//     the current year and fall back to the previous completed season.
//
// League set is derived from performer_external_ids (source='espn') distinct
// espn_slug values, so MLB/NBA/NFL (and any future ESPN league) are covered with
// no hardcoding; leagues whose transactions endpoint 404s are skipped gracefully.
//
// Auth: x-cron-secret (requireCronSecret). Deploy with verify_jwt=false, same as
// espn-collect (the cron sends only X-Cron-Secret, no Authorization header).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const ESPN_HOST = "site.api.espn.com";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function get(path: string, query?: Record<string, string>) {
  const url = new URL(`https://${ESPN_HOST}${path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const r = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url.pathname}`);
  return r.json();
}

// SHA-256 hex — deterministic dedup key. Not cryptographic; identity only.
async function sha256hex(s: string): Promise<string> {
  const buf = new TextEncoder().encode(s);
  const h = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface LeagueSlug { espn_slug: string; espn_league: string; }

// Distinct (espn_slug, league) from performer_external_ids — one row per league.
async function distinctLeagues(db: any): Promise<LeagueSlug[]> {
  const { data } = await db.from("performer_external_ids")
    .select("league,meta").eq("source", "espn");
  const seen: Record<string, LeagueSlug> = {};
  for (const r of (data ?? []) as any[]) {
    const slug = r.meta?.espn_slug as string | undefined;
    if (slug && !seen[slug]) seen[slug] = { espn_slug: slug, espn_league: r.league };
  }
  return Object.values(seen);
}

interface TxnState {
  leagues_processed: number;
  transactions_seen: number;
  transactions_inserted: number;
  errors: number;
  log: string[];
}

async function collectTransactions(db: any, state: TxnState) {
  const leagues = await distinctLeagues(db);
  state.log.push(`transactions: ${leagues.length} leagues`);
  for (const l of leagues) {
    let txns: any[] = [];
    try {
      // limit=100 gives headroom over the 25 default so a busy day (e.g. NFL
      // cutdowns) between daily polls isn't truncated; dedup makes re-polls free.
      const j = await get(`/apis/site/v2/sports/${l.espn_slug}/transactions`, { limit: "100" });
      txns = j.transactions ?? [];
    } catch (e) {
      state.errors++;
      state.log.push(`txn ${l.espn_slug} FAIL: ${(e as Error).message}`);
      continue;
    }
    state.leagues_processed++;
    const rows: any[] = [];
    for (const t of txns) {
      const teamId = t.team?.id != null ? String(t.team.id) : null;
      const date = t.date ?? "";
      const desc = t.description ?? "";
      if (!date && !desc) continue;
      const txn_key = await sha256hex(`${l.espn_league}|${teamId ?? ""}|${date}|${desc}`);
      rows.push({
        txn_key,
        espn_league: l.espn_league,
        espn_team_id: teamId,
        team_abbr: t.team?.abbreviation ?? null,
        team_display_name: t.team?.displayName ?? null,
        txn_date: date ? new Date(date).toISOString() : null,
        description: desc || null,
        meta: { espn_slug: l.espn_slug, team_location: t.team?.location ?? null },
      });
    }
    state.transactions_seen += rows.length;
    // Chunked upsert (ignoreDuplicates => re-poll is a no-op after first pass).
    for (let i = 0; i < rows.length; i += 500) {
      const chunk = rows.slice(i, i + 500);
      const { error } = await db.from("espn_transactions")
        .upsert(chunk, { onConflict: "txn_key", ignoreDuplicates: true });
      if (error) { state.errors++; state.log.push(`upsert ${l.espn_slug}: ${error.message}`); }
      else state.transactions_inserted += chunk.length;
    }
    state.log.push(`txn ${l.espn_slug} (${l.espn_league}): ${rows.length} rows`);
    await sleep(120);
  }
}

// ---------------------------------------------------------------------------
// Attendance — parse the legacy HTML table at
// www.espn.com/{league}/attendance/_/year/{Y}. The league path is the last
// segment of the espn_slug ("baseball/mlb" -> "mlb").
// ---------------------------------------------------------------------------

const WWW_HOST = "www.espn.com";

async function getHtml(path: string): Promise<string> {
  const r = await fetch(`https://${WWW_HOST}${path}`, { headers: { Accept: "text/html" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${path}`);
  return r.text();
}

const stripTags = (s: string) => s.replace(/<[^>]*>/g, "").trim();
const numOrNull = (s: string) => {
  const c = s.replace(/,/g, "").trim();
  if (c === "" || c === "-" || c === "--") return null;
  const n = Number(c);
  return isFinite(n) ? n : null;
};

type AttRow = { espnTeamId: string; season: number } & Record<string, number | string | null>;

// Build the per-column schema from the table header. Column layout varies by
// league (MLB has PCT + no road/overall TOTAL; NFL has TOTAL everywhere + no
// PCT), so we derive keys like "home_avg"/"road_total" from the stathead group
// bands (Home/Road/Overall) crossed with the colhead labels (GMS/TOTAL/AVG/PCT)
// rather than assuming fixed indices.
function attColumnKeys(html: string): (string | null)[] {
  const stathead = html.match(/<tr class="stathead">([\s\S]*?)<\/tr>/);
  const section: string[] = [];
  if (stathead) {
    const cellRe = /<td([^>]*)>([\s\S]*?)<\/td>/g;
    let g: RegExpExecArray | null;
    while ((g = cellRe.exec(stathead[1])) !== null) {
      const spanM = g[1].match(/colspan="(\d+)"/);
      const span = spanM ? Number(spanM[1]) : 1;
      const label = stripTags(g[2]).toLowerCase();
      const sec = label.includes("home") ? "home"
        : (label.includes("road") || label.includes("away")) ? "road"
        : label.includes("overall") ? "overall" : "";
      for (let i = 0; i < span; i++) section.push(sec);
    }
  }
  const colhead = html.match(/<tr class="colhead">([\s\S]*?)<\/tr>/);
  const keys: (string | null)[] = [];
  if (colhead) {
    const cRe = /<td[^>]*>([\s\S]*?)<\/td>/g;
    let c: RegExpExecArray | null;
    let i = 0;
    while ((c = cRe.exec(colhead[1])) !== null) {
      const short = stripTags(c[1]).toUpperCase();
      const sec = section[i] || "";
      i++;
      if (short === "RK") { keys.push("rank"); continue; }
      if (short === "TEAM") { keys.push("team"); continue; }
      const metric = short === "GMS" ? "games" : short === "TOTAL" ? "total"
        : short === "AVG" ? "avg" : short === "PCT" ? "pct" : null;
      keys.push(metric && sec ? `${sec}_${metric}` : null);
    }
  }
  return keys;
}

// Parse the legacy tablehead attendance table. Returns one row per team.
function parseAttendance(html: string): AttRow[] {
  const seasonM = html.match(/(\d{4})\s+Attendance/);
  const season = seasonM ? Number(seasonM[1]) : new Date().getUTCFullYear();
  const keys = attColumnKeys(html);
  const out: AttRow[] = [];
  // Row class carries the numeric team id; tolerate trailing attrs (NFL adds
  // align="right"): "oddrow team-{sportId}-{teamId}" [ align="right" ] >.
  const rowRe = /<tr class="(?:odd|even)row team-([\d-]+)"[^>]*>([\s\S]*?)<\/tr>/g;
  const seen = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = rowRe.exec(html)) !== null) {
    const espnTeamId = m[1].split("-").pop()!;
    if (seen.has(espnTeamId)) continue;  // a page may render the table twice (sortable variants)
    seen.add(espnTeamId);
    const tds = [...m[2].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((x) => x[1]);
    if (tds.length < 3) continue;
    const row: AttRow = { espnTeamId, season };
    for (let i = 0; i < tds.length; i++) {
      const key = keys[i];
      if (!key) continue;
      if (key === "rank") row.rank = numOrNull(stripTags(tds[i]));
      else if (key === "team") {
        row.team_name = stripTags(tds[i]) || null;
        const abbrM = tds[i].match(/\/name\/([a-z0-9]+)\//i);
        row.team_abbr = abbrM ? abbrM[1] : null;
      } else row[key] = numOrNull(stripTags(tds[i]));
    }
    // Skip All-Star / exhibition rows (no /name/{abbr}/ team link) — e.g. NBA's
    // "Team Stars"/"World" show up in the attendance table but aren't franchises.
    if (!row.team_abbr) continue;
    out.push(row);
  }
  return out;
}

// A season is "populated" if teams have real attendance — either an AVERAGE or a
// TOTAL. Games alone isn't enough: ESPN pre-fills a not-yet-started season with a
// full schedule but zero attendance. (NBA is a special case: ESPN publishes home
// TOTAL but serves AVG=0 / PCT=-- for every NBA team, so we key on total there.)
const attHasData = (rows: AttRow[]) =>
  rows.some((r) => (Number(r.home_avg) || 0) > 0 || (Number(r.overall_avg) || 0) > 0 || (Number(r.home_total) || 0) > 0);

async function collectAttendance(db: any, state: TxnState) {
  const leagues = await distinctLeagues(db);
  const thisYear = new Date().getUTCFullYear();
  state.log.push(`attendance: ${leagues.length} leagues`);
  for (const l of leagues) {
    const leaguePath = l.espn_slug.split("/").pop();
    // Use the explicit /_/year/{Y} URL. Try the current season; if it's the
    // empty offseason page, fall back to the last completed season.
    let rows: AttRow[] = [];
    let usedYear = thisYear;
    try {
      for (const y of [thisYear, thisYear - 1]) {
        const html = await getHtml(`/${leaguePath}/attendance/_/year/${y}`);
        const parsed = parseAttendance(html);
        if (attHasData(parsed)) { rows = parsed; usedYear = y; break; }
        rows = parsed; usedYear = y; // keep last attempt even if empty
        if (attHasData(parsed)) break;
        await sleep(120);
      }
    } catch (e) {
      state.errors++;
      state.log.push(`att ${leaguePath} FAIL: ${(e as Error).message}`);
      continue;
    }
    let inserted = 0;
    const fields = ["season", "rank", "home_games", "home_total", "home_avg", "home_pct",
      "road_games", "road_total", "road_avg", "road_pct",
      "overall_games", "overall_total", "overall_avg", "overall_pct"];
    for (const r of rows) {
      const hash = await sha256hex(fields.map((k) => (r[k] == null ? "" : String(r[k]))).join("|"));
      const payload: Record<string, unknown> = { team_name: r.team_name ?? null, team_abbr: r.team_abbr ?? null, meta: { espn_slug: l.espn_slug } };
      for (const k of fields) payload[k] = r[k] ?? null;
      const { data: ret, error } = await db.rpc("upsert_espn_attendance_snapshot", {
        p_team_id: r.espnTeamId, p_league: l.espn_league, p_hash: hash, p_payload: payload,
      });
      if (error) { state.errors++; state.log.push(`att upsert ${r.espnTeamId}: ${error.message}`); }
      else if (ret?.[0]?.action === "inserted") inserted++;
    }
    state.leagues_processed++;
    state.transactions_seen += rows.length;
    state.transactions_inserted += inserted;
    state.log.push(`att ${leaguePath} (${l.espn_league}): ${rows.length} teams, season ${usedYear}, +${inserted}`);
    await sleep(150);
  }
}

// ---------------------------------------------------------------------------
// Player stats — full-roster byathlete, paginated, bulk-upserted into
// espn_player_stats (current-season snapshot). site.web.api.espn.com host.
// Categories are sport-specific: MLB pulls batting + pitching (one category per
// call); NBA/WNBA pull the default set (general/offensive/defensive) merged.
// ---------------------------------------------------------------------------

const WEB_HOST = "site.web.api.espn.com";
async function getWeb(path: string, query: Record<string, string>) {
  const url = new URL(`https://${WEB_HOST}${path}`);
  for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const r = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url.pathname}`);
  return r.json();
}

// { espn_slug: [{ apiCategory, storeCategory }] }. apiCategory '' => no ?category=
// param (basketball default). storeCategory is the row's `category` label.
const STATS_CONFIG: Record<string, { apiCategory: string; storeCategory: string }[]> = {
  "baseball/mlb":   [{ apiCategory: "batting", storeCategory: "batting" }, { apiCategory: "pitching", storeCategory: "pitching" }],
  "basketball/nba":  [{ apiCategory: "", storeCategory: "general" }],
  "basketball/wnba": [{ apiCategory: "", storeCategory: "general" }],
  // new leagues (2026-07-08). Football pulls the main offensive categories;
  // soccer uses the default leader set. Any category that 404s is skipped.
  "football/college-football": [{ apiCategory: "passing", storeCategory: "passing" }, { apiCategory: "rushing", storeCategory: "rushing" }, { apiCategory: "receiving", storeCategory: "receiving" }],
  "football/cfl":              [{ apiCategory: "passing", storeCategory: "passing" }, { apiCategory: "rushing", storeCategory: "rushing" }, { apiCategory: "receiving", storeCategory: "receiving" }],
  "soccer/usa.nwsl":           [{ apiCategory: "", storeCategory: "general" }],
};
const STATS_MAX_PAGES = 40;

async function collectStats(db: any, state: TxnState) {
  const leagues = await distinctLeagues(db);
  const thisYear = new Date().getUTCFullYear();
  for (const l of leagues) {
    const cfg = STATS_CONFIG[l.espn_slug];
    if (!cfg) continue;
    state.leagues_processed++;
    for (const { apiCategory, storeCategory } of cfg) {
      let page = 1, pages = 1, upserted = 0;
      do {
        const q: Record<string, string> = {
          region: "us", lang: "en", contentorigin: "espn",
          isqualified: "false", page: String(page), limit: "50",
        };
        if (apiCategory) q.category = apiCategory;
        let data: any;
        try { data = await getWeb(`/apis/common/v3/sports/${l.espn_slug}/statistics/byathlete`, q); }
        catch (e) { state.errors++; state.log.push(`stats ${l.espn_slug}/${storeCategory} p${page} FAIL: ${(e as Error).message}`); break; }
        pages = Math.min(data.pagination?.pages ?? 1, STATS_MAX_PAGES);
        const season = data.season?.year ?? data.requestedSeason?.year ?? thisYear;
        const catDefs = (data.categories ?? []) as any[];
        const rows: any[] = [];
        for (const entry of (data.athletes ?? []) as any[]) {
          const a = entry.athlete;
          if (!a?.id) continue;
          const stats: Record<string, string> = {};
          const statsNum: Record<string, number> = {};
          for (const ac of (entry.categories ?? []) as any[]) {
            const def = catDefs.find((d) => d.name === ac.name) ?? catDefs[0];
            const names = def?.names ?? [];
            (ac.totals ?? []).forEach((v: any, i: number) => { if (names[i]) stats[names[i]] = String(v); });
            (ac.values ?? []).forEach((v: any, i: number) => { if (names[i] && typeof v === "number") statsNum[names[i]] = v; });
          }
          // ESPN occasionally serves "-" in the display `totals` for a stat whose
          // numeric `value` is real (e.g. HR leaders showing "-"). stats_num is
          // authoritative — backfill a dash/blank display from the numeric.
          for (const k of Object.keys(statsNum)) {
            const d = stats[k];
            if (d === undefined || d === "-" || d === "--" || d === "") stats[k] = String(statsNum[k]);
          }
          const hash = await sha256hex(JSON.stringify(statsNum));
          rows.push({
            espn_athlete_id: String(a.id), espn_league: l.espn_league, category: storeCategory,
            season, athlete_name: a.displayName ?? null,
            position: a.position?.abbreviation ?? a.position?.name ?? null,
            team_abbr: entry.team?.abbreviation ?? a.teamShortName ?? null,
            stats, stats_num: statsNum, content_hash: hash,
            updated_at: new Date().toISOString(), meta: { espn_slug: l.espn_slug },
          });
        }
        if (rows.length) {
          const { error } = await db.from("espn_player_stats")
            .upsert(rows, { onConflict: "espn_athlete_id,espn_league,category" });
          if (error) { state.errors++; state.log.push(`stats upsert ${l.espn_slug}/${storeCategory} p${page}: ${error.message}`); }
          else upserted += rows.length;
        }
        page++;
        await sleep(90);
      } while (page <= pages);
      state.transactions_inserted += upserted;
      state.log.push(`stats ${l.espn_slug}/${storeCategory}: ${upserted} athletes, ${pages} pages`);
    }
  }
}

// ---------------------------------------------------------------------------
// Player game logs — per-game box-score lines for the terminal player page +
// fantasy scoring. Batched, staleness-rotating worker: each invocation processes
// the N least-recently-synced active athletes (espn_gamelog_next_batch) across
// the 4 requested leagues, so a frequent cron rotates through the full roster.
// ---------------------------------------------------------------------------

// CFL + NCAAF added 2026-07-08 (football fantasy ruleset applies to both). NWSL
// is soccer with no fantasy ruleset and sparse per-game logs, so it stays out.
// NHL added 2026-07-08: the hockey fantasy ruleset/profile ship in mig
// 20260705180000; this wires the gamelog primitive so NHL athletes get scored
// stat lines. The parser below is sport-agnostic (stores whatever ESPN `labels`
// it returns), so no hockey-specific parsing is needed — but the NHL ruleset
// keys in that migration are PROVISIONAL and must be reconciled against the
// real hockey `labels` once these rows land (see PR #806's follow-up note).
const GAMELOG_LEAGUES = ["MLB", "NBA", "NFL", "WNBA", "CFL", "NCAAF", "NHL"];
const LEAGUE_SLUG: Record<string, string> = {
  MLB: "baseball/mlb", NBA: "basketball/nba", WNBA: "basketball/wnba", NFL: "football/nfl",
  CFL: "football/cfl", NCAAF: "football/college-football", NHL: "hockey/nhl",
};

async function collectGamelog(db: any, state: TxnState, limit: number) {
  const { data: batch } = await db.rpc("espn_gamelog_next_batch", { p_leagues: GAMELOG_LEAGUES, p_limit: limit });
  let athletes = 0, games = 0;
  for (const a of (batch ?? []) as any[]) {
    const slug = LEAGUE_SLUG[a.espn_league];
    if (!slug) continue;
    athletes++;
    let data: any;
    try { data = await getWeb(`/apis/common/v3/sports/${slug}/athletes/${a.espn_athlete_id}/gamelog`, {}); }
    catch (_) {
      // 404 / no gamelog — write a marker so staleness advances (skip next pass).
      await db.from("espn_player_gamelog").upsert([{ espn_athlete_id: String(a.espn_athlete_id), espn_league: a.espn_league, espn_event_id: "none", athlete_name: a.full_name ?? null, updated_at: new Date().toISOString(), meta: { empty: true } }], { onConflict: "espn_athlete_id,espn_league,espn_event_id" });
      await sleep(50);
      continue;
    }
    const labels = (data.labels ?? []) as string[];
    const evMeta = data.events ?? {};
    const rows: any[] = [];
    for (const st of (data.seasonTypes ?? []) as any[]) {
      for (const cat of (st.categories ?? []) as any[]) {
        for (const g of (cat.events ?? []) as any[]) {
          const eid = String(g.eventId);
          const m = evMeta[eid] ?? {};
          const stats: Record<string, string> = {};
          const statsNum: Record<string, number> = {};
          (g.stats ?? []).forEach((v: any, i: number) => {
            const lbl = labels[i];
            if (!lbl) return;
            stats[lbl] = String(v);
            if (/^-?[0-9]+(\.[0-9]+)?$/.test(String(v))) statsNum[lbl] = Number(v);
          });
          rows.push({
            espn_athlete_id: String(a.espn_athlete_id), espn_league: a.espn_league, espn_event_id: eid,
            game_date: m.gameDate ?? null, season_type: st.displayName ?? null,
            opponent_abbr: m.opponent?.abbreviation ?? null, home_away: m.atVs ?? null,
            result: m.gameResult ?? null, score: m.score ?? null,
            team_abbr: m.team?.abbreviation ?? null, athlete_name: a.full_name ?? null,
            stats, stats_num: statsNum, content_hash: await sha256hex(JSON.stringify(g.stats ?? [])),
            updated_at: new Date().toISOString(), meta: { espn_slug: slug },
          });
        }
      }
    }
    if (rows.length) {
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        const { error } = await db.from("espn_player_gamelog").upsert(chunk, { onConflict: "espn_athlete_id,espn_league,espn_event_id" });
        if (error) { state.errors++; state.log.push(`gl upsert ${a.espn_athlete_id}: ${error.message}`); } else games += chunk.length;
      }
    } else {
      await db.from("espn_player_gamelog").upsert([{ espn_athlete_id: String(a.espn_athlete_id), espn_league: a.espn_league, espn_event_id: "none", athlete_name: a.full_name ?? null, updated_at: new Date().toISOString(), meta: { empty: true } }], { onConflict: "espn_athlete_id,espn_league,espn_event_id" });
    }
    await sleep(60);
  }
  state.transactions_inserted += games;
  state.leagues_processed = athletes;
  state.log.push(`gamelog: ${athletes} athletes, ${games} game rows`);
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const url = new URL(req.url);
  const scope = url.searchParams.get("scope") ?? "transactions";
  const glLimit = Math.max(1, Math.min(Number(url.searchParams.get("limit") ?? "100"), 400));
  const valid = ["transactions", "attendance", "stats", "gamelog"];
  if (!valid.includes(scope)) {
    return new Response(JSON.stringify({ error: `unknown scope: ${scope}`, valid }), { status: 400 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: runRow } = await db.from("espn_runs").insert({}).select().single();
  const runId = runRow?.id;

  const state: TxnState = {
    leagues_processed: 0, transactions_seen: 0, transactions_inserted: 0,
    errors: 0, log: [`scope=${scope}`],
  };

  try {
    if (scope === "transactions") await collectTransactions(db, state);
    else if (scope === "attendance") await collectAttendance(db, state);
    else if (scope === "stats") await collectStats(db, state);
    else if (scope === "gamelog") await collectGamelog(db, state, glLimit);
  } catch (e) {
    state.errors++;
    state.log.push(`fatal: ${(e as Error).message}`);
  }

  if (runId) {
    await db.from("espn_runs").update({
      finished_at: new Date().toISOString(),
      news_inserted: state.transactions_inserted,
      errors: state.errors,
      log: state.log.join("\n"),
    }).eq("id", runId);
  }

  return new Response(JSON.stringify({ run_id: runId, scope, ...state }, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
