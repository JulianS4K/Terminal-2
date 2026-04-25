# SeatGeek API Migration Guide

> **Audience**: Engineers migrating to a Claude Code + kanban workflow.
> **Scope**: Complete reference for both SeatGeek APIs in the project, with implementation patterns, breaking changes, and known gaps.
> **Date context**: As of April 2026, the Bulk Catalog API is GA and the 10K result cap on `/events` is already in effect.

---

## 1. Executive Summary

You have two distinct SeatGeek APIs to integrate, sharing the base host `https://api.seatgeek.com/2`:

| API | Version | Purpose | Auth scope |
|---|---|---|---|
| **The SeatGeek Platform** | v2 | Public catalog: discover events, venues, performers, recommendations | Public/API key |
| **Ticket Export** | v1 | Private: SeatGeek Primary client inventory + transfers | Primary client credentials |

**The single most urgent migration item** is the Bulk Catalog API cutover. As of January 1, 2026, `GET /events` is capped at 10,000 results. If your existing integration relies on full catalog enumeration via that endpoint, you are already losing data. Move to the bulk download (S3 JSONL) or delta feed pattern.

**Documentation gaps** — the project PDFs do not include:
- Authentication mechanics (referenced in sidebar but not extracted)
- Rate limits
- Webhook/event callbacks (transfer status only available via polling)
- Error response schemas beyond the success cases
- SLA / retry guidance

These should be confirmed against `developer.seatgeek.com` before implementation.

---

## 2. Architecture Overview

```
                    ┌──────────────────────────────────┐
                    │   api.seatgeek.com/2 (host)      │
                    └──────────────┬───────────────────┘
                                   │
              ┌────────────────────┴────────────────────┐
              │                                         │
   ┌──────────▼──────────────┐         ┌────────────────▼─────────────┐
   │  Platform API v2        │         │  Ticket Export API v1        │
   │  (public catalog)       │         │  (Primary client inventory)  │
   │                         │         │                              │
   │  /events                │         │  /uploader/performers        │
   │  /venues                │         │  /uploader/events/{pid}      │
   │  /performers            │         │  /uploader/tickets/export/*  │
   │  /recommendations       │         │  /uploader/tickets/transfer/*│
   │  /taxonomies            │         │  /uploader/tickets/transfers │
   │  /bulk/download_url     │         │                              │
   │  /bulk/deltas/events    │         │                              │
   └─────────────────────────┘         └──────────────────────────────┘
              │                                         │
              ▼                                         ▼
       Read-only discovery                   Inventory + transfer ops
       (high volume, cacheable)              (state-changing, audit trail)
```

### Design implications

- **Two integration surfaces** mean two clients in your codebase. Don't share retry/error policies blindly — the catalog is read-heavy and idempotent; transfers are state-changing and require careful retry semantics.
- **Pagination shapes differ**. Platform API uses `page` + `per_page` integers. Ticket Export API uses opaque cursor-style `page` tokens returned in `links.next`.
- **Schema drift between bulk and old `/events`** is significant — see §5.

---

## 3. Critical Timeline & Breaking Changes

| Date | Event | Action |
|---|---|---|
| Aug 1, 2025 | Bulk Catalog API beta | Optional adoption |
| Oct 6, 2025 | Bulk Catalog API GA | Recommended migration |
| **Jan 1, 2026** | **`/events` capped at 10,000 results** | **Mandatory if you need full catalog** |
| April 2026 (now) | Cap is live | Audit current `/events` usage immediately |

If your application enumerates the full SeatGeek catalog via `/events` for any of: caching, search index population, recommendation training, partner feeds, or analytics — verify whether you are silently truncating results today.

---

## 4. The SeatGeek Platform API (v2) — Deep Reference

### 4.1 Endpoint catalog

#### Events

**`GET /events`** — List events
- All query params combine with AND logic. The `id` param overrides everything else.
- Filters supported: `performers.id`, `performers.slug`, `performers[primary].id`, `venue.{city|id|state|...}` (no `venue.name`), `datetime_utc`, `datetime_local`, `datetime_*.{gt|gte|lt|lte}`, `q`, `id`, `taxonomies.{name|id|parent_id}`, `addons_visible`, `type`
- Numeric filters: `listing_count`, `average_price`, `lowest_price`, `highest_price` with `.gt/.gte/.lt/.lte`

**`GET /events/{eventId}`** — Single event
- Path: `eventId` (integer, required)

**`GET /events/section_info/{eventId}`** — Section/row layout
- Returns `{ sections: { sectionName: [rowName, ...] } }`
- Useful for venue UI rendering

