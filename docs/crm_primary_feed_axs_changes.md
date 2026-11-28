# AXS changes in the primary feed — notes for CRM consumers

What changed in `/api/v1/subs/primary/events` and `/api/v1/subs/primary/listings` for
`source='axs'` over 2026-11-26/27/28, what you will see differently, and what is still open.

Nothing in the request contract changed. No field was renamed or removed, and no new field was
added to either response. Almost every change below is a change in **which rows carry listings**
and **why a row does not**, so the one field worth re-reading your handling of is
`listings_withheld` — which gained two values on 2026-11-28.

Two changes do go further than that, and both are flagged inline: a listing with
non-contiguous seats is now **split into several rows** (§8), and some events now **leave the
feed entirely** rather than being withheld (§7).

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

## How events join and leave the polled set

One job decides this: `axs_watch_fill_daily`, **03:20 UTC daily**. It also runs on demand. The
active ceiling is **341** events across **51 enabled venues** (29 of them `keep_all`). Every
decision it makes is written to an audit trail with a one-word reason, so any individual
event's fate is answerable.

It runs in five steps, in this order: **retire → refill each venue to its quota → give back
borrowed places → backfill whatever is left → close the run.**

### Leaving, and what you see when it happens

**This is the part that matters most to you**, because leaving the *polled* set is not the
same as leaving the *feed*:

- Retired events are deleted from the polled table, and then the catalogue step immediately
  re-adds the ones still worth listing. Those **reappear in `/primary/events` with
  `listings_withheld='not_polled'`** — still discoverable, just not polled.
- An event that is **dead** (see below) is excluded from the catalogue too, so it **disappears
  from the feed entirely**.

So the normal transition you will observe is `sending → not_polled`, not a disappearance.
Treat a vanished `event_id` as "cancelled or finished", and `not_polled` as "still real, not
being polled".

Reasons an event is retired, exactly as they appear in the audit trail:

| Reason | Meaning |
|---|---|
| `not_in_export` | No longer in the AXS export at all |
| `gone` | The export marks it gone or removed |
| `not_axs_sold` | The export says AXS does not sell it (overridden for venues flagged `trust_axs_sold`) |
| `not_kept` | Fails the keep rules — category, title or venue |
| `starts_soon` | Starts within **6 hours**. We stop polling before doors |
| `beyond_horizon` | Past the date ceiling — **currently disabled**, so this never fires |
| `over_or_cancelled` | Cancelled, or near-term with nothing to sell (below) |
| `not_on_sale` | The last read says it is not on sale, or its on-sale has not arrived and no listings exist yet |
| `not_axs_or_expired` | **Three consecutive** reads said AXS does not sell it, or that it is over |
| `over_target_events` | A borrowed place handed back because the list was over its ceiling |

**`over_or_cancelled` has two distinct triggers**, and the asymmetry is deliberate:

1. **Cancelled** — the read says cancelled. Retires at **any date**.
2. **Nothing to sell** — AXS says no tickets are available, or a successful read returns zero
   listings. Retires **only within 7 days of the event**. A far-future event with nothing on
   sale has usually not released inventory yet, so retiring it would be wrong.

This check reads two sources: the event's own last read *and* the read ledger, which outlives
the event being taken off the list. Without the second, the same job's backfill would hand a
just-retired event its place straight back.

### Joining

An event becomes eligible when **all** of these hold:

- It is in the AXS export, at an **enabled** venue, not marked gone or removed.
- The export says AXS sells it — or its venue is flagged `trust_axs_sold`.
- It starts **more than 6 hours** from now, and on or after the configured start date.
- It has a ticket URL and a parseable local date.
- It passes the keep rules: a non-empty title, **not** matching the absolute exclude list, and
  then either its venue is `keep_all`, or it matches the keep rules for its category (sports
  titles have their own list).
- Its on-sale moment is not still more than **3 days** out.
- No read in the last **7 days** said it was not on sale.
- Fewer than **3** reads in the ledger (which keeps 14 days) said not-AXS or expired.
- It is not dead — so an event the retire step just removed cannot come straight back.

Eligible events are then taken **soonest-event-first**: each venue is filled to its own quota
first, and any places still free go to the remaining eligible events regardless of venue.
There is no preference for bigger venues or higher prices — only date order.

### Two rules worth knowing because they look like bugs

