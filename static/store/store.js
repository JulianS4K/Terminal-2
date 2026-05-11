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

    function render(events, mode) {
      // mode: "all" (initial load) or "search" (after a query)
      grid.innerHTML = "";
      status.hidden = true;
      if (!events.length) {
        grid.hidden = true;
        empty.hidden = false;
        empty.textContent = mode === "search"
          ? "No events match. Try a broader search, or clear the box to see all."
          : "No events with available inventory right now. Check back after the next collector run.";
        return;
      }
      empty.hidden = true;
      grid.hidden = false;

      for (const ev of events) {
        const a = document.createElement("a");
        a.className = "card";
        a.href = `/store/event/${ev.id}`;
        if (ev.primary_performer_color) {
          a.style.setProperty("--card-accent", ev.primary_performer_color);
        }

        // Header row: logo (if branded) + meta lines.
        const head = document.createElement("div");
        head.className = "card-head";
        if (ev.primary_performer_logo) {
          const img = document.createElement("img");
          img.className = "card-logo";
          img.src = ev.primary_performer_logo;
          img.alt = "";
          img.loading = "lazy";
          head.append(img);
        }
        const headText = document.createElement("div");
        const when = document.createElement("div");
        when.className = "when";
        when.textContent = fmtWhen(ev.occurs_at_local);
        const name = document.createElement("div");
        name.className = "name";
        name.textContent = ev.name || "Untitled event";
        headText.append(when, name);
        head.append(headText);

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

        a.append(head, where, meta);
        grid.append(a);
      }
    }

    function filter(query) {
      const q = (query || "").trim().toLowerCase();
      if (!q) return render(allEvents, "all");
      const filtered = allEvents.filter((e) => {
        const hay = [e.name, e.venue_name, e.venue_location, e.primary_performer_name]
          .filter(Boolean).join(" ").toLowerCase();
        return hay.includes(q);
      });
      render(filtered, "search");
    }

    form.addEventListener("submit", (e) => {
      e.preventDefault();
      filter(input.value);
    });
    input.addEventListener("input", () => filter(input.value));

    api("/api/store/events?limit=500")
      .then((res) => {
        allEvents = res.events || [];
        render(allEvents, "all");
      })
      .catch((err) => {
        status.textContent = `Couldn't load events: ${err.message}`;
        status.style.color = "var(--bad)";
      });
  }

  // ---------- Event detail page ----------
  function mountEvent() {
    // The event/listings page is also the share-link surface — the URL is
    // the source of truth for the filter set. Two URL shapes can land here:
    //
    //   /store/event/{eventId}?zones=...&min_qty=...   stateless filtered
    //   /s/{shareId}                                   revocable share — resolves
    //                                                  via /api/store/share/{id},
    //                                                  then we replaceState into
    //                                                  the canonical event URL
    //                                                  with the saved filters.
    //
    // Filter inputs on the page are bound to the URL:
    //   - chip click / input change -> debounced -> writes URL via
    //     replaceState -> refetches /api/store/events/{id}?<filters>
    //   - server-side filter is the only filter (no client-side narrowing)
    //   - "Share this view" just serializes the current URL
    let path = location.pathname;
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

    // DOM refs (ALL pulled here so the helpers below don't re-query).
    const status = $("#status");
    const head = $("#header");
    const body = $("#body");
    const listEl = $("#listings");
    const noListings = $("#noListings");
    const listCount = $("#listCount");
    const seatMap = $("#seatMap");
    const zoneRow = $("#zoneRow");
    const zoneChipsEl = $("#zoneChips");
    const sectionRow = $("#sectionRow");
    const sectionChipsEl = $("#sectionChips");
    const minPriceInput = $("#minPrice");
    const maxPriceInput = $("#maxPrice");
    const minQtyInput = $("#minQty");
    const resetBtn = $("#resetFilters");

    let allListings = [];
    // Section universe — server tells us every section present in the
    // unfiltered owned set (`sections_available`). We cache it so the
    // section chip group keeps showing every section even after the user
    // selects one and the listings narrow. Multi-select needs all chips
    // to stay clickable.
    let sectionsAvailable = [];
    let event = null;
    let zonesAvailable = [];   // populated from /api/store/events/{id}/zones
    let resolvedShare = null;  // populated when arriving via /s/{id}
    let suppressApply = false; // true while we paint inputs programmatically

    // ---- URL <-> filter conversion (hardened per #57's A1 review:
    // cap array sizes + clamp numeric ranges so a malicious URL can't
    // bloat the share-UI or trigger backend errors). ----
    const _capArr = (s) => s.split(",").map((x) => x.trim()).filter(Boolean)
                            .filter((x) => x.length <= 64).slice(0, 50);
    function parseUrlFilters() {
      const u = new URLSearchParams(location.search);
      return {
        zones:    _capArr(u.get("zones") || ""),
        section:  _capArr(u.get("section") || ""),
        min_price: u.get("min_price") ? clampFloat(u.get("min_price"), 0, 1e6) : null,
        max_price: u.get("max_price") ? clampFloat(u.get("max_price"), 0, 1e6) : null,
        min_qty:   u.get("min_qty") ? clampInt(u.get("min_qty"), 1, 50) : null,
      };
    }

    function buildQueryString(f) {
      const p = new URLSearchParams();
      if (f.zones && f.zones.length)     p.set("zones", f.zones.join(","));
      if (f.section && f.section.length) p.set("section", f.section.join(","));
      if (f.min_price != null)           p.set("min_price", f.min_price);
      if (f.max_price != null)           p.set("max_price", f.max_price);
      if (f.min_qty != null)             p.set("min_qty", f.min_qty);
      const qs = p.toString();
      return qs ? `?${qs}` : "";
    }

    function hasActiveFilters(f) {
      return (f.zones && f.zones.length)
        || (f.section && f.section.length)
        || f.min_price != null
        || f.max_price != null
        || f.min_qty != null;
    }

    function readFiltersFromUI() {
      return {
        zones:    $$(".filter-chip.on", zoneChipsEl).map(c => c.dataset.value),
        section:  $$(".filter-chip.on", sectionChipsEl).map(c => c.dataset.value),
        min_price: minPriceInput.value === "" ? null : Number(minPriceInput.value),
        max_price: maxPriceInput.value === "" ? null : Number(maxPriceInput.value),
        min_qty:   minQtyInput.value === "" ? null : Number(minQtyInput.value),
      };
    }

    function paintInputsFromFilters(f) {
      suppressApply = true;
      try {
        minPriceInput.value = f.min_price ?? "";
        maxPriceInput.value = f.max_price ?? "";
        minQtyInput.value   = f.min_qty != null ? String(f.min_qty) : "";
      } finally {
        suppressApply = false;
      }
    }

    function updateUrl(f) {
      const qs = buildQueryString(f);
      const newUrl = `/store/event/${eventId}${qs}`;
      if (newUrl !== location.pathname + location.search) {
        history.replaceState({}, "", newUrl);
      }
    }

    // ---- Listings rendering (server already filtered) ----
    function renderListings() {
      listCount.textContent = `${allListings.length}`;
      listEl.innerHTML = "";
      if (!allListings.length) {
        noListings.hidden = false;
        return;
      }
      noListings.hidden = true;
      for (const l of allListings) {
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

    // ---- Filter chip rendering ----
    function renderZoneChips(activeZones) {
      // Zones row appears ONLY when this event has curated zones in
      // performer_zones (today: NYK at MSG and a handful of others).
      // For everything else, the row stays hidden — sections/price/qty cover it.
      if (!zonesAvailable.length) {
        zoneRow.hidden = true;
        return;
      }
      zoneRow.hidden = false;
      zoneChipsEl.innerHTML = "";
      const activeSet = new Set(activeZones || []);
      const all = Array.from(new Set([...zonesAvailable.map(z => z.name), ...activeSet]));
      for (const name of all) {
        const meta = zonesAvailable.find(z => z.name === name);
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "filter-chip" + (activeSet.has(name) ? " on" : "");
        chip.dataset.value = name;
        chip.textContent = meta && meta.tickets ? `${name} (${meta.tickets})` : name;
        chip.addEventListener("click", () => {
          chip.classList.toggle("on");
          scheduleApply();
        });
        zoneChipsEl.append(chip);
      }
    }

    function renderSectionChips(activeSections) {
      // Sections come from `sections_available` (server-side, unfiltered
      // universe). Falls back to the currently-loaded listings if the
      // server didn't send it (defensive — older share-resolve responses).
      // Active sections that aren't in either set are still shown so the
      // user can clear/toggle them. Multi-select works because all chips
      // stay clickable regardless of how the user narrows.
      const fromServer = sectionsAvailable || [];
      const fromListings = allListings.map(l => String(l.section || "").trim()).filter(Boolean);
      const activeSet = new Set(activeSections || []);
      const all = Array.from(new Set([...fromServer, ...fromListings, ...activeSet]))
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
      if (!all.length) {
        sectionRow.hidden = true;
        return;
      }
      sectionRow.hidden = false;
      sectionChipsEl.innerHTML = "";
      for (const s of all) {
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "filter-chip" + (activeSet.has(s) ? " on" : "");
        chip.dataset.value = s;
        chip.textContent = s;
        chip.addEventListener("click", () => {
          chip.classList.toggle("on");
          scheduleApply();
        });
        sectionChipsEl.append(chip);
      }
    }

    // ---- Apply filter changes: read UI -> URL -> fetch -> render ----
    let applyTimer = null;
    function scheduleApply() {
      if (suppressApply) return;
      clearTimeout(applyTimer);
      applyTimer = setTimeout(applyFiltersAndFetch, 250);
    }

    async function applyFiltersAndFetch() {
      const f = readFiltersFromUI();
      updateUrl(f);
      try {
        const res = await api(`/api/store/events/${eventId}${buildQueryString(f)}`);
        applyEventResponse(res, resolvedShare);
      } catch (err) {
        // Filter apply failures don't break the existing rendered state —
        // surface in the banner only.
        console.error("filter apply failed:", err);
      }
    }

    // ---- Banner: shows when any filter is active or arriving via /s/{id} ----
    function showSharedBanner(filters, totalBefore, listingsCount, share) {
      const banner = $("#sharedBanner");
      const summary = $("#sharedSummary");
      const clearLink = $("#clearShared");
      const isFiltered = hasActiveFilters(filters || {});
      if (!isFiltered && !share) {
        banner.hidden = true;
        return;
      }
      const parts = [];
      if (filters.zones?.length) parts.push(`zone: ${filters.zones.join(", ")}`);
      if (filters.section?.length) parts.push(`section: ${filters.section.join(", ")}`);
      if (filters.min_price != null) parts.push(`min ${fmtMoney(filters.min_price)}`);
      if (filters.max_price != null) parts.push(`max ${fmtMoney(filters.max_price)}`);
      if (filters.min_qty != null) parts.push(`${filters.min_qty}+ seats`);
      const filterText = parts.length ? parts.join(" · ") : "no filters";

      // Build via DOM — filterText carries URL-param + server data unescaped.
      // Hardened 2026-05-11 (PR #57 A1 security review). Distinguishes
      // "Filtered view" (user just filtered inline) from "Shared view"
      // (arrived via /s/{id}).
      summary.replaceChildren();
      const strong = document.createElement("strong");
      strong.textContent = share ? "Shared view" : "Filtered view";
      summary.append(
        strong,
        document.createTextNode(
          ` · ${filterText} · showing ${Number(listingsCount) || 0} of ${Number(totalBefore) || 0}`
        ),
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

      if (clearLink && eventId) clearLink.href = `/store/event/${Number(eventId) || 0}`;
      banner.hidden = false;
    }

    // ---- Apply event response: paint header + listings + chip state ----
    function applyEventResponse(res, share) {
      event = res.event;
      allListings = res.listings || [];
      // Server tells us every section in the unfiltered set — cache so the
      // chip group keeps showing every section even after the user narrows.
      if (Array.isArray(res.sections_available) && res.sections_available.length) {
        sectionsAvailable = res.sections_available;
      }
      const filters = res.filters || readFiltersFromUI();

      $("#evName").textContent = event.name || "Untitled event";
      $("#evVenue").textContent = [event.venue?.name, event.venue?.location].filter(Boolean).join(" · ");
      $("#evDate").textContent = fmtWhen(event.occurs_at_local);

      const perfEl = $("#evPerformers");
      perfEl.innerHTML = "";
      const perfs = event.performers || [];
      perfs.forEach((p, i) => {
        if (i > 0) {
          const sep = document.createElement("span");
          sep.className = "muted";
          sep.textContent = " vs ";
          perfEl.append(sep);
        }
        const span = document.createElement("span");
        span.className = "perf-chip";
        if (p.color_primary) span.style.setProperty("--perf-color", p.color_primary);
        if (p.logo_url) {
          const img = document.createElement("img");
          img.src = p.logo_url;
          img.alt = "";
          img.className = "perf-logo";
          img.loading = "lazy";
          span.append(img);
        }
        const txt = document.createElement("span");
        txt.textContent = p.name + (p.primary ? " (home)" : "");
        span.append(txt);
        perfEl.append(span);
      });

      const map = event.configuration?.seating_chart_medium || event.configuration?.seating_chart_large;
      if (map) seatMap.src = map;
      else seatMap.style.display = "none";

      const freshness = $("#freshness");
      if (freshness) {
        if (res.inventory_source === "cache") {
          freshness.textContent = "inventory cached (≤10s)";
          freshness.className = "freshness cached";
        } else if (res.inventory_source === "live") {
          freshness.textContent = "live inventory";
          freshness.className = "freshness live";
        } else if (res.inventory_source === "snapshot") {
          // SQL-only demo mode — be honest about staleness so testers and
          // share-link recipients know what they're looking at.
          const age = Number(res.snapshot_age_seconds) || 0;
          const human = age < 60 ? `${age}s`
                      : age < 3600 ? `${Math.round(age/60)}m`
                      : age < 86400 ? `${Math.round(age/3600)}h`
                      : `${Math.round(age/86400)}d`;
          freshness.textContent = `demo · snapshot ${human} old`;
          freshness.className = "freshness cached";
        } else {
          freshness.textContent = "";
        }
      }

      status.hidden = true;
      head.hidden = false;
      body.hidden = false;
      renderListings();
      // Re-render section chips against the new listings (sections may have
      // shifted as filters narrowed); zone chips are event-static so don't
      // need re-rendering here.
      renderSectionChips(filters.section || []);
      showSharedBanner(filters, res.total_before_filters || 0, res.listings_count || 0, share);
    }

    // ---- Filter input wiring ----
    minPriceInput.addEventListener("input", scheduleApply);
    maxPriceInput.addEventListener("input", scheduleApply);
    minQtyInput.addEventListener("change", scheduleApply);
    resetBtn.addEventListener("click", () => {
      paintInputsFromFilters({});
      $$(".filter-chip", $("#filterBar")).forEach((c) => c.classList.remove("on"));
      // No debounce — Reset is intentional.
      applyFiltersAndFetch();
    });

    // ---- Modal close handlers (shared by reserve + share modals) ----
    $("#closeModal").addEventListener("click", closeModal);
    $("#modal").addEventListener("click", (e) => {
      if (e.target.id === "modal") closeModal();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") closeModal();
    });

    // ---- Share button ----
    $("#openShare").addEventListener("click", openShareModal);

    // ---- Share modal: serializes the CURRENT URL. No filter UI here.
    //      The page itself is the filter UI; share is just a copy/save action. ----
    function openShareModal() {
      const modal = $("#modal");
      const mb = $("#modalBody");
      const f = readFiltersFromUI();
      const statelessUrl = `${location.origin}/store/event/${eventId}${buildQueryString(f)}`;

      const summaryParts = [];
      if (f.zones.length)     summaryParts.push(`zone: ${f.zones.join(", ")}`);
      if (f.section.length)   summaryParts.push(`section: ${f.section.join(", ")}`);
      if (f.min_price != null) summaryParts.push(`min ${fmtMoney(f.min_price)}`);
      if (f.max_price != null) summaryParts.push(`max ${fmtMoney(f.max_price)}`);
      if (f.min_qty != null)   summaryParts.push(`${f.min_qty}+ seats`);
      const summary = summaryParts.length
        ? summaryParts.join(" · ")
        : "no filters — full inventory";
      const listingCount = allListings.length;

      mb.innerHTML = `
        <h3 style="margin:0 0 4px">Share this view</h3>
        <p class="muted" style="margin:0 0 12px">
          ${escapeHtml(summary)} · ${listingCount} listing${listingCount === 1 ? "" : "s"}
        </p>

        <input id="shareUrl" class="share-url" readonly value="${escapeAttr(statelessUrl)}" />

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

        <div class="share-actions">
          <a href="/store/shares" class="btn ghost" style="text-decoration:none">Manage links</a>
          <span style="flex:1"></span>
          <button class="btn" id="shareCopy">Copy link</button>
        </div>
      `;

      const useRevToggle = $("#useRevocable", mb);
      const copyBtn = $("#shareCopy", mb);
      const urlInput = $("#shareUrl", mb);

      function refreshButton() {
        const useRev = useRevToggle.checked;
        $("#revocableOpts", mb).hidden = !useRev;
        if (useRev) {
          urlInput.value = "";
          urlInput.placeholder = "click Generate to create a /s/… link";
          copyBtn.textContent = "Generate link";
        } else {
          urlInput.value = statelessUrl;
          urlInput.placeholder = "";
          copyBtn.textContent = "Copy link";
        }
      }
      useRevToggle.addEventListener("change", refreshButton);

      async function copyToClipboard(url) {
        try {
          await navigator.clipboard.writeText(url);
          const old = copyBtn.textContent;
          copyBtn.textContent = "Copied ✓";
          setTimeout(() => (copyBtn.textContent = old), 1200);
        } catch {
          urlInput.select();
        }
      }

      copyBtn.addEventListener("click", async () => {
        if (!useRevToggle.checked) {
          await copyToClipboard(urlInput.value);
          return;
        }
        copyBtn.disabled = true;
        copyBtn.textContent = "Generating…";
        try {
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
          urlInput.value = url;
          await copyToClipboard(url);
        } catch (e) {
          alert(`Could not create link: ${e.message}`);
          copyBtn.textContent = "Generate link";
        } finally {
          copyBtn.disabled = false;
        }
      });

      modal.hidden = false;
    }

    // ---- Bootstrap ----
    async function bootstrap() {
      try {
        let initialFilters;
        if (shareId) {
          // /s/{id}: resolve the share, replaceState into the canonical event
          // URL with the saved filters, then hand off to the normal flow.
          const shareRes = await api(`/api/store/share/${encodeURIComponent(shareId)}`);
          resolvedShare = shareRes.share || null;
          eventId = shareRes.event?.id;
          initialFilters = (resolvedShare && resolvedShare.filters) || {};
          // Normalize the filters object so subsequent UI operations treat it cleanly.
          initialFilters = {
            zones: initialFilters.zones || [],
            section: initialFilters.section || [],
            min_price: initialFilters.min_price ?? null,
            max_price: initialFilters.max_price ?? null,
            min_qty: initialFilters.min_qty ?? null,
          };
          history.replaceState({}, "", `/store/event/${eventId}${buildQueryString(initialFilters)}`);

          const zonesRes = await api(`/api/store/events/${eventId}/zones`).catch(() => ({ zones: [] }));
          zonesAvailable = zonesRes.zones || [];
          paintInputsFromFilters(initialFilters);
          applyEventResponse(shareRes, resolvedShare);
          renderZoneChips(initialFilters.zones);
        } else {
          initialFilters = parseUrlFilters();
          paintInputsFromFilters(initialFilters);
          const [evRes, zonesRes] = await Promise.all([
            api(`/api/store/events/${eventId}${buildQueryString(initialFilters)}`),
            api(`/api/store/events/${eventId}/zones`).catch(() => ({ zones: [] })),
          ]);
          zonesAvailable = zonesRes.zones || [];
          applyEventResponse(evRes, null);
          renderZoneChips(initialFilters.zones);
        }
      } catch (err) {
        if (err.message && err.message.includes("410")) {
          status.textContent = "This share link is no longer active.";
        } else {
          status.textContent = `Couldn't load event: ${err.message}`;
        }
        status.style.color = "var(--bad)";
      }
    }

    bootstrap();
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
