# Retail UI Kit

**Owners:** claude design (UI), copilot (backend RPCs already shipped — see DATA WIRING).
**Read first:** `AGENTS.md` → CLAUDE DESIGN LANGUAGE section. This kit applies that language to a manual browse flow that lives ALONGSIDE the chatbot, not instead of it.

## HARD RESTRICTION (rule 15)

**No actual purchases.** Browse + reserve-style intent capture only. The kit must NOT integrate any of these TEvo endpoints:

- `POST /v9/clients` — no client account creation
- `POST /v9/clients/{id}/credit_cards` — no card capture
- `POST /v9/clients/{id}/payment_method_nonces` — no Braintree nonces
- `POST /v9/orders` — no order creation
- Any `payments`, `shipped_items`, `tax_quote`, `promo_code` flow

The deepest CTA in the entire kit is **"Have S4K source these for you"** — pushes name + contact + the listing identifier into `bot_messages` (or a future `leads` table) and notifies a human rep. That's it. A human handles the rest off-platform.

Frontend MUST surface this restriction visibly: every listing detail page shows "Tickets reserved through an S4K rep, not auto-purchased" as a sub-line under the CTA. No "Buy now" button anywhere.

## Why a manual UI alongside the chat

The chatbot is good for slot-loaded queries ("Knicks tomorrow lowers 4 under $200 each") but poor for browsing ("show me what's around"). TEvo's own workflow is the proven shape: comprehensive search → landing pages → event page. Build that as the primary surface; keep chat as an express-lane shortcut. Most users will browse; power users will type.

Both surfaces share the same backend (5W slots, S4K-only filter, fallback search) and the same drill-down hierarchy (SEARCH → EVENT → ZONE → LISTING → DETAILS → HANDOFF).

## TEvo workflow → our pages

| TEvo concept | Our page | Backing RPC / endpoint |
|---|---|---|
| Comprehensive Search | Home / persistent search bar in header | `search_performers_for_chat` (typeahead) + `search_events_by_date` (results) + `tevo-fallback-search` (broader market when local empty) |
| Events Near User (geolocation) | "Tonight near you" home strip | `events_near` via the chat fn or direct TEvo wrap |
| Performer Landing Page | `/performer/{slug-or-id}` | `performer_metadata` row + `eventsForPerformer` filtered through `v_s4k_inventoried_events` |
| Venue Landing Page | `/venue/{slug-or-id}` | venues table + `eventsAtVenue` filtered through `v_s4k_inventoried_events` |
| Event Landing Page | `/event/{event_id}` | `get_broker_event_detail` (seating chart, configuration, popularity) + `get_event_zones` (zones with prices) + `find_listings` (ticket groups) |
| Ticket Groups | listings table on event page | `find_listings` already shipped, all v25 metadata surfaced |
| Client / Credit Card / Order creation | NOT BUILT — see HARD RESTRICTION | n/a |
| Reserve CTA → S4K rep handoff | "Reserve" button on listing detail | `bot_messages` insert with channel='web', direction='lead' OR future `leads` table |

## Page roster

```
/                       Home — chips + search + tonight-near-you + popular-categories
/search?q=…             Comprehensive search results (events / performers / venues split)
/performers             Index — A-Z + filter by league / genre
/performer/{slug}       Performer landing — header + upcoming events + similar performers
/venues                 Index — by city
/venue/{slug}           Venue landing — venue header + map + upcoming events
/event/{event_id}       Event landing — header + seating chart + zones + listings table
                        clicking a row drills into LISTING DETAILS modal/panel
/chat                   Existing chatbot, redesigned per CLAUDE DESIGN LANGUAGE
/me                     (FUTURE) my reservations — stub only, no auth yet
/about, /contact, /help (FUTURE) static pages
```

## Component primitives (build once, reuse across all pages)

