# Retail buying site + chatbot feed — design (2026-05-08)

> **Audience**: claude design (next session) + Julian (code).
>
> **Mandate (Julian, 2026-05-08)**: design a retail-facing ticket site that (a) is a competent traditional ticketing marketplace, and (b) feeds the existing `/chat` retail chatbot with both data and interaction telemetry so the chatbot improves over time.
>
> **Strict wall** — same as the chatbot's: S4K-owned inventory only, no wholesale prices, no broker names, no cross-source internal data ever exposed.

---

## 0. TL;DR

- **Three surfaces**, all served from the same Railway service: `/shop` (catalog + buy flow), `/shop/event/{id}` (event detail + seat picker), `/chat` (the existing retail chatbot, now bidirectionally wired into the shop).
- **Single source of truth** for both surfaces: a public-only API namespace `/api/retail/*` that mirrors the broker's `/api/broker/*` but redacts everything wholesale-or-broker. Two API surfaces, ONE database query layer with a public/private flag — code-side enforcement, not just UI hiding.
- **Chatbot integration**: a persistent floating-pill ("Ask AI to find tickets") on every retail page. Open expands a side panel; the chatbot has access to the same retail catalog and learns from interaction telemetry.
- **Telemetry-as-product**: every search, view, seat pick, abandonment, and chatbot turn writes to a structured `retail_events` table. This is both an analytics asset and the chatbot's training corpus.

---

## 1. Architecture & wall enforcement

### 1.1 Two API surfaces, one DB

| | Broker terminal (existing) | Retail shop (new) |
|---|---|---|
| Auth | Google OAuth gated to `@s4kent.com` | Public; user account is optional (login = save-cart, order history) |
| API namespace | `/api/broker/*` | `/api/retail/*` |
| Inventory visible | Full: S4K-owned + competitor + wholesale | **S4K-owned only**, retail prices only |
| Pricing fields | retail, wholesale, owned-vs-nonowned | retail only (no wholesale, no premium) |
| Seller identity | All (S4K + brokers + competitors) | Hidden; "Sold by VibePass" label |
| Cross-source | All (TEvo + SD + SG + ESPN) | None (internal-only) |
| Read schema | `public.*` | `public.*` filtered by `is_s4k_owned=true AND retail_visible=true` |
| Write schema | `public.*` (orders, etc.) via code | `public.retail_orders`, `public.retail_events` (telemetry) |

**Wall is code-enforced**: the `/api/retail/*` handlers each apply a `WHERE is_s4k_owned=true` filter before any other clause. Audit: a single SQL view `public.retail_inventory_v` is the only data source `/api/retail/*` reads from. If new fields are added to inventory tables, they don't show up in retail until explicitly added to the view.

### 1.2 Why same Railway service

