// Supabase Edge Function: espn-rosters (v2)
// v2: release detection now only fires against open segments older than 1 hour
//     so the initial run's freshly-inserted segments aren't mis-classified.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ESPN_HOST = "site.api.espn.com";
const RELEASE_AGE_THRESHOLD_MS = 60 * 60 * 1000; // 1 hour

async function get(path: string, query?: Record<string, string>) {
  const url = new URL(`https://${ESPN_HOST}${path}`);
  if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const r = await fetch(url.toString(), { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url.pathname}`);
  return r.json();
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const num = (v: any) => v == null || v === "" ? null : Number(v);
function inchesFromHeight(h: any): number | null {
  if (h == null) return null;
  if (typeof h === "number") return Math.round(h);
  const m = String(h).match(/^(\d+)'\s*(\d+)/);
  if (m) return parseInt(m[1]) * 12 + parseInt(m[2]);
  const n = parseFloat(h);
  return isFinite(n) ? Math.round(n) : null;
}

interface AthleteRow {
  espn_athlete_id: string; full_name: string | null; display_name: string | null;
  short_name: string | null; jersey: string | null; position: string | null; position_abbr: string | null;
  height_inches: number | null; weight_lbs: number | null; birth_date: string | null; age: number | null;
  espn_team_id: string; espn_league: string; status: string | null;
  experience_years: number | null; headshot_url: string | null;
}

function parseAthlete(a: any, espnTeamId: string, espnLeague: string): AthleteRow | null {
  if (!a?.id) return null;
  return {
    espn_athlete_id: String(a.id),
    full_name: a.fullName ?? a.displayName ?? null,
    display_name: a.displayName ?? null,
    short_name: a.shortName ?? null,
    jersey: a.jersey ?? null,
    position: a.position?.name ?? null,
    position_abbr: a.position?.abbreviation ?? null,
    height_inches: inchesFromHeight(a.height),
    weight_lbs: num(a.weight),
    birth_date: a.dateOfBirth ? String(a.dateOfBirth).slice(0, 10) : null,
    age: num(a.age),
    espn_team_id: espnTeamId,
    espn_league: espnLeague,
    status: a.status?.type ?? a.status?.name ?? "active",
    experience_years: num(a.experience?.years),
    headshot_url: a.headshot?.href ?? null,
  };
}

async function fetchTeamRoster(slug: string, teamId: string): Promise<any[]> {
  const out: any[] = [];
  try {
    const j = await get(`/apis/site/v2/sports/${slug}/teams/${teamId}/roster`);
    if (Array.isArray(j.athletes)) {
      for (const group of j.athletes) {
        if (Array.isArray(group)) out.push(...group);
        else if (Array.isArray(group?.items)) out.push(...group.items);
      }
    }
  } catch (_) {}
  if (out.length === 0) {
    try {
      const j = await get(`/apis/site/v2/sports/${slug}/teams/${teamId}`, { enable: "roster" });
      const athletes = j.team?.athletes ?? [];
      out.push(...athletes);
    } catch (_) {}
  }
  return out;
}

interface RunStats {
  teams_processed: number; athletes_upserted: number; initial_segments: number;
  team_changes: number; releases: number; errors: number; log: string[];
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (expected && req.headers.get("x-cron-secret") !== expected) {
    return new Response("unauthorized", { status: 401 });
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any = {}; try { body = await req.json(); } catch (_) {}
  const leagueFilter = (body.league as string | undefined)?.toLowerCase();
  const teamFilter   = body.team_id as string | undefined;

  const stats: RunStats = {
    teams_processed: 0, athletes_upserted: 0, initial_segments: 0,
    team_changes: 0, releases: 0, errors: 0, log: [],
  };

  // NB: team_xref is now a VIEW over performer_external_ids (compat shim,
  // see migration team_xref_compat_view). Same columns, same query works.
  let q = db.from("team_xref").select("espn_team_id,espn_league,espn_slug,espn_display_name");
  if (leagueFilter) q = q.eq("espn_league", leagueFilter.toUpperCase());
  if (teamFilter)   q = q.eq("espn_team_id", teamFilter);
  const { data: teams, error: txErr } = await q;
  if (txErr) return new Response(JSON.stringify({ error: "team_xref read failed", details: txErr }), { status: 500 });

  const releaseCutoffIso = new Date(Date.now() - RELEASE_AGE_THRESHOLD_MS).toISOString();

  const seenByTeam = new Map<string, Set<string>>();

  for (const t of (teams ?? []) as any[]) {
    stats.teams_processed++;
    let roster: any[] = [];
    try {
      roster = await fetchTeamRoster(t.espn_slug, t.espn_team_id);
    } catch (e) {
      stats.errors++;
      stats.log.push(`team ${t.espn_team_id} roster fetch failed: ${(e as Error).message}`);
      continue;
    }
    const seen = new Set<string>();
    seenByTeam.set(t.espn_team_id, seen);

    const rowsByAthleteId = new Map<string, AthleteRow>();
    for (const a of roster) {
      const row = parseAthlete(a, t.espn_team_id, t.espn_league);
      if (!row) continue;
      rowsByAthleteId.set(row.espn_athlete_id, row);
      seen.add(row.espn_athlete_id);
    }
    const rows = [...rowsByAthleteId.values()];
    if (rows.length === 0) {
      stats.log.push(`team ${t.espn_team_id} (${t.espn_display_name}): empty roster`);
      await sleep(120);
      continue;
    }

    {
      const payload = rows.map((r) => ({ ...r, last_seen_at: new Date().toISOString() }));
      const { error } = await db.from("espn_athletes").upsert(payload, { onConflict: "espn_athlete_id" });
      if (error) { stats.errors++; stats.log.push(`upsert athletes ${t.espn_team_id}: ${error.message}`); continue; }
      stats.athletes_upserted += payload.length;
    }

    const ids = rows.map((r) => r.espn_athlete_id);
    const { data: openSegs } = await db.from("espn_athlete_team_history")
      .select("id, espn_athlete_id, espn_team_id")
      .in("espn_athlete_id", ids).is("end_date", null);
    const openByAthlete = new Map<string, { id: number; team_id: string | null }>();
    for (const seg of (openSegs ?? []) as any[]) {
      openByAthlete.set(seg.espn_athlete_id, { id: seg.id, team_id: seg.espn_team_id });
    }

    const today = new Date().toISOString().slice(0, 10);
    for (const r of rows) {
      const open = openByAthlete.get(r.espn_athlete_id);
      if (!open) {
        const { error } = await db.from("espn_athlete_team_history").insert({
          espn_athlete_id: r.espn_athlete_id, espn_team_id: r.espn_team_id,
          espn_league: r.espn_league, transaction_type: "initial_seen",
        });
        if (error) stats.errors++; else stats.initial_segments++;
        continue;
      }
      if (open.team_id === r.espn_team_id) continue;
      const closeRes = await db.from("espn_athlete_team_history").update({
        end_date: today,
      }).eq("id", open.id);
      if (closeRes.error) { stats.errors++; continue; }
      const ins = await db.from("espn_athlete_team_history").insert({
        espn_athlete_id: r.espn_athlete_id, espn_team_id: r.espn_team_id,
        espn_league: r.espn_league, transaction_type: "traded",
        prior_team_id: open.team_id,
        notes: `Was ${open.team_id ?? 'unknown'} → now ${r.espn_team_id}.`,
      });
      if (ins.error) stats.errors++; else stats.team_changes++;
    }

    await sleep(120);
  }

  // Release detection: only fires against segments older than the cutoff.
  for (const [teamId, seen] of seenByTeam) {
    const { data: opens } = await db.from("espn_athlete_team_history")
      .select("id, espn_athlete_id")
      .eq("espn_team_id", teamId)
      .is("end_date", null)
      .lt("detected_at", releaseCutoffIso);
    const today = new Date().toISOString().slice(0, 10);
    for (const o of (opens ?? []) as any[]) {
      if (seen.has(o.espn_athlete_id)) continue;
      const closeRes = await db.from("espn_athlete_team_history").update({
        end_date: today,
        transaction_type: "released",
        notes: "Disappeared from team roster on subsequent fetch.",
      }).eq("id", o.id);
      if (closeRes.error) stats.errors++; else stats.releases++;
      await db.from("espn_athletes").update({ status: "released" }).eq("espn_athlete_id", o.espn_athlete_id);
    }
  }

  return new Response(JSON.stringify(stats, null, 2), { headers: { "content-type": "application/json" } });
});
