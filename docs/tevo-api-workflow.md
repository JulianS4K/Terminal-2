# TEvo API — workflow reference

both agents read first when working on anything that touches TEvo. distilled from the official docs julian dropped in 2026-05-07. keep cave-man.

## Auth

Every request signed with HMAC-SHA256.

```
GET https://api.ticketevolution.com/v9/<path>?<sorted-params>
Headers:
  X-Token: <token>
  X-Signature: base64(HMAC-SHA256(secret, "GET <host><path>?<sorted-params>"))
  Accept: application/vnd.ticketevolution.api+json; version=9
```

Param sorting is alphabetical, URL-encoded. We have this in `chat` edge fn (`hmacSha256Base64` + `canonicalQuery`) and `collect-listings`.

Creds live in Supabase `settings` table keys `tevo_token` / `tevo_secret`.

## Five core entities

| Entity | What | Identifier |
|--------|------|------------|
| **Performer** | Bands, teams, individuals, comedians, annual events (Kentucky Derby), plays (Hamilton). | `id` (numeric) + `slug` (e.g. `arizona-diamondbacks`) |
| **Venue** | Physical location (MSG, Fenway). | `id` + `slug` (e.g. `chase-field`) |
| **Configuration** | A specific stage layout for a venue (baseball vs concert vs custom tour). Includes seating chart image URLs (medium / large). | `id` |
| **Event** | One performance at one venue at one specific time (`occurs_at_local`). Has `performances[]` array — each entry has `primary` flag. **`primary=true` = HOME team / headliner.** | `id` (7+ digits, e.g. 3346855) |
| **Ticket Group** | Adjacent seats from one supplier at one price. `available_quantity`, `splits[]`, `wholesale_price`, `retail_price`, etc. | `id` |

## Endpoints we use

### Search

| Endpoint | When to use |
|----------|-------------|
| `GET /v9/searches/suggestions?q=X&entities=events,performers,venues&fuzzy=true&limit=N` | **BEST for ambiguous user input.** Multi-entity, fuzzy (handles typos). Returns suggestions grouped by type. Used in chat fn `comprehensive_search` tool + auto-fired pre-LLM when entity extractor draws blank. |
| `GET /v9/search?q=X&types=...&order_by_popularity=true` | Alternative comprehensive search with full result objects + `_score`. We don't currently use this; suggestions endpoint is lighter and sufficient. |
| `GET /v9/events?q=X` | Keyword event-name search. Fuzzy. Use for narrow event-name lookups. |
| `GET /v9/events?performer_id=X&order_by=events.occurs_at_local%20ASC` | **Canonical** when performer_id is known. No keyword. Returns clean upcoming list. Used by `eventsForPerformer()` + auto-fired into `RESOLVED_CONTEXT` system block. |
| `GET /v9/events?venue_id=X` | Events at one venue. `eventsAtVenue()` + chat fn tool `events_at_venue`. |
| `GET /v9/events?lat=X&lon=Y&within=N` | Events within N miles of lat/lon. `eventsNear()` + chat fn tool `events_near`. |

### Detail

| Endpoint | Returns |
|----------|---------|
| `GET /v9/performers/{slug-or-id}` | Single performer with `venue` (home venue), `category`, `slug`, popularity, `upcoming_events { first, last }`. |
| `GET /v9/venues/{slug-or-id}` | Single venue with address (incl `latitude` / `longitude` / `time_zone`), `upcoming_events`. |
| `GET /v9/events/{id}` | Single event with venue, performances (with `primary` flag), `configuration` (incl seating chart URLs). |
| `GET /v9/categories?name=NBA` | Category lookup by name. We use this in `seed-home-venues`. |

### Listings

`GET /v9/ticket_groups?event_id=X` — broker-side, returns ALL listings including `office.brokerage` info. Used by `chat` (S4K-only filter applied client-side) and `collect-listings` (raw inventory snapshots).

`GET /v9/listings?event_id=X` — same shape, retail-side framing in TEvo docs. We use `ticket_groups` because we need brokerage info to flag S4K-owned (`brokerage.id === 1768`).

**No server-side filters.** Section / zone / price / quantity filtering is all client-side after fetching.

## Ticket Group properties to know

From `/v9/ticket_groups`. Surface to retail customers when relevant:

