// D0 Terminal — Supabase Auth (mirrors d2_dashboard's auth pattern).
//
// Same Supabase project as D2, same Google OAuth provider, same
// @s4kent.com email gate. Session lives in localStorage on this origin
// (vibepass-terminal-test.onrender.com); each app's session is independent
// even though the underlying auth backend is shared.
//
// Operator one-time setup (per d2_dashboard/DEPLOY.md):
//   Supabase Auth → URL Configuration → Redirect URLs, add:
//     https://vibepass-terminal-test.onrender.com/static/terminal/login.html
//     http://localhost:8000/static/terminal/login.html  (for dev)
//
// Public anon key — safe to embed in static-site JS (RLS gates access).

(function () {
  'use strict';

  const SUPABASE_URL  = 'https://hzrizjeaxlqcxfrtczpq.supabase.co';
  const SUPABASE_KEY  = 'sb_publishable_lIuFt79XqZoGa70NWbg20Q_KBbRSDS8';
  const ALLOWED_EMAIL_DOMAIN = 's4kent.com';

  if (!window.supabase || !window.supabase.createClient) {
    console.error('[auth.js] supabase-js not loaded — include lib/supabase.js before auth.js');
    return;
  }

  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,  // process #access_token=... from OAuth redirect
      flowType: 'implicit',
    },
  });

  let _session = null;
  let _accessToken = null;
  let _initResolve;
  const _initPromise = new Promise(r => { _initResolve = r; });

  function setSession(s) {
    _session = s;
    _accessToken = s ? s.access_token : null;
  }

  function isAllowedEmail(email) {
    return typeof email === 'string' && email.toLowerCase().endsWith('@' + ALLOWED_EMAIL_DOMAIN);
  }

  function isLocalhost() {
    const h = location.hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '';
  }

  client.auth.onAuthStateChange((event, session) => {
    setSession(session || null);
  });

  // Bootstrap: pick up any pre-existing session OR process an OAuth hash.
  client.auth.getSession().then(({ data }) => {
    setSession(data && data.session || null);
    _initResolve();
  }).catch(err => {
    console.warn('[auth.js] getSession failed:', err);
    _initResolve();
  });

  function loginUrl(returnUrl) {
    const here = returnUrl || (location.pathname + location.search);
    return '/static/terminal/login.html?return=' + encodeURIComponent(here);
  }

  async function requireAuth() {
    await _initPromise;
    // Local dev: AUTH_DISABLED=true on uvicorn handles it; don't force login.
    if (isLocalhost()) return _session;
    if (!_session) {
      window.location.href = loginUrl();
      // Never resolve — page navigation in flight.
      return new Promise(() => {});
    }
    const email = _session.user && _session.user.email;
    if (!isAllowedEmail(email)) {
      // Wrong domain — sign out and bounce to login with error flag.
      await client.auth.signOut();
      window.location.href = loginUrl() + '&error=domain_restricted';
      return new Promise(() => {});
    }
    return _session;
  }

  async function signInWithGoogle(returnUrl) {
    const here = returnUrl || (location.pathname + location.search);
    const redirectTo = location.origin + '/static/terminal/login.html?return=' + encodeURIComponent(here);
    const { error } = await client.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo,
        queryParams: { access_type: 'offline', prompt: 'consent' },
      },
    });
    if (error) throw error;
  }

  async function signOut() {
    try { await client.auth.signOut(); } catch (e) { console.warn('signOut error', e); }
    window.location.href = '/static/terminal/login.html';
  }

  function getAccessToken() {
    return _accessToken;
  }

  function getSession() {
    return _session;
  }

  function getEmail() {
    return _session && _session.user ? _session.user.email : null;
  }

  function onReady(callback) {
    _initPromise.then(() => callback(_session));
  }

  window.TerminalAuth = {
    client,
    requireAuth,
    signInWithGoogle,
    signOut,
    getAccessToken,
    getSession,
    getEmail,
    isAllowedEmail,
    onReady,
    ready: _initPromise,
  };
})();
