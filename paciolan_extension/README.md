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

## Raw capture — format-drift safety net

Paciolan/eVenue markup changes over time, and a parser that's right today can go
silently blind after a layout change. So every **upload** capture also carries
the **whole rendered page** (`document.documentElement.outerHTML`, capped ~2 MB)
plus every inline JSON blob (`ld+json` / `application/json` / `__NEXT_DATA__`).
The server keeps them in `paciolan_raw_captures`, so:

- **Nothing is lost to a format change** — history can be re-parsed server-side
  from the stored raw after the parser is updated.
- **Drift is a loud signal, not a silent zero** — a capture that renders (raw
  present) but yields **0 sections and 0 seats** is flagged `format_drift`
  (purple ⚑ badge / verdict, a *Drift / 24h* card on the terminal health screen,
  a `drift` row badge). That's the tell the parser needs a look — the raw is
  already safe.

Raw is attached **only on uploads** (button / autonomous driver), never the
local buffer, so `chrome.storage` never holds megabytes; the server prunes raw
to 14 days. The secret-gated ingest now accepts a raw-only capture (the drift
case) — it's only rejected when there's *neither* parsed rows *nor* raw.

## Export-health indicator

A successful HTTP 200 isn't the same as a *good* export, so the popup shows a
verdict after each upload (and colors the toolbar badge to match):

- 🟢 **Export good** — uploaded, with available seats **and** the event
  name/date/venue needed to map to EVO/SeatGeek/StubHub.
- 🟠 **Uploaded, thin** — either **0 available seats** (you probably didn't
  expand a section) or **missing event info** (won't map yet).
- 🔴 **Upload failed** — with the error/status.

The verdict lists a checklist — *uploaded ✓/✗ · N available seats · event info
(name/date/venue)* — so you can see exactly what's missing. The toolbar badge is
green / amber / red accordingly (grey = a passive buffer, not an upload).

## Autonomous mode (SQL-driven pull loop)

Beyond the manual button, the extension can run **hands-off** — the browser twin
of how TicketsData fetches AXS. eVenue can't be fetched server-side (it's a
`FORBIDDEN_HOST`, egress-blocked, and anti-bot), so instead of Postgres calling
out, **SQL keeps a queue and this Chrome polls it**:

```
pg_cron  paciolan_enqueue_due()   auto-seeds captured events → due targets →
                                  paciolan_pull_queue        (every 5 min)
browser  paciolan_next_pull(sec)  claims one due row (FOR UPDATE SKIP LOCKED)
         → opens a fresh background tab at the eVenue URL, scrapes, uploads,
         paciolan_pull_resolve(…) marks it done, tab closes  (open+close per pull)
pg_cron  paciolan_pull_sweep()    re-opens stuck rows (<3 tries), expires the
                                  rest, prunes 7d                 (hourly)
```

Turn it on with the **“Autonomous auto-pull (SQL-driven)”** toggle in the popup.
While armed, this Chrome polls the queue on a `chrome.alarms` timer (~1 min) and
refreshes due events on its own; the popup shows the last poll and live queue
depth (`pending / in-flight / done-24h`). The toggle is the safety — autonomous
= it opens tabs by itself, so nothing runs until you arm it. Leave one
logged-in Chrome open with the toggle on.

**Self-refreshing watchlist:** any event you scrape once (manual button) is
auto-seeded into `paciolan_pull_targets` and kept fresh — no manual upkeep. A1
can also seed/adjust targets directly (`pull_interval_min`, `active`).

**Per-instance tracking:** each Chrome gets a stable `driver_id` and an operator
**name** (set it under *This Chrome instance* in the popup). Every poll/resolve
is attributed to that instance and a heartbeat keeps it visible while idle, so
`v_paciolan_drivers` (the **Chrome instances** panel on the terminal PACIOLAN
tab) shows per-instance extraction + issues — online, pulls/24h, ok/empty/error,
and last error — i.e. which instance is working and which is stuck.

The `next_pull` / `resolve` / `stats` RPCs are anon-granted but **secret-gated**
by the same `paciolan_ingest_config` secret as ingest — the public anon key
alone can't claim work or write. `SKIP LOCKED` means two Chromes never
double-pull the same URL. **RULE 2 holds:** the queue only *names* eVenue URLs;
the browser (you, in your own session) opens them read-only.

*Note:* seat numbers only render once a section is expanded, so an autonomous
pull captures the per-section availability % on every pass; deep per-seat
capture stays a manual, section-expanded click for now.

Migration: `supabase/migrations/20260727220000_paciolan_pull_queue.sql`
(**A1 applies**; needs the ingest secret already set).

## Updates (git pull — no Web Store)

The extension is installed **unpacked from this repo**, so it is not on the
Chrome Web Store and Chrome will not auto-update it. To update:

```bash
./paciolan_extension/update.sh      # git pull --ff-only
# then chrome://extensions → Reload ↻ on the extension
```

The popup footer shows the **loaded version** and a **Check for updates** button.
That check compares your loaded `manifest.json` version to the latest version
published to Supabase — which CI sets on every push to `main` that changes the
extension (`.github/workflows/paciolan-extension-release.yml` →
`paciolan_extension_publish`, secret-gated; the popup reads
`paciolan_extension_latest`, public). When a newer version exists the footer
says *"update available → vX.Y.Z · git pull + reload."*

*(CI publish needs three repo secrets — `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`PACIOLAN_INGEST_SECRET`; the workflow no-ops if they're unset. Nothing here uses
the `service_role` key.)*

## Files

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest (content scripts, SW, permissions) |
| `update.sh` | `git pull` helper (self-hosted update path) |
| `parse_seatmap.js` | DOM → normalized `{sections, seats}` (twin of `paciolan_client.py`) |
| `content.js` | reads the map, re-captures on expand/qty change, de-dupes |
| `background.js` | ring-buffer + ship to Supabase **+ the autonomous `chrome.alarms` driver** (poll queue → open/scrape/upload/resolve/close) |
| `popup.html` / `popup.js` | config, status, verdict, recent, export, **auto-pull toggle + queue depth** |

## Server side

- `paciolan_client.py` — server-side twin of `parse_seatmap.js` + the
  pure-Python `group_consecutive()` (unit-tested parity with the SQL view).
- `routers/paciolan.py` — `POST /api/paciolan/ingest` (secret-gated) + read
  routes for `v_paciolan_listings` and section availability.
- `supabase/migrations/20260727190000_paciolan_seat_snapshots_and_views.sql` —
  tables + `paciolan_ingest(jsonb)` SECDEF RPC + the two views. **Applying that
  migration is A1's call** (operator-approved) and sets `PACIOLAN_INGEST_SECRET`.
