# SeatGeek Migration — Kanban Backlog

> Each task is structured for direct import into a kanban tool. Format:
> **Title** · Priority · Estimate · Dependencies · Description · Acceptance Criteria · Notes
>
> **Priority key**: P0 (blocker / time-critical), P1 (must-have), P2 (should-have), P3 (nice-to-have)
> **Estimate key**: S (≤1 day), M (2–4 days), L (1–2 weeks), XL (multi-sprint)

---

## EPIC 1 — Bulk Catalog Migration (URGENT)

> Driver: `/events` is hard-capped at 10,000 results since Jan 1, 2026. If your integration relies on full catalog enumeration, you are already losing data.

---

### TASK 1.1 — Audit current `/events` usage

**Priority**: P0
**Estimate**: S
**Dependencies**: none

**Description**
Identify every code path that calls `GET /events`, document the access pattern (one-off lookup vs. full enumeration), and estimate exposure to the 10K cap.

**Acceptance criteria**
- [ ] List of all `/events` call sites with file/line references
- [ ] For each: classification as `lookup` (specific id/filter) or `enumeration` (paginate-all)
- [ ] Estimated production query volume per call site
- [ ] Risk assessment doc: which call sites are silently truncating today

**Notes**
Use grep/ripgrep across the repo. Don't forget background jobs and scheduled syncs.

---

### TASK 1.2 — Decide bulk vs. delta vs. hybrid strategy

**Priority**: P0
**Estimate**: S
**Dependencies**: 1.1

**Description**
Choose sync architecture based on audit findings. Document the decision and rationale.

**Decision matrix**
| Use case | Recommendation |
|---|---|
| Need full catalog ≤ hourly | Hybrid: bulk baseline + delta poll |
| Need full catalog daily | Bulk download only |
| Spot lookups only | Keep `/events/{id}` direct, no bulk |
| Search index | Hybrid + reindex after each bulk |

**Acceptance criteria**
- [ ] ADR (architecture decision record) committed to repo
- [ ] Strategy mapped per call site identified in 1.1
- [ ] Stakeholder sign-off documented

---

### TASK 1.3 — Implement bulk download client

**Priority**: P0
**Estimate**: M
**Dependencies**: 1.2

**Description**
Build the client that calls `/2/bulk/download_url`, retrieves the presigned S3 URL, downloads the JSONL, and streams it to a parser.

**Acceptance criteria**
- [ ] `bulk_client.fetch_download_url(entity)` returns a presigned URL string
- [ ] Supports `entity` ∈ {events, venues, performers}
- [ ] Streaming download (does not load full file into memory)
- [ ] Streaming JSONL parser yields parsed records one at a time
- [ ] Handles network errors with retry + backoff
- [ ] Logs file size, download duration, record count
- [ ] Unit tests with mocked S3 responses
- [ ] Integration test against staging (if available)

**Notes**
Presigned URLs are short-lived; do not cache them across runs. Treat the download URL endpoint as the entry point of every sync run.

---

### TASK 1.4 — Implement delta feed poller

**Priority**: P0
**Estimate**: M
**Dependencies**: 1.3

**Description**
Hourly job that calls `/2/bulk/deltas/events?updated_after={last_run}` and applies changes incrementally.

**Acceptance criteria**
- [ ] `delta_poller.poll(since: datetime)` returns paginated deltas
- [ ] Pagination loop (page + page_size) handled cleanly
- [ ] Persists `last_successful_poll_at` after every run
- [ ] Validates `updated_after` is within last hour (UTC) before sending
- [ ] If `last_successful_poll_at` is older than 1 hour: triggers fallback to bulk download (do NOT just send a stale `updated_after` — the API will reject)
- [ ] Idempotent upsert into local store (same record applied twice = same result)
- [ ] Unit + integration tests

**Notes**
The 1-hour `updated_after` constraint is a hard limit. Document the fallback path prominently — this is the easiest place for silent data loss.

---

### TASK 1.5 — Schema mapping layer

**Priority**: P0
**Estimate**: M
**Dependencies**: 1.3

**Description**
Build a normalization layer that translates the bulk JSONL shape into your domain models. Do NOT let new field names leak into business logic.

