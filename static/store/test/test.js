/* Shared helpers for the multi-page wiring test harness.
   Each page imports this and uses Test.* utilities. */
(function () {
  "use strict";

  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));

  function fmtMoney(v) {
    if (v == null || isNaN(Number(v))) return "—";
    return "$" + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 });
  }

  function fmtWhen(iso) {
    if (!iso) return "";
    const clean = String(iso).endsWith("Z") ? String(iso).slice(0, -1) : iso;
    const d = new Date(clean);
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
      + " " + d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }

  function fmtJson(v) {
    const json = JSON.stringify(v, null, 2) || "";
    return json
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/"([^"]+)":/g, '<span class="key">"$1":</span>')
      .replace(/: "([^"]*)"/g, ': <span class="str">"$1"</span>')
      .replace(/: (true|false)/g, ': <span class="bool">$1</span>')
      .replace(/: (null)/g, ': <span class="null">$1</span>')
      .replace(/: (-?\d+\.?\d*)/g, ': <span class="num">$1</span>');
  }

  // Activity log — adds to #log if present on the page.
  function log(msg, cls) {
    const el = $("#log");
    if (!el) return;
    const ts = new Date().toLocaleTimeString();
    const line = document.createElement("div");
    line.className = "line" + (cls ? " " + cls : "");
    line.textContent = `[${ts}]  ${msg}`;
    el.append(line);
    el.scrollTop = el.scrollHeight;
  }

  // Minimal fetch wrapper with timing + auto-log + JSON parsing.
  async function api(path, init) {
    const t0 = performance.now();
    let res, body, err;
    try {
      res = await fetch(path, init);
      const text = await res.text();
      try { body = JSON.parse(text); } catch { body = text; }
      if (!res.ok) {
        err = (body && (body.detail || body.error)) || text || `HTTP ${res.status}`;
      }
    } catch (e) {
      err = e.message;
    }
    const dt = Math.round(performance.now() - t0);
    const status = res ? res.status : "ERR";
    log(
      `${(init && init.method) || "GET"} ${path} → ${status} (${dt}ms)${err ? ' ' + err : ''}`,
      err ? "err" : "ok"
    );
    if (err) throw new Error(err);
    return { body, dt, status };
  }

  // Highlight the active sidebar link based on the current path.
  function markCurrentNav() {
    const path = location.pathname;
    for (const a of $$(".sidebar a")) {
      if (a.getAttribute("href") === path) a.classList.add("current");
    }
  }

  // Boot — fill the server-env pill, mark sidebar.
  async function boot() {
    markCurrentNav();
    const envEl = $("#serverEnv");
    if (envEl) {
      try {
        const r = await fetch("/api/public/config");
        const cfg = await r.json();
        const env = cfg && cfg.supabase_url
          ? new URL(cfg.supabase_url).hostname.split(".")[0]
          : "?";
        envEl.textContent = `supabase: ${env}`;
      } catch {
        envEl.textContent = "config unreachable";
        envEl.className = "pill err";
      }
    }
  }

  window.Test = { $, $$, fmtMoney, fmtWhen, fmtJson, log, api, boot };
  document.addEventListener("DOMContentLoaded", boot);
})();
