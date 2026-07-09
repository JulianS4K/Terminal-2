// Compare was folded into the performer stat-card gallery (2026-07-09).
// Redirect to performer.html, preserving ?ids=a,b,c so old compare deep-links
// still open the same comparison (performer.js restores the basket from ?ids).
(function () {
  'use strict';
  var ids = new URLSearchParams(location.search).get('ids');
  location.replace('performer.html' + (ids ? '?ids=' + encodeURIComponent(ids) : ''));
})();
