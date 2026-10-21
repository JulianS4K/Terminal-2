// /developers — the MCP developer portal.
//
// Sign in with Google (Supabase Auth, PKCE), mint an external API key via the
// SQL function mcp_self_issue_key with the user's own session (the server
// never sees the plaintext key), list the account's keys, and render the
// public catalog (tools + per-feed freshness) from /api/mcp/catalog.
// Builds DOM with createElement only (no innerHTML — eslint ratchet).
(function () {
  'use strict';

  // Supabase URL + publishable key come from /api/public/config (same source
  // the login page uses) so no key literal lives in this file.
  const ENDPOINT = location.origin + '/mcp';

  const $ = (id) => document.getElementById(id);

  function el(tag, attrs, children) {
    const n = document.createElement(tag);
    Object.entries(attrs || {}).forEach(([k, v]) => {
      if (k === 'text') n.textContent = v;
      else if (k === 'class') n.className = v;
      else n.setAttribute(k, v);
    });
    (children || []).forEach((c) => n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c));
    return n;
  }

  function replaceChildren(node, children) {
    while (node.firstChild) node.removeChild(node.firstChild);
    children.forEach((c) => node.appendChild(c));
  }

  function showErr(id, msg) {
    const e = $(id);
    e.textContent = msg;
    e.hidden = !msg;
  }

  function fmtWhen(ts) {
    if (!ts) return '—';
    const d = new Date(ts);
    return Number.isNaN(d.getTime()) ? String(ts) : d.toLocaleString();
  }

  function fmtAge(min) {
    if (min === null || min === undefined) return '—';
    if (min < 60) return Math.round(min) + ' min';
    if (min < 48 * 60) return (min / 60).toFixed(1) + ' h';
    return Math.round(min / 1440) + ' d';
  }

  // ---------------------------------------------------------------- snippets
  function renderSnippets() {
    $('endpoint').textContent = ENDPOINT;
    $('snipClaude').textContent =
      'claude mcp add --transport http s4k-market ' + ENDPOINT +
      ' --header "Authorization: Bearer YOUR_KEY"';
    $('snipJson').textContent = JSON.stringify({
      mcpServers: {
        's4k-market': { url: ENDPOINT, headers: { Authorization: 'Bearer YOUR_KEY' } },
      },
    }, null, 2);
    $('snipCurl').textContent =
      'curl -s ' + ENDPOINT + ' \\\n' +
      '  -H "Authorization: Bearer YOUR_KEY" -H "Content-Type: application/json" \\\n' +
      '  -H "Accept: application/json, text/event-stream" \\\n' +
      '  -d \'{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"search","arguments":{"query":"Lakers"}}}\'';
  }

  // ---------------------------------------------------------------- catalog
  async function loadCatalog() {
    let cat;
    try {
      const r = await fetch('/api/mcp/catalog', { headers: { Accept: 'application/json' } });
      cat = await r.json();
    } catch (e) {
      replaceChildren($('toolsList'), [el('li', { class: 'err', text: 'catalog unavailable' })]);
      return;
    }
    replaceChildren($('toolsList'), (cat.tools || []).map((t) => el('li', {}, [
      el('code', { text: t.name + '(' + (t.parameters || []).join(', ') + ')' }),
      el('span', { class: 'desc', text: ' — ' + t.description }),
    ])));
    replaceChildren($('viewsList'), Object.entries(cat.views || {}).map(([v, cols]) => el('li', {}, [
      el('code', { text: v }), el('span', { class: 'desc', text: ': ' + cols.join(', ') }),
    ])));
    const fr = cat.freshness || {};
    $('freshGenerated').textContent = fr.generated_at
      ? 'Generated ' + fmtWhen(fr.generated_at) + ' (cached up to 60 s).'
      : (fr.error || 'Freshness unavailable.');
    const feeds = fr.feeds || [];
    replaceChildren($('freshBody'), feeds.length ? feeds.map((f) => el('tr', { class: f.age_minutes > 48 * 60 ? 'stale' : '' }, [
      el('td', {}, [el('code', { text: f.feed })]),
      el('td', { text: f.description || '' }),
      el('td', { text: fmtWhen(f.as_of) }),
      el('td', { text: fmtAge(f.age_minutes) }),
      el('td', { text: f.rows_24h === null || f.rows_24h === undefined ? '—' : String(f.rows_24h) }),
      el('td', { text: f.cadence || '' }),
    ])) : [el('tr', {}, [el('td', { colspan: '6', class: 'muted', text: 'no freshness data' })])]);
  }

  // ---------------------------------------------------------------- auth + keys
  let client = null;

  async function initClient() {
    if (!window.supabase || !window.supabase.createClient) return null;
    const r = await fetch('/api/public/config', { headers: { Accept: 'application/json' } });
    const cfg = await r.json();
    if (!cfg.supabase_url || !cfg.supabase_anon_key) return null;
    return window.supabase.createClient(cfg.supabase_url, cfg.supabase_anon_key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' },
    });
  }

  function setSignedIn(session) {
    const on = !!session;
    $('authSignedOut').hidden = on;
    $('authSignedIn').hidden = !on;
    if (on) {
      $('whoami').textContent = (session.user && session.user.email) || 'signed in';
      loadKeys();
    }
  }

  async function loadKeys() {
    const body = $('keysBody');
    const { data, error } = await client.rpc('mcp_my_keys');
    if (error) {
      replaceChildren(body, [el('tr', {}, [el('td', { colspan: '5', class: 'err', text: error.message })])]);
      return;
    }
    const keys = Array.isArray(data) ? data : [];
    replaceChildren(body, keys.length ? keys.map((k) => el('tr', {}, [
      el('td', {}, [el('code', { text: k.key_prefix + '…' })]),
      el('td', { text: k.label || '' }),
      el('td', { text: k.revoked_at ? 'revoked' : 'active' }),
      el('td', { text: String(k.calls_today || 0) + ' / ' + String(k.daily_quota || '') }),
      el('td', { text: fmtWhen(k.last_used_at) }),
    ])) : [el('tr', {}, [el('td', { colspan: '5', class: 'muted', text: 'no keys yet' })])]);
  }

  async function issueKey(ev) {
    ev.preventDefault();
    showErr('issueErr', '');
    const btn = $('issueBtn');
    btn.disabled = true;
    try {
      const { data, error } = await client.rpc('mcp_self_issue_key', { p_label: $('labelInput').value || 'my bot' });
      if (error) throw error;
      $('newKeyValue').textContent = data.key;
      $('newKey').hidden = false;
      loadKeys();
    } catch (e) {
      showErr('issueErr', (e && e.message) || 'could not create a key');
    } finally {
      btn.disabled = false;
    }
  }

  async function copyKey() {
    try {
      await navigator.clipboard.writeText($('newKeyValue').textContent);
      $('copyKeyBtn').textContent = 'Copied';
    } catch (e) {
      $('copyKeyBtn').textContent = 'Select + copy';
    }
  }

  async function signIn() {
    showErr('authErr', '');
    const btn = $('googleBtn');
    btn.disabled = true;
    try {
      const { error } = await client.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: location.origin + '/developers' },
      });
      if (error) throw error;
    } catch (e) {
      btn.disabled = false;
      showErr('authErr', (e && e.message) || 'sign-in failed');
    }
  }

  async function signOut() {
    await client.auth.signOut();
    setSignedIn(null);
  }

  async function wireAuth() {
    try {
      client = await initClient();
    } catch (e) {
      client = null;
    }
    if (!client) {
      showErr('authErr', 'Sign-in is unavailable right now — reload the page.');
      return;
    }
    $('googleBtn').addEventListener('click', signIn);
    $('signOutBtn').addEventListener('click', signOut);
    $('issueForm').addEventListener('submit', issueKey);
    $('copyKeyBtn').addEventListener('click', copyKey);
    client.auth.onAuthStateChange((_event, session) => setSignedIn(session));
    client.auth.getSession().then(({ data }) => setSignedIn(data && data.session));
  }

  renderSnippets();
  loadCatalog();
  wireAuth();
})();
