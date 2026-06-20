// D0 Terminal — Retail Chat page init.
//
// Wires the shared retail-chat widget to the email-gated terminal endpoint
// (/api/retail-chat, scope=all → full market). The widget itself lives in
// /static/shared/retail-chat-widget.js so the storefront reuses the same code;
// this file only supplies the terminal's auth + topology wiring.

(function () {
  'use strict';

  function boot() {
    var T = window.Terminal || {};
    // API_BASE points the call at the FastAPI shell even when this page is
    // served from the static CDN topology (terminal-test). Same-origin → ''.
    var base = (typeof T.API_BASE === 'string') ? T.API_BASE : '';

    if (!window.RetailChat) {
      var host = document.getElementById('retailChat');
      if (host) host.textContent = 'Chat failed to load — please refresh.';
      return;
    }

    window.RetailChat.mount({
      container: '#retailChat',
      endpoint: base + '/api/retail-chat',
      scope: 'all',
      cors: !!base,
      getAuthHeaders: function () {
        return (T.getAuthHeader && T.getAuthHeader()) || {};
      },
      greeting: "Hey — ask me about prices or availability. Try a team and a budget, "
              + "like “next Yankees home game with tickets under $5”.",
      placeholder: 'e.g. cheapest Knicks home game this month',
      hint: 'Full-market view · grounded in live TEvo listings.',
      examples: [
        'Next Yankees home game with tickets under $5',
        'Cheapest Knicks home game this month',
        'Lakers tickets under $100 next week',
        'What’s at MSG this weekend?'
      ]
    });

    if (T.setStatus) T.setStatus('retail chat', 'ok');
  }

  function start() {
    var Auth = window.TerminalAuth;
    if (Auth && Auth.requireAuth) {
      // requireAuth bounces to login if the session is missing; boot once it
      // resolves (or on failure, so the page still renders an auth error).
      Auth.requireAuth().then(boot).catch(boot);
    } else {
      boot();
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
