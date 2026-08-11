// D0 Terminal — shared top-nav injector. Each page sets data-page on <body>;
// nav.js inserts the link row into the existing .topbar and marks the active.

(function () {
  'use strict';

  // Relative hrefs so the same nav works under both deploy targets:
  // (a) localhost uvicorn at /static/terminal/, (b) Render static-site CDN
  // at root (publishPath strips static/terminal/). Each link is resolved
  // relative to the current page URL by the browser.
  // ← HUB target — the unified landing selector (Terminal / Undelivered /
  // Store / Bridge). The selector lives at static/home/index.html and is
  // served at `/home/` by an explicit FastAPI route (app.py) on the shell and
  // on localhost. On the static CDN (vibepass-terminal-test) the home subtree
  // is NOT reliably reachable at `/home/` — it depends on the wider
  // publishPath + directory-index serving that render-d0-terminal.yaml flags
  // as not-guaranteed-live, which is why HUB used to dead-end there. So mirror
  // app.js's API_BASE topology detection: from the CDN, send HUB cross-origin
  // to the always-on FastAPI shell that serves /home/ by construction.
  // Same-origin `/home/` everywhere else (shell + localhost).
  const HUB_HREF = location.hostname.includes('terminal-test')
    ? 'https://vibepass-storefront-test.onrender.com/home/'
    : '/home/';

  // FANTASY moved to its own D5 surface (served only by the FastAPI storefront
  // shell, not this static CDN). Same topology rule as HUB: from the terminal-
  // test CDN, deep-link cross-origin to the always-on shell; same-origin
  // `/fantasy/` everywhere else (shell + localhost).
  const FANTASY_HREF = location.hostname.includes('terminal-test')
    ? 'https://vibepass-storefront-test.onrender.com/fantasy/'
    : '/fantasy/';

  const PAGES = [
    // HOME below remains the terminal's mark-to-market dashboard (broker desk).
    { id: 'hub',       label: '← HUB',     href: HUB_HREF },
    { id: 'home',      label: 'HOME',      href: './' },
    { id: 'event',     label: 'EVENT',     href: 'event.html' },
    { id: 'venue',     label: 'VENUE',     href: 'venue.html' },
    { id: 'performer', label: 'PERFORMER', href: 'performer.html' },
    // (COMPARE folded into the performer stat-card gallery 2026-07-09 — the
    // landing grid has a compare basket; compare.html now redirects there.)
    // Sports data surfaces (ESPN pipelines). Leagues = one hub across every
    // ESPN-tracked league: team leagues (per-team demand + blind spots) plus
    // the merged racing series (F1 + NASCAR schedule + driver standings +
    // results). Fantasy = league browser over the fantasy engine.
    { id: 'leagues',   label: 'LEAGUES',   href: 'leagues.html' },
    // Fantasy was promoted to its own hub surface (D5, /fantasy/) — no longer a
    // terminal tab. The global search still deep-links to it (see below).
    { id: 'transactions', label: 'TRANSACTIONS', href: 'transactions.html' },
    // Trade Watch — "first to know when he trades": fuses the Kalshi next-team
    // market, a high-frequency Wikipedia team-hint poll, and the ESPN roster team
    // into one MOVED/WATCHING state per tracked player. Backed by get_trade_watch
    // (mig 20260714130000). Grouped by the transactions/movers "what moved" cluster.
    { id: 'trade-watch', label: 'TRADE WATCH', href: 'trade-watch.html' },
    // Cast Watch — Broadway twin of Trade Watch: shows with a detected Wikipedia
    // cast-section change (the theatre analog of a trade). Backed by get_cast_watch
    // (mig 20260714220000).
    { id: 'cast-watch', label: 'CAST WATCH', href: 'cast-watch.html' },
    { id: 'movers',    label: 'MOVERS',    href: 'movers.html' },
    // Deals — GoTickets BUYABLE deals, benchmarked against the OTHER sources'
    // prices (EVO/amalgam) for the same event×zone: a GoTickets listing priced
    // well below the cross-market zone median = an arbitrage opportunity. Zone is
    // the common key via derive_zone_fallback (both sides). GoTickets-exclusive
    // for now; the other sites are the metric, not the inventory. Sits in the
    // movers "what to trade" cluster. Wired 2026-08-11.
    { id: 'deals',     label: 'DEALS',     href: 'deals.html' },
    // Sales — realized-sales analytics per league + per team (home/away split,
    // owned-vs-market, price distribution, top sections). Backed by
    // /api/d0/sales/* over the d0_sales_fact snapshot. See docs/d0-sales-reports.md.
    { id: 'sales',     label: 'SALES',     href: 'sales.html' },
    // Retail chat — natural-language price/inventory lookups over the book
    // (full market on the terminal; owned-EVO-only on the storefront). Talks
    // to /api/retail-chat → the `chat` edge fn. Wired 2026-06-19.
    { id: 'retail-chat', label: 'RETAIL CHAT', href: 'retail-chat.html' },
    // Notebook — open-notebook port: notebooks, sources (text/URL/PDF), RAG
    // ask + chat over your sources, transformations, and podcast generation.
    // Backed by /api/notebook/* (open_notebook/ package + onb_* tables).
    { id: 'notebook', label: 'NOTEBOOK', href: 'notebook.html' },
    // Discovery — TEvo blindspot (broker selling, we own 0) + returning
    // performers/venues. Companion to Movers; same nav grouping for the
    // "what to watch" surface. Wired 2026-05-19 (PR A1 blindspot stack).
    { id: 'discovery', label: 'DISCOVERY', href: 'discovery.html' },
    // AXS — every event in the axs_events registry (PRIMARY box office) with
    // its latest snapshot get-in / price band / listing depth. Backed by
    // /api/axs/events (service-role read; axs_* tables are RLS-locked). 2026-06-20.
    { id: 'axs',       label: 'AXS',       href: 'axs.html' },
    // Paciolan / eVenue — every event captured from <tenant>.evenue.net (PRIMARY
    // box office), with face band + AQ mapping + the autonomous pull-loop health.
    // Browser twin of the AXS tab. Backed by /api/paciolan/events + /health
    // (service-role read; paciolan_* tables are RLS-locked). 2026-07-27.
    { id: 'paciolan',  label: 'PACIOLAN',  href: 'paciolan.html' },
    // Eventbrite — organizer events discovered via the TicketsData /events feed
    // (td_discovered_events, platform=eventbrite) with face price band +
    // sold-out / availability. Backed by /api/eventbrite/events (service-role
    // read; td_discovered_events is RLS-locked). 2026-07-08.
    { id: 'eventbrite', label: 'EVENTBRITE', href: 'eventbrite.html' },
    // Subs — substitution checker. Given a sold ticket (event/section/row/qty)
    // find the cheapest acceptable cover: same-section same-or-better row, then
    // a better-section fallback. Backed by /api/broker/event/{id}/substitutions.
    // Grouped with the discovery/axs tools cluster.
    { id: 'subs',      label: 'SUBS',      href: 'subs.html' },
    // Season Tix — is a season-ticket package worth buying vs assembling
    // comparable seats game-by-game? Per-seat package ask vs same-section,
    // row±band, pair-sellable cost across the team's regular-season home games
    // (getin & VWAP baselines). Major pro leagues only (NFL/NBA/MLB/NHL/MLS).
    // Backed by /api/broker/season-ticket-value. Wired 2026-07-09.
    { id: 'season-tickets', label: 'SEASON TIX', href: 'season-tickets.html' },
    { id: 'orders',    label: 'ORDERS',    href: 'orders.html' },
    { id: 'health',    label: 'HEALTH',    href: 'health.html' },
    // Help — the in-app onboarding guide + feature tour + glossary for
    // first-time operators (static/terminal/help.html). Kept last so it reads
    // as the always-available "lost? start here" tab. The full design brief for
    // the richer onboarding overlay lives in docs/d0_onboarding_guide.md.
    { id: 'help',      label: 'HELP',      href: 'help.html' },
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
      const rac     = d.racing      || [];
      const fan     = d.fantasy     || [];
      flat = [];
      if (!players.length && !evs.length && !perfs.length && !vens.length && !mkt.length && !rac.length && !fan.length) {
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
      // RACING — drivers (espn_racing_standings). Link to the series' standings
      // on the merged Leagues hub (racing folded in — was racing.html?series=).
      if (rac.length) {
        const SER = { 'nascar-cup': 'NASCAR Cup', 'nascar-xfinity': 'Xfinity',
                      'nascar-truck': 'Truck', 'f1': 'Formula 1' };
        parts.push('<div class="ts-section"><div class="ts-section-lbl">RACING</div>');
        rac.forEach(r => {
          const href = `leagues.html?league=${encodeURIComponent(r.series)}`;
          const meta = [SER[r.series] || r.series, r.rank ? 'P' + r.rank : '', r.points != null ? r.points + ' pts' : '']
            .filter(Boolean).join(' · ');
          flat.push({ href, label: r.driver_name, kind: 'racing' });
          parts.push(`<a class="ts-row" href="${href}" data-kind="racing">
              <span class="ts-name">${escapeHtml(r.driver_name || '(driver)')}</span>
              <span class="ts-meta">${escapeHtml(meta)}</span>
            </a>`);
        });
        parts.push('</div>');
      }
      // FANTASY — leagues (fantasy_leagues). Link to the fantasy tab, preselected.
      if (fan.length) {
        parts.push('<div class="ts-section"><div class="ts-section-lbl">FANTASY</div>');
        fan.forEach(f => {
          const href = `${FANTASY_HREF}?league=${encodeURIComponent(f.id)}`;
          const meta = [f.espn_league, (f.team_count != null ? f.team_count + ' teams' : '')].filter(Boolean).join(' · ');
          flat.push({ href, label: f.name, kind: 'fantasy' });
          parts.push(`<a class="ts-row" href="${href}" data-kind="fantasy">
              <span class="ts-name">${escapeHtml(f.name || '(league)')}</span>
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
  const escapeHtml = window.TermRender.escapeHtml;

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