#### Performers

**`GET /performers`** — List performers
- Filters: `slug`, `q`, `id`, `taxonomies.{name|id|parent_id}`
- Default sort: `score.desc`
- Note: geolocation params are **not supported** here

**`GET /performers/{performerId}`** — Single performer

#### Venues

**`GET /venues`** — List venues
- Filters: `city`, `state` (2-letter), `country` (2-letter), `postal_code`, `q`, `id`
- Default sort: `score.desc`

**`GET /venues/{venueId}`** — Single venue

#### Discovery

**`GET /recommendations`** — Recommended events
- Seeds: `performers.id`, `events.id` (one or more, comma-separated)
- Geo: `geoip`, `lat`/`lon`, `postal_code`, `range` (default `200mi`)
- Sorted by affinity score (highest first)
- If a performer is the seed, that performer is excluded from results

**`GET /recommendations/performers`** — Recommended performers
- Same seed semantics as event recommendations
- No geolocation params

**`GET /taxonomies`** — List all taxonomies
- No params; paginated

### 4.2 Cross-cutting query features

| Feature | Params | Default | Notes |
|---|---|---|---|
| Geolocation | `geoip`, `postal_code`, `lat`+`lon`, `range` | `range=30mi` | Not on `/performers` |
| Pagination | `per_page`, `page` | 10 / 1 | 1-indexed |
| Sorting | `sort=field.direction` | varies by resource | Fields: `datetime_local`, `datetime_utc`, `announce_date`, `id`, `score` |
| Partner attribution | `aid`, `rid` | null | Appended to all URLs in response |

### 4.3 Filtering syntax (events only)

```
/events?listing_count.gt=0           # only events with listings
/events?highest_price.lte=20         # max price ≤ $20
/events?datetime_utc.gte=2026-05-01  # on or after May 1
```

### 4.4 Deep links (mobile)

`seatgeek://` URI scheme supports:
- `app` (home), `about`
- `events/{id}`, `performers/{id}`, `venues/{id}`
- `search?q={query}`

On Android, send as Intent.

### 4.5 Response schemas

**Event** (key fields): `id`, `title`, `short_title`, `type`, `datetime_utc`, `datetime_local`, `datetime_tbd`, `time_tbd`, `date_tbd`, `announce_date`, `url`, `score`, `performers[]`, `venue{}`, `taxonomies[]`, `integrated{provider_id, provider_name}`, `visible_until`

**Performer**: `id`, `name`, `short_name`, `slug`, `type`, `image`, `images{huge|large|medium|small}`, `primary`, `score`, `url`

**Venue**: `id`, `name`, `address`, `extended_address`, `city`, `state`, `country`, `postal_code`, `location{lat, lon}`, `score`, `url`

**Taxonomy**: `id`, `name`, `parent_id`

**Recommendation**: `{ performer: {...}, score: number }`

---

## 5. Bulk Catalog API Migration

### 5.1 Why migrate

The legacy pattern of polling `/events` repeatedly to maintain a synced catalog is inefficient and now hard-capped. The Bulk Catalog API offers two complementary modes:

| Mode | Cadence | Best for |
|---|---|---|
| **Bulk download** (S3 JSONL) | Hourly snapshots | Initial sync, full rebuilds, recovery |
| **Delta feed** (`/bulk/deltas/events`) | On-demand polling | Incremental updates between snapshots |

### 5.2 Bulk download flow

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Request presigned URL                                            │
│    GET /2/bulk/download_url?client_id={id}&entity={events|venues|   │
│        performers}                                                  │
│                                                                     │
│ 2. Receive short-lived presigned S3 URL in response                 │
│                                                                     │
│ 3. Download JSONL file directly from S3                             │
│                                                                     │
│ 4. Parse line-by-line, upsert into your store                       │
└─────────────────────────────────────────────────────────────────────┘
```

**Implementation notes:**
- Presigned URLs are short-lived; do not cache them across runs.
- JSONL format means streaming parse is feasible (don't load whole file in memory for large catalogs).
- The S3 bucket itself is locked; access is only via the presigned URL endpoint.

### 5.3 Delta feed flow

```
GET /2/bulk/deltas/events
    ?updated_after=2026-04-25T15:55:00Z
    &page=1
    &page_size=100
    &client_id={clientID}