**Acceptance criteria**
- [ ] `Event`, `Venue`, `Performer` domain models defined
- [ ] `from_bulk_record()` constructors for each
- [ ] All "added" fields from bulk format mapped or explicitly ignored with comment
- [ ] All "removed" fields documented with replacement source (or marked "deprecated, no replacement")
- [ ] Schema drift detector: unknown fields in JSONL → log warning, do NOT crash
- [ ] Migration test fixtures: sample old `/events` response + sample bulk JSONL → both produce equivalent `Event`

**Notes**
Reference the field comparison tables in `seatgeek-migration-guide.md` §5.4. Pay particular attention to:
- `description`, `links`, `relative_url` — removed; find UI replacements
- `general_admission` → may be replaced by `is_ga`
- `images` (plural performer field) → only singular `image` + top-level `image{}` remain

---

### TASK 1.6 — Sync orchestrator with fallback

**Priority**: P0
**Estimate**: M
**Dependencies**: 1.3, 1.4, 1.5

**Description**
Top-level scheduler that orchestrates baseline + incremental sync, with automatic fallback when delta polling falls behind.

**Acceptance criteria**
- [ ] `sync_orchestrator.run()` decides between bulk and delta based on state
- [ ] State machine: `INITIAL → BULK_RUNNING → DELTA_POLLING → (recovery) → BULK_RUNNING`
- [ ] Hourly cron entry-point for delta
- [ ] Daily/weekly cron entry-point for full bulk (configurable)
- [ ] On bulk completion: resets `last_successful_poll_at` to bulk timestamp
- [ ] On delta failure: increments failure counter, fallback after N consecutive failures
- [ ] Metrics emitted: sync_lag_seconds, last_run_status, records_processed
- [ ] Alerting hook for sync_lag > threshold

**Notes**
This is the highest-blast-radius component. Build it last and test extensively.

---

### TASK 1.7 — Cut over consumers from `/events` to local store

**Priority**: P1
**Estimate**: L
**Dependencies**: 1.6

**Description**
Migrate each call site identified in 1.1 from direct `/events` calls to reading from the bulk-synced local store.

**Acceptance criteria**
- [ ] Per-call-site migration PR
- [ ] Behavior parity tests (old vs. new path) before cutover
- [ ] Feature flag gating each cutover
- [ ] Rollback plan documented per site
- [ ] Old call sites removed after stable observation window

---

### TASK 1.8 — Decommission stale `/events` calls

**Priority**: P2
**Estimate**: S
**Dependencies**: 1.7

**Description**
Remove dead code paths and update documentation.

**Acceptance criteria**
- [ ] No remaining `GET /events` calls except where explicitly justified
- [ ] Remaining justified calls are documented (e.g., real-time spot lookup, low-volume)
- [ ] Internal docs updated to point to bulk-derived store

---

## EPIC 2 — Public Catalog Integration

> Driver: build the read surfaces for events/venues/performers/recommendations.

---

### TASK 2.1 — HTTP client foundation (Platform API)

**Priority**: P1
**Estimate**: M
**Dependencies**: none

**Description**
Build the base HTTP client for the Platform API: auth injection, retries, timeouts, error typing, observability.

**Acceptance criteria**
- [ ] Centralized client class with method-per-verb (`get`, `post`, etc.)
- [ ] Auth header injection (TODO: confirm mechanism — see doc gap §8.1 in migration guide)
- [ ] Configurable timeout (connect, read)
- [ ] Retry policy: exponential backoff with jitter on 5xx + connection errors
- [ ] Typed error hierarchy: `BadRequestError`, `AuthError`, `NotFoundError`, `RateLimitError`, `ServerError`, `TransientError`
- [ ] `Retry-After` header respected on 429
- [ ] Per-request structured logging with correlation IDs
- [ ] Latency histogram emitted per endpoint

**Notes**
Doc gap: the provided PDFs do not specify auth mechanism. Stub with a `TODO(auth)` and confirm with SeatGeek docs/support before merging.

---

### TASK 2.2 — Pagination helpers

**Priority**: P1
**Estimate**: S
**Dependencies**: 2.1

**Description**
Build paginator helpers for the Platform API's page/per_page mechanism.

**Acceptance criteria**
- [ ] `paginate(endpoint, params, per_page=50)` generator yields all results
- [ ] Respects `meta.total` for termination
- [ ] Configurable max page count safety limit (avoid runaway loops)
- [ ] Tested with empty result, single-page, multi-page, partial last page

---

### TASK 2.3 — Events endpoint wrapper

**Priority**: P1
**Estimate**: M
**Dependencies**: 2.1, 2.2

