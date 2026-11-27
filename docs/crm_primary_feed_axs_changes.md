# AXS changes in the primary feed — notes for CRM consumers

What changed in `/api/v1/subs/primary/events` and `/api/v1/subs/primary/listings` for
`source='axs'` over 2026-11-26/27, what you will see differently, and what is still open.

Nothing in the request contract changed. No field was renamed or removed, and no new field was
added to either response. Every change below is a change in **which rows carry listings** and
**why a row does not**, so the one field worth re-reading your handling of is
`listings_withheld`.

---

## 1. An event's freshness window now follows its own polling band

**Was:** listings were served for a flat 35 minutes after a good read, or until 20 minutes
after the event's next slot, whichever was later.

**Now:** the window is the event's *own* band plus grace, floored at the old 35 minutes:

```
now() < GREATEST(last_good_read + GREATEST(35 min, poll_every_minutes + grace),
                 next_poll_at + grace)
```

**Why it mattered:** events on a 2-hour or 4-hour band were read correctly but their listings
expired after 35 minutes, so the feed withheld data that was perfectly current *for that
event's cadence*. Measured on the switch: AXS events carrying listings went **232 → 328**, and
listing rows **94,930 → 133,207**. `listings_withheld='poll_stale'` fell from **98 to 1**.

**What to expect:** a slow-band event can legitimately present listings with an
`listings_as_of` several hours old. That is correct, not stale data. Use `poll_every_minutes`
on the event row to judge whether `listings_as_of` is reasonable — do not apply a fixed
freshness threshold of your own across all events, because the bands differ by design
(30/60/90 min, 2 h, 4 h, and 1 day for parked events).

> ⚠️ The docstring at the top of `routers/primary_poll_feed.py` still describes the old flat
> 35-minute rule and is now wrong. The behaviour above is what is deployed. That docstring is
> logged as drift to fix; believe this document.

## 2. An event with zero listings is treated as sold out

A read that succeeds and returns no listings at all is now handled the same way as a sold-out
read: the event moves to the slow "no tickets" band instead of being re-read at full speed.

**What to expect:** no change to the shape of the response. These events simply refresh less
often, and `poll_every_minutes` on the row will show the slower band.

## 3. Thin inventory is withheld — `listings_withheld='thin_inventory'`

An event with **fewer than 20 sellable tickets** is now withheld from the listings feed and
parked on a one-per-day read.

- "Sellable" means **reserved seats + general admission, with ADA excluded**. It is
  deliberately *not* "non-GA tickets only": a GA-only show has zero reserved seats by
  definition, and the literal rule would have withheld 12,428 genuinely sellable GA tickets
  across six shows.
- The event **stays in `/primary/events`** with `listings_withheld='thin_inventory'`.
- Its rows are **removed from `/primary/listings`**, and `listing_count`, `listed_quantity`
  and `median_price` on the event row are zeroed.
- The ticket count itself is **not exposed** — there is no `sellable_tickets` field in the
  events response. `thin_inventory` is all you get.

**What to expect:** roughly 10–20 AXS events in this state at any time. Treat it as "too thin
to be worth selling", not as an error and not as sold out.

## 4. No 180-day horizon; selection is soonest-first

The watch no longer drops events beyond a fixed number of days out. Which events are actively
polled is decided by soonest-event-first up to the active ceiling. Events far in the future
appearing in the feed is correct.

## 5. The catalogue grew sharply — `not_polled` is by design

AXS rows in `/primary/events` went from **587 to 920**, almost entirely in the
**catalogue** set: events that are published for discovery but never polled, which carry
`listings_withheld='not_polled'`. That count went **226 → 558** (the daily refill plus the
Opry House venue being added).

**`not_polled` is not a failure.** It means "we know this event exists but are not spending
reads on it". Never alert on it, and never treat its absence of listings as sold out.

---

## The complete set of `listings_withheld` values

Taken from the deployed view, not from memory. `null` means the row is sending listings.

| Value | Meaning | Action |
|---|---|---|
| `null` | Listings are being served for this event | Normal |
| `not_polled` | Catalogue event, never polled by design | Ignore — expected, and the largest bucket |
| `thin_inventory` | Under 20 sellable tickets; listings withheld | Treat as not worth selling |
| `poll_failed` | The last read failed | Transient; the previous capture is kept and only two consecutive failures discard it |
| `poll_stale` | The last good read is outside the event's band + grace | Transient; should be near zero |
| `event_started` | The event has already begun | Terminal |

Current distribution across all sources: `not_polled` 558, sending 379, `thin_inventory` 10,
`poll_failed` 10, `event_started` 3, `poll_stale` 1.

---

## Known issues

### A 3 h 24 m feed outage on 2026-11-27 (resolved)

Between roughly **08:54Z and 12:18Z** no AXS event was read. Cause: **Supabase PostgREST — the
data API — was unreachable** (Cloudflare 522 at the origin, then a PostgREST schema-cache
error on recovery) while the database itself stayed up. The reader retried correctly
throughout; nothing was lost or corrupted.

**Impact on the feed during the window:** event rows stayed served, but `listings_as_of` aged
past each event's band, so affected events reported `listings_withheld='poll_stale'` and
served no listings until their next read landed. The day's read volume came in at roughly
7,200 against a normal ~8,250.

**If you see a cluster of `poll_stale` across many events at once**, that is the signature of
a feed-side outage rather than anything about those events. Keep serving your last known good
data and expect recovery without intervention.

### Open, with no fix applied yet

| Issue | Status |
|---|---|
| No out-of-band liveness alarm on the reader | The outage above ran 3.4 h unnoticed. Any alarm must not route through PostgREST, since that is the component that fails. Operator decision. |
| Database size / retention | 337 GB, and the resource pressure behind the 522. Open P0 (A1-DB-25). |
| Credit cap tightens 2026-12-18 | The monthly pool resets to a cap of ~8,167/day while the configured bands ask ~8,250. Needs either a cap override or a slightly smaller active set. Will show up as reads being refused once reached. |
| `routers/primary_poll_feed.py` docstring | Still documents the pre-change flat 35-minute freshness rule. |

---

## Fixes implemented

| Change | Effect you can see |
|---|---|
| Band-relative freshness | +96 AXS events and +38,000 listing rows served; `poll_stale` 98 → 1 |
| Zero listings = sold out | Empty events stop consuming fast-band reads |
| Thin inventory withheld + parked | New `thin_inventory` reason; those events carry no listings |
| Parked reads outside the daily cap | Parked events keep their once-a-day read without displacing active ones |
| 180-day horizon removed | Far-future events are legitimately present |
| Reader hardened: one failed item no longer abandons its batch | Reads/hour 256 → ~350, matching demand; overdue events 139 → 1 |
| Second reader loop | Queue now drains fully; backlog cleared |
| Parked-read accounting corrected | Internal only — no feed-visible effect |
| Opry House added to the watched venues | Its events appear in the feed |

## Questions

Field-level questions about the two endpoints: see the module docstring in
`routers/primary_poll_feed.py` (noting the freshness caveat above). Anything about why a
specific event is withheld: quote its `event_id` and its `listings_withheld` value.
