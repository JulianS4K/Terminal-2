// D0 Terminal — base helpers (auth, fetch, query string).
// Stays small. Page-specific logic lives in event.js.

(function () {
  'use strict';

  const STATUS = document.getElementById('status');

  // API host — resolves the FastAPI shell location based on where the
  // browser opened the terminal pages. Three deploy topologies:
  //
  //   1. localhost dev (uvicorn) — same-origin. `/api/*` lives next to the
  //      static files.
  //   2. Static CDN (vibepass-terminal-test.onrender.com, per render-d0-
  //      terminal.yaml) — cross-origin to the FastAPI shell on a sibling
  //      service. CSP `connect-src` allowlists the shell host.
  //   3. FastAPI shell directly (vibepass-storefront-test.onrender.com OR
  //      its Railway mirror at glorious-appreciation-production-a6ce.up.
  //      railway.app OR any future preview/staging host) — same-origin.
  //      Cross-origin to the canonical Render host from here is wrong: it
  //      forces a CORS preflight + cold-start trip just to talk to ourselves,
  //      and breaks entirely when the canonical shell is sleeping (FREE plan
  //      cold-start, PROJECT_BIBLE §10). Operator hit "failed to fetch" on
  //      Railway 2026-05-17 — that path is what triggered this fix.
  //
  // Override via localStorage.terminalApiBase for ad-hoc preview/staging.
  const API_BASE = (function () {
    const override = (typeof localStorage !== 'undefined') && localStorage.getItem('terminalApiBase');
    if (override) return override.replace(/\/$/, '');
    const h = location.hostname;
    // Topology 1: localhost dev.
    if (h === 'localhost' || h === '127.0.0.1' || h === '') return '';
    // Topology 2: static CDN — cross-origin to the canonical FastAPI shell.
    // Includes the original publishPath=static/terminal layout and the new
    // wider publishPath=static layout (PR #181); both serve from this host.
    if (h.includes('terminal-test')) {
      return 'https://vibepass-storefront-test.onrender.com';
    }
    // Topology 3: FastAPI shell deploys (any other host). Use same-origin
    // so /api/* hits the local FastAPI without a CORS round-trip.
    return '';
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
      // Strip HTML tags + clip — some servers return full HTML 404 pages and
      // the raw body shouldn't splatter into the status pill.
      let body = '';
      try {
        const raw = await res.text();
        body = raw.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
      } catch (_) {}
      throw new Error(`${res.status} ${res.statusText} ${path}${body ? ' — ' + body : ''}`);
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
