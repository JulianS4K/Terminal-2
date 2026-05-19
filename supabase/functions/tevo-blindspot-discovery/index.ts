// tevo-blindspot-discovery (v1 skeleton)
//
// Companion edge fn to:
//   - mig 20260519180000 (TEvo blindspot detector view + RPC)
//   - mig 20260519190000 (tevo_blindspot_discovery_daily cron)
//
// PURPOSE:
//   Find new TEvo events that aren't yet in our local `events` table and
//   match the blindspot detector's candidate gates (US/CA venue, 31-365d
//   out, sports-leaning). Upsert winners into `events` so they flow into
//   `latest_event_metrics` → `v_tevo_blindspot_movers` on the next
//   collect-listings cycle + metrics refresh.
//
// PATTERN mirrors sg-to-tevo-search-bridge (mig 20260516250000):
//   - HMAC-signed TEvo /v9/events calls
//   - Audit row in `tevo_blindspot_discovery_attempts` updated with results
//   - requireCronSecret() auth wrapper
//
// THIS IS A SKELETON. The TEvo /v9/events search semantics + the new-event
// filter logic need operator-side validation before production. Specifically:
//   1. TEvo /v9/events supports `office_id` + `occurs_at.gte/lte` filters
//      but the country-code filter shape is undocumented in our code
//      base — needs trial-and-error against the live API.
//   2. The "matching blindspot criteria" filter currently checks venue
//      country + date window + presence of `tickets_count` — but the
//      search response shape doesn't include `tickets_count` directly.
//      We need either a follow-up /v9/ticket_groups call per candidate
//      (expensive) OR rely on the post-upsert collect-listings cycle to
//      backfill that field, then let the detector filter it out if too low.
//
// GET /functions/v1/tevo-blindspot-discovery?attempt_id=N&limit=200&dry_run=false
//   - attempt_id: row id in tevo_blindspot_discovery_attempts to update
//   - limit:      max events to upsert per run (default 200)
//   - dry_run:    if true, scores + counts but doesn't write to `events`

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;

// US states + DC + Canadian provinces — same set as the detector view regex.
const US_STATES = new Set([
  "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA",
  "KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
  "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT",
  "VA","WA","WV","WI","WY","DC",
]);
const CA_PROVINCES = new Set([
  "AB","BC","MB","NB","NL","NS","ON","PE","QC","SK","YT","NT","NU",
]);

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

function qs(p: Record<string, unknown>): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

