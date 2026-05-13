// D2 Orders Dashboard — front-end controller.
//
// Reads server-rendered config from `window.__D2_CONFIG__` (injected by
// d2_dashboard/main.py at request time). No /api/d2/config-public round-trip
// on boot — if the server can't serve config, /  returns 503 before this JS
// ever loads.
//
// Supabase JS is loaded from jsdelivr ESM, pinned to a known-good version,
// with a hard timeout so a blocked / slow CDN surfaces a clear error instead
// of hanging on "bootstrapping...".

const CFG = window.__D2_CONFIG__ || {};
const SUPABASE_JS_URL = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";
const SUPABASE_JS_TIMEOUT_MS = 8000;

const root = document.getElementById("app-root");

function render(html) { root.innerHTML = html; }

function escapeHtml(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatDate(iso) {
  if (!iso) return "";
  try {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return escapeHtml(iso);
    return d.toISOString().replace("T", " ").replace(/\..+$/, "Z");
  } catch (e) {
    return escapeHtml(iso);
  }
}

function formatAmount(amount, currency) {
  if (amount == null) return "";
  const num = Number(amount).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return currency ? `${num} ${escapeHtml(currency)}` : num;
}

let SB = null;
let SESSION = null;
let AUTH_BYPASS = false;

async function importWithTimeout(url, ms) {
  // Race the dynamic import against a timeout so we don't hang on a blocked CDN.
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`Supabase JS load timed out after ${ms}ms (CDN blocked?)`)),
      ms
    );
  });
  try {
    return await Promise.race([import(/* @vite-ignore */ url), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function bootstrap() {
  AUTH_BYPASS = !!CFG.auth_disabled;
  if (AUTH_BYPASS) {
    renderDashboard(CFG.allowed_email_domain);
    return;
  }
  if (!CFG.supabase_url || !CFG.supabase_anon_key) {
    // Shouldn't reach here in normal operation — main.py serves 503 at / when
    // production is detected with missing supabase env. This is the last-ditch
    // client-side message for local-dev misconfigs.
    render(
      `<div class="login"><h2>Server misconfigured</h2>` +
      `<p class="err-text">SUPABASE_URL / SUPABASE_ANON_KEY not injected into shell.</p></div>`
    );
    return;
  }
  let mod;
  try {
    mod = await importWithTimeout(SUPABASE_JS_URL, SUPABASE_JS_TIMEOUT_MS);
  } catch (e) {
    render(
      `<div class="login"><h2>Boot error</h2>` +
      `<p class="err-text">${escapeHtml(e.message)}</p>` +
      `<p>Supabase JS could not be loaded from the CDN. ` +
      `Check network / corporate proxy / CSP.</p></div>`
    );
    return;
  }
  SB = mod.createClient(CFG.supabase_url, CFG.supabase_anon_key, {
    auth: { detectSessionInUrl: true, persistSession: true, autoRefreshToken: true },
  });

  const { data: { session } } = await SB.auth.getSession();
  SESSION = session;
  if (!SESSION) {
    renderLogin(CFG.allowed_email_domain);
  } else {
    renderDashboard(CFG.allowed_email_domain);
  }
  SB.auth.onAuthStateChange((_event, s) => {
    SESSION = s;
    if (!SESSION) renderLogin(CFG.allowed_email_domain);
    else renderDashboard(CFG.allowed_email_domain);
  });
}

function renderLogin(domain) {
  render(`
    <div class="login">
      <h2>D2 Orders Dashboard</h2>
      <p>Sign in with your @${escapeHtml(domain)} Google account.</p>
      <button id="btn-google">Sign in with Google</button>
    </div>
  `);
  document.getElementById("btn-google").addEventListener("click", async () => {
    // Use server-provided canonical origin when available — it matches what's
    // registered as a redirect URL in Supabase Auth. Falls back to the
    // browser's current origin for local dev (http://localhost:8000).
    const redirectTo = (CFG.canonical_origin || window.location.origin) + "/";
    const { error } = await SB.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo },
    });
    if (error) alert(error.message);
  });
}

function renderDashboard(domain) {
  const email = AUTH_BYPASS
    ? "auth disabled (testing)"
    : ((SESSION && SESSION.user && SESSION.user.email) || "");
  const signoutBtn = AUTH_BYPASS
    ? ""
    : `<button id="btn-signout">Sign out</button>`;
  render(`
    <header>
      <h1>D2 Orders Dashboard</h1>
      <div>
        <span class="who">${escapeHtml(email)}</span>
        <button id="btn-refresh" style="margin-left:8px;">Refresh</button>
        ${signoutBtn}
      </div>
    </header>
    <main>
      <div class="tabs">
        <button class="tab active" data-tab="orders">Orders</button>
        <button class="tab" data-tab="samples">Samples</button>
        <button class="tab" data-tab="seatdata">SeatData</button>
      </div>
      <section id="panel-orders" class="panel active">
        <div class="sources-bar" id="sources-bar"><span class="chip">loading...</span></div>
        <div id="orders-table-wrap"><div class="empty"><span class="spinner"></span> fetching orders...</div></div>
      </section>
      <section id="panel-samples" class="panel">
        <div id="samples-wrap"><div class="empty">not loaded yet</div></div>
      </section>
      <section id="panel-seatdata" class="panel">
        <div id="seatdata-wrap"><div class="empty">not loaded yet</div></div>
      </section>
    </main>
  `);
  document.querySelectorAll(".tab").forEach((el) => {
    el.addEventListener("click", () => activateTab(el.dataset.tab));
  });
  document.getElementById("btn-refresh").addEventListener("click", () => {
    const active = document.querySelector(".tab.active").dataset.tab;
    if (active === "orders") loadOrders();
    else if (active === "samples") loadSamples();
    else if (active === "seatdata") loadSeatData();
  });
  if (!AUTH_BYPASS) {
    document.getElementById("btn-signout").addEventListener("click", async () => {
      await SB.auth.signOut();
    });
  }
  loadOrders();
}

