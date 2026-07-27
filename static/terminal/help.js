// D0 Terminal — HELP page. Static, in-app user guide + glossary. No data fetch:
// the content mirrors docs/d0_onboarding_guide.md (Parts 2–4) so operators have
// the guide one click away from every page. The "Replay the tour" button is the
// hook the future onboarding tour (built by Claude design per Part 1 of that
// doc) attaches to; until then it degrades to a friendly pointer at this page.

(function () {
  'use strict';

  const T = window.Terminal;
  const esc = (window.TermRender && window.TermRender.escapeHtml)
    ? window.TermRender.escapeHtml
    : (s) => String(s == null ? '' : s);

  // ---- content model (single source; edit here, mirrors the guide doc) ----

  const STEPS = [
    ['Sign in', 'One button — <em>Continue with Google</em>, restricted to <code>@s4kent.com</code>. After sign-in you bounce back to where you started; your session persists in this browser until you sign out (top-right).'],
    ['Meet HOME', 'Your morning mark-to-market desk: a live news wire, <strong>My Watchlist</strong> (empty until you fill it), coverage counts, the "market selling, we’re not in" board, the <strong>Movers</strong> index, and S4K-owned events for the next 30 days.'],
    ['Search anything', 'Press <kbd>/</kbd> anywhere to jump to the top search box. Type a team, player, event, performer, or venue. Results group into Players → team → their next games, plus Events, Performers, Venues, Racing, Fantasy and Marketplace. ↑/↓ to move, Enter to open.'],
    ['Open an EVENT', 'The single-event deep-dive: a KPI grid (owned %, retail median, get-in, qty owned/available), the cross-source listings table, the price + inventory chart, and per-marketplace tabs (SG / EVO / SH / GT / VD / TM, Seat Map, Sales, Our Orders).'],
    ['Track it', 'Hit <strong>☆ Track</strong> in the event header — it becomes <strong>★ Tracking</strong> and the event now shows on <strong>My Watchlist</strong> on HOME. That’s the core loop: curate the events you care about and HOME becomes <em>your</em> board.'],
    ['Come back to HELP', 'This tab holds the whole guide plus this walkthrough, any time you’re lost.'],
  ];

  const GLOBAL = [
    ['Top-nav', 'Brand tag, the tab row (current tab highlighted), the global search box, a <code>v:…</code> version chip (which deploy you’re on), your email, and <em>sign out</em>.'],
    ['Global search', 'One box on every page. Searches players (athlete → team → upcoming games), events, performers, venues, racing drivers, fantasy leagues, and marketplace events we don’t track yet. <kbd>/</kbd> focuses it from anywhere; ↑/↓ to move, Enter to open, Esc to close.'],
    ['Sign-in', 'Google OAuth, <code>@s4kent.com</code> only. Non-domain accounts are bounced.'],
  ];

  const CLUSTERS = [
    {
      title: '1 · Look something up — "what’s this worth?"',
      rows: [
        ['HOME', 'Your daily desk: news wire, My Watchlist, coverage counts, the Top-50 "market selling, we’re not in" board, the cross-source Movers index, and S4K-owned events for the next 30 days.'],
        ['EVENT', 'The single-event deep-dive — KPI grid, cross-source price/inventory/sales table, composite chart, per-marketplace tabs, and the ☆ Track button. Answers: is our inventory priced right vs. every marketplace, and which way is it trending?'],
        ['VENUE', 'A venue as its own ticker — aggregate demand + owned exposure, upcoming events, Sections, Market Carpet, and Competing Events (tune radius + window to find events fighting for the same buyers).'],
        ['PERFORMER', 'A team/act as a tradeable name — portfolio rollup, demand trend, prediction markets, Blind Spots (their events with depth but zero owned), a Trip Planner, and a Compare basket.'],
        ['PLAYER', 'Reached from a Roster tab or search (not a top tab): one athlete tied to ticket impact — next-team/transfer market, a name-scoped live feed, season stats, and game log.'],
      ],
    },
    {
      title: '2 · Follow the sports',
      rows: [
        ['LEAGUES', 'One hub across every ESPN-tracked league (and racing series): per-team demand leaderboard + standings, game slate, season-ticket-value leaderboard, and per-team blind spots.'],
        ['TRANSACTIONS', 'The league transaction wire — trades, signings, roster moves that move ticket prices. Filter by league, move type, or search.'],
        ['TRADE WATCH', 'Be first to know when a watchlisted player moves — fuses prediction markets + a high-frequency Wikipedia poll + the ESPN roster into one MOVED / WATCHING state per player.'],
        ['CAST WATCH', 'The Broadway twin of Trade Watch — each show’s cast section is watched daily; CHANGED flags a cast change (the theatre analog of a trade).'],
      ],
    },
    {
      title: '3 · Find what’s moving / what to chase',
      rows: [
        ['MOVERS', 'The big-board of market movers — filter by source, horizon (7d–365d), and category (Price ↑/↓, Selling Fast, Accumulating, Value Gap, Cross Gap). Includes a Blind Spots panel.'],
        ['DISCOVERY', 'Where the broker pool is active but we own zero, plus performers/venues returning from dormancy. Companion to Movers (excludes the Big-5 leagues Movers already covers).'],
        ['SALES', 'Realized-sales analytics — what actually sold, by league, team, and performer. Ground-truth demand from closed sales, not just listings.'],
      ],
    },
    {
      title: '4 · Primary-market coverage',
      rows: [
        ['AXS', 'Every event in the AXS primary box-office registry with its latest get-in / price band / listing depth, plus AXS-only artists EVO doesn’t carry.'],
        ['EVENTBRITE', 'Organizer events discovered on Eventbrite with face price band + sold-out / on-sale status.'],
      ],
    },
    {
      title: '5 · Do the desk’s math',
      rows: [
        ['SUBS', 'Substitution checker — cover a sold/double-sold ticket with the cheapest acceptable seat from our inventory. Paste an order # or enter event/section/row/qty manually.'],
        ['SEASON TIX', 'Is a season-ticket package worth buying vs. assembling comparable seats game-by-game? A league leaderboard → per-seat verdict at get-in and VWAP baselines.'],
        ['RETAIL CHAT', 'Ask about prices and availability in plain English across the full market — conversational lookups without writing a query.'],
        ['NOTEBOOK', 'A research notebook — collect sources (text/URL/PDF), ask questions over them, chat, transform, and generate podcasts.'],
      ],
    },
    {
      title: '6 · Operate the book',
      rows: [
        ['ORDERS', 'The unified order book across EVO / SeatGeek / TickPick / Vivid (read-only). Filter by source/state/date; per-source freshness chips show count + last-seen age.'],
        ['HEALTH', 'System status for the whole pipeline — is the data you’re trading on current, and is anything down?'],
      ],
    },
  ];

  const GLOSSARY = [
    ['Owned / S4K-owned', 'Inventory the desk holds. "Owned share," "qty owned," "owned premium %" measure our position vs. the wider market.'],
    ['Get-in', 'The cheapest ticket available — the price to "get in the door."'],
    ['Retail median', 'The middle listing price across the market for an event or zone.'],
    ['VWAP', 'Volume-weighted average price — average sale price weighted by quantity sold; a truer "what it trades at" than a raw median.'],
    ['Face / primary', 'The primary-market (box-office) price — AXS / Ticketmaster / Eventbrite — vs. resale.'],
    ['Blind spot', 'An event/performer where the market is active but we own zero — an opportunity we’re not capturing.'],
    ['Movers', 'Events whose price or inventory moved meaningfully over a window — ranked and categorized.'],
    ['Cross-source', 'Data stitched across marketplaces — EVO, SG (SeatGeek), SH (StubHub), GT (GameTime), VD (VividSeats), TM (Ticketmaster), TP (TickPick).'],
    ['Value gap', 'The market’s price sits meaningfully above comparable inventory — a mispricing worth chasing.'],
    ['Coverage', 'How many active future events we’re tracking (and how soon they occur).'],
    ['Track / Watchlist', 'Your personal list — the ☆ Track button on an event adds it to My Watchlist on HOME.'],
    ['Freshness / stale', 'How recently a data feed last updated. Freshness chips (count + last-seen age) tell you whether what you’re looking at is current.'],
  ];

  // ---- render ----

  function rowsTable(rows, termHeader, descHeader) {
    const body = rows.map(([a, b]) =>
      `<tr><td class="term">${esc(a)}</td><td>${b}</td></tr>`).join('');
    return `<table class="help-grid"><thead><tr>
        <th>${esc(termHeader)}</th><th>${esc(descHeader)}</th>
      </tr></thead><tbody>${body}</tbody></table>`;
  }

  function render() {
    const parts = [];

    // First 5 minutes
    parts.push('<section id="help-start">');
    parts.push('<div class="panel-title">THE FIRST 5 MINUTES</div>');
    parts.push('<ol class="help-steps">');
    STEPS.forEach(([h, d]) => parts.push(`<li><strong>${esc(h)}.</strong> ${d}</li>`));
    parts.push('</ol></section>');

    // Global chrome
    parts.push('<section id="help-global">');
    parts.push('<div class="panel-title">SEARCH &amp; SIGN-IN (every page)</div>');
    parts.push(rowsTable(GLOBAL, 'Feature', 'What it does'));
    parts.push('</section>');

    // Feature tour
    parts.push('<section id="help-tour">');
    parts.push('<div class="panel-title">FEATURE TOUR</div>');
    parts.push('<p class="muted small" style="margin:4px 0 14px">' +
      'The ~20 tabs cluster into six jobs. Find the cluster that matches what you’re doing — you rarely need all of them at once.</p>');
    CLUSTERS.forEach(c => {
      parts.push(`<div class="help-cluster-lbl">${esc(c.title)}</div>`);
      parts.push(rowsTable(c.rows, 'Tab', 'What you use it for'));
      parts.push('<div style="height:14px"></div>');
    });
    parts.push('</section>');

    // Glossary
    parts.push('<section id="help-glossary">');
    parts.push('<div class="panel-title">GLOSSARY</div>');
    parts.push('<p class="muted small" style="margin:4px 0 12px">' +
      'The vocabulary trips people up before the features do. Decode these first.</p>');
    parts.push(rowsTable(GLOSSARY, 'Term', 'What it means here'));
    parts.push('</section>');

    document.getElementById('helpBody').innerHTML = parts.join('');
    if (T && T.setStatus) T.setStatus('Ready');
  }

  // "Replay the tour" — attaches to the future guided-tour hook if present,
  // otherwise degrades gracefully (this page IS the fallback the tour points at).
  function wireReplay() {
    const btn = document.getElementById('replayTourBtn');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const tour = window.TerminalTour;
      if (tour && typeof tour.start === 'function') {
        tour.start({ replay: true });
        return;
      }
      // No tour engine yet — flag a replay request for HOME to honor once the
      // onboarding overlay ships, and surface an honest inline note meanwhile.
      try { localStorage.setItem('terminalReplayTour', '1'); } catch (_) { /* private mode */ }
      if (T && T.setStatus) T.setStatus('Guided tour coming soon — this page is your full guide.', 'warn');
      const start = document.getElementById('help-start');
      if (start && start.scrollIntoView) start.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  function boot() { render(); wireReplay(); }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