1. **TopBar** — wordmark left, persistent search center (uses `search_performers_for_chat` typeahead), `/chat` link right. Sticky.
2. **SearchInput** — typeahead-enabled, results grouped by kind (performers / events / venues). Down-arrow navigation, enter to drill.
3. **Chip** — small rounded pill. Variants: kind chip (Game / Concert / Comedy / etc.), provenance chip (S4K-owned amber, TEvo-fallback grey), price chip (`from $X`), freshness chip.
4. **EventCard** — title, when, where, from-price, mode badge, optional thumbnail. Used in chips bar, search results, performer/venue events lists.
5. **Breadcrumb** — drill-down indicator. Shows SEARCH → PERFORMER/VENUE → EVENT → ZONE → LISTING. Each crumb is a back-link.
6. **EventHeader** — name, when (with timezone), where, HOME/road badge for sports, similar-events sidebar trigger.
7. **SeatingChartImage** — `<img>` of `seating_chart_medium` or `_large`. Click opens lightbox. Below it, a small "What zones can I afford?" affordance.
8. **ZonesList** — clickable rows: name, source (curated / system), from-price, median, count. Sort by price asc by default.
9. **ListingsTable** — sortable by price / row / qty. Columns: section, row, qty, format, view_type, in_hand, price, action ("Reserve via S4K"). Owned-row amber stripe for S4K, grey row for TEvo-fallback.
10. **ListingDetailPanel** — slides in from right or full-screen on mobile. Full ticket-group breakdown + "Reserve via S4K" CTA + "Tickets reserved through an S4K rep, not auto-purchased" sub-line.
11. **ReserveForm** — name + email + phone + optional notes. Submit calls a new `/api/leads` route (code agent owns) which inserts to bot_messages with `channel='web', direction='lead'` and notifies the rep. Returns "We'll be in touch within 30 min" confirmation.
12. **EmptyState** — when local search has 0 results, prompt: "We don't have these in our inventory right now. Want us to source from another vendor?" → fires `tevo-fallback-search`. Renders results with grey provenance chip.
13. **WhyBadges** — small inline strip on the event page: weather alert (NOAA), holiday match (#100 future), trending signal (#95 future). Driven by `v_event_why_context`.

## Page wireframes (loose, claude design refines)

### Home `/`

```
┌───────────────────────────────────────────────────────┐
│  [S4K wordmark]   [search bar — typeahead]   [chat ↗]  │
├───────────────────────────────────────────────────────┤
│                                                        │
│   What's good tonight?                                 │
│   [chip] [chip] [chip]   ← rotating, S4K-owned only,   │
│   [chip] [chip] [chip]     get_chat_suggestion_chips    │
│                                                        │
│   Tonight near you                                     │
│   [event card] [event card] [event card] →             │
│                                                        │
│   Browse by category                                   │
│   [Sports] [Concerts] [Comedy] [Theater] [Family]      │
│                                                        │
│   Popular venues                                       │
│   [MSG] [Yankee Stadium] [Crypto.com Arena] →          │
│                                                        │
└───────────────────────────────────────────────────────┘
```

### Performer landing `/performer/{slug}`

```
┌───────────────────────────────────────────────────────┐
│  Top bar (search persistent)                           │
├───────────────────────────────────────────────────────┤
│  Breadcrumb: Home › Performers › New York Knicks       │
│                                                        │
│  New York Knicks                                       │
│  NBA · Basketball · Home: Madison Square Garden        │
│  53-29 · Playoff push · Rivalry with 76ers (intensity 8)│
│  (← from get_team_context, broker-rich version on hover)│
│                                                        │
│  Upcoming events S4K can sell  (8)                     │
│  ┌──────────────────────────────────────────────┐    │
│  │ event card · Knicks @ 76ers G4 · Fri 7pm     │    │
│  │   Xfinity Mobile Arena · from $204 · 831 tix │    │
│  ├──────────────────────────────────────────────┤    │
│  │ event card · 76ers @ Knicks G5 · Mon 7pm     │    │
│  │   MSG · from $164 · 696 tix · seating chart ●│    │
│  └──────────────────────────────────────────────┘    │
│                                                        │
│  Similar performers (← Lakers, Bulls, etc.)            │
│  Recent results (← from broker_performer_dashboard,    │
│                   only the public-safe subset)         │
└───────────────────────────────────────────────────────┘
```

### Venue landing `/venue/{slug}`

Same shape as performer, but: venue header (city, capacity, configuration variants), seating chart preview if a default exists, upcoming events at this venue.

### Event landing `/event/{event_id}` (the key page)

```
┌───────────────────────────────────────────────────────┐
│  Top bar                                               │
├───────────────────────────────────────────────────────┤
│  Breadcrumb: Home › Knicks › Game 5 vs 76ers           │
│                                                        │
│  76ers vs Knicks · Game 5                              │
│  Mon May 12 · 7:00 PM · MSG (Knicks HOME)              │
│  WHY: rivalry intensity 8 · trending up · weather OK   │
│                                                        │
│  ┌──────────────────────┐  ┌──────────────────────┐   │
│  │                       │  │ Available zones (22)  │   │
│  │   [seating chart      │  │ Courtside Apples      │   │
│  │    medium image,      │  │   from $9,240         │   │
│  │    click to enlarge]  │  │ Courtside             │   │
│  │                       │  │   from $9,240 · 7 lst │   │
│  │                       │  │ Courtside A           │   │
│  │                       │  │   $28,000 · 1 lst     │   │
│  │                       │  │ Club Platinum         │   │
│  │                       │  │   from $1,800         │   │
│  │                       │  │ … (scrollable)        │   │
│  └──────────────────────┘  └──────────────────────┘   │
│                                                        │
│  Listings  (filtered by chosen zone, defaults to all)  │
│  [zone filter chips] [qty 1-8] [price max] [sort by]   │
│  ┌──────────────────────────────────────────────┐    │
│  │ Section 12D  Row 4  Qty 4  $9,856 ea  Mobile │    │
│  │   In-hand May 10 · view Full · S4K-owned ◖    │    │
│  │   [Reserve via S4K rep] →                     │    │
│  ├──────────────────────────────────────────────┤    │
│  │ Section 4D   Row 1  Qty 2  $9,240 ea  Mobile │    │
│  │   In-hand May 10 · S4K-owned ◖                │    │
│  └──────────────────────────────────────────────┘    │
│                                                        │
│  Don't see what you want?                              │
│  [Open in chat] [Contact a rep directly]               │
└───────────────────────────────────────────────────────┘
```

### Listing detail (modal or right panel)

```
┌──────────────────────────────────────────────┐
│ Section 12D · Row 4 · 4 tickets               │
│ $9,856 each · $39,424 total                   │
│                                                │
│ Format: Mobile transfer (Ticketmaster)         │
│ View: Full                                     │
│ In hand: not yet · seller delivers May 10      │
│ Splits available: 2 or 4                       │
│ Notes: (any public_notes)                      │
│ Instant delivery: no · Wheelchair: no          │
│                                                │
│ [ Reserve via S4K rep ]                        │
│ Tickets reserved through an S4K rep, not       │
│ auto-purchased. Average response: 30 min.      │
└──────────────────────────────────────────────┘
```

### Reserve form (after CTA click)

Name · email · phone · optional notes (e.g. "willing to go to row 6 if cheaper"). Submit → `/api/leads` → bot_messages insert + rep notification → "We'll be in touch within 30 min" + reservation reference number.

### Chat `/chat`

Already speced under CLAUDE DESIGN LANGUAGE in AGENTS.md. Lives at `/chat` route, accessible from top bar everywhere. No more loud "🎟️ Find Tickets" header — the chat is now one tool among several.

## Data wiring (all backend ready, no copilot/code-agent dependency)

| Page / element | RPC or endpoint | Notes |
|---|---|---|
| Home chips | `get_chat_suggestion_chips(p_count, p_min_tickets)` | rotating; default 6 chips, 200+ tickets |
| Tonight near you | `events_near` (chat fn tool, exposed via `/api/events/near`) | needs lat/lon — use browser geolocation API; fallback IP geo |
| Search typeahead | `search_performers_for_chat(p_query, p_limit)` | groups by alias_kind |
| Search results page | `search_events_by_date(...)` + `tevo-fallback-search` | local first, fallback if empty |
| Performer page | `performer_metadata` row + `get_broker_events_upcoming(p_performer_id=…)` | filter through `v_s4k_inventoried_events` |
| Venue page | venues + `get_broker_events_upcoming(p_venue_id=…)` | same filter |
| Event page header | `get_broker_event_detail(event_id)` | full event + map URL + popularity |
| Event page zones | `get_event_zones` (chat fn tool, exposed via `/api/event/{id}/zones`) | sorts curated first |
| Event page listings | `find_listings` (chat fn tool, exposed via `/api/event/{id}/listings`) | with zone fuzzy expansion (#106) |
| WHY badges | `v_event_why_context` | weather, holiday, trending |
| Reserve form submit | `/api/leads` (NEW — code agent owns) | inserts bot_messages row + rep notify |

## What I (copilot) need to ship for this kit

1. **Expose chat-fn-internal tools as direct REST endpoints** so the manual UI doesn't need to go through the chatbot. New routes (in `/api/`):
   - `GET /api/event/{id}/zones`
   - `GET /api/event/{id}/listings?zone=…&min_qty=…&max_price=…`
   - `GET /api/events/near?lat=…&lon=…&within=…`
   - `GET /api/events/by-performer/{id}?days_ahead=30`
   - `GET /api/events/by-venue/{id}?days_ahead=30`
   These can be Postgres functions wrapped via PostgREST, or thin edge fns. Either way, all already-shipped logic.
2. **A new `leads` table** (or reuse bot_messages with channel='web', direction='lead') so the Reserve CTA has somewhere to write. Plus a tiny notify hook (Slack webhook, email — code agent picks).
3. **`POST /api/leads`** edge fn — accepts {event_id, ticket_group_id, qty, name, email, phone, notes} → writes to leads → fires the notify.

## What claude design needs to ship

1. The 13 component primitives above as reusable HTML/CSS/JS. Vanilla — no React per CLAUDE DESIGN LANGUAGE.
2. The 7 pages (Home, Search, Performers, Performer, Venues, Venue, Event) wired to the RPCs.
3. The `/chat` redesign per the existing spec.
4. Top-level routing — could be plain HTML files (`event.html?id=…` query param style) OR a tiny SPA router. Pick whatever's simplest.
5. HARD RESTRICTION enforcement: no purchase buttons anywhere, all CTAs route to ReserveForm.

## Build order (suggested)

**Phase 1 — Read-only browse + reserve handoff (this kit, MVP):**
1. Component primitives (claude design)
2. REST endpoint wrappers (copilot)
3. Home + Event landing pages (claude design)
4. Reserve form + leads table + rep notify (code + copilot)
5. Performer + Venue landing pages (claude design)
6. Search results page (claude design)
7. Chat redesign (claude design — separate from this kit but same design language)

**Phase 2 — DEFERRED until phase 1 ships and S4K rep handoff is proven:**
- Client account creation
- Saved searches / watchlist for users
- Soft-hold / waitlist
- Eventually: real purchase flow (Braintree, TEvo orders) — but only when business decides

Phase 2 is GATED on user research from phase 1 leads. Don't build it speculatively.

## Anti-goals

- No "Buy now" or "Add to cart" anywhere
- No card-on-file storage
- No marketing email opt-in (do that in phase 2 with explicit consent)
- No infinite-scroll listings — paginate at 25
- No carousel hero with auto-rotation
- No social-proof popups ("12 people viewing!")
- No countdown timers
- No price-pressure language ("Only 2 left!" — even when true; user can see the count themselves)

The whole product reads as a calm concierge marketplace. Trust over urgency.

## Cross-references

- `AGENTS.md` → CLAUDE DESIGN LANGUAGE (palette, type, motion)
- `AGENTS.md` → WEBSITE WORKFLOW (level-by-level UI)
- `AGENTS.md` → 5W structure (WHAT/WHEN/WHO/WHERE/WHY)
- `docs/tevo-api-workflow.md` → TEvo endpoint reference
- Tasks: #84 (chat v28 drill-down), #92 (chat redesign), #104 (website retail UI), #109 (Claude design language application)
