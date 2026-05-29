// inject_capture.js  —  runs in the page's MAIN world at document_start.
//
// Broadway.com (2026-05-24 redesign) loads per-performance inventory from an
// async POST to /{slug}/{show_id}/{event_id}/sections/ that returns JSON
// {status, data:{event_id, tickets:[…]}}. That POST is minted by the page's
// own JS (Fastly challenge solved + reCAPTCHA Enterprise token + session
// CSRF). We do NOT issue it — we only TEE the RESPONSE of the page's own
// call (RULE 2: read-only; we never originate a write to broadway.com).
//
// We patch fetch + XMLHttpRequest before the app code runs, capture the
// JSON body of the sections POST, and postMessage it to the isolated-world
// relay (relay.js), which forwards to the service worker.

(() => {
  "use strict";
  const ORIGIN = location.origin;

  function isSectionsUrl(u) {
    try {
      const x = new URL(u, location.href);
      return x.hostname === "checkout.broadway.com" &&
             /\/sections\/?$/.test(x.pathname);
    } catch (_) {
      return false;
    }
  }

  // Pull quantity=<n> out of the urlencoded request body so we can tag which
  // block-size this availability response is for.
  function extractQty(body) {
    try {
      if (typeof body === "string") {
        const m = body.match(/(?:^|&)quantity=(\d+)/);
        return m ? parseInt(m[1], 10) : null;
      }
      if (body instanceof URLSearchParams) {
        const v = body.get("quantity");
        return v != null ? parseInt(v, 10) : null;
      }
    } catch (_) {}
    return null;
  }

  function emit(payload, url, method, qty) {
    try {
      window.postMessage({
        __bwy_capture__: true,
        url: String(url),
        method: String(method || "").toUpperCase(),
        requested_quantity: qty,
        captured_at: new Date().toISOString(),
        payload: payload,
      }, ORIGIN);
    } catch (_) {}
  }

  // ---- patch fetch ----
  const origFetch = window.fetch;
  if (typeof origFetch === "function") {
    window.fetch = function (input, init) {
      const p = origFetch.apply(this, arguments);
      try {
        const url = (typeof input === "string") ? input : (input && input.url);
        const method = (init && init.method) || (input && input.method) || "GET";
        if (url && isSectionsUrl(url) && String(method).toUpperCase() === "POST") {
          const qty = extractQty(init && init.body);
          p.then((res) => {
            // Only JSON responses carry inventory; the bootstrap GET is HTML
            // (and is a GET, already excluded). clone() so the app still reads it.
            res.clone().json().then((j) => emit(j, url, method, qty)).catch(() => {});
          }).catch(() => {});
        }
      } catch (_) {}
      return p;
    };
  }

  // ---- patch XMLHttpRequest ----
  const XP = XMLHttpRequest.prototype;
  const origOpen = XP.open;
  const origSend = XP.send;
  XP.open = function (method, url) {
    this.__bwy_method = method;
    this.__bwy_url = url;
    return origOpen.apply(this, arguments);
  };
  XP.send = function (body) {
    try {
      if (this.__bwy_url && isSectionsUrl(this.__bwy_url) &&
          String(this.__bwy_method).toUpperCase() === "POST") {
        const qty = extractQty(body);
        this.addEventListener("load", function () {
          try {
            const ct = (this.getResponseHeader &&
                        this.getResponseHeader("content-type")) || "";
            if (ct.includes("json")) {
              emit(JSON.parse(this.responseText), this.__bwy_url, this.__bwy_method, qty);
            }
          } catch (_) {}
        });
      }
    } catch (_) {}
    return origSend.apply(this, arguments);
  };
})();
