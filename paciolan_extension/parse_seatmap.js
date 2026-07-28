// parse_seatmap.js  —  JS twin of paciolan_client.py parse/group.
//
// Turns a rendered eVenue (Paciolan) seat map (a DOM subtree, or `document`)
// into the normalized capture shape our ingest expects:
//   { sections:[{level,section_label,pct_available,disabled}],
//     seats:[{data_seat_key,level,section_label,row_label,seat_number,seat_no,
//             price,seat_type,is_ga,available}] }
// Kept in sync with paciolan_client.parse_seatmap_html() / classify_seat_type().
//
// RULE 2: this only READS the DOM the page already rendered. It originates no
// request to any evenue.net host.
"use strict";

const STANDARD = "standard", PREMIUM = "premium", ACCESSIBLE = "accessible", GA = "ga";

function splitLevelSection(token) {
  // "U:16U" -> ["U","16U"]; "BN:20A" -> ["BN","20A"]; "WC:WC11L" -> ["WC","WC11L"]
  const i = (token || "").indexOf(":");
  return i >= 0 ? [token.slice(0, i), token.slice(i + 1)] : ["", token];
}

function parseSeatKey(key) {
  // "U:16U:19:1" -> {level, section_label, row_label, seat_number}
  const p = (key || "").split(":");
  if (p.length < 4) return null;
  return { level: p[0], section_label: p[1], row_label: p[2],
           seat_number: p.slice(3).join(":") };
}

function seatNo(seatNumber) {
  return /^[0-9]+$/.test(seatNumber || "") ? parseInt(seatNumber, 10) : null;
}

function classifySeatType(level, icon, isGa) {
  if (isGa) return GA;
  if ((level || "").toUpperCase() === "WC") return ACCESSIBLE;
  return icon === "crown" ? PREMIUM : STANDARD;
}

function priceFromAria(aria) {
  const m = /\$([0-9]+(?:\.[0-9]{1,2})?)/.exec(aria || "");
  return m ? parseFloat(m[1]) : null;
}

function parseSeatmap(root) {
  root = root || document;
  const sections = [];
  root.querySelectorAll("[data-level-section]").forEach((el) => {
    const [level, section] = splitLevelSection(el.getAttribute("data-level-section"));
    const pct = el.getAttribute("percent");
    sections.push({
      level,
      section_label: section,
      pct_available: pct != null && pct !== "" ? parseFloat(pct) : null,
      disabled: el.hasAttribute("disabled") ||
                el.getAttribute("aria-disabled") === "true",
    });
  });

  const seats = [];
  root.querySelectorAll("[data-seat-key]").forEach((el) => {
    const parsed = parseSeatKey(el.getAttribute("data-seat-key"));
    if (!parsed) return;
    const aria = el.getAttribute("aria-label") || "";
    const availAttr = el.getAttribute("data-available");
    const available = availAttr != null
      ? availAttr.toLowerCase() === "true"
      : !/unavailable/i.test(aria);
    // Crown (premium) seats render as <svg>, standard as <circle>.
    const icon = el.tagName.toLowerCase() === "svg" ? "crown" : "circle";
    const isGa = /ga/i.test(parsed.section_label || "") &&
                 seatNo(parsed.seat_number) === null;
    seats.push({
      data_seat_key: el.getAttribute("data-seat-key"),
      level: parsed.level,
      section_label: parsed.section_label,
      row_label: parsed.row_label,
      seat_number: parsed.seat_number,
      seat_no: seatNo(parsed.seat_number),
      price: priceFromAria(aria),
      seat_type: classifySeatType(parsed.level, icon, isGa),
      is_ga: isGa,
      available,
    });
  });
  return { sections, seats };
}

// Consecutive-seat grouping (parity with v_paciolan_seat_groups) — used for the
// popup's local "N together" preview; the server view is the source of truth.
function groupConsecutive(seats) {
  // Field-by-field comparator (NOT array `<`, which stringifies and would sort
  // seat "10" before "6"). Numbers compare numerically, strings lexically —
  // parity with the Python tuple sort and the SQL view's `order by seat_no`.
  const cmp = (a, b) => {
    const fields = [
      [a.level || "", b.level || ""],
      [a.section_label || "", b.section_label || ""],
      [a.row_label || "", b.row_label || ""],
      [a.seat_type || "", b.seat_type || ""],
      [a.price == null ? -1 : a.price, b.price == null ? -1 : b.price],
      [a.seat_no == null ? 1e12 : a.seat_no, b.seat_no == null ? 1e12 : b.seat_no],
      [a.seat_number || "", b.seat_number || ""],
    ];
    for (const [x, y] of fields) { if (x < y) return -1; if (x > y) return 1; }
    return 0;
  };
  const avail = seats.filter((s) => s.available).slice().sort(cmp);
  const blocks = [];
  let cur = null, prev = null;
  for (const s of avail) {
    const key = [s.level, s.section_label, s.row_label, s.seat_type, s.price].join("|");
    const contiguous = cur && cur._key === key && s.seat_no != null &&
                       prev != null && s.seat_no === prev + 1;
    if (!contiguous) {
      cur = { _key: key, level: s.level, section_label: s.section_label,
              row_label: s.row_label, seat_type: s.seat_type, price: s.price,
              quantity: 0, seat_from: s.seat_no, seat_to: s.seat_no,
              seat_numbers: [] };
      blocks.push(cur);
    }
    cur.quantity += 1;
    cur.seat_numbers.push(s.seat_number);
    if (s.seat_no != null) cur.seat_to = s.seat_no;
    prev = s.seat_no;
  }
  blocks.forEach((b) => { delete b._key; b.seat_numbers = b.seat_numbers.join(","); });
  return blocks;
}

