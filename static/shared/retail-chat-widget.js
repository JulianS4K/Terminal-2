// Retail Chat Widget — shared, build-once chat panel for the retail
// price/inventory assistant. Mounted on TWO surfaces:
//   - D0 broker terminal (static/terminal/retail-chat.html) → /api/retail-chat
//     (scope=all; the operator sees the full market)
//   - Consumer storefront (static/store/chat.html)           → /api/store/retail-chat
//     (scope=owned; hard-locked to our owned EVO inventory)
//
// Both endpoints proxy to the deployed `chat` edge function, which already
// resolves events, aggregates price zones, and filters owned-EVO listings by
// quantity + budget (e.g. "next Yankees home game with tickets under $5").
//
// CSP-safe by construction: this is an external same-origin script
// (script-src 'self'); it POSTs only to a same-origin/allowlisted endpoint
// (connect-src 'self'); its styles are injected as a single <style> block
// (style-src 'self' 'unsafe-inline'). No inline handlers, no third-party hosts.
//
// Two ways to use it:
//   (a) Declarative — drop a container with data-retail-chat and the widget
//       auto-mounts on DOMContentLoaded reading its data-* attributes. Used by
//       the storefront (no auth header needed).
//   (b) Programmatic — window.RetailChat.mount({ container, endpoint,
//       getAuthHeaders, cors, ... }). Used by the terminal to attach the
//       Supabase bearer token.

