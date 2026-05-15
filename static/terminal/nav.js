// D0 Terminal — shared top-nav injector. Each page sets data-page on <body>;
// nav.js inserts the link row into the existing .topbar and marks the active.

(function () {
  'use strict';

  const PAGES = [
    { id: 'home',      label: 'HOME',      href: '/static/terminal/' },
    { id: 'event',     label: 'EVENT',     href: '/static/terminal/event.html' },
    { id: 'movers',    label: 'MOVERS',    href: '/static/terminal/movers.html' },
    { id: 'performer', label: 'PERFORMER', href: '/static/terminal/performer.html' },
    { id: 'orders',    label: 'ORDERS',    href: '/static/terminal/orders.html' },
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
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', inject);
  } else {
    inject();
  }
})();
