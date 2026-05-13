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

// Cached last successful /api/d2/orders body — lets the Hide-Past-12h toggle
// re-render without re-hitting the upstream APIs. Cleared on each new fetch.
let LAST_ORDERS_BODY = null;
let LAST_ORDERS_AT = null;

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
        <div class="orders-toolbar">
          <label class="toolbar-toggle">
            <input type="checkbox" id="chk-hide-past" checked />
            <span>Hide past (&minus;12h)</span>
          </label>
          <span class="toolbar-meta" id="last-refreshed">last refresh: never</span>
        </div>
        <div class="sources-bar" id="sources-bar"><span class="chip">loading...</span></div>
        <div id="orders-table-wrap"><div class="empty"><span class="spinner"></span> fetching orders...</div></div>
        <div id="order-detail-wrap" class="order-detail-wrap"></div>
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
  // Re-render (not re-fetch) when the user toggles Hide-Past-12h.
  document.getElementById("chk-hide-past").addEventListener("change", renderOrders);
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
  const detailWrap = document.getElementById("order-detail-wrap");
  wrap.innerHTML = `<div class="empty"><span class="spinner"></span> fetching orders...</div>`;
  bar.innerHTML = `<span class="chip">loading...</span>`;
  detailWrap.innerHTML = "";
  let body;
  try {
    body = await authedFetch("/api/d2/orders?per_page=50");
  } catch (e) {
    wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
    bar.innerHTML = "";
    return;
  }
  LAST_ORDERS_BODY = body;
  LAST_ORDERS_AT = new Date();
  renderOrders();
}

