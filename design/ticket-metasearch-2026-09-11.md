# Ticket metasearch — "Trivago" vs "Expedia" for tickets

**Status:** proposal, point-in-time (2026-09-11). Non-canonical; the open-work row, if the operator files one, lives in `KANBAN.md`. Facts below were read live from prod (read-only) on 2026-09-11 ~04:00 UTC and will drift.

---

## 0. The question

Build a consumer surface that shows, for one event, the cheapest ticket across every marketplace we observe. Two shapes were floated:

| | **Trivago model** (metasearch) | **Expedia model** (agency / one checkout) |
|---|---|---|
| What the fan sees | One event, one price ladder, one row per marketplace, "Buy on SeatGeek / GoTickets / VibePass" | One event, one price ladder, one **Buy** button; we sell every row |
| Where the money moves | On the marketplace we hand off to; we earn affiliate CPA/CPC + our own sales when VibePass wins | Through us: we buy the seat from the source and resell it |
| Upstream calls | GET only | GET **and** order creation on the source |
| Fits `CLAUDE.md` Rule 2 today? | **Yes, exactly** — nothing new touches an upstream write | **No** — order creation is the named forbidden action; needs the security-CRIT exception documented in `docs/buy_side_evo_gotickets.md` |
| Also needs | Affiliate/partner agreements; ToS review for displaying marketplace prices to consumers | Payments (Stripe exists for D4), delivery/transfer handling, refunds, CS, inventory verification before charging (`n2s_cover_verify` pattern) |

**Recommendation: build the Trivago shape first, on the D1 store event page, and let one row of it become Expedia.** The comparison engine is ~90% already in the data plane (§1). The one supplier we can transact with cleanly is the TEvo exchange, and VibePass already sells TEvo inventory (`/api/store/reserve`) — so when TEvo is the cheapest row, the "Buy" button is ours. That single path *is* the Expedia model with one supplier, and it is the scoped exception an operator can authorise without opening every marketplace's buy API. GoTickets Pro API (`POST /orders`) is the natural second supplier, later.

---

## 1. What already exists (do not rebuild)

The repo already runs a per-event, multi-marketplace price comparison — it is just pointed at a broker problem (covering failed orders) rather than at a fan.

| Piece | Where | What it gives the metasearch |
|---|---|---|
| Canonical event hub | `aq_event_map` (`PROJECT_BIBLE §0/§5`) | One `tevo_event_id` per real-world event with SG / SH / Vivid / TM ids hanging off it — the join key for "same event, different marketplaces" |
| Latest-capture-per-source union with buy links | `n2s_cover_candidates()` (migs `20260910300000`/`310000`) | The exact CTE shape a compare RPC needs: per source, the newest capture within an age window, joined to that capture's rows, with a `buy_url` per listing. Sources: TEvo · GoTickets · SeatGeek · TicketsData |
| Cross-source listing view | `unified_listings` (mig `20260527140000`) | tevo / sg_broker / sg_seller / seatdata / td_* arms in one shape. **Missing:** a GoTickets arm, `buy_url`, and it is unbounded over a 48 GB table — never query without event + latest capture |
| Per-source event URLs | `get_event_source_links(p_event_id)` (mig `20260603180000`) | SG canonical URL + TD per-platform event URLs. Email-gated `@s4kent.com` — needs a public, whitelisted variant |
| Per-source aggregate stats | `get_event_all_source_listing_metrics`, `get_event_cross_source_metrics` | min/median/count per source. Email-gated |
| Cross-market demand ranking | `sg_market_chart` (`platform_breadth`, `market_median_all`) | Which events have a live market on ≥2 platforms — the index page's "compare prices" badge |
| On-demand SG pull | `sg_listings_pull_on_demand()` + cron 604 | Fan-triggered "refresh prices" for SeatGeek, already budget- and FK-guarded (mig `20260911010000`) |
| GoTickets listings ingest | `gotickets_listings_snapshots` + `gt_*` crons (mig `20260804230000`) | Listing-level `all_in_price`, `splits`, `section_id` → GT deep link |
| Consumer storefront | `static/store/*`, `/api/store/*` (D1) | Event page with seat map, zone filters, share links, `from_price`; single-source (our TEvo inventory) today |
| Read-only guard | `core/readonly_guard.py` + `scripts/check_readonly.py` | The Trivago shape adds nothing that this needs to change |

### Buy-link reality per source

