// Lanes: each lane reads in its own Firefox container ("AXS reader 1", "AXS reader 2", ...), so its cookies and site
// storage stay apart from the operator's own browsing (an AXS login in the default container is never used or touched)
// and from the other lanes. The tabs open in one reader window, in the background, and close when their read is done.
// A lane's container can be reset (its cookies dropped) from the popup.
"use strict";

const LANE_PREFIX = "AXS reader ";
const LANE_COLORS = ["blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple"];
const BLOCKED_TITLE = /AXS Access Info|Just a moment|Attention Required|Access denied/i;
const POLL_MS = 500;
// TicketsData's timings on AXS (axs_event_snapshots): the seat page lands in 12-15 s and its inventory takes ~28 s more,
// ~45 s a read. So once the purchase flow has started the reader waits to the page timeout; only the event page itself
// (no flow, no "Buy Tickets" link, or a page that says why) is given up on early.
const NO_INVENTORY_AFTER_LOAD_MS = 12000;
const QUEUE_WAIT_MS = 20000;               // still on Queue-it after this long: the waiting room is up

let readerWindowId = null;

async function laneContainers(n) {
  const all = await browser.contextualIdentities.query({});
  const ids = [];
  for (let i = 1; i <= n; i++) {
    const name = LANE_PREFIX + i;
    let c = all.find(x => x.name === name);
    if (!c) c = await browser.contextualIdentities.create({ name, color: LANE_COLORS[(i - 1) % LANE_COLORS.length], icon: "briefcase" });
    ids.push(c.cookieStoreId);
  }
  return ids;
}

// drop every lane container (and with it its cookies and storage); they are made again, empty, on the next read
async function resetLanes() {
  const all = await browser.contextualIdentities.query({});
  for (const c of all.filter(x => x.name.startsWith(LANE_PREFIX))) {
    await browser.contextualIdentities.remove(c.cookieStoreId);
  }
}

async function readerWindow() {
  if (readerWindowId !== null) {
    try { await browser.windows.get(readerWindowId); return readerWindowId; } catch (_) { readerWindowId = null; }
  }
  const w = await browser.windows.create({ url: "about:blank", state: "normal" });
  readerWindowId = w.id;
  return readerWindowId;
}

async function inTab(tabId, code) {
  try {
    const [out] = await browser.tabs.executeScript(tabId, { code, runAt: "document_idle" });
    return out;
  } catch (_) {
    return null;
  }
}

// read-only looks at the page as rendered: its text, its title, the JSON it carries inline, its "Buy Tickets" link
const PAGE_TEXT_JS = `(document.body ? document.body.innerText : "").slice(0, 4000)`;
const INLINE_JSON_JS = `Array.from(document.querySelectorAll('script[type="application/json"], script#__NEXT_DATA__'))
  .slice(0, 20).map(s => s.textContent).filter(t => t && t.length < 4000000)`;
const BUY_LINK_JS = `(() => { const a = Array.from(document.querySelectorAll('a[href]')).find(x =>
  /buy tickets|get tickets|find tickets|see tickets/i.test(x.textContent || '') && /^https:\\/\\//.test(x.href));
  return a ? a.href : null; })()`;

const sleep = ms => new Promise(r => setTimeout(r, ms));

// One event read in one lane. Returns the capture sent to /api/axs/ext/record.
async function readEvent(cfg, cookieStoreId, event) {
  const firedAt = new Date().toISOString();
  const t0 = Date.now();
  const windowId = await readerWindow();
  const tab = await browser.tabs.create({ windowId, cookieStoreId, url: "about:blank", active: false });
  const st = watchTab(tab.id);
  const out = { event_id: String(event.id), url: event.url, fired_at: firedAt, outcome: "loaded", error: null };
  try {
    await browser.tabs.update(tab.id, { url: event.url });
    const deadline = t0 + cfg.timeoutS * 1000;
    let followed = false, loadedAt = null;
    for (;;) {
      await sleep(POLL_MS);
      const now = Date.now();
      let info;
      try { info = await browser.tabs.get(tab.id); } catch (_) { out.outcome = "error"; out.error = "the tab was closed"; break; }
      if (st.queueSince && now - st.queueSince > QUEUE_WAIT_MS) { out.outcome = "queue"; break; }
      if ([403, 429, 503].includes(st.mainStatus) || BLOCKED_TITLE.test(info.title || "")) {
        out.outcome = "blocked"; out.http_status = st.mainStatus || 403;
        out.error = `${info.title || "blocked"} (${st.mainServer || "?"})`; break;
      }
      if (st.mainStatus === 404 || st.mainStatus === 410) { out.http_status = st.mainStatus; break; }
      const inv = inventoryIn(st.captures);
      if (inv.complete && now - st.lastAnswerAt >= cfg.settleMs) break;
      if (info.status === "complete" && loadedAt === null) loadedAt = now;
      if (loadedAt !== null && !st.inFlow && !inv.flow && !inv.offers && !inv.prices && !st.queueSince) {
        if (!followed && cfg.followBuyLink && now - loadedAt > 4000) {
          const href = await inTab(tab.id, BUY_LINK_JS);
          followed = true;
          if (href) { loadedAt = null; st.inFlow = true; await browser.tabs.update(tab.id, { url: href }); continue; }
        }
        if (now - loadedAt > NO_INVENTORY_AFTER_LOAD_MS) break;   // the page has nothing we read; the server says why
      }
      if (now >= deadline) {
        if (inv.offers || inv.prices) break;                      // late but in: send what came
        out.outcome = "timeout"; out.error = `no inventory within ${cfg.timeoutS}s`; break;
      }
    }
    if (out.outcome === "loaded") {
      out.page_text = await inTab(tab.id, PAGE_TEXT_JS);
      for (const text of (await inTab(tab.id, INLINE_JSON_JS)) || []) keepAnswer(st, "inline:" + (st.mainUrl || event.url), 200, text);
    }
    const info = await browser.tabs.get(tab.id).catch(() => null);
    out.title = info ? info.title : null;
    out.final_url = st.mainUrl;
    if (out.http_status === undefined) out.http_status = st.mainStatus;
  } catch (e) {
    out.outcome = "error"; out.error = String(e && e.message || e).slice(0, 200);
  } finally {
    unwatchTab(tab.id);
    await browser.tabs.remove(tab.id).catch(() => {});
  }
  out.elapsed_s = Math.round((Date.now() - t0) / 100) / 10;
  out.captures = st.captures.map(c => ({ url: c.url, status: c.status, json: c.json }));
  out.cancelled = st.cancelled;
  return out;
}
