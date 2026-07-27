// content.js  —  runs on *.evenue.net pages (ISOLATED world).
//
// Reads the rendered seat map (via parse_seatmap.js). Two flows:
//   * passive: on load + on DOM change (expand/quantity), refresh the local
//     buffer/badge (no upload).
//   * on demand: the popup's "Get seats & upload" button → scrape NOW and
//     upload to Supabase, relaying the result (snapshot_id) back to the popup.
//
// Seat numbers only exist in the DOM once a section is expanded, so the button
// captures whatever sections are currently open plus the always-present
// per-section availability summary.
//
// RULE 2: only reads the DOM eVenue already rendered. Originates no request to
// any evenue.net host.
"use strict";

function tenantFromHost() {
  const h = location.hostname || "";           // bgsufalcons.evenue.net -> bgsufalcons
  return h.endsWith(".evenue.net") ? h.slice(0, -".evenue.net".length) : h;
}

function eventCodeFromPath() {
  const m = /\/event\/([^/?#]+)\/([^/?#]+)/.exec(location.pathname);  // /event/F26/F01
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

// Passive refresh (no upload), de-duped on the available-seat fingerprint.
let lastSig = "";
function passiveCapture(reason) {
  let payload;
  try { payload = buildCapture(); } catch (e) { return; }
  if (!payload) return;
  const sig = JSON.stringify([
    payload.sections.length,
    payload.seats.filter((s) => s.available).length,
    payload.seats.map((s) => (s.available ? s.data_seat_key : "")).join(""),
  ]);
  if (sig === lastSig) return;
  lastSig = sig;
  chrome.runtime.sendMessage({ type: "paciolan_capture", reason, upload: false,
                               payload });
}

let t = null;
function schedulePassive(reason) { clearTimeout(t); t = setTimeout(() => passiveCapture(reason), 600); }

schedulePassive("load");
new MutationObserver(() => schedulePassive("mutation"))
  .observe(document.documentElement, { childList: true, subtree: true });

// Button-driven capture+upload: scrape now, ask background to upload, relay the
// result to the popup.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "paciolan_capture_now") {
    let payload;
    try { payload = buildCapture(); } catch (e) { payload = null; }
    if (!payload) {
      sendResponse({ ok: false, error: "No seat map found on this page. Open an eVenue event and expand a section." });
      return true;
    }
    const availed = payload.seats.filter((s) => s.available).length;
    chrome.runtime.sendMessage(
      { type: "paciolan_capture", reason: "button", upload: true, payload },
      (record) => sendResponse({ ok: true, record, scraped: {
        sections: payload.sections.length, seats: payload.seats.length,
        available_seats: availed } }),
    );
    return true; // async
  }
  return false;
});
