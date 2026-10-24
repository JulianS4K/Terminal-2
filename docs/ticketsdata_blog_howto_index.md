# TicketsData Blog How-To Index — mapped to our integration

On-demand reference (not a session-start read). Indexes the developer
how-to guides on the TicketsData blog (<https://ticketsdata.com/blog>) and
maps each one's guidance onto **our existing, production** TicketsData
integration so a session can see, at a glance, what the vendor recommends
and where we already do it.

**One fact, one home.** This doc is a *pointer index*, not a second copy of
the integration facts. The canonical homes stay authoritative — link, don't
restate:

- Service + secrets + tables → `RESOURCES_BIBLE §1`, `§2.12` (`td_*`), `§2.15` (AXS via TD).
- Client code → `ticketsdata_client.py` (read-only `/fetch` · `/events` · `/match`).
- Budget-guarded smoke test → `scripts/ticketsdata_mvp.py`.
- Poll cadence authority → `collector_cadence` + `td_enqueue_peak` (`RESOURCES_BIBLE §2.12`, §5.1).

> **Sourcing note.** The blog host is **network-blocked** from this
> environment (agent-proxy policy denies `ticketsdata.com`), so the article
> set below was resolved from public search on 2026-07-27, not a live crawl.
> Treat the live articles as source of truth; this file is an index +
> a mapping of their *guidance* to our code. Refresh URLs if the blog
> re-slugs.

---

## 1. The how-to guides (external reference)

**Integration / getting started**
| Guide | URL | Relevance to us |
|---|---|---|
| How to Build Ticket API Integration (step-by-step) | `/blog/build-ticket-api-integration` | The Intake→Cleaning→Storage→Delivery model — matches our `td_pull_queue`→xref→snapshots→RPC path. |
| How to Use the Ticketmaster Data API (quick guide) | `/blog/ticketmaster-data-api-1` | `/fetch` usage for TM, one of our TD platforms. |
| Ticketmaster Data API: Access, Query, Integrate | `/blog/ticketmaster-data-api` | Query/normalize patterns for the TM feed. |
| How to Get Ticketmaster Data: APIs, Feeds & Exports | `/blog/how-to-get-ticketmaster-data` | Feed/export options context. |

**Best practices & libraries**
| Guide | URL | Relevance to us |
|---|---|---|
| Implementing Ticketing API: Essential Strategies | `/blog/ticketing-api-best-practices` | Retries, caching, pagination, error handling — see §2, several map 1:1 to our client. |
| Choosing the Right Ticketing API Libraries | `/blog/ticketing-api-libraries` | Library selection; we use `requests` + shared `core/` guards. |

**Per-platform guides**
| Guide | URL |
|---|---|
| SeatGeek Tickets API | `/blog/seatgeek-tickets-api` |
| StubHub API Access | `/blog/stubhub-api-access` |
| Gametime Ticket API | `/blog/gametime-ticket-api` |
| Sports Ticket API | `/blog/sports-ticket-api` |
| Stadium Ticket API | `/blog/stadium-ticket-api` |
| Concert Tour API | `/blog/concert-tour-api` |
| AXS Tickets API | `/blog/axs-tickets-api` |

**Pricing / market intelligence**
| Guide | URL | Relevance to us |
|---|---|---|
| Ticket Broker Market Intelligence | `/blog/ticket-broker-market-intelligence` | The value story behind `/match` (cross-market report, 12 credits + 1 report). |
| Optimal Pricing Strategies for Ticket Brokers | `/blog/ticket-broker-pricing-tools` | Informs demand/price surfacing — note RULE 2: **we never reprice upstream**. |
| Cross-Venue Ticket Pricing | `/blog/cross-venue-ticket-pricing` | Cross-venue medians ≈ our `venue_section_price_daily` aggregates (`RESOURCES_BIBLE §2.14`). |
| Ticket Inventory API: Real-Time Availability | `/blog/ticket-inventory-api` | Live-feed rationale behind `ticketsdata_listings_snapshots`. |

---

## 2. Blog guidance → our implementation

| Blog how-to says | Where we do it | Status |
|---|---|---|
| Authenticate with email + password as request params | `ticketsdata_client.py` `_get()` — creds injected into params, **never** in the logged/raised URL | ✅ |
| GET / read endpoints only | `ALLOWED_HTTP_METHODS = {"GET"}` + `_assert_readonly_method` (RULE 2, `core/readonly_guard.py`) | ✅ (stronger — raises on non-GET) |
| Retry `service_unavailable`/`timeout` ~2× at 1.5s→3s; **don't** retry 400/401/402/404 | `_get()` retry loop: `delays=[1.5,3.0]`, retries 429/503/504, deterministic 401→`AuthError`, 402→`QuotaError` | ✅ (exact match to the vendor's rule) |
| Watch quota; each call spends 1 credit (`/match` 12) | `CREDIT_COST` + `scripts/ticketsdata_mvp.py` worst-case pre-flight guard + per-call `quota_remaining`/`reports_remaining` floor | ✅ |
| Keep concurrency moderate (~5–15), no spikes | Cadence governed centrally by `collector_cadence` + `td_enqueue_peak`, not per-call fan-out (`RESOURCES_BIBLE §2.12`) | ✅ (link) |
| Cache static details (venues) longer than fast-moving (prices) | `tevo_ticket_groups_cache` 5-min TTL; TD listings retention 30d (`RESOURCES_BIBLE §2.14`) | ✅ (link) |
| Intake → Cleaning → Storage → Delivery pipeline | `td_pull_queue` → `ticketsdata_event_xref` (AQ map) → `ticketsdata_listings_snapshots` → read RPCs | ✅ (link) |
| Add pagination/filtering early | `/events` discovery feeds the queue; reads are AQ-keyed + filtered downstream | ✅ |
| — (our addition beyond the blog) | `NATIVE_PLATFORMS={"seatgeek"}` + `OPERATOR_DISABLED_PLATFORMS` reject paid re-fetch of natively-sourced/disabled markets | ✅ (cost guard the blog doesn't mention) |

---

## 3. Optional follow-ups (honest gaps)

Nothing here is a defect — the integration already follows the vendor's core
guidance. Candidates only if a future task wants them:

- **AXS caching tier.** AXS `/fetch` is slow (~20–40s) and per-fetch ≈1 credit
  (logged to `ticketsdata_credit_usage`, `RESOURCES_BIBLE §2.15`). The blog's
  "cache static longer" advice suggests a longer TTL for AXS venue/section
  scaffolding vs. per-seat pricing — worth measuring before adding.
- **`/match` budget visibility.** The blog frames `/match` as the market-
  intelligence product; we gate it behind `--allow-match` + a raised cap. A
  dashboard readout of `reports_remaining` (Pro plan) would make the 250/mo
  report budget visible rather than script-only.

Author under operator direction; read-only work — no code or prod mutation
was required to produce this index.
