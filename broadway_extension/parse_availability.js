// parse_availability.js  —  JS port of BroadwayClient.parse_availability()
// (broadway_client.py). Loaded by the service worker via importScripts, so it
// defines globals on `self`. Pure: no network, no chrome.* calls.
//
// Input: the availability POST response — either the full wrapper
//   {status, messages, data:{event_id, event_status, tickets:[…], score}}
// or the inner `data` dict. Output: a normalized snapshot with snake_case
// TicketBlock rows, matching the Python dataclasses.

"use strict";

function _numOrNull(v) {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : parseFloat(String(v).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(n) ? n : null;
}

function _intOrNull(v) {
  if (v === null || v === undefined || v === "") return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

// One data.tickets[] row (PascalCase) -> normalized TicketBlock.
function ticketFromRow(r) {
  const seats = Array.isArray(r.seatsStr) ? r.seatsStr.map(String) : [];
  const price = _numOrNull(r.TicketPrice) || 0.0;
  const fee = _numOrNull(r.ServiceFee) || 0.0;
  return {
    section_name: String(r.SectionName || ""),
    area_name: String(r.AreaName || ""),
    row_name: String(r.RowName || ""),
    ticket_type: String(r.TicketTypeName || ""),
    price: price,
    fee: fee,
    all_in: price + fee,
    original_price: _numOrNull(r.OriginalTicketPrice),
    quantity: parseInt(r.Quantity, 10) || 0,
    price_id: _intOrNull(r.PriceId),
    section_id: _intOrNull(r.SectionId),
    area_id: _intOrNull(r.AreaId),
    quality: _intOrNull(r.Quality),
    is_ga: Boolean(r.IsGA),
    can_split: Boolean(r.CanSplitBlock),
    price_name: r.PriceName || null,
    ticket_block_id: (r.TicketBlockId !== undefined ? r.TicketBlockId : null),
    seats: seats,
  };
}

// Returns {ok:true, snapshot} or {ok:false, reason} — does NOT throw, so the
// service worker can quietly skip non-availability payloads (e.g. a bootstrap
// JSON without data.tickets).
function parseAvailability(obj, opts) {
  opts = opts || {};
  if (!obj || typeof obj !== "object") {
    return { ok: false, reason: "not an object" };
  }
  const wrapperStatus = ("status" in obj) ? obj.status : null;
  const messages = Array.isArray(obj.messages) ? obj.messages.map(String) : [];
  const data = (obj.data && typeof obj.data === "object") ? obj.data : obj;
  if (!("tickets" in data)) {
    return { ok: false, reason: "no data.tickets[]" };
  }
  const rows = Array.isArray(data.tickets) ? data.tickets : [];
  const tickets = rows.filter((r) => r && typeof r === "object").map(ticketFromRow);
  const allIn = tickets.map((t) => t.all_in);
  const snapshot = {
    event_id: parseInt(data.event_id, 10) || 0,
    event_status: (data.event_status !== undefined ? data.event_status : null),
    requested_quantity: (opts.requestedQuantity != null ? opts.requestedQuantity : null),
    score: _numOrNull(data.score),
    status: wrapperStatus,
    messages: messages,
    captured_at_utc: opts.capturedAt || new Date().toISOString(),
    source_url: opts.sourceUrl || null,
    tickets: tickets,
    // convenience aggregates
    ticket_count: tickets.length,
    price_min: allIn.length ? Math.min.apply(null, allIn) : null,
    price_max: allIn.length ? Math.max.apply(null, allIn) : null,
    sections: tickets.reduce((acc, t) => {
      if (t.section_name && acc.indexOf(t.section_name) === -1) acc.push(t.section_name);
      return acc;
    }, []),
  };
  return { ok: true, snapshot };
}

// Expose for importScripts (classic SW global) and for any module context.
if (typeof self !== "undefined") {
  self.parseAvailability = parseAvailability;
  self.ticketFromRow = ticketFromRow;
}
