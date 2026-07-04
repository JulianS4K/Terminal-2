// Supabase Edge Function: espn-racing
//
// Driver championship standings for F1 + NASCAR Cup/Xfinity/Truck ->
// espn_racing_standings (current-snapshot bulk upsert).
//
// Source: site.api.espn.com/apis/v2/sports/racing/{slug}/standings (verified
// live 2026-07-04). children[].standings.entries[].{athlete, stats[]}.
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

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const season = new Date().getUTCFullYear();
  const log: string[] = [];
  let total = 0, errors = 0;
  for (const [series, slug] of Object.entries(SERIES)) {
    let data: any;
    try { data = await get(`https://site.api.espn.com/apis/v2/sports/racing/${slug}/standings`); }
    catch (e) { errors++; log.push(`${series} FAIL: ${(e as Error).message}`); continue; }
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
      if (error) { errors++; log.push(`${series} upsert: ${error.message}`); } else total += rows.length;
    }
    log.push(`${series} (${slug}): ${rows.length} drivers`);
    await sleep(120);
  }
  return new Response(JSON.stringify({ total, errors, log }, null, 2), { headers: { "content-type": "application/json" } });
});
