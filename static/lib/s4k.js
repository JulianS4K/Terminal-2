// SPDX-License-Identifier: MIT
// Copyright (c) 2026 S4Kent. Licensed under the MIT License (see static/lib/LICENSE).
//
// S4K — canonical cross-surface frontend lib (window.S4K).
//
// Coding-recommendation #4: escapeHtml existed 5×, a scheme-safe href builder
// and XFF/DOM boilerplate more times still — every copy a future chance for one
// to drift or be missed on a new render path. This is the single source, shared
// by every surface (store / home / dashboard / terminal), and the ESLint rule
// (eslint.config.js) BANS raw `innerHTML` / `outerHTML` / `insertAdjacentHTML`
// assignment everywhere except this file — turning per-line escaping discipline
// into a structural guarantee.
//
// (The D0 terminal shipped `window.TermRender` first with the same esc/safeHref
// pair; S4K is that fix generalized cross-surface. New surfaces use S4K; the
// terminal converges onto it as pages are touched.)
//
// Load before any page script: <script src="/static/lib/s4k.js"></script>.
// A page that renders untrusted strings but forgets the include fails loudly
// (S4K is undefined) rather than silently emitting unescaped HTML.
(function () {
  'use strict';

  // HTML-escape a value for safe interpolation into markup. null/undefined → ''.
  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // User-/feed-derived URLs are untrusted: escaping alone doesn't stop a
  // `javascript:` / `data:` / `vbscript:` scheme (or a leading-whitespace/case
  // bypass) from becoming click-to-execute in an href. Allow only http(s);
  // anything else collapses to a dead '#'. Legit URLs are still HTML-escaped.
  function safeHref(u) {
    if (!u) return '#';
    return /^https?:\/\//i.test(String(u).trim()) ? esc(u) : '#';
  }

  // --- DOM helpers: build nodes without touching innerHTML -------------------

  // Create an element with attributes + children. children may be strings
  // (become TEXT nodes — auto-escaped by the DOM) or nodes.
  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
        const v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') node.className = v;
        else if (k === 'text') node.textContent = v;
        else if (k === 'href') node.setAttribute('href', safeHref(v));
        else if (k.slice(0, 2) === 'on' && typeof v === 'function') {
          node.addEventListener(k.slice(2), v);
        } else node.setAttribute(k, v);
      }
    }
    for (const child of [].concat(children == null ? [] : children)) {
      if (child === null || child === undefined || child === false) continue;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    }
    return node;
  }

  // Remove all children of a node (the safe alternative to `node.innerHTML = ''`).
  function clear(node) {
    while (node && node.firstChild) node.removeChild(node.firstChild);
    return node;
  }

  // Set the text content of a node (never HTML — auto-escaped).
  function setText(node, s) {
    if (node) node.textContent = s == null ? '' : String(s);
    return node;
  }

  // The ONE sanctioned raw-HTML sink. Every other site must build nodes (el /
  // setText) or interpolate through esc(). Callers pass markup they have
  // themselves escaped with esc(); this centralizes the single unavoidable
  // innerHTML write so the ESLint ban can be universal everywhere else.
  function setTrustedHTML(node, html) {
    // eslint-disable-next-line no-restricted-properties -- the sanctioned sink
    if (node) node.innerHTML = html == null ? '' : String(html);
    return node;
  }

  window.S4K = { esc, safeHref, el, clear, setText, setTrustedHTML };
})();
