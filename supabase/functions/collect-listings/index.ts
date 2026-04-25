// Supabase Edge Function: collect-listings
//
// Pulls broker-portal ticket_groups per event (via /v9/ticket_groups), inserts
// into listings_snapshots, and computes event_metrics + section_metrics from
// the raw data. /v9/ticket_groups returns the same inventory as /v9/listings
// but exposes office/brokerage info, which we use to flag S4K-owned rows.
//
// Owned flag: a row is_owned when office.brokerage.id == S4K_BROKERAGE_ID (1768).
// Settings table can override via key 's4k_brokerage_id'.
//
// Ancillary detection: primary signal is TEvo's `type` field ('event' vs 'parking').
// Regex backstop catches hospitality/lounge items that come back as type=event.
//
// Query params:
//   ?window=0-24h | 1-7d | 7-30d | 30-60d | 60d+
//   ?watchlist_id=X
//   (no params)   -> process the entire watchlist

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API_HOST = "api.ticketevolution.com";
const API_BASE = `https://${API_HOST}`;
const DEFAULT_S4K_BROKERAGE_ID = 1768;

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
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
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

  /**
   * /v9/ticket_groups returns broker-portal ticket groups for an event.
   * Same inventory as /v9/listings, but with office + brokerage + owned fields.
   * No pagination params allowed; one call per event returns everything.
   */
  async getTicketGroups(eventId: number): Promise<any[]> {
    const resp = await this.get("/v9/ticket_groups", { event_id: eventId });
    return resp.ticket_groups ?? [];
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function withRetry<R>(fn: () => Promise<R>, maxAttempts = 4): Promise<R> {
  let lastErr: Error | null = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try { return await fn(); }
    catch (err) {
      lastErr = err as Error;
      if (!/\b429\b/.test(lastErr.message) || attempt === maxAttempts) throw lastErr;
      await sleep(500 * Math.pow(3, attempt - 1));
    }
  }
  throw lastErr;
}

async function mapPool<T, R>(
  items: T[], limit: number,
  fn: (item: T) => Promise<R>, perItemDelayMs = 0,
): Promise<{ results: (R | null)[]; errors: Array<{ item: T; err: Error }> }> {
  const results: (R | null)[] = new Array(items.length).fill(null);
  const errors: Array<{ item: T; err: Error }> = [];
  let nextIdx = 0;

  async function worker() {
    while (true) {
      const i = nextIdx++;
      if (i >= items.length) return;
      try { results[i] = await fn(items[i]); }
      catch (err) { errors.push({ item: items[i], err: err as Error }); }
      if (perItemDelayMs > 0) await sleep(perItemDelayMs);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return { results, errors };
}

function primaryPerformer(ev: any): { id: number | null; name: string | null } {
  const perf = (ev.performances ?? []).find((p: any) => p.primary);
  return { id: perf?.performer?.id ?? null, name: perf?.performer?.name ?? null };
}

function allPerformerIds(ev: any): number[] {
  return (ev.performances ?? []).map((p: any) => p.performer?.id).filter((x: any) => typeof x === "number");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status, headers: { "Content-Type": "application/json" },
  });
}

const ANCILLARY_SECTION_PATTERNS = [
  /\bvip lounge\b/i,
  /\bhospitality\b/i,
  /\bpremium lounge\b/i,
  /\bclub lounge\b/i,
  /\bsuite\b/i,
  /\bmeet.{0,4}greet\b/i,
];

function isAncillary(group: any): boolean {
  if (group.type && group.type !== "event") return true;
  const section = group.section ?? "";
  if (ANCILLARY_SECTION_PATTERNS.some((re) => re.test(section))) return true;
  return false;
}