| Source | Listing-level consumer link | Notes |
|---|---|---|
| SeatGeek | **Yes** — `sg_events_canonical.sg_url` + `#listing=<display_id>` | Verified 2026-09-10; both halves or neither (mig `20260910310000`). `sg_url` present on 88% of live listing rows, 31% of the upcoming TEvo catalogue |
| GoTickets | **Yes** — `pro.gotickets.com/tickets/<gt_event_id>/…?sections=<section_id>` | `section_id` is a stored column, never derived (`PROJECT_BIBLE` v2.23.0) |
| TEvo | **No consumer URL** — the exchange is wholesale | The buy path for a TEvo row is **our** storefront: `/store/event?id=<tevo_event_id>` |
| StubHub / Vivid / TickPick / TM (via TicketsData) | Event-level URL only (`ticketsdata_event_xref.event_url`) | And dark since 2026-09-09 — see §2 |
| AXS / TM primary (face value) | Event-level | AXS routed through TicketsData → also dark |

---

## 2. Live coverage (prod, read-only, 2026-09-11)

| Metric | Value |
|---|---|
| Upcoming catalogued TEvo events, next 180 d | 8,569 |
| … polled on TEvo within 24 h | 8,569 (100%) — `evo_listings_poll_2min`, band-prioritised |
| … with a SeatGeek id in the hub | 5,382 (63%) |
| … with a stored SeatGeek consumer URL | 2,633 (31%) |
| … mapped to a GoTickets event | 3,530 (41%) |
| GoTickets events with listings polled in 24 h | 4,217 |
| **SeatGeek events with listings in the last 7 d** | **76** — the on-demand poller fires only for open N2S obligations; the owned/non-owned pollers have been off since 2026-06-26 |
| TicketsData (StubHub/Vivid/TickPick/TM) latest capture | 2026-09-09 10:04 UTC — contract lapsed (KANBAN A1-OPS-33) |
| AXS latest capture | 2026-09-01 |

So **today the comparison is TEvo × GoTickets at scale, SeatGeek only where something asked for it.** The catalogue side (ids, URLs) is far ahead of the listings side for SeatGeek: 5,382 events are comparable the moment a pull fires.

### Does the comparison change what a fan pays? (30-event sample, events with SG + TEvo fresh)

| Event | TEvo min | SeatGeek min | GoTickets min | Cheapest→dearest |
|---|---|---|---|---|
| Red Sox at Rays, 9/19 | $42.75 (163) | $132.74 (1) | **$35.90** (246) | 270% |
| Rockies at Yankees, 9/9 | $2.14 (193) | $6.90 (550) | **$1.99** (219) | 247% |
| Astros at Phillies, 9/10 | $9.59 (267) | $16.15 (317) | **$7.06** (28) | 129% |
| Twins at Giants, 9/21 | $10.53 (507) | $18.59 (12) | **$9.53** (602) | 95% |
| Mets at Yankees, 9/13 | $40.40 (553) | $54.26 (13) | **$38.70** (692) | 40% |
| Giants at Dodgers, 9/19 | $93.52 (394) | $83.90 (3) | **$68.26** (515) | 37% |
| Mets at Yankees, 9/11 | $102.24 (443) | $121.68 (1046) | **$93.23** (438) | 31% |
| US Open, 9/13 | **$408.72** (1367) | $504.90 (417) | — | 24% |

(n listings at the latest capture in parentheses.) Across the 30: the cheapest seat differs by **>25% on 18 events and >100% on 7**. Two caveats that are themselves design requirements:

1. **Fees are not normalised.** TEvo `retail_price` is exchange retail before *our* fees; SeatGeek `retail_price_all_in` and GoTickets `all_in_price` include fees. Trivago's hard-won lesson: compare the **total** price or the ladder lies. A `source_fee_model` (per-source fee formula, plus ours on the VibePass row) is table stakes.
2. **SeatGeek snapshots are partial.** Most SG rows above come from N2S pulls scoped to one section (n = 1–13), so the SG "min" is a section min, not a book min. A consumer compare needs whole-book pulls for the events it shows.

---

## 3. Proposed build (Trivago shape, D1 surface, A1 data)

Ordered by what unblocks what. Phases 1–3 are read-only end to end.

