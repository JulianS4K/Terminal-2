// VibePass unified homescreen. Auth-aware: signed-in @s4kent.com unlocks the
// Terminal card; everyone else sees Store + Bridge unlocked and the Terminal
// card gated. localhost dev is treated as authed (parity with terminal).
// (Orders + Undelivered were folded into the Terminal — no longer separate
// hub surfaces.)
// Bridge runs at /bridge/ on the same Railway origin — same localStorage,
// so the Supabase session from the hub carries over to Bridge automatically.

(function () {
  'use strict';

  const cardTerminal    = document.getElementById('cardTerminal');
  const cardFlights     = document.getElementById('cardFlights');
  const cardFantasy     = document.getElementById('cardFantasy');
  const cardBridge      = document.getElementById('cardBridge');
  const bridgeNote      = document.getElementById('bridgeNote');
  const authCtrl        = document.getElementById('auth-ctrl');
  const footStatus      = document.getElementById('footStatus');

  function isLocalhost() {
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '';
  }

  function lockCard(card) {
    if (!card) return;
    card.classList.add('locked');
    card.removeAttribute('href');
    const gate = card.querySelector('.card-gate');
    if (gate) gate.hidden = false;
  }

  // Terminal + Flights + Fantasy are all @s4kent.com-gated operator surfaces.
  function lockOperatorCards() {
    lockCard(cardTerminal);
    lockCard(cardFlights);
    lockCard(cardFantasy);
  }

  function renderAuth(email) {
    if (email) {
      authCtrl.innerHTML = `<span class="email">${escapeHtml(email)}</span><a href="#" id="signout">sign out</a>`;
      const so = document.getElementById('signout');
      if (so) so.addEventListener('click', e => {
        e.preventDefault();
        window.TerminalAuth.signOut();
      });
    } else {
      authCtrl.innerHTML = `<a href="/static/terminal/login.html?return=${encodeURIComponent(location.pathname)}">sign in</a>`;
    }
  }

  function setFootStatus(text) {
    if (footStatus) footStatus.textContent = text;
  }

  // Bridge is always accessible — never lock it. Same-origin means the hub's
  // Supabase session (localStorage) is shared with Bridge automatically.
  // Show a soft note only when signed out so the user knows signing in here
  // will carry over. Hide it once any session exists.
  function setBridgeNote(signedIn) {
    if (bridgeNote) bridgeNote.hidden = signedIn;
  }

  if (!window.TerminalAuth) {
    // supabase-js or auth.js failed to load — treat as not signed in.
    lockOperatorCards();
    setBridgeNote(false);
    setFootStatus('auth offline');
    renderAuth(null);
    return;
  }

  window.TerminalAuth.ready.then(() => {
    const email = window.TerminalAuth.getEmail();
    const allowed = window.TerminalAuth.isAllowedEmail(email);

    if (allowed || isLocalhost()) {
      renderAuth(email || (isLocalhost() ? 'dev (localhost)' : null));
      setBridgeNote(true);
      setFootStatus('all surfaces unlocked');
    } else {
      lockOperatorCards();
      setBridgeNote(!!email);
      renderAuth(email);
      setFootStatus(email ? 'not on @s4kent.com — operator surfaces gated' : 'sign in to unlock operator surfaces');
    }
  }).catch(err => {
    console.error('auth ready failed', err);
    lockOperatorCards();
    setBridgeNote(false);
    setFootStatus('auth init failed');
  });

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
})();