| Field | Meaning | Bot behavior |
|-------|---------|--------------|
| `section` | "100", "Floor 1", "VIP", "GA", "SRO" | Resolve via curated zones first, system zones as fallback. |
| `row` | Row identifier. Lower row = closer. | Sort upgrades by `rowRank()`. |
| `available_quantity` | How many tickets in this group. | Filter by `min_qty`. |
| `splits` | Array of allowed sale quantities. Order MUST match. | Use when user asks "3 tickets" — check if 3 in splits. |
| `retail_price` | Customer-facing per-ticket price. | What we surface. |
| `wholesale_price` | Broker cost. Order must be ≥ this. | Broker-only. NEVER surface to retail. |
| `format` | `Physical` / `Eticket` / `TM_mobile` / `Flash_seats` / `Paperless` / `Guest_list` | Translate: TM_mobile/Flash_seats → "Mobile transfer", Eticket → "eTicket (PDF)", Physical → "FedEx", Paperless → "Gift card", Guest_list → "Guest list". |
| `view_type` | `Full` / `Obstructed` / `Partially Obstructed` / `Possibly Obstructed` | **WARN customer** if Obstructed or Partially Obstructed. |
| `in_hand` | Bool. False = seller doesn't yet physically have tickets. | If false AND event ≤ 48 hours away: WARN. |
| `in_hand_on` | Date when seller expects tickets. | Show only when in_hand=false. |
| `public_notes` | Seller's important caveats. | Surface verbatim if short (<140 chars). |
| `featured` | Bool. Seller promoted. | Sort featured-first within zone. |
| `instant_delivery` | Bool. Tickets delivered within minutes. | Mention as "instant delivery" when true. |
| `wheelchair` | Bool. ADA seats. | Mention if user asked about accessibility. |
| `office.brokerage.id` | The supplier's brokerage. **S4K = 1768.** | Filter to S4K-only by default in retail. |
| `type` | `event` (real seats) or `parking` (parking pass). | Filter out non-event by default. |

## Common workflow patterns

### "Knicks tonight"
1. Entity extractor matches `knicks` → performer_id 16303 (chat_aliases).
2. Chat fn auto-fires `eventsForPerformer(16303)` — returns next 12 Knicks events with venue + performances + primary flag.
3. Inject as `RESOLVED_CONTEXT` block in system prompt.
4. Bot picks today's event from the list, calls `get_event_zones(event_id)`.
5. Returns zones with prices, asks qty + budget.

### "Wallen this weekend" (concert, no chat_alias)
1. Entity extractor returns no performer match.
2. Chat fn auto-fires `comprehensiveSuggest(query="wallen")` — fuzzy returns Morgan Wallen tour events.
3. Inject as `COMPREHENSIVE_SEARCH_CONTEXT`.
4. Bot picks an event_id and proceeds.

### "Shows in Vegas tonight"
1. Bot calls `events_near(lat, lon, within)` — geolocation event list.
2. Bot returns numbered list, asks "which one?"

### "What's at MSG this week"
1. Bot calls `comprehensive_search("MSG")` to resolve venue_id=896.
2. Bot calls `events_at_venue(venue_id=896)` for the upcoming list.

### Buying flow inside a single event
1. `get_event_zones(event_id)` → returns price-tier buckets.
2. User picks zone + qty + budget.
3. `find_listings(event_id, zone, max_price, min_qty)` → returns up to 6 listings with view_type / in_hand / public_notes / format / featured flag.
4. If user has current seats: `find_better_seats(event_id, current_section, current_row)` → upgrades + adjacent.

## Invariants we rely on

1. **event_id is 7+ digits.** Anything smaller is a model hallucination — `validateEventId()` rejects in chat fn.
2. **`performances[].primary === true`** identifies the home team / headliner. Used to compute `home_or_away`.
3. **`occurs_at_local`** is the local-time string with offset (e.g. `2026-05-08T19:00:00-04:00`). Format-print this; don't UTC-convert for display.
4. **Retail layer (chat) NEVER sees `wholesale_price` or `office.brokerage.name`.** Only event_id flows; broker fields stripped at tool-output time.
5. Caching: `/v9/ticket_groups` results cached in Postgres for 90s — same `event_id` requested again within window returns cached. Saves duplicate fetches across get_event_zones + find_listings.

## Pagination + conditionals

- All list endpoints take `page` + `per_page` (max 100).
- Most accept `order_by=<table>.<col>%20ASC|DESC`.
- `If-Modified-Since` headers supported on most endpoints — we don't use yet.

## Sandbox vs production

- Production: `https://api.ticketevolution.com`
- Sandbox: `https://api.sandbox.ticketevolution.com`

We're on production. Sandbox would be for test orders without live inventory.

## Where in our code

| Concern | File |
|---------|------|
| HMAC signing + canonical query | `supabase/functions/chat/index.ts` (cowork), `supabase/functions/collect-listings/index.ts` (cowork) |
| Search tools (comprehensive, near, at_venue, etc.) | `supabase/functions/chat/index.ts` (cowork) |
| Listings ingest | `supabase/functions/collect-listings/index.ts` (cowork) |
| Cron + daily collector | `supabase/migrations/20260507000001_chat_rate_limit_and_cron.sql` + `cron.job` table |
| Brokerage filter (S4K = 1768) | `chat` edge fn `filterRetailGroups()` |

## Open questions for code agent

- `team_xref.espn_display_name` often null — backfill from TEvo's `/v9/performers/{id}` `name` field.
- `/v9/categories` query for MLS keeps failing — try `name=MLS`, `name=Soccer`, `name=Major League Soccer`. Or pull `/v9/categories?per_page=200` once and grep.
- Can we use `/v9/configurations/{id}` seating chart URLs for the broker UI? Direct image embed would be cheap visual.