**Description**
Typed wrappers for `/events`, `/events/{id}`, `/events/section_info/{id}`.

**Acceptance criteria**
- [ ] `list_events(filters, sort, paginate)` with all documented filter params
- [ ] `get_event(event_id)` returns single event
- [ ] `get_section_info(event_id)` returns section/row map
- [ ] Filter param builders: `performers_filter`, `venue_filter`, `datetime_range`, `price_range`
- [ ] Datetime operators (`gt/gte/lt/lte`) supported
- [ ] Type-safe enum for `taxonomies`
- [ ] Tested against documented response shape
- [ ] Hard cap at 10K results documented in code (and consumers warned)

---

### TASK 2.4 — Performers endpoint wrapper

**Priority**: P1
**Estimate**: S
**Dependencies**: 2.1, 2.2

**Description**
Typed wrappers for `/performers` and `/performers/{id}`.

**Acceptance criteria**
- [ ] `list_performers(slug, q, id, taxonomies)` with all params
- [ ] `get_performer(performer_id)`
- [ ] Note documented in code: geolocation NOT supported on this endpoint
- [ ] Tested

---

### TASK 2.5 — Venues endpoint wrapper

**Priority**: P1
**Estimate**: S
**Dependencies**: 2.1, 2.2

**Description**
Typed wrappers for `/venues` and `/venues/{id}`.

**Acceptance criteria**
- [ ] `list_venues(city, state, country, postal_code, q, id)`
- [ ] `get_venue(venue_id)`
- [ ] State/country code validation (2-letter)
- [ ] `venue.name` filter is NOT supported — documented in code
- [ ] Tested

---

### TASK 2.6 — Recommendations endpoint wrapper

**Priority**: P2
**Estimate**: S
**Dependencies**: 2.1, 2.2

**Description**
Wrappers for `/recommendations` and `/recommendations/performers`.

**Acceptance criteria**
- [ ] `recommend_events(seed_performers, seed_events, geo_params)`
- [ ] `recommend_performers(seed_performers, seed_events)`
- [ ] Geolocation params (`geoip`, `lat`/`lon`, `postal_code`, `range`) on event recs only
- [ ] Default `range=200mi` documented
- [ ] Seed exclusion behavior documented (performer seeds excluded from results)

---

### TASK 2.7 — Taxonomies endpoint + caching

**Priority**: P2
**Estimate**: S
**Dependencies**: 2.1

**Description**
Wrap `/taxonomies` and add long-lived cache.

**Acceptance criteria**
- [ ] `list_taxonomies()` returns full list
- [ ] In-memory cache with configurable TTL (default 1 hour)
- [ ] `get_taxonomy_by_id(id)` and `get_taxonomy_by_name(name)` lookups
- [ ] Cache invalidation hook

**Notes**
Taxonomies change rarely. Cache aggressively to avoid round-trips.

---

### TASK 2.8 — Geolocation helper module

**Priority**: P2
**Estimate**: S
**Dependencies**: 2.3, 2.5

**Description**
Centralized geolocation parameter builder used by event and venue queries.

**Acceptance criteria**
- [ ] `GeoFilter.from_ip(ip)`, `GeoFilter.from_postal(code)`, `GeoFilter.from_coords(lat, lon)`
- [ ] Validates US/Canadian postal codes only (per docs)
- [ ] Range supports both `mi` and `km` suffixes
- [ ] Mutually exclusive with itself (only one geo input at a time)

---

## EPIC 3 — Ticket Export Workflows

> Driver: build the discovery + export side of the Ticket Export API.

---

### TASK 3.1 — HTTP client foundation (Ticket Export API)

**Priority**: P1
**Estimate**: M
**Dependencies**: none (parallel with 2.1)

**Description**
Build a SEPARATE HTTP client for the Ticket Export API. Auth scope and credentials may differ from the Platform API.

**Acceptance criteria**
- [ ] Independent client class — does NOT share state with Platform client
- [ ] Auth injection (TODO: confirm mechanism)
- [ ] Same retry/error/observability standards as 2.1
- [ ] Idempotency key support for state-changing endpoints (transfer create/cancel)

**Notes**
Why separate? Different auth scope, different consumer (internal ops vs. external discovery), different retry semantics for state-changing endpoints.

---

### TASK 3.2 — Cursor-style paginator

**Priority**: P1
**Estimate**: S
**Dependencies**: 3.1

