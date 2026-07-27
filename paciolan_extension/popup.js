// popup.js  —  one-click capture+upload, Supabase config, recent, export.
"use strict";

const $ = (id) => document.getElementById(id);

function setStatus(text, cls) {
  const el = $("status");
  el.textContent = text;
  el.className = cls || "muted";
}

async function load() {
  const cfg = await chrome.storage.local.get(
    ["supabaseUrl", "supabaseAnonKey", "ingestSecret", "captures"]);
  $("supabaseUrl").value = cfg.supabaseUrl || "";
  $("supabaseAnonKey").value = cfg.supabaseAnonKey || "";
  $("ingestSecret").value = cfg.ingestSecret || "";
  renderRecent(cfg.captures || []);
  const configured = cfg.supabaseUrl && cfg.supabaseAnonKey && cfg.ingestSecret;
  if (!configured) {
    $("cfg").open = true;
    setStatus("Configure Supabase below (one time), then click above.");
  }
}

function renderRecent(caps) {
  const el = $("recent");
  if (!caps.length) { el.innerHTML = '<div class="muted">No captures yet.</div>'; return; }
  el.innerHTML = caps.slice(0, 20).map((c) => {
    const s = c.ship || {};
    const ship = s.shipped ? `✓ #${s.snapshot_id ?? "?"}`
      : s.error ? `✗ ${s.error}` : s.reason === "not requested" ? "buffered" : "—";
    return `<div class="cap"><b>${c.tenant || "?"}</b> ${c.event_code || ""}
      — ${c.available_seats}/${c.seats} seats, ${c.sections} sec
      <span class="muted">${ship}</span></div>`;
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
    } else {
      const ship = (resp.record && resp.record.ship) || {};
      const sc = resp.scraped || {};
      if (ship.shipped) {
        setStatus(`Uploaded ${sc.available_seats}/${sc.seats} seats across `
          + `${sc.sections} sections → snapshot #${ship.snapshot_id ?? "?"}.`, "ok");
      } else {
        setStatus(`Scraped ${sc.available_seats}/${sc.seats} seats but upload `
          + `failed: ${ship.error || ship.status || "unknown"}.`, "err");
      }
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
});

$("export").addEventListener("click", async () => {
  const { captures = [] } = await chrome.storage.local.get(["captures"]);
  const blob = new Blob([JSON.stringify(captures, null, 2)],
                        { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "paciolan_captures.json";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});

load();