```

**Hard constraint**: `updated_after` must be a UTC datetime within the **last hour**. This effectively forces hourly-or-faster polling and prevents replay of arbitrary historical windows.

**Implication for design:**
- Persist `last_successful_poll_at` in your sync state.
- If your job is offline for >1 hour, fall back to a fresh bulk download — the delta feed cannot bridge the gap.
- Pagination is via `page`/`page_size` (not cursor).

### 5.4 Schema drift: old `/events` → bulk

This is where most migration bugs will live. Field categories:

#### Events — fields added in bulk format

```
primary_performer_id          venue_id
performer_ids                 taxonomy_id
visibility_start_datetime_utc visibility_end_datetime_utc
visible_at_utc                visible_until_utc
main_event_id                 tags
image (top-level: url,        is_ga
  license, rights_message)    seat_selection_enabled
```

#### Events — fields removed from bulk format

```
access_method        announcements        conditional
description          display_config       game_number
home_game_number     integrated           links
mobile_entry_enabled performer_order      playoffs
relative_url         tdc_pv_id            tdc_pvo_id
venue_config         visible_at           open_domain_id
open_id              general_admission    show_static_map_images
all_in_price_before_checkout              all_in_price_on_event_page
themes
```

#### Venues — fields added

```
created_at_utc    updated_at_utc    status
```

#### Venues — fields removed

```
name_v2          links              passes
display_location access_method      has_upcoming_events
num_upcoming_events                 stats (full object, including event_count)
relative_url
```

#### Performers — fields added

```
event_performer    created_at_utc    updated_at_utc
```

#### Performers — fields removed

```
images (plural)         divisions              links
has_upcoming_events     primary                stats
official_logo           image_attribution      num_upcoming_events
colors                  image_license          location
passes                  tracks                 pattern_url
verified_provider_message
performer_header_style_type
relative_url            image_rights_message   is_event
domain_information
```

### 5.5 Migration risk assessment per field group

**High-risk removals** (likely to break consumers if used):
- `description`, `links`, `relative_url` — common UI display fields
- `general_admission`, `is_ga` — moved/renamed; verify GA detection logic
- `stats`, `num_upcoming_events`, `has_upcoming_events` — aggregate counts, may need to be computed downstream
- `images` (plural) on performers — only `image` (singular) and a top-level `image` object remain

**Useful additions**:
- `*_id` fields (`venue_id`, `performer_ids`, etc.) enable join-friendly schemas without re-querying
- `visibility_*_datetime_utc` enables proper temporal filtering of catalog visibility
- `created_at_utc` / `updated_at_utc` on all three entities enables incremental caching

### 5.6 Recommended migration sequence

1. **Audit**: Grep your codebase for every reference to removed fields. Build a list.
2. **Adapt models**: Introduce a normalization layer between the bulk JSONL and your domain models. Don't let the new field names leak directly into business logic.
3. **Backfill once**: Pull a full bulk download for each entity, populate cleanly.
4. **Switch reads to bulk-derived store**: Cut over consumers from live `/events` calls.
5. **Add delta poll**: Hourly job pulling `/bulk/deltas/events?updated_after={last_run}`.
6. **Add fallback**: If delta poll fails or `last_run` >1h ago, trigger a fresh bulk download.
7. **Decommission old `/events` calls** that are no longer needed.

---

## 6. Ticket Export API (v1) — Deep Reference

### 6.1 Conceptual model

The Ticket Export API exposes inventory the authenticated Primary client owns. The discovery hierarchy is:

```
Performer (or Domain)
   └─> Event
        └─> Ticket
             └─> Transfer (state-changing op)
```

You typically traverse: `GET /uploader/performers` → `GET /uploader/events/{performer_id}` → `GET /uploader/tickets/export/{performer_id}?event_id=...` → optional `POST /uploader/tickets/transfer/{performer_id}`.

For 3rd-party events where `performer_id` isn't permanently mapped, use the domain-keyed variants instead.

### 6.2 Endpoint catalog

#### Discovery

**`GET /uploader/performers`**
- No params
- Returns `{ meta, performer_ids: [int] }`

**`GET /uploader/events/{performer_id}`**
- Path: `performer_id` (integer, required)
- Returns `{ meta, event_ids: [int] }`

#### Export

**`GET /uploader/tickets/export/{performer_id}`**
- Path: `performer_id` (required)
- Query: `event_id` (required), `page` (optional, opaque token)
- Returns `{ meta, links{next}, tickets[] }`

**`GET /uploader/tickets/export/domain/{domain_id}`**
- Path: `domain_id` (required)
- Query: `event_id` (required), `page` (optional)
- Same response shape

#### Transfer lifecycle

**`POST /uploader/tickets/transfer/{performer_id}`**
- Body: `{ quantity: int, recipient_email: string, ticket_ids: [string] }`
- Returns: `{ confirmation_reference: string }`

**`POST /uploader/tickets/transfer/domain/{domain_id}`**
- Same body and response as performer variant

**`DELETE /uploader/tickets/transfers`**
- Body: `{ transfer_id: string }`
- Returns: `{ confirmation_reference: string }`

**`GET /uploader/tickets/transfers/{transfer_id}`**
- Path: `transfer_id` (required)
- Returns `{ ok: int, transfer: { id, status } }`

### 6.3 Ticket schema

```
id                   string   ticket ID
event_id             string   event reference
event_name           string
event_datetime_local string   ISO 8601
event_datetime_utc   string   ISO 8601
venue_name           string
section              string
row                  string
seat_number          string
area_name            string
price                number
in_hand_date         string   currently always null per docs
ticket_url           string   URL to the ticket
token                string   barcode
```

### 6.4 Transfer state machine (inferred)

The docs only define the `status` field as a string, without enumerating values. From the endpoint shapes you can infer at minimum:

```
[created] ──POST /transfer──> [pending] ──> [completed]
                                  │
                                  └──DELETE /transfers──> [cancelled]
