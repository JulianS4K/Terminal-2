// D0 Terminal — Home page NEWS WIRE ticker.
//
// Renders a live, filterable sports-news ticker above the watchlist. Reads the
// SECURITY DEFINER RPC get_terminal_news_ticker (mig 20260629120000, repointed
// 20260702210000, +injuries 20260702230040) — the only path the authenticated
// terminal client has to espn_news / espn_injuries_snapshots, whose RLS is
// admin_only (USING(false) for authenticated/anon). The RPC unions:
//   * ESPN      — espn_news, ~80 articles/24h across 7 leagues (LIVE).
//   * Injuries  — espn_injuries_snapshots (LIVE: change-only injury updates from
//                 espn-collect's roster scope). item_type='injury'; INJ tag.
//   * Scores    — espn_event_snapshots (LIVE: latest per game, live + final;
//                 gameday scope). item_type='score'; SCORE tag.
//   * Standings — espn_team_snapshots (LIVE: latest per team; team_daily scope,
//                 ~daily). item_type='standing'; W-L tag.
//   * Reddit    — v_reddit_news_ticker (LIVE: flair:"News" pipeline, mig
//                 20260626120000 — title-only, 48h, deduped first-post-shows).
//                 Each Reddit row carries `team` = 'r/<sub>' for attribution.
//
// Server params: window hours (re-query). Client-side (instant): source toggle,
// league chips (faceted with live counts), free-text search. Auto-refreshes
// every 3 min while the tab is visible.
//
// Degrades honestly: if the RPC isn't applied to prod yet the panel shows
// "news wire not enabled yet" instead of crashing (same pattern as home.js's
// watchlist 42883 guard).

