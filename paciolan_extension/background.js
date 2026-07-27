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

function setBadge(count) {
  try {
    chrome.action.setBadgeBackgroundColor({ color: "#2e7d32" });
    chrome.action.setBadgeText({ text: count > 0 ? String(count) : "" });
  } catch (_) {}
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
