// The scheduler: asks our service what is due, hands each event to a free lane no sooner than the spacing after the
// last open, and sends each read back. The database decides what is due, how many lanes and what spacing
// (axs_watch_config: reader = 'extension', ext_lanes, ext_spacing_ms); the local settings are the starting values.
"use strict";

const S = {
  running: false, busy: new Map(), queue: [], lastOpenAt: 0, nextAskAt: 0,
  server: { lanes: null, spacingMs: null, reason: null, holdS: null }, lastError: null,
  stats: { reads: 0, ok: 0, empty: 0, failed: 0, listings: 0, since: null }, log: [],
};
const LOG_MAX = 50;

function note(line) {
  S.log.unshift(`${new Date().toLocaleTimeString()} ${line}`);
  S.log.length = Math.min(S.log.length, LOG_MAX);
}

async function askServer(cfg, lanes) {
  const want = lanes * 2 + S.busy.size;
  const got = await Api.next(cfg, await workerId(), want);
  S.server = { lanes: got.lanes || null, spacingMs: got.spacing_ms || null, reason: got.reason || null, holdS: got.hold_s || null };
  const taken = new Set([...S.busy.values()].map(e => e.id).concat(S.queue.map(e => e.id)));
  const fresh = (got.events || []).filter(e => !taken.has(String(e.id)) && e.url);
  S.queue.push(...fresh.map(e => ({ id: String(e.id), url: e.url })));
  if (!fresh.length) S.nextAskAt = Date.now() + 1000 * (got.hold_s || cfg.idleS);
}

async function runLane(cfg, lane, storeId, event) {
  S.busy.set(lane, event);
  try {
    const capture = await readEvent(cfg, storeId, event);
    const r = await Api.record(cfg, capture);
    S.stats.reads++;
    if (r.outcome === "ok") S.stats.ok++; else if (r.outcome === "empty") S.stats.empty++; else S.stats.failed++;
    S.stats.listings += r.listings || 0;
    note(`lane ${lane + 1} · ${event.id} · ${r.outcome}${r.listings != null ? ` · ${r.listings} listings` : ""}` +
         `${r.error ? ` · ${r.error}` : ""} · ${capture.elapsed_s}s${capture.cancelled.length ? ` · ${capture.cancelled.length} write(s) cancelled` : ""}`);
    if (capture.outcome === "blocked" || capture.outcome === "queue") S.nextAskAt = Date.now() + 60000;   // back off; the DB holds too
  } catch (e) {
    S.stats.failed++;
    S.lastError = String(e.message || e);
    note(`lane ${lane + 1} · ${event.id} · not sent: ${S.lastError}`);
  } finally {
    S.busy.delete(lane);
  }
}

let ticking = false;
async function tick() {
  if (!S.running || ticking) return;
  ticking = true;
  try {
    const cfg = await loadConfig();
    const lanes = Math.max(1, Math.min(8, S.server.lanes || cfg.lanes));
    const spacing = S.server.spacingMs || cfg.spacingMs;
    if (!S.queue.length && Date.now() >= S.nextAskAt && S.busy.size < lanes) {
      try { await askServer(cfg, lanes); S.lastError = null; }
      catch (e) { S.lastError = String(e.message || e); S.nextAskAt = Date.now() + 30000; note(`next: ${S.lastError}`); }
    }
    const stores = await laneContainers(lanes);
    for (let lane = 0; lane < lanes && S.queue.length; lane++) {
      if (S.busy.has(lane) || Date.now() - S.lastOpenAt < spacing) continue;
      S.lastOpenAt = Date.now();
      runLane(cfg, lane, stores[lane], S.queue.shift());
    }
  } finally {
    ticking = false;
  }
}

setInterval(tick, 1000);
loadConfig().then(cfg => { if (cfg.running) { S.running = true; S.stats.since = new Date().toISOString(); } });

browser.runtime.onMessage.addListener(async msg => {
  switch (msg && msg.type) {
    case "status":
      return { running: S.running, busy: [...S.busy.entries()].map(([l, e]) => ({ lane: l + 1, id: e.id })),
               queued: S.queue.length, server: S.server, lastError: S.lastError, stats: S.stats, log: S.log,
               config: await loadConfig(), worker: await workerId() };
    case "start":
      await saveConfig({ running: true });
      S.running = true; S.nextAskAt = 0; S.stats.since = S.stats.since || new Date().toISOString();
      note("started");
      return { ok: true };
    case "stop":
      await saveConfig({ running: false });
      S.running = false; S.queue = [];
      note("stopped (reads in progress finish)");
      return { ok: true };
    case "save":
      await saveConfig(msg.patch || {});
      return { ok: true };
    case "ping":
      try { return { ok: true, answer: await Api.ping(await loadConfig()) }; }
      catch (e) { return { ok: false, error: String(e.message || e) }; }
    case "resetLanes":
      if (S.busy.size) return { ok: false, error: "wait for the reads in progress to finish (stop first)" };
      await resetLanes();
      note("lane containers reset (cookies dropped)");
      return { ok: true };
    default:
      return { ok: false, error: "unknown message" };
  }
});
