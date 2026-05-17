// D0 Terminal — shared top-nav injector. Each page sets data-page on <body>;
// nav.js inserts the link row into the existing .topbar and marks the active.

(function () {
  'use strict';

  // Relative hrefs so the same nav works under both deploy targets:
  // (a) localhost uvicorn at /static/terminal/, (b) Render static-site CDN
  // at root (publishPath strips static/terminal/). Each link is resolved
  // relative to the current page URL by the browser.
  const PAGES = [
    { id: 'home',      label: 'HOME',      href: './' },
    { id: 'event',     label: 'EVENT',     href: 'event.html' },
    { id: 'movers',    label: 'MOVERS',    href: 'movers.html' },
    { id: 'performer', label: 'PERFORMER', href: 'performer.html' },
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

    injectVersionChip(topbar);
    injectAuthControl(topbar);
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
