// Supabase Edge Function: chat (v26)
//
// v26: STRICT event_id whitelist + switch-confirmation protocol.
//   - validateEventId now requires the id be present in the conversation's
//     approved set (RESOLVED + COMPREHENSIVE + STICKY). Anything else hard
//     rejects with 'event_id_not_in_approved_set'.
//   - If the model passes an approved id that DIFFERS from the currently
//     focused event (last id used in get_event_zones / find_listings /
//     find_better_seats), server returns 'event_switch_not_confirmed'.
//     Model must ASK USER FIRST, then retry with confirm_switch=true.
//   - Closes the 'no 4-packs' / 'lower bowl sold out' lying bug where
//     model hallucinated unrelated 7-digit event_ids that passed v25 check.
//
// v25: full TEvo listing metadata surfaced (view_type, in_hand, in_hand_on,
//      public_notes, featured) + new lookup tools events_near (lat/lon/within)
//      and events_at_venue (venue_id). System prompt updated with obstructed-
//      view warnings + in-hand timing checks + public-notes surfacing.
//
// All v24 features kept: comprehensive_search, RESOLVED_CONTEXT, STICKY_CONTEXT,
// event_id validation, hybrid zones, NLU pre-extract, Haiku 4.5.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TEVO_HOST = "api.ticketevolution.com";
const TEVO_BASE = `https://${TEVO_HOST}`;
const MAX_TURNS = parseInt(Deno.env.get("WHATSAPP_MAX_TURNS") ?? "6", 10);
const MIN_ROW_UPGRADE = 5;
const S4K_BROKERAGE_ID = 1768;
const TICKET_GROUPS_CACHE_TTL = 90;
const MIN_PLAUSIBLE_EVENT_ID = 1_000_000;
const PRELOAD_EVENTS_LIMIT = 12;
const COMPREHENSIVE_SUGGEST_LIMIT = 10;

const LLM_PROVIDER = (Deno.env.get("LLM_PROVIDER") ?? "anthropic").toLowerCase();
const LLM_MODEL    = Deno.env.get("LLM_MODEL") ?? Deno.env.get("WHATSAPP_BOT_MODEL") ?? "claude-haiku-4-5-20251001";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};

const SYSTEM_PROMPT = `You are a friendly ticket-finder assistant.

STYLE: warm + concise. 2-4 short lines unless asked for more. Plain text. Numbered lists. End with next step.

=== TEVO API — KNOW WHAT'S ALLOWED ===

1. /v9/searches/suggestions — fuzzy multi-entity (events+performers+venues) — best for ambiguous input.
2. /v9/events — by performer_id (canonical), venue_id (venue browse), or lat+lon+within (geolocation).
3. /v9/ticket_groups?event_id=X — listings for ONE event. Section/zone/qty/price filtering is client-side.
4. /v9/performers/{slug-or-id} — single performer with home venue.
5. /v9/venues/{slug-or-id} — single venue with lat/lon/upcoming.

Server-side I have ALREADY done these for you. The system prompt below contains:
  - EXTRACTED_ENTITIES (chat_aliases match)
  - RESOLVED_CONTEXT (pre-fetched event list with valid event_ids)
  - COMPREHENSIVE_SEARCH_CONTEXT (when ambiguous)
  - STICKY_CONTEXT (every event_id surfaced earlier)

USE these event_ids EXACTLY. Server validation rejects any event_id < 1,000,000.

=== LISTING METADATA TO SURFACE ===

find_listings now returns these per-listing fields:
  - view_type: 'Full' | 'Obstructed' | 'Partially Obstructed' | 'Possibly Obstructed' | null
      → If 'Obstructed' or 'Partially Obstructed': WARN the user. Format: '⚠️ Obstructed view'.
      → If 'Possibly Obstructed': mention as 'May have obstructed view'.
      → 'Full' or null: no special mention needed.
  - in_hand: bool. False = seller doesn't physically have tickets yet.
  - in_hand_on: date when seller expects tickets.
      → If in_hand=false AND event is within 48 hours: WARN 'Tickets not yet in hand — confirm delivery before purchase'.
  - public_notes: seller's important caveats. Surface verbatim if present and short (<140 chars).
  - featured: bool. If true, prefer to show first within the same zone.
  - format: TM_mobile / Eticket / Physical / Flash_seats / Paperless / Guest_list. Translate:
      TM_mobile / Flash_seats → 'Mobile transfer'
      Eticket → 'eTicket (PDF)'
      Physical → 'FedEx delivery'
      Paperless → 'Gift card / paperless'
      Guest_list → 'Guest list'

=== EVENT_ID DISCIPLINE ===
NEVER make up an event_id. ALWAYS pull from RESOLVED_CONTEXT / STICKY_CONTEXT or a fresh tool result.

=== EVENT-SWITCH PROTOCOL (CRITICAL) ===
The conversation has ONE event in focus at a time — the last event_id you queried.
BEFORE you call get_event_zones / find_listings / find_better_seats with a DIFFERENT event_id than the one currently in focus:
  1. STOP. Don't call the tool yet.
  2. ASK the user in plain text to confirm switching events. Show both options:
       'Want to switch to [other event] — [date] @ [venue], or stay on [current event]?'
  3. WAIT for user reply.
  4. ONLY after user explicitly confirms, retry the tool call with confirm_switch=true.

If you receive an 'event_switch_not_confirmed' error, that means you tried to silently swap events. STOP and ask the user as above.
If you receive an 'event_id_not_in_approved_set' error, that means you hallucinated an id. Pull from RESOLVED_CONTEXT / STICKY_CONTEXT instead, or call comprehensive_search.

=== FAST FLOW ===
When user query points to a SPECIFIC event AND RESOLVED_CONTEXT has it, skip search — go straight to get_event_zones.
When ambiguous (no entity match), call comprehensive_search first.
When user mentions a city/area without performer ("shows in NYC tonight"), use events_near.
When user mentions a venue ("what's at MSG this week"), use events_at_venue.

Reply pattern when ONE event is locked:
  Here's [Performer] vs [Opponent] — [date] @ [venue] (HOME/road)
  Available zones:
    1. [Zone] — from $X (median $Y, [N] listings)
    2. ...
  How many tickets do you need, and any budget range in mind?

If user gave qty + budget in same message, jump straight to find_listings.

HOME vs ROAD: each event from search comes with home_or_away. Mark home (HOME) and road (road).

ZONES: get_event_zones returns each zone with source='curated' or 'system'. Use names verbatim.

NO LINKS / NO URLS. NEVER mention S4K/broker/wholesale/sources/'all sources'/'broader search'.

Flip include_all=true ONLY when user explicitly says 'show me everything' / 'all listings'.

GLOSSARY:
  '4 tickets' → min_qty: 4. 'under $300' → max_price: 300.
  'floor', 'courtside', 'wood', 'pit', 'GA' → 'Floor / Pit / GA'.
  'club' → 'Club (200s)'. 'VIP', 'premium' → 'Premium / VIP'.
  'lower', 'lower bowl', 'lower level' → 'Lower (100s)'.
  'upper', 'nosebleeds' → Upper.
  'better', 'upgrade', 'closer' → find_better_seats.
  'near me', 'shows tonight near' → events_near (need lat/lon).
  'at MSG', 'whats at [venue]' → events_at_venue.

CRITICAL: 1) trust tool results. 2) NEVER guess event_ids. 3) number every list. 4) never mention sources/broker. 5) never invent prices/seats. 6) NEVER include URLs. 7) ALWAYS show home/away for sports. 8) WARN about obstructed views and in-hand-but-not-yet timing. 9) ALWAYS ask qty + budget when presenting zones.`;