**A parked event does not hold a place.** An event parked for thin inventory or sold-out is on
a once-a-day read and does *not* count against the 341 ceiling, so a fresh event is pulled in
to replace it. This is why the total watched count drifts above 341 and will keep drifting.
Counting the total against 341 and concluding something is broken is the single easiest
mistake to make here. The 6-hour not-on-sale pin is **not** parked — that event is waiting for
an on-sale that can land at any hour, so it is still being watched properly and does hold its
place.

**Quota places outrank borrowed ones.** A venue over its quota holds a "borrowed" place. When
the list goes over its ceiling, borrowed places are returned furthest-event-first. At a
`keep_all` venue the event stays on as catalogue; elsewhere it is dropped.

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
| `wrong_performance` | **New 2026-11-28.** The event is serving another performance's seats and has been parked | Do not sell. See §6 |
| `paused` | **New 2026-11-28.** An operator pause that a read cannot undo | Do not sell. See §6 |

**One reason you will never see, because those events leave the feed entirely:**
`non_transferable`. An event whose tickets cannot be transferred is removed from *both*
endpoints rather than published with an explanation — see §7.

Current distribution, AXS only, 2026-11-28 11:2xZ: `not_polled` 473, sending 337,
`thin_inventory` 9, `poll_failed` 3, `wrong_performance` 2, `paused` 1, `poll_stale` 0.
825 AXS events in the feed, 148,060 listing rows.

---

## 6. Some events serve another performance's seats — `listings_withheld='wrong_performance'`

**This is the most important change here, because it is the one that could have sold the wrong
seats.** Three AXS events were proved to be publishing inventory belonging to a *different
performance*. All three are upstream TicketsData defects: our reads are faithful, the body we
are handed is wrong.

| What we asked for | What we were served |
|---|---|
| Trans-Siberian Orchestra, 2026-12-11 **19:30** | the **15:00** performance's seats |
| Disney *Descendants* 2026-12-02 | **for KING + COUNTRY**'s seats, 2026-12-03 |
| PBR 2026-12-20 | the 2026-12-19 performance's seats |

The proof is not inference. The two TSO events return **1,672 seats each with an intersection
of 1,672 and none unique to either**, and 292 listings under *both* carry TicketsData's own fee
label `Service Fee - 261211_300 TSO` — where `261211` is the date and `300` is the 3:00 PM show.

**Detection** uses AXS's own internal event id, which the body carries. Two of our events
sharing one internal id at the same venue is a collision. (The id is scoped per venue/box
office, not globally, so the comparison is venue-scoped — an earlier cross-venue match was a
false positive.)

**What happens on a catch:** the event's listings are deleted, it is pinned to a once-a-day
read, `listings_withheld` becomes `wrong_performance`, and its place returns to the fill.

**What to expect:** a handful at most, currently 2. Treat `wrong_performance` as *do not sell*,
not as sold out — the event is real and its seats exist, we just cannot tell you which ones.
Note that in a colliding pair **one side is usually correct**, so you may see one of two
same-day events sending normally while the other is withheld. That is intended.

`paused` is the manual equivalent: an operator pause that survives a read. Same handling.

## 7. Non-transferable events leave the feed entirely

An event whose tickets cannot be transferred is not inventory we can sell, so it is removed
from **both** `/primary/events` and `/primary/listings` — not published with a withheld reason.
If an `event_id` you were receiving disappears, this is one of the reasons why.

The rule is deliberately about the **whole event**, not individual offers: an event qualifies
only when its own description says so, or when *every* delivery method is labelled
non-transferable. A first, broader version of this rule retired 27 events in about 40 minutes —
nearly all Red Rocks, and including a Houston Rockets game — before it was narrowed; those were
restored.

Separately, where only *some* offers on an otherwise fine event are non-transferable, just
those listings are dropped. The event keeps sending.

## 8. A listing with a gap in its seats is now split

`primary_poll_split_event` used to split a listing only when its quantity exceeded its order
limit. A listing whose seats were **not contiguous** but fitted inside the order limit was
published as one run of seats that cannot actually be bought together.

Example the operator caught: section 113 row P published as `seat_low 10, seat_high 14,
quantity 3` — reading as three adjacent seats. The actual seats were 10, 13 and 14.

**What changed:** such a listing is now split into its contiguous blocks. Listing rows rose
136,548 → 143,213 on the rebuild (74,693 pieces). The pieces carry the existing `-1`, `-2`
suffix convention on `listing_id`, which the contract already used.

