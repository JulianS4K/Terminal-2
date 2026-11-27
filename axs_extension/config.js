// Settings, kept in browser.storage.local. The database's axs_watch_config (ext_lanes, ext_spacing_ms) overrides lanes
// and spacing when it answers /next; these are the starting values and the local ceilings.
"use strict";

const DEFAULTS = Object.freeze({
  server: "https://vibepass-storefront-test.onrender.com",
  secret: "",
  lanes: 4,            // tabs reading at once, one container each (1-8); an AXS read takes ~45 s
  spacingMs: 4000,     // least time between two page opens, across all lanes
  timeoutS: 90,        // a page that has shown no inventory by then is a timed-out read (AXS reads take ~45 s)
  settleMs: 2500,      // after the inventory arrives, wait this long for the rest of the page's answers
  followBuyLink: true, // when the event page itself carries no inventory, follow its "Buy Tickets" link (a GET)
  idleS: 15,           // nothing due: ask again after this long
  running: false,
});

async function loadConfig() {
  const got = await browser.storage.local.get(Object.keys(DEFAULTS));
  const cfg = Object.assign({}, DEFAULTS, got);
  cfg.lanes = Math.max(1, Math.min(8, parseInt(cfg.lanes, 10) || DEFAULTS.lanes));
  cfg.spacingMs = Math.max(1000, parseInt(cfg.spacingMs, 10) || DEFAULTS.spacingMs);
  cfg.timeoutS = Math.max(30, Math.min(240, parseInt(cfg.timeoutS, 10) || DEFAULTS.timeoutS));
  cfg.server = String(cfg.server || DEFAULTS.server).replace(/\/+$/, "");
  return cfg;
}

async function saveConfig(patch) {
  await browser.storage.local.set(patch);
  return loadConfig();
}

// One id per install, sent as the worker name: the database's lease (axs_watch_next) lets one reader read at a time.
async function workerId() {
  const { workerId: id } = await browser.storage.local.get("workerId");
  if (id) return id;
  const fresh = "ff-" + Array.from(crypto.getRandomValues(new Uint8Array(6)), b => b.toString(16).padStart(2, "0")).join("");
  await browser.storage.local.set({ workerId: fresh });
  return fresh;
}
