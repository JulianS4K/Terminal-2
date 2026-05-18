/* VibePass storefront — MVP, browse only.
 * Talks to /api/store/* exclusively. No real purchases — Reserve is a
 * validation-only endpoint that returns a mock receipt. */
(function () {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

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
    const r = await fetch(path, init);
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
    const empty = $("#empty");

    let allEvents = [];
    // loadComplete gates filter() so the user can't trigger a misleading
    // "No events match" empty state by typing in the search box while the
    // initial /api/store/home call is still in flight (common on free-tier
    // cold-start where the round-trip is ~12s). When load resolves below,
    // any pending user query is re-applied at that point.
    let loadComplete = false;

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
      if (!loadComplete) return;  // same cold-start gate as filter()
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
            from_price: e.from_price != null ? Number(e.from_price) : null,
            owned_tickets_count: e.owned_tix != null ? Number(e.owned_tix) :
                                 (e.owned_tickets_count != null ? Number(e.owned_tickets_count) : null),
            owned_groups_count: e.owned_groups_count != null ? Number(e.owned_groups_count) : null,
            rivalry: e.rivalry || null,
            mlb_series: e.mlb_series || null,
            tournament: e.tournament || null,
            holiday: e.holiday || null,
          }));
          // Client-side speculative filter — mirrors PR #175's server-side
          // logic. Drops CANCELLED + (If Necessary). Kept here in addition
          // to the server filter so the fix works even if the older server
          // build hasn't redeployed yet.
          const cleaned = normalized.filter((e) => {
            const up = (e.name || "").toUpperCase();
            return !up.includes("CANCELLED") && !up.includes("(IF NECESSARY)");
          });
          render(cleaned, "search");
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
      status.textContent = "Loading available events…";
      status.style.color = "";
      status.hidden = false;
      // Reset gate — Retry re-fires this and we want the same race
      // protection on the second attempt.
      loadComplete = false;
      api(catalogEndpoint)
        .then((res) => {
          allEvents = res.events || [];
          loadComplete = true;
          renderCatalogFilterBanner(performerId, venueId, allEvents);
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
          status.replaceChildren();
          status.style.color = "var(--bad)";
          status.hidden = false;
          const msg = document.createElement("div");
          msg.textContent = `Couldn't load events: ${(err && err.message ? String(err.message) : "Unknown error").slice(0, 120)}`;
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

    // NYC movers strip — only shown on the bare /store view (no performer
    // or venue filter). Velocity-driven, sorted by 24h ticket drop.
    if (!performerId && !venueId) {
      const strip = $("#moversStrip");
      const row = $("#moversRow");
      if (strip && row) {
        api("/api/store/movers?city=NYC&days=21&limit=8")
          .then((res) => renderMoversStrip(strip, row, res))
          .catch(() => { strip.hidden = true; });
      }
    }

    // ----- Live search suggestions dropdown -----
    // Debounced /api/store/search call as the user types. 300ms debounce
    // + 2-char minimum keeps upstream load reasonable (TEvo doesn't cache
    // suggestions — see notes in evo_client.search_suggestions). Server
    // also caches per-q for 60s.
    const suggestEl = $("#searchSuggest");
    let suggestTimer = null;
    let suggestSeq = 0;  // monotonic so stale responses don't overwrite

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

  // Render suggestion dropdown body. Three sections:
  //   Events you can buy now (we_own=true) — top priority, shown first
  //   Other events (we_own=false) — surfaced but flagged as "browse"
  //   Performers + venues — bottom, clickable filter pivots
  function renderSuggest(host, payload) {
    if (!host) return;
    host.replaceChildren();
    const events = (payload && payload.events) || [];
    const performers = (payload && payload.performers) || [];
    const venues = (payload && payload.venues) || [];

    if (!events.length && !performers.length && !venues.length) {
      host.hidden = true;
      return;
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

  // Render the "Moving fast in NYC" strip — horizontal card row above
  // the main grid. Each card carries at most one velocity badge from
  // the locked-down trio: 🔥 selling fast, 📈 demand rising, ⭐ premium.
  function renderMoversStrip(strip, row, payload) {
    const items = (payload && payload.events) || [];
    row.replaceChildren();
    if (!items.length) { strip.hidden = true; return; }
    strip.hidden = false;
    for (const ev of items) {
      const a = document.createElement("a");
      a.className = "mover-card";
      a.href = `/store/event/${Number(ev.id) || 0}`;
      if (ev.primary_performer_color) {
        a.style.setProperty("--card-accent", ev.primary_performer_color);
      }
      // Velocity badge: 'selling_fast' | 'demand_rising' | 'premium' | null
      if (ev.signal) {
        const badge = document.createElement("span");
        badge.className = `mover-badge ${ev.signal}`;
        badge.textContent = ({
          selling_fast: "🔥 selling fast",
          demand_rising: "📈 demand rising",
          premium: "⭐ premium",
        })[ev.signal] || "";
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
      if (ev.tix_d24h != null && Number(ev.tix_d24h) < 0) {
        const note = document.createElement("span");
        note.className = "mover-note";
        note.textContent = `${Math.abs(Number(ev.tix_d24h))} sold today`;
        meta.append(note);
      }
      a.append(meta);
      row.append(a);
    }
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
      // Same trick for split-quantities. Rebuild the min-qty dropdown to
      // match what's actually offered.
      if (Array.isArray(res.splits_available)) {
        splitsAvailable = res.splits_available.slice();
        rebuildMinQtyOptions(splitsAvailable, readFiltersFromUI().min_qty);
      }
      const filters = res.filters || readFiltersFromUI();

      $("#evName").textContent = event.name || "Untitled event";

      // Update SEO/share-card metadata from the resolved event payload.
      // Crawlers that DO run JS (Googlebot, modern social previewers) pick
      // up these mutations; static fallback values in <head> cover the
      // no-JS / static-snapshot path.
      updateEventMeta(event);

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
      const map = event.configuration?.seating_chart_medium || event.configuration?.seating_chart_large;
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