function percentile(sortedNumbers: number[], p: number): number | null {
  if (sortedNumbers.length === 0) return null;
  const idx = (sortedNumbers.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sortedNumbers[lo];
  return sortedNumbers[lo] * (hi - idx) + sortedNumbers[hi] * (idx - lo);
}

function round2(n: number | null): number | null {
  if (n === null || !isFinite(n)) return null;
  return Math.round(n * 100) / 100;
}

function round4(n: number | null): number | null {
  if (n === null || !isFinite(n)) return null;
  return Math.round(n * 10000) / 10000;
}

interface ListingRow {
  event_id: number;
  captured_at: string;
  tevo_ticket_group_id: number;
  section: string | null;
  row: string | null;
  quantity: number;
  retail_price: number | null;
  wholesale_price: number | null;
  format: string | null;
  splits: number[] | null;
  wheelchair: boolean;
  instant_delivery: boolean;
  eticket: boolean;
  type: string | null;
  is_ancillary: boolean;
  office_id: number | null;
  office_name: string | null;
  brokerage_id: number | null;
  brokerage_name: string | null;
  is_owned: boolean;
}

function buildListingRows(
  eventId: number,
  capturedAt: string,
  groups: any[],
  s4kBrokerageId: number,
): ListingRow[] {
  return groups.map((g: any) => {
    const officeId = g.office?.id ?? null;
    const officeName = g.office?.name ?? null;
    const brokerageId = g.office?.brokerage?.id ?? null;
    const brokerageName = g.office?.brokerage?.name ?? null;
    return {
      event_id: eventId,
      captured_at: capturedAt,
      tevo_ticket_group_id: g.id,
      section: g.section ?? null,
      row: g.row ?? null,
      quantity: g.available_quantity ?? 0,
      retail_price: g.retail_price != null ? Number(g.retail_price) : null,
      wholesale_price: g.wholesale_price != null ? Number(g.wholesale_price) : null,
      format: g.format ?? null,
      splits: Array.isArray(g.splits) ? g.splits : null,
      wheelchair: !!g.wheelchair,
      instant_delivery: !!g.instant_delivery,
      eticket: !!g.eticket,
      type: g.type ?? null,
      is_ancillary: isAncillary(g),
      office_id: officeId,
      office_name: officeName,
      brokerage_id: brokerageId,
      brokerage_name: brokerageName,
      is_owned: brokerageId === s4kBrokerageId,
    };
  });
}

function computeEventMetrics(rows: ListingRow[], eventId: number, capturedAt: string) {
  const seats = rows.filter((r) => !r.is_ancillary);
  const ancillary = rows.filter((r) => r.is_ancillary);
  const ownedSeats = seats.filter((r) => r.is_owned);

  const retailPrices: number[] = [];
  const wholesalePrices: number[] = [];
  for (const r of seats) {
    if (r.retail_price != null) {
      for (let i = 0; i < (r.quantity || 0); i++) retailPrices.push(r.retail_price);
    }
    if (r.wholesale_price != null) {
      for (let i = 0; i < (r.quantity || 0); i++) wholesalePrices.push(r.wholesale_price);
    }
  }
  retailPrices.sort((a, b) => a - b);
  wholesalePrices.sort((a, b) => a - b);

  const ownedRetail: number[] = [];
  for (const r of ownedSeats) {
    if (r.retail_price != null) {
      for (let i = 0; i < (r.quantity || 0); i++) ownedRetail.push(r.retail_price);
    }
  }
  ownedRetail.sort((a, b) => a - b);

  const ticketsCount = seats.reduce((s, r) => s + (r.quantity || 0), 0);
  const groupsCount = seats.length;
  const sectionsSet = new Set(seats.map((r) => r.section).filter((s): s is string => !!s));
  const sectionsCount = sectionsSet.size;

  const groupSizes = seats.map((r) => r.quantity || 0).filter((q) => q > 0).sort((a, b) => a - b);
  const medianGroupSize = groupSizes.length ? percentile(groupSizes, 0.5) : null;

  const pairs = seats
    .filter((r) => (r.quantity || 0) >= 2 && r.retail_price != null)
    .map((r) => r.retail_price as number);
  const getinPrice = pairs.length ? Math.min(...pairs) : null;

  const perSection = new Map<string, number>();
  for (const r of seats) {
    if (!r.section) continue;
    perSection.set(r.section, (perSection.get(r.section) || 0) + (r.quantity || 0));
  }
  const sortedSectionSizes = [...perSection.values()].sort((a, b) => b - a);
  const top5 = sortedSectionSizes.slice(0, 5).reduce((s, n) => s + n, 0);
  const top5Concentration = ticketsCount > 0 ? top5 / ticketsCount : null;

  const retailMin    = percentile(retailPrices, 0);
  const retailP25    = percentile(retailPrices, 0.25);
  const retailMedian = percentile(retailPrices, 0.5);
  const retailMean   = retailPrices.length ? retailPrices.reduce((s, n) => s + n, 0) / retailPrices.length : null;
  const retailP75    = percentile(retailPrices, 0.75);
  const retailP90    = percentile(retailPrices, 0.9);
  const retailMax    = percentile(retailPrices, 1);

  const wholesaleP25 = percentile(wholesalePrices, 0.25);
  const bidAskProxy = retailP25 && retailP25 > 0 && wholesaleP25 != null
    ? (retailP25 - wholesaleP25) / retailP25
    : null;

  const priceDispersion = retailP25 && retailP25 > 0 && retailP75 != null
    ? retailP75 / retailP25
    : null;
  const tailPremium = retailMedian && retailMedian > 0 && retailP90 != null
    ? retailP90 / retailMedian
    : null;

  const ownedTicketsCount = ownedSeats.reduce((s, r) => s + (r.quantity || 0), 0);
  const ownedGroupsCount = ownedSeats.length;
  const ownedShare = ticketsCount > 0 ? ownedTicketsCount / ticketsCount : null;
  const ownedMedianRetail = percentile(ownedRetail, 0.5);

  return {
    event_id: eventId,
    captured_at: capturedAt,
    tickets_count: ticketsCount,
    groups_count: groupsCount,
    sections_count: sectionsCount,
    median_group_size: round2(medianGroupSize),
    ancillary_groups: ancillary.length,
    ancillary_tickets: ancillary.reduce((s, r) => s + (r.quantity || 0), 0),
    retail_min: round2(retailMin),
    retail_p25: round2(retailP25),
    retail_median: round2(retailMedian),
    retail_mean: round2(retailMean),
    retail_p75: round2(retailP75),
    retail_p90: round2(retailP90),
    retail_max: round2(retailMax),
    retail_sum: round2(retailPrices.reduce((s, n) => s + n, 0)),
    wholesale_min: round2(percentile(wholesalePrices, 0)),
    wholesale_median: round2(percentile(wholesalePrices, 0.5)),
    wholesale_mean: round2(wholesalePrices.length ? wholesalePrices.reduce((s, n) => s + n, 0) / wholesalePrices.length : null),
    wholesale_max: round2(percentile(wholesalePrices, 1)),
    getin_price: round2(getinPrice),
    top5_concentration: round2(top5Concentration),
    bid_ask_proxy: round2(bidAskProxy),
    price_dispersion: round4(priceDispersion),
    tail_premium: round4(tailPremium),
    owned_groups_count: ownedGroupsCount,
    owned_tickets_count: ownedTicketsCount,
    owned_share: round4(ownedShare),
    owned_median_retail: round2(ownedMedianRetail),
  };
}

function computeSectionMetrics(rows: ListingRow[], eventId: number, capturedAt: string) {
  const bySection = new Map<string, ListingRow[]>();
  for (const r of rows) {
    if (!r.section) continue;
    if (!bySection.has(r.section)) bySection.set(r.section, []);
    bySection.get(r.section)!.push(r);
  }

  const out: any[] = [];
  for (const [section, items] of bySection.entries()) {
    const prices: number[] = [];
    for (const r of items) {
      if (r.retail_price == null) continue;
      for (let i = 0; i < (r.quantity || 0); i++) prices.push(r.retail_price);
    }
    prices.sort((a, b) => a - b);
    const tickets = items.reduce((s, r) => s + (r.quantity || 0), 0);
    out.push({
      event_id: eventId,
      captured_at: capturedAt,
      section,
      is_ancillary: items[0]?.is_ancillary ?? false,
      tickets_count: tickets,
      groups_count: items.length,
      retail_min: round2(percentile(prices, 0)),
      retail_median: round2(percentile(prices, 0.5)),
      retail_mean: round2(prices.length ? prices.reduce((s, n) => s + n, 0) / prices.length : null),
      retail_max: round2(percentile(prices, 1)),
    });
  }
  return out;
}

function parseWindow(w: string | null): { minHours: number; maxHours: number | null } | null {
  if (!w) return null;
  const table: Record<string, { minHours: number; maxHours: number | null }> = {
    "0-24h":   { minHours: 0,    maxHours: 24 },
    "1-7d":    { minHours: 24,   maxHours: 7 * 24 },
    "7-30d":   { minHours: 7*24, maxHours: 30 * 24 },
    "30-60d":  { minHours: 30*24, maxHours: 60 * 24 },
    "60d+":    { minHours: 60*24, maxHours: null },
  };
  return table[w] ?? null;
}

function eventInWindow(ev: any, window: { minHours: number; maxHours: number | null }): boolean {
  if (!ev.occurs_at_local) return false;
  const eventTime = new Date(ev.occurs_at_local).getTime();
  if (isNaN(eventTime)) return false;
  const now = Date.now();
  const hoursUntil = (eventTime - now) / (1000 * 60 * 60);
  if (hoursUntil < window.minHours) return false;
  if (window.maxHours !== null && hoursUntil >= window.maxHours) return false;
  return true;
}

async function resolveTevoCreds(db: any): Promise<{ token: string; secret: string }> {
  try {
    const { data } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
    const byKey = Object.fromEntries((data ?? []).map((r: any) => [r.key, r.value]));
    if (byKey.tevo_token && byKey.tevo_secret) return { token: byKey.tevo_token, secret: byKey.tevo_secret };
  } catch (_) {}
  const t = Deno.env.get("TEVO_TOKEN");
  const s = Deno.env.get("TEVO_SECRET");
  if (!t || !s) throw new Error("TEvo creds not found in settings table or env");
  return { token: t, secret: s };
}

async function resolveS4kBrokerageId(db: any): Promise<number> {
  try {
    const { data } = await db.from("settings").select("value").eq("key", "s4k_brokerage_id").maybeSingle();
    if (data?.value) {
      const n = Number(data.value);
      if (Number.isFinite(n)) return n;
    }
  } catch (_) {}
  return DEFAULT_S4K_BROKERAGE_ID;
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (expected && req.headers.get("x-cron-secret") !== expected) {
    return new Response("unauthorized", { status: 401 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let creds;
  try { creds = await resolveTevoCreds(db); }
  catch (e) { return json({ error: String((e as Error).message) }, 500); }
  const evo = new EvoClient(creds.token, creds.secret);
  const s4kBrokerageId = await resolveS4kBrokerageId(db);

  const url = new URL(req.url);
  const windowParam = url.searchParams.get("window");
  const watchlistIdParam = url.searchParams.get("watchlist_id");
  const window = parseWindow(windowParam);

  const startedAt = new Date().toISOString();
  const log: string[] = [];
  log.push(`s4k_brokerage_id=${s4kBrokerageId}`);

  const { data: runRow, error: runErr } = await db.from("runs").insert({ started_at: startedAt }).select().single();
  if (runErr) return json({ error: "could not open run", details: runErr }, 500);
  const runId = runRow.id;

  let wlQuery = db.from("watchlist").select("*");
  if (watchlistIdParam) wlQuery = wlQuery.eq("id", Number(watchlistIdParam));
  const { data: watchlist, error: wlErr } = await wlQuery;
  if (wlErr) {
    await db.from("runs").update({ finished_at: new Date().toISOString(), stats_errors: 1 }).eq("id", runId);
    return json({ run_id: runId, error: "watchlist read failed", details: wlErr }, 500);
  }
  if (!watchlist || watchlist.length === 0) {
    await db.from("runs").update({ finished_at: new Date().toISOString(), events_collected: 0, stats_errors: 0 }).eq("id", runId);
    return json({ run_id: runId, note: "empty watchlist" });
  }

  log.push(`scope: ${watchlistIdParam ? `watchlist_id=${watchlistIdParam}` : `full (${watchlist.length} rows)`}, window=${windowParam ?? "all"}`);

  const byEvent = new Map<number, any>();
  const sources: any[] = [];

  for (const w of watchlist) {
    const label = w.label ?? `${w.kind} ${w.ext_id}`;
    const params: Params = { only_with_available_tickets: true };
    if (w.kind === "performer") params.performer_id = Number(w.ext_id);
    else if (w.kind === "venue") params.venue_id = Number(w.ext_id);
    else continue;

    try {
      let events = await evo.searchEventsAll(params);
      if (window) events = events.filter((e) => eventInWindow(e, window));
      log.push(`${w.kind} ${w.ext_id} (${label}): ${events.length} events in window`);
      for (const ev of events) {
        byEvent.set(ev.id, ev);
        sources.push({
          event_id: ev.id,
          source_type: w.kind,
          source_id: Number(w.ext_id),
          source_label: label,
        });
      }
    } catch (e) {
      log.push(`${w.kind} ${w.ext_id} ERROR: ${(e as Error).message}`);
    }
  }

  const total = byEvent.size;
  log.push(`${total} unique events after dedup`);

  if (total === 0) {
    await db.from("runs").update({ finished_at: new Date().toISOString(), events_collected: 0, stats_errors: 0 }).eq("id", runId);
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

  const eventIds = [...byEvent.keys()];
  let totalListingRows = 0;
  let totalOwnedRows = 0;

  const { errors } = await mapPool(
    eventIds, 3,
    async (eid) => {
      const groups = await withRetry(() => evo.getTicketGroups(eid));
      const listingRows = buildListingRows(eid, capturedAt, groups, s4kBrokerageId);

      for (let i = 0; i < listingRows.length; i += 500) {
        const chunk = listingRows.slice(i, i + 500);
        const { error } = await db.from("listings_snapshots").insert(chunk);
        if (error) log.push(`listings insert error event ${eid} @${i}: ${error.message}`);
      }
      totalListingRows += listingRows.length;
      totalOwnedRows += listingRows.filter((r) => r.is_owned).length;

      const eMetrics = computeEventMetrics(listingRows, eid, capturedAt);
      const { error: em } = await db.from("event_metrics").upsert(eMetrics, { onConflict: "event_id,captured_at" });
      if (em) log.push(`event_metrics upsert error ${eid}: ${em.message}`);

      const secMetrics = computeSectionMetrics(listingRows, eid, capturedAt);
      if (secMetrics.length) {
        const { error: sm } = await db.from("section_metrics").upsert(secMetrics, { onConflict: "event_id,captured_at,section" });
        if (sm) log.push(`section_metrics upsert error ${eid}: ${sm.message}`);
      }

      return { eid, listings: listingRows.length };
    },
    200,
  );

  for (const err of errors.slice(0, 5)) log.push(`FAIL event ${err.item}: ${err.err.message}`);
  if (errors.length > 5) log.push(`… and ${errors.length - 5} more errors`);

  const finishedAt = new Date().toISOString();
  await db.from("runs").update({
    finished_at: finishedAt, events_collected: total, stats_errors: errors.length,
  }).eq("id", runId);

  return json({
    run_id: runId,
    window: windowParam ?? null,
    events_collected: total,
    listing_rows_written: totalListingRows,
    owned_rows_written: totalOwnedRows,
    errors: errors.length,
    started_at: startedAt,
    finished_at: finishedAt,
    log,
  });
});
