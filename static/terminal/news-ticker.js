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
//   * Broadway  — broadway_cast_run + v_broadway_performer_getin (current
//                 headliner per tracked show, always shown + get-in metric) and
//                 broadway_cast_pull_log flags (daily cast-poll change detection,
//                 mig 20260704160000). item_type='cast'; CAST tag; `team` = show
//                 title. Broadway analogue of the injury report.
//   * Fed       — macro_indicators (FRED macro releases: FEDFUNDS Fed policy
//                 rate, UMCSENT sentiment, mig 20260705120000). item_type='macro';
//                 FED tag. Window-gated on WHEN the reading first landed in our
//                 store — a new print flashes at the top, then ages out, so the
//                 wire surfaces the Fed only when it actually updates.
//   * X         — v_x_news_ticker (TwitterAPI.io advanced-search pipeline, mig
//                 20260706114500 — reddit mechanics: roster + pg_net queue,
//                 48h, deduped first-post-shows). INERT until the operator
//                 creates vault.TWITTERAPI_IO_KEY + enables roster rows. Each
//                 row carries `team` = '@<author>' for attribution.
//                 item_type='x_post'; X tag.
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
  // fetch would drop them entirely and leave their toggles empty. Raised
  // 300 → 500 with the X feeds live (10 sources now share the newest-first
  // window; mig 20260707210000 raised the RPC clamp to match) so every source
  // stays represented under the All view + client-side filters.
  const FETCH_LIMIT    = 500;      // rows pulled per query (newest-first; RPC cap)
  const REEL_MAX       = 30;       // headlines in the scrolling marquee
  const LIST_MAX       = 25;       // rows in the readable list
  const REFRESH_MS     = 180000;   // 3 min auto-refresh

  const state = {
    items:       [],
    source:      'all',            // 'all' | 'ESPN' | 'Transactions' | 'Injuries' | 'Scores' | 'Standings' | 'Reddit' | 'Broadway' | 'Fed' | 'X'
    windowHours: WINDOW_DEFAULT,   // 24 | 48 | 168
    league:      'ALL',
    category:    'ALL',            // X-source secondary facet (mirrors league for ESPN)
    search:      '',
    loading:     false,
    xCat:        Object.create(null),  // handle(lower, de-@'d) -> category, from get_x_news_categories
  };

  // Human labels for the X-account category buckets (raw values come from
  // important_x_accounts.category, normalized server-side in get_x_news_categories).
  const CAT_LABEL = {
    sports:                 'Sports',
    entertainment_concerts: 'Concerts',
    entertainment_broadway: 'Broadway',
    other:                  'Other',
  };
  const catLabel = c => CAT_LABEL[c] || c;

  // ---------- helpers ----------
  const esc = window.TermRender.escapeHtml;

  // Feed-derived URLs are untrusted: escaping alone does not stop a
  // `javascript:`/`data:` scheme from becoming click-to-execute in an href.
  // Allow only http(s); anything else collapses to a dead '#'.
  const safeHref = window.TermRender.safeHref;

  // Ticker rows now carry INTERNAL relative links for mapped items
  // (performer.html?…, player.html?…) alongside external http(s) article URLs.
  // Internal links open same-tab (stay in the terminal); external open new-tab.
  // The strict pattern (a `<page>.html` with a query of safe chars) is itself
  // the injection guard for the relative branch — no scheme can slip through.
  const INTERNAL_RE = /^[\w-]+\.html(?:\?[\w=&%.-]+)?$/i;
  function linkAttrs(url) {
    const u = (url || '').trim();
    if (INTERNAL_RE.test(u)) return { href: u, ext: false };
    return { href: safeHref(u), ext: true };
  }

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

  // X-post category: derived from the account roster (get_x_news_categories) via
  // the post's `team` = '@<author_handle>'. Unmapped handles bucket as 'other'
  // (also the honest fallback when the roster RPC isn't applied to prod yet).
  const catOf = it => {
    if (!it) return 'other';
    const h = (it.team || '').replace(/^@/, '').toLowerCase();
    return state.xCat[h] || 'other';
  };

  // Source label: for Reddit rows show the originating sub ('r/<sub>', carried
  // in `team`); for X rows the author handle ('@<user>', same slot); for
  // injury rows show the affected team; otherwise the plain source name.
  const srcLabel = it => {
    if (!it) return '';
    if (it.source === 'Reddit' && it.team) return it.team;
    if (it.source === 'X' && it.team) return it.team;             // '@<handle>'
    if (it.source === 'Injuries') return it.team || 'Injuries';
    if (it.source === 'Broadway') return it.team || 'Broadway';   // show title
    return it.source || '';
  };

  // A story carried under a byline (Reddit sub, X author handle, injured
  // player's team, or Broadway show title) gets a secondary source line in the reel.
  const hasSub = it => !!(it && it.team && (it.source === 'Reddit' || it.source === 'X' || it.source === 'Injuries' || it.source === 'Broadway'));

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

  // One-shot load of the X-account category map (handle → category). Powers the
  // X-source CATEGORY facet. Best-effort: on any error (incl. RPC not applied
  // yet) the map stays empty and X posts bucket under 'Other' — no crash.
  async function fetchXCategories() {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) return;
    try {
      const res = await Auth.client.rpc('get_x_news_categories');
      if (res.error || !Array.isArray(res.data)) return;
      const map = Object.create(null);
      res.data.forEach(r => { if (r && r.handle) map[String(r.handle).toLowerCase()] = r.category || 'other'; });
      state.xCat = map;
    } catch (_) { /* leave map empty → 'other' bucket */ }
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

  // The active secondary facet depends on source: X → category, else → league.
  function visibleItems(base) {
    if (state.source === 'X') {
      if (state.category === 'ALL') return base;
      return base.filter(x => catOf(x) === state.category);
    }
    if (state.league === 'ALL') return base;
    return base.filter(x => leagueOf(x) === state.league);
  }

  // ---------- render ----------
  function setMeta(txt) { const m = el('newsTickerMeta'); if (m) m.textContent = txt; }

  // Show the league facet for every source except X, which gets the category
  // facet instead — the same "click source → reveals a second filter" pattern.
  function syncFacetGroups() {
    const isX = state.source === 'X';
    const lg = el('newsLeagueGroup'), cat = el('newsCategoryGroup');
    if (lg)  lg.hidden  = isX;
    if (cat) cat.hidden = !isX;
  }

  function renderAll() {
    const base = baseItems();
    syncFacetGroups();
    if (state.source === 'X') renderCategoryChips(base);
    else                      renderLeagueChips(base);
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

  // X-source CATEGORY chips — the league-facet analogue for X posts. Faceted
  // with live counts over the source-narrowed base, same as renderLeagueChips.
  function renderCategoryChips(base) {
    const wrap = el('newsCategoryChips');
    if (!wrap) return;
    const counts = new Map();
    base.forEach(it => { const c = catOf(it); counts.set(c, (counts.get(c) || 0) + 1); });
    const cats = Array.from(counts.entries()).sort((a, b) => b[1] - a[1]);

    // Keep the active category selectable even if it dropped to 0 under a new filter.
    if (state.category !== 'ALL' && !counts.has(state.category)) cats.push([state.category, 0]);

    let html = `<button class="ctrl-btn${state.category === 'ALL' ? ' is-active' : ''}" data-news-cat="ALL">All ${base.length}</button>`;
    cats.forEach(([c, n]) => {
      html += `<button class="ctrl-btn${state.category === c ? ' is-active' : ''}" data-news-cat="${esc(c)}">${esc(catLabel(c))} ${n}</button>`;
    });
    wrap.innerHTML = html;
  }

  // Per-item-type tag so a score / injury / standing is distinguishable at a
  // glance when sources are mixed under "All".
  const TYPE_TAG = {
    injury:   ['INJ', 'news-badge-inj'],
    score:    ['SCORE', 'news-badge-score'],
    standing: ['W-L', 'news-badge-standing'],
    transaction: ['TXN', 'news-badge-txn'],
    cast:     ['CAST', 'news-badge-cast'],
    macro:    ['FED', 'news-badge-fed'],
    x_post:   ['X', 'news-badge-x'],
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
      const { href, ext } = linkAttrs(it.url);
      const tgt = ext ? ' target="_blank" rel="noopener noreferrer"' : '';
      const sub = hasSub(it)
        ? `<span class="news-src">${esc(it.team)}</span>` : '';
      return `<a class="news-reel-item" href="${esc(href)}"${tgt}>`
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
      const { href, ext } = linkAttrs(it.url);
      const tgt = ext ? ' target="_blank" rel="noopener noreferrer"' : '';
      return `<div class="news-row">`
           + `<span class="news-time">${esc(relTime(it.published_at))}</span>`
           + badge(it)
           + `<span class="news-head"><a href="${esc(href)}"${tgt}>${esc(it.headline || '')}</a></span>`
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
        // Reset both secondary facets so a stale league/category chip can't
        // hide rows after a source switch.
        state.league = 'ALL';
        state.category = 'ALL';
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

    // Category chips (X source) — same delegated pattern as league chips.
    const catChips = el('newsCategoryChips');
    if (catChips) {
      catChips.addEventListener('click', e => {
        const btn = e.target.closest('[data-news-cat]');
        if (!btn) return;
        state.category = btn.getAttribute('data-news-cat');
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
    fetchXCategories();   // load the X category map (best-effort, parallel with news)
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