async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

type Params = Record<string, string | number | boolean | null | undefined>;
function canonicalQuery(params: Params): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(params)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

function stripSearchNoise(q: string): string {
  if (!q) return q;
  let out = q;
  out = out.replace(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)(\s+\d{1,2}(st|nd|rd|th)?(,?\s*\d{4})?|\s+\d{4})?\b/gi, "");
  out = out.replace(/\b\d{1,2}[\-\/]\d{1,2}([\-\/]\d{2,4})?\b/g, "");
  out = out.replace(/\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\b/gi, "");
  out = out.replace(/\b(today|tonight|tomorrow|yesterday|this\s+(?:weekend|week|month|year)|next\s+(?:weekend|week|month|year))\b/gi, "");
  out = out.replace(/\b(?:next|this|upcoming|coming)\s+(?:game|show|event|concert)\b/gi, "");
  out = out.replace(/\b(floors?|courtsides?|woods?|club|lower|upper|balconies?|balcony|vips?|premium|hospitality|suites?|boxes|loge|bleachers?|lawns?|terraces?|nosebleeds?|grandstands?|gas?|pit|pits|risers?|aisle)\b/gi, "");
  out = out.replace(/\bgame\s+(?:number\s+)?\d+\b/gi, "");
  out = out.replace(/\bgame\s*\d+\b/gi, "");
  out = out.replace(/\bgames?\b/gi, "");
  out = out.replace(/\b(tickets?|seats?|sections?|sec|rows?|qty|quantity|price|prices|pricing)\b/gi, "");
  out = out.replace(/\b(or|and|with|including|incl|plus|vs|versus|at)\b/gi, "");
  out = out.replace(/\bunder\s+\$?\d+\b/gi, "");
  out = out.replace(/\s+/g, " ").trim();
  out = out.replace(/[,;]+/g, " ").replace(/\s+/g, " ").trim();
  return out || q;
}