**What to expect:** more rows, each one genuinely buyable as a unit. A row's `seats` array is
now always contiguous.

---

## A caveat on price, fee and tax — read this before summing them

`price + fee + tax = all_in_price` holds for **every primary listing** and for most resale
ones, but **not for about 1.9% of resale rows**, where the parts sum high by up to ~9%.

**Use `all_in_price`.** It is AXS's own total and is correct in every case measured, including
against a real AXS checkout (Pechanga Arena, resale: 2 × $52.80 + $26.92 fee = $132.52, matching
our stored row to the cent). Do not reconstruct the total from the parts.

The cause is upstream shape, not arithmetic: for resale, `pricing.face` is **tax-inclusive**
while for primary it is **net**, and the tax field double-counts the part already inside `face`.
Three attempts to correct the mapping on 2026-11-28 each made the contract worse on a wider
sample and were reverted; the field is back to its long-standing behaviour while raw bodies from
more venues are gathered. Tracked in `tests/sql/axs_watch` s39, which documents the gap
deliberately rather than asserting it away.

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

### A 29-minute read outage on 2026-11-28 (resolved, self-inflicted)

Between **23:38Z and 00:28Z** no AXS event was read. Cause was ours, not upstream: two audit
INSERTs added that evening were malformed — one omitted a NOT NULL column, one used a value the
CHECK constraint did not allow. Each raised *inside* the settle function, so the acknowledgement
returned 400, the read was never acked, and the lane retried in a loop.

**Impact on the feed:** the same signature as any read gap — `listings_as_of` aged and affected
events reported `poll_stale` until their next read landed. Nothing was lost or corrupted.

Fixed the same night, and the test suite gained a scenario asserting the settle can write its
own audit rows, which is the check whose absence let both through.

### A Postgres restart loop, 2026-11-24 to 2026-11-28 (resolved)

**409 cron jobs** were killed by `server restarted` between 11-24 18:09 and 11-28 04:33, in
bursts every 15–20 minutes. Each restart dropped in-flight reads, so the polling backlog could
not drain: overdue events peaked at **241** and the median overdue read passed 26 minutes,
briefly breaching the freshness tripwire and pushing `poll_stale` to 40.

Resolved by a CPU/RAM upgrade on 2026-11-28. Postgres has since run **408 minutes with zero
restart-killed jobs**, the read rate went 227/h → 358/h against demand of 352/h, and **overdue
fell to 1 with `poll_stale` at 0** — the lane now meets its configured cadence for the first
time. If you saw a cluster of `poll_stale` across many events in that window, that is the cause.

### Open, with no fix applied yet

| Issue | Status |
|---|---|
| No out-of-band liveness alarm on the reader | The outage above ran 3.4 h unnoticed. Any alarm must not route through PostgREST, since that is the component that fails. Operator decision. |
| Database size / retention | 334 GB. Open P0 (A1-DB-25). The 2026-11-28 upgrade raised the ceiling but did not shrink the data. |
| `price + fee + tax` on resale | Does not equal `all_in_price` on ~1.9% of resale rows. **Use `all_in_price`** — see the caveat above. Three fix attempts on 2026-11-28 each measured worse and were reverted. |
| pg_net request-id reuse | Stale queue rows can match another service's HTTP response, so a consumer may ingest the wrong data silently. Affects several queues, not this feed's reads. Reported (`bot_chat` 7749). |
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
| Knockdown Center added (2026-11-28) | Its AXS-ticketed events appear; a non-AXS event at the same venue correctly does not |
| Wrong-performance detection + parking | New `wrong_performance` reason; 2 events withheld rather than selling another show's seats (§6) |
| Durable operator pause | New `paused` reason, which a poll cannot undo (§6) |
| Non-transferable events removed | Those events leave both endpoints entirely (§7) |
| Splitter breaks on seat gaps | ~6,700 more listing rows, each genuinely buyable as a unit (§8) |
| Restart loop ended by a CPU/RAM upgrade | overdue 241 → 1, `poll_stale` 40 → 0, reads 227/h → 358/h |

## Questions

Field-level questions about the two endpoints: see the module docstring in
`routers/primary_poll_feed.py` (noting the freshness caveat above). Anything about why a
specific event is withheld: quote its `event_id` and its `listings_withheld` value.
