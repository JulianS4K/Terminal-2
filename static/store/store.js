/* VibePass storefront — MVP, browse only.
 * Talks to /api/store/* exclusively. No real purchases — Reserve is a
 * validation-only endpoint that returns a mock receipt. */
(function () {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  function fmtMoney(v) {
    if (v == null || isNaN(Number(v))) return "—";
    return "$" + Number(v).toLocaleString(undefined, {
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    });
  }

  function fmtWhen(iso) {
    if (!iso) return "";
    // occurs_at_local has trailing Z but is actually local time per AGENTS.md
    // Strip the Z so the browser doesn't double-shift it.
    const clean = iso.endsWith("Z") ? iso.slice(0, -1) : iso;
    const d = new Date(clean);
    if (isNaN(d.getTime())) return iso;
    const date = d.toLocaleDateString(undefined, {
      weekday: "short", month: "short", day: "numeric",
    });
    const time = d.toLocaleTimeString(undefined, {
      hour: "numeric", minute: "2-digit",
    });
    return `${date} · ${time}`;
  }

  async function api(path, init) {
    const r = await fetch(path, init);
    if (!r.ok) {
      const body = await r.text();
      let msg = body;
      try { msg = JSON.parse(body).detail || JSON.parse(body).error || body; } catch {}
      throw new Error(`${r.status} ${msg}`);
    }
    return r.json();
  }

  // ---------- Catalog page ----------
  function mountCatalog() {
    const form = $("#searchForm");
    const input = $("#q");
    const status = $("#status");
    const grid = $("#grid");
    const empty = $("#empty");

    let allEvents = [];

    function render(events) {
      grid.innerHTML = "";
      if (!events.length) {
        grid.hidden = true;
        empty.hidden = false;
        status.hidden = true;
        return;
      }
      empty.hidden = true;
      status.hidden = true;
      grid.hidden = false;

      for (const ev of events) {
        const a = document.createElement("a");
        a.className = "card";
        a.href = `/store/event/${ev.id}`;

        const when = document.createElement("div");
        when.className = "when";
        when.textContent = fmtWhen(ev.occurs_at_local);

        const name = document.createElement("div");
        name.className = "name";
        name.textContent = ev.name || "Untitled event";

        const where = document.createElement("div");
        where.className = "where";
        where.textContent = [ev.venue_name, ev.venue_location].filter(Boolean).join(" · ");

        const meta = document.createElement("div");
        meta.className = "meta";
        const left = document.createElement("div");
        left.className = "from";
        const priceSpan = document.createElement("span");
        priceSpan.className = "price";
        priceSpan.textContent = fmtMoney(ev.from_price);
        if (ev.from_price != null) {
          left.append("from ", priceSpan);
        } else {
          left.append(priceSpan);
        }
        const right = document.createElement("div");
        right.className = "qty";
        right.textContent = ev.owned_tickets_count
          ? `${ev.owned_tickets_count} tix · ${ev.owned_groups_count || 0} listings`
          : "available";
        meta.append(left, right);

        a.append(when, name, where, meta);
        grid.append(a);
      }
    }

    function filter(query) {
      const q = (query || "").trim().toLowerCase();
      if (!q) return render(allEvents);
      const filtered = allEvents.filter((e) => {
        const hay = [e.name, e.venue_name, e.venue_location, e.primary_performer_name]
          .filter(Boolean).join(" ").toLowerCase();
        return hay.includes(q);
      });
      render(filtered);
    }

    form.addEventListener("submit", (e) => {
      e.preventDefault();
      filter(input.value);
    });
    input.addEventListener("input", () => filter(input.value));

    api("/api/store/events?limit=120")
      .then((res) => {
        allEvents = res.events || [];
        render(allEvents);
      })
      .catch((err) => {
        status.textContent = `Couldn't load events: ${err.message}`;
        status.style.color = "var(--bad)";
      });
  }

  // ---------- Event detail page ----------
  function mountEvent() {
    // Two URL shapes:
    //   /store/event/{eventId}?zones=...    stateless (current)
    //   /s/{shareId}                        revocable share — resolves
    //                                       to an event_id + saved filters
    //                                       via the /api/store/share/{id}
    //                                       endpoint.
    const path = location.pathname;
    const sharedMatch = path.match(/^\/s\/([^/]+)$/);
    const shareId = sharedMatch ? sharedMatch[1] : null;

    // Clamp helpers — added 2026-05-11 security chat. Reject non-finite
    // values (Infinity, NaN) and out-of-band ints that could distort UI or
    // trigger backend errors.
    const clampInt = (v, lo, hi) => {
      const n = Number(v);
      if (!Number.isFinite(n)) return null;
      const i = Math.trunc(n);
      if (i < lo || i > hi) return null;
      return i;
    };
    const clampFloat = (v, lo, hi) => {
      const n = Number(v);
      if (!Number.isFinite(n)) return null;
      if (n < lo || n > hi) return null;
      return n;
    };

    let eventId = null;
    if (!shareId) {
      eventId = clampInt(path.split("/").pop(), 1, 1e9);
      if (!eventId) {
        $("#status").textContent = "Bad event id in URL.";
        return;
      }
    }

    const status = $("#status");
    const head = $("#header");
    const body = $("#body");
    const minQty = $("#minQty");
    const maxPrice = $("#maxPrice");
    const listEl = $("#listings");
    const noListings = $("#noListings");
    const listCount = $("#listCount");
    const seatMap = $("#seatMap");

    let allListings = [];
    let event = null;
    let zonesAvailable = [];   // populated from /api/store/events/{id}/zones
    let resolvedShare = null;  // populated when arriving via /s/{id}

    // Read share-link filters from the URL on load (only meaningful on the
    // /store/event/{id}?... path; /s/{id} fills these in after resolve).
    const urlParams = new URLSearchParams(location.search);
    // Hardened 2026-05-11: bound prices/qty and cap chip arrays at 50
    // entries / 64 chars each so a malicious URL can't bloat the share-UI.
    const _capArr = (s) => s.split(",").map((x) => x.trim()).filter(Boolean).filter((x) => x.length <= 64).slice(0, 50);
    const shareFilters = {
      zones: _capArr(urlParams.get("zones") || ""),
      section: _capArr(urlParams.get("section") || ""),
      min_price: urlParams.get("min_price") ? clampFloat(urlParams.get("min_price"), 0, 1e6) : null,
      max_price: urlParams.get("max_price") ? clampFloat(urlParams.get("max_price"), 0, 1e6) : null,
      min_qty: urlParams.get("min_qty") ? clampInt(urlParams.get("min_qty"), 1, 50) : null,
    };
    const hasUrlFilters = Object.values(shareFilters).some(
      (v) => Array.isArray(v) ? v.length : v != null
    );
    const isSharedView = hasUrlFilters || !!shareId;

    function renderList() {
      const minQ = Number(minQty.value) || 1;
      const maxP = Number(maxPrice.value) || Infinity;
      const filtered = allListings.filter((l) => {
        const splits = l.splits || [];
        const aQty = Number(l.available_quantity) || 0;
        const meetsQty = splits.length
          ? splits.some((s) => s >= minQ)
          : aQty >= minQ;
        const price = Number(l.retail_price) || 0;
        return meetsQty && price <= maxP;
      });

      listCount.textContent = `${filtered.length} of ${allListings.length}`;
      listEl.innerHTML = "";

      if (!filtered.length) {
        noListings.hidden = false;
        return;
      }
      noListings.hidden = true;

      for (const l of filtered) {
        const li = document.createElement("li");
        li.className = "row";

        const seat = document.createElement("div");
        seat.className = "seat";
        const section = document.createElement("div");
        section.className = "section";
        section.textContent = `Sec ${l.section || "—"}`;
        if (l.zone) {
          const zChip = document.createElement("span");
          zChip.className = "tag zone";
          zChip.textContent = l.zone;
          section.append(" ", zChip);
        }
        const rowLabel = document.createElement("div");
        rowLabel.className = "row-label";
        rowLabel.textContent = `Row ${l.row || "—"}`;
        seat.append(section, rowLabel);

        const splitsLabel = l.splits && l.splits.length ? l.splits.join(", ") : String(l.available_quantity || 0);
        const qbox = document.createElement("div");
        qbox.className = "qbox";
        qbox.append(
          document.createTextNode(`${l.available_quantity || 0} available`),
          document.createElement("br"),
        );
        const sellsIn = document.createElement("span");
        sellsIn.className = "muted";
        sellsIn.textContent = `sells in ${splitsLabel}`;
        qbox.append(sellsIn);

        const pbox = document.createElement("div");
        pbox.className = "pbox";
        pbox.append(document.createTextNode(fmtMoney(l.retail_price)));
        const eachSpan = document.createElement("span");
        eachSpan.className = "each";
        eachSpan.textContent = "each";
        pbox.append(eachSpan);

        const btn = document.createElement("button");
        btn.className = "btn";
        btn.textContent = "Reserve";
        btn.addEventListener("click", () => openModal(l));

        li.append(seat, qbox, pbox, btn);

        if (l.public_notes) {
          const notes = document.createElement("div");
          notes.className = "notes";
          notes.textContent = l.public_notes;
          li.append(notes);
        }

        if (l.in_hand === false) {
          const tag = document.createElement("span");
          tag.className = "tag warn";
          tag.textContent = l.in_hand_on ? `ships by ${new Date(l.in_hand_on).toLocaleDateString()}` : "ships later";
          rowLabel.append(" ", tag);
        } else if (l.instant_delivery) {
          const tag = document.createElement("span");
          tag.className = "tag";
          tag.textContent = "instant";
          rowLabel.append(" ", tag);
        }

        listEl.append(li);
      }
    }

    function openModal(listing) {
      const splits = listing.splits || [];
      const defaultQ = splits[0] || 1;

      const modal = $("#modal");
      const mb = $("#modalBody");

      // Build via DOM — was innerHTML with server-derived data. Hardened
      // 2026-05-11 (security chat).
      mb.replaceChildren();

      const h3 = document.createElement("h3");
      h3.style.margin = "0 0 4px";
      h3.textContent = "Reserve seats";

      const sub = document.createElement("p");
      sub.className = "muted";
      sub.style.margin = "0 0 12px";
      sub.textContent = `Section ${listing.section ?? "—"} · Row ${listing.row ?? "—"}`;

      const label = document.createElement("label");
      label.style.cssText = "display:flex;justify-content:space-between;align-items:center;margin:8px 0";
      const lblSpan = document.createElement("span");
      lblSpan.textContent = "Quantity";
      const qSel = document.createElement("select");
      qSel.id = "resQty";
      qSel.style.cssText = "background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:6px 8px;font:inherit";
      const availCap = Number(listing.available_quantity) || 999;
      for (const s of (splits.length ? splits : [1, 2, 3, 4]).filter((n) => Number(n) <= availCap)) {
        const opt = document.createElement("option");
        opt.value = String(s);
        opt.textContent = String(s);
        qSel.append(opt);
      }
      label.append(lblSpan, qSel);

      const receipt = document.createElement("div");
      receipt.className = "receipt";
      const mkRow = (k, vText, idV) => {
        const ks = document.createElement("span"); ks.className = "k"; ks.textContent = k;
        const vs = document.createElement("span"); vs.className = "v"; vs.textContent = vText;
        if (idV) vs.id = idV;
        receipt.append(ks, vs);
      };
      mkRow("Unit price", fmtMoney(listing.retail_price));
      mkRow("Quantity", String(defaultQ), "rcQty");
      const totK = document.createElement("span"); totK.className = "k total"; totK.textContent = "Subtotal";
      const totV = document.createElement("span"); totV.className = "v total"; totV.id = "rcTotal"; totV.textContent = fmtMoney(Number(listing.retail_price) * defaultQ);
      receipt.append(totK, totV);

      const confirm = document.createElement("button");
      confirm.className = "btn";
      confirm.id = "confirmReserve";
      confirm.style.width = "100%";
      confirm.textContent = "Reserve (mock)";

      const disc = document.createElement("p");
      disc.className = "disclaimer";
      disc.textContent = "MVP demo only — no payment will be processed and no order will be sent to Ticket Evolution. This shows what the confirmation flow would look like once checkout is wired up.";

      mb.append(h3, sub, label, receipt, confirm, disc);

      qSel.value = String(defaultQ);
      const recompute = () => {
        const q = Number(qSel.value);
        $("#rcQty", mb).textContent = String(q);
        totV.textContent = fmtMoney(Number(listing.retail_price) * q);
      };
      qSel.addEventListener("change", recompute);

      confirm.addEventListener("click", async () => {
        confirm.disabled = true;
        confirm.textContent = "Validating with TEvo…";
        try {
          const res = await api("/api/store/reserve", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              event_id: eventId,
              ticket_group_id: listing.id,
              quantity: Number(qSel.value),
            }),
          });
          renderReceipt(mb, res);
        } catch (err) {
          confirm.disabled = false;
          confirm.textContent = "Reserve (mock)";
          alert(`Could not reserve: ${err.message}`);
        }
      });

      modal.hidden = false;
    }

    function renderReceipt(mb, res) {
      const r = res.reservation || {};
      // Build via DOM — was innerHTML with server-derived data. Hardened
      // 2026-05-11 (security chat).
      mb.replaceChildren();

      const h3 = document.createElement("h3");
      h3.style.margin = "0 0 4px";
      h3.textContent = "Reservation confirmed (mock)";

      const msg = document.createElement("p");
      msg.className = "muted";
      msg.style.margin = "0 0 12px";
      msg.textContent = res.message || "";

      const receipt = document.createElement("div");
      receipt.className = "receipt";
      const mkRow = (k, vText, totalClass) => {
        const ks = document.createElement("span"); ks.className = totalClass ? "k total" : "k"; ks.textContent = k;
        const vs = document.createElement("span"); vs.className = totalClass ? "v total" : "v"; vs.textContent = vText;
        receipt.append(ks, vs);
      };
      mkRow("Event", `#${r.event_id}`);
      mkRow("Section", String(r.section ?? "—"));
      mkRow("Row", String(r.row ?? "—"));
      mkRow("Quantity", String(r.quantity ?? ""));
      mkRow("Unit price", fmtMoney(r.unit_price));
      mkRow("Total", fmtMoney(r.subtotal), true);

      const closeBtn = document.createElement("button");
      closeBtn.className = "btn ghost";
      closeBtn.id = "closeOk";
      closeBtn.style.width = "100%";
      closeBtn.textContent = "Close";

      mb.append(h3, msg, receipt, closeBtn);
      closeBtn.addEventListener("click", closeModal);
    }

    function closeModal() {
      $("#modal").hidden = true;
    }

    $("#closeModal").addEventListener("click", closeModal);
    $("#modal").addEventListener("click", (e) => {
      if (e.target.id === "modal") closeModal();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") closeModal();
    });

    minQty.addEventListener("change", renderList);
    maxPrice.addEventListener("input", renderList);

    // Share button — opens the share modal.
    $("#openShare").addEventListener("click", () => openShareModal());

    // "Show all" link inside the shared-view banner — strips URL filters.
    const clearShared = $("#clearShared");
    if (clearShared) {
      clearShared.href = location.pathname;
    }

    function buildEventQuery(extra) {
      const p = new URLSearchParams();
      const f = { ...shareFilters, ...(extra || {}) };
      if (f.zones && f.zones.length) p.set("zones", f.zones.join(","));
      if (f.section && f.section.length) p.set("section", f.section.join(","));
      if (f.min_price != null && f.min_price !== "") p.set("min_price", f.min_price);
      if (f.max_price != null && f.max_price !== "") p.set("max_price", f.max_price);
      if (f.min_qty != null && f.min_qty !== "") p.set("min_qty", f.min_qty);
      const qs = p.toString();
      return qs ? `?${qs}` : "";
    }

    function showSharedBanner(filters, totalBefore, listingsCount, share) {
      const banner = $("#sharedBanner");
      const summary = $("#sharedSummary");
      const clearLink = $("#clearShared");
      if (!isSharedView) { banner.hidden = true; return; }
      const parts = [];
      if (filters.zones?.length) parts.push(`zone: ${filters.zones.join(", ")}`);
      if (filters.section?.length) parts.push(`section: ${filters.section.join(", ")}`);
      if (filters.min_price != null) parts.push(`min ${fmtMoney(filters.min_price)}`);
      if (filters.max_price != null) parts.push(`max ${fmtMoney(filters.max_price)}`);
      if (filters.min_qty != null) parts.push(`${filters.min_qty}+ seats`);
      const filterText = parts.length ? parts.join(" · ") : "no filters";

      // Build via DOM — filterText carries URL-param + server data unescaped.
      // Hardened 2026-05-11 (security chat).
      summary.replaceChildren();
      const strong = document.createElement("strong");
      strong.textContent = "Shared view";
      summary.append(
        strong,
        document.createTextNode(` · ${filterText} · showing ${Number(listingsCount) || 0} of ${Number(totalBefore) || 0}`),
      );
      if (share) {
        const track = document.createElement("span");
        track.className = "muted";
        track.textContent = ` · link viewed ${Number(share.view_count) || 0}×`;
        summary.append(document.createTextNode(" "), track);
      }
      if (share?.note) {
        summary.append(document.createElement("br"));
        const noteSpan = document.createElement("span");
        noteSpan.style.fontStyle = "italic";
        noteSpan.textContent = `"${share.note}"`;
        summary.append(noteSpan);
      }

      if (clearLink && event?.id) clearLink.href = `/store/event/${Number(event.id) || 0}`;
      banner.hidden = false;
    }

    function applyEventResponse(res, share) {
      event = res.event;
      allListings = res.listings || [];

      $("#evName").textContent = event.name || "Untitled event";
      $("#evVenue").textContent = [event.venue?.name, event.venue?.location].filter(Boolean).join(" · ");
      $("#evDate").textContent = fmtWhen(event.occurs_at_local);
      $("#evPerformers").textContent = (event.performers || [])
        .map((p) => p.name + (p.primary ? " (home)" : ""))
        .join(" vs ");

      const map = event.configuration?.seating_chart_medium || event.configuration?.seating_chart_large;
      if (map) seatMap.src = map;
      else seatMap.style.display = "none";

      status.hidden = true;
      head.hidden = false;
      body.hidden = false;
      showSharedBanner(res.filters || {}, res.total_before_filters || 0, res.listings_count || 0, share);
      renderList();
    }

    function loadEvent() {
      if (shareId) {
        // Stateful share — server resolves filters + bumps view_count.
        return api(`/api/store/share/${encodeURIComponent(shareId)}`)
          .then((res) => {
            resolvedShare = res.share || null;
            // Backfill the share filters into the local state so the share
            // modal pre-fills correctly if the recipient re-opens it.
            if (resolvedShare?.filters) {
              const f = resolvedShare.filters;
              shareFilters.zones = f.zones || [];
              shareFilters.section = f.section || [];
              shareFilters.min_price = f.min_price != null ? Number(f.min_price) : null;
              shareFilters.max_price = f.max_price != null ? Number(f.max_price) : null;
              shareFilters.min_qty = f.min_qty != null ? Number(f.min_qty) : null;
            }
            eventId = res.event?.id;
            applyEventResponse(res, resolvedShare);
            return res;
          });
      }
      // Stateless share — filters come from URL params.
      return api(`/api/store/events/${eventId}${buildEventQuery()}`)
        .then((res) => { applyEventResponse(res, null); return res; });
    }

    function loadZones() {
      // For /s/{id} links the eventId is unknown until loadEvent resolves,
      // so the call is delayed in that path (see Promise chain below).
      if (!eventId) return Promise.resolve();
      return api(`/api/store/events/${eventId}/zones`)
        .then((res) => { zonesAvailable = res.zones || []; })
        .catch(() => { zonesAvailable = []; });
    }

    // ---------- Share modal ----------
    function openShareModal() {
      const modal = $("#modal");
      const mb = $("#modalBody");

      // Distinct sections present in the currently-loaded listings — so the
      // share dialog suggests sections the seller actually has.
      const sectionsPresent = Array.from(new Set(
        allListings.map((l) => String(l.section || "").trim()).filter(Boolean)
      )).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

      const zoneOpts = zonesAvailable.length
        ? zonesAvailable.map((z) =>
            `<label class="chip"><input type="checkbox" value="${escapeAttr(z.name)}" data-zone /> ${escapeHtml(z.name)} <span class="muted">(${z.tickets || 0})</span></label>`
          ).join("")
        : `<span class="muted">No curated zones for this event yet — use sections or price.</span>`;

      const sectionOpts = sectionsPresent.length
        ? sectionsPresent.map((s) =>
            `<label class="chip"><input type="checkbox" value="${escapeAttr(s)}" data-section /> ${escapeHtml(s)}</label>`
          ).join("")
        : `<span class="muted">No sections available.</span>`;

      mb.innerHTML = `
        <h3 style="margin:0 0 4px">Share inventory</h3>
        <p class="muted" style="margin:0 0 16px">
          Pick what to share — recipients see only listings matching these filters.
        </p>

        <div class="share-section">
          <div class="share-label">Zones</div>
          <div class="chip-row" id="zoneChips">${zoneOpts}</div>
        </div>

        <div class="share-section">
          <div class="share-label">Sections</div>
          <div class="chip-row" id="sectionChips">${sectionOpts}</div>
          <input id="sectionExtra" placeholder="extra sections (CSV)" class="share-input" />
        </div>

        <div class="share-section">
          <div class="share-label">Price (per seat)</div>
          <div class="share-row">
            <input id="shareMin" type="number" min="0" step="10" placeholder="min $" />
            <input id="shareMax" type="number" min="0" step="10" placeholder="max $" />
          </div>
        </div>

        <div class="share-section">
          <div class="share-label">Minimum quantity</div>
          <select id="shareMinQty">
            <option value="">any</option>
            <option value="2">2+</option>
            <option value="3">3+</option>
            <option value="4">4+</option>
            <option value="6">6+</option>
          </select>
        </div>

        <div class="share-preview">
          <span id="sharePreview" class="muted">Pick filters above to preview.</span>
        </div>

        <div class="share-section">
          <label class="share-toggle">
            <input type="checkbox" id="useRevocable" />
            <span><strong>Make this revocable</strong>
              <span class="muted">tracks views, expires, can be turned off later</span>
            </span>
          </label>
          <div id="revocableOpts" hidden>
            <input id="shareNote" class="share-input" maxlength="500"
                   placeholder="Optional note for the recipient" />
            <select id="shareExpires" class="share-input" style="margin-top:6px">
              <option value="">never expires</option>
              <option value="1">expires in 1 day</option>
              <option value="7" selected>expires in 7 days</option>
              <option value="30">expires in 30 days</option>
              <option value="90">expires in 90 days</option>
            </select>
          </div>
        </div>

        <input id="shareUrl" class="share-url" readonly />
        <div class="share-actions">
          <a href="/store/shares" class="btn ghost" style="text-decoration:none">Manage links</a>
          <span style="flex:1"></span>
          <button class="btn ghost" id="shareReset">Reset</button>
          <button class="btn" id="shareCopy">Copy link</button>
        </div>
      `;

      // Pre-fill controls if a shared filter is already in the URL — lets the
      // owner tweak an existing share.
      if (shareFilters.zones?.length) {
        for (const cb of $$("#zoneChips input[data-zone]", mb)) {
          if (shareFilters.zones.includes(cb.value)) cb.checked = true;
        }
      }
      if (shareFilters.section?.length) {
        for (const cb of $$("#sectionChips input[data-section]", mb)) {
          if (shareFilters.section.includes(cb.value)) cb.checked = true;
        }
        const known = new Set(sectionsPresent);
        const extras = shareFilters.section.filter((s) => !known.has(s));
        if (extras.length) $("#sectionExtra", mb).value = extras.join(",");
      }
      if (shareFilters.min_price != null) $("#shareMin", mb).value = shareFilters.min_price;
      if (shareFilters.max_price != null) $("#shareMax", mb).value = shareFilters.max_price;
      if (shareFilters.min_qty != null) $("#shareMinQty", mb).value = String(shareFilters.min_qty);

      function readShareForm() {
        const zones = $$("#zoneChips input[data-zone]", mb).filter((c) => c.checked).map((c) => c.value);
        const sectionChips = $$("#sectionChips input[data-section]", mb).filter((c) => c.checked).map((c) => c.value);
        const sectionExtra = ($("#sectionExtra", mb).value || "")
          .split(",").map((s) => s.trim()).filter(Boolean);
        const sections = Array.from(new Set([...sectionChips, ...sectionExtra]));
        const minP = $("#shareMin", mb).value;
        const maxP = $("#shareMax", mb).value;
        const mq = $("#shareMinQty", mb).value;
        return {
          zones,
          section: sections,
          min_price: minP === "" ? null : Number(minP),
          max_price: maxP === "" ? null : Number(maxP),
          min_qty: mq === "" ? null : Number(mq),
        };
      }

      function buildShareUrl(f) {
        const p = new URLSearchParams();
        if (f.zones.length) p.set("zones", f.zones.join(","));
        if (f.section.length) p.set("section", f.section.join(","));
        if (f.min_price != null) p.set("min_price", f.min_price);
        if (f.max_price != null) p.set("max_price", f.max_price);
        if (f.min_qty != null) p.set("min_qty", f.min_qty);
        const qs = p.toString();
        return `${location.origin}/store/event/${eventId}${qs ? "?" + qs : ""}`;
      }

      let previewTimer = null;
      function refreshUrlPreview() {
        // Only the stateless URL is shown live; the revocable URL is generated
        // on click of "Generate link" since it requires a server round trip.
        const f = readShareForm();
        const url = buildShareUrl(f);
        const useRev = $("#useRevocable", mb).checked;
        if (!useRev) {
          $("#shareUrl", mb).value = url;
          $("#shareUrl", mb).placeholder = "";
          $("#shareCopy", mb).textContent = "Copy link";
        } else {
          $("#shareUrl", mb).value = "";
          $("#shareUrl", mb).placeholder = "click Generate to create a /s/… link";
          $("#shareCopy", mb).textContent = "Generate link";
        }
        $("#revocableOpts", mb).hidden = !useRev;
      }

      function refreshCountPreview() {
        const f = readShareForm();
        clearTimeout(previewTimer);
        previewTimer = setTimeout(async () => {
          try {
            const qp = new URLSearchParams();
            if (f.zones.length) qp.set("zones", f.zones.join(","));
            if (f.section.length) qp.set("section", f.section.join(","));
            if (f.min_price != null) qp.set("min_price", f.min_price);
            if (f.max_price != null) qp.set("max_price", f.max_price);
            if (f.min_qty != null) qp.set("min_qty", f.min_qty);
            const res = await api(`/api/store/events/${eventId}?${qp.toString()}`);
            // Build via DOM — was innerHTML with server numbers. Hardened 2026-05-11.
            const preview = $("#sharePreview", mb);
            preview.replaceChildren();
            const s = document.createElement("strong");
            s.textContent = String(Number(res.listings_count) || 0);
            preview.append(s, document.createTextNode(` of ${Number(res.total_before_filters) || 0} listings would be shared`));
          } catch (e) {
            $("#sharePreview", mb).textContent = `preview failed: ${e.message}`;
          }
        }, 200);
      }

      function updatePreview() {
        refreshUrlPreview();
        refreshCountPreview();
      }

      mb.addEventListener("change", updatePreview);
      mb.addEventListener("input", updatePreview);

      $("#shareReset", mb).addEventListener("click", () => {
        $$("input[type=checkbox]", mb).forEach((c) => (c.checked = false));
        $$('input[type="number"], input[type="text"]', mb).forEach((i) => (i.value = ""));
        $("#sectionExtra", mb).value = "";
        $("#shareMinQty", mb).value = "";
        $("#shareNote", mb) && ($("#shareNote", mb).value = "");
        updatePreview();
      });

      $("#shareCopy", mb).addEventListener("click", async () => {
        const useRev = $("#useRevocable", mb).checked;
        const btn = $("#shareCopy", mb);

        async function copy(url) {
          try {
            await navigator.clipboard.writeText(url);
            const old = btn.textContent;
            btn.textContent = "Copied ✓";
            setTimeout(() => (btn.textContent = old), 1200);
          } catch {
            $("#shareUrl", mb).select();
          }
        }

        if (!useRev) {
          await copy($("#shareUrl", mb).value);
          return;
        }

        // Revocable: persist a share_links row.
        btn.disabled = true;
        btn.textContent = "Generating…";
        try {
          const f = readShareForm();
          const note = ($("#shareNote", mb)?.value || "").trim();
          const exp = $("#shareExpires", mb)?.value;
          const body = {
            event_id: eventId,
            filters: f,
            note: note || undefined,
            expires_in_days: exp ? Number(exp) : undefined,
          };
          const created = await api("/api/store/share", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
          });
          const url = `${location.origin}${created.url}`;
          $("#shareUrl", mb).value = url;
          await copy(url);
        } catch (e) {
          $("#shareUrl", mb).value = "";
          alert(`Could not create link: ${e.message}`);
          btn.textContent = "Generate link";
        } finally {
          btn.disabled = false;
        }
      });

      updatePreview();
      modal.hidden = false;
    }

    // For /store/event/{id} we know eventId up front and can fire both calls
    // in parallel. For /s/{id} we have to load the share first to discover
    // the eventId, then load zones.
    if (shareId) {
      loadEvent()
        .then(() => loadZones())
        .catch((err) => {
          if (err.message.includes("410")) {
            status.textContent = "This share link is no longer active.";
          } else {
            status.textContent = `Couldn't load event: ${err.message}`;
          }
          status.style.color = "var(--bad)";
        });
    } else {
      Promise.all([loadZones(), loadEvent()]).catch((err) => {
        status.textContent = `Couldn't load event: ${err.message}`;
        status.style.color = "var(--bad)";
      });
    }
  }

  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }
  function escapeAttr(s) { return escapeHtml(s); }

  // ---------- Shares admin page ----------
  function mountSharesAdmin() {
    const status = $("#status");
    const empty = $("#empty");
    const tbl = $("#sharesTbl");
    const tbody = $("#sharesBody");
    const includeInactive = $("#includeInactive");

    function fmtFilters(f) {
      if (!f) return "";
      const parts = [];
      if (f.zones?.length) parts.push(`zone: ${f.zones.join(", ")}`);
      if (f.section?.length) parts.push(`section: ${f.section.join(", ")}`);
      if (f.min_price != null) parts.push(`≥ ${fmtMoney(f.min_price)}`);
      if (f.max_price != null) parts.push(`≤ ${fmtMoney(f.max_price)}`);
      if (f.min_qty != null) parts.push(`${f.min_qty}+ seats`);
      return parts.join(" · ") || "(no filters)";
    }

    function fmtStatusInto(target, s) {
      // DOM-only renderer for the status pill column. Replaces the prior
      // fmtStatus(s) -> HTML string -> td.innerHTML pattern that was
      // flagged by the 2026-05-11 security audit.
      target.replaceChildren();
      const mk = (cls, text) => {
        const el = document.createElement("span");
        el.className = cls;
        el.textContent = text;
        return el;
      };
      if (s.revoked_at) { target.append(mk("pill bad", "revoked")); return; }
      if (s.expires_at) {
        const exp = new Date(s.expires_at);
        if (!isNaN(exp.getTime()) && exp <= new Date()) {
          target.append(mk("pill bad", "expired"));
          return;
        }
        target.append(mk("pill good", "active"));
        target.append(document.createTextNode(" "));
        target.append(mk("muted", `until ${exp.toLocaleDateString()}`));
        return;
      }
      target.append(mk("pill good", "active"));
    }

    async function load() {
      status.hidden = false;
      tbl.hidden = true;
      empty.hidden = true;

      try {
        const url = `/api/store/shares?include_inactive=${includeInactive.checked}`;
        const res = await api(url);
        const shares = res.shares || [];

        if (!shares.length) {
          empty.hidden = false;
          status.hidden = true;
          return;
        }

        tbody.replaceChildren();
        for (const s of shares) {
          const tr = document.createElement("tr");
          tr.dataset.id = s.id;
          const fullUrl = `${location.origin}${s.url}`;

          // Build via DOM — was innerHTML with server data, only some escaped.
          // Hardened 2026-05-11 (security chat).
          const td1 = document.createElement("td");
          const aSlug = document.createElement("a");
          aSlug.className = "mono";
          aSlug.href = String(s.url || "");
          aSlug.textContent = `/s/${s.id}`;
          td1.append(aSlug);

          const td2 = document.createElement("td");
          const aEvent = document.createElement("a");
          aEvent.href = `/store/event/${Number(s.event_id) || 0}`;
          aEvent.textContent = `#${Number(s.event_id) || 0}`;
          td2.append(aEvent);

          const td3 = document.createElement("td");
          const mutedSpan = document.createElement("span");
          mutedSpan.className = "muted";
          mutedSpan.textContent = fmtFilters(s.filters);
          td3.append(mutedSpan);

          const td4 = document.createElement("td");
          td4.textContent = String(s.note || "");

          const td5 = document.createElement("td");
          td5.textContent = String(Number(s.view_count) || 0);

          const td6 = document.createElement("td");
          // fmtStatus returns small static HTML; reparse safely via DOMParser
          // or rebuild via DOM. Rebuild here is simpler.
          fmtStatusInto(td6, s);

          const td7 = document.createElement("td");
          td7.className = "actions";
          const copyBtn = document.createElement("button");
          copyBtn.className = "btn ghost copy-btn";
          copyBtn.dataset.url = fullUrl;
          copyBtn.textContent = "copy";
          td7.append(copyBtn);
          if (!s.revoked_at) {
            const revBtn = document.createElement("button");
            revBtn.className = "btn ghost revoke-btn";
            revBtn.dataset.id = String(s.id || "");
            revBtn.textContent = "revoke";
            td7.append(revBtn);
          }

          tr.append(td1, td2, td3, td4, td5, td6, td7);
          tbody.append(tr);
        }

        tbl.hidden = false;
        status.hidden = true;
      } catch (e) {
        status.textContent = `Couldn't load: ${e.message}`;
        status.style.color = "var(--bad)";
      }
    }

    tbl.addEventListener("click", async (e) => {
      const copyBtn = e.target.closest(".copy-btn");
      if (copyBtn) {
        try {
          await navigator.clipboard.writeText(copyBtn.dataset.url);
          const old = copyBtn.textContent;
          copyBtn.textContent = "copied ✓";
          setTimeout(() => (copyBtn.textContent = old), 1200);
        } catch {}
        return;
      }
      const revBtn = e.target.closest(".revoke-btn");
      if (revBtn) {
        const id = revBtn.dataset.id;
        if (!confirm(`Revoke /s/${id}? Recipients will see "no longer active".`)) return;
        revBtn.disabled = true;
        revBtn.textContent = "revoking…";
        try {
          await api(`/api/store/share/${encodeURIComponent(id)}`, { method: "DELETE" });
          await load();
        } catch (err) {
          alert(`Couldn't revoke: ${err.message}`);
          revBtn.disabled = false;
          revBtn.textContent = "revoke";
        }
      }
    });

    includeInactive.addEventListener("change", load);
    load();
  }

  window.Store = { mountCatalog, mountEvent, mountSharesAdmin };

  // Auto-mount based on body data-page. Lets HTML pages drop their inline
  // `<script>Store.mountX()</script>` so we can ship a strict CSP without
  // 'unsafe-inline'. Added 2026-05-11 (security chat).
  function _autoMount() {
    const page = document.body && document.body.dataset && document.body.dataset.page;
    if (page === "catalog") mountCatalog();
    else if (page === "event") mountEvent();
    else if (page === "shares") mountSharesAdmin();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", _autoMount);
  } else {
    _autoMount();
  }
})();
