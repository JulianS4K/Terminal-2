// popup.js  —  one-click capture+upload, export-health verdict, Supabase
// config, recent, export, and a git-pull update check.
"use strict";

const $ = (id) => document.getElementById(id);

function setStatus(text, cls) {
  const el = $("status");
  el.textContent = text;
  el.className = cls || "muted";
}

function cmpVer(a, b) {
  const pa = String(a).split(".").map(Number), pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) > (pb[i] || 0)) return 1;
    if ((pa[i] || 0) < (pb[i] || 0)) return -1;
  }
  return 0;
}

async function load() {
  const cfg = await chrome.storage.local.get(
    ["supabaseUrl", "supabaseAnonKey", "ingestSecret", "captures"]);
  $("supabaseUrl").value = cfg.supabaseUrl || "";
  $("supabaseAnonKey").value = cfg.supabaseAnonKey || "";
  $("ingestSecret").value = cfg.ingestSecret || "";
  $("version").textContent = chrome.runtime.getManifest().version;
  renderRecent(cfg.captures || []);
  const configured = cfg.supabaseUrl && cfg.supabaseAnonKey && cfg.ingestSecret;
  if (!configured) {
    $("cfg").open = true;
    setStatus("Configure Supabase below (one time), then click above.");
  }
  checkForUpdates(false);  // best-effort on open
}

// Export-health verdict box.
function renderVerdict(record, scraped) {
  const q = record.quality || {};
  const ship = record.ship || {};
  const m = q.meta || {};
  const el = $("verdict");
  const cls = q.level === "good" ? "v-good" : q.level === "fail" ? "v-fail" : "v-warn";
  const icon = q.level === "good" ? "✅" : q.level === "fail" ? "❌" : "⚠️";
  let head;
  if (q.level === "good")
    head = `Export good — ${q.available} available seats uploaded (snapshot #${ship.snapshot_id ?? "?"})`;
  else if (q.level === "fail")
    head = `Upload failed — ${ship.error || ship.status || "unknown error"}`;
  else if (q.level === "empty")
    head = "Uploaded, but 0 available seats — expand a section on the page and retry";
  else
    head = "Uploaded, but missing event info — it won't map to EVO/StubHub yet";
  const chk = (ok, label) =>
    `<li><span class="${ok ? "ok" : "no"}">${ok ? "✓" : "✗"}</span> ${label}</li>`;
  const metaOk = !!(m.name && m.date && m.venue);
  el.className = cls;
  el.style.display = "block";
  el.innerHTML = `<div class="head">${icon} ${head}</div><ul>`
    + chk(!!ship.shipped, `Uploaded to Supabase${ship.snapshot_id ? ` (snapshot #${ship.snapshot_id})` : ""}`)
    + chk((q.available || 0) > 0, `${q.available || 0} available seats${scraped ? ` (of ${scraped.seats} scraped)` : ""}`)
    + chk(metaOk, `Event info for EVO/StubHub mapping — name ${m.name ? "✓" : "✗"} · date ${m.date ? "✓" : "✗"} · venue ${m.venue ? "✓" : "✗"}`)
    + "</ul>";
}

function renderRecent(caps) {
  const el = $("recent");
  if (!caps.length) { el.innerHTML = '<div class="muted">No captures yet.</div>'; return; }
  el.innerHTML = caps.slice(0, 20).map((c) => {
    const lvl = (c.quality && c.quality.level) || "idle";
    const dot = lvl === "good" ? "🟢" : lvl === "fail" ? "🔴" : lvl === "idle" ? "⚪" : "🟠";
    const s = c.ship || {};
    const tail = s.shipped ? `#${s.snapshot_id ?? "?"}` : s.error ? "failed" : "buffered";
    return `<div class="cap">${dot} <b>${c.tenant || "?"}</b> ${c.event_code || ""}
      — ${c.available_seats}/${c.seats} seats <span class="muted">${tail}</span></div>`;
  }).join("");
}

$("grab").addEventListener("click", async () => {
  const cfg = await chrome.storage.local.get(
    ["supabaseUrl", "supabaseAnonKey", "ingestSecret"]);
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !cfg.ingestSecret) {
    $("cfg").open = true;
    setStatus("Fill in Supabase URL, anon key, and ingest secret first.", "err");
    return;
  }
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https:\/\/[^/]+\.evenue\.net\//.test(tab.url || "")) {
    setStatus("Open an eVenue event page (…evenue.net/event/…) first.", "err");
    return;
  }
  $("grab").disabled = true;
  setStatus("Reading seat map…");
  try {
    const resp = await chrome.tabs.sendMessage(tab.id, { type: "paciolan_capture_now" });
    if (!resp || !resp.ok) {
      setStatus(resp && resp.error ? resp.error : "Capture failed.", "err");
      $("verdict").style.display = "none";
    } else {
      setStatus("");
      renderVerdict(resp.record, resp.scraped);
    }
  } catch (e) {
    setStatus("Couldn't reach the page. Reload the eVenue tab and retry.", "err");
  } finally {
    $("grab").disabled = false;
    load();
  }
});

