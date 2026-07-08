// Supabase Edge Function: espn-seed-teams
//
// One-shot / occasional catalog seeder. Fetches ESPN's official team list for a
// set of leagues and upserts espn_teams_canonical(espn_league, espn_team_id,
// display_name). Runs server-side (ESPN is reachable from the edge runtime even
// when a dev proxy blocks it locally).
//
// Why this exists: espn_teams_canonical was hand-authored (169 pro teams,
// 20260510110000). Adding NWSL / CFL / NCAA football — especially "all college
// football conferences" (~250+ teams) — is impractical to hand-author with
// correct ESPN team_ids, so we pull them from the source of truth.
//
// The Tevo-performer mapping (performer_espn_team_xref + performer_external_ids)
// is done separately in SQL by name-match against the rows this function seeds.
//
// Body: { leagues?: [{ league, slug }] }  (defaults to the three new leagues).
// ESPN teams endpoint: site.api.espn.com/apis/site/v2/sports/{slug}/teams
//   -> sports[0].leagues[0].teams[].team.{id, displayName}
// College football returns a large paginated list; we page defensively and stop
// when a page adds no new team ids (works whether or not ESPN honors ?page).
//
// Auth: x-cron-secret (requireCronSecret). Deploy with verify_jwt=false.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const DEFAULT_LEAGUES: Array<{ league: string; slug: string }> = [
  { league: "NWSL", slug: "soccer/usa.nwsl" },
  { league: "CFL", slug: "football/cfl" },
  { league: "NCAAF", slug: "football/college-football" },
];

async function get(url: string) {
  const r = await fetch(url, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url}`);
  return r.json();
}

// Pull every team for a league slug. Pages until a request yields no new ids
// (dedupe-and-stop is robust whether ESPN paginates or returns the full set).
async function fetchTeams(slug: string, log: string[]): Promise<Array<{ id: string; name: string }>> {
  const byId = new Map<string, string>();
  const LIMIT = 250;
  for (let page = 1; page <= 20; page++) {
    let data: any;
    try {
      data = await get(`https://site.api.espn.com/apis/site/v2/sports/${slug}/teams?limit=${LIMIT}&page=${page}`);
    } catch (e) {
      log.push(`${slug} page ${page} FAIL: ${(e as Error).message}`);
      break;
    }
    const teams = data?.sports?.[0]?.leagues?.[0]?.teams ?? [];
    let added = 0;
    for (const t of teams as any[]) {
      const team = t?.team ?? t;
      const id = team?.id != null ? String(team.id) : null;
      const name = team?.displayName ?? team?.name ?? null;
      if (!id || !name) continue;
      if (!byId.has(id)) { byId.set(id, name); added++; }
    }
    log.push(`${slug} page ${page}: ${teams.length} returned, ${added} new (total ${byId.size})`);
    if (teams.length === 0 || added === 0) break;
    await sleep(150);
  }
  return Array.from(byId, ([id, name]) => ({ id, name }));
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let leagues = DEFAULT_LEAGUES;
  try {
    const body = await req.json();
    if (Array.isArray(body?.leagues) && body.leagues.length) leagues = body.leagues;
  } catch { /* no body -> defaults */ }

  const log: string[] = [];
  const summary: Record<string, number> = {};
  let errors = 0;

  for (const { league, slug } of leagues) {
    const teams = await fetchTeams(slug, log);
    if (!teams.length) { errors++; summary[league] = 0; continue; }
    const rows = teams.map((t) => ({ espn_league: league, espn_team_id: t.id, display_name: t.name }));
    const { error } = await db.from("espn_teams_canonical")
      .upsert(rows, { onConflict: "espn_team_id,espn_league" });
    if (error) { errors++; log.push(`${league} upsert FAIL: ${error.message}`); summary[league] = 0; }
    else summary[league] = rows.length;
    await sleep(150);
  }

  return new Response(JSON.stringify({ summary, errors, log }, null, 2), {
    headers: { "content-type": "application/json" },
  });
});
