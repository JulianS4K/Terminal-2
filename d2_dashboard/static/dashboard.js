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

// Cached Intl formatter — operator preference is America/New_York (EST/EDT)
// because the "Hide past -12h" filter is mentally evaluated against EST, and
// all displayed dates lining up with that reference removes ambiguity. The
// formatter auto-handles DST so the suffix reads EST or EDT correctly.
const _EST_FMT = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit",
  hour12: false, timeZoneName: "short",
});

function formatDate(iso) {
  if (!iso) return "";
  try {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return escapeHtml(iso);
    // Intl returns "05/13/2026, 16:34:52 EDT" — reshape to "2026-05-13 16:34:52 EDT".
    const parts = Object.fromEntries(_EST_FMT.formatToParts(d).map((p) => [p.type, p.value]));
    return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second} ${parts.timeZoneName}`;
  } catch (e) {
    return escapeHtml(iso);
  }
}

function formatAgo(iso) {
  if (!iso) return "";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const diffMs = Date.now() - t;
  if (diffMs < 0) return "just now";
  const m = Math.floor(diffMs / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

// Translate a cron expression into a human-readable interval. Covers the
// patterns our actual cron jobs use; falls back to the raw expression for
// anything exotic. Examples:
//   "*/30 * * * *"   → "every 30m"
//   "5-59/30 * * * *"→ "every 30m"
//   "0 * * * *"      → "every hour"
//   "7 * * * *"      → "every hour"
function formatCronSchedule(expr) {
  if (!expr) return "";
  const m = expr.match(/^(\*\/|\d+-\d+\/)(\d+)\s+\*/);
  if (m) return `every ${m[2]}m`;
  if (/^\d+\s+\*\s+\*\s+\*\s+\*$/.test(expr)) return "every hour";
  if (/^\d+\s+\*\/(\d+)\s+\*/.test(expr)) {
    const h = expr.match(/^\d+\s+\*\/(\d+)/)[1];
    return `every ${h}h`;
  }
  return expr;
}

// Decide whether the last cron run is older than the expected interval.
// Flags the chip with a "stale" CSS class so the operator sees a missed
// run at a glance — works for "*/Nm" and "N-N/Nm" minute schedules.
function cronStaleClass(lastRunIso, schedule) {
  if (!lastRunIso || !schedule) return "";
  const m = schedule.match(/^(?:\*\/|\d+-\d+\/)(\d+)\s+\*/);
  if (!m) return "";
  const intervalMin = parseInt(m[1], 10);
  const ageMin = (Date.now() - Date.parse(lastRunIso)) / 60000;
  // Allow 2× the interval as the "fresh" window — Render/pg_cron jitter
  // can push runs a minute or two; we only flag when we're plainly behind.
  if (ageMin > intervalMin * 2) return "cron-stale";
  return "";
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
let CURRENT_PAGE = 1;
const PER_PAGE = 50;
// Cron freshness is fetched separately from /api/d2/orders so a slow cron
// RPC doesn't pace the orders feed. Cached client-side and re-fetched on
// a slower poll (60s) than the orders auto-refresh (5min).
let LAST_CRON_FRESHNESS = {};
const CRON_FRESHNESS_POLL_MS = 60 * 1000;
let _CRON_FRESHNESS_TIMER = null;
// Auto-refresh interval for the Orders tab. The cron runs every 30 min;
// a 5-min poll picks up status changes (accepted → fulfilled, etc.) well
// before the next cron tick and well within human attention spans.
// Paused while a row-detail panel is open so the operator's inspection
// flow doesn't get yanked out from under them.
const ORDERS_AUTO_REFRESH_MS = 5 * 60 * 1000;
let _ORDERS_REFRESH_TIMER = null;
let _DETAIL_OPEN = false;

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
        <button class="tab" data-tab="health">Health</button>
      </div>
      <section id="panel-orders" class="panel active">
        <div class="orders-toolbar">
          <label class="toolbar-toggle">
            <input type="checkbox" id="chk-hide-past" checked />
            <span>Hide past (&minus;12h)</span>
          </label>
          <label class="toolbar-toggle">
            <input type="checkbox" id="chk-auto-refresh" checked />
            <span title="Pauses the 5-min poll while you're working with the table">Auto-refresh</span>
          </label>
          <span class="toolbar-meta" id="last-refreshed">last refresh: never</span>
        </div>
        <div class="orders-toolbar orders-filters">
          <div class="filter-group">
            <span class="toolbar-meta">Order ID:</span>
            <input type="search" id="flt-order-id" placeholder="search id..." />
          </div>
          <div class="filter-group">
            <span class="toolbar-meta">Source:</span>
            <label><input type="checkbox" class="flt-source" value="evo"      checked /> evo</label>
            <label><input type="checkbox" class="flt-source" value="seatgeek" checked /> sg</label>
            <label><input type="checkbox" class="flt-source" value="tickpick" checked /> tickpick</label>
            <label><input type="checkbox" class="flt-source" value="vivid"    checked /> vivid</label>
          </div>
          <div class="filter-group">
            <span class="toolbar-meta">Status:</span>
            <!-- Default-on: needs-action / in-flight buckets. Operator flips
                 fulfilled / rejected / cancelled on when they want history. -->
            <label><input type="checkbox" class="flt-status" value="pending"      checked /> pending</label>
            <label><input type="checkbox" class="flt-status" value="accepted"     checked /> accepted</label>
            <label><input type="checkbox" class="flt-status" value="substitution" checked /> sub</label>
            <label><input type="checkbox" class="flt-status" value="fulfilled"    /> fulfilled</label>
            <label><input type="checkbox" class="flt-status" value="rejected"     /> rejected</label>
            <label><input type="checkbox" class="flt-status" value="cancelled"    /> cancelled</label>
          </div>
          <div class="filter-group">
            <span class="toolbar-meta">Event:</span>
            <input type="date" id="flt-date-from" />
            <span class="toolbar-meta">to</span>
            <input type="date" id="flt-date-to" />
          </div>
          <div class="filter-group">
            <span class="toolbar-meta">Amount:</span>
            <input type="number" id="flt-amount-min" placeholder="min" step="0.01" />
            <input type="number" id="flt-amount-max" placeholder="max" step="0.01" />
          </div>
          <button type="button" id="btn-clear-filters" class="btn-link">clear</button>
        </div>
        <div class="sources-bar" id="sources-bar"><span class="chip">loading...</span></div>
        <div id="orders-table-wrap"><div class="empty"><span class="spinner"></span> fetching orders...</div></div>
        <div class="orders-toolbar orders-pager">
          <button type="button" id="btn-prev" disabled>&larr; Prev</button>
          <span class="toolbar-meta" id="page-indicator">page 1</span>
          <button type="button" id="btn-next">Next &rarr;</button>
        </div>
        <div id="order-detail-wrap" class="order-detail-wrap"></div>
      </section>
      <section id="panel-health" class="panel">
        <div id="health-wrap"><div class="empty">not loaded yet</div></div>
      </section>
    </main>
  `);
  document.querySelectorAll(".tab").forEach((el) => {
    el.addEventListener("click", () => activateTab(el.dataset.tab));
  });
  document.getElementById("btn-refresh").addEventListener("click", () => {
    const active = document.querySelector(".tab.active").dataset.tab;
    if (active === "orders") { CURRENT_PAGE = 1; loadOrders(); }
    else if (active === "health") loadHealth();
  });
  if (!AUTH_BYPASS) {
    document.getElementById("btn-signout").addEventListener("click", async () => {
      await SB.auth.signOut();
    });
  }
  // Re-render (not re-fetch) when the user toggles Hide-Past-12h or any of
  // the in-memory filters. Source / date / amount filters all just re-slice
  // the cached body — no new API call, no new SQL query.
  document.getElementById("chk-hide-past").addEventListener("change", renderOrders);
  document.querySelectorAll(".flt-source").forEach((el) => el.addEventListener("change", renderOrders));
  document.querySelectorAll(".flt-status").forEach((el) => el.addEventListener("change", renderOrders));
  ["flt-date-from", "flt-date-to", "flt-amount-min", "flt-amount-max", "flt-order-id"].forEach((id) => {
    document.getElementById(id)?.addEventListener("input", renderOrders);
  });
  document.getElementById("btn-clear-filters")?.addEventListener("click", () => {
    document.querySelectorAll(".flt-source").forEach((el) => { el.checked = true; });
    // Status defaults: needs-action / in-flight buckets only.
    document.querySelectorAll(".flt-status").forEach((el) => {
      el.checked = ["pending", "accepted", "substitution"].includes(el.value);
    });
    ["flt-date-from", "flt-date-to", "flt-amount-min", "flt-amount-max", "flt-order-id"].forEach((id) => {
      const el = document.getElementById(id); if (el) el.value = "";
    });
    renderOrders();
  });
  // Pagination — Prev/Next re-fetch (not re-render) since the server holds
  // the per-page slice. Reset CURRENT_PAGE to 1 on full Refresh from the header.
  document.getElementById("btn-prev")?.addEventListener("click", () => {
    if (CURRENT_PAGE > 1) { CURRENT_PAGE -= 1; loadOrders(); }
  });
  document.getElementById("btn-next")?.addEventListener("click", () => {
    CURRENT_PAGE += 1; loadOrders();
  });
  // GoTickets lookup form lives inside the Health tab now; loadHealth()
  // (re-)binds the form's submit handler whenever it renders.
  // Orders is the default landing tab — kick off the auto-refresh poll.
  startOrdersAutoRefresh();
  loadOrders();
}

