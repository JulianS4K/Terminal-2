// Supabase Edge Function: espn-racing
//
// Two scopes for F1 + NASCAR Cup/Xfinity/Truck (body {scope} = standings|events|
// all, default all):
//   * standings -> espn_racing_standings (driver championship, current snapshot).
//     Source: site.api.espn.com/apis/v2/sports/racing/{slug}/standings.
//     children[].standings.entries[].{athlete, stats[]}.
//   * events -> espn_racing_events (race calendar, current window).
//     Source: site.api.espn.com/apis/site/v2/sports/racing/{slug}/scoreboard.
//     events[].{id,date,endDate,name,shortName,season,competitions[].{status,venue}}.
// Both verified live 2026-07-04.
//
// Auth: x-cron-secret (requireCronSecret). Deploy with verify_jwt=false.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// stored series -> ESPN racing slug
const SERIES: Record<string, string> = {
  "f1": "f1", "nascar-cup": "nascar-premier",
  "nascar-xfinity": "nascar-secondary", "nascar-truck": "nascar-truck",
};

async function get(url: string) {
  const r = await fetch(url, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url}`);
  return r.json();
}
async function sha256hex(s: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
const num = (v: any) => (v == null || v === "" || isNaN(Number(v)) ? null : Number(v));

async function collectStandings(db: any, season: number, log: string[]): Promise<{ total: number; errors: number }> {
  let total = 0, errors = 0;
  for (const [series, slug] of Object.entries(SERIES)) {
    let data: any;
    try { data = await get(`https://site.api.espn.com/apis/v2/sports/racing/${slug}/standings`); }
    catch (e) { errors++; log.push(`standings ${series} FAIL: ${(e as Error).message}`); continue; }
    const rows: any[] = [];
    const seen = new Set<string>();
    for (const child of (data.children ?? []) as any[]) {
      for (const e of (child.standings?.entries ?? []) as any[]) {
        const a = e.athlete;
        if (!a?.id || seen.has(String(a.id))) continue;
        seen.add(String(a.id));
        const statsMap: Record<string, string> = {};
        let rank: number | null = null, points: number | null = null, wins: number | null = null;
        for (const s of (e.stats ?? []) as any[]) {
          if (s.name) statsMap[s.name] = String(s.displayValue ?? s.value ?? "");
          if (s.type === "rank" || s.name === "rank") rank = num(s.value);
          if (s.type === "points" || s.name === "championshipPts") points = num(s.value);
          if (s.name === "wins") wins = num(s.value);
        }
        rows.push({
          series, espn_athlete_id: String(a.id),
          driver_name: a.displayName ?? a.name ?? null,
          driver_abbr: a.abbreviation ?? null,
          country: a.flag?.alt ?? null,
          rank, points, wins, season, stats: statsMap,
          content_hash: await sha256hex(JSON.stringify(statsMap)),
          updated_at: new Date().toISOString(), meta: { slug },
        });
      }
    }
    if (rows.length) {
      const { error } = await db.from("espn_racing_standings").upsert(rows, { onConflict: "series,espn_athlete_id" });
      if (error) { errors++; log.push(`standings ${series} upsert: ${error.message}`); } else total += rows.length;
    }
    log.push(`standings ${series} (${slug}): ${rows.length} drivers`);
    await sleep(120);
  }
  return { total, errors };
}

async function collectEvents(db: any, season: number, log: string[]): Promise<{ total: number; errors: number }> {
  let total = 0, errors = 0;
  for (const [series, slug] of Object.entries(SERIES)) {
    // ?dates={season} returns the full-season calendar (vs the default single
    // featured race); fall back to the bare scoreboard if the season query fails.
    let data: any = null;
    try { data = await get(`https://site.api.espn.com/apis/site/v2/sports/racing/${slug}/scoreboard?dates=${season}`); }
    catch { /* retry bare below */ }
    if (!data) {
      try { data = await get(`https://site.api.espn.com/apis/site/v2/sports/racing/${slug}/scoreboard`); }
      catch (e) { errors++; log.push(`events ${series} FAIL: ${(e as Error).message}`); continue; }
    }
    const rows: any[] = [];
    for (const ev of (data.events ?? []) as any[]) {
      if (!ev?.id) continue;
      const comp = (ev.competitions ?? [])[0] ?? {};
      const st = comp.status?.type ?? {};
      // F1 carries the track in ev.circuit; NASCAR has none (the name is the track).
      const venue = comp.venue?.fullName ?? ev.circuit?.fullName ?? ev.venue?.fullName ?? null;
      rows.push({
        series, espn_event_id: String(ev.id),
        name: ev.name ?? null, short_name: ev.shortName ?? null,
        event_date: ev.date ?? null, end_date: ev.endDate ?? null,
        season: num(ev.season?.year), season_type: num(ev.season?.type),
        season_slug: ev.season?.slug ?? null,
        status_state: st.state ?? null, status_name: st.name ?? null,
        completed: st.completed ?? null, venue,
        content_hash: await sha256hex(JSON.stringify({ n: ev.name, s: st.name, d: ev.date })),
        updated_at: new Date().toISOString(), meta: ev,
      });
    }
    if (rows.length) {
      const { error } = await db.from("espn_racing_events").upsert(rows, { onConflict: "series,espn_event_id" });
      if (error) { errors++; log.push(`events ${series} upsert: ${error.message}`); } else total += rows.length;
    }
    log.push(`events ${series} (${slug}): ${rows.length} races`);
    await sleep(120);
  }
  return { total, errors };
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const season = new Date().getUTCFullYear();
  let scope = "all";
  try { const body = await req.json(); if (body?.scope) scope = String(body.scope); } catch { /* no body */ }
  const log: string[] = [];
  let total = 0, errors = 0;
  if (scope === "standings" || scope === "all") {
    const r = await collectStandings(db, season, log); total += r.total; errors += r.errors;
  }
  if (scope === "events" || scope === "all") {
    const r = await collectEvents(db, season, log); total += r.total; errors += r.errors;
  }
  return new Response(JSON.stringify({ scope, total, errors, log }, null, 2), { headers: { "content-type": "application/json" } });
});