**Description**
Build a paginator for the Ticket Export API's opaque-token mechanism (`links.next`).

**Acceptance criteria**
- [ ] `paginate_cursor(endpoint, initial_params)` generator
- [ ] Extracts `page` token from `links.next` URL
- [ ] Terminates when `links.next` absent
- [ ] Tested with empty, single-page, multi-page

**Notes**
This is structurally different from the Platform API's `page` integer. Don't try to share the implementation.

---

### TASK 3.3 — Inventory discovery endpoints

**Priority**: P1
**Estimate**: S
**Dependencies**: 3.1

**Description**
Wrap `/uploader/performers` and `/uploader/events/{performer_id}`.

**Acceptance criteria**
- [ ] `list_performers()` returns `[performer_id]`
- [ ] `list_events_for_performer(performer_id)` returns `[event_id]`
- [ ] Tested

---

### TASK 3.4 — Ticket export (performer-keyed)

**Priority**: P1
**Estimate**: M
**Dependencies**: 3.1, 3.2

**Description**
Wrap `/uploader/tickets/export/{performer_id}` with full pagination and parsing.

**Acceptance criteria**
- [ ] `export_tickets(performer_id, event_id)` generator yields all `Ticket` records
- [ ] Streams pages, does not buffer entire result set
- [ ] Maps response into typed `Ticket` model
- [ ] Handles in_hand_date being null (per docs, always null currently)
- [ ] Tested

---

### TASK 3.5 — Ticket export (domain-keyed)

**Priority**: P2
**Estimate**: S
**Dependencies**: 3.4

**Description**
Wrap `/uploader/tickets/export/domain/{domain_id}`.

**Acceptance criteria**
- [ ] `export_tickets_by_domain(domain_id, event_id)` mirrors performer-keyed shape
- [ ] Documented: use this when `performer_id` isn't permanently mapped (3rd-party events)
- [ ] Tested

**Notes**
Doc gap: where does `domain_id` come from? Add `TODO(domain-id-source)` until clarified.

---

### TASK 3.6 — End-to-end inventory walk

**Priority**: P2
**Estimate**: S
**Dependencies**: 3.3, 3.4

**Description**
Convenience helper that walks the full hierarchy: performers → events → tickets.

**Acceptance criteria**
- [ ] `walk_inventory()` generator yields `(performer_id, event_id, ticket)` tuples
- [ ] Configurable filters (specific performer, event, etc.)
- [ ] Concurrency-safe if used in parallel scrapes
- [ ] Tested with mocked client

---

## EPIC 4 — Transfer Lifecycle

> Driver: state-changing operations. Highest risk component.
> Defer until Epic 3 is solid and tested.

---

### TASK 4.1 — Transfer creation (performer-keyed)

**Priority**: P1
**Estimate**: M
**Dependencies**: 3.1

**Description**
Wrap `POST /uploader/tickets/transfer/{performer_id}`. Handle idempotency carefully.

**Acceptance criteria**
- [ ] `create_transfer(performer_id, quantity, recipient_email, ticket_ids)` returns `confirmation_reference`
- [ ] Client-side idempotency key generated and persisted before send
- [ ] On retry: looks up persisted state first, only re-POSTs if no record
- [ ] Validates `len(ticket_ids) == quantity` before sending
- [ ] Tested with mocked client (success + failure paths)

**Notes**
This is the most dangerous endpoint in the project. A blind retry could double-transfer tickets. Spend extra time on the retry/idempotency tests.

---

### TASK 4.2 — Transfer creation (domain-keyed)

**Priority**: P2
**Estimate**: S
**Dependencies**: 4.1

**Description**
Wrap `POST /uploader/tickets/transfer/domain/{domain_id}`.

**Acceptance criteria**
- [ ] Same shape as 4.1 but domain-keyed
- [ ] Shares idempotency machinery
- [ ] Tested

---

### TASK 4.3 — Transfer cancellation

**Priority**: P1
**Estimate**: S
**Dependencies**: 4.1

**Description**
Wrap `DELETE /uploader/tickets/transfers`.

**Acceptance criteria**
- [ ] `cancel_transfer(transfer_id)` returns `confirmation_reference`
- [ ] Idempotent if API treats already-cancelled as success (verify)
- [ ] Tested

**Notes**
Doc gap: behavior of cancelling an already-cancelled or already-completed transfer is not specified.

