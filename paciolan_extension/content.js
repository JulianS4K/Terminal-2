// content.js  —  runs on *.evenue.net pages (ISOLATED world).
//
// Reads the rendered seat map (via parse_seatmap.js) and forwards a normalized
// capture to the service worker. Seat numbers only exist in the DOM once a
// section is expanded, so we also watch for DOM changes (expanding a section,
// changing quantity) and re-capture — debounced. The top-level section
// availability summary is captured on every pass even before any expand.
//
// RULE 2: only reads the DOM eVenue already rendered. Originates no request to
// any evenue.net host.
"use strict";

function tenantFromHost() {
  // bgsufalcons.evenue.net -> "bgsufalcons"
  const h = location.hostname || "";
  return h.endsWith(".evenue.net") ? h.slice(0, -".evenue.net".length) : h;
}

function eventCodeFromPath() {
  // /event/F26/F01 -> "F26/F01"
  const m = /\/event\/([^/?#]+)\/([^/?#]+)/.exec(location.pathname);
  return m ? `${m[1]}/${m[2]}` : null;
}

function buildCapture() {
  const { sections, seats } = self.PaciolanParse.parseSeatmap(document);
  if (!sections.length && !seats.length) return null;
  return {
    platform: "paciolan",
    tenant: tenantFromHost(),
    event_code: eventCodeFromPath(),
    source_url: location.href,
    event_name: (document.title || "").trim() || null,
    captured_at: new Date().toISOString(),
    sections,
    seats,
  };
}

let lastSig = "";
function capture(reason) {
  let payload;
  try {
    payload = buildCapture();
  } catch (e) {
    return;
  }
  if (!payload) return;
  // De-dupe: skip if the available-seat/section fingerprint is unchanged.
  const sig = JSON.stringify([
    payload.sections.length,
    payload.seats.filter((s) => s.available).length,
    payload.seats.map((s) => (s.available ? s.data_seat_key : "")).join(""),
  ]);
  if (sig === lastSig) return;
  lastSig = sig;
  chrome.runtime.sendMessage({ type: "paciolan_capture", reason, payload });
}

let t = null;
function scheduleCapture(reason) {
  clearTimeout(t);
  t = setTimeout(() => capture(reason), 600);
}

// Initial pass + observe the seat-map container for expands/quantity changes.
scheduleCapture("load");
const obs = new MutationObserver(() => scheduleCapture("mutation"));
obs.observe(document.documentElement, { childList: true, subtree: true });

// Let the popup force a fresh capture.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "paciolan_recapture") {
    lastSig = "";
    capture("manual");
    sendResponse({ ok: true });
  }
  return true;
});