function activateTab(name) {
  document.querySelectorAll(".tab").forEach((el) =>
    el.classList.toggle("active", el.dataset.tab === name)
  );
  document.querySelectorAll(".panel").forEach((el) =>
    el.classList.toggle("active", el.id === `panel-${name}`)
  );
  if (name === "seatdata") loadSeatData();
  else if (name === "samples") loadSamples();
}

async function authedFetch(path) {
  const headers = {};
  if (!AUTH_BYPASS) {
    if (!SESSION) throw new Error("no session");
    headers.Authorization = `Bearer ${SESSION.access_token}`;
  }
  const r = await fetch(path, { headers });
  if (!r.ok) {
    const text = await r.text();
    throw new Error(`${path} → HTTP ${r.status}: ${text.slice(0, 200)}`);
  }
  return r.json();
}

async function loadOrders() {
  const wrap = document.getElementById("orders-table-wrap");
  const bar = document.getElementById("sources-bar");
  wrap.innerHTML = `<div class="empty"><span class="spinner"></span> fetching orders...</div>`;
  bar.innerHTML = `<span class="chip">loading...</span>`;
  let body;
  try {
    body = await authedFetch("/api/d2/orders?per_page=50");
  } catch (e) {
    wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
    bar.innerHTML = "";
    return;
  }
  bar.innerHTML = (body.sources || [])
    .map((s) => {
      const cls = s.ok ? "chip ok" : "chip err";
      const detail = s.ok
        ? `${s.count} row${s.count === 1 ? "" : "s"}` + (s.total_reported != null ? ` / ${s.total_reported} total` : "")
        : (s.error || "error");
      return `<span class="${cls}"><strong>${escapeHtml(s.source)}</strong> · ${escapeHtml(detail)}</span>`;
    })
    .join("");
  const rows = body.rows || [];
  if (!rows.length) {
    wrap.innerHTML = `<div class="empty">No orders across any source.</div>`;
    return;
  }
  wrap.innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Source</th>
          <th>Order ID</th>
          <th>Event</th>
          <th>Event Date</th>
          <th class="num">Qty</th>
          <th>Status</th>
          <th class="num">Amount</th>
          <th>Ordered At</th>
        </tr>
      </thead>
      <tbody>
        ${rows.map((r) => `
          <tr>
            <td class="source ${escapeHtml(r.source)}">${escapeHtml(r.source)}</td>
            <td>${escapeHtml(r.order_id)}</td>
            <td>${escapeHtml(r.event_name || "")}</td>
            <td>${formatDate(r.event_date)}</td>
            <td class="num">${r.qty != null ? escapeHtml(String(r.qty)) : ""}</td>
            <td>${escapeHtml(r.status || "")}</td>
            <td class="num">${formatAmount(r.amount, r.currency)}</td>
            <td>${formatDate(r.ordered_at)}</td>
          </tr>
        `).join("")}
      </tbody>
    </table>
  `;
}

async function loadSamples() {
  const wrap = document.getElementById("samples-wrap");
  wrap.innerHTML = `<div class="empty"><span class="spinner"></span> sampling sources...</div>`;
  let body;
  try {
    body = await authedFetch("/api/d2/samples");
  } catch (e) {
    wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
    return;
  }
  const samples = body.samples || [];
  if (!samples.length) {
    wrap.innerHTML = `<div class="empty">No samples returned.</div>`;
    return;
  }
  wrap.innerHTML = samples.map((s) => {
    const headerCls = s.ok ? "chip ok" : "chip err";
    const totalDetail = s.ok && s.total_available != null
      ? ` · ${escapeHtml(String(s.total_available))} available`
      : "";
    const methodDetail = s.method ? ` · <code>${escapeHtml(s.method)}()</code>` : "";
    const bodyDetail = s.ok
      ? (s.sample == null
          ? `<div class="empty">empty — source has no records right now</div>`
          : `<pre class="json">${escapeHtml(JSON.stringify(s.sample, null, 2))}</pre>`)
      : `<div class="empty err-text">${escapeHtml(s.error || "error")}</div>`;
    return `
      <section class="sample-card">
        <div class="sample-head">
          <span class="${headerCls}"><strong>${escapeHtml(s.source)}</strong>${methodDetail}${totalDetail}</span>
        </div>
        ${bodyDetail}
      </section>
    `;
  }).join("");
}

async function loadSeatData() {
  const wrap = document.getElementById("seatdata-wrap");
  wrap.innerHTML = `<div class="empty"><span class="spinner"></span> fetching seatdata...</div>`;
  let body;
  try {
    body = await authedFetch("/api/d2/seatdata");
  } catch (e) {
    wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
    return;
  }
  wrap.innerHTML = `<pre class="json">${escapeHtml(JSON.stringify(body, null, 2))}</pre>`;
}

bootstrap();
