/*
 * Exos venue embed loader. Paste on any site:
 *
 *   <div data-exos-event="EVENT_ID"></div>
 *   <script src="https://<exos host>/bridge/embed.js" async></script>
 *
 * Turns each [data-exos-event] div into an iframe of /embed/event/:id (event
 * card, ticket picker and Stripe checkout, all inside the iframe), sizes it to
 * its content, and fires a bubbling "exos:checkout-complete" DOM event on the
 * div when a purchase finishes (detail: { eventId, sessionId }).
 *
 * Messages are only accepted from the Exos origin this script was loaded from
 * AND from that div's own iframe. Plain ES5, no dependencies. Keep in sync
 * with src/lib/embed.ts (message types, validation).
 */
(function (w, d) {
  'use strict';
  if (w.__exosEmbed) { w.__exosEmbed.scan(); return; }

  var script = d.currentScript;
  if (!script) {
    var all = d.getElementsByTagName('script');
    for (var i = all.length - 1; i >= 0; i--) {
      if (/\/embed\.js(\?|$)/.test(all[i].src || '')) { script = all[i]; break; }
    }
  }
  if (!script || !script.src) return;
  var src = new URL(script.src, w.location.href);
  var exosOrigin = src.origin;
  // .../bridge/embed.js -> .../bridge
  var base = exosOrigin + src.pathname.replace(/\/embed\.js$/, '');
  var ID_RE = /^[A-Za-z0-9-]{1,64}$/;
  var PASS = ['promoter', 'ref', 'fbclid', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_content'];
  var frames = [];

  function hostParams() {
    var out = [];
    var q;
    try { q = new URL(w.location.href).searchParams; } catch (e) { q = null; }
    for (var i = 0; i < PASS.length; i++) {
      var v = q && q.get(PASS[i]);
      if (v) out.push(PASS[i] + '=' + encodeURIComponent(v.slice(0, 255)));
    }
    return out;
  }

  function mount(div) {
    if (div.getAttribute('data-exos-mounted')) return;
    var id = div.getAttribute('data-exos-event') || '';
    if (!ID_RE.test(id)) return;
    div.setAttribute('data-exos-mounted', '1');
    var q = ['host=' + encodeURIComponent(w.location.origin)].concat(hostParams());
    var f = d.createElement('iframe');
    f.src = base + '/embed/event/' + encodeURIComponent(id) + '?' + q.join('&');
    f.title = div.getAttribute('data-exos-title') || 'Tickets';
    f.setAttribute('allow', 'payment');
    f.setAttribute('loading', 'lazy');
    f.style.width = '100%';
    f.style.maxWidth = '480px';
    f.style.border = '0';
    f.style.display = 'block';
    f.style.height = '420px';
    div.appendChild(f);
    frames.push({ div: div, iframe: f, eventId: id });
  }

  function scan() {
    var divs = d.querySelectorAll('[data-exos-event]');
    for (var i = 0; i < divs.length; i++) mount(divs[i]);
  }

  function onMessage(e) {
    if (e.origin !== exosOrigin) return;
    var entry = null;
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].iframe.contentWindow === e.source) { entry = frames[i]; break; }
    }
    if (!entry) return;
    var m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.type === 'exos:resize') {
      var h = m.height;
      if (typeof h !== 'number' || !isFinite(h) || h < 0 || h > 20000) return;
      entry.iframe.style.height = Math.ceil(h) + 'px';
    } else if (m.type === 'exos:checkout-complete') {
      if (m.eventId !== entry.eventId) return;
      var detail = { eventId: entry.eventId };
      if (typeof m.sessionId === 'string' && /^cs_[A-Za-z0-9_]{1,255}$/.test(m.sessionId)) detail.sessionId = m.sessionId;
      var ev;
      try {
        ev = new w.CustomEvent('exos:checkout-complete', { bubbles: true, detail: detail });
      } catch (err) {
        ev = d.createEvent('CustomEvent');
        ev.initCustomEvent('exos:checkout-complete', true, false, detail);
      }
      entry.div.dispatchEvent(ev);
    }
  }

  w.addEventListener('message', onMessage);
  w.__exosEmbed = { scan: scan };
  if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', scan);
  else scan();
})(window, document);
