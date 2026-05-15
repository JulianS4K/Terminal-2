// D0 Terminal — base helpers (auth, fetch, query string).
// Stays small. Page-specific logic lives in event.js.

(function () {
  'use strict';

  const STATUS = document.getElementById('status');

  // API host. The terminal deploys as a static site on
  // vibepass-terminal-test.onrender.com (per render-d0-terminal.yaml — D0's
  // assigned Render service, srv-d839339kh4rs73ac3s20). FastAPI lives on
  // D1's vibepass-storefront-test service. So in prod we cross-origin to
  // D1's host; on localhost everything is same-origin against the dev
  // uvicorn. Override at runtime via localStorage.terminalApiBase if the
  // operator wants to point at a different host (preview, staging).
  const API_BASE = (function () {
    const override = (typeof localStorage !== 'undefined') && localStorage.getItem('terminalApiBase');
    if (override) return override.replace(/\/$/, '');
    const h = location.hostname;
    if (h === 'localhost' || h === '127.0.0.1' || h === '') return '';
    return 'https://vibepass-storefront-test.onrender.com';
  })();

  function setStatus(msg, cls) {
    if (!STATUS) return;
    STATUS.textContent = msg;
    STATUS.className = 'status' + (cls ? ' ' + cls : '');
  }

  function getAuthHeader() {
    // Primary: live Supabase session via TerminalAuth (same auth backend as
    // D2's dashboard — Google OAuth → @s4kent.com gate; see auth.js).
    if (window.TerminalAuth) {
      const tok = window.TerminalAuth.getAccessToken();
      if (tok) return { Authorization: 'Bearer ' + tok };
    }
    // Fallback: legacy manual paste-in. Still useful pre-OAuth-setup or for
    // ad-hoc curl-derived JWTs during debugging.
    const legacy = (typeof localStorage !== 'undefined') && localStorage.getItem('terminalToken');
    return legacy ? { Authorization: 'Bearer ' + legacy } : {};
  }

  async function api(path) {
    const url = API_BASE + path;
    const res = await fetch(url, {
      headers: { 'Accept': 'application/json', ...getAuthHeader() },
      credentials: API_BASE ? 'omit' : 'same-origin',
      mode: API_BASE ? 'cors' : 'same-origin',
    });
    if (res.status === 401 || res.status === 403) {
      const detail = res.status === 401
        ? '401 — set localStorage.terminalToken or run with AUTH_DISABLED=true'
        : '403 — token email not in @s4kent.com allowlist';
      throw new Error(detail);
    }
    if (!res.ok) {
      let body = '';
      try { body = (await res.text()).slice(0, 200); } catch (_) {}
      throw new Error(`${res.status} ${res.statusText} ${path} ${body}`);
    }
    return res.json();
  }

  function getEventId() {
    const params = new URLSearchParams(window.location.search);
    const v = params.get('event');
    if (!v) return null;
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  function fmtDate(iso) {
    if (!iso) return '—';
    try {
      const d = new Date(iso);
      return d.toLocaleString(undefined, {
        weekday: 'short', month: 'short', day: 'numeric',
        hour: 'numeric', minute: '2-digit',
      });
    } catch (_) { return iso; }
  }

  function fmtNum(n, opts) {
    if (n === null || n === undefined || Number.isNaN(n)) return '—';
    const o = opts || {};
    return Number(n).toLocaleString(undefined, {
      minimumFractionDigits: o.min ?? 0,
      maximumFractionDigits: o.max ?? 0,
    });
  }

  function fmtPct(p, decimals) {
    if (p === null || p === undefined || Number.isNaN(p)) return '—';
    const d = decimals ?? 1;
    return (p >= 0 ? '+' : '') + Number(p).toFixed(d) + '%';
  }

  function daysUntil(iso) {
    if (!iso) return null;
    const ms = new Date(iso).getTime() - Date.now();
    if (!Number.isFinite(ms)) return null;
    return Math.ceil(ms / 86400000);
  }

  // Pluck the most recent non-null value from a [{t, v}, ...] series.
  function latestNonNull(series) {
    if (!Array.isArray(series)) return null;
    for (let i = series.length - 1; i >= 0; i--) {
      const v = series[i] && series[i].v;
      if (v !== null && v !== undefined && !Number.isNaN(v)) return v;
    }
    return null;
  }

  window.Terminal = {
    setStatus, getAuthHeader, api, getEventId,
    fmtDate, fmtNum, fmtPct, daysUntil, latestNonNull,
  };
})();
