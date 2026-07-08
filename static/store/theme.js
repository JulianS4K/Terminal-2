// VibePass storefront — theme switch (Ivory Editorial default ⇄ dark).
//
// Loaded as a RENDER-BLOCKING script in each page's <head>, before style.css,
// so the theme attribute is set before first paint (no flash). The storefront
// defaults to the Ivory Editorial (light) look; a header toggle switches to the
// original dark theme and the choice persists in localStorage. Runs on every
// storefront page — including the ones that don't load store.js (chat, legal,
// error) — so it's a standalone, dependency-free IIFE.
//
// CSS lives in style.css: :root holds the dark tokens (base); the ivory palette
// is the [data-theme="ivory"] override scope. Pages ship with a static
// data-theme="ivory" attribute so no-JS visitors still get the default look;
// this script only flips it to dark when that's the stored preference.
(function () {
  "use strict";
  var KEY = "vp-theme";
  var DARK = "#0a0b0e";
  var IVORY = "#f4f1ea";

  function apply(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", theme === "dark" ? DARK : IVORY);
  }

  // Resolve the active theme: stored choice wins, otherwise the ivory default.
  var stored = null;
  try { stored = localStorage.getItem(KEY); } catch (e) { /* private mode */ }
  apply(stored === "dark" ? "dark" : "ivory");

  function label(theme) {
    return theme === "dark" ? "Switch to ivory theme" : "Switch to dark theme";
  }
  // Icon shows the theme you'd switch TO: moon while ivory, sun while dark.
  function icon(theme) { return theme === "dark" ? "☀" : "☾"; }

  function wire() {
    var btns = document.querySelectorAll(".theme-toggle");
    if (!btns.length) return;

    function refresh() {
      var cur = document.documentElement.getAttribute("data-theme") || "ivory";
      for (var i = 0; i < btns.length; i++) {
        btns[i].setAttribute("aria-label", label(cur));
        btns[i].setAttribute("aria-pressed", cur === "dark" ? "true" : "false");
        btns[i].title = label(cur);
        btns[i].textContent = icon(cur);
      }
    }

    function toggle() {
      var cur = document.documentElement.getAttribute("data-theme");
      var next = cur === "dark" ? "ivory" : "dark";
      apply(next);
      try { localStorage.setItem(KEY, next); } catch (e) { /* private mode */ }
      refresh();
    }

    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener("click", toggle);
    }
    refresh();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
