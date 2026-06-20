/* VibePass storefront — MVP, browse only.
 * Talks to /api/store/* exclusively. No real purchases — Reserve is a
 * validation-only endpoint that returns a mock receipt. */
(function () {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  // ---- Modal focus trap (a11y: WCAG 2.4.3 + dialog pattern) ----
  // The shared #modal (reserve + share) re-renders #modalBody on each open,
  // so focusables are queried live. trapModalFocus() records the opener,
  // moves focus into the dialog, and cycles Tab / Shift+Tab within it;
  // releaseModalFocus() restores focus to the opener on close.
  let _modalReturnFocus = null;
  function _modalFocusables() {
    const modal = document.getElementById("modal");
    if (!modal) return [];
    return $$(
      'a[href], button:not([disabled]), input:not([disabled]),' +
      ' select:not([disabled]), textarea:not([disabled]),' +
      ' [tabindex]:not([tabindex="-1"])',
      modal,
    ).filter((el) => el.offsetParent !== null);  // visible only
  }
  function _onModalKeydown(e) {
    if (e.key !== "Tab") return;
    const modal = document.getElementById("modal");
    if (!modal || modal.hidden) return;
    const f = _modalFocusables();
    if (!f.length) return;
    const first = f[0];
    const last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
  function trapModalFocus() {
    const modal = document.getElementById("modal");
    if (!modal) return;
    _modalReturnFocus = document.activeElement;
    document.addEventListener("keydown", _onModalKeydown, true);
    const closeBtn = $("#closeModal", modal);
    const f = _modalFocusables();
    (closeBtn || f[0] || modal).focus();
  }
  function releaseModalFocus() {
    document.removeEventListener("keydown", _onModalKeydown, true);
    if (_modalReturnFocus && typeof _modalReturnFocus.focus === "function") {
      try { _modalReturnFocus.focus(); } catch (_e) { /* opener gone */ }
    }
    _modalReturnFocus = null;
  }

  // Section sort key — mirrors the server's _section_sort_key. Letter-prefixed
  // sections (Floor, Courtside, GA) come before numeric (100, 101). Numeric
  // sections sort naturally (1, 2, 10, 100 — not lex 1, 10, 100, 2).
  function sectionSortCmp(a, b) {
    const aAlpha = /^[A-Za-z]/.test(a);
    const bAlpha = /^[A-Za-z]/.test(b);
    if (aAlpha && !bAlpha) return -1;
    if (!aAlpha && bAlpha) return 1;
    return a.localeCompare(b, undefined, { numeric: true });
  }

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
    // 20s default timeout via AbortController. Was unbounded — when the
    // backend or network stalled (Render free-tier cold-start dragging
    // past 30s, supabase latency spike, transient connection hang), the
    // promise never resolved and the UI sat on "Loading…" indefinitely.
    // loadCatalog's PR #141 loadComplete gate compounds the symptom: the
    // spinner stays until either then() or catch() fires. With the
    // timeout, a stall surfaces an AbortError through the existing catch
    // path → user sees the Retry button instead of an infinite spinner.
    // Per-call override: pass `init.timeout` in ms.
    const userInit = init || {};
    const timeoutMs = Number.isFinite(userInit.timeout) ? userInit.timeout : 20000;
    const controller = new AbortController();
    const fetchInit = { ...userInit, signal: userInit.signal || controller.signal };
    delete fetchInit.timeout;
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let r;
    try {
      r = await fetch(path, fetchInit);
    } catch (e) {
      clearTimeout(timer);
      if (e && (e.name === "AbortError" || e.code === 20)) {
        const tag = String(path).split("?")[0].replace(/^\/api\/store\//, "");
        throw new Error(`timeout ${tag}: server didn't respond within ${Math.round(timeoutMs / 1000)}s`);
      }
      throw e;
    }
    clearTimeout(timer);
    if (!r.ok) {
      const body = await r.text();
      let msg = body;
      try { msg = JSON.parse(body).detail || JSON.parse(body).error || body; } catch {}
      // Strip HTML tags + collapse whitespace + clip to 80 chars before
      // throwing — some servers (Render cold-start 503, FastAPI default 5xx
      // HTML pages, raw nginx 404) return full HTML bodies and the raw
      // markup shouldn't splatter into the status pill downstream. Mirrors
      // D0's app.js fix from PR #113 commit 34232a1.
      msg = String(msg).replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
      // Tag the error with the failing endpoint so the downstream catch
      // (status pill / alert) tells you *which* call died. Strips the
      // /api/store/ prefix to keep the message tight — full path stays
      // available on the network tab when debugging.
      const tag = String(path).split("?")[0].replace(/^\/api\/store\//, "");
      throw new Error(`${r.status} ${tag}: ${msg}`);
    }
    return r.json();
  }

  // Short date range like "Aug 26 – Aug 28" (or "Aug 26 – Sep 2" when the
  // span crosses a month). Used by the MLB-series + tournament context
  // badges where a wall-clock weekday/time would be noise.
  //
  // Parses just the YYYY-MM-DD prefix as a LOCAL date so a tournament
  // recorded as "2026-05-22T00:00:00+00:00" doesn't render as May 21 in
  // the US east coast (UTC midnight = previous day local). The audit
  // lane writes these dates as wall-clock dates, not instant timestamps.
  function fmtDateRange(startIso, endIso) {
    if (!startIso) return "";
    const opts = { month: "short", day: "numeric" };
    const parseLocal = (s) => {
      if (!s) return null;
      const m = String(s).match(/^(\d{4})-(\d{2})-(\d{2})/);
      if (!m) return null;
      return new Date(+m[1], +m[2] - 1, +m[3]);
    };
    const start = parseLocal(startIso);
    if (!start) return "";
    const startStr = start.toLocaleDateString(undefined, opts);
    const end = parseLocal(endIso);
    if (!end || +end === +start) return startStr;
    return `${startStr} – ${end.toLocaleDateString(undefined, opts)}`;
  }

  // Build badge nodes for the optional context dimensions a row can carry:
  // rivalry, MLB series, tournament. Returns an array (possibly empty); the
  // caller decides where to append it. Each badge is a small chip; on cards
  // we render a compact "lite" variant.
  //
  // ctx shape: { rivalry: {...}|null, mlb_series: {...}|null, tournament: {...}|null }
  function buildContextBadges(ctx, opts) {
    if (!ctx) return [];
    const compact = !!(opts && opts.compact);
    const out = [];

    if (ctx.rivalry && ctx.rivalry.name) {
      const r = ctx.rivalry;
      // Branded rivalries get the rivalry name verbatim ("Subway Series").
      // Generic rivalries get "Rivalry game · intensity" so the user knows
      // what they're looking at without a Wikipedia trip.
      const span = document.createElement("span");
      span.className = `ctx-badge rivalry intensity-${r.intensity || "high"}`;
      const label = r.is_branded
        ? r.name
        : (compact
            ? (r.intensity === "historic" ? "Historic rivalry" : "Rivalry game")
            : `${r.name} · ${r.intensity || "rivalry"}`);
      span.textContent = label;
      // Wikipedia link only on the full (non-compact) variant; cards stay
      // click-through to the event detail without a competing link.
      if (!compact && r.wikipedia_url) {
        const a = document.createElement("a");
        a.href = r.wikipedia_url;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.className = "ctx-badge-link";
        a.textContent = "ⓘ";
        span.appendChild(document.createTextNode(" "));
        span.appendChild(a);
      }
      out.push(span);
    }

    if (ctx.mlb_series && ctx.mlb_series.game_count) {
      const s = ctx.mlb_series;
      const span = document.createElement("span");
      span.className = "ctx-badge series";
      const pos = s.game_number ? `Game ${s.game_number} of ${s.game_count}` : `${s.game_count}-game series`;
      const range = fmtDateRange(s.series_start, s.series_end);
      // Branded series name surfaces when set; falls back to the generic
      // "Part of N-game series" tag the user asked for.
      const lead = s.branded_name
        ? s.branded_name
        : (compact ? `${s.game_count}-game series` : `Part of a ${s.game_count}-game series`);
      span.textContent = compact ? `${lead} · ${pos}` : `${lead} · ${pos} · ${range}`;
      out.push(span);
    }

    if (ctx.tournament && (ctx.tournament.name || ctx.tournament.short_name)) {
      const t = ctx.tournament;
      const span = document.createElement("span");
      span.className = "ctx-badge tournament";
      const name = t.short_name || t.name;
      const range = fmtDateRange(t.start_date, t.end_date);
      span.textContent = range ? `${name} · ${range}` : name;
      out.push(span);
    }

    // Playoff badge — distinct purple palette. Server returns the most
    // specific label available ("NBA Finals", "NBA Eastern Conference
    // Semifinals", "World Series"); falls back to generic "Playoffs"
    // when only a Round-N / Game-N hint is detectable.
    if (ctx.playoff && ctx.playoff.label) {
      const p = ctx.playoff;
      const span = document.createElement("span");
      span.className = `ctx-badge playoff kind-${p.kind || "generic"}`;
      if (compact && p.label.length > 22) {
        // Long names like "NBA Eastern Conference Semifinals" eat real
        // estate on a card. Compact shortens to "Playoffs" so the layout
        // stays scannable; full label keeps showing on event detail.
        span.textContent = "🏆 Playoffs";
      } else {
        span.textContent = `🏆 ${p.label}`;
      }
      out.push(span);
    }

    return out;
  }

  // Format a single holiday/calendar hit as a small chip. Returns a span
  // element or null when nothing meaningful is set. Three kinds:
  //   day_of       → "Memorial Day"
  //   nearby       → "Memorial Day weekend (Mon May 25)"
  //   school_break → "Summer Break"
  function buildHolidayBadge(holiday, opts) {
    if (!holiday || !holiday.label) return null;
    const compact = !!(opts && opts.compact);
    const span = document.createElement("span");
    const impact = holiday.impact === "boost" ? "boost" : "neutral";
    span.className = `holiday-pill kind-${holiday.kind || "day_of"} impact-${impact}`;
    let label = holiday.label;
    // Nearby gets a short date suffix when not compact ("(Mon May 25)").
    if (holiday.kind === "nearby" && !compact && holiday.date) {
      const m = String(holiday.date).match(/^(\d{4})-(\d{2})-(\d{2})/);
      if (m) {
        const d = new Date(+m[1], +m[2] - 1, +m[3]);
        const day = d.toLocaleDateString(undefined, {
          weekday: "short", month: "short", day: "numeric",
        });
        label += ` (${day})`;
      }
    }
    span.textContent = label;
    return span;
  }

  // Render the weather row for an event detail page. Two layouts:
  //   - With alerts: red severity-aware banner first, then forecast line
  //     (when present)
  //   - No alerts, forecast only: a single neutral pill
  // Returns a DocumentFragment ready to append; empty when nothing to show.
  function buildWeatherRow(weather) {
    const frag = document.createDocumentFragment();
    if (!weather) return frag;

    // Alerts: render each as a top-line warning. Severity-aware coloring.
    const alerts = Array.isArray(weather.alerts) ? weather.alerts : [];
    alerts.forEach((a) => {
      const div = document.createElement("div");
      const sev = (a.severity || "").toLowerCase();
      div.className = `weather-alert severity-${sev || "minor"}`;
      const icon = document.createElement("span");
      icon.className = "weather-alert-icon";
      icon.textContent = "⚠";
      const txt = document.createElement("span");
      txt.className = "weather-alert-text";
      // Prefer the short event ("Severe Thunderstorm Warning") + headline if
      // short enough; otherwise just the event name.
      const headline = a.headline || "";
      const evtName = a.event || "Weather alert";
      txt.textContent = headline && headline.length < 90
        ? `${evtName} — ${headline}`
        : evtName;
      div.append(icon, txt);
      frag.append(div);
    });

    // Forecast line — only when set (outdoor + ≤7d per server rules).
    if (weather.forecast) {
      const f = weather.forecast;
      const div = document.createElement("div");
      div.className = "weather-row";
      const parts = [];
      if (f.temp_f != null) {
        parts.push(`${Math.round(Number(f.temp_f))}°F`);
      }
      if (f.summary) parts.push(String(f.summary));
      if (f.precip_pct != null) {
        parts.push(`${Number(f.precip_pct)}% rain`);
      }
      if (f.wind_mph != null && Number(f.wind_mph) >= 1) {
        parts.push(`${Math.round(Number(f.wind_mph))}mph wind`);
      }
      const icon = document.createElement("span");
      icon.className = "weather-icon";
      // Pick an icon by summary keyword — cheap heuristic, no emoji library.
      const summary = String(f.summary || "").toLowerCase();
      let glyph = "🌤";
      if (summary.includes("thunder")) glyph = "⛈";
      else if (summary.includes("snow")) glyph = "❄";
      else if (summary.includes("rain") || summary.includes("drizzle") || summary.includes("shower")) glyph = "🌧";
      else if (summary.includes("fog")) glyph = "🌫";
      else if (summary.includes("overcast")) glyph = "☁";
      else if (summary.includes("clear")) glyph = "☀";
      icon.textContent = glyph;
      const txt = document.createElement("span");
      txt.textContent = parts.join(" · ");
      div.append(icon, txt);
      frag.append(div);
    }

    return frag;
  }

  // ---------- Catalog page ----------
  function mountCatalog() {
    const form = $("#searchForm");
    const input = $("#q");
    const status = $("#status");
    const grid = $("#grid");
    const gridHeading = $("#gridHeading");
    const empty = $("#empty");
    // Suggest dropdown DOM + state — declared early so functions that
    // reference them (hideSuggest/wireSuggestDropdown/scheduleSuggest)
    // don't hit TDZ when called before the previous declaration location
    // ~line 639. Operator report 2026-05-18: typing + Submit threw
    // "Cannot access 'suggestEl' before initialization" because
    // wireSuggestDropdown() is called at line 524 (was), which referenced
    // suggestEl before its declaration ran. mountCatalog halted mid-flight
    // there → const suggestEl line never executed → submit handler (already
    // registered) fires later and re-hits TDZ on hideSuggest.
    const suggestEl = $("#searchSuggest");
    let suggestTimer = null;
    let suggestSeq = 0;

    let allEvents = [];
    // loadComplete gates filter() so the user can't trigger a misleading
    // "No events match" empty state by typing in the search box while the
    // initial /api/store/home call is still in flight (common on free-tier
    // cold-start where the round-trip is ~12s). When load resolves below,
    // any pending user query is re-applied at that point.
    let loadComplete = false;
    // True once the user has submitted a backend search via /api/store/
    // search. Prevents loadCatalog's late .then() from clobbering search
    // results with the unfiltered home grid when home was still pending
    // at submit time (operator report 2026-05-18 — "yankees" + Search
    // produced silent no-op because the gate at searchAndRender bailed).
    let userHasSearched = false;

    // Shimmer placeholder cards shown while the catalog loads. Static
    // markup (no user data); aria-hidden so screen readers ignore them —
    // the grid's aria-busy attr carries the loading semantics.
    function renderSkeleton(n) {
      grid.replaceChildren();
      if (gridHeading) gridHeading.hidden = true;
      empty.hidden = true;
      for (let i = 0; i < n; i++) {
        const sk = document.createElement("div");
        sk.className = "card skeleton-card";
        sk.setAttribute("aria-hidden", "true");
        for (const c of ["sk-logo", "sk-when", "sk-name", "sk-where", "sk-meta"]) {
          const bar = document.createElement("div");
          bar.className = `sk-bar ${c}`;
          sk.append(bar);
        }
        grid.append(sk);
      }
      grid.hidden = false;
    }

    // Stable partition that floats NYC-area events to the front while
    // preserving the server's within-group order. Keeps the home grid
    // coherent with the "…in NYC" rails without dropping national
    // inventory (non-NYC events still follow). Word-boundary \bny\b also
    // catches "…, NY"; "new york"/borough names cover the rest.
    function nycFirst(events) {
      const isNyc = (e) => {
        const loc = String(e.venue_location || "").toLowerCase();
        return /\bny\b|new york|bronx|brooklyn|flushing|queens|manhattan|staten island/.test(loc);
      };
      const nyc = [], rest = [];
      for (const e of events) (isNyc(e) ? nyc : rest).push(e);
      return nyc.concat(rest);
    }

    function render(events, mode) {
      // mode: "all" (initial load) or "search" (after a query)
      grid.innerHTML = "";
      status.hidden = true;
      if (!events.length) {
        grid.hidden = true;
        if (gridHeading) gridHeading.hidden = true;
        empty.hidden = false;
        empty.textContent = mode === "search"
          ? "No events match. Try a broader search, or clear the box to see all."
          : "No events available right now. Check back soon — we add inventory daily.";
        return;
      }
      empty.hidden = true;
      grid.hidden = false;
      // Section header so the grid reads as distinct from the themed NYC
      // rails above it (which carry their own titles). "Search results"
      // when the grid is showing a query's matches, "All events" otherwise.
      if (gridHeading) {
        gridHeading.textContent = mode === "search" ? "Search results" : "All events";
        gridHeading.hidden = false;
      }

      for (const ev of events) {
        const a = document.createElement("a");
        a.className = "card";
        a.href = `/store/event/${ev.id}`;
        if (ev.primary_performer_color) {
          a.style.setProperty("--card-accent", ev.primary_performer_color);
        }

        // Header row: logo(s) + meta lines.
        // 2026-05-19: Sports matchups render BOTH team logos when away is
        // populated (e.g. "Cavs @ Knicks" → away logo + home logo). Falls
        // back to home-only when away is null (concerts, theater, playoff
        // placeholders without secondary performer).
        const head = document.createElement("div");
        head.className = "card-head";
        if (ev.away_performer_logo || ev.primary_performer_logo) {
          const logos = document.createElement("div");
          logos.className = "card-logos";
          if (ev.away_performer_logo) {
            const awayImg = document.createElement("img");
            awayImg.className = "card-logo card-logo-away";
            awayImg.src = ev.away_performer_logo;
            awayImg.alt = ev.away_performer_name || "";
            awayImg.loading = "lazy";
            logos.append(awayImg);
          }
          if (ev.primary_performer_logo) {
            const homeImg = document.createElement("img");
            homeImg.className = "card-logo card-logo-home";
            homeImg.src = ev.primary_performer_logo;
            homeImg.alt = ev.primary_performer_name || "";
            homeImg.loading = "lazy";
            logos.append(homeImg);
          }
          head.append(logos);
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

        // Context strip (rivalry / series / tournament / holiday) — compact
        // variant for catalog cards. Skipped silently when none apply.
        // Compact mode drops date ranges and the Wikipedia link so the card
        // stays scannable. Holiday gets its own pill kind (warm yellow).
        const ctxRow = document.createElement("div");
        ctxRow.className = "card-context";
        const badges = buildContextBadges(
          { rivalry: ev.rivalry, mlb_series: ev.mlb_series, tournament: ev.tournament },
          { compact: true },
        );
        badges.forEach((b) => ctxRow.append(b));
        const holidayBadge = buildHolidayBadge(ev.holiday, { compact: true });
        if (holidayBadge) ctxRow.append(holidayBadge);

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

        a.append(head, where);
        if (badges.length || holidayBadge) a.append(ctxRow);
        a.append(meta);
        grid.append(a);
      }
    }

    function filter(query) {
      // Guard against the cold-start race: user typed in the search box
      // before loadCatalog's /api/store/home round-trip completed. Bailing
      // out here keeps the "Loading available events…" status pill visible
      // instead of showing a misleading "No events match" empty state.
      // The pending query (input.value) is re-applied by loadCatalog when
      // it resolves — see the .then() handler below.
      if (!loadComplete) return;
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
      const q = (input.value || "").trim();
      hideSuggest();
      // Empty submit → revert to the home view (full catalog).
      if (!q) {
        userHasSearched = false;
        render(allEvents, "all");
        return;
      }
      // Backend search — hits /api/store/search for the FULL result set,
      // not just the in-memory home payload. Click-Search previously called
      // filter(q) which ran an in-memory scan over the 60 events that
      // /api/store/home returned, so any query that didn't match one of
      // those (e.g. "knicks" when we don't have Knicks owned-inventory on
      // home) rendered "No events match" — even though /api/store/search
      // would have returned playoff games we hold. searchAndRender() fixes
      // this by going to the backend on every Submit click. Live as-you-type
      // still hits the in-memory filter (instant) + the suggest dropdown
      // (debounced); only the explicit Submit promotes to backend.
      searchAndRender(q);
    });
    // Local in-memory filter on the already-loaded catalog AND a debounced
    // call to /api/store/search for live suggestions (TEvo + our SQL).
    input.addEventListener("input", () => {
      filter(input.value);
      scheduleSuggest(input.value);
    });

    // ------------------------------------------------------------------
    // searchAndRender: backend-search promote (Submit click handler target)
    // ------------------------------------------------------------------
    // Fetches /api/store/search?q=...&limit=60, normalizes the search-
    // response shape (which differs slightly from /api/store/home — see
    // app.py:_search_live + _search_sql_only) to what render() expects,
    // then re-renders the main grid. Defensively filters cancelled +
    // (If Necessary) speculative names client-side until PR #175 lands
    // the server-side filter.
    function searchAndRender(q) {
      // No loadComplete gate here — Submit is an explicit user action and
      // /api/store/search is independent of /api/store/home (different
      // endpoint, different code path). If the home catalog is still
      // pending or stalled, the user can still recover by submitting a
      // search. The original gate (PR #141) was added to prevent the
      // in-memory filter() from racing with the home fetch; that race
      // never applied to backend-search Submit because Submit doesn't
      // touch the in-memory allEvents array. Removed 2026-05-18 after
      // operator report: typing "yankees" + clicking Search produced
      // silent no-op when home was hanging.
      status.hidden = false;
      status.textContent = `Searching for "${q}"…`;
      grid.hidden = true;
      empty.hidden = true;
      api(`/api/store/search?q=${encodeURIComponent(q)}&limit=60`)
        .then((data) => {
          const raw = Array.isArray(data && data.events) ? data.events : [];
          // Shape adapter: /search returns {location, occurs_at, owned_tix}
          // while render() expects {venue_location, occurs_at_local,
          // owned_tickets_count}. Map the keys without losing data.
          const normalized = raw.map((e) => ({
            id: e.id,
            name: e.name,
            venue_name: e.venue_name || null,
            venue_location: e.venue_location || e.location || null,
            occurs_at_local: e.occurs_at_local || e.occurs_at || null,
            primary_performer_name: e.primary_performer_name || null,
            primary_performer_logo: e.primary_performer_logo || null,
            primary_performer_color: e.primary_performer_color || null,
            // Away-team assets (2026-05-19) — pass through when /search
            // payload carries them; otherwise null and card falls back to
            // home-only render.
            away_performer_name: e.away_performer_name || null,
            away_performer_logo: e.away_performer_logo || null,
            away_performer_color: e.away_performer_color || null,
            from_price: e.from_price != null ? Number(e.from_price) : null,
            owned_tickets_count: e.owned_tix != null ? Number(e.owned_tix) :
                                 (e.owned_tickets_count != null ? Number(e.owned_tickets_count) : null),
            owned_groups_count: e.owned_groups_count != null ? Number(e.owned_groups_count) : null,
            rivalry: e.rivalry || null,
            mlb_series: e.mlb_series || null,
            tournament: e.tournament || null,
            holiday: e.holiday || null,
          }));
          // Client-side filter — two gates:
          // 1. Speculative-name guard (mirrors PR #175 server-side logic).
          //    Drops CANCELLED + (If Necessary).
          // 2. Owned-inventory only (operator 2026-05-18). Storefront pitches
          //    "Direct inventory, transparent pricing" — Submit-driven grid
          //    must not surface events we can't sell. _search_sql_only +
          //    _search_live return `we_own:false` events for the as-you-type
          //    suggest dropdown's "browse" section, but the main grid only
          //    shows what's bookable.
          const cleaned = normalized.filter((e) => {
            const up = (e.name || "").toUpperCase();
            if (up.includes("CANCELLED") || up.includes("(IF NECESSARY)")) return false;
            return (Number(e.owned_tickets_count) || 0) > 0;
          });
          render(cleaned, "search");
          userHasSearched = true;
        })
        .catch((err) => {
          console.error("searchAndRender failed:", err);
          // Fall back to the in-memory local filter so the user still gets
          // SOMETHING relevant rather than a blank page. Original behavior.
          status.hidden = true;
          filter(q);
        });
    }

    wireSuggestDropdown();

    // URL params let event-detail links into the catalog filter to a single
    // performer or venue. Server-side filter, not just client-side, so the
    // result is bounded even when a performer has hundreds of events.
    const urlParams = new URLSearchParams(location.search);
    const performerId = urlParams.get("performer_id");
    const venueId = urlParams.get("venue_id");
    const qs = new URLSearchParams({ limit: "500" });
    if (performerId) qs.set("performer_id", performerId);
    if (venueId) qs.set("venue_id", venueId);

    // Catalog fetch with retryable error UI. On failure the user sees the
    // error + an inline Retry button instead of stuck red text. Per D1 UX
    // audit 2026-05-12 fix #1.
    //
    // Endpoint switch by view:
    //   Home view (unfiltered) → /api/store/home — SQL-only, ~50ms, returns
    //     owned events with from_price + owned_tickets_count populated.
    //   Filtered view (?performer_id= or ?venue_id=) → /api/store/events —
    //     TEvo-direct so the catalog reflects fresh inventory for that
    //     filter. /api/store/home doesn't accept those filters today; a
    //     future PR adds a SQL-only filtered variant (see D1-NEXT in
    //     docs/d1_retail_finish_punchlist.md §G — "store_home filter
    //     variants" — closes the last TEvo dependency on the storefront).
    //
    // PR #111 originally chained both calls (home first, then events as a
    // "freshness" refresh). That overwrote the populated home grid with
    // /api/store/events's null-from_price response ~1.5s later, producing
    // a "prices flash then disappear" UX bug. Single-endpoint switch
    // resolves that: home view keeps its prices forever (until next
    // page-load refresh).
    //
    // TRADEOFF: dropping the lazy /events refresh makes latest_event_metrics
    // (the SQL matview behind /api/store/home) the SINGLE SOURCE OF TRUTH
    // for what appears on the home grid. TEvo-only events that haven't
    // been ingested into the matview yet won't show up here — that's
    // intentional per the owned-only homepage strategy
    // (docs/d1-bot-continues-here-rustling-sunrise.md §7d). If a future
    // contributor sees the home grid stale and is tempted to "fix" it by
    // adding /events back, please instead investigate the LEM refresh
    // cron upstream (bot_chat 130 class — listings_snapshots silent-
    // success → no LEM rows ingested → home grid goes stale).
    const isHomeView = !performerId && !venueId;
    const catalogEndpoint = isHomeView
      ? "/api/store/home?limit=60"
      : `/api/store/events?${qs.toString()}`;

    function loadCatalog() {
      // Skeleton cards ARE the loading affordance now (replaces the plain
      // "Loading…" text pill). On a cold Render dyno first paint can take
      // ~12s; shimmer placeholders make that wait feel responsive instead
      // of blank. aria-busy on the grid announces the load to screen
      // readers; the skeleton cards themselves are aria-hidden.
      status.hidden = true;
      grid.setAttribute("aria-busy", "true");
      renderSkeleton(8);
      // Reset gate — Retry re-fires this and we want the same race
      // protection on the second attempt.
      loadComplete = false;
      api(catalogEndpoint)
        .then((res) => {
          grid.removeAttribute("aria-busy");
          allEvents = res.events || [];
          // NYC-first ordering on the home view so the grid coheres with the
          // "…in NYC" rails above it (the home endpoint returns owned events
          // nationwide; without this the grid leads with Baltimore/Toronto/
          // KC games while the rails say NYC). Stable partition — preserves
          // the endpoint's within-group order. Filtered views keep server
          // order. H2, 2026-05-25 UX audit.
          if (isHomeView) allEvents = nycFirst(allEvents);
          loadComplete = true;
          renderCatalogFilterBanner(performerId, venueId, allEvents);
          // Don't clobber a backend search the user submitted while home
          // was still pending. The Submit-gate removal (2026-05-18) lets
          // a user search even before home resolves; if they did, leave
          // their results in place.
          if (userHasSearched) {
            status.hidden = true;
            return;
          }
          // If user typed during the load window, honor that query now.
          // Otherwise render the full grid as before.
          const pendingQuery = (input.value || "").trim();
          if (pendingQuery) {
            filter(input.value);
          } else {
            render(allEvents, "all");
          }
          status.hidden = true;
        })
        .catch((err) => {
          // loadComplete stays false — filter() correctly bails out so a
          // user typing during error state doesn't see "No events match"
          // on top of the Retry-button error UI.
          grid.removeAttribute("aria-busy");
          grid.replaceChildren();   // clear skeleton cards
          grid.hidden = true;
          if (gridHeading) gridHeading.hidden = true;
          status.replaceChildren();
          status.style.color = "var(--bad)";
          status.hidden = false;
          const spec = describeFetchError(err);
          const msg = document.createElement("div");
          // Same normalized voice as the event-detail screen. Catalog load
          // never hits a true 404 (the home/events endpoints always answer),
          // so this is almost always the retryable "temporarily unavailable"
          // copy — but routing through describeFetchError keeps the wording
          // consistent if that ever changes.
          msg.textContent = `${spec.title}. ${spec.message}`;
          const retry = document.createElement("button");
          retry.type = "button";
          retry.className = "btn ghost";
          retry.style.marginTop = "12px";
          retry.textContent = "Retry";
          retry.addEventListener("click", loadCatalog);
          status.append(msg, retry);
        });
    }
    loadCatalog();

    // NYC themed sliders — only shown on the bare /store view (no performer
    // or venue filter). Server returns 4 keyed arrays (moving_fast,
    // price_drops, climbing, specials) and each becomes its own horizontal
    // slider. Empty sections are hidden. days=90 to give the 3mo horizon
    // enough pool depth for each section's filter.
    if (!performerId && !venueId) {
      // Concierge rail — premium top-band EVO seats (leads the curated rails).
      const cHost = $("#conciergeRail");
      if (cHost) {
        api("/api/store/concierge?days=60&limit=18")
          .then((res) => renderConcierge(cHost, res))
          .catch(() => { cHost.hidden = true; });
      }
      const host = $("#moversSections");
      if (host) {
        api("/api/store/movers?city=NYC&days=90")
          .then((res) => renderMoversSections(host, res))
          .catch(() => { host.hidden = true; });
      }
    }

    // ----- Live search suggestions dropdown -----
    // Debounced /api/store/search call as the user types. 300ms debounce
    // + 2-char minimum keeps upstream load reasonable (TEvo doesn't cache
    // suggestions — see notes in evo_client.search_suggestions). Server
    // also caches per-q for 60s.
    // (suggestEl / suggestTimer / suggestSeq moved to top of mountCatalog
    //  to fix TDZ — see comment block there.)

    function scheduleSuggest(qRaw) {
      const q = (qRaw || "").trim();
      if (suggestTimer) {
        clearTimeout(suggestTimer);
        suggestTimer = null;
      }
      if (q.length < 2) {
        hideSuggest();
        return;
      }
      const mySeq = ++suggestSeq;
      // Render a loading state immediately on debounce arm so the user sees
      // SOMETHING during cold-start latency (live TEvo can take 10-30s on
      // free-tier Render). Without this, an empty dropdown reads as "broken."
      showSuggestStatus("Searching…");
      suggestTimer = setTimeout(() => {
        api(`/api/store/search?q=${encodeURIComponent(q)}&limit=8`)
          .then((res) => {
            if (mySeq !== suggestSeq) return;  // stale; user typed more
            renderSuggest(suggestEl, res);
          })
          .catch((err) => {
            if (mySeq !== suggestSeq) return;
            // Show the error inline rather than silently hiding. Users
            // need feedback when network/server hiccups happen — the most
            // common failure modes on this deploy are 502 (sleeping
            // dyno) and 5xx during cold starts.
            const msg = err && err.message ? String(err.message) : "Search unavailable";
            // isError=true → renders with .suggest-status.error styling
            // (bad-tone color + ⚠ glyph), distinct from "Searching…".
            showSuggestStatus(`${msg.slice(0, 80)} · try again`, true);
          });
      }, 300);
    }

    function showSuggestStatus(text, isError) {
      if (!suggestEl) return;
      suggestEl.replaceChildren();
      const div = document.createElement("div");
      div.className = "suggest-status" + (isError ? " error" : "");
      div.textContent = text;
      suggestEl.append(div);
      suggestEl.hidden = false;
    }

    function hideSuggest() {
      if (!suggestEl) return;
      suggestEl.hidden = true;
      suggestEl.replaceChildren();
    }

    function wireSuggestDropdown() {
      if (!suggestEl) return;
      // Click outside → close. Use mousedown so the suggestion's own
      // click handler fires first if the user clicked a row.
      document.addEventListener("mousedown", (e) => {
        if (!form.contains(e.target)) hideSuggest();
      });
      // Escape → close + return focus to the input.
      input.addEventListener("keydown", (e) => {
        if (e.key === "Escape") { hideSuggest(); input.focus(); }
      });
    }
  }

  // Render suggestion dropdown body. Sections, in priority order:
  //   Players — sports search: a matched athlete + their team's upcoming
  //     events (e.g. "messi" → Inter Miami CF games). Shown first.
  //   Events you can buy now (we_own=true) — top priority among plain events
  //   Other events (we_own=false) — surfaced but flagged as "browse"
  //   Performers + venues — bottom, clickable filter pivots
  function renderSuggest(host, payload) {
    if (!host) return;
    host.replaceChildren();
    const players = (payload && payload.players) || [];
    const events = (payload && payload.events) || [];
    const performers = (payload && payload.performers) || [];
    const venues = (payload && payload.venues) || [];

    if (!players.length && !events.length && !performers.length && !venues.length) {
      host.hidden = true;
      return;
    }

    if (players.length) {
      host.append(suggestHeader("Players"));
      players.forEach((pl) => {
        host.append(suggestPlayerRow(pl));
        (pl.events || []).forEach((e) => {
          const row = suggestEventRow(e, !!e.we_own);
          row.classList.add("under-player");
          host.append(row);
        });
      });
    }

    const buyable = events.filter((e) => e.we_own);
    const browseOnly = events.filter((e) => !e.we_own);

    if (buyable.length) {
      host.append(suggestHeader("Tickets you can buy"));
      buyable.forEach((e) => host.append(suggestEventRow(e, true)));
    }
    if (browseOnly.length) {
      host.append(suggestHeader("More events"));
      browseOnly.forEach((e) => host.append(suggestEventRow(e, false)));
    }
    if (performers.length) {
      host.append(suggestHeader("Performers"));
      performers.forEach((p) => host.append(suggestPerformerRow(p)));
    }
    if (venues.length) {
      host.append(suggestHeader("Venues"));
      venues.forEach((v) => host.append(suggestVenueRow(v)));
    }
    host.hidden = false;
  }

  function suggestHeader(text) {
    const h = document.createElement("div");
    h.className = "suggest-header";
    h.textContent = text;
    return h;
  }

  function suggestEventRow(ev, weOwn) {
    const a = document.createElement("a");
    a.className = "suggest-row event" + (weOwn ? " we-own" : "");
    a.href = `/store/event/${Number(ev.id) || 0}`;
    a.setAttribute("role", "option");
    const name = document.createElement("div");
    name.className = "suggest-row-name";
    name.textContent = ev.name || "Untitled event";
    a.append(name);
    const meta = document.createElement("div");
    meta.className = "suggest-row-meta";
    const parts = [];
    if (ev.venue_name) parts.push(ev.venue_name);
    if (ev.occurs_at) parts.push(fmtWhen(ev.occurs_at));
    meta.textContent = parts.join(" · ");
    a.append(meta);
    if (weOwn && ev.from_price != null) {
      const price = document.createElement("span");
      price.className = "suggest-row-price";
      price.textContent = `from ${fmtMoney(ev.from_price)}`;
      a.append(price);
    }
    return a;
  }

  function suggestPlayerRow(pl) {
    // Player → their team's performer filter page. The team's upcoming events
    // render as nested rows beneath this one (see renderSuggest).
    const a = document.createElement("a");
    a.className = "suggest-row player";
    a.href = `/store?performer_id=${Number(pl.performer_id) || 0}`;
    a.setAttribute("role", "option");
    const name = document.createElement("div");
    name.className = "suggest-row-name";
    name.textContent = pl.name || "";
    a.append(name);
    const meta = document.createElement("div");
    meta.className = "suggest-row-meta";
    const who = [pl.jersey ? `#${pl.jersey}` : "", pl.position].filter(Boolean).join(" ");
    meta.textContent = [pl.team_name, pl.league, who].filter(Boolean).join(" · ");
    a.append(meta);
    return a;
  }

  function suggestPerformerRow(p) {
    const a = document.createElement("a");
    a.className = "suggest-row performer";
    a.href = `/store?performer_id=${Number(p.id) || 0}`;
    a.setAttribute("role", "option");
    const name = document.createElement("div");
    name.className = "suggest-row-name";
    name.textContent = p.name || "";
    a.append(name);
    if (p.location || p.venue_name || p.league) {
      const meta = document.createElement("div");
      meta.className = "suggest-row-meta";
      meta.textContent = [p.league, p.venue_name, p.location].filter(Boolean).join(" · ");
      a.append(meta);
    }
    return a;
  }

  function suggestVenueRow(v) {
    const a = document.createElement("a");
    a.className = "suggest-row venue";
    a.href = `/store?venue_id=${Number(v.id) || 0}`;
    a.setAttribute("role", "option");
    const name = document.createElement("div");
    name.className = "suggest-row-name";
    name.textContent = v.name || "";
    a.append(name);
    if (v.location) {
      const meta = document.createElement("div");
      meta.className = "suggest-row-meta";
      meta.textContent = v.location;
      a.append(meta);
    }
    return a;
  }

  // Section render config — one entry per themed slider in display order.
  // `accent` line is the per-card secondary note describing why this event
  // qualified for the section (e.g. "↓ 35% in 24h" for price_drops).
  const SECTIONS = [
    // Featured (operator directive 2026-05-19 v2): narrow criteria — only
    // playoff games + events with owned_median_retail > $50. Other signals
    // (high-owned, specials) flow to their own rails. Cross-list dedup
    // applied server-side: each event appears in AT MOST ONE rail.
    // Tag = playoff label only; premium-only events show no per-card chip
    // (internal owned counts dropped — not consumer-facing).
    { key: "featured", title: "Featured in NYC",
      accent: (ev) => ev._featured_tag || "" },
    // Moving fast — server flags via velocity signals. Per-card accents
    // dropped (those exposed internal sold-today counts); section title
    // alone communicates the framing.
    { key: "moving_fast", title: "Moving fast in NYC",
      accent: () => "" },
    { key: "price_drops", title: "Price drops in NYC",
      accent: (ev) => {
        const d = Number(ev._discount_pct);
        return Number.isFinite(d) ? `↓ ${d.toFixed(0)}% in 24h` : "";
      } },
    { key: "climbing", title: "Climbing fast in NYC",
      accent: (ev) => {
        const c = Number(ev._climb_pct);
        return Number.isFinite(c) ? `↑ ${c.toFixed(0)}% in 24h` : "";
      } },
    // Specials restored as its own rail (operator: "let the others
    // populate to other lists we have"). Holiday/rivalry events with
    // owned > 100 that don't qualify for Featured land here.
    { key: "specials", title: "Upcoming Specials in NYC",
      accent: (ev) => ev._special || "" },
  ];

  function _moverCard(ev, accent) {
    const a = document.createElement("a");
    a.className = "mover-card";
    a.href = `/store/event/${Number(ev.id) || 0}`;
    if (ev.primary_performer_color) {
      a.style.setProperty("--card-accent", ev.primary_performer_color);
    }
    if (accent) {
      const badge = document.createElement("div");
      badge.className = "mover-accent";
      badge.textContent = accent;
      a.append(badge);
    }
    const title = document.createElement("div");
    title.className = "mover-title";
    title.textContent = ev.name || "Untitled event";
    a.append(title);
    const where = document.createElement("div");
    where.className = "mover-where";
    where.textContent = [ev.venue_name, fmtWhen(ev.occurs_at_local)].filter(Boolean).join(" · ");
    a.append(where);
    const meta = document.createElement("div");
    meta.className = "mover-meta";
    if (ev.from_price != null) {
      const fp = document.createElement("span");
      fp.className = "mover-price";
      fp.textContent = `from ${fmtMoney(ev.from_price)}`;
      meta.append(fp);
    }
    a.append(meta);
    return a;
  }

  // Concierge card — an event where we hold premium top-band seats (EVO only).
  // `from_price` is the entry price into that event's premium tier (the cheapest
  // of its top-band owned seats). Bookable link into our /store/event page.
  function _conciergeCard(ev) {
    const a = document.createElement("a");
    a.className = "mover-card concierge-card";
    a.href = `/store/event/${Number(ev.id) || 0}`;
    if (ev.primary_performer_color) {
      a.style.setProperty("--card-accent", ev.primary_performer_color);
    }
    const badge = document.createElement("div");
    badge.className = "mover-accent";
    badge.textContent = "Premium seats";
    a.append(badge);
    const title = document.createElement("div");
    title.className = "mover-title";
    title.textContent = ev.name || "Untitled event";
    a.append(title);
    const where = document.createElement("div");
    where.className = "mover-where";
    where.textContent = [ev.venue_name, fmtWhen(ev.occurs_at_local)]
      .filter(Boolean).join(" · ");
    a.append(where);
    const meta = document.createElement("div");
    meta.className = "mover-meta";
    if (ev.from_price != null) {
      const fp = document.createElement("span");
      fp.className = "mover-price";
      fp.textContent = `from ${fmtMoney(ev.from_price)}`;
      meta.append(fp);
    }
    a.append(meta);
    return a;
  }

  // Render the Concierge rail as one horizontal slider. Hidden when empty.
  function renderConcierge(host, payload) {
    host.replaceChildren();
    const items = (payload && payload.events) || [];
    if (!items.length) { host.hidden = true; return; }
    const section = document.createElement("section");
    section.className = "movers-section movers-concierge";
    section.setAttribute("aria-label", "Concierge — premium seats");
    const h = document.createElement("h2");
    h.className = "movers-section-title";
    h.textContent = "Concierge · premium seats";
    section.append(h);
    const row = document.createElement("div");
    row.className = "movers-section-row";
    for (const ev of items) row.append(_conciergeCard(ev));
    section.append(row);
    host.append(section);
    host.hidden = false;
  }

  // Render the 4 themed sliders. Each one builds a labeled <section> with
  // a horizontal scrolling row of `_moverCard()`s. Empty sections are
  // skipped entirely (no header rendered); when all 4 are empty, the
  // whole container hides.
  function renderMoversSections(host, payload) {
    host.replaceChildren();
    let rendered = 0;
    for (const cfg of SECTIONS) {
      const items = (payload && payload[cfg.key]) || [];
      if (!items.length) continue;
      const section = document.createElement("section");
      section.className = `movers-section movers-${cfg.key.replace(/_/g, "-")}`;
      section.setAttribute("aria-label", cfg.title);
      const h = document.createElement("h2");
      h.className = "movers-section-title";
      h.textContent = cfg.title;
      section.append(h);
      const row = document.createElement("div");
      row.className = "movers-section-row";
      for (const ev of items) {
        row.append(_moverCard(ev, cfg.accent(ev)));
      }
      section.append(row);
      host.append(section);
      rendered += 1;
    }
    host.hidden = rendered === 0;
  }

  // Shows a "Showing events for ___" banner above the catalog when the user
  // arrived via a performer/venue link on an event page. DOM-built (no
  // innerHTML on user-controlled values).
  function renderCatalogFilterBanner(performerId, venueId, events) {
    const host = $("#catalogFilterBanner");
    if (!host) return;
    if (!performerId && !venueId) { host.hidden = true; return; }
    const first = events[0] || {};
    let label = "";
    if (performerId) {
      label = first.primary_performer_name
        || (first.venue_name && first.name)
        || `Performer #${Number(performerId) || ""}`;
    } else if (venueId) {
      label = [first.venue_name, first.venue_location].filter(Boolean).join(" · ")
        || `Venue #${Number(venueId) || ""}`;
    }
    host.replaceChildren();
    const strong = document.createElement("strong");
    strong.textContent = `Showing events for ${label}`;
    host.append(strong);
    const sep = document.createTextNode(" · ");
    host.append(sep);
    const clearA = document.createElement("a");
    clearA.href = "/store";
    clearA.textContent = "show all events";
    host.append(clearA);
    host.hidden = false;
  }

  // ---------- Honest-scarcity cues ----------
  // Real availability facts from the UNFILTERED owned set, summarized as
  // urgency only when a genuine threshold is crossed. Every value here is
  // already visible in the listings table below (sections, quantities, row
  // count) — this just surfaces it. No fabricated "N people viewing" theater,
  // and nothing wall-sensitive (it's our own retail availability, already shown).
  function renderScarcity(res) {
    const host = document.getElementById("scarcityStrip");
    if (!host) return;
    host.replaceChildren();
    const total = res.total_before_filters || res.listings_count || (res.listings || []).length || 0;
    const sections = Array.isArray(res.sections_available) ? res.sections_available.length : 0;
    const splits = Array.isArray(res.splits_available) ? res.splits_available.length : 0;

    const chips = [];
    if (sections > 0 && sections <= 3) {
      chips.push({ kind: "warn", text: `Only ${sections} section${sections === 1 ? "" : "s"} left` });
    }
    if (total > 0 && total <= 6) {
      chips.push({ kind: "warn", text: `Only ${total} listing${total === 1 ? "" : "s"} remaining` });
    } else if (total >= 40) {
      // Honest reassurance for deep inventory — the opposite of false urgency.
      chips.push({ kind: "calm", text: "Plenty of seats available" });
    }
    if (splits === 1) {
      chips.push({ kind: "info", text: "Limited quantity options" });
    }
    if (!chips.length) {
      host.hidden = true;
      return;
    }
    for (const c of chips) {
      const el = document.createElement("span");
      el.className = `scarcity-chip scarcity-${c.kind}`;
      el.textContent = c.text;
      host.appendChild(el);
    }
    host.hidden = false;
  }

  // ---------- "Deal & demand" panel ----------
  // Cross-source market context: how our price compares to the public
  // secondary market (SeatGeek/StubHub/Vivid/TickPick), a 30-day price
  // history sparkline, and a demand read. All numbers are consumer-safe
  // (server projects only public market + our-listed prices — never
  // owned/wholesale fields). Fire-and-forget + self-hiding: any failure or
  // an event with no cross-source coverage simply leaves the panel hidden.
  async function loadMarketContext(eventId) {
    const host = document.getElementById("marketPanel");
    if (!host || !eventId) return;
    let ctx;
    try {
      ctx = await api(`/api/store/events/${encodeURIComponent(eventId)}/market-context`);
    } catch {
      return; // network/timeout — leave the panel hidden, never block listings
    }
    if (!ctx || ctx.available === false) return;
    const html = renderMarketContext(ctx);
    if (!html) return;
    host.innerHTML = html;
    host.hidden = false;
  }

  // Tiny dependency-free SVG sparkline: two polylines (ours vs market) over
  // the daily series. Nulls are skipped (the series has market gaps). Returns
  // "" when there's nothing plottable.
  function priceSparkline(series) {
    const pts = (series || []).filter((p) => p && (p.ours != null || p.market != null));
    if (pts.length < 2) return "";
    const W = 280, H = 56, padX = 4, padY = 6;
    const ys = [];
    pts.forEach((p) => { if (p.ours != null) ys.push(+p.ours); if (p.market != null) ys.push(+p.market); });
    const ymin = Math.min(...ys), ymax = Math.max(...ys);
    const span = ymax - ymin || 1;
    const x = (i) => padX + (i * (W - 2 * padX)) / (pts.length - 1);
    const y = (v) => padY + (H - 2 * padY) * (1 - (v - ymin) / span);
    const line = (key) => pts
      .map((p, i) => (p[key] == null ? null : `${x(i).toFixed(1)},${y(+p[key]).toFixed(1)}`))
      .filter(Boolean)
      .join(" ");
    const market = line("market"), ours = line("ours");
    return (
      `<svg class="mp-spark" viewBox="0 0 ${W} ${H}" width="100%" height="${H}" ` +
      `preserveAspectRatio="none" aria-hidden="true">` +
      (market ? `<polyline class="mp-spark-market" points="${market}" fill="none" />` : "") +
      (ours ? `<polyline class="mp-spark-ours" points="${ours}" fill="none" />` : "") +
      `</svg>`
    );
  }

  function renderMarketContext(ctx) {
    const m = ctx.market || {};
    const bm = ctx.below_market;
    const demand = ctx.demand;
    const sources = Array.isArray(m.by_source) ? m.by_source : [];
    const blocks = [];

    // Headline: below-market deal proof.
    if (bm && bm.amount > 0) {
      blocks.push(
        `<div class="mp-deal">` +
          `<span class="mp-deal-badge">${bm.pct}% below market</span>` +
          `<span class="mp-deal-sub">about ${fmtMoney(bm.amount)} under the ${escapeHtml(bm.vs || "market")}` +
          (m.recent_sale_median ? ` · recently selling around ${fmtMoney(m.recent_sale_median)}` : "") +
          `</span>` +
        `</div>`
      );
    }

    // Demand read (honest — price-movement based, not fabricated urgency).
    if (demand && demand.label) {
      const arrow = demand.label === "rising" ? "▲" : demand.label === "cooling" ? "▼" : "•";
      const pct = demand.getin_change_24h_pct;
      const sub = pct != null && Number(pct) !== 0
        ? `get-in price ${Number(pct) > 0 ? "+" : ""}${Number(pct).toFixed(0)}% in 24h`
        : "prices steady";
      blocks.push(
        `<div class="mp-demand mp-demand-${escapeHtml(demand.label)}">` +
          `<span class="mp-demand-dot">${arrow}</span> Demand ${escapeHtml(demand.label)} · ${escapeHtml(sub)}` +
        `</div>`
      );
    }

    // Cross-marketplace comparison rows. "ours" first, then each public source.
    const rows = [];
    if (ctx.our_from_price != null) {
      rows.push(`<div class="mp-row mp-row-ours"><span>VibePass (our price)</span><strong>${fmtMoney(ctx.our_from_price)}</strong></div>`);
    }
    sources.forEach((s) => {
      if (s && s.median != null) {
        rows.push(`<div class="mp-row"><span>${escapeHtml(s.label)} median</span><strong>${fmtMoney(s.median)}</strong></div>`);
      }
    });
    if (rows.length >= 2) {
      blocks.push(`<div class="mp-compare">${rows.join("")}</div>`);
    }

    // Price-history sparkline.
    const spark = priceSparkline(ctx.history);
    if (spark) {
      blocks.push(
        `<div class="mp-history">` +
          `<div class="mp-history-head">Price history` +
            `<span class="mp-legend"><i class="mp-key-ours"></i>ours <i class="mp-key-market"></i>market</span>` +
          `</div>` + spark +
        `</div>`
      );
    }

    if (!blocks.length) return "";
    return `<h2 class="mp-title">Deal &amp; demand</h2>${blocks.join("")}`;
  }

  // ---------- Event detail page ----------
  // SEO + share-card metadata updater. Runs after /api/store/events/:id
  // resolves so document.title + OG tags reflect the event name + venue.
  // Pure DOM mutation; no fetches. Crawlers/preview-bots that run JS pick
  // these up; static fallbacks in <head> cover the no-JS path.
  function updateEventMeta(event) {
    if (!event) return;
    const name = String(event.name || "").trim();
    const venue = event.venue || {};
    const venueLabel = [venue.name, venue.location].filter(Boolean).join(", ");
    const titleText = name
      ? `${name} — VibePass`
      : "Event tickets — VibePass";
    const descText = name && venueLabel
      ? `Direct-inventory tickets for ${name} at ${venueLabel}. Transparent pricing on VibePass.`
      : (name
          ? `Direct-inventory tickets for ${name}. Transparent pricing on VibePass.`
          : "Direct-inventory event tickets. Transparent pricing on VibePass.");

    document.title = titleText;
    const setMeta = (selector, value) => {
      const el = document.querySelector(selector);
      if (el && value != null) el.setAttribute("content", String(value));
    };
    setMeta('meta[name="description"]', descText);
    setMeta('meta[property="og:title"]', titleText);
    setMeta('meta[property="og:description"]', descText);
    setMeta('meta[property="og:url"]', location.href);
    setMeta('meta[name="twitter:title"]', titleText);
    setMeta('meta[name="twitter:description"]', descText);
    // Canonical = filter-less event URL (drop ?zones=&min_price= etc.) so
    // the filter variants don't fragment into duplicate-content pages.
    const canonical = document.querySelector('link[rel="canonical"]');
    if (canonical) canonical.setAttribute("href", location.origin + location.pathname);
  }

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

    // TEvo Hosted Checkout config — DORMANT unless the server has
    // STOREFRONT_CHECKOUT_DOMAIN set. When checkout_domain is present the
    // Reserve button redirects the buyer to TEvo's hosted checkout (TEvo =
    // merchant-of-record) instead of the MVP mock. Fetched once here;
    // openModal (a user click) always runs well after this resolves, and
    // if it somehow hasn't, the default below keeps the safe mock path.
    let purchaseConfig = { checkout_domain: null, purchase_enabled: false };
    api("/api/public/config")
      .then((cfg) => {
        if (cfg && cfg.checkout_domain) {
          purchaseConfig = {
            checkout_domain: String(cfg.checkout_domain),
            purchase_enabled: !!cfg.purchase_enabled,
          };
        }
      })
      .catch(() => { /* dormant default stays → mock reserve */ });

    // Build TEvo's hosted-checkout URL per their spec:
    //   https://<domain>/checkout/payment/<event_id>/<ticket_group_id>?quantity=N
    function hostedCheckoutUrl(domain, evId, tgId, qty) {
      const d = String(domain).replace(/^https?:\/\//, "").replace(/\/+$/, "");
      const q = Math.max(1, Number(qty) || 1);
      return `https://${d}/checkout/payment/${Number(evId)}/${Number(tgId)}?quantity=${q}`;
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
    // Shared listing lookup — keyed by string(listing.id). renderListings()
    // and renderParkingTab() write into this; the single delegated Reserve
    // click handler reads from it. Replaces the prior per-row
    // `btn.addEventListener` pattern, which accumulated handlers on every
    // re-render (filter change, refetch) without ever removing them.
    const listingsByIdMap = new Map();
    // Section universe — server tells us every section present in the
    // unfiltered owned set (`sections_available`). We cache it so the
    // section chip group keeps showing every section even after the user
    // selects one and the listings narrow. Multi-select needs all chips
    // to stay clickable.
    let sectionsAvailable = [];
    // Quantities the seller offers (`splits_available`). The min-qty
    // dropdown is rebuilt from this list — no "any" when nothing sells
    // singles, no "4+" when no listing has a split ≥ 4.
    let splitsAvailable = [];
    let event = null;
    // Interactive seat map mounts once per event (the build refetches the
    // manifest + spins up the bundled React tree — expensive). applyEventResponse
    // runs on every filter change, so we guard against re-mounting; instead we
    // refresh the existing map's prices when listings shift (see maybeMountSeatmap).
    let seatmapMounted = false;
    let seatmapApi = null;
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

    // One-time delegated click handler for Reserve buttons. Resolves the
    // listing via `data-listing-id` against `listingsByIdMap`. Prevents
    // the previous leak where every re-render attached fresh per-row
    // listeners with no cleanup.
    function onReserveDelegatedClick(e) {
      const btn = e.target.closest("button[data-action='reserve']");
      if (!btn) return;
      const id = btn.dataset.listingId;
      if (!id) return;
      const listing = listingsByIdMap.get(id);
      if (listing) openModal(listing);
    }
    listEl.addEventListener("click", onReserveDelegatedClick);

    // ---- Quick pricing rollup (from-price by quantity + by section) ----
    // Computed client-side from the same listings array the server returns.
    // No new fetch, no broker-internal fields. Re-runs from renderListings()
    // so filter changes update the rollup. Buckets a listing into every
    // quantity tier its `splits` array exposes (TEvo ticket_groups.splits is
    // the allowed split sizes; absent → fall back to available_quantity).
    function _qpBucketFor(n) {
      if (n === 1) return "singles";
      if (n === 2) return "pairs";
      if (n === 3) return "triples";
      if (n === 4) return "quads";
      if (n >= 5) return "five_plus";
      return null;
    }
    function _qpBucketsFromListing(l) {
      const fromSplits = Array.isArray(l.splits) && l.splits.length
        ? l.splits
        : [Number(l.available_quantity || 0)];
      const set = new Set();
      fromSplits.forEach((s) => {
        const b = _qpBucketFor(Number(s) || 0);
        if (b) set.add(b);
      });
      return Array.from(set);
    }
    function renderQuickPricing(listings) {
      const host = $("#quickPricing");
      const bucketsHost = $("#qpBuckets");
      const sectionsHost = $("#qpSections");
      if (!host || !bucketsHost || !sectionsHost) return;
      bucketsHost.replaceChildren();
      sectionsHost.replaceChildren();
      if (!listings || !listings.length) {
        host.hidden = true;
        return;
      }

      // Quantity buckets: groups offering + min retail_price for each.
      const order = ["singles", "pairs", "triples", "quads", "five_plus"];
      const labels = { singles: "1", pairs: "2", triples: "3", quads: "4", five_plus: "5+" };
      const agg = {};
      order.forEach((b) => { agg[b] = { groups: 0, min_price: null }; });
      for (const l of listings) {
        const px = Number(l.retail_price);
        if (!Number.isFinite(px) || px <= 0) continue;
        for (const b of _qpBucketsFromListing(l)) {
          agg[b].groups += 1;
          if (agg[b].min_price == null || px < agg[b].min_price) agg[b].min_price = px;
        }
      }
      const anyBucket = order.some((b) => agg[b].groups > 0);
      if (anyBucket) {
        order.forEach((b) => {
          const cell = document.createElement("div");
          cell.className = "qp-bucket";
          if (!agg[b].groups) cell.classList.add("empty");
          const qty = document.createElement("div");
          qty.className = "qp-qty";
          qty.textContent = labels[b];
          const price = document.createElement("div");
          price.className = "qp-price";
          price.textContent = agg[b].min_price != null ? `from ${fmtMoney(agg[b].min_price)}` : "—";
          const grp = document.createElement("div");
          grp.className = "qp-meta muted";
          grp.textContent = agg[b].groups
            ? `${agg[b].groups} listing${agg[b].groups === 1 ? "" : "s"}`
            : "none";
          cell.append(qty, price, grp);
          bucketsHost.append(cell);
        });
      }

      // Section rollup: top 10 sections by listings count.
      const bySection = new Map();
      for (const l of listings) {
        const sec = (l.section == null || l.section === "") ? "—" : String(l.section);
        const px = Number(l.retail_price);
        const tix = Number(l.available_quantity) || 0;
        const cur = bySection.get(sec) || { section: sec, listings: 0, tickets: 0, min_price: null };
        cur.listings += 1;
        cur.tickets += tix;
        if (Number.isFinite(px) && px > 0 && (cur.min_price == null || px < cur.min_price)) {
          cur.min_price = px;
        }
        bySection.set(sec, cur);
      }
      const top = Array.from(bySection.values())
        .sort((a, b) => b.listings - a.listings || (a.min_price ?? Infinity) - (b.min_price ?? Infinity))
        .slice(0, 10);
      if (top.length > 1) {
        const hdr = document.createElement("div");
        hdr.className = "qp-sections-hdr muted";
        hdr.textContent = `By section · top ${top.length}`;
        sectionsHost.append(hdr);
        const ul = document.createElement("ul");
        ul.className = "qp-sec-list";
        top.forEach((r) => {
          const li = document.createElement("li");
          li.className = "qp-sec";
          const name = document.createElement("span");
          name.className = "qp-sec-name";
          name.textContent = `Sec ${r.section}`;
          const meta = document.createElement("span");
          meta.className = "qp-sec-meta muted";
          meta.textContent = `${r.listings} · ${r.tickets} tix`;
          const price = document.createElement("span");
          price.className = "qp-sec-price";
          price.textContent = r.min_price != null ? `from ${fmtMoney(r.min_price)}` : "—";
          li.append(name, meta, price);
          ul.append(li);
        });
        sectionsHost.append(ul);
        sectionsHost.hidden = false;
      } else {
        sectionsHost.hidden = true;
      }

      host.hidden = !(anyBucket || top.length > 1);
    }

    // ---- Listings rendering (server already filtered) ----
    function renderListings() {
      listCount.textContent = `${allListings.length}`;
      listEl.replaceChildren();
      renderQuickPricing(allListings);
      if (!allListings.length) {
        noListings.hidden = false;
        return;
      }
      noListings.hidden = true;
      // Cheapest option in the current view — an honest anchor for the
      // "pick one" decision (factual; only shown when there's a choice).
      const _prices = allListings
        .map((l) => Number(l.retail_price))
        .filter((v) => !isNaN(v) && v > 0);
      const _minPrice = _prices.length ? Math.min(..._prices) : null;
      let _badgedLowest = false;
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
        // Badge the first listing that matches the minimum price (once).
        if (!_badgedLowest && _minPrice != null && allListings.length > 1
            && Number(l.retail_price) === _minPrice) {
          const best = document.createElement("span");
          best.className = "tag best";
          best.textContent = "Lowest price";
          section.append(" ", best);
          _badgedLowest = true;
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
        btn.dataset.action = "reserve";
        if (l.id != null) {
          const key = String(l.id);
          btn.dataset.listingId = key;
          listingsByIdMap.set(key, l);
        }

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

    // Parking tab renderer + toggle wiring. Simpler than the seat list:
    // no zones, no row labels (parking "row" is rarely meaningful), no
    // split-quantities (parking is single-pass per listing). One row per
    // parking lot/section sorted by price asc.
    function renderParkingTab(parkingListings, parkingCount) {
      const tabs = $("#listingTabs");
      const tabCountEl = $("#parkingTabCount");
      const parkUl = $("#parkingListings");
      const filterBar = $("#filterBar");
      if (!tabs || !parkUl) return;

      if (!parkingListings.length) {
        tabs.hidden = true;
        parkUl.hidden = true;
        parkUl.replaceChildren();
        return;
      }
      tabs.hidden = false;
      tabCountEl.textContent = String(parkingCount);
      // Screen-reader-friendly label so the parking tab announces as
      // "Parking, 12 listings" instead of two disconnected tokens. Per D1
      // UX audit 2026-05-12 fix #4.
      const parkTabBtn = tabs.querySelector('[data-tab="parking"]');
      if (parkTabBtn) {
        parkTabBtn.setAttribute(
          "aria-label",
          `Parking, ${parkingCount} listing${parkingCount === 1 ? "" : "s"}`,
        );
        // Remove any prior aria-disabled (in case earlier render set it).
        parkTabBtn.removeAttribute("aria-disabled");
      }

      parkUl.replaceChildren();
      for (const l of parkingListings) {
        const li = document.createElement("li");
        li.className = "row parking-row";

        const seat = document.createElement("div");
        seat.className = "seat";
        const section = document.createElement("div");
        section.className = "section";
        section.textContent = l.section || "Parking";
        seat.append(section);
        // No row label for parking — most lots don't have meaningful rows.

        const qbox = document.createElement("div");
        qbox.className = "qbox";
        qbox.textContent = `${l.available_quantity || 0} pass${(l.available_quantity || 0) === 1 ? "" : "es"} available`;

        const pbox = document.createElement("div");
        pbox.className = "pbox";
        pbox.append(document.createTextNode(fmtMoney(l.retail_price)));
        const each = document.createElement("span");
        each.className = "each";
        each.textContent = "per pass";
        pbox.append(each);

        const btn = document.createElement("button");
        btn.className = "btn";
        btn.textContent = "Reserve";
        btn.dataset.action = "reserve";
        if (l.id != null) {
          const key = String(l.id);
          btn.dataset.listingId = key;
          listingsByIdMap.set(key, l);
        }

        li.append(seat, qbox, pbox, btn);
        if (l.public_notes) {
          const notes = document.createElement("div");
          notes.className = "notes";
          notes.textContent = l.public_notes;
          li.append(notes);
        }
        parkUl.append(li);
      }

      // One-time delegated click handler on parkUl. Shares the same
      // resolution path as the seats list — looks up the listing via
      // `data-listing-id` in `listingsByIdMap`. Gated by `dataset.wired`
      // so we don't stack handlers across renderParkingTab() calls.
      if (!parkUl.dataset.wired) {
        parkUl.dataset.wired = "1";
        parkUl.addEventListener("click", onReserveDelegatedClick);
      }

      // Wire tab toggle once; idempotent — first click handler win.
      if (!tabs.dataset.wired) {
        tabs.dataset.wired = "1";
        const seatsTab = tabs.querySelector('[data-tab="seats"]');
        const parkingTab = tabs.querySelector('[data-tab="parking"]');
        function setActive(name) {
          const seats = name === "seats";
          seatsTab.classList.toggle("is-active", seats);
          parkingTab.classList.toggle("is-active", !seats);
          seatsTab.setAttribute("aria-selected", String(seats));
          parkingTab.setAttribute("aria-selected", String(!seats));
          // Seat-side UI (filters + seat list + no-match line) is shown
          // only on the Seats tab; parking list flips inverse.
          if (filterBar) filterBar.hidden = !seats;
          $("#listings").hidden = !seats;
          const qp = $("#quickPricing");
          if (qp && !seats) qp.hidden = true;
          else if (qp && seats) renderQuickPricing(allListings);
          const noMatch = $("#noListings");
          if (noMatch && !seats) noMatch.hidden = true;
          parkUl.hidden = seats;
        }
        seatsTab.addEventListener("click", () => setActive("seats"));
        parkingTab.addEventListener("click", () => setActive("parking"));
        setActive("seats");
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

      // Live online checkout is DISABLED — the storefront performs no online
      // checkout. Defensive client guard (server also force-returns checkout
      // off via /api/public/config): never redirect to a hosted-checkout URL,
      // regardless of any (stale/cached) purchaseConfig. Re-enabling requires
      // both this guard and the server kill switch (STOREFRONT_CHECKOUT_DISABLED).
      const CHECKOUT_DISABLED = true;
      const checkoutLive = !CHECKOUT_DISABLED
        && !!purchaseConfig.purchase_enabled && !!purchaseConfig.checkout_domain;

      const confirm = document.createElement("button");
      confirm.className = "btn";
      confirm.id = "confirmReserve";
      confirm.style.width = "100%";
      confirm.textContent = checkoutLive ? "Continue to checkout" : "Reserve (mock)";

      const disc = document.createElement("p");
      disc.className = "disclaimer";
      disc.textContent = checkoutLive
        ? "You'll complete payment securely on Ticket Evolution, our ticketing partner. Apple Pay and Google Pay supported."
        : "MVP demo only — no payment will be processed and no order will be sent to Ticket Evolution. This shows what the confirmation flow would look like once checkout is wired up.";

      // Honeypot — hidden from humans (off-screen, not a real "hidden" input so
      // some bots still see it), aria-hidden + no autofill. A non-empty value on
      // submit means a bot filled it; the server rejects the reserve.
      const hp = document.createElement("input");
      hp.type = "text";
      hp.id = "rsvCompany";
      hp.name = "company";
      hp.tabIndex = -1;
      hp.autocomplete = "off";
      hp.setAttribute("aria-hidden", "true");
      hp.style.cssText = "position:absolute;left:-9999px;width:1px;height:1px;opacity:0;pointer-events:none";

      mb.append(h3, sub, label, receipt, confirm, disc, hp);

      qSel.value = String(defaultQ);
      const recompute = () => {
        const q = Number(qSel.value);
        $("#rcQty", mb).textContent = String(q);
        totV.textContent = fmtMoney(Number(listing.retail_price) * q);
      };
      qSel.addEventListener("change", recompute);

      confirm.addEventListener("click", async () => {
        // Live path: hand off to TEvo's hosted checkout (TEvo = MOR). This
        // is a top-level navigation to TEvo's domain — no backend write, no
        // payment handled here. Not blocked by our CSP (form-action only
        // gates form POSTs, not JS navigations).
        if (checkoutLive) {
          confirm.disabled = true;
          confirm.textContent = "Redirecting to checkout…";
          window.location.assign(
            hostedCheckoutUrl(purchaseConfig.checkout_domain, eventId, listing.id, qSel.value),
          );
          return;
        }
        // Dormant path (default): MVP mock — validate availability only.
        confirm.disabled = true;
        confirm.textContent = "Validating with TEvo…";
        try {
          // Bot gate: honeypot value + a fresh reCAPTCHA token as a fallback
          // when the first-interaction cookie is unavailable (both no-ops when
          // the gate is dormant). The cookie, if set, rides along automatically.
          const rcToken = window.StoreBot ? await window.StoreBot.token("submit") : null;
          const res = await api("/api/store/reserve", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              event_id: eventId,
              ticket_group_id: listing.id,
              quantity: Number(qSel.value),
              hp: hp.value || "",
              recaptcha_token: rcToken || undefined,
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
      trapModalFocus();
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
      releaseModalFocus();
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

    // Rebuild the min-qty <select> so it only lists qtys the seller actually
    // offers. Server passes us `splits_available` — the distinct split values
    // across all listings (pre-min_qty-filter). We add "any" as the first
    // option only when at least one listing has a single-seat split, so a
    // venue that sells exclusively in pairs/quads doesn't tease "any" to
    // a shopper. Preserves the user's current selection if still valid.
    function rebuildMinQtyOptions(splits, currentValue) {
      if (!minQtyInput) return;
      const has1 = splits.includes(1);
      const uniques = Array.from(new Set(splits)).filter(n => n > 1).sort((a, b) => a - b);
      const desired = [
        // "any" only when single tickets exist somewhere
        ...(has1 ? [{ v: "", label: "any" }] : []),
        ...uniques.map(n => ({ v: String(n), label: `${n}+` })),
      ];
      if (!desired.length) {
        // No listings at all (or no split data) — show a single inert option.
        desired.push({ v: "", label: "any" });
      }
      minQtyInput.innerHTML = "";
      const wanted = currentValue != null ? String(currentValue) : "";
      let preserveOK = false;
      for (const o of desired) {
        const opt = document.createElement("option");
        opt.value = o.v;
        opt.textContent = o.label;
        if (o.v === wanted) { opt.selected = true; preserveOK = true; }
        minQtyInput.append(opt);
      }
      // If the user's previous selection isn't valid anymore (e.g. they
      // had "4+" and the filter now leaves only single+pair listings),
      // fall back to the first option and re-fire the filter to keep
      // URL state honest.
      if (!preserveOK && currentValue != null && currentValue !== "") {
        suppressApply = true;
        try { minQtyInput.value = ""; } finally { suppressApply = false; }
        scheduleApply();
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
      // Letter-prefixed sections (Floor, Courtside, GA) come before numeric.
      const all = Array.from(new Set([...fromServer, ...fromListings, ...activeSet]))
        .sort(sectionSortCmp);
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

    // Sets the section chips matching `sections` to active and re-fetches.
    // Used by the interactive seat map's onSelect: clicking a section on the
    // map toggles the same chip a manual click would. Sections the map echoes
    // back that have no chip yet are appended (active) so the selection still
    // takes effect. Empty selection clears all section chips (show-all).
    function selectSectionsFromMap(sections) {
      const want = new Set((sections || []).map((s) => String(s).trim()).filter(Boolean));
      // Make sure every wanted section has a chip; renderSectionChips already
      // includes active sections in its universe, so seed activeSet via the
      // existing chips plus any new ones.
      const have = new Set($$(".filter-chip", sectionChipsEl).map((c) => c.dataset.value));
      const missing = [...want].filter((s) => !have.has(s));
      if (missing.length) {
        // Re-render with the new sections folded into the active set so they
        // render as real chips (keeps multi-select + clear working).
        renderSectionChips([...want]);
      } else {
        for (const chip of $$(".filter-chip", sectionChipsEl)) {
          chip.classList.toggle("on", want.has(chip.dataset.value));
        }
      }
      scheduleApply();
    }

    // Mount the interactive TEvo seat map into #seatmapHost, once per event.
    // No-op when the widget/bundle didn't load, when venue/config are missing,
    // or when already mounted. On a successful build the static seating-chart
    // image + any "unavailable" placeholder are hidden in favor of the map.
    function maybeMountSeatmap() {
      if (seatmapMounted) return;
      if (!window.StoreSeatmap || typeof window.StoreSeatmap.mount !== "function") return;
      const host = $("#seatmapHost");
      const venueId = event && event.venue && event.venue.id;
      const configId = event && event.configuration && event.configuration.id;
      if (!host || venueId == null || configId == null) return;
      seatmapMounted = true; // claim the slot up-front so re-renders don't race
      host.hidden = false;
      window.StoreSeatmap.mount({
        host,
        venueId,
        configurationId: configId,
        listings: allListings,
        onSelect: selectSectionsFromMap,
      }).then((result) => {
        if (result && result.api) {
          // Map built — hide the static fallback so we don't show both.
          seatmapApi = result.api;
          seatMap.style.display = "none";
          const ph = host.parentElement && host.parentElement.querySelector(".map-placeholder");
          if (ph) ph.remove();
        } else {
          // No published map (or build failed) — drop the empty host and let
          // the static image/placeholder stand. Allow a retry on a later event.
          host.hidden = true;
          seatmapMounted = false;
        }
      }).catch(() => {
        host.hidden = true;
        seatmapMounted = false;
      });
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
      // Clear any prior inline filter error before retrying.
      showFilterError(null);
      try {
        const res = await api(`/api/store/events/${eventId}${buildQueryString(f)}`);
        applyEventResponse(res, resolvedShare);
      } catch (err) {
        // Surface in the filter bar so the user knows the apply failed
        // (was silently console.error'd before). Per D1 UX audit
        // 2026-05-12 fix #5. Existing rendered listings stay visible —
        // filter just didn't refresh, not catastrophic.
        console.error("filter apply failed:", err);
        const msg = (err && err.message ? String(err.message) : "Filter unavailable").slice(0, 120);
        showFilterError(`Filter didn't apply: ${msg} · listings shown reflect prior state`);
      }
    }

    // Inline filter-bar error pill. Pass null to clear. Same pattern as
    // the search dropdown's .suggest-status.error.
    function showFilterError(text) {
      const bar = $("#filterBar");
      if (!bar) return;
      let pill = bar.querySelector(".filter-error");
      if (!text) {
        if (pill) pill.remove();
        return;
      }
      if (!pill) {
        pill = document.createElement("div");
        pill.className = "filter-error";
        bar.append(pill);
      }
      pill.textContent = text;
    }

    // ---- Banner: shows when any filter is active or arriving via /s/{id} ----
    // Translate raw filters into shopper-friendly "fit" criteria for the
    // curated/concierge view (e.g. min_qty:2 → "2+ seats together").
    function friendlyFitChips(filters) {
      const f = filters || {};
      const chips = [];
      if (f.zones?.length) chips.push(f.zones.join(", "));
      if (f.section?.length) chips.push(`Section ${f.section.join(", ")}`);
      if (f.min_price != null && f.max_price != null) chips.push(`${fmtMoney(f.min_price)}–${fmtMoney(f.max_price)}`);
      else if (f.max_price != null) chips.push(`under ${fmtMoney(f.max_price)}`);
      else if (f.min_price != null) chips.push(`from ${fmtMoney(f.min_price)}`);
      if (f.min_qty != null) chips.push(`${f.min_qty}+ seats together`);
      return chips;
    }

    function showSharedBanner(filters, totalBefore, listingsCount, share) {
      const banner = $("#sharedBanner");
      const summary = $("#sharedSummary");
      const clearLink = $("#clearShared");
      const isFiltered = hasActiveFilters(filters || {});
      if (!isFiltered && !share) {
        banner.hidden = true;
        banner.classList.remove("concierge");
        return;
      }
      summary.replaceChildren();

      if (share) {
        // ---- Concierge / "hand-picked for you" framing (arrived via /s/{id}) ----
        // This is the core VibePass loop: a curated set sent to a buyer who
        // picks one. Present it as a recommendation, not a raw filtered list.
        banner.classList.add("concierge");
        const count = Number(listingsCount) || 0;

        const eyebrow = document.createElement("div");
        eyebrow.className = "concierge-eyebrow";
        eyebrow.textContent = "🎟️ Hand-picked for you";
        summary.append(eyebrow);

        if (share.note) {
          const note = document.createElement("p");
          note.className = "concierge-note";
          note.textContent = `"${share.note}"`;
          summary.append(note);
        }

        const fit = friendlyFitChips(filters);
        if (fit.length) {
          const fitWrap = document.createElement("div");
          fitWrap.className = "fit-chips";
          const lead = document.createElement("span");
          lead.className = "fit-lead";
          lead.textContent = "Matched to:";
          fitWrap.append(lead);
          fit.forEach((c) => {
            const chip = document.createElement("span");
            chip.className = "fit-chip";
            chip.textContent = c;
            fitWrap.append(chip);
          });
          summary.append(fitWrap);
        }

        const line = document.createElement("p");
        line.className = "concierge-line";
        line.textContent = count === 1
          ? "1 option that fits — review the details and grab it below."
          : `${count} options that fit — pick the one you like below.`;
        summary.append(line);

        // Set the listings heading so the set reads as recommendations.
        const h = document.querySelector(".listings h2");
        if (h && h.firstChild && h.firstChild.nodeType === 3) {
          h.firstChild.textContent = "Your options ";
        }
      } else {
        // ---- Inline filtered view (user narrowed on the page themselves) ----
        const filterText = friendlyFitChips(filters).join(" · ") || "no filters";
        const strong = document.createElement("strong");
        strong.textContent = "Filtered view";
        summary.append(
          strong,
          document.createTextNode(
            ` · ${filterText} · showing ${Number(listingsCount) || 0} of ${Number(totalBefore) || 0}`
          ),
        );
      }

      if (clearLink && eventId) clearLink.href = `/store/event/${Number(eventId) || 0}`;
      if (clearLink) clearLink.textContent = share ? "see all available seats" : "show all listings";
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
      // Same trick for split-quantities. Rebuild the min-qty dropdown to
      // match what's actually offered.
      if (Array.isArray(res.splits_available)) {
        splitsAvailable = res.splits_available.slice();
        rebuildMinQtyOptions(splitsAvailable, readFiltersFromUI().min_qty);
      }
      const filters = res.filters || readFiltersFromUI();

      // Honest-scarcity cues from the unfiltered owned set.
      renderScarcity(res);

      $("#evName").textContent = event.name || "Untitled event";

      // Update SEO/share-card metadata from the resolved event payload.
      // Crawlers that DO run JS (Googlebot, modern social previewers) pick
      // up these mutations; static fallback values in <head> cover the
      // no-JS / static-snapshot path.
      updateEventMeta(event);

      // "Deal & demand" panel — fire-and-forget cross-source market context.
      // Non-blocking and self-hiding; a failure never affects the listings.
      loadMarketContext(event.id || eventId);

      // Venue hero image (audit-lane venue_assets.hero_image_url). Subtle
      // backdrop, dimmed by CSS so the heading stays legible.
      const heroEl = $("#evHero");
      if (heroEl) {
        const hero = event.venue?.hero_image_url;
        if (hero) {
          heroEl.style.backgroundImage = `url("${String(hero).replace(/"/g, "%22")}")`;
          heroEl.hidden = false;
        } else {
          heroEl.style.backgroundImage = "";
          heroEl.hidden = true;
        }
      }

      // Venue — clickable link to /store?venue_id=X so users can browse
      // other events at the same venue. Falls back to plain text when no id.
      const venueEl = $("#evVenue");
      venueEl.replaceChildren();
      const venueLabel = [event.venue?.name, event.venue?.location].filter(Boolean).join(" · ");
      if (event.venue?.id) {
        const a = document.createElement("a");
        a.href = `/store?venue_id=${Number(event.venue.id) || 0}`;
        a.className = "venue-link";
        a.textContent = venueLabel;
        venueEl.append(a);
      } else {
        venueEl.textContent = venueLabel;
      }
      $("#evDate").textContent = fmtWhen(event.occurs_at_local);

      // Venue tag pills — indoor/outdoor + capacity (audit-lane data).
      const tagsEl = $("#evVenueTags");
      if (tagsEl) {
        tagsEl.replaceChildren();
        const v = event.venue || {};
        if (v.is_indoor === true || v.is_indoor === false) {
          const pill = document.createElement("span");
          pill.className = "venue-tag";
          pill.textContent = v.is_indoor ? "indoor" : "outdoor";
          tagsEl.append(pill);
        }
        if (v.capacity && Number(v.capacity) > 0) {
          const pill = document.createElement("span");
          pill.className = "venue-tag";
          pill.textContent = `cap ${Number(v.capacity).toLocaleString()}`;
          tagsEl.append(pill);
        }
      }

      const perfEl = $("#evPerformers");
      perfEl.replaceChildren();
      const perfs = event.performers || [];
      perfs.forEach((p, i) => {
        if (i > 0) {
          const sep = document.createElement("span");
          sep.className = "muted";
          sep.textContent = " vs ";
          perfEl.append(sep);
        }
        // Wrap each performer chip in an anchor to /store?performer_id=X so
        // users can browse other events for the same performer.
        const wrap = document.createElement(p.id ? "a" : "span");
        wrap.className = "perf-chip";
        if (p.id) wrap.href = `/store?performer_id=${Number(p.id) || 0}`;
        if (p.color_primary) wrap.style.setProperty("--perf-color", p.color_primary);
        if (p.logo_url) {
          const img = document.createElement("img");
          img.src = p.logo_url;
          img.alt = "";
          img.className = "perf-logo";
          img.loading = "lazy";
          wrap.append(img);
        }
        const txt = document.createElement("span");
        txt.textContent = p.name + (p.primary ? " (home)" : "");
        wrap.append(txt);
        perfEl.append(wrap);
      });

      // Context strip — rivalry / MLB series / tournament / holiday +
      // weather. Full variant (includes date ranges and Wikipedia link).
      // Container stays hidden when nothing applies so the header area
      // doesn't reserve empty space.
      const ctxEl = $("#evContext");
      if (ctxEl) {
        ctxEl.replaceChildren();
        const ctx = res.context || {};
        const ctxBadges = buildContextBadges(ctx, { compact: false });
        const holidayBadge = buildHolidayBadge(ctx.holiday, { compact: false });
        let any = false;
        if (ctxBadges.length || holidayBadge) {
          // Pills row first (badges + holiday share a flex line).
          const pills = document.createElement("div");
          pills.className = "context-pills";
          ctxBadges.forEach((b) => pills.append(b));
          if (holidayBadge) pills.append(holidayBadge);
          ctxEl.append(pills);
          any = true;
        }
        // Weather row beneath the pills — alerts + forecast line. Renders
        // its own fragment so we don't have to know the alert count here.
        const weatherFrag = buildWeatherRow(ctx.weather);
        if (weatherFrag && weatherFrag.childNodes.length) {
          ctxEl.append(weatherFrag);
          any = true;
        }
        ctxEl.hidden = !any;
      }

      // Seating chart: prefer medium, fall back to large. When the venue has
      // no static chart, swap the <img> for a styled empty placeholder so the
      // 2-column event-body grid keeps its left column (without the placeholder
      // the listings reflow into the empty space, jumping content around at
      // the 760px breakpoint). Per D1 UX audit 2026-05-12 fix #3.
      // Defensive: v_event_seating_chart / TEvo sometimes carry the literal
      // string "null" (or "none"/"") for an absent chart. Treat those as no
      // map so we don't set <img src="null"> (a broken image resolving to
      // /store/event/null). Backend also coerces these, but guard here too
      // in case a stale-cached payload slips through.
      const cleanMapUrl = (v) => {
        if (!v) return null;
        const s = String(v).trim().toLowerCase();
        return (s === "null" || s === "none" || s === "undefined" || s === "") ? null : v;
      };
      const map = cleanMapUrl(event.configuration?.seating_chart_medium)
        || cleanMapUrl(event.configuration?.seating_chart_large);
      const mapHost = seatMap.parentElement; // the <aside class="map">
      if (map) {
        seatMap.src = map;
        seatMap.style.display = "";
        // Remove any previously rendered placeholder if we now have a map.
        const existing = mapHost && mapHost.querySelector(".map-placeholder");
        if (existing) existing.remove();
      } else {
        seatMap.style.display = "none";
        if (mapHost && !mapHost.querySelector(".map-placeholder")) {
          const ph = document.createElement("div");
          ph.className = "map-placeholder";
          ph.textContent = "Seating chart unavailable for this venue.";
          mapHost.append(ph);
        }
      }

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

      // Interactive seat map — replaces the static image when the venue +
      // configuration resolve to a published TEvo map. Mount AFTER #body is
      // unhidden: Tevomaps reads the container's size at build() time, so a
      // zero-size container (hidden ancestor) bakes a blank map that never
      // re-fits — the white-box bug. rAF lets layout settle so the host has
      // real clientWidth/Height. Mounts once (the build is heavy); on success
      // the static <img>/placeholder is hidden. Failure is silent — the static
      // fallback stays put.
      requestAnimationFrame(() => maybeMountSeatmap());
      // Re-render section chips against the new listings (sections may have
      // shifted as filters narrowed); zone chips are event-static so don't
      // need re-rendering here.
      renderSectionChips(filters.section || []);
      showSharedBanner(filters, res.total_before_filters || 0, res.listings_count || 0, share);

      // Parking tab — only surfaces when the server returned at least one
      // parking listing for this event. Tab UI stays inert otherwise so
      // events without parking inventory don't reserve UI real estate.
      renderParkingTab(res.parking_listings || [], res.parking_count || 0);
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
              <option value="" selected>auto · 1h after event start</option>
              <option value="1">expires in 1 day (capped at event end)</option>
              <option value="7">expires in 7 days (capped at event end)</option>
              <option value="30">expires in 30 days (capped at event end)</option>
              <option value="90">expires in 90 days (capped at event end)</option>
            </select>
            <p class="muted" style="font-size:11px;margin:6px 0 0">
              Links auto-expire 1 hour after event start regardless of choice — past tip-off the inventory is moot anyway.
            </p>
          </div>
        </div>

        <div class="social-share" role="group" aria-label="Share to social">
          <button type="button" class="social-btn" id="shareNative" hidden>
            <span aria-hidden="true">📲</span> Share…
          </button>
          <a class="social-btn" id="shareFb" target="_blank" rel="noopener noreferrer">
            <span aria-hidden="true">📘</span> Facebook
          </a>
          <a class="social-btn" id="shareX" target="_blank" rel="noopener noreferrer">
            <span aria-hidden="true">✖️</span> X
          </a>
          <a class="social-btn" id="shareWa" target="_blank" rel="noopener noreferrer">
            <span aria-hidden="true">💬</span> WhatsApp
          </a>
        </div>
        <p class="muted" style="font-size:11px;margin:8px 0 0" id="shareNativeHint" hidden>
          Tap <strong>Share…</strong> to post to Instagram Stories, TikTok, Messages and more.
        </p>

        <div class="share-actions">
          <a href="/store/shares" class="btn ghost" style="text-decoration:none">Manage links</a>
          <span style="flex:1"></span>
          <button class="btn" id="shareCopy">Copy link</button>
        </div>
      `;

      const useRevToggle = $("#useRevocable", mb);
      const copyBtn = $("#shareCopy", mb);
      const urlInput = $("#shareUrl", mb);

      // ---- Social share targets ----
      // The stateless URL is the canonical, crawler-unfurlable event link
      // (server injects per-event OG/Twitter/JSON-LD for bots — see
      // app.store_event_page). Facebook / X / WhatsApp take URL-intent links;
      // Instagram Stories + TikTok have no web-share URL, so they're reached
      // through the native share sheet (navigator.share) on mobile.
      const evTitle = ($("#evName")?.textContent || "Tickets on VibePass").trim();
      const shareText = `${evTitle} — tickets on VibePass`;
      function wireSocial(url) {
        const u = encodeURIComponent(url);
        const t = encodeURIComponent(shareText);
        const fb = $("#shareFb", mb);
        const x = $("#shareX", mb);
        const wa = $("#shareWa", mb);
        if (fb) fb.href = `https://www.facebook.com/sharer/sharer.php?u=${u}`;
        if (x) x.href = `https://twitter.com/intent/tweet?url=${u}&text=${t}`;
        if (wa) wa.href = `https://wa.me/?text=${encodeURIComponent(`${shareText} ${url}`)}`;
      }
      wireSocial(statelessUrl);
      // Native share sheet — only meaningful where the platform provides one
      // (mobile / some desktops). This is the Instagram-Stories / TikTok path.
      const nativeBtn = $("#shareNative", mb);
      if (nativeBtn && typeof navigator !== "undefined" && navigator.share) {
        nativeBtn.hidden = false;
        const hint = $("#shareNativeHint", mb);
        if (hint) hint.hidden = false;
        nativeBtn.addEventListener("click", async () => {
          const url = useRevToggle.checked && urlInput.value ? urlInput.value : statelessUrl;
          try {
            await navigator.share({ title: evTitle, text: shareText, url });
          } catch {
            /* user dismissed the sheet — no-op */
          }
        });
      }

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
          wireSocial(statelessUrl);
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
          wireSocial(url);
          await copyToClipboard(url);
          // Surface the expiry the server actually chose (may be capped at
          // event_start + 1h even if user picked 7 days). DOM-built so the
          // server's ISO string never lands in innerHTML.
          renderShareExpiryHint(mb, created.expires_at);
        } catch (e) {
          alert(`Could not create link: ${e.message}`);
          copyBtn.textContent = "Generate link";
        } finally {
          copyBtn.disabled = false;
        }
      });

      modal.hidden = false;
      trapModalFocus();
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
        // Normalized full-page error screen (404 dead-end vs retryable
        // upstream blip vs expired-share). Retry re-runs bootstrap.
        renderEventError(err, bootstrap);
      }
    }

    bootstrap();
  }

  // Replace any prior expiry hint in the share modal with a fresh "Expires at
  // {date}" note. Called after a revocable link is generated so the user can
  // confirm the server's chosen expiry (auto-cap may have moved it earlier
  // than the dropdown selection). DOM-built — date string from server.
  function renderShareExpiryHint(modalBody, expiresAtIso) {
    if (!modalBody) return;
    // Remove any prior hint so repeated Generate clicks don't stack.
    const prior = modalBody.querySelector(".share-expiry-hint");
    if (prior) prior.remove();
    if (!expiresAtIso) return;
    let when;
    try {
      const d = new Date(expiresAtIso);
      when = isNaN(d.getTime()) ? null : d.toLocaleString();
    } catch { when = null; }
    if (!when) return;
    const note = document.createElement("p");
    note.className = "share-expiry-hint muted";
    note.style.cssText = "font-size: 12px; margin: 8px 0 0; padding: 8px 10px; background: rgba(74,222,128,0.06); border: 1px solid rgba(74,222,128,0.18); border-radius: 6px; color: var(--good);";
    note.append(document.createTextNode("Active until "));
    const strong = document.createElement("strong");
    strong.textContent = when;
    note.append(strong);
    note.append(document.createTextNode(" · revoke any time at /store/shares"));
    modalBody.append(note);
  }

  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }
  function escapeAttr(s) { return escapeHtml(s); }

  // ---------- Normalized error messaging ----------
  // Single source of truth for turning a fetch failure from api() into a
  // user-facing error. api() throws "<status> <tag>: <detail>" for HTTP
  // errors and "timeout <tag>: …" for aborts; network failures surface the
  // raw fetch error. Maps to { code, title, message, retryable } so every
  // store surface (event detail screen, catalog inline error) speaks the
  // same language: not-found is a calm dead-end, an upstream blip offers a
  // retry. Keeps the backend's status normalization (404 vs 502/503) honest
  // on the UI side — a 404 must never read as "outage."
  function describeFetchError(err) {
    const raw = (err && err.message) ? String(err.message) : "";
    const m = raw.match(/^(\d{3})\b/);
    const code = m ? Number(m[1]) : null;
    const isTimeout = /\btimeout\b/i.test(raw) || (err && err.name === "AbortError");
    if (code === 404) return {
      code, retryable: false, title: "Event not found",
      message: "This event isn’t available — it may have ended, sold out, or been removed. Browse what’s on sale now.",
    };
    if (code === 410) return {
      code, retryable: false, title: "Share link expired",
      message: "This share link is no longer active — the seller may have revoked it or it passed its expiry. You can still browse all events.",
    };
    if (code === 429) return {
      code, retryable: true, title: "Too many requests",
      message: "We’re seeing heavy traffic right now. Give it a moment, then try again.",
    };
    if (isTimeout) return {
      code, retryable: true, title: "This is taking too long",
      message: "The server didn’t respond in time — it may be waking up. Try again in a few seconds.",
    };
    if (code === 502 || code === 503 || code === 504) return {
      code, retryable: true, title: "Temporarily unavailable",
      message: "We couldn’t reach our inventory provider just now. This is usually brief — try again in a moment.",
    };
    return {
      code, retryable: true, title: "Couldn’t load this event",
      message: "Something went wrong loading this event. Try again, or head back to the catalog.",
    };
  }

  // Render the full-page event-detail error screen (event.html #errorScreen).
  // Hides the loading/header/body sections and reveals a normalized error
  // panel. Retryable errors expose a "Try again" button wired to onRetry
  // (re-runs bootstrap). Falls back to the legacy inline #status line if the
  // markup isn't present (older cached event.html).
  function renderEventError(err, onRetry) {
    const spec = describeFetchError(err);
    const status = $("#status");
    const screen = $("#errorScreen");
    [$("#header"), $("#body"), $("#sharedBanner")].forEach((el) => { if (el) el.hidden = true; });
    if (!screen) {
      if (status) {
        status.hidden = false;
        status.textContent = `${spec.title}: ${spec.message}`;
        status.style.color = "var(--bad)";
      }
      return;
    }
    if (status) status.hidden = true;
    const icon = $("#errIcon", screen);
    const title = $("#errTitle", screen);
    const msg = $("#errMsg", screen);
    const retry = $("#errRetry", screen);
    const codeEl = $("#errCode", screen);
    screen.classList.toggle("is-unavailable", spec.retryable);
    screen.classList.toggle("is-notfound", !spec.retryable);
    if (icon) icon.textContent = spec.retryable ? "⚠️" : "🎟️";
    if (title) title.textContent = spec.title;
    if (msg) msg.textContent = spec.message;
    if (codeEl) {
      codeEl.hidden = !spec.code;
      if (spec.code) codeEl.textContent = `error ${spec.code}`;
    }
    if (retry) {
      retry.hidden = !spec.retryable;
      retry.onclick = (spec.retryable && typeof onRetry === "function")
        ? () => {
            screen.hidden = true;
            if (status) { status.hidden = false; status.textContent = "Loading event…"; status.style.color = ""; }
            onRetry();
          }
        : null;
    }
    screen.hidden = false;
  }

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

  // Reverse discovery — for fans who want to travel ALONG a favorite artist or team's
  // run (go city to city with them), not just catch one show. Location-first:
  // performers (and teams, via their away games) playing >= min_shows within a radius
  // of home in the window — i.e. a multi-stop run you can follow in person. Backed by
  // /api/store/tours/near; "Travel the whole tour" → /store/tour plans the dates.
  function mountDiscover() {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
    const money = (n) => "$" + Math.round(n).toLocaleString();
    const fmtD = (iso) => {
      try { return new Date(iso + "T00:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" }); }
      catch (_) { return iso; }
    };

    async function run() {
      const p = new URLSearchParams({
        home_lat: $("dLat").value, home_lon: $("dLon").value,
        within_mi: $("dMi").value || "250", days: $("dDays").value || "120",
        min_shows: $("dMin").value || "2",
      });
      if ($("dKind").value) p.set("concerts_only", "true");
      $("dStatus").textContent = "Searching…";
      $("dResults").innerHTML = "";
      try {
        render(await api("/api/store/tours/near?" + p.toString()));
      } catch (e) {
        $("dStatus").textContent = "Error: " + e.message;
      }
    }

    function render(d) {
      const tours = (d && d.tours) || [];
      $("dStatus").textContent = `${tours.length} tour${tours.length === 1 ? "" : "s"} within ${d.within_mi} mi`;
      $("dResults").innerHTML = tours.map((t) => {
        const badges = (t.hot ? '<span class="pill3 hot">🔥 hot</span>' : "")
          + (t.we_own ? '<span class="pill3 own">in stock</span>' : "");
        const shows = (t.events || [])
          .map((ev) => `<a href="/store/event/${ev.event_id}">${esc(ev.city || "")} ${fmtD(ev.date)}</a>`)
          .join("");
        const price = t.price_from != null ? ` · from ${money(t.price_from)}` : "";
        const isTeam = t.kind === "sports";
        // Teams surface by their road games near you (backend team_side='away'); the
        // side= flows to the follow-the-tour page so it plans the away leg.
        const side = isTeam ? (t.team_side === "home" ? "home" : "away") : "";
        const gamesLabel = side === "home" ? "home games" : "away games";
        // Hand off to the budget-first tour planner: performer + name (pre-fills the
        // search box) + side for teams. No coordinates — the tour flow is budget-only.
        const follow = `/store/tour?performer=${t.performer_id}`
          + `&name=${encodeURIComponent(t.performer || "")}`
          + (isTeam ? `&side=${side}` : "");
        return `<div class="tour-card"><h3>${esc(t.performer || "")}${badges}</h3>`
          + `<div class="tour-meta">${isTeam ? "team · " : ""}${t.nearby_shows} ${isTeam ? gamesLabel : "shows"} · ${t.cities} cit${t.cities === 1 ? "y" : "ies"} · nearest ${t.nearest_mi} mi${price}</div>`
          + `<div style="margin:6px 0"><a href="${follow}"><b>${isTeam ? "Travel with them →" : "Travel the whole tour →"}</b></a></div>`
          + `<div class="tour-shows">${shows}</div></div>`;
      }).join("") || "<p>No multi-show tours found near you in that window — widen the radius or window.</p>";
    }

    // City quick-picks: set coords without making the shopper know their
    // latitude. Presets carry hardcoded metro coords; "My location" uses the
    // browser geolocation API. Exact coords stay available under <details>.
    const cityChips = Array.from(document.querySelectorAll("#dCities .city-chip[data-lat]"));
    function markActive(el) {
      cityChips.forEach((c) => c.classList.toggle("active", c === el));
      const geo = $("dGeo");
      if (geo) geo.classList.toggle("active", el === geo);
    }
    function pickCity(el) {
      $("dLat").value = el.dataset.lat;
      $("dLon").value = el.dataset.lon;
      markActive(el);
      const sel = $("dSelected");
      if (sel) sel.textContent = `Showing tours within range of ${el.dataset.city}.`;
      run();
    }
    cityChips.forEach((c) => c.addEventListener("click", () => pickCity(c)));

    $("dGo").addEventListener("click", run);
    $("dGeo").addEventListener("click", () => {
      if (!navigator.geolocation) {
        $("dStatus").textContent = "Location isn't available — pick a city above.";
        return;
      }
      $("dStatus").textContent = "Locating…";
      navigator.geolocation.getCurrentPosition((pos) => {
        $("dLat").value = pos.coords.latitude.toFixed(4);
        $("dLon").value = pos.coords.longitude.toFixed(4);
        markActive($("dGeo"));
        const sel = $("dSelected");
        if (sel) sel.textContent = "Showing tours within range of your location.";
        run();
      }, () => { $("dStatus").textContent = "Couldn't get your location — pick a city above."; });
    });

    // Default to the first preset (New York) so the page loads with content
    // instead of an arbitrary raw-coordinate default.
    if (cityChips.length) pickCity(cityChips[0]);
    else run();
  }

  // Follow-the-tour — search an artist/team, set a date range + how many stops, tickets/show
  // and a TOTAL BUDGET; we plan the most stops that fit (cheapest seats per show) and show
  // what the next one would cost. Budget-first — no location needed (the optimizer plans on
  // ticket spend alone). Backed by /api/store/performers/{id}/tour-package. ?performer=&name=
  // pre-fills (e.g. arriving from Discover).
  function mountTourFollow() {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
    const money = (n) => "$" + Math.round(n).toLocaleString();
    const fmtD = (iso) => {
      try { return new Date(iso + "T00:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" }); }
      catch (_) { return iso; }
    };
    const u = new URLSearchParams(location.search);
    let performer = parseInt(u.get("performer"), 10);   // mutated by search selection
    let performerName = u.get("name") || "";
    let side = u.get("side") || "auto";   // teams: away (road trip) vs home (home stand)
    if (u.get("qty")) $("ftQty").value = u.get("qty");

    // Default the date range to the next 6 months (local-date ISO, no TZ shift).
    const isoDate = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const _today = new Date();
    const _plus6 = new Date(_today.getTime()); _plus6.setMonth(_plus6.getMonth() + 6);
    if (!$("ftStart").value) $("ftStart").value = isoDate(_today);
    if (!$("ftEnd").value) $("ftEnd").value = isoDate(_plus6);

    // ---- performer typeahead (artist or team) ----
    const box = $("ftPerformer"), sug = $("ftSuggest");
    if (performerName) box.value = performerName;
    let searchTimer = null;
    const hideSug = () => { sug.hidden = true; sug.innerHTML = ""; };
    async function search(q) {
      if (q.length < 2) { hideSug(); return; }
      try {
        const r = await api("/api/store/search?q=" + encodeURIComponent(q) + "&limit=8");
        const perfs = (r && r.performers) || [];
        if (!perfs.length) { hideSug(); return; }
        sug.innerHTML = perfs.map((p) =>
          `<div class="opt" role="option" data-id="${Number(p.id) || 0}" data-name="${esc(p.name)}">`
          + `${esc(p.name)}${p.location ? `<small>${esc(p.location)}</small>` : ""}</div>`).join("");
        sug.hidden = false;
      } catch (_) { hideSug(); }
    }
    box.addEventListener("input", () => {
      performer = NaN;            // typing invalidates the prior pick
      const q = box.value.trim();
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => search(q), 200);
    });
    sug.addEventListener("click", (e) => {
      const opt = e.target.closest(".opt");
      if (!opt) return;
      performer = parseInt(opt.dataset.id, 10);
      performerName = opt.dataset.name || "";
      box.value = performerName;
      side = "auto";              // re-detect concert vs team for the new pick
      hideSug();
      run();
    });
    document.addEventListener("click", (e) => {
      if (e.target !== box && !sug.contains(e.target)) hideSug();
    });

    function run() {
      if (!Number.isFinite(performer) || performer <= 0) {
        $("ftStatus").textContent = "Search and pick an artist or team to follow.";
        $("ftResult").hidden = true;
        return;
      }
      const p = new URLSearchParams({ qty: $("ftQty").value || "2", side: side });
      if ($("ftBudget").value) p.set("budget_usd", $("ftBudget").value);
      if ($("ftStops").value) p.set("max_events", $("ftStops").value);
      if ($("ftStart").value) p.set("start", $("ftStart").value);
      if ($("ftEnd").value) p.set("end", $("ftEnd").value);
      $("ftStatus").textContent = "Building your tour…";
      $("ftResult").hidden = true;
      api(`/api/store/performers/${performer}/tour-package?` + p.toString())
        .then(render)
        .catch((e) => { $("ftStatus").textContent = "Error: " + e.message; });
    }

    function render(d) {
      const pk = (d && d.package) || {};
      const qty = d.qty_per_show;
      const isTeam = String(d.mode || "").indexOf("team") === 0;
      const away = d.mode === "team_away";
      let name = performerName;
      if (!name) {
        if (isTeam) {
          const ev = (d.all_stops && d.all_stops[0]) || {};
          const parts = String(ev.event_name || "").split(" at ");   // "Away at Home"
          name = parts.length === 2 ? (away ? parts[0] : parts[1]) : (ev.performer || "this team");
        } else {
          name = (pk.legs && pk.legs[0] && pk.legs[0].performer)
            || (d.all_stops && d.all_stops[0] && d.all_stops[0].performer) || "this performer";
        }
      }
      $("ftTitle").textContent = isTeam
        ? `Follow ${name} ${away ? "on the road" : "at home"}`
        : `Follow ${name}'s tour`;
      // team -> show the away/home toggle, highlight current side
      const sideEl = $("ftSide");
      if (sideEl) {
        sideEl.hidden = !isTeam;
        sideEl.querySelectorAll(".ftside").forEach((b) => {
          b.classList.toggle("active", away ? b.dataset.side === "away" : b.dataset.side === "home");
        });
      }
      if (!d.stops_available || !pk.count) {
        $("ftStatus").textContent = isTeam
          ? `No ${away ? "away" : "home"} games in range — try the other side.`
          : "No routable tour right now — try a wider budget.";
        $("ftResult").hidden = true;
        return;
      }
      $("ftStatus").textContent = isTeam
        ? `${away ? "Away games · road trip" : "Home stand"} · ${d.stops_available} dates`
        : `${d.stops_available} tour dates available`;
      $("ftStat").innerHTML =
        `<div><span class="l">Total</span><b>${money(pk.fan_total_bundled)}</b></div>` +
        `<div><span class="l">Tickets</span><b>${pk.count * qty}</b></div>` +
        `<div><span class="l">Shows</span><b>${pk.count}</b></div>` +
        `<div><span class="l">Cities</span><b>${pk.cities}</b></div>`;
      $("ftHead").textContent = `Your shows — ${qty} ticket${qty === 1 ? "" : "s"} at each of ${pk.count}`;
      const picked = new Set((pk.legs || []).map((l) => l.event_id));
      $("ftLegs").innerHTML = (d.all_stops || []).map((l) => {
        const on = picked.has(l.event_id);
        const s = l.seats;
        const seat = s
          ? `<span class="seat">${esc(s.section || "GA")}${s.row ? " " + esc(s.row) : ""}${s.is_owned ? " · in stock" : ""}</span>`
          : (l.selection === "estimate" ? '<span class="seat">est. price</span>' : '<span class="seat">no group of that size</span>');
        const hot = l.hot ? '<span class="hot" title="high demand">🔥</span>' : "";
        const line = l.unit_price != null
          ? `<span class="line">${money(l.unit_price * qty)} <span class="ea">(${money(l.unit_price)} ea)</span></span>`
          : "";
        return `<li class="${on ? "" : "skip"}">`
          + `<span class="d">${fmtD(l.date)}</span>`
          + `<span class="c">${esc(l.city || "—")}${hot}</span>`
          + `<span>${esc(l.event_name || l.venue || "")}</span>`
          + seat + line + "</li>";
      }).join("");

      // "Add one more" — the cheapest stop we left out, so the fan sees exactly
      // what raising the budget (or stop count) by a little would buy them.
      const more = $("ftMore");
      const left = (d.all_stops || []).filter((l) => !picked.has(l.event_id) && l.unit_price != null);
      if (left.length) {
        const cheapest = left.reduce((a, b) => (b.unit_price < a.unit_price ? b : a));
        more.innerHTML = `Add one more stop: <b>${esc(cheapest.city || "another date")}</b> `
          + `${fmtD(cheapest.date)} for +${money(cheapest.unit_price * qty)}`
          + ` (${money(cheapest.unit_price)} ea × ${qty}).`;
        more.hidden = false;
      } else {
        more.hidden = true;
      }
      $("ftResult").hidden = false;
    }

    $("ftGo").addEventListener("click", run);
    box.addEventListener("keydown", (e) => { if (e.key === "Enter" && sug.hidden) run(); });
    const sideToggle = $("ftSide");
    if (sideToggle) sideToggle.addEventListener("click", (e) => {
      const b = e.target.closest(".ftside");
      if (!b) return;
      side = b.dataset.side;     // "away" | "home"
      run();
    });
    // Auto-run only when we arrived with a performer already chosen (e.g. from
    // Discover); otherwise wait for the user to search + pick one.
    if (Number.isFinite(performer) && performer > 0) run();
    else $("ftStatus").textContent = "Search and pick an artist or team to follow.";
  }

  // ---------- Performer landing page (programmatic SEO) ----------
  // Reuses the catalog card classes (.card/.card-head/.when/.name/.where/.meta)
  // so no new CSS is needed. Event shape comes from /api/store/performers/:id
  // (the _public RPCs): {id, name, when_local, venue_name, city, from_price}.
  function renderLandingCards(grid, events) {
    grid.replaceChildren();
    for (const ev of events) {
      const a = document.createElement("a");
      a.className = "card";
      a.href = `/store/event/${ev.id}`;

      const head = document.createElement("div");
      head.className = "card-head";
      const headText = document.createElement("div");
      const when = document.createElement("div");
      when.className = "when";
      when.textContent = fmtWhen(ev.when_local);
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = ev.name || "Untitled event";
      headText.append(when, name);
      head.append(headText);

      const where = document.createElement("div");
      where.className = "where";
      where.textContent = [ev.venue_name, ev.city].filter(Boolean).join(" · ");

      const meta = document.createElement("div");
      meta.className = "meta";
      const left = document.createElement("div");
      left.className = "from";
      const priceSpan = document.createElement("span");
      priceSpan.className = "price";
      priceSpan.textContent = fmtMoney(ev.from_price);
      if (ev.from_price != null) left.append("from ", priceSpan);
      else left.append(priceSpan);
      meta.append(left);

      a.append(head, where, meta);
      grid.append(a);
    }
  }

  // Shared driver for the performer + venue landing pages — identical layout,
  // only the URL pattern, API path, entity key, and subtitle differ.
  function _mountLanding(opts) {
    const grid = document.getElementById("grid");
    const status = document.getElementById("status");
    const head = document.getElementById("landingHead");
    const body = document.getElementById("landingBody");
    const empty = document.getElementById("empty");
    const heading = document.getElementById("gridHeading");
    const m = location.pathname.match(opts.pathRe);
    const id = m && m[1];
    if (!id || !grid) {
      if (status) status.textContent = `${opts.noun} not found.`;
      return;
    }
    (async () => {
      let data;
      try {
        data = await api(`${opts.apiBase}/${encodeURIComponent(id)}`);
      } catch {
        if (status) status.textContent = `Couldn't load this ${opts.noun.toLowerCase()}. Try again shortly.`;
        return;
      }
      const entity = data[opts.entityKey] || {};
      const name = entity.name || opts.noun;
      const nameEl = document.getElementById("landingName");
      const subEl = document.getElementById("landingSub");
      if (nameEl) nameEl.textContent = name;
      if (subEl) subEl.textContent = opts.subtitle(entity);
      document.title = `${name} tickets — VibePass`;
      if (status) status.hidden = true;
      if (head) head.hidden = false;
      if (body) body.hidden = false;
      const events = data.events || [];
      renderLandingCards(grid, events);
      if (heading) heading.hidden = events.length === 0;
      if (empty) empty.hidden = events.length !== 0;
    })();
  }

  function mountPerformer() {
    _mountLanding({
      pathRe: /\/store\/performer\/(\d+)/,
      apiBase: "/api/store/performers",
      entityKey: "performer",
      noun: "Performer",
      subtitle: (p) =>
        [p.category, p.home_venue_name && `home: ${p.home_venue_name}`].filter(Boolean).join(" · "),
    });
  }

  function mountVenue() {
    _mountLanding({
      pathRe: /\/store\/venue\/(\d+)/,
      apiBase: "/api/store/venues",
      entityKey: "venue",
      noun: "Venue",
      subtitle: (v) => v.city || "",
    });
  }

  // Auto-mount based on body data-page. Lets HTML pages drop their inline
  // `<script>Store.mountX()</script>` so we can ship a strict CSP without
  // 'unsafe-inline'. Added 2026-05-11 (security chat).
  function _autoMount() {
    const page = document.body && document.body.dataset && document.body.dataset.page;
    if (page === "catalog") mountCatalog();
    else if (page === "event") mountEvent();
    else if (page === "shares") mountSharesAdmin();
    else if (page === "discover") mountDiscover();
    else if (page === "tour") mountTourFollow();
    else if (page === "performer") mountPerformer();
    else if (page === "venue") mountVenue();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", _autoMount);
  } else {
    _autoMount();
  }

  // PWA: register the storefront service worker. Served at /store-sw.js (a root
  // path) so it can claim the '/store' scope. Progressive enhancement — any
  // failure (unsupported, blocked, offline) is silent and the site works as-is.
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => {
      navigator.serviceWorker
        .register("/store-sw.js", { scope: "/store" })
        .catch(() => {});
    });
  }

  // ---- Bot protection: reCAPTCHA v3 sitewide first-interaction gate ----
  // Dormant unless the server returns recaptcha_site_key (keys unset = no-op, so
  // the demo works without provisioning). When enabled: on the first user
  // gesture we fetch a v3 token and POST it to /api/store/verify-human, which
  // sets a short-lived signed cookie the write endpoints require — so the gate
  // runs once per session, not per action. StoreBot.token(action) yields a fresh
  // token for the reserve fallback. All failures are silent (write endpoints
  // re-challenge as needed).
  const StoreBot = (function () {
    let siteKey = null;
    let gated = false;

    function loadScript(key) {
      return new Promise((resolve, reject) => {
        if (window.grecaptcha && window.grecaptcha.execute) return resolve();
        const s = document.createElement("script");
        s.src = "https://www.google.com/recaptcha/api.js?render=" + encodeURIComponent(key);
        s.async = true;
        s.defer = true;
        s.onload = () => resolve();
        s.onerror = () => reject(new Error("recaptcha load failed"));
        document.head.appendChild(s);
      });
    }

    async function token(action) {
      if (!siteKey || !window.grecaptcha || !window.grecaptcha.execute) return null;
      try {
        await new Promise((res) => window.grecaptcha.ready(res));
        return await window.grecaptcha.execute(siteKey, { action: action || "submit" });
      } catch { return null; }
    }

    async function gateOnce() {
      if (gated) return;
      gated = true;
      const t = await token("gate");
      if (!t) return;
      try {
        await api("/api/store/verify-human", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ recaptcha_token: t }),
        });
      } catch { /* gate failed — write endpoints will re-challenge */ }
    }

    async function init() {
      let cfg = null;
      try { cfg = await api("/api/public/config"); } catch { return; }
      if (!cfg || !cfg.recaptcha_enabled || !cfg.recaptcha_site_key) return;
      siteKey = cfg.recaptcha_site_key;
      try { await loadScript(siteKey); } catch { return; }
      const events = ["pointerdown", "keydown", "touchstart"];
      const fire = () => {
        events.forEach((e) => window.removeEventListener(e, fire, true));
        gateOnce();
      };
      events.forEach((e) => window.addEventListener(e, fire, true));
    }

    return { init, token };
  })();
  window.StoreBot = StoreBot;
  StoreBot.init();
})();
