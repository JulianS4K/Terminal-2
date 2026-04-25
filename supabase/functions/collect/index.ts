// Supabase Edge Function: evo collector
//
// Designed to be called ONCE PER WATCHLIST ENTRY, not once for the whole list.
// Query params:
//   ?watchlist_id=123   -> process only that row's events (preferred, for pg_cron)
//   no param            -> process the entire watchlist in one invocation
//                          (fine for tiny lists; will hit 150s ceiling past ~40 events)
//
// Env vars (via `supabase secrets set`):
//   TEVO_TOKEN, TEVO_SECRET, CRON_SECRET
// Provided automatically:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API_HOST = "api.ticketevolution.com";
const API_BASE = `https://${API_HOST}`;

async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

type ParamValue = string | number | boolean | null | undefined;
type Params = Record<string, ParamValue>;

function canonicalQuery(params: Params): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(params)) {
    if (v === null || v === undefined || v === "") continue;
    const val = typeof v === "boolean" ? (v ? "true" : "false") : String(v);
    pairs.push([k, val]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
}

class EvoClient {
  constructor(private token: string, private secret: string) {}

  private async get(path: string, params: Params = {}): Promise<any> {
    const query = canonicalQuery(params);
    const stringToSign = `GET ${API_HOST}${path}?${query}`;
    const signature = await hmacSha256Base64(this.secret, stringToSign);
    const url = `${API_BASE}${path}?${query}`;
    const resp = await fetch(url, {
      headers: {
        "X-Token": this.token,
        "X-Signature": signature,
        "Accept": "application/vnd.ticketevolution.api+json; version=9",
      },
    });
    if (!resp.ok) {
      const body = await resp.text();
      throw new Error(`${resp.status} ${resp.statusText} on ${path} — ${body}`);
    }
    return resp.json();
  }

  async searchEventsAll(params: Params): Promise<any[]> {
    const out: any[] = [];
    for (let page = 1; page <= 50; page++) {
      const resp = await this.get("/v9/events", { per_page: 100, page, ...params });
      const events: any[] = resp.events ?? [];
      if (events.length === 0) break;
      out.push(...events);
      if (out.length >= (resp.total_entries ?? 0)) break;
    }
    return out;
  }

  async getEventStats(eventId: number): Promise<any> {
    return this.get(`/v9/events/${eventId}/stats`);
  }
}

function primaryPerformer(ev: any): { id: number | null; name: string | null } {
  const perf = (ev.performances ?? []).find((p: any) => p.primary);
  return { id: perf?.performer?.id ?? null, name: perf?.performer?.name ?? null };
}

function allPerformerIds(ev: any): number[] {
  return (ev.performances ?? [])
    .map((p: any) => p.performer?.id)
    .filter((x: any) => typeof x === "number");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function withRetry<R>(fn: () => Promise<R>, maxAttempts = 4): Promise<R> {
  let lastErr: Error | null = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err as Error;
      const is429 = /\b429\b/.test(lastErr.message);
      if (!is429 || attempt === maxAttempts) throw lastErr;
      await sleep(500 * Math.pow(3, attempt - 1));
    }
  }
  throw lastErr;
}

