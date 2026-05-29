// relay.js  —  runs in the ISOLATED world (has chrome.* APIs; the MAIN-world
// inject_capture.js does not). It receives the window.postMessage emitted by
// inject_capture.js and forwards it to the service worker.

(() => {
  "use strict";
  window.addEventListener("message", (ev) => {
    // Only trust messages from this same page/window.
    if (ev.source !== window) return;
    const d = ev.data;
    if (!d || d.__bwy_capture__ !== true) return;
    try {
      chrome.runtime.sendMessage({
        type: "bwy_capture",
        url: d.url,
        method: d.method,
        requested_quantity: d.requested_quantity,
        captured_at: d.captured_at,
        payload: d.payload,
      });
    } catch (_) {
      // Service worker may be asleep mid-handshake; the next capture re-wakes it.
    }
  });
})();
