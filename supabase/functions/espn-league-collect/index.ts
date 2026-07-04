// Supabase Edge Function: espn-league-collect
//
// League-level ESPN data that is NOT team/event/roster-scoped (those live in
// espn-collect / espn-rosters). Daily cadence — slow-moving aggregate pages.
//
// Routes (via ?scope= query param):
//   ?scope=transactions  -> league roster-move ledger (append-only, deduped)
//   [attendance, stats scopes added in later slices]
//
// Source endpoints (verified live 2026-07-04 from Supabase pg_net):
//   transactions: site.api.espn.com/apis/site/v2/sports/{sport}/{league}/transactions
//     -> { season, transactions: [{ date, description, team{ id, abbreviation,
//        displayName } }] }
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

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const url = new URL(req.url);
  const scope = url.searchParams.get("scope") ?? "transactions";
  const valid = ["transactions"];
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
