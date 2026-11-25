"use strict";

const $ = id => document.getElementById(id);
const send = msg => browser.runtime.sendMessage(msg);
const FIELDS = ["server", "secret", "lanes", "spacingMs", "timeoutS"];
let filled = false;

async function refresh() {
  const s = await send({ type: "status" });
  if (!filled) {
    for (const f of FIELDS) $(f).value = s.config[f];
    $("followBuyLink").checked = !!s.config.followBuyLink;
    filled = true;
  }
  $("state").textContent = s.running ? "· running" : "· stopped";
  $("state").className = s.running ? "ok" : "stat";
  const st = s.stats;
  const srv = s.server.reason ? ` · server: ${s.server.reason}` : "";
  const lanes = s.server.lanes ? ` · DB lanes ${s.server.lanes}, spacing ${s.server.spacingMs} ms` : "";
  $("summary").replaceChildren(
    `${st.reads} reads (${st.ok} ok, ${st.empty} empty, ${st.failed} failed) · ${st.listings} listings · ` +
    `reading ${s.busy.map(b => `${b.id} (lane ${b.lane})`).join(", ") || "nothing"} · ${s.queued} queued${lanes}${srv}`);
  if (s.lastError) {
    const e = document.createElement("div"); e.className = "bad"; e.textContent = s.lastError; $("summary").append(e);
  }
  const w = document.createElement("div"); w.textContent = `worker ext:${s.worker}`; $("summary").append(w);
  $("log").textContent = s.log.join("\n");
}

$("save").onclick = async () => {
  const patch = { followBuyLink: $("followBuyLink").checked };
  for (const f of FIELDS) patch[f] = $(f).value;
  await send({ type: "save", patch });
  $("pingOut").textContent = "saved";
};
$("ping").onclick = async () => {
  $("pingOut").textContent = "…";
  const r = await send({ type: "ping" });
  $("pingOut").textContent = r.ok ? `ok · reader=${r.answer.reader}, enabled=${r.answer.enabled}` : r.error;
  $("pingOut").className = r.ok ? "ok" : "bad";
};
$("start").onclick = async () => { await send({ type: "start" }); refresh(); };
$("stop").onclick = async () => { await send({ type: "stop" }); refresh(); };
$("reset").onclick = async () => {
  const r = await send({ type: "resetLanes" });
  $("pingOut").textContent = r.ok ? "lane containers reset" : r.error;
};

refresh();
setInterval(refresh, 2000);
