// D0 Terminal — shared top-nav injector. Each page sets data-page on <body>;
// nav.js inserts the link row into the existing .topbar and marks the active.

(function () {
  'use strict';

  // Relative hrefs so the same nav works under both deploy targets:
  // (a) localhost uvicorn at /static/terminal/, (b) Render static-site CDN
  // at root (publishPath strips static/terminal/). Each link is resolved
  // relative to the current page URL by the browser.
  const PAGES = [
    // ← HUB takes the operator back to the unified landing selector
    // (Terminal / Undelivered / Store / Bridge). Points at the explicit
    // `/home/` path — which serves static/home/index.html directly on the
    // static CDN (publishPath=static) without depending on the bare-`/`
    // root rewrite (not guaranteed live, see render-d0-terminal.yaml) AND
    // resolves on the FastAPI shell via the /home route (app.py). HOME
    // below remains the terminal's mark-to-market dashboard (broker desk).
    { id: 'hub',       label: '← HUB',     href: '/home/' },
    { id: 'home',      label: 'HOME',      href: './' },
    { id: 'event',     label: 'EVENT',     href: 'event.html' },
    { id: 'venue',     label: 'VENUE',     href: 'venue.html' },
    { id: 'performer', label: 'PERFORMER', href: 'performer.html' },
    { id: 'movers',    label: 'MOVERS',    href: 'movers.html' },
    // Retail chat — natural-language price/inventory lookups over the book
    // (full market on the terminal; owned-EVO-only on the storefront). Talks
    // to /api/retail-chat → the `chat` edge fn. Wired 2026-06-19.
    { id: 'retail-chat', label: 'RETAIL CHAT', href: 'retail-chat.html' },
    // Discovery — TEvo blindspot (broker selling, we own 0) + returning
    // performers/venues. Companion to Movers; same nav grouping for the
    // "what to watch" surface. Wired 2026-05-19 (PR A1 blindspot stack).
    { id: 'discovery', label: 'DISCOVERY', href: 'discovery.html' },
    // AXS — every event in the axs_events registry (PRIMARY box office) with
    // its latest snapshot get-in / price band / listing depth. Backed by
    // /api/axs/events (service-role read; axs_* tables are RLS-locked). 2026-06-20.
    { id: 'axs',       label: 'AXS',       href: 'axs.html' },
    // Subs — substitution checker. Given a sold ticket (event/section/row/qty)
    // find the cheapest acceptable cover: same-section same-or-better row, then
    // a better-section fallback. Backed by /api/broker/event/{id}/substitutions.
    // Grouped with the discovery/axs tools cluster.
    { id: 'subs',      label: 'SUBS',      href: 'subs.html' },
    { id: 'orders',    label: 'ORDERS',    href: 'orders.html' },
  ];

  function inject() {
    const topbar = document.querySelector('header.topbar');
    if (!topbar || topbar.querySelector('nav.pagenav')) return;

    const current = document.body.dataset.page || '';
    const nav = document.createElement('nav');
    nav.className = 'pagenav';
    nav.setAttribute('role', 'navigation');
    PAGES.forEach(p => {
      const a = document.createElement('a');
      a.href = p.href;
      a.textContent = p.label;
      a.dataset.nav = p.id;
      if (p.id === current) a.classList.add('active');
      nav.appendChild(a);
    });

    const status = topbar.querySelector('#status');
    if (status) topbar.insertBefore(nav, status);
    else topbar.appendChild(nav);

    injectSearchBox(topbar);
    injectVersionChip(topbar);
    injectAuthControl(topbar);
  }

  // ---------- Global terminal search ----------
  //
  // Topbar search input, available on every terminal page (via nav.js).
  // Calls `terminal_search` SECDEF RPC (mig 20260517230000, players added v3
  // mig 20260617120000) and renders a dropdown — Players (sports: athlete →
  // team → upcoming events) / Events / Performers / Venues / Marketplace.
  //
  // Keyboard: type-to-search (300ms debounce), ↑/↓ to navigate suggestions,
  // Enter to follow first/selected result, Esc closes. Click-outside closes.
  //
  // Localhost dev (no Path C auth) gets a degraded "search unavailable"
  // hint when the user focuses the input.
  function injectSearchBox(topbar) {
    if (topbar.querySelector('.term-search')) return;
    const wrap = document.createElement('div');
    wrap.className = 'term-search';
    wrap.innerHTML = `
      <input type="search" class="term-search-input" placeholder="Search players / events / performers / venues…" autocomplete="off" spellcheck="false" />
      <div class="term-search-suggest" hidden></div>`;
    // Insert before version chip / auth ctrl / status. Use the .pagenav as
    // anchor — search slots immediately after the nav links.
    const nav = topbar.querySelector('nav.pagenav');
    if (nav && nav.nextSibling) topbar.insertBefore(wrap, nav.nextSibling);
    else if (nav) topbar.appendChild(wrap);
    else topbar.appendChild(wrap);

    const input = wrap.querySelector('.term-search-input');
    const sugg  = wrap.querySelector('.term-search-suggest');
    let debounceT = 0;
    let lastQ = '';
    let activeIdx = -1;
    let flat = []; // flat list of {href, label, kind} for keyboard nav

    function close() {
      sugg.setAttribute('hidden', '');
      activeIdx = -1;
      updateActive();
    }
    function open() { sugg.removeAttribute('hidden'); }
    function updateActive() {
      [...sugg.querySelectorAll('.ts-row')].forEach((r, i) => {
        r.classList.toggle('active', i === activeIdx);
      });
    }
    function follow(idx) {
      if (idx < 0 || idx >= flat.length) return;
      window.location.href = flat[idx].href;
    }

    async function runSearch(q) {
      if (q === lastQ) return;
      lastQ = q;
      if (q.length < 2) { close(); return; }
      const Auth = window.TerminalAuth;
      if (!Auth || !Auth.client || !Auth.getAccessToken()) {
        sugg.innerHTML = '<div class="ts-empty">search needs auth — sign in with @s4kent.com</div>';
        open();
        return;
      }
      sugg.innerHTML = '<div class="ts-empty">searching…</div>';
      open();
      const res = await Auth.client.rpc('terminal_search', { p_q: q, p_limit: 6 });
      if (res.error) {
        const msg = res.error.message || 'search RPC error';
        // 42883 = function does not exist (migration not yet applied)
        const friendly = res.error.code === '42883'
          ? 'search RPC not deployed yet — pending migration 20260517230000'
          : msg;
        sugg.innerHTML = `<div class="ts-empty err">${escapeHtml(friendly)}</div>`;
        return;
      }
      const d = res.data || {};
      renderResults(d);
    }

    function renderResults(d) {
      const players = d.players     || [];
      const evs     = d.events      || [];
      const perfs   = d.performers  || [];
      const vens    = d.venues      || [];
      const mkt     = d.marketplace || [];
      flat = [];
      if (!players.length && !evs.length && !perfs.length && !vens.length && !mkt.length) {
        sugg.innerHTML = `<div class="ts-empty">no matches for &ldquo;${escapeHtml(d.q || '')}&rdquo;</div>`;
        return;
      }
      const parts = [];
      // PLAYERS — ESPN athlete → mapped TEvo team performer → upcoming events.
      // The headline sports-search feature: typing a player name surfaces their
      // team and the team's next games. Player head links to the performer page;
      // each nested event row links to that event's page.
      if (players.length) {
        parts.push('<div class="ts-section"><div class="ts-section-lbl">PLAYERS</div>');
        players.forEach(pl => {
          const teamHref = pl.tevo_performer_id != null
            ? `performer.html?performer=${pl.tevo_performer_id}` : '#';
          const bits = [pl.jersey ? '#' + pl.jersey : '', pl.position_abbr].filter(Boolean).join(' · ');
          const teamMeta = [pl.team_name, pl.espn_league].filter(Boolean).join(' · ');
          const inj = pl.latest_injury && pl.latest_injury.status
            ? `<span class="ts-inj">${escapeHtml(pl.latest_injury.status)}</span>` : '';
          flat.push({ href: teamHref, label: pl.full_name, kind: 'player' });
          parts.push(`<a class="ts-row ts-player-head" href="${teamHref}" data-kind="player">
              <span class="ts-name">${escapeHtml(pl.full_name || '(unknown)')}${bits ? ` <span class="ts-sub">${escapeHtml(bits)}</span>` : ''}${inj}</span>
              <span class="ts-meta">${escapeHtml(teamMeta)}</span>
            </a>`);
          (pl.events || []).forEach(e => {
            const href = `event.html?event=${e.tevo_event_id}`;
            const meta = [e.venue_name, fmtDateShort(e.occurs_at_local)].filter(Boolean).join(' · ');
            flat.push({ href, label: e.name, kind: 'event' });
            parts.push(`<a class="ts-row ts-player-event" href="${href}" data-kind="event">
                <span class="ts-name">${escapeHtml(e.name || '(unnamed)')}</span>
                <span class="ts-meta">${escapeHtml(meta)}</span>
              </a>`);
          });
        });
        parts.push('</div>');
      }
      if (evs.length) {
        parts.push('<div class="ts-section"><div class="ts-section-lbl">EVENTS</div>');
        evs.forEach(e => {
          const href = `event.html?event=${e.tevo_event_id}`;
          const meta = [e.venue_name, fmtDateShort(e.occurs_at_local)].filter(Boolean).join(' · ');
          flat.push({ href, label: e.name, kind: 'event' });
          parts.push(`<a class="ts-row" href="${href}" data-kind="event">
              <span class="ts-name">${escapeHtml(e.name || '(unnamed)')}</span>
              <span class="ts-meta">${escapeHtml(meta)}</span>
            </a>`);
        });
        parts.push('</div>');
      }
      if (perfs.length) {
        parts.push('<div class="ts-section"><div class="ts-section-lbl">PERFORMERS</div>');
        perfs.forEach(p => {
          const href = `performer.html?performer=${p.tevo_performer_id}`;
          flat.push({ href, label: p.performer_name, kind: 'performer' });
          parts.push(`<a class="ts-row" href="${href}" data-kind="performer">
              <span class="ts-name">${escapeHtml(p.performer_name || '(unnamed)')}</span>
              <span class="ts-meta">${escapeHtml(p.category || '')}</span>
            </a>`);
        });
        parts.push('</div>');
      }
      if (vens.length) {
        parts.push('<div class="ts-section"><div class="ts-section-lbl">VENUES</div>');
        vens.forEach(v => {
          const href = `venue.html?venue=${v.tevo_venue_id}`;
          const meta = [v.city, v.state].filter(Boolean).join(', ');
          flat.push({ href, label: v.venue_name, kind: 'venue' });
          parts.push(`<a class="ts-row" href="${href}" data-kind="venue">
              <span class="ts-name">${escapeHtml(v.venue_name || '(unnamed)')}</span>
              <span class="ts-meta">${escapeHtml(meta)}</span>
            </a>`);
        });
        parts.push('</div>');
      }
      if (mkt.length) {
        // Marketplace events discovered via TicketsData /events that we don't
        // track locally yet. No internal page to link to — open the buy URL.
        parts.push('<div class="ts-section"><div class="ts-section-lbl">MARKETPLACE</div>');
        mkt.forEach(m => {
          // Scheme-validate the third-party URL: TicketsData supplies
          // event_url verbatim — only http(s) may reach an href (blocks
          // javascript:/data: if the feed is ever compromised).
          const href = /^https?:\/\//i.test(m.event_url || '') ? m.event_url : '#';
          const meta = [m.platform, m.venue_name, fmtDateShort(m.event_date)].filter(Boolean).join(' · ');
          flat.push({ href, label: m.event_name, kind: 'marketplace' });
          const ext = href !== '#' ? ' target="_blank" rel="noopener"' : '';
          parts.push(`<a class="ts-row" href="${escapeHtml(href)}"${ext} data-kind="marketplace">
              <span class="ts-name">${escapeHtml(m.event_name || '(unnamed)')}</span>
              <span class="ts-meta">${escapeHtml(meta)}</span>
            </a>`);
        });
        parts.push('</div>');
      }
      sugg.innerHTML = parts.join('');
      activeIdx = flat.length ? 0 : -1;
      updateActive();
    }

    input.addEventListener('input', () => {
      clearTimeout(debounceT);
      const q = input.value.trim();
      debounceT = setTimeout(() => runSearch(q), 250);
    });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { input.blur(); close(); return; }
      if (e.key === 'Enter') { e.preventDefault(); follow(activeIdx); return; }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        if (!flat.length) return;
        activeIdx = (activeIdx + (e.key === 'ArrowDown' ? 1 : -1) + flat.length) % flat.length;
        updateActive();
        const row = sugg.querySelectorAll('.ts-row')[activeIdx];
        if (row && row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
      }
    });
    input.addEventListener('focus', () => {
      if (lastQ.length >= 2 && sugg.innerHTML) open();
    });
    document.addEventListener('click', (e) => {
      if (!wrap.contains(e.target)) close();
    });

    // '/' shortcut focuses the search anywhere — only when not already in
    // an input/textarea, so it doesn't hijack page-level typing.
    document.addEventListener('keydown', (e) => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
      e.preventDefault();
      input.focus();
      input.select();
    });
  }

  function fmtDateShort(iso) {
    if (!iso) return '';
    try {
      return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    } catch (_) { return ''; }
  }
  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;',
    }[c]));
  }

  // ---------- Deploy version chip ----------
  //
  // Operator request 2026-05-17: visible version indicator on every page so
  // they can distinguish which deploy a tab is on at a glance — independent
  // of URL bar (might show terminal-test vs storefront-test vs Railway) and
  // data shown (might be cached or stale).
  //
  // Detection cascade — each layer covers a different deploy topology:
  //   1. <meta name="x-app-version" content="..."> in HTML
  //      (server-side rendered; FastAPI shell could swap "dev" → SHA in
  //      _read_storefront_html; not wired yet for terminal pages)
  //   2. Any script tag with `?v=<sha>` cache-bust query suffix — that's
  //      what _read_storefront_html (app.py:73-97) injects on FastAPI shell
  //      deploys. Works on storefront-test + Railway today.
  //   3. Any stylesheet with `?v=<sha>` — same fallback.
  //   4. Render-CDN-only fetch of /version.json (added by future build
  //      step that writes RENDER_GIT_COMMIT to disk). Until that ships,
  //      CDN shows "dev" — that's an honest signal the CDN HTML wasn't
  //      rewritten through the cache-bust pipeline.
  //
  // The chip displays `v:<first-7-of-sha>` with a hover title showing the
  // full SHA + the deploy hostname so the operator can copy/diff.
  function injectVersionChip(topbar) {
    const status = topbar.querySelector('#status');
    const chip = document.createElement('span');
    chip.className = 'version-chip muted small';
    chip.textContent = 'v:dev';
    chip.title = `host: ${location.hostname}\nversion: dev (no cache-bust suffix found)`;
    if (status) topbar.insertBefore(chip, status);
    else topbar.appendChild(chip);
    const v = detectVersion();
    if (v) {
      chip.textContent = 'v:' + v.slice(0, 7);
      chip.title = `host: ${location.hostname}\nversion: ${v}`;
    } else {
      // Async fallback — fetch /version.json from same origin (cheap,
      // ~5ms warm). Works on FastAPI-shell deploys (storefront-test +
      // Railway) where terminal HTML is served verbatim without a
      // cache-bust suffix to detect synchronously. Static CDN doesn't
      // have this endpoint → chip stays "v:dev" which is the honest
      // signal ("this came from CDN bytes, not the FastAPI shell").
      fetch('/version.json', { credentials: 'omit' })
        .then(r => r.ok ? r.json() : null)
        .then(j => {
          if (!j || !j.version || j.version === 'dev') return;
          chip.textContent = 'v:' + String(j.version).slice(0, 7);
          chip.title = `host: ${location.hostname}\nversion: ${j.version}` +
            (j.render_external_url ? `\nrender: ${j.render_external_url}` : '') +
            (j.railway_public_domain ? `\nrailway: ${j.railway_public_domain}` : '');
        })
        .catch(() => { /* chip stays "v:dev" — acceptable degraded state */ });
    }
  }

  function detectVersion() {
    // 1. Meta tag (future-proof — FastAPI shell can render this)
    const meta = document.querySelector('meta[name="x-app-version"]');
    if (meta && meta.content && meta.content !== 'dev' && meta.content !== '') {
      return meta.content;
    }
    // 2. Script src ?v=<sha>
    for (const s of document.scripts) {
      const m = (s.src || '').match(/[?&]v=([^&#]+)/);
      if (m && m[1] !== 'dev') return decodeURIComponent(m[1]);
    }
    // 3. Stylesheet href ?v=<sha>
    for (let i = 0; i < document.styleSheets.length; i++) {
      try {
        const href = document.styleSheets[i].href || '';
        const m = href.match(/[?&]v=([^&#]+)/);
        if (m && m[1] !== 'dev') return decodeURIComponent(m[1]);
      } catch (_) { /* cross-origin stylesheet access throws — ignore */ }
    }
    // 4. Link tag ?v=<sha> (fallback for stylesheets that haven't loaded)
    const links = document.querySelectorAll('link[rel="stylesheet"]');
    for (const l of links) {
      const m = (l.href || '').match(/[?&]v=([^&#]+)/);
      if (m && m[1] !== 'dev') return decodeURIComponent(m[1]);
    }
    return null;
  }

  function injectAuthControl(topbar) {
    if (!window.TerminalAuth) return;
    const status = topbar.querySelector('#status');
    const wrap = document.createElement('span');
    wrap.className = 'auth-ctrl';
    wrap.innerHTML = '<span class="auth-email muted small"></span> <a href="#" class="auth-signout">sign out</a>';
    if (status) topbar.insertBefore(wrap, status);
    else topbar.appendChild(wrap);

    const emailEl = wrap.querySelector('.auth-email');
    const signoutEl = wrap.querySelector('.auth-signout');
    signoutEl.addEventListener('click', e => {
      e.preventDefault();
      window.TerminalAuth.signOut();
    });

    window.TerminalAuth.ready.then(() => {
      const email = window.TerminalAuth.getEmail();
      if (email) {
        emailEl.textContent = email;
      } else {
        emailEl.textContent = 'not signed in';
        signoutEl.style.display = 'none';
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', inject);
  } else {
    inject();
  }
})();