---

### TASK 4.4 — Transfer status polling

**Priority**: P1
**Estimate**: M
**Dependencies**: 4.1

**Description**
Build the status polling loop with configurable backoff.

**Acceptance criteria**
- [ ] `poll_transfer_status(transfer_id, timeout, backoff)` returns final status
- [ ] Distinguishes terminal states (completed, failed, cancelled) from pending
- [ ] Exponential backoff between polls
- [ ] Total timeout enforced
- [ ] Returns full transfer record at terminal state
- [ ] Tested with mocked client

**Notes**
Doc gap: status enum values are not documented. Build with a permissive set first, then tighten once observed in practice. Document each new value seen.

---

### TASK 4.5 — Resolve `confirmation_reference` vs `transfer_id`

**Priority**: P1
**Estimate**: S
**Dependencies**: 4.1, 4.4

**Description**
The transfer creation response gives `confirmation_reference`. The status endpoint expects `transfer_id`. Determine if these are the same value.

**Acceptance criteria**
- [ ] Empirical test against staging (or dev) confirms relationship
- [ ] Code clearly distinguishes the two if different
- [ ] Mapping persistence layer if they differ
- [ ] Documented in code comments and `seatgeek-migration-guide.md`

**Notes**
Until resolved, this is a blocker for any reliable end-to-end transfer test.

---

### TASK 4.6 — Transfer state machine + persistence

**Priority**: P1
**Estimate**: L
**Dependencies**: 4.1, 4.3, 4.4, 4.5

**Description**
Build the local state machine that tracks every transfer initiated, with audit log.

**Acceptance criteria**
- [ ] States: `INITIATED → PENDING → COMPLETED | FAILED | CANCELLED`
- [ ] Every transition timestamped and persisted
- [ ] Idempotency keys persisted alongside transfer records
- [ ] Audit log: every API call, request body, response, error
- [ ] Query API: list transfers by status, by ticket_id, by recipient
- [ ] Tested with full lifecycle scenarios

**Notes**
Treat this as a small ledger system. State changes must be atomic and durable. Consider using your existing transactional store rather than building from scratch.

---

### TASK 4.7 — Transfer reconciliation job

**Priority**: P2
**Estimate**: M
**Dependencies**: 4.6

**Description**
Periodic job that polls all `PENDING` transfers and updates their state.

**Acceptance criteria**
- [ ] Cron job (configurable cadence, default 5min)
- [ ] Polls all pending transfers in parallel (with concurrency cap)
- [ ] Updates state machine on terminal transitions
- [ ] Alerts on transfers stuck in PENDING > threshold
- [ ] Metrics: transfers_completed, transfers_failed, time_to_completion histogram

---

## EPIC 5 — Cross-Cutting Concerns

---

### TASK 5.1 — Resolve authentication mechanism

**Priority**: P0
**Estimate**: S
**Dependencies**: none

**Description**
The provided docs reference an Authentication section but do not include it. Determine the mechanism for both APIs.

**Acceptance criteria**
- [ ] Mechanism documented (API key, OAuth, mTLS, etc.)
- [ ] Whether Platform API and Ticket Export share credentials
- [ ] Where credentials live (header, query string, etc.)
- [ ] Rotation/expiry behavior
- [ ] Updated in `seatgeek-migration-guide.md`

**Notes**
Pull from `developer.seatgeek.com` directly or contact SeatGeek support. This blocks all integration work.

---

### TASK 5.2 — Resolve rate limit behavior

**Priority**: P1
**Estimate**: S
**Dependencies**: 5.1

**Description**
Determine documented or empirical rate limits for both APIs.

**Acceptance criteria**
- [ ] Per-endpoint limits documented (or "unknown, treat as N/sec")
- [ ] Response headers used to communicate limits documented
- [ ] `Retry-After` semantics documented
- [ ] Client-side rate limiter implemented per API
- [ ] Tested against staging

---

### TASK 5.3 — Observability + metrics

**Priority**: P1
**Estimate**: M
**Dependencies**: 2.1, 3.1

**Description**
Standard metrics and logs for both clients.

**Acceptance criteria**
- [ ] Request latency histogram (per endpoint)
- [ ] Request count (per endpoint, per status code)
- [ ] Sync lag gauge (`now - last_successful_poll_at`)
- [ ] Bulk download size + duration metric
- [ ] Transfer state transition counters
- [ ] Structured logs with correlation IDs
- [ ] Dashboard/runbook for on-call