async function loadGoTicketsLookup(orderId) {
  const wrap = document.getElementById("gt-lookup-result");
  wrap.innerHTML = `
    <section class="sample-card">
      <div class="sample-head">
        <span class="chip"><strong>gotickets</strong> · order ${escapeHtml(orderId)}</span>
        <span class="toolbar-meta"><span class="spinner"></span> looking up&hellip;</span>
      </div>
    </section>
  `;
  let body;
  try {
    body = await authedFetch(`/api/d2/order/gotickets/${encodeURIComponent(orderId)}`);
  } catch (e) {
    wrap.innerHTML = `<section class="sample-card"><div class="empty err-text">${escapeHtml(e.message)}</div></section>`;
    return;
  }
  if (!body.ok) {
    wrap.innerHTML = `
      <section class="sample-card">
        <div class="sample-head">
          <span class="chip err"><strong>gotickets</strong> · order ${escapeHtml(orderId)}</span>
        </div>
        <div class="empty err-text">${escapeHtml(body.error || "fetch failed")}</div>
      </section>
    `;
    return;
  }
  const d = body.data || {};
  const fulfilled = d.fulfilled === true ? "yes" : "no";
  const kv = [
    ["Sale ID",          d.id || d.orderId || d.saleId || orderId],
    ["Event",            (d.event && (d.event.name || d.event.title)) || ""],
    ["Event date",       (d.event && (d.event.startsAt || d.event.date)) || ""],
    ["Fulfilled",        fulfilled],
    ["Fulfillment time", d.fulfillmentTime || ""],
    ["Seller status",    d.sellerStatus || ""],
    ["Cancel reason",    d.cancelReason || ""],
    ["Event status",     (d.event && d.event.status) || ""],
  ];
  const rows = kv.map(([k, v]) => `<tr><td class="kv-key">${escapeHtml(k)}</td><td>${escapeHtml(v == null || v === "" ? "—" : String(v))}</td></tr>`).join("");
  wrap.innerHTML = `
    <section class="sample-card">
      <div class="sample-head">
        <span class="chip ok"><strong>gotickets</strong> · order ${escapeHtml(orderId)}</span>
      </div>
      <table class="kv">${rows}</table>
      <details>
        <summary class="toolbar-meta">raw JSON</summary>
        <pre class="json">${escapeHtml(JSON.stringify(d, null, 2))}</pre>
      </details>
    </section>
  `;
}