- Shared `/api/public/config` bootstrap (Supabase URL + anon key for any browser).
- Single SSL cert, single deploy.
- Chatbot lives at `/chat`, easiest to keep co-located so it shares fetching with `/shop`.
- Login state survives across surfaces (a customer who chats then buys doesn't re-auth).

If the retail load grows to need its own service, the `/api/retail/*` namespace is already separate so a future split is one re-routing change.

---

## 2. Three surfaces — wireframes

### 2.1 `/shop` — landing + catalog

**Persona served**: browse-and-leave + specific-intent.

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ◤VIBEPASS◢          [tickets] [my account ▾]                              [Cart 0]  │
│  ┌──────────────────────────────────────────────────────────────────────────────┐    │
│  │  Find tickets to anything                                                      │    │
│  │  ┌──────────────────────────┐ ┌──────────────────┐ ┌──────────┐ [Search ►]  │    │
│  │  │ artist · team · venue    │ │ when (any date) │ │ where    │              │    │
│  │  └──────────────────────────┘ └──────────────────┘ └──────────┘              │    │
│  │       💡 Or just: "Knicks playoff lower bowl under $500"  [Ask AI]            │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  TONIGHT NEAR YOU (geolocated, opt-in)                                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                                  │
│  │ Knicks   │ │ Madonna  │ │ Hadestown│ │ Yankees  │                                  │
│  │ vs PHI   │ │ Eras-Echo│ │ Bway     │ │ vs PIT   │                                  │
│  │ 7:30 PM  │ │ 8:00 PM  │ │ 8:00 PM  │ │ 7:05 PM  │                                  │
│  │ MSG      │ │ Barclays │ │ W Kerr   │ │ YS3      │                                  │
│  │ from $89 │ │ from $145│ │ from $65 │ │ from $42 │                                  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘                                  │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  TRENDING                                                                             │
│  Knicks playoffs · Eras-Echo Tour · NHL Stanley Cup R2 · MLB rivalry weekend          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  CATEGORIES                                                                           │
│  [Concerts] [NBA] [NFL] [MLB] [NHL] [Comedy] [Theater] [F1/Tennis/Golf]               │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  💬 Ask AI                                                              floating pill │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Search results page (after a query)**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  Results for "knicks may"                              33 events · sorted by date     │
│  ┌─FILTERS────────────────────────┐  ┌─RESULTS─────────────────────────────────────┐ │
│  │ Date range  [May ▾]             │  │ ⚡ Knicks vs PHI G5 · MSG · Wed 5/13 7:30  │ │
│  │ Price       [$ – $$$$ ]         │  │   from $87 · 1,402 tickets                 │ │
│  │ City        [NYC ▾]             │  │   [View tickets →]                          │ │
│  │ Section     [any ▾]             │  │                                              │ │
│  │ Min qty     [2 ▾]               │  │   Knicks vs PHI G6 · MSG · Fri 5/15 7:30   │ │
│  │ Genre       [Sports ▾]          │  │   from $112                                 │ │
│  │                                  │  │   …                                          │ │
│  │ ☐ Hide sold-out                 │  └──────────────────────────────────────────┘ │
│  └─────────────────────────────────┘                                                  │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Data deps (NEW, all `/api/retail/*`)**:
- `GET /api/retail/events/featured` — geolocated tonight + trending
- `GET /api/retail/events/search?q=&city=&date=&genre=&min_qty=` — full-text + facets, S4K-only
- `GET /api/retail/categories` — top genres for nav

### 2.2 `/shop/event/{id}` — event detail + seat picker

**Persona served**: specific-intent (knows what they want, picking seats).

**Wireframe**:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ← back to results                                                                    │
│  Knicks vs 76ers · Game 5                                                             │
│  Madison Square Garden · Wed May 13 · 7:30 PM ET                                      │
│  ┌─SUMMARY─────────────────────────┐  ┌─MAP / SECTION PICKER────────────────────────┐│
│  │ from $87                          │  │  [interactive venue map]                   ││
│  │ 1,402 tickets available           │  │  click a section to see prices             ││
│  │ pairs available: 89%              │  │                                              ││
│  │                                   │  │  Lower Bowl   $310-$2,400                   ││
│  │ 💡 "Tickets here typically drop  │  │  Mezzanine    $145-$890                     ││
│  │  the day of — see chat for       │  │  Upper Deck   $89-$310                      ││
│  │  context."  [Ask AI]              │  │  Nosebleed    $87-$145                      ││
│  └───────────────────────────────────┘  └────────────────────────────────────────────┘│
├──────────────────────────────────────────────────────────────────────────────────────┤
│  SECTIONS (filtered to selected, or all)                                              │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐                             │
│  │ Sec 102  │ Row 12   │ 4 seats  │ $325 ea  │ [Buy]    │  ← chip-row inventory       │
│  │ Sec 102  │ Row 14   │ 2 seats  │ $310 ea  │ [Buy]    │                             │
│  │ Sec 215  │ Row 6    │ 2 seats  │ $145 ea  │ [Buy]    │                             │
│  │ Sec 415  │ Row 9    │ 2 seats  │ $87 ea   │ [Buy]    │                             │
│  └──────────┴──────────┴──────────┴──────────┴──────────┘                             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  WHAT YOU'RE BUYING                                                                   │
│  Mobile-transfer e-tickets · sent within 2 hours of game-time                         │
│  100% guaranteed by VibePass · refund if not delivered                                │
│  Sold by VibePass                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Note on density**: deliberately the OPPOSITE of the broker terminal. Only retail-relevant fields. No owned-share, no premium, no sentiment, no historical comparables, no wholesale. Just: where, when, how much, how many, how delivered.

**Data deps (NEW)**:
- `GET /api/retail/events/{id}` — event metadata (no analytics)
- `GET /api/retail/events/{id}/inventory?section=&min_qty=` — listings filtered to S4K-owned + retail-eligible
- `GET /api/retail/events/{id}/sections` — sections + price ranges for the picker
- `GET /api/retail/venues/{id}/map` — venue seat-map asset (when `venue_assets.has_map=true`)

### 2.3 Cart + checkout

Standard Stripe Checkout flow. Hide everything broker-y:
- Show: per-ticket retail price, fees (clearly itemized), tax, total.
- Hide: wholesale base, broker margin, internal channel/source, S4K cost basis.
- Post-purchase: e-ticket receipt with delivery ETA + chatbot pin "questions about delivery? Ask AI."

### 2.4 Chatbot integration (`/chat` ↔ `/shop`)

**Existing**: `/chat` is the standalone retail chatbot per the wall rules.

**New wiring**:

1. **Chatbot pill on every `/shop` page** — bottom-right floating button. Click expands a side panel (~360px) without leaving the page. The chatbot has the current event/search context auto-attached so the user doesn't have to repeat ("on this Knicks page" rather than "I'm looking at Knicks").

2. **Chat → buy handoff** — when the chatbot recommends a specific event/seat, the response includes a deep link (`/shop/event/{id}?section=Lower%20Bowl`). Click goes to the event detail with the picker pre-filtered.

3. **Buy → chat handoff** — pages have an explicit "💡 Ask AI about this" button (event detail, seat picker, post-purchase). Opens chat with the page context as the first system message.

4. **Shared session token** — login persists across `/shop` and `/chat`; the chatbot can reference cart contents ("I have 2 in my cart, will more be released?") since the cart and chat share auth.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  /shop/event/3845925?  ⏪ event page in main column                                   │
│  ┌──────────────────────────────────┐ ┌─/chat side panel (collapsible)─────────────┐ │
│  │  Event detail layout              │ │  💬 VibePass AI                         × │ │
│  │  …                                │ │  Context: Knicks vs 76ers Game 5, MSG    │ │
│  │                                   │ │                                            │ │
│  │                                   │ │  > can i bring kids?                       │ │
│  │                                   │ │  AI: yes — MSG allows children of any age.│ │
│  │                                   │ │      under-2 sit on a parent's lap free.  │ │
│  │                                   │ │                                            │ │
│  │                                   │ │  > what's the cheapest pair?               │ │
│  │                                   │ │  AI: section 415 row 9, $87 each.          │ │
│  │                                   │ │      [View these tickets →]                 │ │
│  │                                   │ │                                            │ │
│  │                                   │ │  ┌──────────────────────┐                   │ │
│  │                                   │ │  │ ask anything...      │                   │ │
│  │                                   │ │  └──────────────────────┘                   │ │
│  └──────────────────────────────────┘ └────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Telemetry — chatbot training feed

The site is a learning machine. Every meaningful action writes a structured event to `retail_events` (new table).

### 3.1 Event taxonomy

| event_type | Captured fields |
|---|---|
| `search` | query, facets (date/city/genre/price/qty), result_count, top_3_event_ids |
| `event_view` | event_id, source (search/recommendation/chat), time_on_page_sec |
| `section_focus` | event_id, section, price_range_seen |
| `add_to_cart` | event_id, listing_id, qty, unit_price |
| `cart_abandon` | cart_id, last_step (cart/checkout), seconds_idle |
| `purchase` | order_id, event_id, listing_id, qty, gross, fees, tax |
| `chat_turn` | session_id, role (user/bot), message_text, page_context, latency_ms |
| `chat_to_event` | session_id, recommended_event_id, clicked, converted |

All linkable by `(user_id when logged in OR session_id always)` so we can build conversion funnels.

### 3.2 Why this is the chatbot's training signal

The current `/chat` is presumably either:
- (a) a static prompt-tuned chatbot, or
- (b) a retrieval-augmented one over our event catalog.

Either way, it improves with: (1) more representative user queries, (2) ground-truth signals on which responses lead to purchases. `retail_events` is exactly that.

Pipeline (proposed for Phase 2):
- Daily ETL job aggregates `chat_turn` rows tied to `chat_to_event` outcomes.
- "Successful" turns (those that led to a purchase within 24h) become positive examples.
- "Abandoned" turns (chat → no purchase, or chat → search elsewhere) become negative-or-improvement examples.
- Fed into prompt-tuning, RAG indexing, or an eval set for whichever LLM backs `/chat` (Grok per Julian's note, or Claude, or both).

### 3.3 Privacy

`retail_events` ties to `user_id` only when logged in. Anonymous sessions use a rotating `session_id` (no fingerprinting). PII (email, payment) lives in `retail_orders` and never crosses to the training pipeline. Retention: aggregate-level forever, raw-text for chat 90 days.

---

## 4. Simulations — retail personas × site flows

Scoring: 🟢 = task completes in <60s; 🟡 = completes in <3 min; 🔴 = bounces.

| Scenario | Landing + search | Event detail | Seat picker | Chatbot path |
|---|---|---|---|---|
| Parent buys teen birthday Knicks tix, $200 ceiling | 🟢 (filter price) | 🟢 | 🟢 | 🟡 (helpful but not required) |
| Season-ticket holder reselling 4 seats | n/a v1 (not in scope) | n/a | n/a | n/a |
| Browse-and-leave casual ("anything fun tonight") | 🟢 (Tonight Near You) | 🟢 | 🟡 | 🟢 (chatbot is the fast path here) |
| Specific intent: "Knicks lower bowl under $500" | 🟡 (filters work but tedious) | 🟢 | 🟢 | 🟢 (one-shot via chat) |
| FAQ: "can I bring kids" / "where's parking" | 🔴 (site has no FAQ structure) | 🔴 | 🔴 | 🟢 (chat answers) |
| "Find me 4 seats together" | 🟡 (min_qty=4 filter) | 🟢 | 🟢 | 🟢 (chat is faster) |
| Post-purchase concern: "didn't get my tickets" | 🟡 (account → orders) | 🔴 | 🔴 | 🟢 (chat → support) |
| Multi-event ("Knicks G5 and G6") | 🔴 (one at a time) | n/a | n/a | 🟡 (chat can suggest both) |

**Insights**:
- Chatbot wins almost every "softer" persona (browse, FAQ, multi-event). The site's role is to be the deterministic-purchase rail; the chatbot is the discovery + support rail.
- Search-by-filters is good for sports + concerts where users have a specific event in mind. Less good for "something fun" — that's where Tonight Near You + chat carry.
- Multi-event purchases are a UX hole today. Phase 2: cart that can hold multiple events.
- FAQ structure is missing. Either (a) build a knowledge base accessible from the chatbot only (quick win), or (b) build a structured FAQ section per venue/event_type (more work). Recommend (a) — it doubles as chatbot training.

---

## 5. Open questions

1. **Account requirement** — anonymous checkout vs login-required? Suggest anonymous OK with optional account-creation post-purchase. Removes friction at the conversion step.
2. **Resale (sell mode)** — Phase 2? Suggest yes; v1 is buy-only. Sell-mode is a different product (price-suggestion, listing creation, fulfillment) and shouldn't gate the buy launch.
3. **Geolocation default** — opt-in vs opt-out for "Tonight Near You"? Suggest opt-in via a small "near {detected city}, change?" inline prompt. Don't ask for permission upfront.
4. **Chatbot proactiveness** — pop up after N seconds idle on event detail, or always passive? Suggest passive (floating pill only). Pop-ups are a known conversion killer.
5. **Price transparency** — show fees upfront (TicketMaster does NOT, sketchy reputation) or only at checkout? Strongly suggest upfront. Marketable as "no surprise fees."
6. **Wall enforcement audit** — how does code verify the retail surface never exposes wholesale? Suggest: a CI test that hits `/api/retail/*` against a synthetic dataset where some rows are wholesale-flagged, asserts they're not in the response. Audit pass enforces wall both at data layer (view definition) and at network layer (CI test).
7. **Mobile** — broker terminal is desktop-only, but RETAIL is mostly mobile. Mobile-first design for `/shop` is non-negotiable. PWA shell so the cart works offline-ish on flaky cellular.

---

## 6. Build sequence

| # | Ship | Blockers | Notes |
|---|---|---|---|
| 1 | `/api/retail/*` namespace + `retail_inventory_v` view | code-side, ~2d | Foundation. Wall enforcement at data layer. |
| 2 | `/shop` landing + search + event detail | code+design, ~3d | Mobile-first; copy the chatbot's data shape so they share fetching. |
| 3 | `retail_events` telemetry table + writers | code, ~1d | Even before the pipeline, capture from day-1 so we have data to work with later. |
| 4 | Seat picker + venue map renderer | design+code, ~3-5d | Big visual surface; lean on `venue_assets.map_url` data. |
| 5 | Cart + Stripe Checkout | code, ~2d | Existing TEvo/SG plumbing handles fulfillment downstream. |
| 6 | Chatbot side-panel integration | design+code, ~2d | Reuse `/chat` directly via iframe or shared component. |
| 7 | Account + order history | code, ~2d | Stripe customer portal handles 80%; thin wrapper. |
| 8 | Chatbot training pipeline (Phase 2) | code, ~5d | ETL job over `retail_events`, eval harness, weekly model refresh. |

---

## 7. References

- Existing: `static/chat.html` — current retail chatbot UI; reuse styling/components.
- Existing: `docs/retail-ui-kit.md` — retail UI kit (per repo inventory).
- Existing: `docs/tevo-api-workflow.md` — TEvo handoff for fulfillment.
- New: this doc.
- Companion: `design/preliminary-event-views-2026-05-08.md` (broker terminal templates) — opposite-density target. Retail surfaces should NEVER look like the broker terminal.

---

## 8. Status

Filed by: design · 2026-05-08
Builds on the existing /chat retail chatbot infrastructure and the broker-terminal architecture decisions; introduces a new public surface with strict wall enforcement at the data layer.
Next step: review by Julian (code) + claude design session pickup.