(function () {
  'use strict';

  const WINDOW_DEFAULT = 48;       // hours
  // Pull the RPC max. Sources refresh at very different cadences — Standings
  // update once daily (~05:00) so they sit well below the freshest news; a small
  // fetch would drop them entirely and leave the Standings toggle empty. 300
  // keeps every source represented for the client-side source filter.
  const FETCH_LIMIT    = 300;      // rows pulled per query (newest-first; RPC cap)
  const REEL_MAX       = 30;       // headlines in the scrolling marquee
  const LIST_MAX       = 25;       // rows in the readable list
  const REFRESH_MS     = 180000;   // 3 min auto-refresh

  const state = {
    items:       [],
    source:      'all',            // 'all' | 'ESPN' | 'Injuries' | 'Scores' | 'Standings' | 'Reddit'
    windowHours: WINDOW_DEFAULT,   // 24 | 48 | 168
    league:      'ALL',
    search:      '',
    loading:     false,
  };

  // ---------- helpers ----------
  const esc = window.TermRender.escapeHtml;

  // Feed-derived URLs are untrusted: escaping alone does not stop a
  // `javascript:`/`data:` scheme from becoming click-to-execute in an href.
  // Allow only http(s); anything else collapses to a dead '#'.
  const safeHref = window.TermRender.safeHref;

  function relTime(iso) {
    if (!iso) return '';
    const ms = Date.now() - new Date(iso).getTime();
    if (!Number.isFinite(ms)) return '';
    const m = Math.floor(ms / 60000);
    if (m < 1)  return 'now';
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  // Reddit rows can land with no resolved league → bucket as GEN.
  const leagueOf = it => (it && it.league) ? it.league : 'GEN';

  // Source label: for Reddit rows show the originating sub ('r/<sub>', carried
  // in `team`); for injury rows show the affected team; otherwise the plain
  // source name.
  const srcLabel = it => {
    if (!it) return '';
    if (it.source === 'Reddit' && it.team) return it.team;
    if (it.source === 'Injuries') return it.team || 'Injuries';
    return it.source || '';
  };

  // A story carried under a team byline (Reddit sub or injured player's team)
  // gets a secondary source line in the reel.
  const hasSub = it => !!(it && it.team && (it.source === 'Reddit' || it.source === 'Injuries'));

  function el(id) { return document.getElementById(id); }

  // ---------- fetch ----------
  async function fetchNews() {
    const reel = el('newsTickerReel');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      if (reel) reel.innerHTML = '<div class="empty">not signed in</div>';
      return;
    }
    if (state.loading) return;
    state.loading = true;
    try {
      const res = await Auth.client.rpc('get_terminal_news_ticker', {
        p_window_hours: state.windowHours,
        p_sources:      null,   // pull all sources; source toggle filters client-side
        p_leagues:      null,
        p_search:       null,   // search filters client-side for instant typing
        p_limit:        FETCH_LIMIT,
      });
      if (res.error) {
        // RPC not applied to prod yet → honest empty state, no crash.
        if (/does not exist/i.test(res.error.message || '') || res.error.code === '42883') {
          if (reel) reel.innerHTML = '<div class="empty">news wire not enabled yet — RPC pending apply</div>';
          el('newsTickerList').innerHTML = '';
          setMeta('');
          return;
        }
        console.error('[news] rpc', res.error);
        if (reel) reel.innerHTML = '<div class="empty">failed to load news</div>';
        return;
      }
      state.items = Array.isArray(res.data) ? res.data : [];
      renderAll();
    } catch (e) {
      console.error('[news] fetch', e);
      if (reel) reel.innerHTML = '<div class="empty">failed to load news</div>';
    } finally {
      state.loading = false;
    }
  }

  // ---------- filtering ----------
  // Base = items narrowed by source + search but NOT league, so league chips
  // can show accurate faceted counts (standard facet behaviour).
  function baseItems() {
    let arr = state.items;
    if (state.source !== 'all') arr = arr.filter(x => x.source === state.source);
    const q = state.search.trim().toLowerCase();
    if (q) {
      arr = arr.filter(x =>
        (x.headline || '').toLowerCase().includes(q) ||
        (x.summary  || '').toLowerCase().includes(q) ||
        (x.team     || '').toLowerCase().includes(q) ||
        (x.league   || '').toLowerCase().includes(q));
    }
    return arr;
  }

  function visibleItems(base) {
    if (state.league === 'ALL') return base;
    return base.filter(x => leagueOf(x) === state.league);
  }

  // ---------- render ----------
  function setMeta(txt) { const m = el('newsTickerMeta'); if (m) m.textContent = txt; }

  function renderAll() {
    const base = baseItems();
    renderLeagueChips(base);
    const vis = visibleItems(base);
    renderReel(vis);
    renderList(vis);

    const latest = vis.length ? relTime(vis[0].published_at) : '';
    const srcLbl = state.source === 'all' ? 'all sources' : state.source;
    setMeta(vis.length
      ? `${vis.length} items · ${srcLbl} · last ${state.windowHours}h${latest ? ' · updated ' + latest + ' ago' : ''}`
      : `no items · ${srcLbl} · last ${state.windowHours}h`);
  }

  function renderLeagueChips(base) {
    const wrap = el('newsLeagueChips');
    if (!wrap) return;
    const counts = new Map();
    base.forEach(it => { const l = leagueOf(it); counts.set(l, (counts.get(l) || 0) + 1); });
    const leagues = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);

    // Keep the active league selectable even if it dropped to 0 under a new filter.
    if (state.league !== 'ALL' && !counts.has(state.league)) leagues.push([state.league, 0]);

    let html = `<button class="ctrl-btn${state.league === 'ALL' ? ' is-active' : ''}" data-news-league="ALL">All ${base.length}</button>`;
    leagues.forEach(([lg, n]) => {
      html += `<button class="ctrl-btn${state.league === lg ? ' is-active' : ''}" data-news-league="${esc(lg)}">${esc(lg)} ${n}</button>`;
    });
    wrap.innerHTML = html;
  }

  // Per-item-type tag so a score / injury / standing is distinguishable at a
  // glance when sources are mixed under "All".
  const TYPE_TAG = {
    injury:      ['INJ', 'news-badge-inj'],
    score:       ['SCORE', 'news-badge-score'],
    standing:    ['W-L', 'news-badge-standing'],
    transaction: ['TXN', 'news-badge-txn'],
  };
  function badge(it) {
    const lg = leagueOf(it);
    const tag = it && TYPE_TAG[it.item_type];
    const extra = tag ? `<span class="news-badge ${tag[1]}">${tag[0]}</span>` : '';
    return `<span class="news-badge">${esc(lg)}</span>` + extra;
  }

  function renderReel(items) {
    const reel = el('newsTickerReel');
    if (!reel) return;
    if (!items.length) {
      reel.innerHTML = '<div class="empty">no headlines for this filter</div>';
      return;
    }
    const slice = items.slice(0, REEL_MAX);
    const itemHtml = slice.map(it => {
      const href = safeHref(it.url);
      const sub = hasSub(it)
        ? `<span class="news-src">${esc(it.team)}</span>` : '';
      return `<a class="news-reel-item" href="${href}" target="_blank" rel="noopener noreferrer">`
           + badge(it)
           + `<span class="news-reel-head">${esc(it.headline || '')}</span>`
           + sub
           + `<span class="news-reel-dot">•</span></a>`;
    }).join('');
    // Two copies → seamless -50% marquee loop. Pace by item count. Slower =
    // larger duration; ~4× the original (24s/3.4s-per-item) for an easier read
    // (halved the speed again per operator request 2026-07-02).
    const dur = Math.max(96, slice.length * 13.6);
    reel.innerHTML = `<div class="news-reel-track" style="animation-duration:${dur}s">${itemHtml}${itemHtml}</div>`;
  }

  function renderList(items) {
    const list = el('newsTickerList');
    if (!list) return;
    if (!items.length) { list.innerHTML = ''; return; }
    const rows = items.slice(0, LIST_MAX).map(it => {
      const href = safeHref(it.url);
      return `<div class="news-row">`
           + `<span class="news-time">${esc(relTime(it.published_at))}</span>`
           + badge(it)
           + `<span class="news-head"><a href="${href}" target="_blank" rel="noopener noreferrer">${esc(it.headline || '')}</a></span>`
           + `<span class="news-src">${esc(srcLabel(it))}</span>`
           + `</div>`;
    }).join('');
    list.innerHTML = rows;
  }

  // ---------- controls ----------
  let _searchTimer = null;

  function setActive(group, btn) {
    group.querySelectorAll('.ctrl-btn').forEach(b => b.classList.remove('is-active'));
    btn.classList.add('is-active');
  }

  function wireControls() {
    document.querySelectorAll('[data-news-src]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.source = btn.getAttribute('data-news-src');
        setActive(btn.parentElement, btn);
        renderAll();              // client-side, no re-fetch
      });
    });

    document.querySelectorAll('[data-news-win]').forEach(btn => {
      btn.addEventListener('click', () => {
        state.windowHours = parseInt(btn.getAttribute('data-news-win'), 10) || WINDOW_DEFAULT;
        setActive(btn.parentElement, btn);
        fetchNews();              // window is a server param → re-query
      });
    });

    // League chips are re-rendered each pass → delegate from the container.
    const chips = el('newsLeagueChips');
    if (chips) {
      chips.addEventListener('click', e => {
        const btn = e.target.closest('[data-news-league]');
        if (!btn) return;
        state.league = btn.getAttribute('data-news-league');
        renderAll();
      });
    }

    const search = el('newsSearch');
    if (search) {
      search.addEventListener('input', () => {
        clearTimeout(_searchTimer);
        _searchTimer = setTimeout(() => {
          state.search = search.value || '';
          state.league = 'ALL';   // reset league so a search isn't hidden by a stale chip
          renderAll();
        }, 180);
      });
    }
  }

  // ---------- init ----------
  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    wireControls();
    fetchNews();
    setInterval(() => {
      if (document.visibilityState === 'visible') fetchNews();
    }, REFRESH_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