```

Confirm exact status strings against live API responses or contact SeatGeek support — these are not in the provided docs.

### 6.5 Implementation patterns

**Pagination loop** (export):
```
def export_all_tickets(performer_id, event_id):
    page = None
    while True:
        params = {"event_id": event_id}
        if page:
            params["page"] = page
        resp = GET(f"/uploader/tickets/export/{performer_id}", params)
        yield from resp["tickets"]
        next_url = resp.get("links", {}).get("next")
        if not next_url:
            break
        page = extract_page_token(next_url)  # opaque, parse from URL
```

**Transfer with confirmation poll**:
```
ref = POST(/uploader/tickets/transfer/{pid}, body)["confirmation_reference"]
# transfer_id is NOT returned directly — confirmation_reference may
# differ from transfer_id; this is a doc gap, verify with API
while True:
    status = GET(/uploader/tickets/transfers/{transfer_id})["transfer"]["status"]
    if status in ("completed", "failed", "cancelled"):
        break
    sleep(backoff)
```

⚠️ **Doc inconsistency to flag**: The transfer creation returns `confirmation_reference`, but the status endpoint expects `transfer_id`. The docs do not clarify whether these are the same value. This needs verification before building the polling loop.

---

## 7. Implementation Patterns (cross-cutting)

### 7.1 Client structure for Claude Code

Suggested package layout (language-agnostic):

```
seatgeek/
├── platform/                    # Public catalog (v2)
│   ├── client.py                # HTTP client, retries, rate limit handling
│   ├── events.py                # Endpoint wrappers
│   ├── venues.py
│   ├── performers.py
│   ├── recommendations.py
│   └── bulk/
│       ├── download.py          # S3 presigned URL flow
│       ├── delta.py             # Delta feed polling
│       └── parser.py            # JSONL streaming parser
├── uploader/                    # Ticket Export (v1)
│   ├── client.py                # Separate client; different auth scope
│   ├── inventory.py             # Performers/events/tickets discovery
│   └── transfers.py             # Transfer lifecycle
├── models/                      # Shared domain models
│   ├── event.py
│   ├── ticket.py
│   └── transfer.py
└── sync/                        # Catalog sync orchestration
    ├── baseline.py              # Bulk download orchestrator
    ├── incremental.py           # Delta poller
    └── state.py                 # last_run tracking, fallback logic
