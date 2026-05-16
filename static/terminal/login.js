// D0 Terminal — Login page logic.
// Handles three states:
//   1. Page just opened, no session → show Google button
//   2. ?error=domain_restricted in URL → show "not @s4kent.com" message
//   3. Post-OAuth (hash present OR session detected on init) → redirect
//      to ?return=<url> if email is allowed, else sign out + show error.

(function () {
  'use strict';

  const Auth = window.TerminalAuth;
  if (!Auth) {
    console.error('[login.js] TerminalAuth missing — auth.js failed to load');
    return;
  }

  const params = new URLSearchParams(location.search);
  // Default return: the directory containing login.html — yields
  // /static/terminal/ on localhost uvicorn and / on Render static-site CDN.
  const defaultReturn = location.pathname.replace(/login\.html.*$/, '');
  const returnUrl = params.get('return') || defaultReturn;
  const errParam = params.get('error');

  const errEl = document.getElementById('loginErr');
  const btnEl = document.getElementById('googleBtn');

  function showError(msg) {
    errEl.textContent = msg;
    errEl.hidden = false;
  }

  if (errParam === 'domain_restricted') {
    showError('Access restricted to @s4kent.com. Sign in with a permitted account.');
  }

  btnEl.addEventListener('click', async () => {
    btnEl.disabled = true;
    btnEl.textContent = 'Redirecting to Google…';
    try {
      await Auth.signInWithGoogle(returnUrl);
    } catch (e) {
      console.error(e);
      btnEl.disabled = false;
      btnEl.textContent = 'Continue with Google';
      showError(e.message || 'OAuth init failed');
    }
  });

  // If we land here with a session already (post-OAuth redirect or
  // pre-existing session from prior login), bounce to the return URL.
  Auth.ready.then(() => {
    const session = Auth.getSession();
    if (!session) return;
    const email = Auth.getEmail();
    if (!Auth.isAllowedEmail(email)) {
      Auth.client.auth.signOut().finally(() => {
        showError('Signed-in email (' + (email || 'unknown') + ') is not @s4kent.com. Signed out.');
        btnEl.disabled = false;
      });
      return;
    }
    // Valid session — bounce to where we came from.
    // Defensive: only bounce to same-origin URLs to avoid open-redirect.
    const safe = isSafeReturn(returnUrl) ? returnUrl : defaultReturn;
    window.location.replace(safe);
  });

  function isSafeReturn(url) {
    try {
      // Reject protocol-relative or absolute URLs to other origins.
      if (!url) return false;
      if (url.startsWith('//')) return false;
      if (url.startsWith('http://') || url.startsWith('https://')) {
        const u = new URL(url);
        return u.origin === location.origin;
      }
      return url.startsWith('/');
    } catch (_) { return false; }
  }
})();
