// VibePass unified homescreen. Auth-aware: signed-in @s4kent.com sees all 4
// cards; everyone else sees Store + Bridge unlocked and the two operator
// cards gated. localhost dev is treated as authed (parity with terminal).
// Bridge is always accessible — it runs on a separate Render origin and
// manages its own Supabase auth internally (same project, different domain,
// so localStorage sessions are not shared).

(function () {
  'use strict';

  const cardTerminal    = document.getElementById('cardTerminal');
  const cardUndelivered = document.getElementById('cardUndelivered');
  const cardBridge      = document.getElementById('cardBridge');
  const bridgeNote      = document.getElementById('bridgeNote');
  const authCtrl        = document.getElementById('auth-ctrl');
  const footStatus      = document.getElementById('footStatus');

  function isLocalhost() {
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '';
  }

  function lockCard(card) {
    card.classList.add('locked');
    card.removeAttribute('href');
    const gate = card.querySelector('.card-gate');
    if (gate) gate.hidden = false;
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

  // Bridge is always accessible — never lock it. Show a soft note when no
  // hub session exists so the user knows Bridge has its own sign-in.
  function setBridgeNote(signedIn) {
    if (bridgeNote) bridgeNote.hidden = signedIn;
  }

  if (!window.TerminalAuth) {
    // supabase-js or auth.js failed to load — treat as not signed in.
    lockCard(cardTerminal);
    lockCard(cardUndelivered);
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
      lockCard(cardTerminal);
      lockCard(cardUndelivered);
      setBridgeNote(!!email);
      renderAuth(email);
      setFootStatus(email ? 'not on @s4kent.com — operator surfaces gated' : 'sign in to unlock operator surfaces');
    }
  }).catch(err => {
    console.error('auth ready failed', err);
    lockCard(cardTerminal);
    lockCard(cardUndelivered);
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