```

### 7.2 Pagination patterns

| API | Mechanism | Termination |
|---|---|---|
| Platform `/events`, `/venues`, etc. | `page` int, `per_page` int | `meta.total` exhausted, or empty page |
| Ticket Export | Opaque `page` token in `links.next` URL | `links.next` absent |
| Bulk delta | `page` + `page_size` ints | `meta.total` exhausted |

Build one paginator helper per mechanism, not a single abstraction — the semantics are different enough that a unified interface gets ugly.

### 7.3 Retry semantics

- **Catalog reads**: Idempotent. Exponential backoff with jitter, retry on 5xx and connection errors.
- **Transfer creation**: NOT idempotent in any documented way. A blind retry could double-transfer. Strategy:
  1. Generate a client-side idempotency key (UUID).
  2. Persist the request before sending.
  3. On retry, first poll for any transfer matching that key (if API supports it — verify) or confirmation reference.
  4. Only re-POST if no record exists.
- **Transfer cancel**: Idempotent if the API treats already-cancelled as success; verify.
- **Status poll**: Idempotent, retry freely.

### 7.4 Error handling

The provided docs only show 200 responses. You'll need to handle (at minimum) the standard set:
- `400` — bad params (e.g., malformed `updated_after`)
- `401` / `403` — auth failures
- `404` — unknown id
- `429` — rate limit (no documented headers; assume `Retry-After`)
- `5xx` — transient server errors

Build a typed error hierarchy so callers can distinguish "user error" (don't retry) from "transient" (do retry).

### 7.5 Observability requirements

For a production integration, instrument:
- Per-endpoint latency histograms
- Sync lag (time since `last_successful_poll`)
- Transfer state transitions (created → completed durations)
- Bulk download size + parse duration
- Schema drift alarms (unknown field in JSONL → log + alert; don't crash)

---

## 8. Open Questions / Documentation Gaps

These should be resolved before or during implementation:

1. **Authentication mechanism** — not in extracted docs. API key? OAuth? Per-API or shared?
2. **Rate limits** — no documented quotas, headers, or backoff guidance.
3. **`confirmation_reference` vs `transfer_id`** — same value or different?
4. **Transfer status enum** — what are the actual string values?
5. **Webhook support** — appears to be polling-only; confirm.
6. **Bulk download file naming / pinning** — can you request a specific snapshot, or always "latest"?
7. **Bulk download size guarantees** — JSONL files for full catalog could be GB-scale; any size hints?
8. **Domain ID origin** — for the `domain/{domain_id}` endpoints, where does this ID come from? Not documented.
9. **Concurrent transfer behavior** — can you have multiple in-flight transfers for the same ticket_id?
10. **`addons_visible=true` shape** — are parking events differentiated by `type` only, or other fields?

---

## 9. Recommended Project Structure for Claude Code

When starting work in Claude Code:

1. **Drop this guide and the kanban backlog into the repo** at `docs/seatgeek/`. Reference them in the system prompt or `CLAUDE.md`.
2. **Establish CLAUDE.md conventions** — pin which client to use for which task, list known doc gaps so Claude doesn't fabricate answers.
3. **Stub the doc gaps explicitly** — e.g., add `# TODO(auth): mechanism not documented in PDFs, confirm with SeatGeek` so Claude flags rather than guesses.
4. **Build narrow, testable units first**:
   - HTTP client with retry policy
   - One paginator per mechanism
   - JSONL streaming parser
   - One end-to-end happy path per API (e.g., list performers → list their events → export 1 page of tickets)
5. **Defer the transfer lifecycle** until the discovery side is solid. Transfers are state-changing and the hardest to test safely.

---

## Appendix A: Endpoint quick reference

### Platform API v2

| Method | Path | Purpose |
|---|---|---|
| GET | `/events` | List events |
| GET | `/events/{eventId}` | Single event |
| GET | `/events/section_info/{eventId}` | Section/row layout |
| GET | `/performers` | List performers |
| GET | `/performers/{performerId}` | Single performer |
| GET | `/venues` | List venues |
| GET | `/venues/{venueId}` | Single venue |
| GET | `/recommendations` | Recommended events |
| GET | `/recommendations/performers` | Recommended performers |
| GET | `/taxonomies` | List taxonomies |
| GET | `/bulk/download_url` | Presigned S3 URL for bulk dump |
| GET | `/bulk/deltas/events` | Incremental event changes |

### Ticket Export API v1

| Method | Path | Purpose |
|---|---|---|
| GET | `/uploader/performers` | Discover performers user has tickets for |
| GET | `/uploader/events/{performer_id}` | Discover events for performer |
| GET | `/uploader/tickets/export/{performer_id}` | Export tickets by performer + event |
| GET | `/uploader/tickets/export/domain/{domain_id}` | Export tickets by domain + event |
| POST | `/uploader/tickets/transfer/{performer_id}` | Create transfer (performer-keyed) |
| POST | `/uploader/tickets/transfer/domain/{domain_id}` | Create transfer (domain-keyed) |
| DELETE | `/uploader/tickets/transfers` | Cancel transfer |
| GET | `/uploader/tickets/transfers/{transfer_id}` | Transfer status |

---

## Appendix B: Glossary

- **Primary client** — A SeatGeek partner with direct ticket inventory (vs. resale).
- **Seed** (recommendations) — The performer or event used as the basis for "give me similar."
- **Slug** — URL-safe identifier for a performer/venue (e.g., `new-york-mets`).
- **Taxonomy** — Hierarchical category (e.g., `sports → mlb → mets`).
- **Domain** — Used in 3rd-party event contexts where performer mapping isn't stable.
- **In-hand date** — When the ticket holder will physically/digitally receive the ticket. Per docs, currently always null.
- **Token** (ticket) — The barcode value.
