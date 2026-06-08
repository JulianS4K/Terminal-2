// seatdata-poll
//
// AUTOPOLL (twice daily 11:00/20:00 ET, scheduled by cron seatdata_poll_twice_daily):
// for due events (next-25 owned + top-40 of the sg_market_chart "TOP 50 — SG
// SELLING, WE'RE NOT IN"), map to SeatData (events/search) and fill/refresh sold
// comps (salesdata.get). Selection + upcoming-only + staleness live in SQL
// (seatdata_due_events). aq_event_map.sd_event_id is synced by resolve_aq_seatdata_link.
//
// Spend is hard-capped at daily_cap PAID pulls/day (default 75), counted across both
// runs from the log via seatdata_autopoll_paid_today(). Per run: <= limit searches
// (events_search is 6/min, so 429s are retried) and <= max_paid fills, to stay inside
// the edge-fn time budget; the daily cap is the real ceiling.
//
// GET /functions/v1/seatdata-poll?limit=8&max_paid=30&daily_cap=75&min_score=55&dry_run=false
// Body-gated via requireCronSecret per PROJECT_BIBLE §1 rule #7.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

// Inlined from ../_shared/cron-auth.ts (kept self-contained for single-fn deploy).
// Fails CLOSED if CRON_SECRET is unset; constant-time compare.
function requireCronSecret(req: Request): Response | null {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected) return new Response("server misconfigured: CRON_SECRET unset", { status: 500 });
  const provided = req.headers.get("x-cron-secret") ?? "";
  let mismatch = provided.length ^ expected.length;
  const n = Math.max(provided.length, expected.length);
  for (let i = 0; i < n; i++) mismatch |= (provided.charCodeAt(i) || 0) ^ (expected.charCodeAt(i) || 0);
  if (mismatch !== 0) return new Response("unauthorized", { status: 401 });
  return null;
}