// --- event metadata (for AQ mapping to EVO/SeatGeek/StubHub) ---------------
// Twin of paciolan_client.parse_event_meta(): schema.org Event JSON-LD, then
// the page title. Teams split from the matchup string. The matcher
// (paciolan_aq_match) needs name + date + venue to resolve the aq_short_event_id.
function splitTeams(name) {
  const s = name || "";
  const seps = [[" at ", false], [" @ ", false],
                [" vs. ", true], [" vs ", true], [" v ", true]];
  for (const [sep, homeFirst] of seps) {
    const i = s.indexOf(sep);
    if (i >= 0) {
      const left = s.slice(0, i).trim(), right = s.slice(i + sep.length).trim();
      return homeFirst ? [left, right] : [right, left];
    }
  }
  return [null, null];
}

function parseEventMeta(root) {
  root = root || document;
  const meta = { event_name: null, occurs_at: null, venue_name: null,
                 home_team: null, away_team: null };
  root.querySelectorAll('script[type="application/ld+json"]').forEach((el) => {
    let data;
    try { data = JSON.parse(el.textContent || ""); } catch (_) { return; }
    (Array.isArray(data) ? data : [data]).forEach((it) => {
      if (!it || typeof it !== "object") return;
      if (!(it["@type"] === "Event" || it["@type"] === "SportsEvent" || "startDate" in it)) return;
      meta.event_name = meta.event_name || it.name || null;
      meta.occurs_at = meta.occurs_at || it.startDate || null;
      if (it.location && typeof it.location === "object")
        meta.venue_name = meta.venue_name || it.location.name || null;
      [["homeTeam", "home_team"], ["awayTeam", "away_team"]].forEach(([k, d]) => {
        const v = it[k];
        if (v && typeof v === "object") meta[d] = meta[d] || v.name || null;
        else if (typeof v === "string") meta[d] = meta[d] || v;
      });
    });
  });
  if (!meta.event_name) meta.event_name = (document.title || "").trim() || null;
  if (meta.event_name && !(meta.home_team && meta.away_team)) {
    const [home, away] = splitTeams(meta.event_name);
    meta.home_team = meta.home_team || home;
    meta.away_team = meta.away_team || away;
  }
  return meta;
}

// --- raw capture (format-drift safety net) ---------------------------------
// Formats change: rather than trust the parser is right forever, keep the WHOLE
// rendered page + every inline JSON blob with each pull, so we can always
// re-parse history server-side after a layout change (and flag drift = raw
// present but nothing parsed). Twin: paciolan_raw_captures + paciolan_ingest.
const RAW_HTML_CAP = 2000000;  // ~2 MB hard cap so one pull can't balloon

function collectRaw(root) {
  root = root || document;
  const el = root.documentElement;
  const html = (el && el.outerHTML) || "";
  const truncated = html.length > RAW_HTML_CAP;
  const blobs = [];
  const sel = 'script[type="application/json"], script[type="application/ld+json"], script#__NEXT_DATA__';
  (root.querySelectorAll ? root.querySelectorAll(sel) : []).forEach((s) => {
    const text = s.textContent || "";
    if (!text.trim()) return;
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* keep as text */ }
    blobs.push({
      id: s.id || null,
      type: s.getAttribute("type") || null,
      json: json,
      text: json == null ? text.slice(0, RAW_HTML_CAP) : null,
    });
  });
  return {
    raw_html: truncated ? html.slice(0, RAW_HTML_CAP) : html,
    raw_html_truncated: truncated,
    raw_html_bytes: html.length,
    raw_blobs: blobs,
  };
}

if (typeof self !== "undefined") {
  self.PaciolanParse = { parseSeatmap, groupConsecutive, splitLevelSection,
                         parseSeatKey, classifySeatType, parseEventMeta,
                         splitTeams, collectRaw };
}
