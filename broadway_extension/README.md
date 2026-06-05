# Broadway Availability Collector — Chrome extension (D3, MVP)

A Manifest V3 Chrome extension that collects Broadway.com per-performance
inventory by **observing the page's own availability XHR** in your real,
logged-in Chrome — then normalizing it and (optionally) shipping it to Supabase.

This is the "for now" host for the browser-driven collection the
[`docs/broadway-scale-plan.md`](../docs/broadway-scale-plan.md) → *Transport
(2026-05-24)* section calls for. It exists because Broadway.com moved inventory
behind Fastly's JS "Client Challenge" + reCAPTCHA Enterprise, which a
`requests`/Deno path can't pass (see [`docs/broadway-live-testing.md`](../docs/broadway-live-testing.md)).

## Why an extension is the right interim host

- Runs in your **real residential Chrome** → best Fastly/reCAPTCHA reputation
  (datacenter IPs draw harsher defaults).
- The **page itself** solves the Fastly challenge + mints the reCAPTCHA token +
  carries the session CSRF cookie. We don't reproduce any of that.
- **Zero infra** — no Playwright host, no proxies, no servers.

## RULE 2 — read-only, no exceptions

The extension **only tees the RESPONSE** of requests the page already makes. It
**never issues** a POST/PUT/PATCH/DELETE to any broadway.com host, never adds to
cart, never holds inventory. `inject_capture.js` wraps `fetch`/`XMLHttpRequest`
purely to read response bodies; it does not originate requests. The only
outbound write is to **our own** Supabase ingest endpoint (if you enable it).

## How it works

```
checkout.broadway.com/{slug}/{show_id}/{event_id}/sections/
  │  page (real Chrome) solves Fastly challenge + reCAPTCHA, then POSTs
  │  the availability request itself → JSON {data:{tickets:[…]}}
  ▼
inject_capture.js   (MAIN world)  — tees that JSON response, postMessage →
relay.js            (ISOLATED)    — chrome.runtime.sendMessage →
background.js       (service wkr) — parseAvailability() → normalize, redact
                                    cart token, store ring-buffer, ship
popup.html/js                     — status, recent captures, config, export
```

`parse_availability.js` is a faithful JS port of
`BroadwayClient.parse_availability()` in `../broadway_client.py` — same
normalized `TicketBlock` shape, kept in sync.

## Load it (unpacked)

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top-right) on.
3. **Load unpacked** → select this `broadway_extension/` folder.
4. Pin the extension; the toolbar badge shows the block-count of the last capture.

Requires Chrome 111+ (MAIN-world content scripts).

## Use it

- **Passive**: just browse to any `checkout.broadway.com/.../sections/` page.
  The moment the page loads availability, the extension captures it. The badge
  updates and the capture appears in the popup's *Recent* list.
- **Export**: popup → **Export JSON** downloads all buffered captures (full
  normalized snapshots + redacted raw payloads) for offline analysis / loading.
- Buffer holds the latest 100 captures locally (`chrome.storage.local`).

### Capturing more than the default quantity

Each availability response is for one block size (`Quantity`). To collect the
full ladder, change the quantity selector on the page (1, 2, 3, …); each change
triggers a fresh availability XHR that the extension captures and tags with
`requested_quantity`. For price-vs-market RV, one quantity (the default) already
gives the full section/tier/price ladder — multi-quantity is only needed for
exact availability counts.

## Ship to Supabase (optional, off by default)

Until configured, the extension is **local-only** (capture + export). To ship
live, open the popup and set:

- **Ingest URL** — your endpoint, e.g. an edge function
  `https://<project>.supabase.co/functions/v1/broadway-ingest`.
- **Headers (JSON)** — auth for that endpoint, e.g.
  `{"x-ingest-secret":"…"}` (edge fn) or
  `{"apikey":"…","Authorization":"Bearer …"}` (PostgREST RPC).
- **Enabled** — check to start shipping.

POST body shape:

```json
{ "url": "...", "event_id": 1079644, "captured_at": "...",
  "requested_quantity": 2, "ticket_count": 8,
  "snapshot": { ...normalized TicketBlock[]... },
  "payload":  { ...raw availability JSON, cart token redacted... } }
```

### Backend (not yet applied — D3 → A1)

The receiving side is **not built yet**. Recommended minimal ingest:

- Table `broadway_raw_captures(id, captured_at, source_url, event_id,
  requested_quantity, ticket_count, snapshot jsonb, payload jsonb)`.
- A SECDEF RPC or edge function `broadway-ingest` that validates a shared
  ingest secret (header) and inserts the row. Gate per CLAUDE.md §1 hard
  rule 7 (don't rely on platform `verify_jwt` alone).

Capture (extension) is deliberately decoupled from normalization-to-schema so
this works today and the `broadway_listings_snapshots` mapping (see the
corrected `tickets[]` field map in the scale-plan) can land later. **Authoring +
applying that migration is A1's call** (D3 authors, operator approves, A1 applies).

## Data handling

- The raw payload's `bapi_cart_token` (cart/session id) is **redacted** before
  storage or shipping.
- Use an **ingest-scoped** secret/key, never the Supabase `service_role` key.
- Captures are stored locally only; nothing leaves the browser unless you enable
  shipping.

## Next step — autonomous driver (not in this MVP)

Today the extension captures whatever sections pages you visit. To run the full
cadence ladder hands-off, add a background "driver" that pulls due performances
from `broadway_pull_queue` and cycles a worker tab through them in this same
warm context (challenge stays amortized — verified: a warm reload re-fetched
availability with no challenge and an auto-minted reCAPTCHA token). Tracked as a
follow-up; needs the ingest backend first.

## Files

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest (content scripts, SW, permissions) |
| `inject_capture.js` | MAIN world — tees the sections availability XHR |
| `relay.js` | ISOLATED world — postMessage → service worker |
| `parse_availability.js` | JS port of the Python `parse_availability()` |
| `background.js` | normalize, redact, ring-buffer, ship |
| `popup.html` / `popup.js` | status, recent captures, config, export |
