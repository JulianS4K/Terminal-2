// D0 Terminal — shared render helpers (window.TermRender).
//
// Single source for HTML-escaping + URL-scheme validation. Previously each
// page script carried its own copy-pasted escapeHtml/esc — 12 identical
// definitions, i.e. 12 future chances for one to drift or be missed on a new
// render path. Centralizing turns per-file escaping discipline into a
// structural guarantee.
//
// Loaded on every terminal page via `<script src="lib/render.js">`, placed
// right after lib/supabase.js so it is defined before auth.js / app.js /
// nav.js / the per-page script run. A page that renders untrusted strings but
// forgets this include fails loudly (esc is undefined) rather than silently
// emitting unescaped HTML — a hard failure is the safe failure here.
(function () {
  'use strict';

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // Feed-/user-derived URLs are untrusted: escaping alone does not stop a
  // `javascript:`/`data:`/`vbscript:` scheme (or a leading-whitespace/case
  // bypass) from becoming click-to-execute in an href. Allow only http(s);
  // anything else collapses to a dead '#'. Legit URLs still get HTML-escaped.
  function safeHref(u) {
    if (!u) return '#';
    return /^https?:\/\//i.test(String(u).trim()) ? escapeHtml(u) : '#';
  }

  window.TermRender = { escapeHtml, safeHref };
})();
