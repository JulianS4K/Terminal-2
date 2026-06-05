// popup.js  —  status + config UI for the Broadway Availability Collector.
"use strict";

const $ = (id) => document.getElementById(id);

function send(msg) {
  return new Promise((resolve) => chrome.runtime.sendMessage(msg, resolve));
}

function fmtTime(iso) {
  if (!iso) return "—";
  try { return new Date(iso).toLocaleTimeString(); } catch (_) { return iso; }
}

function money(n) {
  return (n == null) ? "?" : "$" + Number(n).toFixed(2);
}

async function render() {
  const s = await send({ type: "get_state" });
  const cfg = s.config || {};
  const shipping = !!(cfg.enabled && cfg.ingestUrl);
  $("state").textContent = shipping ? "shipping" : "local";
  $("state").className = "pill " + (shipping ? "on" : "off");
  $("total").textContent = s.total_captured || 0;

  const lc = s.last_capture;
  $("last").textContent = lc
    ? `event ${lc.event_id} · ${lc.ticket_count} blocks · ${money(lc.price_min)}–${money(lc.price_max)} · ${fmtTime(lc.captured_at)}`
    : "—";
  $("err").textContent = s.last_error ? ("ship error: " + s.last_error) : "";

  const list = $("list");
  list.innerHTML = "";
  (s.captures || []).slice(0, 25).forEach((c) => {
    const li = document.createElement("li");
    const shipped = c.shipped == null ? "" : (` · ${typeof c.shipped === "number" ? "shipped " + c.shipped : c.shipped}`);
    li.innerHTML = `<code>${c.event_id}</code> · ${c.ticket_count} blk · ${money(c.price_min)}–${money(c.price_max)}` +
                   ` · q${c.requested_quantity ?? "?"} · ${fmtTime(c.captured_at)}${shipped}`;
    list.appendChild(li);
  });

  // hydrate config form
  $("url").value = cfg.ingestUrl || "";
  $("headers").value = cfg.headers ? JSON.stringify(cfg.headers) : "";
  $("enabled").checked = !!cfg.enabled;
}

async function saveConfig() {
  let headers = {};
  const raw = $("headers").value.trim();
  if (raw) {
    try { headers = JSON.parse(raw); }
    catch (e) { $("err").textContent = "Headers must be valid JSON"; return; }
  }
  await send({
    type: "save_config",
    config: { ingestUrl: $("url").value.trim(), headers, enabled: $("enabled").checked },
  });
  render();
}

async function exportJson() {
  const s = await send({ type: "get_state" });
  const blob = new Blob([JSON.stringify(s.captures || [], null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `broadway_captures_${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

async function clearAll() {
  await send({ type: "clear_captures" });
  render();
}

document.addEventListener("DOMContentLoaded", () => {
  $("save").addEventListener("click", saveConfig);
  $("export").addEventListener("click", exportJson);
  $("clear").addEventListener("click", clearAll);
  render();
});