(function () {
  'use strict';

  var STYLE_ID = 'retail-chat-widget-styles';
  // Keep transcripts bounded so a long session can't grow an unbounded
  // request body (the server also caps this defensively).
  var MAX_HISTORY = 24;
  var MAX_CHARS = 4000;

  var CSS = [
    '.rchat{display:flex;flex-direction:column;min-height:0;height:100%;',
    'background:var(--rchat-bg,#0f0f12);color:var(--rchat-text,#e7e7ea);',
    "font-family:var(--rchat-sans,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif);",
    'border:1px solid var(--rchat-line,#26262c);border-radius:10px;overflow:hidden}',
    '.rchat__log{flex:1 1 auto;min-height:0;overflow-y:auto;padding:16px;',
    'display:flex;flex-direction:column;gap:12px;scroll-behavior:smooth}',
    '.rchat__msg{max-width:86%;padding:10px 13px;border-radius:12px;',
    'line-height:1.45;font-size:14px;white-space:pre-wrap;word-wrap:break-word}',
    '.rchat__msg--user{align-self:flex-end;background:var(--rchat-accent,#fbbf24);',
    'color:#1a1a1a;border-bottom-right-radius:3px}',
    '.rchat__msg--bot{align-self:flex-start;background:var(--rchat-panel,#1c1c22);',
    'border:1px solid var(--rchat-line,#26262c);border-bottom-left-radius:3px}',
    '.rchat__msg--err{align-self:flex-start;background:#2a1416;',
    'border:1px solid #7f1d1d;color:#fca5a5}',
    '.rchat__typing{align-self:flex-start;display:flex;gap:4px;padding:12px 14px}',
    '.rchat__typing span{width:7px;height:7px;border-radius:50%;',
    'background:var(--rchat-muted,#737380);animation:rchatBlink 1.2s infinite both}',
    '.rchat__typing span:nth-child(2){animation-delay:.2s}',
    '.rchat__typing span:nth-child(3){animation-delay:.4s}',
    '@keyframes rchatBlink{0%,80%,100%{opacity:.25}40%{opacity:1}}',
    '.rchat__examples{display:flex;flex-wrap:wrap;gap:7px;padding:0 16px 12px}',
    '.rchat__chip{font-size:12.5px;padding:6px 11px;border-radius:999px;cursor:pointer;',
    'background:transparent;color:var(--rchat-muted,#9b9ba6);',
    'border:1px solid var(--rchat-line,#34343c)}',
    '.rchat__chip:hover{color:var(--rchat-text,#e7e7ea);border-color:var(--rchat-accent,#fbbf24)}',
    '.rchat__composer{display:flex;gap:8px;padding:12px;',
    'border-top:1px solid var(--rchat-line,#26262c);background:var(--rchat-panel,#16161a)}',
    '.rchat__input{flex:1 1 auto;resize:none;max-height:140px;min-height:42px;',
    'background:var(--rchat-bg,#0f0f12);color:var(--rchat-text,#e7e7ea);',
    'border:1px solid var(--rchat-line,#34343c);border-radius:8px;padding:11px 12px;',
    'font:inherit;font-size:14px;line-height:1.4;outline:none}',
    '.rchat__input:focus{border-color:var(--rchat-accent,#fbbf24)}',
    '.rchat__send{flex:0 0 auto;align-self:flex-end;height:42px;padding:0 18px;',
    'border:none;border-radius:8px;cursor:pointer;font:inherit;font-weight:600;',
    'background:var(--rchat-accent,#fbbf24);color:#1a1a1a}',
    '.rchat__send:disabled{opacity:.45;cursor:not-allowed}',
    '.rchat__hint{font-size:11px;color:var(--rchat-muted,#737380);',
    'padding:0 16px 10px;margin:0}'
  ].join('');

  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function ChatWidget(opts) {
    this.endpoint = opts.endpoint;
    this.scope = opts.scope === 'all' ? 'all' : 'owned';
    this.cors = !!opts.cors;
    this.getAuthHeaders = typeof opts.getAuthHeaders === 'function' ? opts.getAuthHeaders : null;
    this.examples = opts.examples || [];
    this.placeholder = opts.placeholder || 'Ask about a game, price, or seats…';
    this.greeting = opts.greeting || '';
    this.hint = opts.hint || '';
    this.history = [];
    this.busy = false;
    this._build(opts.container);
  }

  ChatWidget.prototype._build = function (container) {
    container.classList.add('rchat');
    container.innerHTML = '';

    this.log = el('div', 'rchat__log');
    this.log.setAttribute('role', 'log');
    this.log.setAttribute('aria-live', 'polite');
    container.appendChild(this.log);

    if (this.greeting) this._append('bot', this.greeting);

    if (this.examples.length) {
      var chips = el('div', 'rchat__examples');
      var self = this;
      this.examples.forEach(function (ex) {
        var c = el('button', 'rchat__chip', ex);
        c.type = 'button';
        c.addEventListener('click', function () {
          self.input.value = ex;
          self._send();
        });
        chips.appendChild(c);
      });
      this.examplesEl = chips;
      container.appendChild(chips);
    }

    if (this.hint) {
      container.appendChild(el('p', 'rchat__hint', this.hint));
    }

    var composer = el('div', 'rchat__composer');
    this.input = el('textarea', 'rchat__input');
    this.input.placeholder = this.placeholder;
    this.input.rows = 1;
    this.input.setAttribute('aria-label', 'Message');
    this.send = el('button', 'rchat__send', 'Send');
    this.send.type = 'button';
    composer.appendChild(this.input);
    composer.appendChild(this.send);
    container.appendChild(composer);

    var self = this;
    this.send.addEventListener('click', function () { self._send(); });
    this.input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        self._send();
      }
    });
    // Auto-grow the textarea up to its max-height.
    this.input.addEventListener('input', function () {
      self.input.style.height = 'auto';
      self.input.style.height = Math.min(self.input.scrollHeight, 140) + 'px';
    });
  };

  ChatWidget.prototype._append = function (kind, text) {
    var cls = kind === 'user' ? 'rchat__msg rchat__msg--user'
            : kind === 'err' ? 'rchat__msg rchat__msg--err'
            : 'rchat__msg rchat__msg--bot';
    var node = el('div', cls, text);
    this.log.appendChild(node);
    this.log.scrollTop = this.log.scrollHeight;
    return node;
  };

  ChatWidget.prototype._showTyping = function () {
    var t = el('div', 'rchat__typing');
    t.appendChild(el('span'));
    t.appendChild(el('span'));
    t.appendChild(el('span'));
    this.log.appendChild(t);
    this.log.scrollTop = this.log.scrollHeight;
    this._typing = t;
  };

  ChatWidget.prototype._hideTyping = function () {
    if (this._typing && this._typing.parentNode) this._typing.parentNode.removeChild(this._typing);
    this._typing = null;
  };

  ChatWidget.prototype._setBusy = function (busy) {
    this.busy = busy;
    this.send.disabled = busy;
    this.input.disabled = busy;
  };

  ChatWidget.prototype._send = function () {
    if (this.busy) return;
    var text = (this.input.value || '').trim();
    if (!text) return;
    if (text.length > MAX_CHARS) text = text.slice(0, MAX_CHARS);

    // Once a conversation starts, the example chips are noise.
    if (this.examplesEl && this.examplesEl.parentNode) {
      this.examplesEl.parentNode.removeChild(this.examplesEl);
      this.examplesEl = null;
    }

    this.input.value = '';
    this.input.style.height = 'auto';
    this._append('user', text);
    this.history.push({ role: 'user', content: text });
    if (this.history.length > MAX_HISTORY) this.history = this.history.slice(-MAX_HISTORY);

    this._setBusy(true);
    this._showTyping();
    this._post();
  };

  ChatWidget.prototype._post = function () {
    var self = this;
    var headers = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
    if (this.getAuthHeaders) {
      try {
        var auth = this.getAuthHeaders();
        if (auth) for (var k in auth) if (Object.prototype.hasOwnProperty.call(auth, k)) headers[k] = auth[k];
      } catch (_) { /* fall through unauthenticated; server will 401 */ }
    }

    fetch(this.endpoint, {
      method: 'POST',
      headers: headers,
      credentials: this.cors ? 'omit' : 'same-origin',
      mode: this.cors ? 'cors' : 'same-origin',
      body: JSON.stringify({ history: this.history })
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (body) {
        return { status: res.status, body: body };
      });
    }).then(function (r) {
      self._hideTyping();
      self._setBusy(false);
      if (r.status === 401 || r.status === 403) {
        self._append('err', 'Your session expired — please sign in again.');
        return;
      }
      if (r.status === 429) {
        self._append('err', "You're sending messages a little fast — give it a few seconds and try again.");
        return;
      }
      if (r.status >= 500 || !r.body || (!r.body.reply && r.body.error)) {
        self._append('err', (r.body && r.body.error) ? String(r.body.error) : 'Something went wrong. Try again in a moment.');
        return;
      }
      var reply = r.body.reply || 'Let me know what you’re looking for!';
      self._append('bot', reply);
      self.history.push({ role: 'assistant', content: reply });
      if (self.history.length > MAX_HISTORY) self.history = self.history.slice(-MAX_HISTORY);
      self.input.focus();
    }).catch(function () {
      self._hideTyping();
      self._setBusy(false);
      self._append('err', "Couldn't reach the assistant. Check your connection and try again.");
    });
  };

  function resolveContainer(c) {
    if (!c) return null;
    if (typeof c === 'string') return document.querySelector(c);
    return c;
  }

  var RetailChat = {
    mount: function (opts) {
      opts = opts || {};
      var container = resolveContainer(opts.container);
      if (!container) { console.warn('RetailChat.mount: container not found', opts.container); return null; }
      if (!opts.endpoint) { console.warn('RetailChat.mount: endpoint required'); return null; }
      injectStyles();
      return new ChatWidget(Object.assign({}, opts, { container: container }));
    }
  };

  // Declarative auto-mount: any [data-retail-chat] element with a
  // data-endpoint is wired automatically (no auth header — the storefront's
  // public path). Examples accept a JSON array or a |-separated list.
  function autoMount() {
    var nodes = document.querySelectorAll('[data-retail-chat]');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.__rchatMounted) continue;
      n.__rchatMounted = true;
      var endpoint = n.getAttribute('data-endpoint');
      if (!endpoint) continue;
      var examples = [];
      var raw = n.getAttribute('data-examples');
      if (raw) {
        try { examples = JSON.parse(raw); }
        catch (_) { examples = raw.split('|').map(function (s) { return s.trim(); }).filter(Boolean); }
      }
      RetailChat.mount({
        container: n,
        endpoint: endpoint,
        scope: n.getAttribute('data-scope') || 'owned',
        cors: n.getAttribute('data-cors') === 'true',
        greeting: n.getAttribute('data-greeting') || '',
        placeholder: n.getAttribute('data-placeholder') || '',
        hint: n.getAttribute('data-hint') || '',
        examples: examples
      });
    }
  }

  window.RetailChat = RetailChat;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', autoMount);
  } else {
    autoMount();
  }
})();
