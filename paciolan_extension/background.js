// background.js  —  MV3 service worker.
//
// Receives normalized captures from content.js, keeps a local ring-buffer for
// the popup, and (if configured) ships each capture to our own ingest endpoint
// with the shared X-Ingest-Secret header.
//
// RULE 2: no request to any evenue.net host originates here. The only outbound
// write is to OUR configured ingest URL (our Render app / Supabase).
"use strict";

const RING_MAX = 100;

async function getLocal(keys) { return await chrome.storage.local.get(keys); }
async function setLocal(obj) { return await chrome.storage.local.set(obj); }

function setBadge(count) {
  try {
    chrome.action.setBadgeBackgroundColor({ color: "#2e7d32" });
    chrome.action.setBadgeText({ text: count > 0 ? String(count) : "" });
  } catch (_) {}
}

async function ship(payload) {
  const cfg = await getLocal(["enabled", "ingestUrl", "ingestSecret"]);
  if (!cfg.enabled || !cfg.ingestUrl) return { shipped: false, reason: "disabled" };
  const headers = { "Content-Type": "application/json" };
  if (cfg.ingestSecret) headers["X-Ingest-Secret"] = cfg.ingestSecret;
  try {
    const res = await fetch(cfg.ingestUrl, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
    return { shipped: res.ok, status: res.status };
  } catch (e) {
    return { shipped: false, reason: String(e) };
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

  const shipResult = await ship(payload);
  record.ship = shipResult;

  const { captures = [] } = await getLocal(["captures"]);
  captures.unshift({ ...record, payload });
  await setLocal({ captures: captures.slice(0, RING_MAX) });
  setBadge(availed);
  return record;
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "paciolan_capture") {
    handleCapture(msg).then(sendResponse);
    return true; // async response
  }
  return false;
});
