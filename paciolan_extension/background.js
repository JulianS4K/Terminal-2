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

// ─────────────────────────────────────────────────────────────────────────────
// Autonomous driver — the browser half of the SQL pull loop.
//
// SQL (pg_cron) enqueues due events into paciolan_pull_queue; this driver polls
// paciolan_next_pull on a chrome.alarms timer, opens the returned eVenue URL in a
// fresh background tab, scrapes + uploads it, then reports the outcome with
// paciolan_pull_resolve and closes the tab (open+close per pull). It only runs
// while ARMED (a popup toggle) — autonomous = it opens tabs on its own, so the
// toggle is the safety. RULE 2 unchanged: eVenue is only ever READ.
const DRIVER_ALARM = "paciolan_driver";
const DRIVER_PERIOD_MIN = 1;     // poll cadence
const MAX_PULLS_PER_TICK = 3;    // cap tab churn per wake
const RENDER_SETTLE_MS = 3500;   // let the seat-map SVG paint after load
const PULL_TIMEOUT_MS = 30000;   // give up on a stuck tab

// Call a secret-gated Paciolan RPC with the anon key. Returns parsed JSON or
// throws. Shares the popup's configured URL / anon key / ingest secret.
async function callRpc(fn, extraBody) {
  const cfg = await getLocal(["supabaseUrl", "supabaseAnonKey", "ingestSecret"]);
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !cfg.ingestSecret) {
    throw new Error("Supabase URL, anon key, and ingest secret must be set.");
  }
  const base = cfg.supabaseUrl.replace(/\/+$/, "");
  const res = await fetch(`${base}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": cfg.supabaseAnonKey,
      "Authorization": `Bearer ${cfg.supabaseAnonKey}`,
    },
    body: JSON.stringify({ p_secret: cfg.ingestSecret, ...extraBody }),
  });
  let body = null;
  try { body = await res.json(); } catch (_) {}
  if (!res.ok) {
    const msg = (body && (body.message || body.hint || body.error)) || res.statusText;
    throw new Error(`${fn}: ${msg}`);
  }
  return body;
}

async function setDriverStatus(patch) {
  const { driverStatus = {} } = await getLocal(["driverStatus"]);
  await setLocal({ driverStatus: { ...driverStatus, ...patch } });
}

// Wait until a tab reports status:'complete', then a fixed settle delay.
function waitForTabLoad(tabId) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(onUpdated);
      reject(new Error("tab load timed out"));
    }, PULL_TIMEOUT_MS);
    function onUpdated(id, info) {
      if (id === tabId && info.status === "complete") {
        chrome.tabs.onUpdated.removeListener(onUpdated);
        clearTimeout(timer);
        setTimeout(resolve, RENDER_SETTLE_MS);   // let the SVG map paint
      }
    }
    chrome.tabs.onUpdated.addListener(onUpdated);
  });
}

function sendMessageToTab(tabId, msg) {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, msg, (resp) => {
      if (chrome.runtime.lastError) { resolve({ ok: false, error: chrome.runtime.lastError.message }); return; }
      resolve(resp || { ok: false, error: "no response from page" });
    });
  });
}

// Drive one queued row: open the URL, scrape+upload, resolve, close the tab.
async function drivePull(row) {
  let tab = null;
  try {
    tab = await chrome.tabs.create({ url: row.url, active: false });
    await waitForTabLoad(tab.id);
    // content.js scrapes the rendered map and uploads via paciolan_ingest_secure.
    const resp = await sendMessageToTab(tab.id, { type: "paciolan_capture_now" });
    if (!resp.ok) {
      await callRpc("paciolan_pull_resolve",
        { p_id: row.id, p_status: "error", p_error: resp.error || "capture failed" });
      return { id: row.id, status: "error", error: resp.error };
    }
    const shipped = resp.record && resp.record.ship && resp.record.ship.shipped;
    const snapId = shipped ? resp.record.ship.snapshot_id : null;
    const avail = resp.scraped ? resp.scraped.available_seats : 0;
    const status = !shipped ? "error" : (avail > 0 ? "ok" : "empty");
    await callRpc("paciolan_pull_resolve", {
      p_id: row.id, p_status: status, p_snapshot_id: snapId,
      p_available: avail,
      p_error: shipped ? null : (resp.record && resp.record.ship && resp.record.ship.error) || "upload failed",
    });
    return { id: row.id, status, available: avail, snapshot_id: snapId };
  } catch (e) {
    await callRpc("paciolan_pull_resolve",
      { p_id: row.id, p_status: "error", p_error: String(e) }).catch(() => {});
    return { id: row.id, status: "error", error: String(e) };
  } finally {
    if (tab && tab.id != null) { try { await chrome.tabs.remove(tab.id); } catch (_) {} }
  }
}

// One driver tick: claim + drive up to MAX_PULLS_PER_TICK due rows.
let driverBusy = false;
async function driverTick() {
  const { driverArmed } = await getLocal(["driverArmed"]);
  if (!driverArmed || driverBusy) return;
  driverBusy = true;
  try {
    let done = 0;
    const results = [];
    for (let i = 0; i < MAX_PULLS_PER_TICK; i++) {
      let claimed;
      try {
        claimed = await callRpc("paciolan_next_pull", { p_driver: "extension" });
      } catch (e) {
        await setDriverStatus({ last_tick: new Date().toISOString(), last_error: String(e) });
        return;
      }
      // PostgREST returns an array of rows for a table-returning function.
      const row = Array.isArray(claimed) ? claimed[0] : claimed;
      if (!row || row.id == null) break;   // queue empty
      results.push(await drivePull(row));
      done++;
    }
    await setDriverStatus({
      last_tick: new Date().toISOString(), last_error: null,
      last_pulled: done, last_results: results,
    });
  } finally {
    driverBusy = false;
  }
}

async function setDriverArmed(armed) {
  await setLocal({ driverArmed: !!armed });
  if (armed) {
    chrome.alarms.create(DRIVER_ALARM, { periodInMinutes: DRIVER_PERIOD_MIN });
    driverTick();   // kick immediately so the operator sees it work
  } else {
    chrome.alarms.clear(DRIVER_ALARM);
  }
  await setDriverStatus({ armed: !!armed });
}

chrome.alarms.onAlarm.addListener((a) => { if (a.name === DRIVER_ALARM) driverTick(); });

// Re-arm the alarm across SW restarts if the operator left the driver on.
async function restoreDriver() {
  const { driverArmed } = await getLocal(["driverArmed"]);
  if (driverArmed) chrome.alarms.create(DRIVER_ALARM, { periodInMinutes: DRIVER_PERIOD_MIN });
}
chrome.runtime.onStartup.addListener(restoreDriver);
chrome.runtime.onInstalled.addListener(restoreDriver);

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "paciolan_capture") {
    handleCapture(msg).then(sendResponse);
    return true; // async response
  }
  if (msg && msg.type === "paciolan_driver_arm") {
    setDriverArmed(msg.armed).then(() => sendResponse({ ok: true, armed: !!msg.armed }));
    return true;
  }
  if (msg && msg.type === "paciolan_driver_status") {
    getLocal(["driverArmed", "driverStatus"]).then((s) =>
      sendResponse({ armed: !!s.driverArmed, status: s.driverStatus || {} }));
    return true;
  }
  return false;
});
