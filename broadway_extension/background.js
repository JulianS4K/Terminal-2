// background.js  —  MV3 service worker.
//
// Receives captured availability payloads from relay.js, normalizes them via
// the ported parse_availability(), redacts the cart token, keeps a local
// ring-buffer for the popup, and (if configured) ships each capture to a
// Supabase ingest endpoint.
//
// No request to broadway.com originates here — we only forward data the page
// already fetched (RULE 2).

"use strict";

importScripts("parse_availability.js");

const RING_MAX = 100;

async function getLocal(keys) {
  return await chrome.storage.local.get(keys);
}
async function setLocal(obj) {
  return await chrome.storage.local.set(obj);
}

function setBadge(count) {
  try {
    chrome.action.setBadgeBackgroundColor({ color: "#2e7d32" });
    chrome.action.setBadgeText({ text: count > 0 ? String(count) : "" });
  } catch (_) {}
}

async function handleCapture(msg) {
  const parsed = parseAvailability(msg.payload, {
    sourceUrl: msg.url,
    capturedAt: msg.captured_at,
    requestedQuantity: msg.requested_quantity,
  });
  if (!parsed.ok) {
    // Not an availability payload (e.g. a bootstrap JSON without tickets). Skip quietly.
    return { skipped: parsed.reason };
  }
  const snap = parsed.snapshot;

  // Redact the cart/session token from the raw payload before storing/shipping.
  let raw = msg.payload;
  try {
    raw = JSON.parse(JSON.stringify(msg.payload));
    if (raw && typeof raw === "object" && "bapi_cart_token" in raw) {
      raw.bapi_cart_token = "REDACTED";
    }
  } catch (_) {}

  const record = {
    url: msg.url,
    event_id: snap.event_id,
    captured_at: snap.captured_at_utc,
    requested_quantity: snap.requested_quantity,
    ticket_count: snap.ticket_count,
    price_min: snap.price_min,
    price_max: snap.price_max,
    sections: snap.sections,
    snapshot: snap,
    payload: raw,
    shipped: null,
  };

  const cfg = (await getLocal("config")).config || {};
  if (cfg.enabled && cfg.ingestUrl) {
    try {
      const r = await ship(cfg, record);
      record.shipped = r.ok ? r.status : `err ${r.status}`;
      await setLocal({ last_error: r.ok ? null : `ingest ${r.status}: ${r.body || ""}`.slice(0, 300) });
    } catch (e) {
      record.shipped = "err";
      await setLocal({ last_error: String(e).slice(0, 300) });
    }
  }

  // ring buffer (newest first) — keep FULL records (snapshot + redacted raw)
  // so the popup's "Export JSON" yields complete data. Capped at RING_MAX to
  // stay under the ~10MB chrome.storage.local quota (~no unlimitedStorage).
  const st = await getLocal(["captures", "total_captured"]);
  const captures = st.captures || [];
  captures.unshift(record);
  if (captures.length > RING_MAX) captures.length = RING_MAX;
  const total = (st.total_captured || 0) + 1;
  await setLocal({ captures, total_captured: total, last_capture: record });
  setBadge(snap.ticket_count);
  return { ok: true, ticket_count: snap.ticket_count };
}

async function ship(cfg, record) {
  const headers = Object.assign({ "Content-Type": "application/json" }, cfg.headers || {});
  const body = JSON.stringify({
    url: record.url,
    event_id: record.event_id,
    captured_at: record.captured_at,
    requested_quantity: record.requested_quantity,
    ticket_count: record.ticket_count,
    snapshot: record.snapshot,
    payload: record.payload,
  });
  const res = await fetch(cfg.ingestUrl, { method: "POST", headers, body });
  let txt = "";
  try { txt = await res.text(); } catch (_) {}
  return { ok: res.ok, status: res.status, body: txt };
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || !msg.type) return;
  if (msg.type === "bwy_capture") {
    handleCapture(msg).then(sendResponse).catch((e) => sendResponse({ error: String(e) }));
    return true; // async
  }
  if (msg.type === "get_state") {
    getLocal(["captures", "total_captured", "config", "last_capture", "last_error"])
      .then((s) => sendResponse(s));
    return true;
  }
  if (msg.type === "save_config") {
    setLocal({ config: msg.config }).then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.type === "clear_captures") {
    setLocal({ captures: [], total_captured: 0, last_capture: null, last_error: null })
      .then(() => { setBadge(0); sendResponse({ ok: true }); });
    return true;
  }
});

chrome.runtime.onInstalled.addListener(() => setBadge(0));
