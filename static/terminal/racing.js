// D0 Terminal — Racing → Leagues redirect shim.
//
// Racing was merged into the Leagues hub on 2026-07-08 (one page across every
// ESPN-tracked league; racing series keep schedule + standings + results).
// This file used to hold the standalone racing page; it is now a redirect that
// preserves the old ?series=<s> deep-link param — leagues.js reads ?series= as
// a fallback, so racing.html?series=f1 → leagues.html?series=f1 lands on F1.
// The <meta http-equiv="refresh"> in racing.html is the no-JS fallback.

(function () {
  'use strict';
  var target = 'leagues.html' + (location.search || '');
  location.replace(target);
})();
