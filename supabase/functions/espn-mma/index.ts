// Supabase Edge Function: espn-mma
//
// UFC fight cards: scoreboard -> event ids -> fightcenter -> espn_mma_events.
// Source: site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard (event ids),
// site.web.api.espn.com/apis/common/v3/sports/mma/ufc/fightcenter/{id} (cards).
// Auth: x-cron-secret (requireCronSecret). Deploy with verify_jwt=false.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function get(url: string) {
  const r = await fetch(url, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`ESPN ${r.status} on ${url}`);
  return r.json();
}
async function sha256hex(s: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function parseFights(fc: any): any[] {
  const cards = fc?.cards ?? {};
  const preferred = ["main", "prelims1", "prelims2", "prelims", "early"];
  const groupKeys = [...preferred.filter((k) => cards[k]), ...Object.keys(cards).filter((k) => !preferred.includes(k))];
  const fighter = (x: any) => x && { name: x.athlete?.displayName ?? x.athlete?.fullName ?? null, id: x.athlete?.id ? String(x.athlete.id) : null, record: x.displayRecord ?? null, winner: x.winner ?? null };
  const fights: any[] = [];
  for (const gk of groupKeys) {
    const g = cards[gk];
    for (const c of (g?.competitions ?? [])) {
      const fr = (c?.competitors ?? []).slice().sort((a: any, b: any) => (a.order ?? 0) - (b.order ?? 0)).map(fighter).filter(Boolean);
      if (!fr.length) continue;
      fights.push({
        segment: g?.displayName ?? gk,
        weight_class: c?.type?.text ?? null,
        status: c?.status?.type?.shortDetail ?? c?.status?.type?.description ?? null,
        result: c?.status?.result?.shortDisplayName ?? c?.status?.result?.description ?? null,
        fighters: fr,
      });
    }
  }
  return fights;
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const log: string[] = [];
  let total = 0, errors = 0;
  let board: any;
  try { board = await get("https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"); }
  catch (e) { return new Response(JSON.stringify({ error: `scoreboard: ${(e as Error).message}` }), { status: 502 }); }
  const events = (board?.events ?? []) as any[];
  log.push(`scoreboard: ${events.length} events`);
  for (const ev of events) {
    const eid = String(ev.id);
    const comp = ev.competitions?.[0] ?? {};
    let fc: any = null;
    try { fc = await get(`https://site.web.api.espn.com/apis/common/v3/sports/mma/ufc/fightcenter/${eid}`); }
    catch (e) { log.push(`fc ${eid} FAIL: ${(e as Error).message}`); }
    const fights = fc ? parseFights(fc) : [];
    const row = {
      espn_event_id: eid,
      name: ev.name ?? ev.shortName ?? fc?.event?.name ?? null,
      event_date: ev.date ? new Date(ev.date).toISOString() : (fc?.event?.date ? new Date(fc.event.date).toISOString() : null),
      venue: comp.venue?.fullName ?? fc?.venue?.fullName ?? null,
      league: "UFC",
      status: comp.status?.type?.shortDetail ?? comp.status?.type?.description ?? null,
      fights, fight_count: fights.length,
      content_hash: await sha256hex(JSON.stringify(fights)),
      updated_at: new Date().toISOString(), meta: {},
    };
    const { error } = await db.from("espn_mma_events").upsert([row], { onConflict: "espn_event_id" });
    if (error) { errors++; log.push(`upsert ${eid}: ${error.message}`); } else total++;
    await sleep(120);
  }
  return new Response(JSON.stringify({ total, errors, log }, null, 2), { headers: { "content-type": "application/json" } });
});