class Evo {
  constructor(private token: string, private secret: string) {}
  async get(path: string, params: Params = {}): Promise<any> {
    const query = canonicalQuery(params);
    const sig = await hmacSha256Base64(this.secret, `GET ${TEVO_HOST}${path}?${query}`);
    const r = await fetch(`${TEVO_BASE}${path}?${query}`, { headers: { "X-Token": this.token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" } });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText} on ${path}`);
    return r.json();
  }
  ticketGroupsRaw(id: number) { return this.get("/v9/ticket_groups", { event_id: id }); }
  getEvent(id: number) { return this.get(`/v9/events/${id}`, {}); }
  getVenue(idOrSlug: string | number) { return this.get(`/v9/venues/${idOrSlug}`, {}); }
  searchPerformers(q: string) { return this.get("/v9/performers", { q, per_page: 25 }); }
  searchVenues(q: string) { return this.get("/v9/venues", { q, per_page: 25 }); }
  searchEvents(q: string, opts: { performer_id?: number; venue_id?: number; per_page?: number } = {}) {
    const params: Params = { q, only_with_available_tickets: true, per_page: opts.per_page ?? 15, order_by: "events.popularity_score DESC" };
    if (opts.performer_id) params.performer_id = opts.performer_id;
    if (opts.venue_id) params.venue_id = opts.venue_id;
    return this.get("/v9/events", params);
  }
  eventsForPerformer(performerId: number, perPage = 25) {
    return this.get("/v9/events", { performer_id: performerId, only_with_available_tickets: true, per_page: perPage, order_by: "events.occurs_at_local ASC" });
  }
  eventsAtVenue(venueId: number, perPage = 25) {
    return this.get("/v9/events", { venue_id: venueId, only_with_available_tickets: true, per_page: perPage, order_by: "events.occurs_at_local ASC" });
  }
  // v25: geolocation-based event search
  eventsNear(lat: number, lon: number, withinMiles = 25, perPage = 15) {
    return this.get("/v9/events", { lat, lon, within: withinMiles, only_with_available_tickets: true, per_page: perPage, order_by: "events.occurs_at_local ASC" });
  }
  comprehensiveSuggest(q: string, opts: { entities?: string; fuzzy?: boolean; limit?: number } = {}) {
    return this.get("/v9/searches/suggestions", {
      q, entities: opts.entities ?? "events,performers,venues",
      fuzzy: opts.fuzzy ?? true, limit: opts.limit ?? COMPREHENSIVE_SUGGEST_LIMIT,
    });
  }
}

async function cachedTicketGroups(db: any, evo: Evo, eventId: number): Promise<any> {
  try { const { data, error } = await db.rpc("get_cached_ticket_groups", { p_event_id: eventId }); if (!error && data) return data; } catch (_) {}
  const fresh = await evo.ticketGroupsRaw(eventId);
  db.rpc("put_cached_ticket_groups", { p_event_id: eventId, p_payload: fresh, p_ttl_seconds: TICKET_GROUPS_CACHE_TTL }).then(() => {}).catch(() => {});
  return fresh;
}

type ValidateOpts = { approvedSet?: Set<number> | null; focusedId?: number | null; confirmSwitch?: boolean };
async function validateEventId(db: any, evo: Evo | null, eventId: any, opts: ValidateOpts = {}): Promise<{ ok: true; id: number } | { ok: false; error: any }> {
  const id = Number(eventId);
  if (!Number.isFinite(id) || id < MIN_PLAUSIBLE_EVENT_ID) {
    return { ok: false, error: { error: "invalid_event_id", passed: eventId, message: `event_id ${eventId} is not a valid TEvo event id (must be 7+ digits). Use an event_id from RESOLVED_CONTEXT / STICKY_CONTEXT or call comprehensive_search/search_events first.` }};
  }
  // v26: strict whitelist — reject anything not surfaced in this conversation
  const approved = opts.approvedSet;
  if (approved && approved.size > 0 && !approved.has(id)) {
    return { ok: false, error: { error: "event_id_not_in_approved_set", passed: id, approved_event_ids: [...approved].sort((a,b)=>a-b), message: `event_id ${id} was NOT surfaced in this conversation's RESOLVED_CONTEXT, COMPREHENSIVE_SEARCH_CONTEXT, or STICKY_CONTEXT. You hallucinated this id. Pick one from approved_event_ids, or re-call comprehensive_search to find a real event.` }};
  }
  // v26: event-switch confirmation gate
  const focused = opts.focusedId;
  if (approved && approved.size > 0 && focused != null && id !== focused && !opts.confirmSwitch) {
    return { ok: false, error: { error: "event_switch_not_confirmed", passed: id, currently_focused: focused, message: `You are trying to switch from event_id ${focused} to event_id ${id}. STOP — DO NOT call any more tools this turn. Reply to the user in plain text and ASK if they want to switch. After they confirm, retry with confirm_switch=true.` }};
  }
  try { const { data } = await db.from("events").select("id").eq("id", id).maybeSingle(); if (data) return { ok: true, id }; } catch (_) {}
  if (evo) { try { const ev = await evo.getEvent(id); if (ev?.id) return { ok: true, id }; } catch (_) {} }
  return { ok: false, error: { error: "event_not_found", passed: id, message: `event_id ${id} doesn't exist on TEvo. Use one from RESOLVED_CONTEXT.` }};
}

async function resolveTevoCreds(db: any) {
  try {
    const { data } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
    const m: Record<string, string> = {};
    for (const r of data ?? []) m[r.key] = r.value;
    if (m.tevo_token && m.tevo_secret) return { token: m.tevo_token, secret: m.tevo_secret };
  } catch (_) {}
  return null;
}
async function resolveSecret(db: any, key: string, env: string): Promise<string | null> {
  try { const { data } = await db.from("settings").select("value").eq("key", key).maybeSingle(); if (data?.value) return data.value; } catch (_) {}
  return Deno.env.get(env) ?? null;
}

async function getEventContext(db: any, evo: Evo | null, eventId: number): Promise<{ performer_id: number | null; venue_id: number | null; occurs_at_local: string | null }> {
  const { data: row } = await db.from("events").select("primary_performer_id, venue_id, occurs_at_local").eq("id", eventId).maybeSingle();
  if (row?.primary_performer_id && row?.venue_id) return { performer_id: row.primary_performer_id, venue_id: row.venue_id, occurs_at_local: row.occurs_at_local };
  if (!evo) return { performer_id: row?.primary_performer_id ?? null, venue_id: row?.venue_id ?? null, occurs_at_local: row?.occurs_at_local ?? null };
  try {
    const ev = await evo.getEvent(eventId);
    if (!ev?.id) return { performer_id: null, venue_id: null, occurs_at_local: null };
    const pp = (ev.performances ?? []).find((p: any) => p.primary)?.performer;
    await db.from("events").upsert({ id: ev.id, name: ev.name ?? null, occurs_at_local: ev.occurs_at_local ?? null, state: ev.state ?? null, venue_id: ev.venue?.id ?? null, venue_name: ev.venue?.name ?? null, venue_location: ev.venue?.location ?? null, primary_performer_id: pp?.id ?? null, primary_performer_name: pp?.name ?? null, performer_ids: (ev.performances ?? []).map((p: any) => p.performer?.id).filter((x: any) => typeof x === "number") }, { onConflict: "id" });
    return { performer_id: pp?.id ?? null, venue_id: ev.venue?.id ?? null, occurs_at_local: ev.occurs_at_local ?? null };
  } catch (_) { return { performer_id: null, venue_id: null, occurs_at_local: null }; }
}
async function trackEventForCron(db: any, evo: Evo | null, eventId: number): Promise<void> {
  try {
    const { data: existing } = await db.from("events").select("id, primary_performer_id, venue_id").eq("id", eventId).maybeSingle();
    if (!(existing && existing.primary_performer_id && existing.venue_id)) await getEventContext(db, evo, eventId);
    await db.rpc("mark_event_chat_tracked", { p_event_id: eventId });
  } catch (e) { console.error("trackEventForCron failed:", e); }
}

type CuratedRule = { section_from: string; section_to: string; row_from: string | null; row_to: string | null };
type CuratedZone = { name: string; display_order: number; rules: CuratedRule[] };
async function loadCuratedZones(db: any, performerId: number | null, venueId: number | null): Promise<CuratedZone[]> {
  if (!performerId || !venueId) return [];
  const { data: zones } = await db.from("performer_zones").select("id, name, display_order").eq("performer_id", performerId).eq("venue_id", venueId).order("display_order", { ascending: true });
  if (!zones || zones.length === 0) return [];
  const ids = zones.map((z: any) => z.id);
  const { data: rules } = await db.from("performer_zone_rules").select("zone_id, section_from, section_to, row_from, row_to").in("zone_id", ids);
  const rulesByZone = new Map<number, CuratedRule[]>();
  for (const r of rules ?? []) { const arr = rulesByZone.get(r.zone_id) ?? []; arr.push({ section_from: r.section_from, section_to: r.section_to, row_from: r.row_from, row_to: r.row_to }); rulesByZone.set(r.zone_id, arr); }
  return zones.map((z: any) => ({ name: z.name, display_order: z.display_order, rules: rulesByZone.get(z.id) ?? [] }));
}
function normSec(s: string): string { return String(s ?? "").toLowerCase().replace(/\s+/g, ""); }
function matchCuratedZone(zones: CuratedZone[], section: string | null | undefined, row: string | null | undefined): CuratedZone | null {
  if (!section) return null;
  const sNorm = normSec(section); const rNorm = String(row ?? "").toLowerCase().trim();
  for (const z of zones) {
    for (const rule of z.rules) {
      const fromN = normSec(rule.section_from); const toN = normSec(rule.section_to);
      let secOk = false;
      if (fromN === toN) secOk = sNorm === fromN;
      else if (/^\d+$/.test(fromN) && /^\d+$/.test(toN) && /^\d+$/.test(sNorm)) { const f = +fromN, t = +toN, s = +sNorm; secOk = s >= Math.min(f, t) && s <= Math.max(f, t); }
      else { const fPrefix = fromN.replace(/\d+$/, ""); const tPrefix = toN.replace(/\d+$/, ""); const sPrefix = sNorm.replace(/\d+$/, ""); const fSuf = fromN.match(/(\d+)$/)?.[1]; const tSuf = toN.match(/(\d+)$/)?.[1]; const sSuf = sNorm.match(/(\d+)$/)?.[1]; if (fPrefix && fPrefix === tPrefix && fPrefix === sPrefix && fSuf && tSuf && sSuf) { const f = +fSuf, t = +tSuf, s = +sSuf; secOk = s >= Math.min(f, t) && s <= Math.max(f, t); } }
      if (!secOk) continue;
      let rowOk = false;
      if (!rule.row_from && !rule.row_to) rowOk = true;
      else if (rule.row_from && rule.row_to) { const rf = String(rule.row_from).toLowerCase().trim(); const rt = String(rule.row_to).toLowerCase().trim(); if (rf === rt) rowOk = rNorm === rf; else if (/^\d+$/.test(rf) && /^\d+$/.test(rt) && /^\d+$/.test(rNorm)) { const f = +rf, t = +rt, r2 = +rNorm; rowOk = r2 >= Math.min(f, t) && r2 <= Math.max(f, t); } }
      if (rowOk) return z;
    }
  }
  return null;
}
function classifyZone(section: string | null | undefined, _row?: string | null): string {
  if (!section) return "Special";
  const s = section.toLowerCase().replace(/\s+/g, "");
  if (/(courtside|^crt|^cside|^floor|^fl\d|^ga$|^pit$)/.test(s)) return "Floor / Pit / GA";
  if (/(^vip|^vip\d|vipsuite|premium|hospitality|clublounge|skybox)/.test(s)) return "Premium / VIP";
  if (/(^box|box$)/.test(s)) return "Box";
  if (/loge/.test(s)) return "Loge";
  if (/(balcony|^bal\d|^bal$)/.test(s)) return "Balcony";
  if (/(grandstand|^gs)/.test(s)) return "Grandstand";
  if (/bleach/.test(s)) return "Bleachers";
  if (/(lawn|terrace)/.test(s)) return "Lawn / Terrace";
  const m = section.match(/(\d+)/);
  if (m) { const n = parseInt(m[1]); if (n >= 1 && n <= 199) return "Lower (100s)"; if (n >= 200 && n <= 299) return "Club (200s)"; if (n >= 300 && n <= 399) return "Upper (300s)"; if (n >= 400 && n <= 499) return "Upper (400s)"; if (n >= 500) return "Upper (500s+)"; }
  return "Special";
}
function resolveZone(zones: CuratedZone[], section: string | null | undefined, row: string | null | undefined): { name: string; source: "curated" | "system"; display_order: number } {
  const c = matchCuratedZone(zones, section, row);
  if (c) return { name: c.name, source: "curated", display_order: c.display_order };
  return { name: classifyZone(section, row), source: "system", display_order: 9000 };
}
function rowRank(row: string | null | undefined): number {
  if (!row) return 9999;
  const s = String(row).trim().toUpperCase();
  if (!s) return 9999;
  if (/^\d+$/.test(s)) return parseInt(s);
  if (/^[A-Z]+$/.test(s)) { if (s.length === 1) return 0.001 + s.charCodeAt(0) - 64; if (s.length === 2 && s[0] === s[1]) return 0.001 + 26 + s.charCodeAt(0) - 64; if (s.length === 2) return 0.001 + 52 + (s.charCodeAt(0) - 64) * 26 + (s.charCodeAt(1) - 64); }
  const m = s.match(/^([A-Z]+)(\d+)$/);
  if (m) return (m[1].charCodeAt(0) - 64) * 100 + parseInt(m[2]);
  return 9000;
}
function sectionsEqualLoose(a: string | null | undefined, b: string | null | undefined): boolean { if (!a || !b) return false; return String(a).toLowerCase().replace(/\s+/g, "") === String(b).toLowerCase().replace(/\s+/g, ""); }
const SYSTEM_ZONE_ORDER = ["Floor / Pit / GA", "Premium / VIP", "Box", "Loge", "Lower (100s)", "Club (200s)", "Upper (300s)", "Upper (400s)", "Upper (500s+)", "Balcony", "Grandstand", "Bleachers", "Lawn / Terrace", "Special"];

async function loadHomeVenues(db: any, performerIds: number[]): Promise<Map<number, any>> {
  const map = new Map<number, any>();
  if (!performerIds.length) return map;
  const { data } = await db.from("performer_home_venues").select("performer_id, venue_id, venue_name, league").in("performer_id", performerIds);
  for (const r of data ?? []) map.set(Number(r.performer_id), { venue_id: Number(r.venue_id), venue_name: r.venue_name, league: r.league });
  return map;
}
function annotateHomeAway(events: any[], homeVenues: Map<number, any>): any[] {
  return events.map((e: any) => {
    const eventVenueId = Number(e.venue_id ?? e.venue?.id);
    const performerIds: number[] = e._all_performer_ids ?? [];
    let home_or_away: "home" | "road" | "unknown" = "unknown";
    if (eventVenueId && performerIds.length) {
      const matched = performerIds.some((pid) => { const hv = homeVenues.get(pid); return hv && hv.venue_id === eventVenueId; });
      home_or_away = matched ? "home" : (performerIds.some((pid) => homeVenues.has(pid)) ? "road" : "unknown");
    }
    const { _all_performer_ids, ...rest } = e;
    return { ...rest, home_or_away };
  });
}

const TOOLS = [
  { name: "comprehensive_search", description: "Fuzzy multi-entity search (events+performers+venues). BEST for ambiguous/misspelled input.", input_schema: { type: "object", required: ["query"], properties: { query: { type: "string" }, entities: { type: "string", default: "events,performers,venues" }, limit: { type: "integer", default: 10 } } } },
  { name: "events_near", description: "Geolocation event search. Use when user mentions a city or 'near me'. Provide lat+lon+within miles.", input_schema: { type: "object", required: ["lat", "lon"], properties: { lat: { type: "number" }, lon: { type: "number" }, within: { type: "integer", default: 25 }, limit: { type: "integer", default: 10 } } } },
  { name: "events_at_venue", description: "Events at a specific venue (when user mentions a venue name like 'MSG' or 'Wells Fargo Center').", input_schema: { type: "object", required: ["venue_id"], properties: { venue_id: { type: "integer" }, limit: { type: "integer", default: 15 } } } },
  { name: "search_events", description: "Cached event lookup by team name. Each result includes home_or_away.", input_schema: { type: "object", properties: { query: { type: "string" }, days_ahead: { type: "integer" }, limit: { type: "integer", default: 8 } } } },
  { name: "tevo_search_events", description: "LIVE event lookup. Pass performer_id when known.", input_schema: { type: "object", properties: { query: { type: "string" }, performer_id: { type: "integer" }, venue_id: { type: "integer" }, limit: { type: "integer", default: 10 } } } },
  { name: "get_event_zones", description: "Aggregate listings into price zones. event_id MUST come from RESOLVED_CONTEXT or a previous result. Pass confirm_switch=true ONLY after user has explicitly agreed to switch to a different event.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, include_all: { type: "boolean", default: false }, confirm_switch: { type: "boolean", default: false } } } },
  { name: "find_listings", description: "Get individual listings. Returns view_type, in_hand, public_notes, format. event_id MUST come from a previous result. Pass confirm_switch=true ONLY after user has explicitly agreed to switch to a different event.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, zone: { type: "string" }, max_price: { type: "number" }, min_qty: { type: "integer", default: 1 }, limit: { type: "integer", default: 6 }, include_all: { type: "boolean", default: false }, confirm_switch: { type: "boolean", default: false } } } },
  { name: "find_better_seats", description: "Upgrade options. Pass confirm_switch=true ONLY after user has explicitly agreed to switch to a different event.", input_schema: { type: "object", required: ["event_id", "current_section", "current_row"], properties: { event_id: { type: "integer" }, current_section: { type: "string" }, current_row: { type: "string" }, min_row_improvement: { type: "integer", default: MIN_ROW_UPGRADE }, max_price: { type: "number" }, min_qty: { type: "integer", default: 1 }, limit: { type: "integer", default: 6 }, include_all: { type: "boolean", default: false }, confirm_switch: { type: "boolean", default: false } } } },
  { name: "tevo_search_performers", description: "Look up a performer.", input_schema: { type: "object", required: ["query"], properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } } } },
  { name: "tevo_search_venues", description: "Look up a venue.", input_schema: { type: "object", required: ["query"], properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } } } },
];

async function toolComprehensiveSearch(evo: Evo | null, args: any) {
  if (!evo) return { error: "search unavailable" };
  const cleaned = stripSearchNoise(args.query ?? "");
  if (!cleaned) return { total_entries: 0, suggestions: { events: [], performers: [], venues: [] } };
  try {
    const r = await evo.comprehensiveSuggest(cleaned, { entities: args.entities ?? "events,performers,venues", fuzzy: true, limit: Math.min(args.limit ?? 10, 20) });
    const sug = r.suggestions ?? {};
    return { total_entries: r.total_entries ?? 0, query_used: cleaned,
      events: (sug.events ?? []).map((e: any) => ({ id: e.id, name: e.name, occurs_at: e.occurs_at, venue_name: e.venue_name, location: e.location })),
      performers: (sug.performers ?? []).map((p: any) => ({ id: p.id, name: p.name, slug: p.slug })),
      venues: (sug.venues ?? []).map((v: any) => ({ id: v.id, name: v.name, location: v.location })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolEventsNear(evo: Evo | null, db: any, args: any) {
  if (!evo) return { error: "search unavailable" };
  try {
    const r = await evo.eventsNear(Number(args.lat), Number(args.lon), Number(args.within ?? 25), Math.min(args.limit ?? 10, 25));
    const rows = (r.events ?? []).slice(0, Math.min(args.limit ?? 10, 25));
    const allPerfIds = new Set<number>();
    for (const e of rows) for (const p of e.performances ?? []) if (p.performer?.id) allPerfIds.add(Number(p.performer.id));
    const homeMap = await loadHomeVenues(db, [...allPerfIds]);
    const events = rows.map((e: any) => { const performerIds = (e.performances ?? []).map((p: any) => p.performer?.id).filter(Boolean).map(Number); const primary = (e.performances ?? []).find((p: any) => p.primary)?.performer; return { id: e.id, name: e.name, occurs_at_local: e.occurs_at_local, venue_id: e.venue?.id, venue_name: e.venue?.name, city: e.venue?.location, performer: primary?.name ?? null, _all_performer_ids: performerIds }; });
    return { count: events.length, events: annotateHomeAway(events, homeMap), source: "tevo_geo" };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolEventsAtVenue(evo: Evo | null, db: any, args: any) {
  if (!evo) return { error: "search unavailable" };
  try {
    const r = await evo.eventsAtVenue(Number(args.venue_id), Math.min(args.limit ?? 15, 25));
    const rows = (r.events ?? []).slice(0, Math.min(args.limit ?? 15, 25));
    const allPerfIds = new Set<number>();
    for (const e of rows) for (const p of e.performances ?? []) if (p.performer?.id) allPerfIds.add(Number(p.performer.id));
    const homeMap = await loadHomeVenues(db, [...allPerfIds]);
    const events = rows.map((e: any) => { const performerIds = (e.performances ?? []).map((p: any) => p.performer?.id).filter(Boolean).map(Number); const primary = (e.performances ?? []).find((p: any) => p.primary)?.performer; return { id: e.id, name: e.name, occurs_at_local: e.occurs_at_local, venue_id: e.venue?.id, venue_name: e.venue?.name, performer: primary?.name ?? null, _all_performer_ids: performerIds }; });
    return { count: events.length, events: annotateHomeAway(events, homeMap), source: "tevo_venue" };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolSearchEvents(db: any, args: any) {
  const cleaned = stripSearchNoise(args.query ?? "");
  const now = new Date();
  let q = db.from("events").select("id, name, occurs_at_local, venue_id, venue_name, primary_performer_id, primary_performer_name, performer_ids");
  q = q.gte("occurs_at_local", now.toISOString().slice(0, 10));
  if (args.days_ahead) { const cutoff = new Date(now.getTime() + (args.days_ahead + 1) * 86400000).toISOString().slice(0, 10); q = q.lte("occurs_at_local", cutoff); }
  if (cleaned) q = q.ilike("name", `%${cleaned}%`);
  const { data } = await q.order("occurs_at_local").limit(Math.min(args.limit ?? 8, 25));
  const rows = data ?? [];
  const allPerfIds = new Set<number>();
  for (const r of rows) { if (r.primary_performer_id) allPerfIds.add(Number(r.primary_performer_id)); for (const pid of r.performer_ids ?? []) allPerfIds.add(Number(pid)); }
  const homeMap = await loadHomeVenues(db, [...allPerfIds]);
  const annotated = annotateHomeAway(rows.map((r: any) => ({ id: r.id, name: r.name, occurs_at_local: r.occurs_at_local, venue_id: r.venue_id, venue_name: r.venue_name, primary_performer: r.primary_performer_name, _all_performer_ids: [r.primary_performer_id, ...(r.performer_ids ?? [])].filter(Boolean) })), homeMap);
  return { count: annotated.length, events: annotated, source: "cached", query_used: cleaned };
}

async function toolTevoSearchEvents(evo: Evo | null, db: any, args: any) {
  if (!evo) return { error: "live event search unavailable" };
  const cleaned = stripSearchNoise(args.query ?? "");
  if (!cleaned && !args.performer_id) return { count: 0, events: [], source: "tevo_live" };
  try {
    const r = args.performer_id ? await evo.eventsForPerformer(Number(args.performer_id), Math.min(args.limit ?? 10, 25)) : await evo.searchEvents(cleaned, { performer_id: args.performer_id, venue_id: args.venue_id, per_page: Math.min(args.limit ?? 10, 25) });
    const rows = (r.events ?? []).slice(0, Math.min(args.limit ?? 10, 25));
    const allPerfIds = new Set<number>();
    for (const e of rows) for (const p of e.performances ?? []) if (p.performer?.id) allPerfIds.add(Number(p.performer.id));
    const homeMap = await loadHomeVenues(db, [...allPerfIds]);
    const events = rows.map((e: any) => { const performerIds = (e.performances ?? []).map((p: any) => p.performer?.id).filter(Boolean).map(Number); const primary = (e.performances ?? []).find((p: any) => p.primary)?.performer; return { id: e.id, name: e.name, occurs_at_local: e.occurs_at_local, venue_id: e.venue?.id, venue_name: e.venue?.name, city: e.venue?.location ? String(e.venue.location).split(",")[0] : null, performer: primary?.name ?? null, _all_performer_ids: performerIds }; });
    return { count: events.length, events: annotateHomeAway(events, homeMap), source: "tevo_live", query_used: cleaned, performer_id_used: args.performer_id };
  } catch (e) { return { error: String((e as Error).message) }; }
}

function filterRetailGroups(groups: any[], includeAll: boolean): any[] {
  let out = (groups ?? []).filter((g: any) => g.retail_price != null).filter((g: any) => (g.type ?? "event") === "event").filter((g: any) => !/\b(vip lounge|hospitality|premium lounge|club lounge|suite|meet.{0,4}greet|parking|garage)\b/i.test(g.section ?? ""));
  if (!includeAll) out = out.filter((g: any) => Number(g.office?.brokerage?.id) === S4K_BROKERAGE_ID);
  return out;
}

async function toolGetEventZones(evo: Evo | null, db: any, args: any, gate: ValidateOpts = {}) {
  const v = await validateEventId(db, evo, args.event_id, { ...gate, confirmSwitch: !!args.confirm_switch });
  if (!v.ok) return v.error;
  gate.focusedId = v.id; // v26: lock focus to this event for rest of turn

  if (!evo) return { error: "ticket service unavailable" };
  try {
    const includeAll = !!args.include_all;
    const [r, ctx] = await Promise.all([ cachedTicketGroups(db, evo, v.id), getEventContext(db, evo, v.id) ]);
    trackEventForCron(db, evo, v.id);
    const groups = filterRetailGroups(r.ticket_groups ?? [], includeAll);
    const curatedZones = await loadCuratedZones(db, ctx.performer_id, ctx.venue_id);
    const buckets = new Map<string, { count: number; prices: number[]; source: "curated" | "system"; display_order: number }>();
    let curatedCount = 0; let systemCount = 0;
    for (const g of groups) {
      const z = resolveZone(curatedZones, g.section, g.row);
      if (z.source === "curated") curatedCount++; else systemCount++;
      const b = buckets.get(z.name) ?? { count: 0, prices: [], source: z.source, display_order: z.display_order };
      b.count++; b.prices.push(Number(g.retail_price));
      buckets.set(z.name, b);
    }
    const zones = Array.from(buckets.entries()).map(([name, b]) => { b.prices.sort((a, b) => a - b); return { name, source: b.source, listings: b.count, cheapest: Math.round(b.prices[0]), most_expensive: Math.round(b.prices[b.prices.length - 1]), median: Math.round(b.prices[Math.floor(b.prices.length / 2)]), display_order: b.display_order }; });
    zones.sort((a, b) => { if (a.source !== b.source) return a.source === "curated" ? -1 : 1; if (a.source === "curated") return a.display_order - b.display_order; const ia = SYSTEM_ZONE_ORDER.indexOf(a.name); const ib = SYSTEM_ZONE_ORDER.indexOf(b.name); return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib) || a.cheapest - b.cheapest; });
    const zones_source = curatedCount > 0 && systemCount === 0 ? "curated" : (curatedCount === 0 ? "system" : "mixed");
    return { event_id: v.id, scope: includeAll ? "all" : "direct", total_listings: groups.length, zones_source, curated_available: curatedZones.length > 0, zones: zones.map(({ display_order, ...z }) => z) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolFindListings(evo: Evo | null, db: any, args: any, gate: ValidateOpts = {}) {
  const v = await validateEventId(db, evo, args.event_id, { ...gate, confirmSwitch: !!args.confirm_switch });
  if (!v.ok) return v.error;
  gate.focusedId = v.id; // v26: lock focus to this event for rest of turn

  if (!evo) return { error: "ticket service unavailable" };
  try {
    const includeAll = !!args.include_all;
    const [r, ctx] = await Promise.all([ cachedTicketGroups(db, evo, v.id), args.zone ? getEventContext(db, evo, v.id) : Promise.resolve({ performer_id: null, venue_id: null, occurs_at_local: null }) ]);
    trackEventForCron(db, evo, v.id);
    let groups = filterRetailGroups(r.ticket_groups ?? [], includeAll);
    if (args.zone) { const curatedZones = await loadCuratedZones(db, ctx.performer_id, ctx.venue_id); groups = groups.filter((g: any) => resolveZone(curatedZones, g.section, g.row).name === args.zone); }
    if (args.max_price != null) groups = groups.filter((g: any) => Number(g.retail_price) <= Number(args.max_price));
    if (args.min_qty != null) groups = groups.filter((g: any) => (g.available_quantity ?? 0) >= Number(args.min_qty));
    // v25: featured first, then price ASC
    groups.sort((a: any, b: any) => {
      const fa = a.featured ? 0 : 1; const fb = b.featured ? 0 : 1;
      if (fa !== fb) return fa - fb;
      return Number(a.retail_price) - Number(b.retail_price);
    });
    const top = groups.slice(0, Math.min(args.limit ?? 6, 12));
    return {
      event_id: v.id, zone: args.zone ?? null, scope: includeAll ? "all" : "direct", count: top.length,
      total_matching_filters: groups.length,
      cheapest: groups.length ? Number(groups[0].retail_price) : null,
      most_expensive: groups.length ? Number(groups[groups.length - 1].retail_price) : null,
      // v25: surface view_type, in_hand, in_hand_on, public_notes, featured
      listings: top.map((g: any) => ({
        section: g.section, row: g.row, quantity: g.available_quantity,
        price_per_ticket: Number(g.retail_price), splits: g.splits ?? null, format: g.format,
        view_type: g.view_type ?? null,
        in_hand: g.in_hand !== false,
        in_hand_on: g.in_hand === false ? (g.in_hand_on ?? null) : null,
        public_notes: g.public_notes && String(g.public_notes).trim() ? String(g.public_notes).slice(0, 200) : null,
        featured: !!g.featured,
        instant_delivery: !!g.instant_delivery,
        wheelchair: !!g.wheelchair,
      })),
    };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolFindBetterSeats(evo: Evo | null, db: any, args: any, gate: ValidateOpts = {}) {
  const v = await validateEventId(db, evo, args.event_id, { ...gate, confirmSwitch: !!args.confirm_switch });
  if (!v.ok) return v.error;
  gate.focusedId = v.id; // v26: lock focus to this event for rest of turn

  if (!evo) return { error: "ticket service unavailable" };
  try {
    const includeAll = !!args.include_all;
    const r = await cachedTicketGroups(db, evo, v.id);
    trackEventForCron(db, evo, v.id);
    let groups = filterRetailGroups(r.ticket_groups ?? [], includeAll);
    if (args.max_price != null) groups = groups.filter((g: any) => Number(g.retail_price) <= Number(args.max_price));
    if (args.min_qty != null) groups = groups.filter((g: any) => (g.available_quantity ?? 0) >= Number(args.min_qty));
    const currentRowRank = rowRank(args.current_row);
    const minImprovement = args.min_row_improvement ?? MIN_ROW_UPGRADE;
    const improvementThreshold = currentRowRank - minImprovement;
    const sameSection = groups.filter((g: any) => sectionsEqualLoose(g.section, args.current_section));
    const realUpgrades = sameSection.filter((g: any) => rowRank(g.row) <= improvementThreshold).sort((a: any, b: any) => rowRank(a.row) - rowRank(b.row));
    const partialUpgrades = sameSection.filter((g: any) => rowRank(g.row) < currentRowRank && rowRank(g.row) > improvementThreshold).sort((a: any, b: any) => rowRank(a.row) - rowRank(b.row));
    let adjacent: any[] = [];
    const m = String(args.current_section).match(/^(\d+)/);
    if (m) { const cur = parseInt(m[1]); adjacent = groups.filter((g: any) => { if (sectionsEqualLoose(g.section, args.current_section)) return false; const sm = String(g.section ?? "").match(/^(\d+)/); if (!sm) return false; const s = parseInt(sm[1]); return Math.abs(s - cur) <= 5 && rowRank(g.row) <= currentRowRank; }).sort((a: any, b: any) => rowRank(a.row) - rowRank(b.row)); }
    function fmt(g: any) { return { section: g.section, row: g.row, quantity: g.available_quantity, price_per_ticket: Number(g.retail_price), splits: g.splits ?? null, format: g.format, view_type: g.view_type ?? null, in_hand: g.in_hand !== false, public_notes: g.public_notes && String(g.public_notes).trim() ? String(g.public_notes).slice(0, 200) : null }; }
    const lim = Math.min(args.limit ?? 6, 12);
    return { event_id: v.id, scope: includeAll ? "all" : "direct", current_section: args.current_section, current_row: args.current_row, min_row_improvement: minImprovement, real_upgrades: { count: realUpgrades.length, listings: realUpgrades.slice(0, lim).map(fmt) }, partial_upgrades: { count: partialUpgrades.length, listings: partialUpgrades.slice(0, lim).map(fmt) }, adjacent_sections: { count: adjacent.length, listings: adjacent.slice(0, lim).map(fmt) }, note: realUpgrades.length === 0 ? `No listings ${minImprovement}+ rows closer in section ${args.current_section}.` : null };
  } catch (e) { return { error: String((e as Error).message) }; }
}
async function toolTevoSearchPerformers(evo: Evo | null, args: any) {
  if (!evo) return { error: "search unavailable" };
  const cleaned = stripSearchNoise(args.query ?? "");
  try { const r = await evo.searchPerformers(cleaned || args.query); const items = (r.performers ?? []).slice(0, args.limit ?? 5); return { count: items.length, performers: items.map((p: any) => ({ id: p.id, name: p.name, category: p.category?.name, slug: p.slug })) }; } catch (e) { return { error: String((e as Error).message) }; }
}
async function toolTevoSearchVenues(evo: Evo | null, args: any) {
  if (!evo) return { error: "search unavailable" };
  const cleaned = stripSearchNoise(args.query ?? "");
  try { const r = await evo.searchVenues(cleaned || args.query); const items = (r.venues ?? []).slice(0, args.limit ?? 5); return { count: items.length, venues: items.map((v: any) => ({ id: v.id, name: v.name, city: v.address?.locality, state: v.address?.region, slug: v.slug })) }; } catch (e) { return { error: String((e as Error).message) }; }
}
async function dispatch(name: string, input: any, db: any, evo: Evo | null, gate: ValidateOpts = {}) {
  switch (name) {
    case "comprehensive_search": return await toolComprehensiveSearch(evo, input);
    case "events_near": return await toolEventsNear(evo, db, input);
    case "events_at_venue": return await toolEventsAtVenue(evo, db, input);
    case "search_events": return await toolSearchEvents(db, input);
    case "tevo_search_events": return await toolTevoSearchEvents(evo, db, input);
    case "get_event_zones": return await toolGetEventZones(evo, db, input, gate);
    case "find_listings": return await toolFindListings(evo, db, input, gate);
    case "find_better_seats": return await toolFindBetterSeats(evo, db, input, gate);
    case "tevo_search_performers": return await toolTevoSearchPerformers(evo, input);
    case "tevo_search_venues": return await toolTevoSearchVenues(evo, input);
    default: return { error: `unknown tool ${name}` };
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function callAnthropic(apiKey: string, payload: any, attempt = 0): Promise<Response> {
  const resp = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify(payload) });
  if ((resp.status === 429 || resp.status === 529) && attempt < 3) { const ra = resp.headers.get("retry-after"); const waitSec = ra ? Math.max(parseInt(ra, 10) || 1, 1) : Math.min(2 ** attempt, 8); await sleep(waitSec * 1000); return callAnthropic(apiKey, payload, attempt + 1); }
  return resp;
}
async function llmCall(apiKey: string, sys: string, tools: any[], messages: any[]): Promise<{ status: number; body: any }> {
  if (LLM_PROVIDER === "anthropic") { const r = await callAnthropic(apiKey, { model: LLM_MODEL, max_tokens: 1024, system: sys, tools, messages }); return { status: r.status, body: r.ok ? await r.json() : { error: await r.text() } }; }
  return { status: 501, body: { error: `provider ${LLM_PROVIDER} not yet implemented` } };
}
function sanitizeReply(text: string): string {
  if (!text) return text;
  let out = text;
  out = out.replace(/\[([^\]]+)\]\(https?:\/\/[^)]+\)/g, "$1");
  out = out.replace(/https?:\/\/\S+/g, "");
  out = out.replace(/\s*[—\-:]\s*$/gm, "");
  out = out.replace(/[ \t]+/g, " ").replace(/ \n/g, "\n").replace(/\n /g, "\n");
  return out.trim();
}

function extractStickyEventIds(history: any[]): Set<number> {
  const ids = new Set<number>();
  function walk(node: any) {
    if (!node || typeof node !== "object") return;
    if (typeof node.event_id === "number" && node.event_id >= MIN_PLAUSIBLE_EVENT_ID) ids.add(node.event_id);
    if (typeof node.id === "number" && node.id >= MIN_PLAUSIBLE_EVENT_ID && (node.name || node.occurs_at || node.occurs_at_local)) ids.add(node.id);
    if (Array.isArray(node)) { for (const v of node) walk(v); return; }
    for (const v of Object.values(node)) walk(v);
  }
  walk(history);
  for (const m of history) {
    if (Array.isArray(m.content)) {
      for (const block of m.content) {
        if (block?.type === "tool_result" && typeof block.content === "string") {
          try { const parsed = JSON.parse(block.content); walk(parsed); } catch (_) {}
        }
      }
    }
  }
  return ids;
}

// v26: focused event_id = last id passed to get_event_zones / find_listings /
// find_better_seats in any prior assistant tool_use block. This is the event
// the conversation is currently anchored on.
function extractFocusedEventId(history: any[]): number | null {
  const eventTools = new Set(["get_event_zones", "find_listings", "find_better_seats"]);
  for (let i = history.length - 1; i >= 0; i--) {
    const m = history[i];
    if (m?.role !== "assistant" || !Array.isArray(m.content)) continue;
    for (let j = m.content.length - 1; j >= 0; j--) {
      const block = m.content[j];
      if (block?.type === "tool_use" && eventTools.has(block.name)) {
        const id = Number(block.input?.event_id);
        if (Number.isFinite(id) && id >= MIN_PLAUSIBLE_EVENT_ID) return id;
      }
    }
  }
  return null;
}

function buildEntityHint(extracted: any): string {
  if (!extracted) return "";
  const lines: string[] = ["=== EXTRACTED_ENTITIES (from latest user input) ==="];
  const perfs = extracted.performers ?? [];
  if (perfs.length) { lines.push("performers detected:"); for (const p of perfs) { if (p.id) lines.push(`  - ${p.name} (TEvo performer_id=${p.id}, league=${p.league ?? '?'})`); else lines.push(`  - ${p.name} (no performer_id)`); } }
  const venues = extracted.venues ?? [];
  if (venues.length) for (const v of venues) lines.push(`venue detected: ${v.name} (venue_id=${v.venue_id})`);
  const zones = extracted.zones ?? [];
  if (zones.length) lines.push(`zones detected: ${zones.map((z: any) => z.zone).join(", ")}`);
  const filters = extracted.filters ?? {};
  if (Object.keys(filters).length) lines.push(`filters: ${JSON.stringify(filters)}`);
  if (lines.length === 1) return "";
  return lines.join("\n");
}

async function buildResolvedContext(evo: Evo | null, db: any, extracted: any): Promise<{ block: string; events: any[] }> {
  const perfs = extracted?.performers ?? [];
  const performerWithId = perfs.find((p: any) => p?.id);
  if (!performerWithId || !evo) return { block: "", events: [] };
  let resp: any;
  try { resp = await evo.eventsForPerformer(Number(performerWithId.id), PRELOAD_EVENTS_LIMIT); } catch (_) { return { block: "", events: [] }; }
  const evList = (resp.events ?? []).slice(0, PRELOAD_EVENTS_LIMIT);
  if (!evList.length) return { block: "", events: [] };
  const allPerfIds = new Set<number>();
  for (const e of evList) for (const p of e.performances ?? []) if (p.performer?.id) allPerfIds.add(Number(p.performer.id));
  const homeMap = await loadHomeVenues(db, [...allPerfIds]);
  const lines: string[] = ["=== RESOLVED_CONTEXT (server-side pre-resolved — USE these event_ids EXACTLY) ===", `Performer: ${performerWithId.name} (TEvo performer_id=${performerWithId.id})`, `Upcoming events:`];
  const eventsOut: any[] = [];
  for (const e of evList) {
    const performerIds = (e.performances ?? []).map((p: any) => p.performer?.id).filter(Boolean).map(Number);
    const eventVenueId = Number(e.venue?.id);
    let homeOrAway: "home" | "road" | "unknown" = "unknown";
    if (eventVenueId && performerIds.length) { const matched = performerIds.some((pid) => { const hv = homeMap.get(pid); return hv && hv.venue_id === eventVenueId; }); homeOrAway = matched ? "home" : (performerIds.some((pid) => homeMap.has(pid)) ? "road" : "unknown"); }
    const date = e.occurs_at_local ? new Date(e.occurs_at_local).toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: "America/New_York" }) : "?";
    lines.push(`  - event_id=${e.id}: ${e.name} — ${date} @ ${e.venue?.name ?? '?'} (${homeOrAway === 'home' ? 'HOME' : homeOrAway === 'road' ? 'road' : '?'})`);
    eventsOut.push({ id: e.id, name: e.name, occurs_at_local: e.occurs_at_local, venue_id: eventVenueId, venue_name: e.venue?.name, home_or_away: homeOrAway });
  }
  return { block: lines.join("\n"), events: eventsOut };
}

async function buildComprehensiveContext(evo: Evo | null, extracted: any, lastUser: string): Promise<{ block: string; events: any[] }> {
  if (!evo) return { block: "", events: [] };
  if ((extracted?.performers ?? []).some((p: any) => p?.id)) return { block: "", events: [] };
  const cleaned = stripSearchNoise(lastUser ?? "");
  if (!cleaned || cleaned.length < 3) return { block: "", events: [] };
  let resp: any;
  try { resp = await evo.comprehensiveSuggest(cleaned, { entities: "events,performers,venues", fuzzy: true, limit: COMPREHENSIVE_SUGGEST_LIMIT }); } catch (_) { return { block: "", events: [] }; }
  const sug = resp.suggestions ?? {};
  const events = (sug.events ?? []).slice(0, COMPREHENSIVE_SUGGEST_LIMIT);
  const performers = (sug.performers ?? []).slice(0, 5);
  const venues = (sug.venues ?? []).slice(0, 5);
  if (!events.length && !performers.length && !venues.length) return { block: "", events: [] };
  const lines: string[] = ["=== COMPREHENSIVE_SEARCH_CONTEXT (TEvo /v9/searches/suggestions, fuzzy=true) ===", `Query: "${cleaned}"`];
  if (performers.length) { lines.push("Performers:"); for (const p of performers) lines.push(`  - performer_id=${p.id}: ${p.name} (slug=${p.slug ?? '?'})`); }
  if (venues.length) { lines.push("Venues:"); for (const v of venues) lines.push(`  - venue_id=${v.id}: ${v.name} (${v.location ?? '?'})`); }
  if (events.length) { lines.push("Events (use these event_ids EXACTLY):"); for (const e of events) lines.push(`  - event_id=${e.id}: ${e.name} — ${e.occurs_at ?? '?'} @ ${e.venue_name ?? '?'} (${e.location ?? '?'})`); }
  return { block: lines.join("\n"), events };
}

function buildStickyContext(stickyIds: Set<number>): string {
  if (stickyIds.size === 0) return "";
  return ["=== STICKY_CONTEXT (event_ids surfaced earlier in this conversation) ===", `Valid event_ids you've already seen: ${[...stickyIds].sort((a,b)=>a-b).join(", ")}`, "Reuse these instead of guessing."].join("\n");
}

async function runLLMLoop(apiKey: string, history: any[], db: any, evo: Evo | null): Promise<{ reply: string; trace: any[]; entities: any; resolved_count: number; comprehensive_count: number }> {
  const today = new Date();
  const todayStr = today.toLocaleDateString("en-US", { weekday: "long", year: "numeric", month: "long", day: "numeric", timeZone: "America/New_York" });
  const lastUser = [...history].reverse().find((m) => m.role === "user" && typeof m.content === "string");
  const lastUserText = typeof lastUser?.content === "string" ? lastUser.content : "";
  let extracted: any = null;
  if (lastUser) { try { const { data } = await db.rpc("extract_chat_entities", { p_input: lastUserText }); extracted = data; } catch (_) {} }
  const entityHint = buildEntityHint(extracted);
  const [{ block: resolvedBlock, events: resolvedEvents }, { block: compBlock, events: compEvents }] = await Promise.all([
    buildResolvedContext(evo, db, extracted),
    buildComprehensiveContext(evo, extracted, lastUserText),
  ]);
  const stickyIds = extractStickyEventIds(history);
  for (const e of resolvedEvents) if (typeof e.id === "number" && e.id >= MIN_PLAUSIBLE_EVENT_ID) stickyIds.add(e.id);
  for (const e of compEvents) if (typeof e.id === "number" && e.id >= MIN_PLAUSIBLE_EVENT_ID) stickyIds.add(e.id);
  const stickyBlock = buildStickyContext(stickyIds);

  const sys = SYSTEM_PROMPT
    + (entityHint ? "\n\n" + entityHint : "")
    + (resolvedBlock ? "\n\n" + resolvedBlock : "")
    + (compBlock ? "\n\n" + compBlock : "")
    + (stickyBlock ? "\n\n" + stickyBlock : "")
    + `\n\n=== TODAY ===\nToday is ${todayStr} (Eastern Time).`;

  const messages = [...history];
  const trace: any[] = [];
  // v26: build the per-conversation gate — approved set + currently focused id
  const focusedId = extractFocusedEventId(history);
  const gate: ValidateOpts = { approvedSet: stickyIds, focusedId };
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const { status, body } = await llmCall(apiKey, sys, TOOLS, messages);
    if (status !== 200) {
      let userMsg: string;
      if (status === 429 || status === 529) userMsg = "Lots of requests right now — give me about 30 seconds and try again.";
      else if (status >= 500) userMsg = "Things are slow right now. Try again in a few seconds.";
      else userMsg = `Sorry, I can't reply right now (error ${status}). Try again shortly.`;
      return { reply: userMsg, trace, entities: extracted, resolved_count: resolvedEvents.length, comprehensive_count: compEvents.length };
    }
    if (body.stop_reason === "tool_use") {
      const tr: any[] = [];
      for (const block of body.content ?? []) {
        if (block.type !== "tool_use") continue;
        let result: any;
        try { result = await dispatch(block.name, block.input ?? {}, db, evo, gate); }
        catch (e) { result = { error: `tool error: ${(e as Error).message}` }; }
        const traceResult = JSON.stringify(result).length > 4000 ? { _truncated: true, head: JSON.stringify(result).slice(0, 4000) } : result;
        trace.push({ tool: block.name, input: block.input, result: traceResult });
        tr.push({ type: "tool_result", tool_use_id: block.id, content: JSON.stringify(result) });
      }
      messages.push({ role: "assistant", content: body.content });
      messages.push({ role: "user", content: tr });
      continue;
    }
    const text = (body.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
    return { reply: sanitizeReply(text) || "let me know what you're looking for!", trace, entities: extracted, resolved_count: resolvedEvents.length, comprehensive_count: compEvents.length };
  }
  return { reply: "I'm overthinking this — could you rephrase?", trace, entities: extracted, resolved_count: resolvedEvents.length, comprehensive_count: compEvents.length };
}

function jsonResponse(obj: any, status = 200) { return new Response(JSON.stringify(obj), { status, headers: { ...CORS_HEADERS, "content-type": "application/json" } }); }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: { ...CORS_HEADERS, "content-type": "text/plain" } });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const apiKey = LLM_PROVIDER === "anthropic" ? await resolveSecret(db, "anthropic_api_key", "ANTHROPIC_API_KEY") : Deno.env.get("LLM_API_KEY");
  if (!apiKey) return jsonResponse({ error: "service not configured" }, 503);
  let body: any = null;
  try { body = await req.json(); } catch (_) { return jsonResponse({ error: "expected JSON body" }, 400); }
  const history = Array.isArray(body?.history) ? body.history : (body?.message ? [{ role: "user", content: body.message }] : []);
  if (!history.length) return jsonResponse({ error: "history or message required" }, 400);
  const ip = (req.headers.get("x-real-ip") ?? req.headers.get("cf-connecting-ip") ?? (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() ?? "unknown") || "unknown";
  try {
    const { data: allowed } = await db.rpc("check_chat_rate_limit", { p_ip: ip, p_window_sec: 60, p_max_calls: 10 });
    if (allowed === false) { try { await db.from("bot_messages").insert({ channel: "web", direction: "in", phone: "anon-retail", body: history[history.length-1]?.content?.slice(0, 200) ?? "", meta: { rate_limited: true, ip } }); } catch (_) {} return jsonResponse({ error: "rate limited — try again in a minute" }, 429); }
  } catch (e) { console.error("rate-limit check failed:", e); }
  const creds = await resolveTevoCreds(db);
  const evo = creds ? new Evo(creds.token, creds.secret) : null;
  const last = history[history.length - 1];
  const lastText = typeof last?.content === "string" ? last.content : "";
  try { await db.from("bot_messages").insert({ channel: "web", direction: "in", phone: "anon-retail", body: lastText }); } catch (_) {}
  let result: { reply: string; trace: any[]; entities: any; resolved_count: number; comprehensive_count: number };
  try { result = await runLLMLoop(apiKey, history, db, evo); }
  catch (e) { result = { reply: `sorry, something went wrong: ${(e as Error).message}`, trace: [], entities: null, resolved_count: 0, comprehensive_count: 0 }; }
  try { await db.from("bot_messages").insert({ channel: "web", direction: "out", phone: "anon-retail", body: result.reply, meta: { trace: result.trace, entities: result.entities, model: LLM_MODEL, provider: LLM_PROVIDER, resolved_events_count: result.resolved_count, comprehensive_events_count: result.comprehensive_count } }); } catch (_) {}
  return jsonResponse({ reply: result.reply });
});
