# S4K AXS Reader — Firefox extension

Reads the AXS watch's events with our own browser instead of TicketsData: no credits, no 3-second rule, no daily cap.
AXS's Cloudflare blocks datacenter addresses (a cloud container gets AXS's "Access Info" 403, even from a real headless
browser), so this runs in Firefox on a machine with an ordinary connection.

## How it reads

1. Asks our web service what is due: `POST /api/axs/ext/next` → `axs_watch_next()`. The database chooses the events,
   the number of lanes (`axs_watch_config.ext_lanes`) and the spacing between page opens (`ext_spacing_ms`).
2. Each **lane** is its own Firefox container (`AXS reader 1`, `AXS reader 2`, …). A lane opens the event's public AXS
   page in a background tab of a separate reader window. Its cookies stay in its container, apart from your own
   browsing and any AXS login you have in the default container, and apart from the other lanes.
3. While the page loads, Firefox's `webRequest.filterResponseData` passes each answer to the page unchanged and keeps
   a copy of the ones that look like AXS inventory: seat items (`offers[].items[]`), the price book (`offerPrices`), the
   on-sale state and the event. Nothing is injected into the page. If the event page itself carries no inventory,
   the reader follows its "Buy Tickets" link (a plain navigation) once.
4. The tab closes and the copies go to `POST /api/axs/ext/record`. The server (`core/axs_ext_doc.py`) builds the same
   document TicketsData returns and the database settles it (`axs_watch_record_ext()`): listings stored, no credit
   charged, a ledger row marked `extension`.

**Read-only (CLAUDE.md RULE 2).** The extension builds no request to AXS. In its tabs it cancels any non-GET request to
a cart, order, checkout, hold, reserve or payment path. It never adds to a cart, holds or orders. It doesn't answer
Cloudflare challenges or wait in AXS's queue. A blocked or queued page counts as a failed read, and the reader backs
off for a minute; the database holds every reader after three failures out of ten.

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

## Switching the watch over

1. Apply mig `20261125210000_axs_watch_extension_reader.sql`.
2. Set `AXS_EXT_INGEST_SECRET` on the web service. The routes answer 503 while it's unset.
3. Install the extension, enter the secret and press **Start**. It idles until step 4.
4. Hand the reading over to the extension, and let the pace use faster rungs:

   ```sql
   UPDATE public.axs_watch_config SET reader = 'extension', pace_min_every = interval '20 minutes' WHERE id;
   ```

   The TicketsData worker idles from the same moment. To go back:
   `UPDATE public.axs_watch_config SET reader = 'worker', pace_min_every = interval '1 hour' WHERE id;`
5. More lanes (up to 8) or tighter spacing: `UPDATE public.axs_watch_config SET ext_lanes = 3, ext_spacing_ms = 3000 WHERE id;`.
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
