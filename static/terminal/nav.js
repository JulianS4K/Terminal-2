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

    injectAuthControl(topbar);
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
