# D0 Terminal — Onboarding Guide & Design Brief

> **Doc version:** v1.0.0 (2026-07-16)
> **Audience of this doc:** (1) **Claude design** — as the brief for building the first-run onboarding + guided-tour experience; (2) the terminal's in-app **HELP** tab (`static/terminal/help.html`), which renders a condensed version of Parts 2–4 below for end users.
> **Who the terminal is for:** the S4K broker desk — signed-in `@s4kent.com` operators who buy, price, and sell event tickets. This guide describes the app **from the user's chair**, not the implementation. Build/architecture facts live in `docs/d0_terminal_build.md`; cross-source data model in `PROJECT_BIBLE.md §5`.

This document has four parts:

1. **The design brief** — what onboarding to build, and how it should feel. *(For Claude design.)*
2. **The five-minute first run** — the exact happy path a brand-new operator should be walked through.
3. **The feature tour** — every tab, grouped, in plain English. *(Also the body of the HELP tab.)*
4. **The glossary** — the terminal's vocabulary, decoded.

---

# PART 1 — DESIGN BRIEF (for Claude design)

## 1.1 The problem we're solving

The terminal is **dense**. A first-time operator lands on a black dashboard with a news wire, a watchlist, a "market we're not in" board, a movers index, and ~20 more tabs across the top — with zero explanation. Everything is jargon-forward (get-in, VWAP, blind spots, cross-source, owned share). Power users love the density; **newcomers bounce or misuse it** (e.g. they never discover the `/` search, never Track an event, never learn that HOME's watchlist is *theirs* to fill).

There is **no onboarding today** — no welcome, no tour, no tooltips, no empty-state guidance, no help. This brief asks Claude design to build that layer **without touching the density power users rely on**.

## 1.2 What to build (scope)

Build a **progressive, skippable onboarding layer** on top of the existing terminal. Five pieces, in priority order:

| # | Piece | What it is | Priority |
|---|---|---|---|
| 1 | **Welcome modal** | First-login-only. 4–6 slides: "what the terminal is," the three things you'll do most (Search anything · Track events · Read Movers), and a "Take the 60-second tour / Skip" fork. | P0 |
| 2 | **Guided tour** | An anchored, step-through spotlight (coach-marks) over the *real* HOME + top-nav — search box, `/` shortcut, a Track button, the Movers panel, the HELP tab. ~6–8 stops, arrow-key + click through, dismissible at any step. | P0 |
| 3 | **Empty states** | Every panel that can be empty for a new user (My Watchlist, S4K-owned events, saved notebooks, alerts) gets a friendly first-run message + a one-click "do the thing" CTA instead of a blank "loading…"/"no rows." | P0 |
| 4 | **Contextual tips** | Small, dismissible "?" affordances on the genuinely non-obvious controls (the Movers SOURCE/SEGMENT toggles, Subs pool fee %, Season-Tix row band, the cross-source table). Tip copy is seeded from Part 4's glossary. | P1 |
| 5 | **HELP tab** *(already scaffolded in this PR)* | A permanent nav tab that renders Part 3 (the feature tour) + Part 4 (glossary) + a "Replay the tour" button + a link to this doc. This is the always-available fallback the modal and tour both point at. | P0 (shell shipped here) |

**Out of scope:** any change to the trading data, RPCs, or existing panel behavior. Onboarding is an *additive overlay*. Do not re-flow existing dashboards.

## 1.3 How it should feel

- **Skippable and rare.** Show the welcome modal once (persist a `terminalOnboardedAt` flag in `localStorage`, keyed per user email). Never nag. "Skip" is always one click, always honored.
- **On the real UI, not a fake screenshot.** The tour spotlights live elements so muscle memory transfers. If an element isn't present on the current page, the step advances or deep-links.
- **Terse and confident, matching the desk's voice.** Trading-desk register: short, lowercase-friendly, no exclamation-mark cheerleading. Mirror the existing copy tone (e.g. panel titles are ALL-CAPS terse: `MOVERS · CROSS-SOURCE INDEX`, `TOP 50 — MARKET SELLING, WE'RE NOT IN`).
- **Dark-native.** The terminal is a dark, high-density Bloomberg-style surface. Use the existing design tokens (`static/_shared/design-tokens.css`) and terminal classes (`.panel-title`, `.ctrl-btn`, `.badge`, `.muted`, `.small`) — do **not** introduce a light-theme modal or off-brand accent.
- **Keyboard-first.** The app already leans on `/` to search and arrow-keys in search. The tour should honor arrow-key/Enter/Esc navigation to stay consistent.
- **Accessible.** Coach-marks need focus management, `aria-live` step announcements, Esc-to-exit, and visible focus rings. Don't trap keyboard users.

## 1.4 Visual & interaction guidance

- **Modal / coach-mark chrome:** reuse the terminal's card styling (rounded, hairline border, near-black panel fill from the tokens). One accent color from the tokens for the "current step" highlight ring.
- **Spotlight:** dim the rest of the page (~60% scrim), cut out the anchored element, float a small caption card near it with `Step n / N`, `Back`, `Next`, `Skip tour`.
- **Progress:** the welcome modal shows slide dots; the tour shows `n / N`.
- **Don't block data loading.** The tour runs over a HOME that's fetching live data; anchor to stable containers (panel titles, nav links), not to rows that may not have arrived.

## 1.5 Success criteria

A new operator, in their first session, should end up having: (a) run one global search, (b) opened one EVENT page, (c) Tracked one event (so their HOME watchlist is non-empty next login), and (d) knowing the HELP tab exists. The onboarding is "done" when those four are reachable in under two minutes and skippable in one click.

## 1.6 Where things live (for the build)

- Terminal frontend: `static/terminal/*` — vanilla JS, no build step, no framework. Each HTML page sets `data-page` on `<body>` and loads the shared chain `lib/supabase.js → auth.js → app.js → nav.js → <page>.js`.
- Nav/search/version chip/auth control: `static/terminal/nav.js` (the tour's anchors for search + the HELP link live here).
- Auth gate (Google OAuth, `@s4kent.com` only): `static/terminal/auth.js`.
- Shared styling + design tokens: `static/terminal/style.css` + `static/_shared/design-tokens.css`.
- The Track (watchlist) button pattern: `static/terminal/event.js` (`wireTrackButton`, the `☆ Track` / `★ Tracking` toggle).
- HELP tab (shipped in this PR): `static/terminal/help.html` + `help.js`, registered in `nav.js`.

Onboarding state should persist in `localStorage` per signed-in email (available via `window.TerminalAuth.getEmail()`).

---

# PART 2 — THE FIVE-MINUTE FIRST RUN

The happy path every new operator should be guided through. This is the script the welcome modal + tour should follow.

1. **Sign in.** One button — *Continue with Google* — restricted to `@s4kent.com`. After sign-in you bounce back to where you started; your session persists in this browser until you sign out (top-right of the nav).
2. **Meet HOME.** This is your morning mark-to-market desk: a live **News Wire**, **My Watchlist** (empty at first — you fill it), a **Coverage** count, **"Top 50 — market selling, we're not in"**, the **Movers** index, and **S4K-owned events, next 30 days**.
3. **Search for anything.** Press **`/`** anywhere to jump to the top search box. Type a team, player, event, performer, or venue. Results group into Players → team → their next games, plus Events, Performers, Venues, Racing, Fantasy, and Marketplace. Arrow-keys move, Enter opens.
4. **Open an EVENT and read it.** From search or a panel, open one event. This is the deep-dive: the KPI grid (owned %, retail median, get-in, qty owned/available), the cross-source listings table, the price+inventory chart, and per-marketplace tabs (SG / EVO / SH / GT / VD / TM, Seat Map, Sales, Our Orders).
5. **Track it.** Hit the **☆ Track** button in the event header. It turns into **★ Tracking** and the event now shows up in **My Watchlist** on HOME. That's the core loop — curate the events you care about, and HOME becomes *your* board.
6. **Know where HELP is.** The **HELP** tab (top nav) has this whole guide plus a "replay the tour" button, any time you're lost.

Everything past step 6 is depth you pull in as you need it — see the feature tour below.

---

# PART 3 — THE FEATURE TOUR (also the HELP tab body)

The terminal has ~20 tabs. They cluster into six jobs. You rarely need all of them at once — find the cluster that matches what you're doing.

## Global chrome (every page)

- **Top-nav** — brand tag, the tab row (current tab highlighted), the global search box, a `v:…` version chip (which deploy you're on), your email, and *sign out*.
- **Global search** — one box, every page. Searches **players** (athlete → their team → the team's upcoming games), **events**, **performers**, **venues**, **racing** drivers, **fantasy** leagues, and **marketplace** events we don't track yet. Type-to-search; **`/`** focuses it from anywhere; ↑/↓ to move, Enter to open, Esc to close. *(Requires being signed in.)*
- **Sign-in** — Google, `@s4kent.com` only. Non-domain accounts are bounced.

## Cluster 1 — Look something up ("what's this worth?")

| Tab | What you use it for |
|---|---|
| **HOME** | Your daily desk. News wire (filter by source/league/window), **My Watchlist**, coverage counts, **Top 50 events the market is selling that we hold zero position in**, the cross-source **Movers** index, and **S4K-owned events, next 30 days**. |
| **EVENT** | The single-event deep-dive. Header (title/venue/date/weather + **☆ Track**), a KPI grid (owned premium %, retail median, qty available/owned, get-in, face), and tabs: Overview · Seat Map · per-marketplace Listings (SG/EVO/SH/GT/VD/TM) · SG & SeatData Sales · AXS Box Office · TD Markets · Predictions · Watchlist & Alerts · Our Orders. Overview carries the cross-source price/inventory/sales table and the composite price+inventory chart (6h → ALL). **The decision: is our inventory priced right vs. every marketplace, and which way is this trending?** |
| **VENUE** | A venue as its own "ticker." Index (venue directory) → detail with Overview, Upcoming, Owned Inventory, SG Activity, **Competing Events** (pick an anchor event, tune radius 10/50/100mi + window to find events cannibalizing the same buyers), Sections, **Market Carpet**, Alerts. |
| **PERFORMER** | A team/act as a tradeable name. Index gallery of stat-cards (search, sort, "sports only," a **Compare basket**) → detail with Overview (portfolio + statistics + prediction markets), Upcoming (incl. a **Trip Planner** and retail tour pricer), **Blind Spots** (their events with market depth but zero owned), Cast/Injuries/Futures/Roster/Alerts. |
| **PLAYER** *(via Roster tab or search — not a top tab)* | One athlete tied to ticket impact: hero (team/pos/status), a **next-team/transfer market** (Kalshi odds), a name-scoped live feed (ESPN + Reddit + X + transactions), season stats, game log. |

## Cluster 2 — Follow the sports

| Tab | What you use it for |
|---|---|
| **LEAGUES** | One hub across every ESPN-tracked league (and racing series). Per-team demand leaderboard + standings, game slate (event-linked), season-ticket-value leaderboard, and per-team blind spots. Pick a racing series (F1/NASCAR) to swap in a schedule + driver standings + results drawer. *(RACING is now folded in here — old racing links redirect.)* |
| **TRANSACTIONS** | The league transaction wire — trades, signings, roster moves that can move ticket prices. Filter by league, move type, or search team/player. |
| **TRADE WATCH** | "Be first to know when a watchlisted player moves." Fuses prediction markets (Kalshi/Polymarket) + a high-frequency Wikipedia poll + the ESPN roster into one **MOVED / WATCHING** state per player. Add players with the "＋ add player" box. |
| **CAST WATCH** | The Broadway twin of Trade Watch — each show's Wikipedia cast section is watched daily; **CHANGED** flags a cast change (the theatre analog of a trade). |

## Cluster 3 — Find what's moving / what to chase

| Tab | What you use it for |
|---|---|
| **MOVERS** | The big-board of market movers. Filter by SOURCE (Merged/EVO/SG/SH/GT/VD), HORIZON (7d–365d), and CATEGORY (Price ↑/↓, Selling Fast, Accumulating, Value Gap, Cross Gap). Includes a **Blind Spots** panel. |
| **DISCOVERY** | Where the broker pool is active but we own **zero**, plus performers/venues returning from dormancy. Panels: Discovery Gaps (by type), TEvo Blind Spots, "SG selling, we're not in," Returning entities. *(Companion to Movers; excludes the Big-5 leagues Movers already covers.)* |
| **SALES** | Realized-sales analytics — what actually sold, by league, team, and performer. Away-team leaderboard + performer sales report. **Ground-truth demand from closed sales, not just listings.** |

## Cluster 4 — Primary-market coverage

| Tab | What you use it for |
|---|---|
| **AXS** | Every event in the AXS primary box-office registry with its latest get-in / price band / listing depth (primary vs resale). Filter by active/holdings; a second section rolls up **AXS-only artists EVO doesn't carry.** |
| **EVENTBRITE** | Organizer events discovered on Eventbrite with face price band + sold-out/on-sale status. Discovery-level view of organizer inventory. |

## Cluster 5 — Do the desk's math

| Tab | What you use it for |
|---|---|
| **SUBS** | Substitution checker. Cover a sold/double-sold ticket with the cheapest acceptable seat from our own inventory (same section, same-or-better row first; then a better-section fallback). Paste an order # to auto-fill, or enter event/section/row/qty manually and pick a pool (owned free-swap vs market buy-in with a fee %). |
| **SEASON TIX** | Is a season-ticket package worth buying vs assembling comparable seats game-by-game? Major pro leagues. A league leaderboard → per-seat breakdown with a verdict and green/red Δ columns at get-in and VWAP baselines. |
| **RETAIL CHAT** | Ask about prices and availability in plain English across the full market. Conversational lookups without writing a query. |
| **NOTEBOOK** | A research notebook — collect sources (text/URL/PDF), ask questions over them (RAG), chat, transform, generate podcasts. Sidebar of notebooks + Sources/Notes/Ask/Chat/Podcasts tabs. |

## Cluster 6 — Operate the book

| Tab | What you use it for |
|---|---|
| **ORDERS** | The unified order book across EVO / SeatGeek / TickPick / Vivid (read-only). Filter by source/state/date, search events, per-source freshness chips (count + last-seen age). |
| **HEALTH** | System status for the whole pipeline — overall banner, web-service reachability, a 24h timeline, individual checks, cron-job health. **"Is the data I'm trading on current, and is anything down?"** |

---

# PART 4 — GLOSSARY (the terminal's vocabulary)

New operators trip on the jargon before the features. Decode these first; the contextual tips (Part 1.2 #4) should draw their copy from here.

| Term | What it means on the terminal |
|---|---|
| **Owned / S4K-owned** | Inventory the desk holds. "Owned share," "qty owned," "owned premium %" all measure our position vs the wider market. |
| **Get-in** | The cheapest ticket available for an event/section — the price to "get in the door." |
| **Retail median / median** | The middle listing price across the market for an event or zone. |
| **VWAP** | Volume-weighted average price — the average sale price weighted by how many sold; a truer "what it actually trades at" than a raw median. |
| **Face / primary** | The primary-market (box-office) price, e.g. AXS/Ticketmaster/Eventbrite — vs. resale. |
| **Blind spot** | An event/performer where the market is active (there's demand and listings) but **we own zero** — an opportunity we're not capturing. |
| **Movers** | Events whose price or inventory moved meaningfully over a window — ranked and categorized (Price ↑/↓, Selling Fast, Accumulating, Value Gap, Cross Gap). |
| **Cross-source / cross-platform** | Data stitched across marketplaces — **EVO** (Ticket Evolution), **SG** (SeatGeek), **SH** (StubHub), **GT** (GameTime), **VD** (VividSeats), **TM** (Ticketmaster), **TP** (TickPick). The event page compares all of them side by side. |
| **Value gap** | The market's price is meaningfully above where comparable inventory sits — a mispricing worth chasing. |
| **Fill-rate spike** | A sudden jump in how fast an event's inventory is selling through. |
| **Coverage** | How many active future events we're tracking (and how soon they occur). |
| **Track / Watchlist** | Your personal list. The **☆ Track** button on an event adds it to **My Watchlist** on HOME. |
| **Substitution (Subs)** | Covering a sold seat you can no longer fill from the original tickets, with the cheapest acceptable alternative from our inventory. |
| **Trip Planner** | On a performer's Upcoming tab: optimize a multi-city tour run given your home location, travel-km budget, tickets/show, and $ budget. |
| **Market Carpet** | A dense heat-grid visualization (on venue/performer pages) of demand/price across events. |
| **TD Markets** | Data sourced via TicketsData across secondary platforms. |
| **Predictions / Futures** | Prediction-market odds (Kalshi/Polymarket) and season/championship futures shown as demand signals. |
| **Freshness / stale** | How recently a data feed last updated. Freshness chips (count + last-seen age) tell you whether what you're looking at is current. |

---

## Handoff notes for Claude design

- **Reuse, don't rebuild:** the terminal already has a coherent dark design system in `static/_shared/design-tokens.css` + `static/terminal/style.css`. Pull the modal/coach-mark palette, radii, and type from there.
- **The HELP tab in this PR is intentionally simple** (static content + a "replay tour" hook that's a no-op until the tour ships). Treat it as the destination the tour and modal point at; enrich it as the tour lands.
- **Persist onboarding state per user**, not per browser-global, so a shared machine doesn't hide onboarding from a second operator.
- **Test the skip path first.** A power user opening the terminal must be able to dismiss everything in one action and never see it again.
- When you build the tour, anchor to these stable hooks: the nav search box (`.term-search-input`), a nav tab link (`nav.pagenav a[data-nav="help"]`), the HOME Movers panel title, and an EVENT page `#trackBtn`.
