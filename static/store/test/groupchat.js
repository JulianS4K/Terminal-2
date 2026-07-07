// Group-chat concierge sandbox (/store/test/groupchat). External file because
// the sitewide CSP is script-src 'self' — inline scripts don't execute.
// Drives /api/store/group-chat/simulate: the real webhook pipeline (mention
// gate → transcript build → chat edge fn, owned scope) minus Twilio.
(() => {
  "use strict";
  const $ = (s) => document.querySelector(s);
  const threadEl = $("#thread");
  const statusEl = $("#status");
  const BOT = "vibepass";
  let thread = [];   // [{author, body}]
  let busy = false;

  function bubble(author, body, cls) {
    const b = document.createElement("div");
    b.className = "bubble " + cls;
    if (cls !== "hint") {
      const who = document.createElement("span");
      who.className = "who";
      who.textContent = author;
      b.appendChild(who);
    }
    // Concierge replies carry direct /store/event/{id} links — render them
    // clickable (DOM-built anchors; no innerHTML per the XSS lint rule).
    const parts = body.split(/(https?:\/\/\S+)/);
    for (const part of parts) {
      if (/^https?:\/\//.test(part)) {
        const a = document.createElement("a");
        a.href = part;
        a.target = "_blank";
        a.rel = "noopener";
        a.textContent = part;
        b.appendChild(a);
      } else if (part) {
        b.appendChild(document.createTextNode(part));
      }
    }
    threadEl.appendChild(b);
    threadEl.scrollTop = threadEl.scrollHeight;
  }

  function render(author, body) {
    const me = author === ($("#who").value || "Sam");
    bubble(author, body, author === BOT ? "bot" : (me ? "me" : "them"));
  }

  async function simulate() {
    busy = true;
    statusEl.textContent = "concierge is thinking…";
    try {
      const r = await fetch("/api/store/group-chat/simulate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: thread }),
      });
      const res = await r.json().catch(() => ({}));
      if (!r.ok) {
        statusEl.textContent = res.detail || ("error " + r.status);
        return;
      }
      if (res.status === "no-mention") {
        // Mirrors the real gating: without an @handle the bot stays out of
        // the conversation entirely.
        bubble("", "concierge stays silent — no @vibe mention", "hint");
        statusEl.textContent = "";
        return;
      }
      if (res.reply) {
        thread.push({ author: BOT, body: res.reply });
        render(BOT, res.reply);
      }
      if (res.history) {
        $("#debugHistory").textContent = JSON.stringify(res.history, null, 2);
      }
      statusEl.textContent = "";
    } catch (e) {
      statusEl.textContent = "network error — is the server up?";
    } finally {
      busy = false;
    }
  }

  $("#compose").addEventListener("submit", (ev) => {
    ev.preventDefault();
    if (busy) return;
    const author = ($("#who").value || "Sam").trim() || "Sam";
    const body = $("#msg").value.trim();
    if (!body) return;
    thread.push({ author, body });
    render(author, body);
    $("#msg").value = "";
    simulate();
  });

  $("#reset").addEventListener("click", () => {
    thread = [];
    threadEl.replaceChildren();
    $("#debugHistory").textContent = "(nothing sent yet)";
    statusEl.textContent = "";
    seed();
  });

  function seed() {
    bubble("", "You added vibepass to the group", "hint");
  }
  seed();
})();