function renderOrders() {
  const wrap = document.getElementById("orders-table-wrap");
  const bar = document.getElementById("sources-bar");
  const refreshedEl = document.getElementById("last-refreshed");
  if (!LAST_ORDERS_BODY) return;
  const body = LAST_ORDERS_BODY;

  refreshedEl.textContent = LAST_ORDERS_AT
    ? `last refresh: ${LAST_ORDERS_AT.toLocaleTimeString()}`
    : "last refresh: never";

  bar.innerHTML = (body.sources || [])
    .map((s) => {
      const cls = s.ok ? "chip ok" : "chip err";
      const detail = s.ok
        ? `${s.count} row${s.count === 1 ? "" : "s"}` + (s.total_reported != null ? ` / ${s.total_reported} total` : "")
        : (s.error || "error");
      return `<span class="${cls}"><strong>${escapeHtml(s.source)}</strong> · ${escapeHtml(detail)}</span>`;
    })
    .join("");

  const hidePast = document.getElementById("chk-hide-past")?.checked;
  const cutoff = Date.now() - 12 * 60 * 60 * 1000;
  let rows = body.rows || [];
  let filtered = 0;
  if (hidePast) {
    const before = rows.length;
    rows = rows.filter((r) => {
      if (!r.event_date) return true;       // keep rows where event_date is missing
      const t = Date.parse(r.event_date);
      if (Number.isNaN(t)) return true;     // keep unparseable dates
      return t >= cutoff;
    });
    filtered = before - rows.length;
  }

  if (!rows.length) {
    wrap.innerHTML = `<div class="empty">No orders to show${filtered ? ` (${filtered} hidden by past-12h filter)` : " across any source"}.</div>`;
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
          <tr class="order-row" data-source="${escapeHtml(r.source)}" data-order-id="${escapeHtml(r.order_id)}">
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
    ${filtered ? `<div class="empty toolbar-meta">${filtered} row${filtered === 1 ? "" : "s"} hidden by past-12h filter</div>` : ""}
  `;
  // Row click → fetch deep order detail. Listener at table-level so we don't
  // attach N listeners after every re-render.
  wrap.querySelector("tbody")?.addEventListener("click", (ev) => {
    const tr = ev.target.closest("tr.order-row");
    if (!tr) return;
    document.querySelectorAll(".order-row.selected").forEach((el) => el.classList.remove("selected"));
    tr.classList.add("selected");
    loadOrderDetail(tr.dataset.source, tr.dataset.orderId);
  });
}

async function loadOrderDetail(source, orderId) {
  const wrap = document.getElementById("order-detail-wrap");
  wrap.innerHTML = `
    <section class="sample-card">
      <div class="sample-head">
        <span class="chip"><strong>${escapeHtml(source)}</strong> · order ${escapeHtml(orderId)}</span>
        <span class="toolbar-meta"><span class="spinner"></span> loading detail&hellip;</span>
      </div>
    </section>
  `;
  let body;
  try {
    body = await authedFetch(`/api/d2/order/${encodeURIComponent(source)}/${encodeURIComponent(orderId)}`);
  } catch (e) {
    wrap.innerHTML = `<section class="sample-card"><div class="empty err-text">${escapeHtml(e.message)}</div></section>`;
    return;
  }
  if (!body.ok) {
    wrap.innerHTML = `
      <section class="sample-card">
        <div class="sample-head">
          <span class="chip err"><strong>${escapeHtml(source)}</strong> · order ${escapeHtml(orderId)}</span>
        </div>
        <div class="empty err-text">${escapeHtml(body.error || "fetch failed")}</div>
      </section>
    `;
    return;
  }
  const readable = renderReadableOrder(source, body.data || {});
  wrap.innerHTML = `
    <section class="sample-card">
      <div class="sample-head">
        <span class="chip ok"><strong>${escapeHtml(source)}</strong> · order ${escapeHtml(orderId)}</span>
      </div>
      ${readable}
      <details>
        <summary class="toolbar-meta">raw JSON</summary>
        <pre class="json">${escapeHtml(JSON.stringify(body.data, null, 2))}</pre>
      </details>
    </section>
  `;
}

// Per-source pretty-print, ported from the operator's reference Tkinter app's
// make_readable(). Read-only — no fulfillment fields, just what's in the data.
function renderReadableOrder(source, d) {
  const row = (k, v) => `<tr><td class="kv-key">${escapeHtml(k)}</td><td>${escapeHtml(v == null || v === "" ? "—" : String(v))}</td></tr>`;
  let rows = "";
  if (source === "tickpick") {
    const seats = Array.isArray(d.seat_numbers) ? d.seat_numbers.join(", ") : (d.seat_numbers || "");
    rows = [
      row("Order ID",   d.order_number),
      row("Event",      d.event_name),
      row("Event date", formatDate(d.event_date)),
      row("Section",    d.section),
      row("Row",        d.row),
      row("Seats",      seats),
      row("Status",     d.status),
      row("Quantity",   d.quantity),
      row("Notes",      d.notes),
    ].join("");
  } else if (source === "vivid") {
    rows = [
      row("Order ID",   d.orderId),
      row("Event",      d.event),
      row("Event date", d.eventDate),
      row("Section",    d.section),
      row("Row",        d.row),
      row("Status",     d.status),
      row("Quantity",   d.quantity),
      row("Customer",   [d.firstName, d.lastName].filter(Boolean).join(" ")),
      row("Email",      d.emailAddress),
    ].join("");
  } else if (source === "evo") {
    const o = d || {};
    const item = (Array.isArray(o.items) && o.items[0]) || {};
    const tg = item.ticket_group || {};
    const ev = tg.event || {};
    rows = [
      row("Order ID",   o.id),
      row("Event",      ev.name),
      row("Event date", formatDate(ev.occurs_at)),
      row("Section",    tg.section),
      row("Row",        tg.row),
      row("Status",     o.state),
      row("Quantity",   item.quantity),
      row("Total",      o.total),
      row("Currency",   o.currency),
    ].join("");
  } else if (source === "seatgeek") {
    const ev = d.event || {};
    rows = [
      row("Order ID",   d.order_id || d.id),
      row("Event",      ev.title || d.event_title),
      row("Event date", formatDate(ev.datetime_local || ev.datetime_utc)),
      row("Status",     d.status),
      row("Quantity",   d.quantity),
      row("Total",      d.total),
      row("Currency",   d.currency),
    ].join("");
  }
  return `<table class="kv">${rows}</table>`;
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
