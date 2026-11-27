// Calls to OUR web service only (routers/axs_ext.py). Nothing in this file talks to the ticketing site: the reads are
// the page's own, in capture.js. Every call carries the shared X-Ingest-Secret.
"use strict";

async function ourApi(cfg, path, body) {
  const init = { headers: { "X-Ingest-Secret": cfg.secret } };
  if (body !== undefined) {
    init.method = "POST";
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 60000);
  init.signal = ctl.signal;
  try {
    const r = await fetch(cfg.server + path, init);
    const text = await r.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (_) { data = { raw: text.slice(0, 300) }; }
    if (!r.ok) {
      const why = (data && (data.detail || data.raw)) || r.statusText;
      throw new Error(`HTTP ${r.status} from our service: ${why}`);
    }
    return data;
  } finally {
    clearTimeout(timer);
  }
}

const Api = {
  ping: (cfg) => ourApi(cfg, "/api/axs/ext/ping"),
  next: (cfg, worker, limit) => ourApi(cfg, "/api/axs/ext/next", { worker, limit }),
  // a lost answer is sent again with the same fired_at; the database returns the first record for a repeat
  async record(cfg, capture) {
    let last;
    for (const wait of [0, 2000, 8000]) {
      if (wait) await new Promise(r => setTimeout(r, wait));
      try { return await ourApi(cfg, "/api/axs/ext/record", capture); } catch (e) { last = e; }
    }
    throw last;
  },
};