async function mapPool<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
  perItemDelayMs = 0,
): Promise<{ results: (R | null)[]; errors: Array<{ item: T; err: Error }> }> {
  const results: (R | null)[] = new Array(items.length).fill(null);
  const errors: Array<{ item: T; err: Error }> = [];
  let nextIdx = 0;

  async function worker() {
    while (true) {
      const i = nextIdx++;
      if (i >= items.length) return;
      try {
        results[i] = await fn(items[i]);
      } catch (err) {
        errors.push({ item: items[i], err: err as Error });
      }
      if (perItemDelayMs > 0) await sleep(perItemDelayMs);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return { results, errors };
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (expected && req.headers.get("x-cron-secret") !== expected) {
    return new Response("unauthorized", { status: 401 });
  }

  const token = Deno.env.get("TEVO_TOKEN");
  const secret = Deno.env.get("TEVO_SECRET");
  if (!token || !secret) return json({ error: "missing TEVO creds" }, 500);

  const evo = new EvoClient(token, secret);
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const url = new URL(req.url);
  const watchlistId = url.searchParams.get("watchlist_id");

  const startedAt = new Date().toISOString();
  const log: string[] = [];

  const { data: runRow, error: runErr } = await db
    .from("runs")
    .insert({ started_at: startedAt })
    .select()
    .single();
  if (runErr) return json({ error: "could not open run", details: runErr }, 500);
  const runId = runRow.id;

  let wlQuery = db.from("watchlist").select("*");
  if (watchlistId) wlQuery = wlQuery.eq("id", Number(watchlistId));
  const { data: watchlist, error: wlErr } = await wlQuery;

  if (wlErr) {
    await db.from("runs").update({ finished_at: new Date().toISOString(), stats_errors: 1 }).eq("id", runId);
    return json({ run_id: runId, error: "could not read watchlist", details: wlErr }, 500);
  }
  if (!watchlist || watchlist.length === 0) {
    await db.from("runs").update({
      finished_at: new Date().toISOString(), events_collected: 0, stats_errors: 0,
    }).eq("id", runId);
    return json({ run_id: runId, note: watchlistId ? `watchlist id ${watchlistId} not found` : "empty watchlist" });
  }

  log.push(`scope: ${watchlistId ? `watchlist_id=${watchlistId}` : `full watchlist (${watchlist.length} rows)`}`);

  const byEvent = new Map<number, any>();
  const sources: Array<{
    event_id: number; source_type: string; source_id: number; source_label: string | null;
  }> = [];

  for (const w of watchlist) {
    const label = w.label ?? `${w.kind} ${w.ext_id}`;
    const params: Params = { only_with_available_tickets: true };
    if (w.kind === "performer") params.performer_id = Number(w.ext_id);
    else if (w.kind === "venue") params.venue_id = Number(w.ext_id);
    else continue;
    try {
      const events = await evo.searchEventsAll(params);
      log.push(`${w.kind} ${w.ext_id} (${label}): ${events.length} events`);
      for (const ev of events) {
        byEvent.set(ev.id, ev);
        sources.push({
          event_id: ev.id, source_type: w.kind,
          source_id: Number(w.ext_id), source_label: label,
        });
      }
    } catch (e) {
      log.push(`${w.kind} ${w.ext_id} ERROR: ${(e as Error).message}`);
    }
  }

  const total = byEvent.size;
  log.push(`${total} unique events after dedup`);

  if (total === 0) {
    await db.from("runs").update({
      finished_at: new Date().toISOString(), events_collected: 0, stats_errors: 0,
    }).eq("id", runId);
    return json({ run_id: runId, log, events_collected: 0 });
  }

  const capturedAt = new Date().toISOString();
  const eventRows = [...byEvent.values()].map((ev) => {
    const pp = primaryPerformer(ev);
    return {
      id: ev.id,
      name: ev.name ?? null,
      occurs_at_local: ev.occurs_at_local ?? null,
      state: ev.state ?? null,
      venue_id: ev.venue?.id ?? null,
      venue_name: ev.venue?.name ?? null,
      venue_location: ev.venue?.location ?? null,
      primary_performer_id: pp.id,
      primary_performer_name: pp.name,
      performer_ids: allPerformerIds(ev),
      last_seen: capturedAt,
    };
  });

  {
    const { error } = await db.from("events").upsert(eventRows, { onConflict: "id" });
    if (error) log.push(`events upsert error: ${error.message}`);
  }
  {
    const { error } = await db.from("watch_sources").upsert(
      sources.map((s) => ({ ...s, first_seen: capturedAt })),
      { onConflict: "event_id,source_type,source_id", ignoreDuplicates: true },
    );
    if (error) log.push(`watch_sources upsert error: ${error.message}`);
  }

  // Phase 3: stats, paced + retry on 429.
  // TEvo allows ~5 req/sec. Concurrency 3 × 200ms pacing gives headroom.
  const eventIds = [...byEvent.keys()];
  const { results, errors } = await mapPool(
    eventIds,
    3,
    async (eid) => {
      const s = await withRetry(() => evo.getEventStats(eid));
      return { eid, s };
    },
    200,
  );

  const snapshots = results
    .filter((r): r is { eid: number; s: any } => r !== null)
    .map(({ eid, s }) => ({
      event_id: eid,
      captured_at: capturedAt,
      ticket_groups_count: s.ticket_groups_count ?? null,
      tickets_count: s.tickets_count ?? null,
      retail_price_min: s.retail_price_min ?? null,
      retail_price_avg: s.retail_price_avg ?? null,
      retail_price_max: s.retail_price_max ?? null,
      retail_price_sum: s.retail_price_sum ?? null,
      wholesale_price_avg: s.wholesale_price_avg ?? null,
      wholesale_price_sum: s.wholesale_price_sum ?? null,
    }));

  for (const err of errors.slice(0, 5)) {
    log.push(`stats FAIL event ${err.item}: ${err.err.message}`);
  }
  if (errors.length > 5) log.push(`… and ${errors.length - 5} more stats errors`);

  for (let i = 0; i < snapshots.length; i += 500) {
    const { error } = await db.from("snapshots").insert(snapshots.slice(i, i + 500));
    if (error) log.push(`snapshots insert error at ${i}: ${error.message}`);
  }

  const finishedAt = new Date().toISOString();
  await db.from("runs").update({
    finished_at: finishedAt,
    events_collected: total,
    stats_errors: errors.length,
  }).eq("id", runId);

  return json({
    run_id: runId,
    watchlist_id: watchlistId ? Number(watchlistId) : null,
    events_collected: total,
    snapshots_written: snapshots.length,
    errors: errors.length,
    started_at: startedAt,
    finished_at: finishedAt,
    log,
  });
});