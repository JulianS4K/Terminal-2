// background.js  —  MV3 service worker.
//
// Receives normalized captures from content.js, keeps a local ring-buffer for
// the popup, and uploads DIRECTLY TO SUPABASE via the secret-gated PostgREST
// RPC `paciolan_ingest_secure` (anon key + shared X-Ingest secret). Passive
// captures only refresh the local buffer/badge; upload happens on the popup's
// "Get seats & upload" button (msg.upload === true).
//
// RULE 2: no request to any evenue.net host originates here. The only outbound
// write is to OUR configured Supabase project.
"use strict";

const RING_MAX = 100;

async function getLocal(keys) { return await chrome.storage.local.get(keys); }
async function setLocal(obj) { return await chrome.storage.local.set(obj); }

// Colored toolbar badge = at-a-glance export health.
//   green  = good (uploaded, has available seats + mapping metadata)
//   amber  = uploaded but thin (0 available seats, or missing name/date/venue)
//   red    = upload failed
//   grey   = passive capture (buffered, not uploaded)
const BADGE = {
  good:  { color: "#2e7d32", text: (n) => String(n) },
  thin:  { color: "#b8860b", text: (n) => String(n) },
  empty: { color: "#b8860b", text: () => "0" },
  fail:  { color: "#c62828", text: () => "!" },
  idle:  { color: "#616161", text: (n) => (n > 0 ? String(n) : "") },
};
function setBadge(level, count) {
  const b = BADGE[level] || BADGE.idle;
  try {
    chrome.action.setBadgeBackgroundColor({ color: b.color });
    chrome.action.setBadgeText({ text: b.text(count) });
  } catch (_) {}
}

// Judge a capture: did it upload, does it have sellable seats, and does it
// carry the event name/date/venue the server needs to map it to EVO/StubHub?
function assessQuality(payload, ship, uploaded) {
  const available = payload.seats.filter((s) => s.available).length;
  const hasMeta = !!(payload.event_name && payload.occurs_at && payload.venue_name);
  let level;
  if (!uploaded) level = "idle";
  else if (!ship.shipped) level = "fail";
  else if (available === 0) level = "empty";
  else if (!hasMeta) level = "thin";
  else level = "good";
  return {
    level, available, hasMeta,
    meta: {
      name: !!payload.event_name, date: !!payload.occurs_at,
      venue: !!payload.venue_name,
    },
  };
}

// Upload one capture to Supabase: POST <url>/rest/v1/rpc/paciolan_ingest_secure
// with { p_secret, p_payload }. Returns { shipped, status, snapshot_id?, error? }.
async function uploadToSupabase(payload) {
  const cfg = await getLocal(["supabaseUrl", "supabaseAnonKey", "ingestSecret"]);
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    return { shipped: false, error: "Set Supabase URL + anon key in the popup." };
  }
  if (!cfg.ingestSecret) {
    return { shipped: false, error: "Set the ingest secret in the popup." };
  }
  const base = cfg.supabaseUrl.replace(/\/+$/, "");
  const url = `${base}/rest/v1/rpc/paciolan_ingest_secure`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": cfg.supabaseAnonKey,
        "Authorization": `Bearer ${cfg.supabaseAnonKey}`,
      },
      body: JSON.stringify({ p_secret: cfg.ingestSecret, p_payload: payload }),
    });
    let body = null;
    try { body = await res.json(); } catch (_) {}
    if (!res.ok) {
      const msg = body && (body.message || body.hint || body.error) || res.statusText;
      return { shipped: false, status: res.status, error: msg };
    }
    // PostgREST returns the function's scalar (the new snapshot_id).
    const snapshotId = typeof body === "number" ? body
      : (body && (body.snapshot_id ?? body)) ?? null;
    return { shipped: true, status: res.status, snapshot_id: snapshotId };
  } catch (e) {
    return { shipped: false, error: String(e) };
  }
}

async function handleCapture(msg) {
  const payload = msg.payload;
  const availed = payload.seats.filter((s) => s.available).length;
  const record = {
    captured_at: payload.captured_at,
    tenant: payload.tenant,
    event_code: payload.event_code,
    source_url: payload.source_url,
    sections: payload.sections.length,
    seats: payload.seats.length,
    available_seats: availed,
    reason: msg.reason,
  };

  // Upload only on explicit request (the popup button); passive captures just
  // refresh the local buffer so a click ships the freshest map.
  record.ship = msg.upload ? await uploadToSupabase(payload)
                           : { shipped: false, reason: "not requested" };

  // Export-health verdict → colored badge + stored for the popup.
  record.quality = assessQuality(payload, record.ship, !!msg.upload);
  const { captures = [] } = await getLocal(["captures"]);
  captures.unshift({ ...record, payload });
  await setLocal({ captures: captures.slice(0, RING_MAX) });
  setBadge(record.quality.level, availed);
  return record;
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "paciolan_capture") {
    handleCapture(msg).then(sendResponse);
    return true; // async response
  }
  return false;
});
