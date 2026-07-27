// popup.js  —  config (ingest URL / secret / enabled), status, recent, export.
"use strict";

const $ = (id) => document.getElementById(id);

async function load() {
  const cfg = await chrome.storage.local.get(
    ["ingestUrl", "ingestSecret", "enabled", "captures"]);
  $("ingestUrl").value = cfg.ingestUrl || "";
  $("ingestSecret").value = cfg.ingestSecret || "";
  $("enabled").checked = !!cfg.enabled;
  renderRecent(cfg.captures || []);
  $("status").textContent = cfg.enabled
    ? "Shipping enabled." : "Local-only until enabled.";
}

function renderRecent(caps) {
  const el = $("recent");
  if (!caps.length) { el.innerHTML = '<div class="muted">No captures yet.</div>'; return; }
  el.innerHTML = caps.slice(0, 20).map((c) => {
    const ship = c.ship && c.ship.shipped ? "✓ shipped"
      : c.ship && c.ship.reason === "disabled" ? "local"
      : c.ship ? `✗ ${c.ship.status || c.ship.reason || "fail"}` : "";
    return `<div class="cap"><b>${c.tenant || "?"}</b> ${c.event_code || ""}
      — ${c.available_seats}/${c.seats} seats, ${c.sections} sections
      <span class="muted">${ship}</span></div>`;
  }).join("");
}

$("save").addEventListener("click", async () => {
  await chrome.storage.local.set({
    ingestUrl: $("ingestUrl").value.trim(),
    ingestSecret: $("ingestSecret").value.trim(),
    enabled: $("enabled").checked,
  });
  $("status").textContent = "Saved.";
  load();
});

$("recapture").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  try {
    await chrome.tabs.sendMessage(tab.id, { type: "paciolan_recapture" });
    $("status").textContent = "Re-capture requested.";
    setTimeout(load, 900);
  } catch (e) {
    $("status").textContent = "Open an eVenue event page first.";
  }
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
