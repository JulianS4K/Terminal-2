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

  // ---------- TemporalChip (Phase 3) ----------
  //
  // Returns a coloured day-of-week + bucket chip for any ISO event date.
  // Phase 3 degraded: pure FE date math (day-of-week + T-days bucket).
  // Holiday / school-break / MLB-branded-series enrichment deferred to Phase 3b
  // pending A1 migration (those lore tables are admin_only RLS).
  //
  // Classes map to existing .badge CSS:
  //   urgent = T≤1d (red/orange tint)
  //   near   = T 2-7d (yellow tint)
  //   (none) = T 8-30d (neutral)
  //   muted  = T>30d or past
  function temporalChipHtml(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (!Number.isFinite(d.getTime())) return '';
    const now = Date.now();
    const days = Math.ceil((d.getTime() - now) / 86400000);
    const dow  = d.toLocaleDateString(undefined, { weekday: 'short' }); // "Mon"
    const full = d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
    let label, cls;
    if (days < -1)       { label = Math.abs(days) + 'd ago'; cls = 'muted'; }
    else if (days <= 0)  { label = 'TODAY';                  cls = 'urgent pos'; }
    else if (days === 1) { label = 'TMRW · ' + dow;          cls = 'urgent'; }
    else if (days <= 7)  { label = dow + ' +' + days + 'd';  cls = 'near'; }
    else if (days <= 30) { label = '+' + days + 'd';          cls = ''; }
    else                 { label = '+' + days + 'd';          cls = 'muted'; }
    return `<span class="badge temporal ${cls.trim()}" title="${_esc(full)}">${_esc(label)}</span>`;
  }

  // ---------- Movers-index cache (Phase 1b: <MoverChip>) ----------
  //
  // One shared lookup of get_event_movers_v2 (mig 20260527260000) per page.
  // Pages call T.moversPreloadIndex() once at init; T.moversChipHtml(eventId)
  // is then a sync Map lookup. Cached by (source, window_days); re-calling
  // with different opts invalidates that key.
  //
  // Default (source='merged', window_days=7) covers ~150 events across the 6
  // categories. Chips only render for events currently in that slot
  // ("currently moving"); events without a row produce an empty string.
  // When an event spans multiple categories the highest signal_score wins.
  const _moversCache = { key: null, promise: null, map: null };

  async function moversPreloadIndex(opts) {
    const source     = (opts && opts.source)      || 'merged';
    const windowDays = (opts && opts.window_days) || 7;
    const key = source + '|' + windowDays;
    if (_moversCache.key === key && _moversCache.promise) return _moversCache.promise;
    _moversCache.key = key;
    _moversCache.map = null;
    _moversCache.promise = (async () => {
      const Auth = window.TerminalAuth;
      if (!Auth || !Auth.client || !Auth.getAccessToken()) return new Map();
      try {
        const res = await Auth.client.rpc('get_event_movers_v2', {
          p_source:      source,
          p_window_days: windowDays,
          p_category:    null,
          p_limit:       200,
        });
        if (res.error) { console.error('[movers preload]', res.error); return new Map(); }
        const m = new Map();
        (res.data || []).forEach(row => {
          const id = +row.event_id;
          const prev = m.get(id);
          if (!prev || (+row.signal_score || 0) > (+prev.signal_score || 0)) m.set(id, row);
        });
        _moversCache.map = m;
        return m;
      } catch (e) {
        console.error('[movers preload]', e);
        return new Map();
      }
    })();
    return _moversCache.promise;
  }

  function moversChipHtml(eventId) {
    if (!eventId || !_moversCache.map) return '';
    const row = _moversCache.map.get(+eventId);
    if (!row) return '';
    const cat   = (row.category || '').replace(/_/g, ' ');
    const dpct  = (row.price_delta_pct != null && Number.isFinite(+row.price_delta_pct))
      ? ((+row.price_delta_pct) > 0 ? '+' : '') + (+row.price_delta_pct).toFixed(1) + '%'
      : '';
    const sign  = (+row.price_delta_pct || 0) > 0 ? 'pos'
                : (+row.price_delta_pct || 0) < 0 ? 'neg' : '';
    const score = row.signal_score != null ? (+row.signal_score).toFixed(2) : '—';
    const title = `In ${cat} index · rank ${row.rank} · score ${score}`;
    return `<span class="badge ${sign}" title="${_esc(title)}">${_esc(cat)}${dpct ? ' ' + dpct : ''}</span>`;
  }

  function _esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;',
    }[c]));
  }

  window.Terminal = {
    setStatus, getAuthHeader, api, getEventId,
    fmtDate, fmtNum, fmtPct, daysUntil, latestNonNull,
    temporalChipHtml,
    moversPreloadIndex, moversChipHtml,
  };

  // PWA: register the service worker (installable + offline app shell). External
  // file so it satisfies CSP script-src 'self'. Loaded on every terminal page.
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js')
        .catch((e) => console.warn('[pwa] sw register failed', e));
    });
  }
})();