$("save").addEventListener("click", async () => {
  await chrome.storage.local.set({
    supabaseUrl: $("supabaseUrl").value.trim(),
    supabaseAnonKey: $("supabaseAnonKey").value.trim(),
    ingestSecret: $("ingestSecret").value.trim(),
  });
  setStatus("Settings saved.", "ok");
  checkForUpdates(false);
});

$("export").addEventListener("click", async () => {
  const { captures = [] } = await chrome.storage.local.get(["captures"]);
  const blob = new Blob([JSON.stringify(captures, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "paciolan_captures.json";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});

// --- git-pull update check (no Web Store) ----------------------------------
// The extension is installed unpacked from the repo, so updates = `git pull`
// + Reload at chrome://extensions. This compares the loaded manifest version
// to the latest version published to Supabase (paciolan_extension_latest RPC,
// set by CI on push to main) and nudges when a newer one exists.
async function checkForUpdates(manual) {
  const el = $("update");
  const cur = chrome.runtime.getManifest().version;
  const cfg = await chrome.storage.local.get(["supabaseUrl", "supabaseAnonKey"]);
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    if (manual) { el.textContent = "set Supabase to check"; el.className = "muted"; }
    return;
  }
  if (manual) el.textContent = "checking…";
  try {
    const base = cfg.supabaseUrl.replace(/\/+$/, "");
    const res = await fetch(`${base}/rest/v1/rpc/paciolan_extension_latest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": cfg.supabaseAnonKey,
        "Authorization": `Bearer ${cfg.supabaseAnonKey}`,
      },
      body: "{}",
    });
    const body = await res.json().catch(() => null);
    const latest = typeof body === "string" ? body : (body && body.version) || null;
    if (!latest) { el.textContent = "version unknown"; el.className = "muted"; return; }
    if (cmpVer(latest, cur) > 0) {
      el.textContent = `update available → v${latest} · git pull + reload`;
      el.className = "avail";
    } else {
      el.textContent = "up to date";
      el.className = "muted";
    }
  } catch (e) {
    el.textContent = "check failed";
    el.className = "muted";
  }
}

// --- autonomous driver toggle + status -------------------------------------
// The checkbox arms the background driver (chrome.alarms). Status shows the last
// tick, what it pulled, and the live queue depth (paciolan_pull_stats).
function fmtResults(st) {
  if (!st || st.last_error) return st && st.last_error ? `error: ${st.last_error}` : "";
  if (!st.last_tick) return "armed — waiting for the first poll…";
  const when = new Date(st.last_tick).toLocaleTimeString();
  const n = st.last_pulled || 0;
  return n ? `last poll ${when}: pulled ${n} event${n === 1 ? "" : "s"}`
           : `last poll ${when}: nothing due`;
}

async function refreshDriver() {
  const info = await chrome.runtime.sendMessage({ type: "paciolan_driver_status" });
  const on = !!(info && info.armed);
  $("armed").checked = on;
  $("driver").className = on ? "on" : "";
  const el = $("driverStatus");
  if (!on) {
    el.textContent = "Off. When armed, this Chrome polls the pull queue and refreshes due events on its own.";
    el.className = "muted";
    return;
  }
  let line = fmtResults(info.status);
  // Best-effort live queue depth.
  const cfg = await chrome.storage.local.get(["supabaseUrl", "supabaseAnonKey", "ingestSecret"]);
  if (cfg.supabaseUrl && cfg.supabaseAnonKey && cfg.ingestSecret) {
    try {
      const base = cfg.supabaseUrl.replace(/\/+$/, "");
      const res = await fetch(`${base}/rest/v1/rpc/paciolan_pull_stats`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": cfg.supabaseAnonKey,
          "Authorization": `Bearer ${cfg.supabaseAnonKey}`,
        },
        body: JSON.stringify({ p_secret: cfg.ingestSecret }),
      });
      const body = await res.json().catch(() => null);
      const s = Array.isArray(body) ? body[0] : body;
      if (res.ok && s) line += ` · queue: ${s.pending} pending, ${s.claimed} in-flight, ${s.resolved_24h} done/24h`;
    } catch (_) { /* leave the tick line as-is */ }
  }
  el.textContent = line;
  el.className = "muted";
}

$("armed").addEventListener("change", async () => {
  const armed = $("armed").checked;
  const cfg = await chrome.storage.local.get(["supabaseUrl", "supabaseAnonKey", "ingestSecret"]);
  if (armed && (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !cfg.ingestSecret)) {
    $("armed").checked = false;
    $("cfg").open = true;
    setStatus("Set Supabase URL, anon key, and ingest secret before arming auto-pull.", "err");
    return;
  }
  await chrome.runtime.sendMessage({ type: "paciolan_driver_arm", armed });
  refreshDriver();
});

$("checkUpdate").addEventListener("click", () => checkForUpdates(true));

load();
refreshDriver();