const BASE = "https://seatdata.io/api";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const slug = (s: string) => (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
const cleanVenue = (s: string) => slug((s ?? "").replace(/\s*-\s*[A-Za-z .]{2,20}$/, ""));

function venueDateScore(cand: any, ourVenue: string, ourDate: string): number {
  let s = 0;
  const cv = cleanVenue(cand.venue_name ?? ""), ov = cleanVenue(ourVenue);
  if (cv && ov && cv === ov) s += 60;
  else if (cv && ov && (cv.startsWith(ov) || ov.startsWith(cv))) s += 35;
  if (String(cand.event_date) === ourDate) s += 30;
  return s;
}

async function sha256_32(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  let hex = ""; for (const b of new Uint8Array(buf)) hex += b.toString(16).padStart(2, "0");
  return hex.slice(0, 32);
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  // key: prefer the function secret, else Vault (service_role can read get_app_secret)
  let KEY = Deno.env.get("SEATDATA_API_KEY") ?? "";
  if (!KEY) {
    const { data: vkey } = await sb.rpc("get_app_secret", { p_name: "SEATDATA_API_KEY" });
    KEY = typeof vkey === "string" ? vkey : "";
  }
  if (!KEY) {
    return new Response(JSON.stringify({ ok: false, error: "missing SEATDATA_API_KEY (env + vault)" }),
      { status: 500, headers: { "content-type": "application/json" } });
  }
  const sdHeaders = { "Authorization": `Bearer ${KEY}`, "User-Agent": "Terminal-2/seatdata-poll" };

  const url = new URL(req.url);
  const searchCap = Math.max(0, Math.min(40, Number(url.searchParams.get("limit") ?? "8")));
  const maxPaid   = Math.max(0, Math.min(75, Number(url.searchParams.get("max_paid") ?? "30")));
  const dailyCap  = Math.max(0, Math.min(200, Number(url.searchParams.get("daily_cap") ?? "75")));
  const minScore  = Number(url.searchParams.get("min_score") ?? "55");
  const dryRun    = url.searchParams.get("dry_run") === "true";

  const { data: paidToday } = await sb.rpc("seatdata_autopoll_paid_today");
  let paidRemaining = Math.min(maxPaid, Math.max(0, dailyCap - (paidToday ?? 0)));

  const { data: due, error: dueErr } = await sb.rpc("seatdata_due_events", { p_limit: 200 });
  if (dueErr) {
    return new Response(JSON.stringify({ ok: false, error: dueErr.message }),
      { status: 500, headers: { "content-type": "application/json" } });
  }

  async function sdSearch(params: URLSearchParams): Promise<any[]> {
    let backoff = 2000;
    for (let i = 0; i < 4; i++) {
      const r = await fetch(`${BASE}/v1/events/search?${params}`, { headers: sdHeaders });
      if (r.status === 429) { await sleep(backoff); backoff = Math.min(30000, backoff * 2); continue; }
      if (r.status !== 200) return [];
      return (await r.json())?.data ?? [];
    }
    return [];
  }

  let mapped = 0, refreshed = 0, noResults = 0, errored = 0, paid = 0, salesRows = 0, searches = 0;

  for (const ev of (due ?? [])) {
    if (paidRemaining <= 0 && searches >= searchCap) break;
    let sdId: number | null = ev.sd_event_id ?? null;
    const wasMapped = sdId != null;

    if (!sdId) {
      if (searches >= searchCap) continue;
      searches++;
      const qVenue = (ev.venue_name ?? "").replace(/\s*-\s*[A-Za-z .]{2,20}$/, "");
      let cands: any[] = [];
      try {
        cands = await sdSearch(new URLSearchParams({ venue_name: qVenue, event_date: ev.event_date, limit: "50" }));
        if (cands.length === 0 && ev.venue_city) {
          const p2 = new URLSearchParams({ venue_city: ev.venue_city, event_date: ev.event_date, limit: "50" });
          if (ev.venue_state) p2.set("venue_state", ev.venue_state);
          cands = await sdSearch(p2);
        }
      } catch (e) {
        errored++;
        await sb.from("seatdata_search_attempts").upsert(
          { tevo_event_id: ev.tevo_event_id, attempted_at: new Date().toISOString(), result: "error", meta: { msg: String(e).slice(0, 200) } },
          { onConflict: "tevo_event_id" });
        continue;
      }
      let best: any = null, bestScore = -1;
      for (const c of cands) { const sc = venueDateScore(c, ev.venue_name, ev.event_date); if (sc > bestScore) { bestScore = sc; best = c; } }
      if (!best || bestScore < minScore) {
        noResults++;
        await sb.from("seatdata_search_attempts").upsert(
          { tevo_event_id: ev.tevo_event_id, attempted_at: new Date().toISOString(),
            result: best ? "low_score" : "no_results", meta: { best_score: bestScore, best_sd: best?.event_id, n_cand: cands.length } },
          { onConflict: "tevo_event_id" });
        continue;
      }
      if (dryRun) { mapped++; continue; }
      sdId = best.event_id;
      await sb.from("seatdata_event_xref").upsert(
        { tevo_event_id: ev.tevo_event_id, sd_event_id: sdId, sd_tm_event_id: best.tm_event_id ?? null,
          sd_std_event_id: best.std_event_id ?? null, sd_std_venue_id: best.std_venue_id ?? null,
          match_method: "auto_search", match_confidence: Math.min(1, bestScore / 90), matched_at: new Date().toISOString() },
        { onConflict: "tevo_event_id" });
      await sb.from("seatdata_search_attempts").upsert(
        { tevo_event_id: ev.tevo_event_id, attempted_at: new Date().toISOString(), result: "matched", sd_event_id: sdId, meta: { score: bestScore } },
        { onConflict: "tevo_event_id" });
      mapped++;
    }

    if (dryRun || sdId == null || paidRemaining <= 0) continue;
    const { data: budget } = await sb.rpc("seatdata_check_budget", { p_endpoint: "paid" });
    if (!budget?.allowed) continue;
    try {
      const sr = await fetch(`${BASE}/v0.3/salesdata/get?event_id=${sdId}`, { headers: sdHeaders });
      paid++; paidRemaining--;
      const body = sr.status === 200 ? await sr.json() : null;
      const rows = Array.isArray(body) ? body : [];
      const out: any[] = [];
      for (const s of rows) {
        const saleTs = typeof s.timestamp === "number" ? new Date(s.timestamp * 1000).toISOString() : (s.timestamp ?? null);
        const ch = await sha256_32([saleTs, s.quantity, s.price, s.zone, s.section, s.row].map((x: any) => x == null ? "" : String(x)).join("|"));
        out.push({ tevo_event_id: ev.tevo_event_id, sd_event_id: sdId, sale_timestamp: saleTs,
          quantity: s.quantity, price: s.price, zone: s.zone, section: s.section, row: s.row, content_hash: ch });
      }
      const charged = out.length > 0;
      if (out.length) {
        await sb.from("seatdata_sales_snapshots").upsert(out, { onConflict: "tevo_event_id,content_hash", ignoreDuplicates: true });
        salesRows += out.length;
      }
      await sb.from("seatdata_event_xref")
        .update({ last_paid_pull_at: new Date().toISOString(), last_refresh_ts: new Date().toISOString() })
        .eq("tevo_event_id", ev.tevo_event_id);
      await sb.rpc("seatdata_increment_budget", { p_endpoint: "v0.3/salesdata/get", p_was_charged: charged });
      await sb.from("seatdata_pull_log").insert({ endpoint: "v0.3/salesdata/get", tevo_event_id: ev.tevo_event_id,
        sd_event_id: sdId, was_charged: charged, http_status: sr.status, rows_returned: out.length, error_message: null, request_meta: { via: "seatdata-poll" } });
      if (wasMapped) refreshed++;
    } catch (e) {
      await sb.from("seatdata_pull_log").insert({ endpoint: "v0.3/salesdata/get", tevo_event_id: ev.tevo_event_id,
        sd_event_id: sdId, was_charged: false, http_status: 0, rows_returned: 0, error_message: String(e).slice(0, 300), request_meta: { via: "seatdata-poll" } });
    }
  }

  if (!dryRun && mapped > 0) { await sb.rpc("resolve_aq_seatdata_link"); }

  return new Response(JSON.stringify({ ok: true, considered: (due ?? []).length,
    mapped, refreshed, no_results: noResults, errored, paid_pulls: paid, sales_rows: salesRows,
    searches, paid_today_before: paidToday ?? 0, daily_cap: dailyCap, dry_run: dryRun }),
    { headers: { "content-type": "application/json" } });
});
