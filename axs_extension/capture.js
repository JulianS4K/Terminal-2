// What the page receives, in the tabs this extension opened (and only those). Firefox's webRequest.filterResponseData
// hands us a copy of each answer as it passes to the page, unchanged; nothing is injected into the page and no
// request of our own is made to the site. RULE 2 guard: in these tabs a write-shaped request (a cart, hold, order,
// checkout or payment call that is not a plain read) is cancelled before it leaves the browser.
"use strict";

const MAX_ANSWER_BYTES = 8 * 1024 * 1024;
const MAX_ANSWERS = 150;
const READ_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);
const WRITE_PATH = /cart|basket|checkout|order|purchase|reserv|\bhold|\block|payment|transaction|claim/i;
// Queue-it: AXS sends nearly every visit through it (TicketsData: queue_it true, rt=Safetynet), and an ordinary
// visit passes straight back to the seat page. Only a stay there is the waiting room, which the reader does not wait in.
const QUEUE_HOST = /(^|\.)queue-it\.net$|(^|\.)queue\./i;
// the purchase flow's own hosts (the event page links to the shop, which lands on the seat page)
const FLOW_HOST = /^(tix|shop)\./i;

const watched = new Map();   // tabId -> state of the read in that tab

function watchTab(tabId) {
  const st = { captures: [], cancelled: [], mainStatus: null, mainUrl: null, mainServer: null, queueSince: null, inFlow: false,
               contentTypes: new Map(), bytes: 0, lastAnswerAt: Date.now() };
  watched.set(tabId, st);
  return st;
}

function unwatchTab(tabId) {
  watched.delete(tabId);
}

function noteMainFrame(st, url) {
  const host = new URL(url).hostname;
  if (QUEUE_HOST.test(host)) st.queueSince = st.queueSince || Date.now();
  else st.queueSince = null;
  if (FLOW_HOST.test(host)) st.inFlow = true;
}

function looksJson(text) {
  const t = text.trimStart();
  return t.startsWith("{") || t.startsWith("[");
}

function keepAnswer(st, url, status, text) {
  if (st.captures.length >= MAX_ANSWERS || !looksJson(text)) return;
  let json;
  try { json = JSON.parse(text); } catch (_) { return; }
  const shape = shapeOf(json);
  // answers with none of the shapes we read are dropped, so a page's analytics and config never leave the browser
  if (!shape.offers && !shape.offersAnswered && !shape.prices && !shape.onsale && !hasEventShape(json)) return;
  st.captures.push({ url: url.slice(0, 500), status, json, shape });
  st.lastAnswerAt = Date.now();
}

function hasEventShape(json) {
  for (const d of walkJson(json)) {
    if (d.venue && typeof d.venue === "object" && (d.title || d.name)) return true;
  }
  return false;
}

browser.webRequest.onBeforeRequest.addListener(details => {
  const st = watched.get(details.tabId);
  if (!st) return {};
  if (!READ_METHODS.has(details.method) && WRITE_PATH.test(new URL(details.url).pathname)) {
    st.cancelled.push(`${details.method} ${details.url.slice(0, 200)}`);
    return { cancel: true };
  }
  if (details.type === "main_frame") {
    noteMainFrame(st, details.url);
    return {};
  }
  if (details.type !== "xmlhttprequest") return {};
  const filter = browser.webRequest.filterResponseData(details.requestId);
  const chunks = [];
  let size = 0;
  filter.ondata = ev => {
    filter.write(ev.data);                       // the page gets every byte, unchanged and at once
    size += ev.data.byteLength;
    if (size <= MAX_ANSWER_BYTES) chunks.push(ev.data);
  };
  filter.onstop = () => {
    filter.close();
    if (size > MAX_ANSWER_BYTES || !watched.has(details.tabId)) return;
    const ct = st.contentTypes.get(details.requestId) || "";
    if (ct && !/json|javascript|text\/plain/i.test(ct)) return;
    const text = new TextDecoder("utf-8").decode(concatChunks(chunks, size));
    keepAnswer(st, details.url, st.contentTypes.get(details.requestId + ":status") || 200, text);
  };
  filter.onerror = () => { try { filter.disconnect(); } catch (_) { /* already gone */ } };
  return {};
}, { urls: ["<all_urls>"] }, ["blocking"]);

function concatChunks(chunks, size) {
  const out = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { out.set(new Uint8Array(c), at); at += c.byteLength; }
  return out;
}

browser.webRequest.onHeadersReceived.addListener(details => {
  const st = watched.get(details.tabId);
  if (!st) return;
  const header = name => (details.responseHeaders || []).find(h => h.name.toLowerCase() === name);
  const ct = header("content-type");
  st.contentTypes.set(details.requestId, ct ? ct.value : "");
  st.contentTypes.set(details.requestId + ":status", details.statusCode);
  if (details.type === "main_frame") {
    st.mainStatus = details.statusCode;
    st.mainUrl = details.url;
    const server = header("server");
    st.mainServer = server ? server.value : null;
    noteMainFrame(st, details.url);
  }
}, { urls: ["<all_urls>"] }, ["responseHeaders"]);