async function tevoSearch(token: string, secret: string, params: Record<string, unknown>) {
  const path = "/v9/events";
  const queryStr = qs(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${queryStr}`);
  const r = await fetch(`${BASE}${path}?${queryStr}`, {
    headers: {
      "X-Token": token,
      "X-Signature": sig,
      "Accept": "application/vnd.ticketevolution.api+json; version=9",
    },
  });
  if (r.status !== 200) {
    return { ok: false, status: r.status, body: (await r.text()).slice(0, 300) };
  }
  return { ok: true, body: await r.json() };
}

// Pull state code from a venue object. TEvo /v9/events embeds venue with
// `state_province` (2-letter) or `country_code`. We match against the same
// set the detector view uses.
function isUsOrCa(venue: any): boolean {
  if (!venue) return false;
  const sp = String(venue.state_province ?? venue.state ?? "").toUpperCase().trim();
  if (sp && (US_STATES.has(sp) || CA_PROVINCES.has(sp))) return true;
  // Fallback: country code if state is missing
  const cc = String(venue.country_code ?? venue.country ?? "").toUpperCase().trim();
  return cc === "US" || cc === "CA";
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const tevoToken = Deno.env.get("TEVO_TOKEN") ?? Deno.env.get("TEVO_API_TOKEN") ?? "";
  const tevoSecret = Deno.env.get("TEVO_SECRET") ?? Deno.env.get("TEVO_API_SECRET") ?? "";
  if (!tevoToken || !tevoSecret) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing TEvo creds" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const url = new URL(req.url);
  const attemptId = Number(url.searchParams.get("attempt_id") ?? "0") || null;
  const limit = Math.max(1, Math.min(500, Number(url.searchParams.get("limit") ?? "200")));
  const dryRun = url.searchParams.get("dry_run") === "true";

  // Date window — must match the detector view exactly.
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const fromDate = new Date(today.getTime() + 31 * 86400000);
  const toDate   = new Date(today.getTime() + 365 * 86400000);

  // Pull existing TEvo event IDs so we can filter to NEW only.
  const { data: existing } = await sb
    .from("events")
    .select("id")
    .gte("occurs_at_local", fromDate.toISOString().slice(0, 10))
    .lte("occurs_at_local", toDate.toISOString().slice(0, 10) + "T23:59:59");
  const existingIds = new Set((existing ?? []).map((r: any) => Number(r.id)));

  // Paginate /v9/events. TEvo caps per_page at ~100; we walk pages until
  // we've gathered enough candidates or hit a hard cap.
  const candidates: any[] = [];
  let page = 1;
  const HARD_PAGE_CAP = 10;     // 100/page × 10 pages = 1k events max per run
  while (candidates.length < limit && page <= HARD_PAGE_CAP) {
    // NOTE: per PROJECT_BIBLE §3 landmine, TEvo date filter syntax is the
    // DOTTED form `occurs_at.gte` (not underscore — 422 Invalid Parameters).
    const res = await tevoSearch(tevoToken, tevoSecret, {
      "occurs_at.gte": fromDate.toISOString(),
      "occurs_at.lte": toDate.toISOString(),
      page,
      per_page: 100,
    });
    if (!res.ok) break;
    const evs = (res.body as any).events ?? [];
    if (!evs.length) break;
    for (const e of evs) {
      if (existingIds.has(Number(e.id))) continue;     // already tracked
      if (!isUsOrCa(e.venue)) continue;                // US/CA only
      candidates.push(e);
      if (candidates.length >= limit) break;
    }
    page += 1;
  }

  // Upsert winners into `events`. Minimum fields needed for the detector to
  // pick them up once latest_event_metrics refreshes. The metadata
  // (performer assets, lifecycle) gets backfilled by subsequent matchers
  // and collectors — discovery just ensures the row exists.
  let added = 0;
  if (!dryRun && candidates.length > 0) {
    const rows = candidates.map((e: any) => ({
      id: Number(e.id),
      name: e.name ?? "",
      occurs_at_local: e.occurs_at_local ?? e.occurs_at ?? null,
      venue_id: e.venue?.id ?? null,
      venue_name: e.venue?.name ?? null,
      venue_location: [e.venue?.city, e.venue?.state_province ?? e.venue?.state]
        .filter(Boolean).join(", "),
      primary_performer_id: e.performances?.[0]?.performer?.id ?? null,
      primary_performer_name: e.performances?.[0]?.performer?.name ?? null,
    }));
    const { error, count } = await sb
      .from("events")
      .upsert(rows, { onConflict: "id", ignoreDuplicates: false, count: "exact" });
    if (error) {
      // Update audit row with the error + return.
      if (attemptId) {
        await sb.from("tevo_blindspot_discovery_attempts")
          .update({
            result: "error",
            events_found: candidates.length,
            events_added: 0,
            meta: { error: error.message, sample: candidates.slice(0, 3).map((c: any) => c.id) },
          })
          .eq("attempt_id", attemptId);
      }
      return new Response(
        JSON.stringify({ ok: false, error: error.message, candidates: candidates.length }),
        { status: 500, headers: { "content-type": "application/json" } },
      );
    }
    added = count ?? rows.length;
  }

  // Log success back to the audit row (the cron's enqueue function wrote
  // the initial row with result='enqueued'; we flip it to 'edge_fn_called'
  // here with concrete counts).
  if (attemptId) {
    await sb.from("tevo_blindspot_discovery_attempts")
      .update({
        result: "edge_fn_called",
        events_found: candidates.length,
        events_added: added,
        meta: {
          dry_run: dryRun,
          window_from: fromDate.toISOString().slice(0, 10),
          window_to: toDate.toISOString().slice(0, 10),
          sample: candidates.slice(0, 3).map((c: any) => ({
            id: c.id, name: c.name, occurs_at: c.occurs_at_local ?? c.occurs_at,
          })),
        },
      })
      .eq("attempt_id", attemptId);
  }

  return new Response(
    JSON.stringify({
      ok: true,
      events_found: candidates.length,
      events_added: added,
      dry_run: dryRun,
      attempt_id: attemptId,
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
});