**0 · Decisions (operator, before any code)**
- Which model (§0). Recommendation: Trivago first, TEvo-row checkout as the Expedia seed.
- ToS: are TEvo exchange prices and SeatGeek *broker-feed* prices displayable to consumers? Both feeds are broker-facing; the consumer-facing SeatGeek/StubHub/Vivid/TickPick partner programs are the clean affiliate path and may come with their own data feeds. This is a legal/commercial question, not an engineering one.
- SeatGeek listings budget: the token is shared with an external prod program (~5 req/10 s). Whole-book pulls for fan-facing events need a budget line.
- Restore StubHub/Vivid/TickPick: renew TicketsData, or go direct via partner feeds.

**1 · Data plane (A1, migration files; standing Builder action)**
- `get_event_price_compare_public(p_event_id bigint, p_qty int DEFAULT 2)` — SECDEF, **anon-callable, rate-limited, column-whitelisted** (no `wholesale_price`, `brokerage_name`, `is_owned`, seller ids — the `*_public` seam in `PROJECT_BIBLE §2.6`). Returns one row per source: cheapest all-in for a qty-compatible split, listings count, `captured_at`, `buy_url`, plus a short ladder (top N by price) per source. Body = the `n2s_cover_candidates` latest-capture CTE with a GoTickets arm added and parking/ancillary/GA excluded; dedupe per `tevo_event_id` (the hub can carry duplicates, `§0`). Add to `docs/anon_callable_surface_inventory.md`.
- `source_fee_model` table + `price_all_in(source, base, qty)` — one place for fee math; the VibePass row uses our own schedule.
- `unified_listings`: add the GoTickets arm and a `buy_url` column so the terminal sees the same book the fan does.
- Consumer-demand-driven SG pull: a small `compare_pull_requests` queue fed by the store (event id, requested_at), drained by the existing `sg_listings_pull_on_demand` under a daily budget, with a per-event cooldown. Never a live API call in the request path.

**2 · Surface (D1: `static/store/event.html` + `/api/store/events/{id}/compare`)**
- "Cheapest across marketplaces" panel above the seat map: one row per source — logo/name, cheapest total for the chosen qty, listing count, "as of 4 min ago", **Buy on …** button. Our row is highlighted only when it actually wins.
- Qty selector drives the whole panel (split-aware).
- A deep-linkable `/store/compare?event=<id>&qty=2` page for sharing (reuse the `share_links` seam).
- Index/discover: "Compare prices" badge on events where `sg_market_chart.platform_breadth ≥ 2`.
- Missing-source honesty: a source with no fresh capture shows "no price yet · refresh", never a stale number without its timestamp.

**3 · Freshness UX**
- "Refresh prices" enqueues a pull (phase 1 queue) and polls the RPC; per-IP limiter via `core/ratelimit`. Read-only upstream by construction — the force-pull rule in `CLAUDE.md §2` already covers this pattern.

**4 · Expedia seed (later, authorised, security-CRIT)**
- TEvo-exchange checkout on VibePass: verify (`n2s_cover_verify` shape) → hold → charge (Stripe) → `Orders/Create` → delivery. Every step is documented as *not implemented* in `docs/buy_side_evo_gotickets.md`; that doc is the spec. GoTickets Pro API second.

---

## 4. Landmines specific to this build

- **Never join sources on raw ids** — everything resolves through `aq_event_map` by `tevo_event_id`; `listings_snapshots.aq_short_event_id` is 0%-populated (`PROJECT_BIBLE §5`).
- **`listings_snapshots` is 48 GB.** Read only the latest capture per event via `(event_id, captured_at DESC)`; the compare RPC must be per-event and bounded, like `get_gotickets_deals`.
- **Half a buy link is worse than none** (mig `20260910310000`): emit `buy_url` only when every component is stored; otherwise the row is "see on SeatGeek" at event level.
- **The hub can be wrong** — N `aq_short_event_id` rows per `tevo_event_id`; dedupe and confirm performer/opponent before trusting a cross-source row.
- **Fans get only public data** (`docs/d_tier_goals.md` G1). No broker fields may leak through the compare RPC; B1's anon-surface sweep must list it.
- **Exclude parking / ancillary / GA / accessible-only rows from the "cheapest" number** (they legitimately price low), but show them in the ladder tagged.
- **SG token is shared** — the consumer pull queue must sit under `v_sg_token_budget`, never fire from a request handler.

---

## 5. What was verified vs assumed

Verified live: coverage counts (§2), cron states (SG listings pollers off; on-demand drain on; TD dark since 09-09; AXS since 09-01), the 30-event price sample, buy-URL patterns (from the migration headers and stored columns). Assumed / to confirm with the operator: affiliate-program availability and terms, ToS position on consumer display of broker-feed prices, whether TicketsData will be renewed.