function activateTab(name) {
  document.querySelectorAll(".tab").forEach((el) =>
    el.classList.toggle("active", el.dataset.tab === name)
  );
  document.querySelectorAll(".panel").forEach((el) =>
    el.classList.toggle("active", el.id === `panel-${name}`)
  );
  // Auto-refresh runs only while the Orders tab is the active one — leaving
  // it clears the timer, returning starts it again.
  if (name === "orders") startOrdersAutoRefresh();
  else                   stopOrdersAutoRefresh();

  if (name === "health") loadHealth();
}

function startOrdersAutoRefresh() {
  if (_ORDERS_REFRESH_TIMER) return;
  _ORDERS_REFRESH_TIMER = setInterval(() => {
    // Operator paused auto-refresh via the toolbar toggle? Skip silently.
    if (!document.getElementById("chk-auto-refresh")?.checked) return;
    // Skip a tick while the row-detail panel is open — silently yanking
    // a card the operator is reading would be hostile UX.
    if (_DETAIL_OPEN) return;
    // Also skip when on a non-first page so we don't disrupt mid-paging.
    if (CURRENT_PAGE !== 1) return;
    // silent=true means no spinner / no detail-wipe — the table updates
    // seamlessly underneath the operator. Scroll position + selected row
    // are preserved by renderOrders's diff-aware path.
    loadOrders({ silent: true });
  }, ORDERS_AUTO_REFRESH_MS);
  // Cron freshness poll — separate from orders. Refresh the chip's "last
  // cron: Xm ago" line every 60s so the operator sees cron health in
  // near-real-time without dragging the orders feed.
  if (!_CRON_FRESHNESS_TIMER) {
    refreshCronFreshness();   // immediate first hit
    _CRON_FRESHNESS_TIMER = setInterval(refreshCronFreshness, CRON_FRESHNESS_POLL_MS);
  }
}

function stopOrdersAutoRefresh() {
  if (_ORDERS_REFRESH_TIMER) {
    clearInterval(_ORDERS_REFRESH_TIMER);
    _ORDERS_REFRESH_TIMER = null;
  }
  if (_CRON_FRESHNESS_TIMER) {
    clearInterval(_CRON_FRESHNESS_TIMER);
    _CRON_FRESHNESS_TIMER = null;
  }
}