---

### TASK 5.4 — Schema drift detection

**Priority**: P2
**Estimate**: S
**Dependencies**: 1.5

**Description**
Detect when SeatGeek adds new fields to bulk responses (or any endpoint).

**Acceptance criteria**
- [ ] Parser logs every unknown field encountered (not crashes)
- [ ] Daily report: count of unknown fields per endpoint
- [ ] Alert if new field appears
- [ ] Documented process for incorporating new fields into models

---

### TASK 5.5 — Integration test suite

**Priority**: P1
**Estimate**: L
**Dependencies**: most endpoint wrappers

**Description**
End-to-end integration tests against a staging environment.

**Acceptance criteria**
- [ ] Test fixtures for happy paths per endpoint
- [ ] Pagination tests (single page, many pages, empty)
- [ ] Error case tests (4xx, 5xx)
- [ ] Bulk download → parse → store flow
- [ ] Transfer lifecycle (create → status → cancel)
- [ ] Run nightly in CI

---

### TASK 5.6 — `CLAUDE.md` for the repo

**Priority**: P2
**Estimate**: S
**Dependencies**: 5.1, 5.2

**Description**
Create a `CLAUDE.md` at repo root pinning conventions for Claude Code.

**Acceptance criteria**
- [ ] References to migration guide and backlog (this doc)
- [ ] Auth mechanism documented (after 5.1)
- [ ] Rate limit posture documented (after 5.2)
- [ ] List of known doc gaps so Claude flags rather than fabricates
- [ ] Code conventions: client structure, error types, retry policy
- [ ] Where to add new endpoints

---

## EPIC 6 — Optional / Future

---

### TASK 6.1 — Mobile deep link generator

**Priority**: P3
**Estimate**: S
**Dependencies**: none

**Description**
Helper to generate `seatgeek://` deep links for events, performers, venues, search.

**Acceptance criteria**
- [ ] `deeplink.event(id)`, `deeplink.performer(id)`, `deeplink.venue(id)`, `deeplink.search(q)`
- [ ] Android Intent builder if relevant

---

### TASK 6.2 — Partner attribution wrapper

**Priority**: P3
**Estimate**: S
**Dependencies**: 2.3, 2.4, 2.5

**Description**
Inject `aid`/`rid` partner params into all outbound URLs in responses.

**Acceptance criteria**
- [ ] Configurable per-client `aid`/`rid`
- [ ] Auto-applied to all relevant endpoints
- [ ] URLs in responses (event.url, performer.url, venue.url) confirmed to include params

---

### TASK 6.3 — Recommendation seed orchestrator

**Priority**: P3
**Estimate**: M
**Dependencies**: 2.6

**Description**
Higher-level recommendation flows: combine multiple seeds, blend results, deduplicate.

**Acceptance criteria**
- [ ] Multi-seed recommendations
- [ ] Score-weighted result merging
- [ ] Deduplication
- [ ] Configurable result diversity heuristic

---

## Execution order summary

If starting today, recommended sprint sequencing:

**Sprint 1 (unblock + audit)**
- 5.1 Auth mechanism
- 5.2 Rate limits
- 1.1 Audit `/events` usage
- 1.2 Strategy decision

**Sprint 2 (foundations)**
- 2.1 Platform HTTP client
- 3.1 Ticket Export HTTP client
- 2.2 Pagination helpers
- 3.2 Cursor paginator

**Sprint 3 (bulk migration core)**
- 1.3 Bulk download client
- 1.4 Delta poller
- 1.5 Schema mapping

**Sprint 4 (sync + cutover)**
- 1.6 Sync orchestrator
- 1.7 Begin consumer cutover (parallelizable)
- 5.3 Observability

**Sprint 5 (catalog wrappers)**
- 2.3, 2.4, 2.5 Events/Performers/Venues
- 3.3, 3.4 Inventory + ticket export

**Sprint 6 (transfers)**
- 4.5 Resolve `confirmation_reference` vs `transfer_id` (do this first, blocks the rest)
- 4.1, 4.3, 4.4, 4.6 Transfer lifecycle
- 5.5 Integration tests

**Sprint 7+ (polish)**
- 1.8 Decommission
- 2.6, 2.7, 2.8 Recommendations + taxonomies + geo
- 4.7 Reconciliation
- Epic 6 if needed
