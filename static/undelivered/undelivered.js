// Scaffold. Data wiring blocked on D2's scope decision (bot_chat #179).
(function () {
  'use strict';
  const Auth = window.TerminalAuth;
  const status = document.getElementById('status');
  if (!Auth) { status.textContent = 'auth offline'; return; }
  Auth.ready.then(async () => {
    const h = location.hostname;
    const isLocalhost = h === 'localhost' || h === '127.0.0.1' || h === '';
    if (isLocalhost) { status.textContent = 'scaffold · localhost'; return; }
    await Auth.requireAuth();
    status.textContent = 'scaffold · ' + (Auth.getEmail() || 'unknown');
  });
})();
