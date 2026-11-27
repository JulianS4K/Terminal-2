# S4K AXS Reader — Firefox extension

Reads the AXS watch's events with our own browser instead of TicketsData: no credits, no 3-second rule, no daily cap.
AXS's Cloudflare blocks datacenter addresses (a cloud container gets AXS's "Access Info" 403, even from a real headless
browser), so this runs in Firefox on a machine with an ordinary connection.

## How it reads

The flow is the one TicketsData's own AXS reads recorded (`axs_event_snapshots.raw`: `source_url`, `routes_captured`,
`timings`): the event page (`www.axs.com/events/<id>`) → its "Buy Tickets" link to the shop → **Queue-it**, which
nearly every AXS event sits behind (`queue_it: true`) and an ordinary visit passes straight through (`rt=Safetynet`) →
the seat page on `tix.axs.com`, whose script asks for `session`, `pre-flow`, `start-flow`, `offer_search` and
`inventory_v4`. Landing takes 12–15 s and the inventory about 28 s more, so **a read takes about 45 s**; the page timeout
is 90 s.

1. Asks our web service what is due: `POST /api/axs/ext/next` → `axs_watch_next()`. The database chooses the events,
   the number of lanes (`axs_watch_config.ext_lanes`) and the spacing between page opens (`ext_spacing_ms`).
2. Each **lane** is its own Firefox container (`AXS reader 1`, `AXS reader 2`, …). A lane opens the event's public AXS
   page in a background tab of a separate reader window. Its cookies stay in its container, apart from your own
   browsing and any AXS login you have in the default container, and apart from the other lanes.
3. While the page loads, Firefox's `webRequest.filterResponseData` passes each answer to the page unchanged and keeps
   a copy of the ones that look like AXS inventory: seat items (`offer_search`: `offers[].items[]`), the price book and
   fee table (`inventory_v4`: `offerPrices`, `fees`), and the on-sale state with its delivery methods (`start-flow`). A
   GA event's `offer_search` is empty (`{"offers": []}`); its places are the price levels' own `availability`. Nothing is injected into the page. If the event page itself carries no inventory,
   the reader follows its "Buy Tickets" link (a plain navigation) once.
4. The tab closes and the copies go to `POST /api/axs/ext/record`. The server (`core/axs_ext_doc.py`) builds the same
   document TicketsData returns, pricing each seat as TicketsData did (the fee table's fixed, range-lookup and
   percentage components: $80 GA at Knockdown Center = $21.29 in fees, $101.29 all in), taking the order limits from
   `offerPrices[].min/max`, typing a seat with `disabilityTypes` as ACCESSIBLE and noting an offer whose only delivery is
   non-transferable, so the feed's existing rules withhold both. The database settles it (`axs_watch_record_ext()`): listings stored, no credit
   charged, a ledger row marked `extension`.

**Read-only (CLAUDE.md RULE 2).** The extension builds no request to AXS. In its tabs it cancels any non-GET request to
a cart, order, checkout, hold, reserve or payment path. It never adds to a cart, holds or orders. It doesn't answer
Cloudflare challenges or wait in AXS's queue: the pass-through above is a redirect, but a visit still held on Queue-it
after 20 s has met the waiting room and is given up. A blocked or queued page counts as a failed read, and the reader
backs off for a minute; the database holds every reader after three failures out of ten.

## Install (Firefox 140 or later)

The extension isn't signed, so:

- **Try it:** `about:debugging` → *This Firefox* → *Load Temporary Add-on…* → pick `manifest.json`. It stays loaded
  until Firefox restarts.
- **Keep it:** sign it as an unlisted add-on (`web-ext sign --channel unlisted` with an AMO API key), or use Firefox
  Developer Edition / Nightly with `xpinstall.signatures.required = false`.

Then open the toolbar button:

- **Server**: `https://vibepass-storefront-test.onrender.com` (the default).
- **Ingest secret**: the value of `AXS_EXT_INGEST_SECRET` on that web service.
- **Test connection** should answer `ok · reader=…`. Then **Start**.

Leave the reader window open. Firefox slows timers in background tabs, but the reads are network-bound and keep
going. **Reset lane containers** drops the lanes' cookies; they're made again, empty, on the next read.

## Test one event (before switching anything over)

No migration, secret or server is needed for this.

1. Load the extension (above). Open its page from the toolbar button.
2. Under **Test one event**, paste a public AXS event link (`https://www.axs.com/events/<id>/...`) and press
   **Read it**. Lane 1's container opens the page in the reader window. Expect about 45 s.
3. The result shows the outcome (`loaded`, `blocked`, `queue`, `timeout`), how many answers were kept, whether
   seats and a price book came in, where the tab ended up, and any write requests the guard cancelled.
4. Press **Download capture**, then see what our server would store from it:

   ```
   python scripts/axs_ext_check.py ~/Downloads/axs-capture-<id>.json
   ```

   It prints every listing with its face, fees and all-in, plus the order limits, and sends nothing anywhere. Fees
   should match AXS's own checkout figure for the same seat.

Try a reserved-seat event and a GA event. If a read comes back `loaded` with no seats and no price book, the
capture file shows which answers the page did get, and that's what to send back for a fix.

## Switching the watch over

1. Apply mig `20261127020000_axs_watch_extension_reader.sql`.
2. Set `AXS_EXT_INGEST_SECRET` on the web service. The routes answer 503 while it's unset.
3. Install the extension, enter the secret and press **Start**. It idles until step 4.
4. Hand the reading over to the extension:

   ```sql
   UPDATE public.axs_watch_config SET reader = 'extension', cadence_scale_floor = 0.5 WHERE id;
   ```

   Cadence is the watch's proximity bands (`axs_watch_cadence`) times `cadence_scale`. The hourly pacer sets that
   scale itself from the measured capacity, never below `cadence_scale_floor` (1.0 by default, so never faster than the
   bands). Lowering the floor to 0.5 lets it read up to twice as often once it has measured the extension's lanes. Don't
   set `cadence_scale` by hand: the pacer rewrites it every hour.

   The TicketsData worker idles from the same moment. To go back:
   `UPDATE public.axs_watch_config SET reader = 'worker', cadence_scale_floor = 1.0 WHERE id;`
5. Lanes and spacing: 4 lanes at ~45 s a read make ~300 reads an hour, the 305-event watch about hourly. More (up to
   8) or tighter: `UPDATE public.axs_watch_config SET ext_lanes = 6, ext_spacing_ms = 3000 WHERE id;`.
   The extension picks both up on its next ask.
6. More events: the watch's list is set by venue quotas (`axs_watch_venue`, `axs_watch_fill()`). With no credits to
   spend, those quotas can rise.

## Files

| File | Does |
|---|---|
| `manifest.json` | MV2, Firefox only (containers and `filterResponseData` are Firefox APIs) |
| `config.js` | settings in `storage.local`, the install's worker id |
| `doc.js` | shape checks: when a page's inventory is in |
| `capture.js` | the copies of the page's answers, the write guard |
| `lanes.js` | containers, the reader window, one event's read |
| `api.js` | calls to our service (the only POSTs the extension makes) |
| `background.js` | the scheduler: ask, hand out to lanes, send back |
| `popup.html` / `popup.js` | settings, start/stop, status, recent reads |