async function refreshCronFreshness() {
  try {
    const body = await authedFetch("/api/d2/cron-freshness");
    LAST_CRON_FRESHNESS = body.sources || {};
    // Re-render the chips with the new cron data if we have an orders body.
    if (LAST_ORDERS_BODY) renderOrders();
  } catch (e) {
    // Non-fatal — the orders feed itself doesn't depend on this.
    console.warn("cron freshness poll failed:", e.message);
  }
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

async function loadOrders({ silent = false } = {}) {
  const wrap = document.getElementById("orders-table-wrap");
  const bar = document.getElementById("sources-bar");
  const detailWrap = document.getElementById("order-detail-wrap");
  // Silent refresh (auto-poll / cron-driven update): don't blow away the
  // current table contents. The spinner + "fetching orders..." flash gets
  // reserved for manual refreshes only. Preserves scroll position +
  // selected row.
  if (!silent) {
    wrap.innerHTML = `<div class="empty"><span class="spinner"></span> fetching orders...</div>`;
    bar.innerHTML = `<span class="chip">loading...</span>`;
    detailWrap.innerHTML = "";
    _DETAIL_OPEN = false;
  }
  let body;
  try {
    body = await authedFetch(`/api/d2/orders?per_page=${PER_PAGE}&page=${CURRENT_PAGE}`);
  } catch (e) {
    if (!silent) {
      wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
      bar.innerHTML = "";
    }
    return;
  }
  LAST_ORDERS_BODY = body;
  LAST_ORDERS_AT = new Date();
  renderOrders();
}

function readFilters() {
  const sources = new Set(
    Array.from(document.querySelectorAll(".flt-source"))
      .filter((el) => el.checked)
      .map((el) => el.value)
  );
  // Canonical-status filter — buckets from order_status_xref. Filtering on
  // canonical_status (not source_status) is the unified path: checking
  // "fulfilled" matches evo "completed" + sg "fulfilled" + sg "delivered" +
  // tickpick "fulfilled"/"filled" + vivid "FULFILLED"/"SHIPPED" all at once.
  const canonicalStatuses = new Set(
    Array.from(document.querySelectorAll(".flt-status"))
      .filter((el) => el.checked)
      .map((el) => el.value)
  );
  const dateFrom = document.getElementById("flt-date-from")?.value || null;
  const dateTo   = document.getElementById("flt-date-to")?.value   || null;
  const amtMinRaw = document.getElementById("flt-amount-min")?.value;
  const amtMaxRaw = document.getElementById("flt-amount-max")?.value;
  const amtMin = amtMinRaw === "" || amtMinRaw == null ? null : Number(amtMinRaw);
  const amtMax = amtMaxRaw === "" || amtMaxRaw == null ? null : Number(amtMaxRaw);
  // dateFrom/To come from <input type="date"> as YYYY-MM-DD; convert to UTC ms.
  const dateFromMs = dateFrom ? Date.parse(`${dateFrom}T00:00:00`) : null;
  const dateToMs   = dateTo   ? Date.parse(`${dateTo}T23:59:59`)   : null;
  const orderIdQuery = (document.getElementById("flt-order-id")?.value || "").trim().toLowerCase();
  return { sources, canonicalStatuses, dateFromMs, dateToMs, amtMin, amtMax, orderIdQuery };
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
      const origin = s.origin === "sql"
        ? `<span class="chip-origin chip-origin-sql" title="from unified_orders (cron-fresh)">SQL</span>`
        : s.origin === "api+sql-match"
          ? `<span class="chip-origin chip-origin-api" title="direct upstream call + v_event_base match">API</span>`
          : s.origin === "api"
            ? `<span class="chip-origin chip-origin-api" title="direct upstream call">API</span>`
            : "";
      let detail;
      if (s.ok) {
        detail = `${s.count} row${s.count === 1 ? "" : "s"}` + (s.total_reported != null ? ` / ${s.total_reported} total` : "");
        if (s.origin === "sql" && s.as_of) detail += ` · row ${formatAgo(s.as_of)}`;
      } else {
        detail = s.error || "error";
      }
      // Cron freshness line — rendered below the chip when a cron job maps
      // to this source. Lets the operator see at a glance "last fetch ran
      // 12m ago against a 30-min schedule" without leaving the dashboard.
      // .cron-stale class fires when last_run is older than 2× the interval.
      // Cron freshness is no longer attached to each source by the orders
      // endpoint — it ships on its own /api/d2/cron-freshness poll. Pull
      // the cached value if we have one, otherwise the chip is bare for
      // the first ~60s after page load (the slower poll's first tick).
      const cronInfo = LAST_CRON_FRESHNESS[s.source];
      let cronLine = "";
      if (cronInfo && cronInfo.jobname) {
        const last = cronInfo.last_run ? `last cron: ${formatAgo(cronInfo.last_run)}` : "cron: never run";
        const sched = cronInfo.schedule ? ` · ${formatCronSchedule(cronInfo.schedule)}` : "";
        const stale = cronInfo.last_run ? cronStaleClass(cronInfo.last_run, cronInfo.schedule) : "";
        cronLine = `<span class="cron-meta ${stale}" title="job: ${escapeHtml(cronInfo.jobname)}">${escapeHtml(last + sched)}</span>`;
      }
      return `<div class="source-cell"><span class="${cls}">${origin}<strong>${escapeHtml(s.source)}</strong> · ${escapeHtml(detail)}</span>${cronLine}</div>`;
    })
    .join("");

  const hidePast = document.getElementById("chk-hide-past")?.checked;
  const cutoff = Date.now() - 12 * 60 * 60 * 1000;
  const { sources: filtSources, canonicalStatuses, dateFromMs, dateToMs, amtMin, amtMax, orderIdQuery } = readFilters();
  let rows = body.rows || [];
  const beforeCount = rows.length;
  rows = rows.filter((r) => {
    // Order-ID search: substring match (case-insensitive). Empty string skips.
    if (orderIdQuery && !(String(r.order_id || "").toLowerCase().includes(orderIdQuery))) return false;
    // Canonical-status filter — rows without a canonical_status (matcher
    // didn't recognize the source enum) are kept so the operator can spot
    // unmapped rows. Empty selection = show all (operator unchecked all).
    if (canonicalStatuses.size > 0 && r.canonical_status && !canonicalStatuses.has(r.canonical_status)) return false;
    // Hide-past-12h cutoff (event_date is the relevant time, not ordered_at).
    if (hidePast && r.event_date) {
      const t = Date.parse(r.event_date);
      if (!Number.isNaN(t) && t < cutoff) return false;
    }
    // Source checkbox filter — empty selection = show all (operator unchecked
    // everything by accident; better to show than to blank).
    if (filtSources.size > 0 && !filtSources.has(r.source)) return false;
    // Event-date range filter (against event_date).
    if (dateFromMs != null && r.event_date) {
      const t = Date.parse(r.event_date);
      if (!Number.isNaN(t) && t < dateFromMs) return false;
    }
    if (dateToMs != null && r.event_date) {
      const t = Date.parse(r.event_date);
      if (!Number.isNaN(t) && t > dateToMs) return false;
    }
    // Amount range filter (skip if row has no amount — keep it visible).
    if (amtMin != null && r.amount != null && Number(r.amount) < amtMin) return false;
    if (amtMax != null && r.amount != null && Number(r.amount) > amtMax) return false;
    return true;
  });
  const filtered = beforeCount - rows.length;

  // Multi-key sort (operator-requested):
  //   1. event_date ASC — soonest upcoming first; NULLs sink to bottom
  //   2. amount DESC — higher-value orders win ties (SQL view's gross_value
  //      is already price × quantity)
  //   3. ordered_at DESC — newer orders before older as final tiebreaker
  rows.sort((a, b) => {
    const aEvT = a.event_date ? Date.parse(a.event_date) : NaN;
    const bEvT = b.event_date ? Date.parse(b.event_date) : NaN;
    const aHas = !Number.isNaN(aEvT), bHas = !Number.isNaN(bEvT);
    if (aHas && bHas && aEvT !== bEvT) return aEvT - bEvT;        // soonest first
    if (aHas && !bHas) return -1;
    if (!aHas && bHas) return 1;
    const aAmt = a.amount != null ? Number(a.amount) : -Infinity;
    const bAmt = b.amount != null ? Number(b.amount) : -Infinity;
    if (aAmt !== bAmt) return bAmt - aAmt;                         // higher value first
    const aOrd = a.ordered_at ? Date.parse(a.ordered_at) : NaN;
    const bOrd = b.ordered_at ? Date.parse(b.ordered_at) : NaN;
    const aOrdHas = !Number.isNaN(aOrd), bOrdHas = !Number.isNaN(bOrd);
    if (aOrdHas && bOrdHas) return bOrd - aOrd;                    // newest first
    if (aOrdHas) return -1;
    if (bOrdHas) return 1;
    return 0;
  });

  // Page indicator + Prev/Next state. Prev disabled at page 1; Next disabled
  // when the current page came back with fewer rows than per_page (no more
  // to fetch). Filter-hidden rows don't disable Next — they're a render-time
  // concern, separate from server-side pagination.
  const page = body.page || CURRENT_PAGE;
  const pageInd = document.getElementById("page-indicator");
  const prevBtn = document.getElementById("btn-prev");
  const nextBtn = document.getElementById("btn-next");
  if (pageInd) pageInd.textContent = filtered ? `page ${page} · ${filtered} hidden by filters` : `page ${page}`;
  if (prevBtn) prevBtn.disabled = page <= 1;
  if (nextBtn) nextBtn.disabled = beforeCount < (body.per_page || PER_PAGE);

  if (!rows.length) {
    wrap.innerHTML = `<div class="empty">No orders to show${filtered ? ` (${filtered} hidden by filters)` : " across any source"}.</div>`;
    return;
  }

  // Preserve scroll + selection across renders. Stable row keys are
  // "${source}:${order_id}" — when a row already exists with the same
  // key we diff-update its cells in place (and flash the ones that
  // changed) instead of nuking the DOM node. Net effect: cron-driven
  // updates slide in seamlessly underneath the operator.
  const scrollY = window.scrollY;
  const selectedKey = wrap.querySelector(".order-row.selected")?.dataset?.rowKey || null;

  // Snapshot the previous DOM keyed by row-key so we can diff against it.
  const prevRows = new Map();
  wrap.querySelectorAll("tr.order-row").forEach((tr) => {
    prevRows.set(tr.dataset.rowKey, tr);
  });

  const rowsHtml = rows.map((r) => {
    const key = `${r.source}:${r.order_id}`;
    const cells = buildRowCells(r);
    return `<tr class="order-row" data-row-key="${escapeHtml(key)}" data-source="${escapeHtml(r.source)}" data-order-id="${escapeHtml(r.order_id)}">${cells}</tr>`;
  }).join("");

  wrap.innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Source</th>
          <th>Order ID</th>
          <th>Event</th>
          <th title="Sort key 1: soonest first">Event Date <span class="sort-key">↑1</span></th>
          <th class="num">Qty</th>
          <th>Status</th>
          <th class="num" title="Sort key 2: higher value first">Amount <span class="sort-key">↓2</span></th>
          <th title="Sort key 3: newest order first">Ordered At <span class="sort-key">↓3</span></th>
        </tr>
      </thead>
      <tbody>${rowsHtml}</tbody>
    </table>
    ${filtered ? `<div class="empty toolbar-meta">${filtered} row${filtered === 1 ? "" : "s"} hidden by past-12h filter</div>` : ""}
  `;

  // Diff pass: flash cells that changed, mark rows that are new since
  // last render. Existing rows whose data is identical pass through
  // unannotated.
  wrap.querySelectorAll("tr.order-row").forEach((newTr) => {
    const key = newTr.dataset.rowKey;
    const prevTr = prevRows.get(key);
    if (!prevTr) {
      newTr.classList.add("row-new");
      return;
    }
    const prevCells = prevTr.querySelectorAll("td");
    const newCells  = newTr.querySelectorAll("td");
    for (let i = 0; i < newCells.length; i++) {
      if (prevCells[i] && prevCells[i].innerHTML !== newCells[i].innerHTML) {
        newCells[i].classList.add("cell-updated");
      }
    }
  });

  // Restore selection by stable key (not DOM identity — the DOM was rebuilt).
  if (selectedKey) {
    const tr = wrap.querySelector(`tr.order-row[data-row-key="${CSS.escape(selectedKey)}"]`);
    if (tr) tr.classList.add("selected");
  }
  // Restore scroll position so silent refreshes don't yank the operator.
  window.scrollTo({ top: scrollY, behavior: "instant" in window ? "instant" : "auto" });

  // Row click → fetch deep order detail. Listener at table-level so we
  // don't attach N listeners after every re-render.
  wrap.querySelector("tbody")?.addEventListener("click", (ev) => {
    const tr = ev.target.closest("tr.order-row");
    if (!tr) return;
    document.querySelectorAll(".order-row.selected").forEach((el) => el.classList.remove("selected"));
    tr.classList.add("selected");
    loadOrderDetail(tr.dataset.source, tr.dataset.orderId);
  });
}

function buildRowCells(r) {
  return [
    `<td class="source ${escapeHtml(r.source)}">${escapeHtml(r.source)}</td>`,
    `<td>${escapeHtml(r.order_id)}</td>`,
    `<td>${escapeHtml(r.event_name || "")}</td>`,
    `<td>${formatDate(r.event_date)}</td>`,
    `<td class="num">${r.qty != null ? escapeHtml(String(r.qty)) : ""}</td>`,
    `<td>${escapeHtml(r.status || "")}${r.canonical_status && r.canonical_status !== r.status ? ` <span class="canon-badge" title="canonical status from order_status_xref">${escapeHtml(r.canonical_status)}</span>` : ""}</td>`,
    `<td class="num">${formatAmount(r.amount, r.currency)}</td>`,
    `<td>${formatDate(r.ordered_at)}</td>`,
  ].join("");
}

async function loadOrderDetail(source, orderId) {
  const wrap = document.getElementById("order-detail-wrap");
  _DETAIL_OPEN = true;  // pause auto-refresh while operator is inspecting
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
  // row(): always renders, "—" for empty (use for core fields the operator
  // expects to see — Order ID, Event, Status).
  // opt(): skips entirely when empty (use for the long-tail of fields that
  // may or may not be populated depending on order shape / ingest stage).
  const row = (k, v) => `<tr><td class="kv-key">${escapeHtml(k)}</td><td>${escapeHtml(v == null || v === "" ? "—" : String(v))}</td></tr>`;
  const opt = (k, v) => (v == null || v === "") ? "" : row(k, v);
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
    // vivid_client._flatten() dumps every <order> XML child into a flat
    // dict. The Apps Script reference + ingest schema gives us these keys.
    // Defensive reads — extras (transferViaURL, orderToken, etc.) auto-
    // populate when ingest lands and the operator wants to act on them.
    const buyer = [d.firstName, d.lastName].filter(Boolean).join(" ");
    const xferUrls = Array.isArray(d.transferURLList)
      ? d.transferURLList.filter(Boolean).join("\n")
      : (d.transferUrl || d.transferURL || "");
    rows = [
      row("Order ID",      d.orderId),
      row("Event",         d.event || d.eventName),
      row("Event date",    d.eventDate),
      row("Status",        d.status),
      row("Quantity",      d.quantity),
      opt("Venue",         d.venue || d.venueName),
      opt("Section / Row", d.section ? `${d.section} / ${d.row || "—"}` : null),
      opt("Total",         d.total || d.price),
      opt("Customer",      buyer),
      opt("Email",         d.emailAddress),
      opt("Phone",         d.phoneNumber || d.phone),
      opt("Transfer-via-URL?", d.transferViaURL),
      opt("Transfer URL(s)",   xferUrls),
      opt("Order token",   d.orderToken),
      opt("Ordered at",    d.orderDate),
    ].join("");
  } else if (source === "evo") {
    const o = d || {};
    const item = (Array.isArray(o.items) && o.items[0]) || {};
    const tg = item.ticket_group || {};
    const ev = tg.event || {};
    // Shipment is the operationally important nested object — carries the
    // transfer URL (tm_mobile_link), delivery state, and transfer source.
    // The Apps Script reference picks shipments[0] for active orders.
    const ship = (Array.isArray(o.shipments) && o.shipments[0]) || {};
    const payment = (Array.isArray(o.payments) && o.payments[0]) || {};
    const seats = Array.isArray(tg.seats) ? tg.seats.join(", ") : tg.seats;
    const autoFlags = [
      o.was_auto_accepted ? "accepted" : null,
      o.was_auto_pended   ? "pended"   : null,
      o.was_auto_canceled ? "canceled" : null,
    ].filter(Boolean).join(", ");
    rows = [
      row("Order ID",        o.id),
      row("Event",           ev.name),
      row("Event date",      formatDate(ev.occurs_at)),
      row("Status",          o.state),
      row("Quantity",        item.quantity),
      row("Total",           o.total),
      opt("Venue",           (ev.venue || {}).name),
      opt("Section / Row",   tg.section ? `${tg.section} / ${tg.row || "—"}` : null),
      opt("Seats",           seats),
      opt("Currency",        o.currency),
      // Auction-hold timer — closest thing to a deadline in /v9/orders.
      opt("Hold expires",    formatDate(o.hold_expires_at)),
      // Shipment / fulfillment block — most operationally relevant for active orders
      opt("Shipment state",  ship.state),
      opt("Shipment type",   ship.type),
      opt("Transfer source", ship.transfer_source),
      // tm_mobile_link is the actual delivery URL — when present, the
      // operator may want to copy/forward/verify it. Rendered as a real
      // clickable anchor below, replacing the row() default escaping.
      ship.tm_mobile_link
        ? `<tr><td class="kv-key">TM mobile link</td><td><a href="${escapeHtml(ship.tm_mobile_link)}" target="_blank" rel="noopener">${escapeHtml(ship.tm_mobile_link)}</a></td></tr>`
        : "",
      opt("Service type",    ship.service_type),
      opt("Tracking #",      ship.tracking_number),
      opt("Tracking URL",    ship.tracking_url),
      // Operator + workflow signals
      opt("Broker notes",    tg.external_notes),
      opt("Order notes",     o.notes),
      opt("Instructions",    o.instructions),
      opt("Fraud check",     o.fraud_check_status),
      opt("Auto-flags",      autoFlags),
      opt("Payment state",   payment.state ? `${payment.state} (${payment.type || "?"})` : null),
    ].join("");
  } else if (source === "seatgeek") {
    // SG seller_order/{id} payload: event.name + event.date + event.time
    // (not event.title / event.datetime_local). Quantity lives under
    // listing, not at the top level. Combine date+time into ISO for the
    // formatDate helper.
    const ev = d.event || {};
    const listing = d.listing || {};
    const evDate = ev.date ? `${ev.date}T${ev.time || "00:00:00"}` : (ev.datetime_local || ev.datetime_utc);
    rows = [
      row("Order ID",      d.order_id || d.id),
      row("Event",         ev.name || ev.title || d.event_title),
      row("Event date",    formatDate(evDate)),
      row("Venue",         ev.venue),
      row("Section / Row", listing.section ? `${listing.section} / ${listing.row || "—"}` : null),
      row("Status",        d.status),
      row("Quantity",      listing.quantity || d.quantity),
      row("Total",         d.total),
      row("Delivery",      d.delivery_method || d.delivery),
    ].join("");
  }
  return `<table class="kv">${rows}</table>`;
}

async function loadHealth() {
  const wrap = document.getElementById("health-wrap");
  wrap.innerHTML = `<div class="empty"><span class="spinner"></span> checking refresh health...</div>`;
  let body;
  try {
    body = await authedFetch("/api/d2/health");
  } catch (e) {
    wrap.innerHTML = `<div class="empty err-text">${escapeHtml(e.message)}</div>`;
    return;
  }

  const crons = body.crons || [];
  const queues = body.queues || {};
  const sql = body.sql_counts || {};
  const fb = body.fulfillby_fields || {};

  // Cron table — one row per scheduled job. .cron-stale row when last_run
  // is older than 2× the schedule interval.
  const cronRows = crons.map((c) => {
    const stale = c.last_run ? cronStaleClass(c.last_run, c.schedule) : "cron-stale";
    const ageCell = c.last_run ? formatAgo(c.last_run) : "never";
    const statusBadge = c.last_status
      ? `<span class="chip ${c.last_status === 'succeeded' ? 'ok' : 'err'}">${escapeHtml(c.last_status)}</span>`
      : `<span class="chip err">no runs</span>`;
    return `
      <tr class="${stale}">
        <td>${escapeHtml(c.source || '')}</td>
        <td><code>${escapeHtml(c.jobname || '')}</code></td>
        <td>${escapeHtml(c.phase || '')}</td>
        <td><code>${escapeHtml(c.schedule || '')}</code> · ${formatCronSchedule(c.schedule || '')}</td>
        <td>${c.active ? 'yes' : 'no'}</td>
        <td>${escapeHtml(ageCell)}</td>
        <td>${statusBadge}</td>
      </tr>
    `;
  }).join("");

  const sqlRows = Object.entries(sql).map(([src, info]) => `
    <tr>
      <td>${escapeHtml(src)}</td>
      <td class="num">${escapeHtml(String(info.rows ?? 0))}</td>
      <td>${info.newest_seen ? `${formatDate(info.newest_seen)} · ${formatAgo(info.newest_seen)}` : '—'}</td>
    </tr>
  `).join("");

  const queueRows = Object.entries(queues).map(([src, depth]) => `
    <tr class="${depth > 0 ? 'cron-stale' : ''}">
      <td>${escapeHtml(src)}</td>
      <td class="num">${depth === -1 ? 'query failed' : escapeHtml(String(depth))}</td>
    </tr>
  `).join("");

  const fbRows = Object.entries(fb).map(([src, info]) => `
    <tr>
      <td>${escapeHtml(src)}</td>
      <td>${info.in_hand ? escapeHtml(info.in_hand) : '<span class="toolbar-meta">none</span>'}</td>
      <td>${info.fulfill_by ? escapeHtml(info.fulfill_by) : '<span class="toolbar-meta">none</span>'}</td>
      <td class="toolbar-meta">${escapeHtml(info.notes || '')}</td>
    </tr>
  `).join("");

  wrap.innerHTML = `
    <section class="sample-card">
      <div class="sample-head"><strong>GoTickets lookup</strong> · <span class="toolbar-meta">by sale ID (no list endpoint)</span></div>
      <form id="gt-lookup-form" class="gt-lookup">
        <input type="text" id="gt-order-id" placeholder="e.g. 123456" />
        <button type="submit">Look up</button>
      </form>
      <div id="gt-lookup-result"></div>
    </section>

    <section class="sample-card">
      <div class="sample-head"><strong>Cron jobs</strong> · <span class="toolbar-meta">checked ${formatAgo(body.checked_at)}</span></div>
      <table>
        <thead><tr><th>Source</th><th>Job</th><th>Phase</th><th>Schedule</th><th>Active</th><th>Last run</th><th>Status</th></tr></thead>
        <tbody>${cronRows || `<tr><td colspan="7" class="empty">no cron rows returned</td></tr>`}</tbody>
      </table>
    </section>

    <section class="sample-card">
      <div class="sample-head"><strong>Unified orders by source</strong></div>
      <table>
        <thead><tr><th>Source</th><th class="num">Rows</th><th>Newest seen</th></tr></thead>
        <tbody>${sqlRows}</tbody>
      </table>
    </section>

    <section class="sample-card">
      <div class="sample-head"><strong>Pending queue depth</strong> · <span class="toolbar-meta">unresolved pg_net requests waiting for process() to drain</span></div>
      <table>
        <thead><tr><th>Source</th><th class="num">Unresolved</th></tr></thead>
        <tbody>${queueRows || `<tr><td colspan="2" class="empty">no pending tables</td></tr>`}</tbody>
      </table>
    </section>

    <section class="sample-card">
      <div class="sample-head"><strong>In-hand / fulfill-by inventory</strong> · <span class="toolbar-meta">what each upstream surfaces</span></div>
      <table>
        <thead><tr><th>Source</th><th>In-hand date</th><th>Fulfill-by date</th><th>Notes</th></tr></thead>
        <tbody>${fbRows}</tbody>
      </table>
    </section>
  `;
  // Re-bind the GoTickets lookup form — the Health tab re-renders on every
  // open / Refresh click, so the form's DOM node is freshly created each
  // time and needs a fresh listener.
  document.getElementById("gt-lookup-form")?.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const orderId = document.getElementById("gt-order-id").value.trim();
    if (!orderId) return;
    loadGoTicketsLookup(orderId);
  });
}


bootstrap();
