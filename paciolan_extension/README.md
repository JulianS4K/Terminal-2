# eVenue / Paciolan Seat Collector — Chrome extension (MVP)

A Manifest V3 Chrome extension that collects **Paciolan / eVenue** primary
box-office inventory by **reading the rendered seat map** in your real,
logged-in Chrome — normalizing it to the same `section / row / seat_from–seat_to
/ qty` model we use for AXS. Click **“Get seats & upload to Supabase”** and it
scrapes the currently-open sections and uploads them **directly to Supabase**.

We **categorize the source as `paciolan`** (the ticketing platform); *eVenue* is
Paciolan's consumer storefront brand at `<tenant>.evenue.net`
(e.g. `bgsufalcons.evenue.net/event/F26/F01`). The tenant subdomain is stored
per capture.

## Why an extension is the right host

- eVenue is behind a **live purchase flow** with anti-bot protection; a
  `requests`/headless path from a datacenter IP gets 403'd, and our
  environment's network egress policy blocks `evenue.net` outright.
- Your **real residential Chrome** already renders the seat map (with your
  session). We just read the DOM it produced.
- **Zero infra** — no proxy, no headless host.

## RULE 2 — read-only, no exceptions

The extension **only reads the DOM the page already rendered**
(`[data-seat-key]`, `[data-level-section]`). It **never** issues a
POST/PUT/PATCH/DELETE to any `evenue.net` host, never adds to cart, never holds
inventory. `evenue.net` is a `FORBIDDEN_HOST` in `scripts/check_readonly.py`.
The only outbound write is to **our own** ingest endpoint (if you enable it).

## How it works

```
<tenant>.evenue.net/event/<price_type>/<perf>   (real Chrome renders the map)
  │  parse_seatmap.js  — DOM → { sections[], seats[] }  (twin of paciolan_client.py)
  │  content.js        — button → scrape open sections; passive → refresh buffer
  ▼
background.js  — POST straight to Supabase:
  POST <project>.supabase.co/rest/v1/rpc/paciolan_ingest_secure
       headers: apikey + Authorization: Bearer <anon key>
       body:    { p_secret: <ingest secret>, p_payload: {…capture…} }
  ▼
paciolan_ingest_secure(secret, payload)   — validates secret, then →
paciolan_ingest(payload)                  — inserts:
  → paciolan_event/section/seat_snapshots
  → v_paciolan_seat_groups (gaps-and-islands) → v_paciolan_listings
```

The upload goes **directly to Supabase** (no server hop) via the PostgREST RPC.
The public **anon key** is safe to embed; write authority is the **shared
ingest secret** checked by `paciolan_ingest_secure` against the service-only
`paciolan_ingest_config` row — the anon key alone can't write. (An alternate
server-side path, `POST /api/paciolan/ingest` on our app with an
`X-Ingest-Secret` header, also exists for headless/cron use.)

Seat numbers only appear in the DOM **once a section is expanded**, so the map's
top-level per-section availability % is captured on every pass, and the numbered
seats are captured as you open each section (the `MutationObserver` re-captures).

## Data model (matches AXS)

Each available seat → `{ level, section_label, row_label, seat_number, seat_no,
price, seat_type, is_ga, available }`. The server view collapses consecutive
available seats (same `level+section+row+price+seat_type`) into one **“N
together”** block via gaps-and-islands — **a sold/missing seat is the qty
break** — yielding `section / row / seat_from–seat_to / qty` listings, identical
to `v_axs_listings`.

`level` (U/L/CH/BN/S/WC/PD/SC) is stored **split** from `section_label`
(e.g. `16U`, `20A`). `seat_type` ∈ `standard | premium | accessible | ga`
(crown-icon seats = premium/higher tier; WC level = accessible; GA/lettered =
qty-1).

## Load it (unpacked)

1. `chrome://extensions` → **Developer mode** on.
2. **Load unpacked** → select this `paciolan_extension/` folder.
3. Browse to an eVenue event page and open sections; the badge shows the
   available-seat count of the last capture.

Requires Chrome 111+.

## Configure the upload (one time)

Open the popup → **Supabase settings**:

- **Supabase URL** — `https://<project>.supabase.co`
- **Anon (public) key** — the project's `anon` key (public; safe to embed).
  **Never** the `service_role` key.
- **Ingest secret** — the shared secret stored in `paciolan_ingest_config`
  (`update public.paciolan_ingest_config set secret = '…' where id = 1;`).

Then just click **Get seats & upload to Supabase**. The popup reports the new
`snapshot_id` and the seat/section counts.

Capture payload (`p_payload`) shape:

```json
{ "platform": "paciolan", "tenant": "bgsufalcons",
  "event_code": "F26/F01", "source_url": "https://…/event/F26/F01",
  "captured_at": "…",
  "sections": [ { "level": "U", "section_label": "16U",
                  "pct_available": 81.47, "disabled": false } ],
  "seats":    [ { "data_seat_key": "U:16U:19:1", "level": "U",
                  "section_label": "16U", "row_label": "19",
                  "seat_number": "1", "seat_no": 1, "price": 25.0,
                  "seat_type": "premium", "is_ga": false, "available": true } ] }
```

## Files

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest (content scripts, SW, permissions) |
| `parse_seatmap.js` | DOM → normalized `{sections, seats}` (twin of `paciolan_client.py`) |
| `content.js` | reads the map, re-captures on expand/qty change, de-dupes |
| `background.js` | ring-buffer + ship to our ingest URL |
| `popup.html` / `popup.js` | config, status, recent captures, export |

## Server side

- `paciolan_client.py` — server-side twin of `parse_seatmap.js` + the
  pure-Python `group_consecutive()` (unit-tested parity with the SQL view).
- `routers/paciolan.py` — `POST /api/paciolan/ingest` (secret-gated) + read
  routes for `v_paciolan_listings` and section availability.
- `supabase/migrations/20260727190000_paciolan_seat_snapshots_and_views.sql` —
  tables + `paciolan_ingest(jsonb)` SECDEF RPC + the two views. **Applying that
  migration is A1's call** (operator-approved) and sets `PACIOLAN_INGEST_SECRET`.
