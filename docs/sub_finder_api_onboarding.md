# S4K Sub Finder API — onboarding

> **Doc version:** not hand-numbered — this file's history is its git history (`git log -- docs/sub_finder_api_onboarding.md`). Do not edit this line (README *Doc-writing rules* §5).

For the CRM team. You send us orders that need a substitute ("sub"); we pull fresh listings, and you read back the best replacement tickets for each order. If you are allowed to, you can also ask us to buy the replacement (on EVO, or on GoTickets while S4K has that turned on) and then follow that purchase until the seller confirms or rejects it.

Code: `routers/subs_api.py` · SQL: migrations `20261112000000` (buy follow-up) and `20261112010000` (the API) · operator switches: [§9](#9-for-s4k-operators-switching-it-on).

**Contents:** [What changed for you](#what-changed-for-you) · [At a glance](#at-a-glance-what-flows-each-way) · [The one thing to build](#the-one-thing-we-ask-you-to-build-a-needs-sub-checkbox) · [1 Quick start](#1-quick-start-5-minutes) · [2 Access](#2-access-keys-limits-errors) · [3 Submit orders](#3-submit-orders) · [4 Read results](#4-read-results) · [5 The order object](#5-the-order-object) · [6 Keep in sync](#6-keep-in-sync) · [6a Notes](#6a-notes-on-an-order) · [6b Balances](#6b-balances) · [6c What we bought](#6c-what-we-bought) · [6d Loss limits](#6d-the-automatic-buys-loss-limits) · [6e Audit log](#6e-the-audit-log) · [6f Your limits](#6f-your-own-limits-on-rebates-and-buys) · [6g MLB schedule](#6g-the-mlb-schedule-with-ticket-links) · [6h Ticketmaster events](#6h-ticketmasters-events-and-the-sites-they-pair-to) · [6i AXS and SeatGeek events](#6i-axs-events-and-seatgeek-primary-events) · [6j Marketplace ids](#6j-the-same-event-on-every-marketplace) · [7 Buy a cover](#7-buy-a-cover) · [7a Offer a sub (GoTickets)](#7a-offer-a-sub-to-a-gotickets-customer) · [8 Rules and limits](#8-how-matching-works-and-what-it-does-not-do) · [9 Operators](#9-for-s4k-operators-switching-it-on) · [10 Troubleshooting](#10-troubleshooting)

## Keeping this guide current

This guide is served by the API itself, so you never work from an old copy:

- **`GET /api/v1/subs/ping`** carries `"docs": {"version": "3f9c2a71b0de", "updated": null, "url": "/api/v1/subs/docs"}`. `version` is a fingerprint of the guide as served to you: it changes when, and only when, the guide changes. Keep the one you last read; when `docs.version` differs, fetch the guide again. Compare it for equality only (it is not a number, and `updated` is always null).
- **`GET /api/v1/subs/docs`** answers `{"version", "updated", "format": "markdown", "markdown": "..."}` with your key. Add `?format=md` for the Markdown itself (`text/markdown`, the version in the `X-Doc-Version` header).

- **The same ping carries `news`**: the newest entries of the list below, each as `{"date", "text"}`, newest first. So a ping tells you what changed, not only that something did. Nothing is pushed to you and nothing needs a reply: read it, and act on what applies.

A ping once a day, or at your service's start, is enough.

## What changed for you

What you need to know or do, newest first. `GET /ping` returns the ten newest of these under `news`.

- **2026-11-24** New: every event of `GET /axs/watch` and `GET /primary/events` carries the same event's id on each marketplace: `ticketmaster_event_id`, `seatgeek_event_id`, `stubhub_event_id`, `vivid_event_id`, `tickpick_event_id`, `gotickets_event_id`, `axs_event_id` and `aq_short_event_id`, as the other event feeds do (section 6j). An AXS watch event is paired by its AXS id, so it can have ids before it has an EVO match. `GET /axs/watch/listings` and `GET /primary/listings` are unchanged: join them to their event by `source` and `event_id`.
- **2026-11-24** New: `GET /axs/watch` and `GET /axs/watch/listings`: the AXS watch as its own call, the 200 upcoming events AXS sells at ten venues and their listings, refilled nightly as events pass (section 6k). The same rows as `/primary/events?source=axs` and `/primary/listings?source=axs`.
- **2026-11-24** New: `axs` is a source of `GET /primary/events` and `GET /primary/listings`: 200 upcoming events AXS sells at ten venues, with their listings (section 6k). The list refills itself nightly as events pass.
- **2026-11-24** Fixed on `GET /primary/listings` for `sitickets`: a general admission block (the HSBC SVNS ones) now carries `general_admission: true`; it has `GA` for a row and no seat numbers, which is how it is sold. `max_per_order` on those blocks is now the largest quantity one order may take (10); it read 1. Seated blocks are unchanged, and now say `general_admission: false`.
- **2026-11-24** New: `GET /health` reports each box office we read: `box_office_sitickets` and `box_office_timberwolves`, with how many events are being sent and how many could not be read. A box office that stops answering us reads `degraded` or `down` there, and counts in the overall `status` (section 2).
- **2026-11-24** Changed: a box-office event's listings stop at its start time. From tip-off, `GET /primary/events` shows it with `listings_available: false` and `listings_withheld: "event_started"`, and it has no rows in `GET /primary/listings`. Red Bull New York and the other Sports Illustrated Stadium events now carry `start_utc` and `timezone` too.
- **2026-11-24** New: six more team box offices are sources of `GET /primary/events` and `GET /primary/listings`: `nccourage`, `denversummit`, `reign`, `bostonlegacy`, `sounders` and `northcarolinafc`. None has single matches on sale yet, so they return no rows today; their matches appear by themselves when they go on sale (section 6k).
- **2026-11-23** Changed: box-office events are now read on their own cadence, not all every 30 minutes, and at a random 10-minute slot inside it. `GET /primary/events` gains `poll_every_minutes` (10 on the day of the event, 30 up to 2 days away or 5 for a Friday, Saturday or Sunday event, 60 otherwise), `next_poll_at` (the slot drawn for the next read), `median_price` and `listed_quantity`. Listings stay available between reads; `as_of` on a listing and `listings_as_of` on an event say how old they are (section 6k).
- **2026-11-23** Changed on `GET /primary/listings`: `price` now means the same for every source, the price before fees and tax, and each listing carries `fee`, `tax` and `all_in_price` with `price` + `fee` + `tax` = `all_in_price`. Until now a Timberwolves `price` was the all-in total rounded to the dollar (55 where the ticket is 42.00 + 8.40 fees + 5.05 tax = 55.45); it is now 42.00 with `all_in_price` 55.45 and `price_estimated: true`, because that site shows only the total and we split it. SI Tickets gains `tax` and the per-order `order_fee`, and its `fee` is now the one inside the total. New fields are at the end of each row (section 6k).
- **2026-11-23** New: `GET /primary/events` and `GET /primary/listings` carry the box offices we poll ourselves every 30 minutes: SI Tickets at Sports Illustrated Stadium (Red Bull New York, HSBC SVNS) with every seat block, its seats, the quantities a buyer may take, the order limit and the price; and the Timberwolves' home games with the team's own and resale seat blocks. Only the newest pull is served, and listings only for an event polled successfully in the last 35 minutes: otherwise the event says `listings_available: false` and why. Obstructed-view listings are never sent (section 6k).
- **2026-11-22** Every event feed now carries the same event's id on each marketplace: `/tm/events`, `/axs/events`, `/seatgeek/events` and `/mlb/events` rows gain `xmap_tevo_event_id`, `ticketmaster_event_id`, `seatgeek_event_id`, `stubhub_event_id`, `vivid_event_id`, `tickpick_event_id`, `gotickets_event_id`, `axs_event_id` and `aq_short_event_id` (null where we hold no pairing), and `/mlb/schedule` gains `tickpick_event_id` and `axs_event_id`. Nothing was renamed or removed (section 6j).
- **2026-11-22** Our matching gates, in one place. Every cover carries `gate` and `label`: 1 `Index` and 2 `S4KTrading` keep the buyer in the same section and the same or a better row (1 at a profit, 2 at up to 200% of the sale); 3 `Index offer subs` and 4 `offer subs s4ktrading` move the buyer to another section in the same zone; 5 `Index Down offer subs` and 6 `Down offer subs S4KTrading` move the buyer up to 5 rows back. Gates 3 to 6 need the buyer's agreement and are never bought by us. New: `GET /gates` returns the table as JSON (section 8).
- **2026-11-22** New: `GET /axs/events` lists AXS's upcoming events, by default the 48,000 AXS itself sells (`primary=false` for the ones another ticketer sells), and `GET /seatgeek/events` lists the events where SeatGeek is the primary ticketer, from the SeatGeek events we hold. Both carry the EVO event each matched, take `q`, `since`, dates and state, and have no prices (section 6i).
- **2026-11-22** `GET /tm/events` now says who really sells each event: `source` and `tm_primary` (Ticketmaster itself, a resale page, or another ticketer), with `official_seller`, `transactable`, `hot_event`, Ticketmaster's own page ids (`legacy_event_id`, `legacy_venue_id`), promoters, a seat map link and outlets. Filter with `primary=true` or `source=`. About a third of the events are resale pages. These fields are null for an event until Ticketmaster's daily bulk file has been loaded for it; the first load is being switched on now.
- **2026-11-22** Ticketmaster changes will show within about a day: the catalogue is moving to Ticketmaster's daily bulk file, so `GET /tm/changes` and `since` on `GET /tm/events` pick up a cancellation or a moved time the day after. Until the first file is loaded, the once-a-week reads announced earlier today continue. Detail such as the ticket limit is read only for events Ticketmaster itself sells (section 6h).
- **2026-11-21** Ticketmaster events are now read again on a schedule, so `GET /tm/changes` fills and `since` on `GET /tm/events` picks up changes. Until this day an event was read once and a later cancellation was not seen (section 6h).
- **2026-11-21** New: `GET /tm/changes` lists each change to a Ticketmaster event's status, date, start time or venue, with the old and the new value, so you can catch a cancellation without reading the catalogue again. Page with `after_id`. The same changes now move `changed_at`, so `since` on `GET /tm/events` returns a changed event too. Logging starts today (section 6h).
- **2026-11-21** New: `GET /tm/events?q=` searches the catalogue by name: every word must be in the event's name, its teams or performers, its venue or its city. Case and accents do not matter. It combines with the date, segment, state and status filters, so you need not keep a full copy to look an event up.
- **2026-11-21** `GET /tm/markets` no longer answers 502 on a wide request. Asking for every pairing at once, or for a month, used to run past our time limit; the whole feed now answers in a few seconds, so you can read it page by page with no date filter. If you split your reads into small date windows to get round this, you no longer need to. Same columns, same values.
- **2026-11-18** `GET /tm/events` now carries everything Ticketmaster returns for an event. Buying: the ticket limit as a number (`ticket_limit_count`, with `ticket_limit_numbers` when presale and public limits differ), `safetix` (tickets move by Ticketmaster transfer only), `all_in_pricing` and when the public sale ends. Also end, access and doors times, notes, teams or performers with their links, add-ons such as parking, and the venue's address, coordinates, market, box office, parking and accessibility notes. `safetix=true` filters; `detail=false` returns the smaller core row (section 6h).
- **2026-11-18** New: `GET /tm/markets` lists, for each Ticketmaster event we have matched to an EVO event, the id of the same event on SeatGeek, Vivid Seats, TickPick, StubHub, GoTickets and AXS where we can pair it. One row per event, `site=` to ask for one site, `since` for what changed (section 6h).
- **2026-11-18** New: `GET /tm/events` lists Ticketmaster's own catalogue of upcoming US events (name, date and time, venue, status, on-sale and presale dates, the Ticketmaster page) with the EVO event each one matched. It is filling in now: Sports first, then Music and Arts & Theatre, about 13 weeks ahead. No prices or inventory (section 6h).
- **2026-11-18** `GET /results` now returns only orders still in play, one row per order: a Need-to-Sub alert while its 15-minute timer is running, a need2buy order (S4K's PED list is part of need2buy now) while its item is open and the event day has not passed, and any order with a purchase or an offer you are following. Older lookups and repeats of the same order are gone from it. An alert leaves the feed when its timer runs out, so drop it then; its lookup can still be read with `GET /orders/{n}`. Each row carries `n2s` with the timer. `scope=all` returns every lookup as before (section 6).
- **2026-11-18** The buy key is now registered to the address `crm.s4kcs.com` resolves to, so from that server it can buy, offer and set limits; nothing more is needed from you if that is where your calls come from. From any other address it answers 403 `forbidden` on every call, `/ping` included. If your first call with it is refused, call `GET /ping` with the read key from the same server and send us the `your_ip` it returns (section 2).
- **2026-11-17** Accessible seats are never swapped with ordinary seats. A sold seat in an accessible (ADA / wheelchair) section or row, such as `204LWC`, `103WC` or row `WC`, is covered only by accessible seats, and an ordinary seat is never covered by accessible ones. This is a block, not a review: such a listing is not returned as a cover, and a buy or offer for one is refused. The `wheelchair_row` flag is gone (section 8).
- **2026-11-17** MLB schedule upgrades. Clubs are now re-read every 2 hours (minor league every 4), so new ticket links and time changes show up the same day. Each game row now also carries its `promotions` (giveaways, theme nights, ticket offers) and `removed` (true once the club drops the game from its schedule). Two new endpoints: `GET /mlb/changes` lists every change we detect (a link going live, a moved date or time, an on-sale date, a removed game, a new giveaway or stadium event), and `GET /mlb/events` lists the concerts and other live events at the ballparks, each mapped to its EVO event where we can (section 6g).
- **2026-11-16** `GET /mlb/schedule` can now list minor league games too: add `level=milb` for every Triple-A, Double-A, High-A and Single-A club, or one level (`aaa`, `aa`, `high_a`, `single_a`), or `level=all`. Without `level` you get MLB only, as before. Each row now also carries `level`, `league_name` and `parent_org` (the MLB club the team is affiliated with). Only some minor league clubs have released their 2027 ticket links so far; the rest fill in as they do (section 6g).
- **2026-11-16** `GET /mlb/schedule` now gives each game its SeatGeek event: `sg_event_id` and `sg_url`, matched straight from MLB's schedule (same teams on the same date, and on a doubleheader day the same start time). Nearly every 2027 game has one (section 6g).
- **2026-11-16** New: `GET /mlb/schedule` lists every MLB club's games (this season and next) with the club's direct ticket link for each game, its start time, venue, and the EVO event and terminal event it maps to. It fills itself in as clubs release times and links, and `since` returns only what changed (section 6g).
- **2026-11-16** You set your own limits on rebates and buys, each as a percent of the sale total: `rebate_max_pct` (0 to 100) and `buy_max_cost_pct` (1 to 1000), with a default and a value per marketplace. Read them with `GET /settings/limits`, set them with `PUT /settings/limits` using the buy key (section 6f). Our earlier note said a rebate could be at most 50% of the sale: that figure was ours, not yours, and is removed. Until you set a limit, a rebate may be up to the sale total, and a buy is held only by S4K's ceilings of $750 a buy and $4,000 a day.
- **2026-11-16** New: `GET /health` tells you whether S4K's side is working: one overall `status` (`ok`, `degraded` or `down`) and one entry for each thing you depend on, with when it last ran (our read of your Need-to-Sub feed, our copy of your order book, your lookups, buying, offers, balances). Poll it from your monitoring; it always answers 200, so read `status` (section 2).
- **2026-11-16** The base URL is now `https://s4k-subs-api-siyb.onrender.com/api/v1/subs`: a host that serves only this API and is always on. Please switch to it. The earlier address keeps answering with the same keys and data (section 2).
- **2026-11-16** If a key leaks or a buy goes wrong, email both tu@s4kent.com and julian@s4kent.com (section 2).
- **2026-11-16** The key of 2026-11-13 is revoked. Two keys replace it: one that only reads, one that may also buy and offer. The buy key cannot buy, offer or change settings until S4K registers the address it calls from: call `GET /ping` with it from the server that will buy, and send us the `your_ip` it returns (section 2).
- **2026-11-16** Only an item whose `status` is exactly `need2buy` starts a lookup, and automatic buying is off: a buy happens only when you ask for it, or when a GoTickets customer accepts seats you offered. `POST .../buy` and `POST .../offer-sub` take an `Idempotency-Key`, and `GET /audit` lists every buy, offer and limit change asked with your keys (sections 6e, 7, 7a).

## At a glance: what flows each way

Three things move between the CRM and S4K. Nothing is pushed to you: every answer is something you read.

**1. What we read from you, with no call from you**

| What | How often | What we take |
|---|---|---|
| Your Need-to-Sub feed (`GET /api/v1/n2s/items` on the CRM) | every 30 seconds, the first 250 items | each item's order number, marketplace, event, seats, quantity, price, status and notes. An item whose `status` is `need2buy` starts a lookup by itself ([the feed](#the-other-way-in-label-the-item-need2buy-in-your-n2s-feed)) |
| Your order book (our mirror of it) | about every 10 minutes | each order's event, seats, quantity, sale price and status. This is what an order is checked against before anything is bought |

**2. What you send us** (your key, `/api/v1/subs`)

| Call | What it does |
|---|---|
| `POST /orders/{n}/needs-sub` | start a lookup for one order (the checkbox) |
| `POST /jobs` | start a lookup for several orders ([§3](#3-submit-orders)) |
| `POST /orders/{n}/notes` | put a note on an order ([§6a](#6a-notes-on-an-order)) |
| `POST /orders/{n}/buy` | buy a cover we quoted ([§7](#7-buy-a-cover)) |
| `POST /orders/{n}/offer-sub` | offer replacement seats to a GoTickets customer ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)) |
| `PUT /settings/auto-buy-loss` | set how big a loss the automatic buy may take on `need2buy` orders, by marketplace ([§6d](#6d-the-automatic-buys-loss-limits)) |
| `PUT /settings/limits` | set your own ceilings on a rebate and on the cost of a buy you ask for, as a percent of the sale, by marketplace ([§6f](#6f-your-own-limits-on-rebates-and-buys)) |

**3. What you read from us**

| Read | What it carries |
|---|---|
| `GET /orders/{n}`, `GET /jobs/{id}`, `GET /results` | the order object ([§5](#5-the-order-object)): state, recommended action, gate, label and flags, the covers with their links, what was searched, the purchase (`buy`), the GoTickets offer (`sub_offer`), your feed decision's outcome (`feed_decision`) |
| `GET /results?updated_since=` | the orders still in play as a sync feed, one row per order: what changed since your cursor ([§6](#6-keep-in-sync)) |
| `GET /balances` | S4K's EVO balances and GoTickets gift cards, read hourly ([§6b](#6b-balances)) |
| `GET /buys?updated_since=` | **every purchase S4K placed to cover an order, by either buyer, as one sync feed** ([§6c](#6c-what-we-bought)) |
| `GET /autobuys?updated_since=` | only the purchases S4K's Need-to-Sub auto-buyer placed (the same items as in `/buys`; kept for callers already using it) |
| `GET /settings/auto-buy-loss` | the automatic buy's loss limits as they stand ([§6d](#6d-the-automatic-buys-loss-limits)) |
| `GET /settings/limits` | your own limits on rebates and buys as they stand ([§6f](#6f-your-own-limits-on-rebates-and-buys)) |
| `GET /audit?since=` | every buy, offer and limit change asked with your keys, with the address each call came from ([§6e](#6e-the-audit-log)) |
| `GET /mlb/schedule?since=` | every MLB club's games (and, with `level`, every minor league club's), this season and next: teams, venue, start time, the club's direct ticket link, and the EVO event and terminal event each game maps to. Not tied to an order; it fills itself in as clubs release times and links ([§6g](#6g-the-mlb-schedule-with-ticket-links)) |
| `GET /tm/events?since=` | Ticketmaster's catalogue of upcoming US and Canadian events with the EVO event each matched ([§6h](#6h-ticketmasters-events-and-the-sites-they-pair-to)) |
| `GET /tm/markets?since=` | for each matched Ticketmaster event, its id on SeatGeek, Vivid Seats, TickPick, StubHub, GoTickets and AXS ([§6h](#6h-ticketmasters-events-and-the-sites-they-pair-to)) |
| `GET /tm/changes?after_id=` | each change to a Ticketmaster event's status, date, start time or venue, with the old and the new value ([§6h](#6h-ticketmasters-events-and-the-sites-they-pair-to)) |
| `GET /axs/events?since=` | AXS's upcoming events, by default the ones AXS itself sells, with the EVO event each matched ([§6i](#6i-axs-events-and-seatgeek-primary-events)) |
| `GET /seatgeek/events?since=` | the upcoming events where SeatGeek is the primary ticketer, with the EVO event each matched ([§6i](#6i-axs-events-and-seatgeek-primary-events)) |
| `GET /gates` | our six matching gates: the seats rule, the cost rule, whether the buyer must agree and what we do with each ([§8](#8-how-matching-works-and-what-it-does-not-do)) |
| `GET /ping`, `GET /docs` | your scopes, the address we see you call from, the limits your buys are held to, and this guide with its version |
| `GET /health` | whether S4K's side is working: one overall status and one for each thing you depend on, with when it last ran ([§2](#2-access-keys-limits-errors)) |

**Two buyers, one feed.** S4K has two buyers: this API's (the automatic one-to-one buy, your buy call or feed decision, or seats a GoTickets customer accepted) and S4K's separate Need-to-Sub auto-buyer. `GET /buys` lists what both bought, each item marked with its `buyer`. A purchase made through this API is also on the order's `buy`. The same sale is never bought by both.

## The one thing we ask you to build: a "Needs sub" checkbox

Put one checkbox on the order screen, labelled **Needs sub**. When an agent ticks it, the CRM tells us, and we do the rest. That single alert is the whole integration; everything else in this document is optional.

**When the box is ticked, make one call.** The order number goes in the URL and no body is needed, because we already mirror the CRM's order books:

```bash
curl -s -X POST -H "X-API-Key: $KEY" $HOST/api/v1/subs/orders/<order_number>/needs-sub
```

It answers at once (**202**) with a job header. The search itself runs on our side.

**Then show the agent what we found.** Read the order back by its number and render it next to the checkbox:

```bash
curl -s -H "X-API-Key: $KEY" $HOST/api/v1/subs/orders/<order_number>
```

| The order's `state` | Show the agent |
|---|---|
| `pending` | "Looking for a sub..." — read again in 10 seconds (answers take 20 seconds to 3 minutes) |
| `cover` | the `best` cover: market, section, row, quantity, price, profit or loss, and its `link`. A **Buy** button if `best.buyable` is true and your key may buy ([§7](#7-buy-a-cover)) |
| `no_cover` | "No sub found" — offer **Check again** (the same alert call) |
| `unmapped` | "Event not recognised" — S4K needs to map it; tell us the order number |

**How we would like to be alerted — please follow these.**

1. **Alert at the moment the order is flagged, one order per call.** Do not save them up for a nightly batch: listings sell, and a sub found three hours late is usually gone.
2. **Alert only orders that actually need a sub.** Do not send the whole book. Each alert pulls live listings from several marketplaces.
3. **Send the order number, nothing else.** If the order is too new for our mirror (the call answers 404 `not_found`), retry once after a minute; only then send the CRM's row as the JSON body, unchanged.
4. **Ticking twice is safe.** A repeat within 10 minutes returns the same lookup. After that, a new tick is a fresh search — which is exactly what **Check again** should do.
5. **Unticking needs no call.** We hold nothing open: an alert is a one-off search, not a subscription. Just stop reading the order.
6. **Do not poll every order forever.** Read an order while its `state` is `pending`, or while a purchase on it is unconfirmed. For anything broader use the sync feed ([§6](#6-keep-in-sync)).
7. **If the CRM auto-creates N2S items from failed-order alerts,** fire the same call when it does, so the agent opens the order to a sub already found.

That is all the CRM has to build: one checkbox, one call when it is ticked, one read to show the answer.

## The other way in: label the item `need2buy` in your N2S feed

You do not have to call us to start a lookup. We already read your Need-to-Sub feed (`GET /api/v1/n2s/items` on the CRM) every 30 seconds. **Label an item `need2buy` there and we start the sub finder on it by ourselves**, within about a minute and a half (mig `20261113160000`). One feed, one poller.

- **The label.** Set the item's `status` to `need2buy`, exactly: that one value in that one field (mig `20261116000000`, as you asked). No other spelling and no other field starts a lookup.
- **What we take from the item.** Its `order_number` and `marketplace`. Everything else we look up ourselves, as for an alert. `seller_notes` becomes the order's `notes`.
- **Reading the answer** is unchanged: `GET /api/v1/subs/orders/{order_number}` or the sync feed, with your key. Your API has no write surface, so we write nothing back to the CRM.
- **It takes the whole path**, the automatic buy included while automatic buying is on (it is off for now, see `auto_buy_off` in §8) ([§8](#8-how-matching-works-and-what-it-does-not-do)). An item in the feed that is not labelled `need2buy` is left to the Need-to-Sub pipeline as before.
- **It stays live until one of two things is seen** (mig `20261113190000`): **the label is removed** in your feed (taken off, changed to any other status, or the item resolved: `closed_reason` `label_removed`), or **the order's status changes on its marketplace** (cancelled, delivered or rejected, read from the marketplace's own order feed: `order_cancelled` / `order_fulfilled` / `order_rejected`). `closed_by_s4k` means S4K closed the lookup by hand (a test or a dry run). Until then we keep pulling listings and re-matching it every round, except while a GoTickets offer is waiting on the customer. Labelling it again starts a fresh lookup.
- The checkbox call above still works and can be used alongside the label.

### What we ask you to add to your N2S feed

The label starts a lookup. With the additions below, the rest of the conversation could run through the same feed, and you would not have to call us for anything except reading the answer. They are in the order that helps most. **Group B is switched off** (since 2026-11-16, as you asked): a decision written in your feed is not read, and a buy or an offer is made only by a call from your server ([§7](#7-buy-a-cover), [§7a](#7a-offer-a-sub-to-a-gotickets-customer)). It stays described below because the code exists (mig `20261113170000`); S4K switches it on again only if you ask. Groups A and C are requests: tell S4K which you can add.

**A. The primary way: tell us only what changed** (please build this first)

This is how we would like to read your feed. Until it exists we keep reading it the current way, which stays the default and needs nothing from you.

| | Primary way (once you have built it) | Current way (the default until then) |
|---|---|---|
| What we ask your feed | `GET /n2s/items?status=need2buy&updated_since=<the instant of our last read>` | `GET /n2s/items`: the first 250 items, whatever changed |
| What comes back | only the labelled items that changed since we last asked; usually nothing | the top of the whole book, every 30 seconds |
| How fast a new label reaches us | the next poll, wherever the item sits in your book | only if the item is among the first 250 |
| Cost to both sides | a tiny answer, so we can ask more often | a large answer each time; 500 items was too slow, so we read 250 |

What it needs from your feed:

| Ask | Why |
|---|---|
| `updated_since=<instant>` on `GET /n2s/items`, returning every item whose `updated_at` is later (including one whose label was just removed, or that was resolved) | lets us ask only for what changed, however large the book is. Removals must be included, or we would keep watching an order you have closed |
| `need2buy` as a real status in `GET /n2s/meta`, usable as `GET /n2s/items?status=need2buy` | we ask for exactly the labelled items instead of scanning the book |
| `updated_at` bumped on every change to an item, decision fields included | it is the cursor: a change that does not move it is never seen |
| until then: newest change first by default, or `sort=updated_at&order_by=desc` honoured | the current way reads the first 250 items; a newly labelled item must be among them |

When it is live on your side, tell S4K: we switch our reader over and confirm with you on one test item. Nothing else in this guide changes, and you read our answers exactly as before.

**B. So your decision reaches us without a call (switched off)**

| Field on the item | Values | Replaces | What we would do |
|---|---|---|---|
| `sub_decision` | `buy` · `offer` · `none` | the buy and offer-sub calls | `buy`: buy the listing named below. `offer`: send the GoTickets substitution. `none`: do nothing |
| `sub_listing_id`, `sub_market` | the `listing_id` and `market` of the cover you chose, exactly as we returned them | `listing_id` in those calls | act only on a cover we quoted for that order; a `buy` needs a cover with `buyable: true` |
| `sub_confirm` | `true` when a person has seen the cover's `flags` and accepts them | `"confirm": true` | required for a flagged cover, and for buying a one-ticket cover in another row instead of offering it |
| `sub_rebate_amount` | dollars, `0` allowed | `rebate_amount` | sent with a GoTickets offer; required when the sub is rows back |
| `sub_decided_by`, `sub_decided_at` | who, and a UTC instant | `requested_by` | we act **once per `sub_decided_at`**, so a decision is never carried out twice; change the instant to decide again |

How a decision in the feed is handled:

- **Where.** On a `need2buy` item, as top-level fields of the item, next to `status` and `seller_notes`. Bump the item's `updated_at` when you write them, or our copy will not change.
- **When.** We read the feed every 30 seconds and carry decisions out once a minute, so allow up to about two minutes.
- **Once.** One (item, `sub_decided_at`) is carried out once, whatever the outcome. A refused decision is not retried: fix it and send a new `sub_decided_at`.
- **Only after our answer.** A decision is carried out only when the order has an answer from us, and only if `sub_decided_at` is later than that lookup started. An older decision is refused as `stale`.
- **Same rules as the calls.** `buy` and `offer` go through exactly what `POST /orders/{n}/buy` and `POST /orders/{n}/offer-sub` do: the listing must be a cover we quoted, the order must match our own records, the sale must still be live, one buy and one live offer per order, a flagged cover needs `sub_confirm: true` (a real JSON `true`), rows back need `sub_rebate_amount`.
- **What happened** is on the order as `feed_decision`: `{"decision", "listing_id", "decided_at", "decided_by", "outcome", "detail", "flags", "acted_at"}`. `outcome` is `requested` when it went through (then follow `buy` or `sub_offer` as usual), otherwise the refusal: `confirm_needed`, `invalid`, `conflict`, `forbidden`, `stale`, `failed`.

```json
{"id": 4812, "order_number": "1074300986", "marketplace": "Stubhub 2.0", "status": "need2buy",
 "updated_at": "2026-11-13T05:40:00Z", "seller_notes": "buyer ok with a better row",
 "sub_decision": "buy", "sub_listing_id": "7526676784", "sub_confirm": true,
 "sub_decided_by": "dana", "sub_decided_at": "2026-11-13T05:40:00Z"}
```

**Which answer each gate and suffix needs.** These are the only responses we need from you; everything else we decide or do ourselves.

| What the best cover is | What we do by ourselves | The answer we need in your feed |
|---|---|---|
| Gate 1 `Index`, on a market we can buy on (`buyable: true`: EVO, and GoTickets while S4K has it on), no suffix (a one-ticket order: exact row) | buy it | none |
| Gate 2 `S4KTrading`, on a market we can buy on, a `need2buy` order, loss inside your limit for that marketplace (5% of the sale unless you set it, [§6d](#6d-the-automatic-buys-loss-limits)), no suffix | buy it | none |
| Gate 1 or 2 that we did not buy (a loss over the limit, a loss on an order that is not `need2buy`, or over a spending limit) | nothing | `sub_decision: buy` + `sub_listing_id` |
| Gate 1 or 2 on a market we cannot buy on (`buyable: false`: SeatGeek, the TicketsData markets, and GoTickets while S4K has it off) | nothing | none; a person buys it through `link` |
| Gate 3 `Index offer subs` / gate 4 `offer subs s4ktrading` | nothing | GoTickets order: `sub_decision: offer` + `sub_listing_id`. Other marketplaces: you ask the buyer, then `sub_decision: buy` if the cover is `buyable` |
| Gate 5 `Index Down offer subs` | nothing | as gate 3–4, plus `sub_rebate_amount` (`0` allowed) |
| Gate 6 `Down offer subs S4KTrading` | nothing | none: shown to you only, never offered or bought on an answer |
| `over 200% of sale` | nothing | `sub_decision: buy` + `sub_listing_id` if a person accepts the cost |

| Suffix on the label (`flags` code) | What it adds to the answer above |
|---|---|
| `single ticket` in a different row (`single_ticket_row_differs`) | either `sub_decision: offer` (no confirm needed), or to skip the offer `sub_decision: buy` + `sub_confirm: true` |
| `single ticket` in the exact row (no flag) | nothing: bought as gate 1 / 2 |
| `repost single` (`repost_single`) | `sub_confirm: true`: one more ticket than was sold will be bought |
| `obstructed view` (`obstructed_view`) | `sub_confirm: true` |
| `zone unverified` (`zone_unverified`) | `sub_confirm: true`: we could not check the seats are in the same area |
| `no sale price` (`no_sale_price`) | `sub_confirm: true`: profit could not be worked out |
| `row letters differ` (`row_letter_mismatch`) | `sub_confirm: true`: one row is a single letter and the other a double letter (sold `AA`, sub `H`, or the other way round). Venues differ on whether `AA` is in front of `A` or behind `Z`, so a person checks the seating chart |

After a GoTickets customer accepts and the offered seats are gone (`accepted_next: "new_sub_needed"`), the same tables apply to `new_best`: send a new answer with a new `sub_decided_at`.

**C. So we stop sooner and match better**

| Field on the item | Why |
|---|---|
| `order_status` (`open` · `cancelled` · `delivered` · `rejected`) | we stop watching the moment you know the sale is over, instead of waiting for the marketplace's feed |
| `marketplace_order_id` when it differs from `order_number` | GoTickets substitutions are sent against GoTickets' own order id |
| `in_hand_date`, `delivery_type` (read today when present) | so we do not suggest tickets that cannot be delivered in time |
| `seller_notes` (**read today**: becomes the order's `notes`) | your notes travel with the order |

**What stays as it is.** We cannot write to the CRM, so you still read our answer from us: `GET /api/v1/subs/orders/{order_number}` or the sync feed. If you would rather we called you when an answer changes, give S4K a URL and we can add that; each call would carry an HMAC signature of its body, made with a secret we share with you.

## 1. Quick start (5 minutes)

You need the **host** and an **API key**; both come from S4K with your onboarding. The API looks like the CRM's own (`/api/v1`, `X-API-Key`, the same list envelope and `updated_since` cursor), so nothing here should be new.

The whole flow is three calls, and the only thing you have to send is the order number:

```bash
HOST=https://<host>          # given with your key
KEY=s4k_...                  # given once; we store only its hash

# 1. Alert us: this order needs a sub. (What the "Needs sub" checkbox does.)
curl -s -X POST -H "X-API-Key: $KEY" $HOST/api/v1/subs/orders/659213629/needs-sub

# 2. Read the order by its number until "state" is no longer "pending"
#    (usually 20 seconds to 3 minutes).
curl -s -H "X-API-Key: $KEY" $HOST/api/v1/subs/orders/659213629

# 3. Optional, if your key may buy: buy the cover you were quoted (one with buyable: true), then keep reading
#    the same URL until buy.outcome is "confirmed" or "rejected".
curl -s -X POST $HOST/api/v1/subs/orders/659213629/buy \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"listing_id": "6833175743"}'
```

Many orders at once (a backlog, a one-off sweep) go through the batch call in [§3](#3-submit-orders) instead: `POST /api/v1/subs/jobs` with `{"order_numbers": [...]}`.

Check your key first with `curl -s -H "X-API-Key: $KEY" $HOST/api/v1/subs/ping`.

A finished order looks like this (shortened):

```json
{
  "order_number": "659213629", "state": "cover",
  "best": {"market": "evo", "listing_id": "6833175743", "section": "217", "row": "D",
           "row_relation": "better", "buy_qty": 2, "spare": 0, "price_ea": 65.98,
           "total": 131.96, "profit": 119.48, "buyable": true,
           "link": "https://core.ticketevolution.com/buy/event/3241050/tickets/6833175743"},
  "covers": [ "... up to 3 per market ..." ],
  "markets_searched": ["evo", "gotickets", "seatgeek"],
  "buy": null
}
```

## 2. Access: keys, limits, errors

**Base URL.** `https://s4k-subs-api-siyb.onrender.com/api/v1/subs` (since 2026-11-16). Every path in this guide is under it. It is a temporary address: S4K has no domain of its own for this API yet, and will give notice before the address changes. The earlier address (`https://vibepass-storefront-test.onrender.com/api/v1/subs`) keeps answering with the same keys and the same data.

**Authentication.** Send the key as `X-API-Key: <key>` (preferred) or `Authorization: Bearer <key>`. A key only works here after S4K has added it to the sub finder's allow-list, and it only ever sees the jobs of its own account.

**Your keys are never written in this guide.** S4K sends them to you separately.

**Two keys, one account (mig `20261116000000`).** You hold two keys that share the same jobs and orders:

| Key | Scopes | Use it for | Restricted to |
|---|---|---|---|
| read key | `subs:find` | the alert, submitting orders, notes, every read and the sync feeds | any address |
| buy key | `subs:find`, `subs:buy`, `subs:offer` | `POST .../buy`, `POST .../offer-sub`, `PUT /settings/auto-buy-loss`, `PUT /settings/limits` | the addresses you gave S4K; from anywhere else every call with it answers 403 |

The read key cannot spend: a buy, an offer or a settings change sent with it answers 403. The buy key cannot buy or offer until S4K has registered the address it calls from. Each key has its own rate and daily quota, so reading can never use up the calls a buy needs.

**`GET /api/v1/subs/ping`** tells you what the key you sent may do:

```json
{"ok": true, "key_label": "crm sub finder buy", "scopes": ["subs:find", "subs:buy", "subs:offer"],
 "max_orders_per_job": 200, "ticketsdata_fallback": true,
 "your_ip": "203.0.113.7", "allowed_ips": ["203.0.113.7"],
 "limits": {"buy_per_order_usd": 750, "buy_per_day_usd": 4000, "rebate_max_pct": 40, "buy_max_cost_pct": 110},
 "docs": {"version": "3f9c2a71b0de", "updated": null, "url": "/api/v1/subs/docs"},
 "news": [{"date": "2026-11-16", "text": "You set your own limits on rebates and buys, ..."}],
 "generated_at": "2026-11-16T20:00:00.000000Z"}
```

`news` is what changed for you lately, newest first ([the list](#what-changed-for-you)); `docs.version` tells you when to fetch this guide again.

| Scope | Means |
|---|---|
| `subs:find` | may submit orders and read results |
| `subs:buy` | may also ask for a `buyable` cover to be bought (EVO; GoTickets while S4K has it on) |
| `subs:offer` | may also offer a GoTickets customer replacement seats |

An empty `scopes` list means the key is valid but not yet allow-listed (or the API is switched off). `your_ip` is the address we saw this call come from, and `allowed_ips` is what the key is accepted from (empty: any address). Once a key has registered addresses, every call with it from another address answers 403, ping included: to learn the address a server calls from, ping from that server with the read key and send S4K the `your_ip` it returns.

**`GET /api/v1/subs/health`** tells you whether S4K's side is working. Either key may read it. It answers 200 whenever the key is good, so read `status` in the body, not the HTTP code:

```json
{"status": "ok",
 "checks": [
  {"name": "crm_feed", "what": "S4K reading your Need-to-Sub feed (GET /n2s/items on the CRM)", "status": "ok",
   "last_at": "2026-11-16T20:21:55Z", "age_seconds": 41, "ok_within_seconds": 300, "down_after_seconds": 1200,
   "last_attempt_http": 200, "last_read_took_ms": 54990, "last_read_items": 250},
  {"name": "buying", "what": "buys you ask for (POST .../buy)", "status": "ok",
   "buys_waiting": 0, "buys_to_check": 0, "automatic_buying": "off", "ok_within_seconds": 600, "down_after_seconds": 3600}],
 "statuses": {"ok": "...", "degraded": "...", "down": "...", "off": "..."},
 "checked_at": "2026-11-16T20:22:36Z"}
```

| `status` | Means |
|---|---|
| `ok` | working, and its last good run is recent |
| `degraded` | working late (older than `ok_within_seconds`), or something is waiting on S4K |
| `down` | not working: its last good run is older than `down_after_seconds`, or it is stopped |
| `off` | switched off at S4K on purpose. It never lowers the overall status |

The overall `status` is the worst of the checks that are not `off`. A field that does not apply is left out (no `last_at` means it has never run).

| Check | What it watches | `ok` within | `down` after |
|---|---|---|---|
| `crm_feed` | our last complete read of your Need-to-Sub feed. `last_attempt_http` is your API's answer to our most recent try (left out when there was no answer), `last_read_took_ms` how long the last good read took | 5 minutes | 20 minutes |
| `order_book` | our copy of your order book, which an order is checked against before a buy | 30 minutes | 2 hours |
| `lookups` | your own lookups: `lookups_unanswered` with the age of the oldest, and when the `orders_watched` were last re-checked | 10 minutes (15 for an unanswered lookup) | 1 hour |
| `buying` | buys you ask for: `buys_waiting` and the age of the oldest. `down` with `buys_to_check` above 0, or with a `detail` saying buying is stopped, means S4K is holding all buying until a person has checked a buy that did not finish cleanly. `automatic_buying` says whether S4K buys without your call | 10 minutes | 1 hour |
| `offers` | GoTickets offers: `offers_waiting`, and `offers_to_check` for one that was sent with its outcome not known yet (`degraded`). `buy_after_accept` says whether we buy the seats when the customer accepts | 10 minutes | 1 hour |
| `balances` | the hourly read behind `GET /balances` | 2 hours | 6 hours |
| `mlb_schedule` | the MLB schedule reader, once that feed exists; `off` until it is served | 26 hours | 3 days |
| `box_office_sitickets`, `box_office_timberwolves` | the box offices behind `GET /primary/events` and `/primary/listings` (section 6k), one check each; another appears by itself when another team's site starts listing games. `last_at` is the reader's last completed pull (it wakes every 10 minutes). `events` are the ones not yet started, `events_with_listings` the ones we are sending listings for, `events_failing` the ones that were readable and could not be read at the last try (`degraded`), `events_never_readable` a series or package with no listing page (it does not lower the status). `down` when no event of the box office can be read at all: a site refusing us shows here. `off` when the box office has nothing on sale | 25 minutes | 1 hour |

Poll it once a minute at most. If `crm_feed` is not `ok` while your own API is up, tell S4K: a label you set will not reach us until it is. If `buying` is `down`, a buy call is still accepted and waits; nothing is bought until S4K has cleared it.

**Spending limits (`limits`).** They apply to every buy and offer you ask for, whichever person or system sends it; `null` means no limit of that kind. Two are **yours to set**, as a percent of the sale total ([§6f](#6f-your-own-limits-on-rebates-and-buys)); `/ping` shows your default for each. Two are S4K's own ceilings in dollars.

| Limit | Whose | Applies to | When it is passed |
|---|---|---|---|
| `buy_max_cost_pct` | yours | one buy: the quoted total as a percent of the sale total (100 = no loss) | the buy call answers 403 with `"limit": "buy_max_cost_pct"`, `max_usd` and `this_buy_usd` |
| `rebate_max_pct` | yours | `rebate_amount` on an offer, as a percent of the sale total | the offer call answers 422 with `rebate_max`, the most it may be in dollars |
| `buy_per_order_usd` | S4K's | one buy: the tickets at the quoted price | the buy call answers 403 with `"limit": "per_order"` |
| `buy_per_day_usd` | S4K's | all the buys your keys asked for in one New York day (a buy that stopped does not count) | the buy call answers 403 with `"limit": "per_day"` and `spent_today_usd` |

Tax and fees are checked a second time when the buy is sent: a buy whose total with tax passes S4K's own ceiling stops with a reason in `buy.reasons` and nothing is bought. Automatic buys have a separate daily cap of their own.

**Call limits.** Each key has a per-minute rate and a daily call quota (defaults 60 per minute and 2,000 per day; S4K can raise them). Every call counts against the key that made it, including polls. There is also a per-IP ceiling of 600 calls per minute on this path.

**If a key leaks or a buy goes wrong.** Email **tu@s4kent.com** and **julian@s4kent.com**, both on the same message (the contacts for now; S4K will tell you if they change) with the order number or the key's label, never the key itself. A revoked key is refused from its next call. S4K can also stop all buying, which takes effect within 15 seconds; purchases already placed are still followed to their result. [§6e](#6e-the-audit-log) shows every buy and offer your keys asked for and where each call came from.

**Errors.** Every error is JSON: `{"error": "<code>", "detail": "<human text>"}`.

| HTTP | `error` | Meaning | What to do |
|---|---|---|---|
| 401 | `unauthorized` | key missing, wrong, revoked or expired | check the header and the key |
| 403 | `forbidden` | key not allow-listed, API off, or buying not enabled for it; a buy or offer sent with the read key; a call with the buy key from an address that is not registered; a buy over a spending limit (`limit` says which); a buy or offer that would swap an accessible seat and an ordinary one (`limit: "ada_seating"`, [§8](#8-how-matching-works-and-what-it-does-not-do)) | read `detail`; ask S4K |
| 404 | `not_found` | no such job / order for this key | check the ids; jobs are per key |
| 500 | (not JSON) | rare: our service lost its database connection twice in a row | read again after 10 seconds; nothing was lost |
| 409 | `conflict` | a buy already exists for this order or sale, or the order number repeats in the job | read the order to see the existing buy |
| 403 | `forbidden` | the order is one of S4K's own PED Need2Buy orders: it is reported only, never bought here (mig `20261113250000`) | nothing; S4K buys these by hand |
| 422 | `invalid` | the request body or a parameter is wrong; `detail` names the field | fix and resend |
| 429 | `rate_limited` | over the per-minute rate | wait `retry_after_seconds` |
| 429 | `quota_exhausted` | daily quota used up | resets 00:00 UTC |

**Timestamps** are UTC with a trailing `Z`. `event_date` is the venue-local calendar date.

## 3. Submit orders

For one order, use the alert: **`POST /api/v1/subs/orders/{order_number}/needs-sub`** (no body; or the CRM's row as the body when the order is not in our mirror yet). It takes the same fields as below and answers the same job header.

For many at once: **`POST /api/v1/subs/jobs`** — up to 200 orders (see `max_orders_per_job`). Answers **202** with the job header. Pick whichever body is least work for you:

| Body | When |
|---|---|
| `{"order_numbers": ["JY8EGX10HP", "82410899"]}` | the order is already in the CRM's N2S or marketplace book. **Simplest; use this by default** |
| `{"items": [ ...CRM rows... ]}` or `{"orders": [ ...CRM rows... ]}` | post rows exactly as the CRM API returns them (`/n2s/items` or `/marketplace/orders`); no renaming needed |
| `{"orders": [ {...}, "JY8EGX10HP" ]}` | spelled-out orders and bare numbers can be mixed |

**How an order is filled in.** Only `order_number` is required. Anything you leave out is looked up by order number: first in **the marketplace's own order feed**, which we pull ourselves for GoTickets, TickPick, Vivid Seats, SeatGeek and EVO (seats, quantity, sale price and live status come from there); then in our mirror of the CRM's books (the N2S book, then the marketplace book — the only source for StubHub and Gametime). A value the marketplace feed does not carry (SeatGeek's has no price) is filled from the CRM's copy of the same seats. Order numbers are plain numbers on several marketplaces, so send `site` when you know it: without it we use the marketplace the CRM's books give for that number. Anything you do send wins over the mirror. An EVO order can be sent as its full number or its order part.

**How fresh the order feeds are.** We pull each marketplace's order feed every 5 minutes (mig `20261113180000`), and check every watched order against it every 2 minutes. A sale that is cancelled, delivered or rejected stops being watched within about that long.

| Field | CRM names also accepted | Notes |
|---|---|---|
| `order_number` | `s4k_order_id`, `order_id`, `order_no` | **required**; letters, digits, `-`, `_`, `.`; up to 64 characters |
| `section`, `row` | | as sold |
| `qty` | `quantity` | tickets sold, 1 to 50 |
| `sold_ea` | `price_per_ticket`; or `grand_total` ÷ `qty` | what the customer paid per ticket; without it `profit` is null. The marketplace book's `price` is ignored because its basis differs by market |
| `site` | `marketplace`, `source` | where it sold; used on the buy record |
| `tevo_event_id` | | the Ticket Evolution event id, if you have it |
| `event_name` + `event_date` | `event_dt` (the date part is used) | only used when neither you nor the mirror has an event id |
| `venue` | `venue_name` | stored and echoed back; not used for matching |

Unknown fields are ignored, so a full CRM row is fine.

**Which event.** In order: the `tevo_event_id` you sent, then the event our own mappers already resolved for that order in the mirror, then an exact `event_name` + `event_date` match that names exactly one event. The mirror is the reliable route: CRM event names often differ from Ticket Evolution's. If none works the order comes back `unmapped`; it is never guessed.

**Orders we cannot place.** A number that is not in the mirror and came with no section, row and quantity is not stored; it is listed in the response's `not_found`. If every order is like that the call answers 404 `not_found`. A brand-new order may take up to a minute to reach the mirror: retry, or send its row.

**Retries.** The alert call handles this itself (a repeat within 10 minutes is the same lookup). For the batch call, send an `Idempotency-Key` header (or `idempotency_key` in the body). A repeat with the same key returns the first job with `"replayed": true` and creates nothing. Without it, a retry creates a second job and a second round of pulls.

```json
{"job_id": "3f0c2a0e-1b7d-4c55-9a53-0d6f1f0a9b11", "status": "pulling",
 "order_count": 29, "not_found": ["ZZ123"], "unmapped": 1, "replayed": false,
 "created_at": "2026-11-12T19:53:39Z"}
```

The whole request is refused (422) if any one order carries a malformed value; `detail` names it, for example `orders[3].qty must be a whole number from 1 to 50`.

## 4. Read results

**`GET /api/v1/subs/orders/{order_number}`** — that order from the newest job holding it, as `{"count": 1, "items": [...]}`. No job id to keep. This is the simplest way to read one order or follow its buy.

**`GET /api/v1/subs/jobs/{job_id}`** — the whole job with every order; use it for batches. A job moves forward by itself: a background job on our side settles it every 15 seconds (mig `20261113260000`), and a read returns the state as it stands, so reads are quick. Keep polling until it is `done`.

| `status` | Meaning |
|---|---|
| `pulling` | fresh EVO / GoTickets / SeatGeek listings are being fetched |
| `pulling_td` | those are matched; TicketsData is being asked (for the orders still uncovered, or more of them if S4K has widened the search) |
| `done` | every order is answered |

```json
{"job_id": "...", "status": "done", "order_count": 30, "created_at": "...", "done_at": "...",
 "summary": {"cover": 23, "no_cover": 6, "unmapped": 1},
 "items": [ { "...order object..." } ]}
```

Suggested polling: every 10 seconds; expect `done` in 20 seconds to 3 minutes, a little longer when TicketsData is involved. An order reads `pending` until our background job has answered it. If a read ever answers 500, read again: nothing is lost and nothing was bought. Results are a snapshot from that moment: listings sell, so act on them soon, and submit again for a fresh look.

**`GET /api/v1/subs/jobs/{job_id}/orders/{order_number}`** — the same single-order read, pinned to one job (for when you submitted the same order more than once and want an older answer).

## 5. The order object

| Field | Meaning |
|---|---|
| `job_id`, `order_number`, `site`, `section`, `row`, `qty`, `sold_ea`, `venue` | the order as we understood it |
| `order_source` | where its details came from: `api` (the marketplace's own order feed), `n2s` or `marketplace` (our mirror of that CRM book), `request` (you sent them: such an order is searched, but never bought automatically and cannot be bought on a call) |
| `notes`, `notes_at` | your own free text on this order and when it was last written ([§6a](#6a-notes-on-an-order)); null when none |
| `n2s` | in `GET /results` only: where the order stands in the Need-to-Sub book, `{"kind": "n2s" \| "need2buy", "alert_at", "timer_expires_at"}`; null for an order outside it ([§6](#6-keep-in-sync)) |
| `feed_decision` | the last decision we read from your N2S feed for this order, and what carrying it out answered; null when none |
| `tevo_event_id`, `event_name`, `event_date` | the event we matched it to |
| `state` | `pending` (not answered yet) · `cover` · `no_cover` · `unmapped` (event not recognised) |
| `action` | what to do with the answer: `auto_bought` (we bought it, see `buy`) · `buy_manually` (a same-section, same-or-better cover exists: buy it yourselves) · `offer` (only a move to another section or rows back was found: ask the buyer first, then buy it yourselves) · `review` (the only cover costs more than twice the sale) · `none` |
| `sub_offer` | GoTickets orders only: the sub we can offer the customer and how that offer stands ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)); otherwise null |
| `auto_buy_note` | why we did not buy it automatically ([§8](#8-how-matching-works-and-what-it-does-not-do)); null when we did |
| `best` | the recommended cover: lowest gate first, then cheapest total. Null without a cover |
| `covers` | up to 3 covers per market, best first |
| `markets_searched` | which sources were searched for this order |
| `ticketsdata` | the fallback's status for this order (see [§8](#8-how-matching-works-and-what-it-does-not-do)); null when it was not needed |
| `buy` | the purchase, if one was requested ([§7](#7-buy-a-cover)); otherwise null |
| `auto_buy_max_cost_pct` | the most an automatic buy may cost for this order, as a percent of the sale total: your limit for its marketplace if it is a `need2buy` order, otherwise `100` (profit only) ([§6d](#6d-the-automatic-buys-loss-limits)) |
| `last_stopped_buy` | the most recent buy that stopped for this order: `{buy_id, market, listing_id, reasons, at}`, or null. It stays after we have moved on, so you can see which listing was tried and why it stopped |
| `updated_at` | last change to this order — the sync cursor field |

**A cover:**

| Field | Meaning |
|---|---|
| `market` | `evo`, `gotickets`, `seatgeek`, or via TicketsData: `stubhub`, `viagogo`, `vivid`, `tickpick`, `gametime`, `ticketmaster` |
| `source` | `native` (our own feed) or `ticketsdata` |
| `listing_id` | the market's listing id |
| `section`, `row` | where the replacement seats are |
| `row_relation` | `better`, `same`, or `back` (up to 5 rows behind — the customer is being moved back); `unknown` when the two rows cannot be ranked against each other (flag `row_letter_mismatch`) |
| `gate`, `label` | which rule the cover passed, 1 (best) to 6, and its name as the N2S desk uses it ([§8](#8-how-matching-works-and-what-it-does-not-do)). `gate` is null and the label is `over 200% of sale` for a same-section cover that costs more than twice the sale |
| `needs_buyer_ok` | true for gates 3 to 6: the buyer is moved to another section or further back, so they must agree first |
| `flags`, `confirm_needed` | what is off about this cover, as codes: `zone_unverified` (rows back and neither seat has a known zone), `obstructed_view`, `single_ticket_row_differs` (a one-ticket order, and the sub is not in the row that was sold), `repost_single` (the listing forces one more ticket than was sold), `no_sale_price`, `row_letter_mismatch` (one row a single letter, the other a double letter, either way round). `confirm_needed` is true when there is any flag: we never act on such a cover by ourselves, and your yes must carry `"confirm": true` ([§7](#7-buy-a-cover), [§7a](#7a-offer-a-sub-to-a-gotickets-customer)) |
| `zone` | the curated zone of the replacement seats, on covers from another section |
| `view` | `obstructed` when the listing says so; otherwise null |
| `listing_qty` | tickets in the listing |
| `buy_qty` | how many you would have to buy; can be `qty + 1` when the seller only sells the lot whole |
| `spare` | `buy_qty - qty`: tickets left over to resell |
| `price_ea`, `total` | listed price per ticket, and the expected cost for `buy_qty`. On EVO the total **includes the sales tax we expect at that venue** |
| `subtotal`, `tax_pct`, `tax_est` | the listed cost for `buy_qty`, the venue's expected EVO sales tax percent, and that tax in dollars (0 on other markets, and at venues where EVO has never taxed us) |
| `profit` | `sold_ea × qty − total`; negative is a loss. Null without `sold_ea` |
| `price_note` | `before buyer fees` on StubHub and Viagogo, where the checkout price is higher than shown |
| `link` | where to see or buy it. EVO: the exact listing. SeatGeek: the listing on its event page (the event page alone when we do not know the listing's public id). GoTickets and the TicketsData markets: the event page, so find the seats by section and row. Null only when we hold no page for it |
| `buyable` | true for EVO. Also true for GoTickets while S4K has GoTickets buying turned on (mig `20261113300000`); false for every other market. Go by this flag, not by the market name |
| `listing_seen_at` | when we last saw the listing |

Loss-making covers are returned on purpose, with the loss in `profit`. Deciding what loss is acceptable is yours.

**PED orders are report-only.** Some orders you can read here are S4K's own PED Need2Buy orders. You get their covers like any other, but nothing is bought for them through this API: a buy call answers 403 `forbidden`, and a `buy` decision in your feed is refused the same way. S4K buys those by hand. Their covers still say `buyable: true`; go by the 403.

## 6. Keep in sync

**`GET /api/v1/subs/results?updated_since=<instant>&limit=<1-1000>&offset=<n>&scope=<n2s|all>`** — the orders still in play that changed at or after `updated_since`, oldest change first, in the CRM's own envelope:

```json
{"count": 27, "total": 27, "limit": 200, "offset": 0, "scope": "n2s",
 "items": [ "...order objects..." ], "generated_at": "2026-11-18T20:05:11.482913Z"}
```

**What is in it (mig `20261118172530`).** One row per order, and only an order that is still being watched and is one of these:

| Order | In the feed |
|---|---|
| a Need-to-Sub alert | from the alert until its timer runs out, 15 minutes later (`n2s.timer_expires_at`), while its item is open |
| a `need2buy` order, S4K's PED list included | while its item is open and the event day has not passed |
| any order with a purchase or an offer | until a week after that purchase or offer is final, whatever its timer says |

An order you looked up that is in neither group is not in this feed: read it with `GET /orders/{n}`. When the same order was looked up more than once you get one row: the lookup that holds the purchase or offer, else the one still being refreshed, else the newest.

Each row carries `n2s`: `{"kind": "n2s" | "need2buy", "alert_at", "timer_expires_at"}` (`timer_expires_at` is null for need2buy; `n2s` is null for an order outside the Need-to-Sub book). An alert leaves the feed at `timer_expires_at`. A lookup you start on an alert whose timer has already run out is answered by `GET /orders/{n}` but never appears here.

**An order can leave the feed without a last row**: an alert's timer ran out, an item closed, a need2buy order's event day passed. `updated_since` only tells you what changed among the orders still in it. To drop what left, stop showing an alert once its `timer_expires_at` has passed, and read the feed with no `updated_since` now and then, keeping only what comes back.

`scope=all` returns every answered lookup of your key, repeats and closed ones included, as this feed did before 2026-11-18.

The mirror recipe, same as the CRM's N2S feed:

1. First run: call with no `updated_since`; page with `offset` until `offset + count >= total`.
2. Save the `generated_at` of the **first page** of that run.
3. Next run: pass it as `updated_since`. Repeat.

Upsert by (`job_id`, `order_number`). An order can come round more than once: you will see it again when its buy is requested, bought, confirmed or rejected, or when seat numbers arrive. Orders still `pending` are not in the feed.

Your open jobs are settled on our side whether or not you read them, so a client that only ever syncs still gets its answers.

## 6a. Notes on an order

Your own free text on an order, up to 500 characters: why it needs a sub, what the buyer said, who is handling it. We store it and show it back in the order's `notes` / `notes_at`. Nothing reads it to decide a match, a buy or an offer.

- **With the alert:** add `"notes": "..."` to the order (`POST /jobs`, or the body of `POST /orders/{order_number}/needs-sub`).
- **At any time:** `POST /api/v1/subs/orders/{order_number}/notes` with `{"notes": "..."}`. It replaces the note; `""` clears it. Answers 200 `{"order_number", "job_id", "notes", "notes_at"}`, 404 when no lookup holds that order, 422 when `notes` is missing, not text, or over 500 characters.
- A new alert for the same order keeps the last note unless it brings its own.
- Writing a note moves the order's `updated_at`, so the order comes back in the sync feed.

```bash
curl -s -X POST -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"notes": "buyer ok with 2 rows back, call before 5pm"}' \
  $HOST/api/v1/subs/orders/659213629/notes
```

## 6b. Balances

**`GET /api/v1/subs/balances`** — what S4K has to buy with, as we last read it. We read both sources once an hour (at 7 minutes past); the call never reaches EVO or GoTickets itself, so poll it as often as you like. Only keys S4K has allowed for it get an answer; others get 403 `forbidden`.

```json
{"evo": {"taken_at": "2026-11-13T19:07:02Z", "stale": false,
         "total_balance": 220575.53, "total_pending": 468.00, "total_spendable": 220575.53,
         "accounts": [{"office_id": "42029", "currency": "USD", "balance": 148996.49,
                       "pending": 0.00, "pending_sent": 0.00, "spendable": 148996.49}]},
 "gotickets_gift_cards": {"taken_at": "2026-11-13T19:07:03Z", "stale": false,
         "card_count": 14, "cards_with_balance": 1, "total_issued": 4500000.00, "total_remaining": 1234.50,
         "cards": [{"id": "20411", "description": "S4K", "issued": 5000.00, "remaining": 1234.50}]},
 "generated_at": "2026-11-13T19:20:00.000000Z"}
```

| Field | Meaning |
|---|---|
| `evo.accounts[]` | one per EVO office account. `spendable` is what a buy can draw on; EVO buys through this API are paid from office `42029` |
| `evo.total_*` | the accounts added up |
| `gotickets_gift_cards.cards[]` | only the gift cards that still hold money; spent cards are counted in `card_count` and `total_issued` |
| `gotickets_gift_cards.total_remaining` | what is left across all gift cards |
| `taken_at`, `stale` | when that source was last read successfully; `stale` is true when that is over 2 hours ago (the source did not answer). A source never read is `null` |

This is information only: nothing here changes what can be bought, and this API does not buy on GoTickets.

## 6c. What we bought

**`GET /api/v1/subs/buys?updated_since=&limit=&offset=`** — every purchase S4K placed to cover an order, by either of its two buyers, in one feed: what we bought (on EVO or GoTickets), which order it covers, the seats and the money. Each item says who bought it: `buyer` is `n2s_auto` (S4K's **Need-to-Sub auto-buyer**, the N2S desk's own buyer) or `sub_finder` (a buy made through this API: the automatic one-to-one buy, your buy in [§7](#7-buy-a-cover), or seats a GoTickets customer accepted; these are also on the order's `buy`). A row appears as soon as the purchase is placed and comes back each time it changes (seller confirms, the sale is accepted, or it stops). It is a sync feed exactly like [§6](#6-keep-in-sync): same envelope, feed each answer's `generated_at` back as the next `updated_since`. Only keys S4K has allowed for it get an answer; others get 403 `forbidden`.

**`GET /api/v1/subs/autobuys`** takes the same parameters and returns only the Need-to-Sub auto-buyer's purchases, without the `buyer` field. It is unchanged; if you already read it you may keep doing so, or move to `/buys` and get both.

```json
{"count": 1, "total": 1, "limit": 200, "offset": 0, "generated_at": "2026-11-13T20:30:00.000000Z",
 "items": [{
   "buyer": "n2s_auto",
   "buy_ref": "gotickets-8400001", "bought_on": "gotickets", "bought_order_number": "8400001",
   "for_order": {"order_number": "82482253", "ref": "vivid-82482253", "sold_on": "vivid",
                 "section": "345", "row": "7", "qty": 4, "sold_total_usd": 650.00, "state": "accepted"},
   "status": "went_through", "went_through": true, "phase": "accepted", "reasons": [],
   "event": {"name": "Atlanta Falcons vs. Kansas City Chiefs", "local_start": "2026-11-15T13:00:00",
             "start_utc": "2026-11-15T18:00:00+00:00", "venue": "Mercedes-Benz Stadium",
             "tevo_event_id": 3285604, "gotickets_event_id": 1409636},
   "bought": {"listing_id": "7928284282", "section": "Upper 345", "row": "7", "qty": 4,
              "state": "PENDING_MOBILE_FULFILLMENT"},
   "totals": {"quoted_usd": 548.64, "charged_usd": 554.64, "sold_usd": 650.00, "margin_usd": 95.36},
   "bought_at": "2026-11-13T20:21:04Z", "updated_at": "2026-11-13T20:24:40Z"}]}
```

| Field | Meaning |
|---|---|
| `buyer` | `n2s_auto` or `sub_finder` (above). Only in `/buys` |
| `buy_ref` | `<market we bought on>-<that market's order number>`: `evo-<EVO order id>` or `gotickets-<GoTickets purchase id>`. Also split into `bought_on` and `bought_order_number` |
| `for_order` | the order this purchase covers: your `order_number`, `ref` = `<market it sold on>-<order number>`, the seats that were sold, the sale total, and the sale's state on that market (`accepted` once we confirmed it) |
| `status` | `pending` (bought; waiting for the seller to confirm our purchase, then we accept your sale) · `went_through` (seller confirmed and the sale was accepted) · `stopped` (the seller rejected or did not confirm in time, so the sale was **not** accepted; `reasons` says why, e.g. `sub_rejected`, `sub_unconfirmed`) · `check_manually` (a market answer we could not read; S4K checks by hand). `went_through` is the same as `status == "went_through"` |
| `bought` | the listing we bought, its seats and quantity, and our purchase's state on the market we bought on (`state`: EVO's order state, or GoTickets' `orderStatus`) |
| `totals` | `quoted_usd` what we priced it at when we decided to buy (EVO: with the sales tax we expect at the venue) · `charged_usd` what the market charged (null when it did not say) · `sold_usd` the sale total · `margin_usd` sold minus charged (minus quoted when `charged_usd` is null) |
| `bought_at`, `updated_at` | when the buy started and when the row last changed (the sync cursor) |

A `sub_finder` item reads the same way, with these differences: `status` is `went_through` as soon as the seller confirms our purchase (this buyer does not accept the sale; `for_order.state` is null); `phase` is the buy's `request_state` from [§7](#7-buy-a-cover); `bought` also carries the `seats` once the market gives them; `event.start_utc` is null.

How S4K buys on GoTickets, for reading these rows: paid from S4K's GoTickets gift cards (watch them in [§6b](#6b-balances)), Mobile Transfer or another electronic delivery, the buyer and recipient are S4K's own office, and nothing is written to the seller about your order. Every auto-buy has hard limits per market (one live buy at a time while it is being proven, $666 per order, per day and in total) and is only placed at a profit.

## 6d. The automatic buy's loss limits

How big a loss may we take when we buy by ourselves? You decide, per marketplace (mig `20261113320000`).

- **It applies only to `need2buy` orders** (labelled `need2buy` in your N2S feed). Every other order is bought automatically **at a profit only**, and an original Need-to-Sub order that is not labelled is not bought through this API at all.
- **The limit is the most the buy may cost, as a percent of the sale total.** `100` = no loss, `105` = a loss of up to 5% of the sale, `200` = up to twice the sale (the most a gate 2 cover can be). The default is **105** for every marketplace until you set something else.
- **By the marketplace the order sold on.** One number per marketplace, plus a default for the rest.
- The check is made on the quoted cost when we decide, and again on the real total with tax right before the buy (on EVO, from EVO's own quote). S4K's spend ceilings per order and per day still apply on top.
- **A buy that ends at a loss is filed under gate 2 afterwards**: once the real charge is known, the order's `buy.gate_actual` / `label_actual` read `2` / `S4KTrading`; a buy that made money reads `1` / `Index`.
- Each order shows the limit that applies to it as `auto_buy_max_cost_pct` (`100` for an order that is not `need2buy`).

**`GET /api/v1/subs/settings/auto-buy-loss`**

```json
{"applies_to": "need2buy orders only; every other order is bought automatically at a profit only",
 "unit": "the most an automatic buy may cost, as a percent of the sale total (100 = no loss, 105 = a 5% loss)",
 "min": 100, "max": 200, "default_max_cost_pct": 105,
 "by_marketplace": {"stubhub": 110, "vivid": 100},
 "marketplaces": ["evo", "gametime", "gotickets", "seatgeek", "stubhub", "ticketmaster", "tickpick", "viagogo", "vivid"],
 "can_set": true, "updated_at": "2026-11-13T22:00:00+00:00"}
```

**`PUT /api/v1/subs/settings/auto-buy-loss`** (when `can_set` is true)

```json
{"default_max_cost_pct": 105, "by_marketplace": {"stubhub": 110, "vivid": 100, "tickpick": null}, "set_by": "dana"}
```

- Send only what you want to change. A number from `100` to `200` sets it; `null` takes that marketplace (or the default) back to "not set".
- Marketplace names are matched loosely (`StubHub 2.0`, `Vivid Seats`, `gotix` all work) and stored under the names in `marketplaces`.
- If any value is out of range or not a number, nothing is changed and the answer is 422 with the reason. A key that may not set limits gets 403.
- The answer is the limits as they now stand. A change takes effect at the next match, within about a minute; it never undoes a buy already requested. S4K keeps a record of every change with the key and `set_by`.

## 6e. The audit log

**`GET /api/v1/subs/audit`** lists every buy, offer and loss-limit change asked with your keys, newest first, refusals included (mig `20261116000000`). Either key may read it. Optional `since` (an ISO-8601 instant), `limit` (1 to 1000, default 200) and `offset`.

```json
{"count": 1, "total": 1, "limit": 200, "offset": 0, "generated_at": "2026-11-16T20:05:00.000000Z",
 "items": [{"at": "2026-11-16T20:04:11.512345Z", "action": "buy", "order_number": "659213629",
            "listing_id": "6833175743", "market": "evo", "amount_usd": 131.96, "rebate_usd": null,
            "source_ip": "203.0.113.7", "key_label": "crm sub finder buy", "requested_by": "dana@crm",
            "idempotency_key": "3f1c-0001", "http_status": 202, "outcome": "requested",
            "buy_id": 21, "offer_id": null}]}
```

| Field | Meaning |
|---|---|
| `action` | `buy`, `offer` or `settings` |
| `amount_usd` | a buy: the tickets at the price asked. An offer: the total of the seats offered. Null on a refusal |
| `source_ip` | the address the call came from |
| `http_status`, `outcome` | what we answered: `requested` (202), `saved` (a settings change), or the refusal's code (`forbidden`, `conflict`, `confirm_needed`, `invalid`, `not_found`) |

It records calls. What became of a purchase is on the order's `buy` and in [§6c](#6c-what-we-bought); automatic buys are there too, and are not in this log because no call asked for them.

## 6f. Your own limits on rebates and buys

You decide how far a rebate or a buy may go, as a percent of the sale total (sale price each × quantity). S4K does not pick these numbers (mig `20261116030000`).

| Limit | What it caps | Range | Until you set it |
|---|---|---|---|
| `rebate_max_pct` | `rebate_amount` on an offer ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)) | 0 to 100 | a rebate may be up to the sale total |
| `buy_max_cost_pct` | the quoted total of a cover you ask us to buy ([§7](#7-buy-a-cover)); 100 = no loss, 110 = up to 10% over the sale | 1 to 1000 | no percentage limit |

Each has a `default` and may have its own value for the marketplace the order **sold on**; that value wins over the default.

**`GET /api/v1/subs/settings/limits`** (either key) shows them:

```json
{"unit": "percent of the sale total (sale price each x quantity)",
 "rebate_max_pct":   {"default": 40,  "by_marketplace": {"gotickets": 25}, "min": 0, "max": 100},
 "buy_max_cost_pct": {"default": 110, "by_marketplace": {"seatgeek": 125}, "min": 1, "max": 1000},
 "s4k_ceilings": {"buy_per_order_usd": 750, "buy_per_day_usd": 4000},
 "can_set": true, "updated_at": "2026-11-16T21:00:00Z"}
```

**`PUT /api/v1/subs/settings/limits`** sets them. It needs the buy key, from its registered address.

```json
{"rebate_max_pct":   {"default": 40,  "by_marketplace": {"gotickets": 25}},
 "buy_max_cost_pct": {"default": 110, "by_marketplace": {"seatgeek": 125}},
 "set_by": "dana@crm"}
```

- Send only what you are changing: either limit may be left out, and so may `default` or `by_marketplace`. Anything not named stays as it is.
- `null` clears a value: a cleared marketplace falls back to your default, a cleared default to "not set".
- If any value is out of range or not a number, nothing is changed and the answer is 422 with the reason.
- The answer is the limits as they now stand. A change applies from the next buy or offer call; it never undoes one already asked for. S4K keeps a record of every change with the key and `set_by`, and it appears in the audit log ([§6e](#6e-the-audit-log)).
- While `buy_max_cost_pct` is set, a buy for an order with no sale price is refused: there is nothing to measure it against.
- S4K's own ceilings (`s4k_ceilings`) are in dollars and are not changed here.

The automatic buy's loss limit is separate and unchanged ([§6d](#6d-the-automatic-buys-loss-limits)).

## 6g. The MLB schedule with ticket links

`GET /api/v1/subs/mlb/schedule` lists every MLB club's games, this season and next, one row per game; with `level` it lists the 120 Triple-A to Single-A clubs' home games as well. Any key that may look up subs may read it; it buys nothing and calls no marketplace.

We read MLB's own ticketing schedule (what mlb.com/tickets shows) for each MLB club every 2 hours and each minor league club every 4, so a row fills itself in as the club releases it: a start time that was TBD, a ticket link once single-game tickets go on sale, a moved date. `changed_at` changes only when something you would use changed, so you can sync with `since`.

| Query | Meaning |
|---|---|
| `team` | club abbreviation (`NYY`) or MLB team id (`147`); home or away games. Add `home_only=true` for that club's home games only |
| `season` | e.g. `2027` |
| `date_from`, `date_to` | `YYYY-MM-DD`, the game's local date |
| `since` | ISO-8601 instant: only rows whose data changed at or after it |
| `with_tickets=true` | only games with a direct ticket link |
| `mapped=true` | only games mapped to an EVO event |
| `type` | `regular`, `spring`, `exhibition` or `postseason` |
| `level` | `mlb` (the default), `aaa`, `aa`, `high_a`, `single_a`, `milb` (all four minor league levels) or `all` |
| `format` | `json` (default) or `csv` |
| `limit`, `offset` | page size up to 5000 (default 1000); `next_offset` is null on the last page |

```json
{"count": 1, "offset": 0, "next_offset": null, "games": [{
  "mlb_schedule_id": 852989, "season": 2027, "game_type": "regular", "game_date": "2027-03-25",
  "start_local": "2027-03-25T13:35:00", "time_zone": "EDT", "start_utc": "2027-03-25T17:35:00+00:00", "time_tbd": false,
  "doubleheader_game": 1, "home_name": "New York Yankees", "home_abbrev": "NYY", "away_name": "Toronto Blue Jays", "away_abbrev": "TOR",
  "venue_name": "Yankee Stadium", "venue_city": "Bronx",
  "ticket_url": null, "on_sale_start_et": null,
  "tevo_event_id": 3469396, "tevo_start_local": "2027-03-25T00:00:00", "tevo_time_check": "evo_date_only",
  "aq_short_event_id": "SYS-...", "sg_event_id": 17384021, "sh_event_id": null,
  "sg_url": "https://seatgeek.com/...", "sg_match_method": "name_date",
  "terminal_path": "/terminal/event.html?event=3469396", "changed_at": "2026-11-16T19:40:00+00:00",
  "level": "mlb", "league_name": "American League", "parent_org": null}]}
```

- **`ticket_url`** is only ever the seller's own page for that one game (a Ticketmaster event page, mlb.tickets.com with the game's id, or for Somerset the Glitnir page with the game's id). Pages on mlb.com or milb.com that forward you to the seller are left out, so it is null for those clubs, and for clubs that have not opened single-game sales yet.
- **Minor league rows** (`level` other than `mlb`) are the club's home games. `parent_org` is the MLB club it is affiliated with. Minor league abbreviations repeat (three clubs and Colorado are all `COL`), so `team=COL` returns every club with that abbreviation in the levels you asked for; use the team id for one club. EVO and SeatGeek list few minor league games until spring, so `tevo_event_id` / `sg_event_id` fill in later than for MLB.
- **`promotions`** lists the club's offers for that game: giveaways (bobbleheads, hats, apparel), theme nights, fireworks, and ticket offers, each with its `type`, `kind`, `name`, `description`, sponsor (`presented_by`), `distribution` (for example "first 15,000 fans") and links. Null when the game has none.
- **`removed`** is true once the club no longer lists the game (cancelled or moved off the schedule). The row stays, so you can tell it went away; it comes back to false if the club lists it again.
- **`start_local` / `start_utc`** are null while MLB lists the time as TBD (`time_tbd: true`).
- **`tevo_event_id`** is the EVO event for the game, set only when exactly one EVO event is that game on that date (or, on a day with two games, the one starting at MLB's time). `tevo_time_check` compares the two: `same`, `differs`, `evo_date_only` (EVO lists the date without a time) or `mlb_tbd`.
- **`aq_short_event_id`** and the marketplace ids after it are the terminal's event for the game; `terminal_path` opens it in the terminal.
- **`sg_event_id`** / **`sg_url`** are the game's SeatGeek event, matched straight from MLB's schedule: the same teams on the same date, and on a day with two games the one with the same start time. `sg_match_method` says how (`name_date`, `name_date_time`, or `hub` when it comes from the terminal's event).

### Changes: `GET /api/v1/subs/mlb/changes`

Everything the poller detects, oldest first, one row per change: `link_live` / `link_changed` / `link_removed`, `date_changed`, `time_changed`, `venue_changed`, `status_changed`, `on_sale_set` / `on_sale_changed`, `removed` / `restored`, `added` (a new game on the schedule), `promo_added`, and for stadium events `event_added`, `event_moved`, `event_removed`. Each row has `old_value` → `new_value`, the game or event it belongs to (`mlb_schedule_id`, date, teams or event title, venue, `ticket_url`, `tevo_event_id`), and `notable`: the changes worth acting on (a club's first load and plain new-game rows are not notable).

| Query | Meaning |
|---|---|
| `after_id` | only changes after this `change_id`; pass `next_after_id` from the previous page |
| `since` | ISO-8601 instant: changes detected at or after it |
| `kind` | comma list of the kinds above |
| `entity` | `game`, `event` or `promotion` |
| `notable` | `true` for the ones worth acting on |
| `team`, `level` | as for `/mlb/schedule` (`level` defaults to all here) |
| `format`, `limit` | `json` or `csv`; up to 5000 (default 1000) |

### Stadium events: `GET /api/v1/subs/mlb/events`

Concerts and other live events at MLB and minor league ballparks, from the same MLB schedule: for example Monster Jam, Supercross, concerts, the All-Star Home Run Derby. Ballpark tours, parking, rentals and similar extras are left out. MLB lists no ticket link for these, so each carries the EVO event at the same ballpark on the same day when there is exactly one (`tevo_event_id`, `tevo_event_name`, `terminal_path`). Query: `team` (the home club), `level` (default all), `date_from`, `date_to`, `since`, `mapped=true`, `format`, `limit`, `offset`.

## 6h. Ticketmaster's events and the sites they pair to

Three read-only feeds from Ticketmaster's own event catalogue (its Discovery API): the events, the sites each matched event pairs to, and what changed. Any key that may find subs may read them, with that key's rate and quota. They carry names, dates, venues, status and on-sale dates: **no prices and no inventory**.

How the catalogue is collected decides how fresh a row is:

- **The bulk file, once a day.** Ticketmaster publishes its whole catalogue as one file per country. We load the US and Canada files each day. This is where new events, and a changed status, date, start time or venue, come from. So a cancellation or a moved time shows within about a day, and `GET /tm/changes` and `since` report it then.
- **Who sells the event.** The file says who the real seller is (`source`). `ticketmaster` means Ticketmaster itself is the primary seller (`tm_primary` true); `tmr` is a resale-only page; the rest are other ticketers Ticketmaster lists (`universe`, `ticketweb`, `third-party primary`, `frontgate`). About a third of the events are resale pages.
- **The search, only for primary events.** The detail the file lacks (ticket limit, SafeTix, presales, doors, add-ons) is read through Ticketmaster's search only for events Ticketmaster itself sells, in the US and Canada, when they are new or the file shows them changed. Other events have those columns empty; `detail_read_at` says when an event's detail was last read.
- **Not in the file.** About a quarter of the events the search returns are not in the bulk file, nearly all of them resale pages and Universe events. `in_feed` is false for those, and they are not refreshed any more: read `last_seen_at`.
- **No prices.** The file has price columns but they are empty for every event.

### Events: `GET /api/v1/subs/tm/events`

One row per upcoming Ticketmaster event.

| Query | Meaning |
|---|---|
| `date_from`, `date_to` | the event's local date, `YYYY-MM-DD` |
| `segment` | `Sports`, `Music`, `Arts & Theatre` (as Ticketmaster names it) |
| `state` | the venue's two-letter state |
| `status` | `onsale`, `offsale`, `cancelled`, `postponed`, `rescheduled` |
| `mapped` | `true`: only events matched to an EVO event. `false`: only those not matched |
| `primary` | `true`: only events Ticketmaster itself sells. `false`: only resale pages and other ticketers' events. An event that is not in the bulk file matches neither |
| `source` | one seller type as the bulk file names it: `ticketmaster`, `tmr` (resale), `universe`, `ticketweb`, `third-party primary`, `frontgate`, `other` |
| `products` | `true` to include parking, add-ons and packages. They are left out by default |
| `safetix` | `true`: only events with SafeTix. `false`: only those without |
| `detail` | `false` for the core columns only (the example below) plus `source` and `tm_primary`, about a quarter of the size. By default every column comes back |
| `q` | a search, up to 80 characters: every word must be in the event's name, its teams or performers, its venue or its city. Case and accents do not matter (`beyonce` finds Beyoncé). Combine it with any other filter |
| `since` | only rows first seen, matched, or whose status, date, start time or venue changed, at or after this instant |
| `format`, `limit`, `offset` | `json` or `csv`; up to 5000 (default 1000); `next_offset` is null on the last page |

```json
{"count": 1, "offset": 0, "next_offset": null, "events": [
 {"tm_event_id": "vvG1zZ_8p3fAa6", "name": "Atlanta Hawks vs. Charlotte Hornets",
  "ticket_url": "https://www.ticketmaster.com/atlanta-hawks-vs-charlotte-hornets-atlanta-georgia-11-20-2026/event/0E00650592505247",
  "event_date": "2026-11-20", "start_local_time": "19:00", "start_utc": "2026-11-21T00:00:00+00:00", "date_tbd": false, "time_tba": false, "status": "onsale",
  "segment": "Sports", "genre": "Basketball", "sub_genre": "NBA",
  "tm_venue_id": "KovZpa2Xke", "venue_name": "State Farm Arena", "venue_city": "Atlanta", "venue_state": "GA",
  "venue_country": "US", "venue_timezone": "America/New_York",
  "attraction_names": ["Atlanta Hawks", "Charlotte Hornets"],
  "public_onsale": "2026-08-14T14:00:00+00:00", "presales": null, "ticket_limit": null, "is_product": false,
  "tevo_event_id": 3464939, "tevo_match_method": "venue_date_name",
  "tevo_event_name": "Emirates NBA Cup - Charlotte Hornets at Atlanta Hawks", "tevo_start_local": "2026-11-20T19:00:00",
  "terminal_path": "/terminal/event.html?event=3464939",
  "first_seen_at": "2026-11-18T21:30:33+00:00", "last_seen_at": "2026-11-18T21:30:33+00:00",
  "changed_at": "2026-11-18T21:31:02+00:00"}]}
```

- `tm_event_id` is Ticketmaster's Discovery id: text, not a number.
- `tevo_event_id` is set only when exactly one EVO event fits: the same venue, the same local date and a fitting name. Null means we have not matched it, not that EVO lacks it.
- `presales` is Ticketmaster's own list of presale windows for the event (null when it lists none); `public_onsale` is the general on-sale.
- `tevo_start_local` is EVO's start time, which can differ from Ticketmaster's by a few minutes.

**The rest of the row** (left out with `detail=false`). Ticketmaster does not fill every field for every event; an empty one is null.

| Field | Meaning |
|---|---|
| `source`, `tm_primary` | who really sells the event, as Ticketmaster's bulk file names it, and whether that is Ticketmaster itself. Null when the event is not in the file |
| `official_seller`, `brand_name` | whether the page is an official seller's (false on resale pages), and the brand shown (`Ticketmaster`, `Universe`, `TicketWeb`, or a venue's own) |
| `transactable`, `hot_event` | whether tickets can be bought on the page now, and Ticketmaster's own high-demand flag |
| `legacy_event_id`, `legacy_venue_id` | the ids Ticketmaster's own pages use: the event id in `ticketmaster.com/event/<id>` and the venue id in a venue page's address |
| `promoter_names` | the promoters Ticketmaster names for the event |
| `in_feed`, `detail_read_at` | whether the event is in the newest bulk file, and when its detail was last read through the search (null: never, so the detail columns below are empty) |
| `seatmap_url`, `outlets` | a link to Ticketmaster's static seat map picture, and where Ticketmaster says tickets are sold. Filled when the event's detail is next read |
| `ticket_limit` | Ticketmaster's own sentence, for example `There is an overall 8 ticket limit for this event.` (a core column) |
| `ticket_limit_count` | the limit as a number, when the sentence gives exactly one. Null when it gives none or more than one |
| `ticket_limit_numbers` | every number in the sentence, in its order. `[4, 8]` for "a 4 ticket limit for presales and an 8 ticket limit for public onsale": read the sentence to see which is which |
| `safetix` | true when the event uses SafeTix: a rotating barcode, so tickets move only by Ticketmaster transfer |
| `all_in_pricing` | true when Ticketmaster shows the price with fees included |
| `public_onsale_end` | when the public sale closes (`public_onsale` is when it opens) |
| `end_date`, `end_local_time`, `end_utc`, `spans_multiple_days` | when the event ends, where Ticketmaster gives it; `spans_multiple_days` is true for a pass or package covering more than one day |
| `access_start_utc`, `access_end_utc` | the window in which the event can be entered, where given |
| `doors_local_time`, `doors_utc` | when doors open |
| `please_note`, `info`, `description` | Ticketmaster's free-text notes on the event |
| `more_info_url` | a page the organiser points to for more information |
| `ticket_text` | the lines printed on the ticket, `{"line1": ..., "line2": ...}` |
| `classification_type`, `classification_sub_type`, `family` | the rest of Ticketmaster's classification; `family` marks family events |
| `attractions` | the teams or performers: `[{"id", "name", "url", "upcoming_events", "links"}]`. `links` holds their own homepage and social pages where Ticketmaster lists them |
| `products` | add-ons tied to the event, such as parking: `[{"id", "name", "url", "type"}]` |
| `venue_address`, `venue_postal_code`, `venue_latitude`, `venue_longitude`, `venue_url` | where the venue is, and its Ticketmaster page |
| `venue_markets` | the Ticketmaster market areas the venue belongs to, for example `["New York/Tri-State Area"]` |
| `venue_upcoming_events` | how many upcoming events Ticketmaster lists at the venue |
| `venue_box_office` | box office hours, phone, payment and will-call notes |
| `venue_parking`, `venue_general_info`, `venue_accessible_seating`, `venue_ada` | the venue's parking, house rules and accessibility notes |

Ticketmaster's catalogue returns **no prices and no seat inventory** for these events, so there is none here.

### The sites an event pairs to: `GET /api/v1/subs/tm/markets`

One row per Ticketmaster event that matched an EVO event, with the id of the same event on each other site where we can pair it. An id we do not have is null.

| Query | Meaning |
|---|---|
| `site` | only events paired to that site: `seatgeek`, `vivid`, `tickpick`, `stubhub`, `gotickets`, `axs` |
| `date_from`, `date_to`, `segment`, `state`, `status` | as for `/tm/events` |
| `since` | only rows matched, or whose pairings changed, at or after this instant |
| `format`, `limit`, `offset` | as for `/tm/events` |

```json
{"count": 1, "offset": 0, "next_offset": null, "events": [
 {"tm_event_id": "vvG1zZ_8p3fAa6", "name": "Atlanta Hawks vs. Charlotte Hornets", "event_date": "2026-11-20",
  "start_local_time": "19:00", "status": "onsale", "segment": "Sports", "genre": "Basketball",
  "venue_name": "State Farm Arena", "venue_city": "Atlanta", "venue_state": "GA",
  "ticketmaster_url": "https://www.ticketmaster.com/atlanta-hawks-vs-charlotte-hornets-atlanta-georgia-11-20-2026/event/0E00650592505247",
  "tevo_event_id": 3464939, "tevo_event_name": "Emirates NBA Cup - Charlotte Hornets at Atlanta Hawks",
  "tevo_match_method": "venue_date_name",
  "seatgeek_event_id": 18485907, "seatgeek_url": null, "vivid_event_id": 7419725,
  "tickpick_event_id": 8200067, "stubhub_event_id": 161673436, "gotickets_event_id": 1901596,
  "axs_event_id": "1568260", "aq_short_event_id": "SYS-c69814edba", "sites_paired": 6,
  "terminal_path": "/terminal/event.html?event=3464939", "changed_at": "2026-11-18T21:31:02+00:00"}]}
```

- `sites_paired` counts the six site ids that are set (EVO itself is not counted). `seatgeek_url` is set only where we hold SeatGeek's page for that id.
- Each id comes from our own event map, built by matching each site's catalogue to the EVO event. A pairing can be added later, so sync with `since`.
- An event that is in `/tm/events` but not here has not matched an EVO event yet.

### What changed: `GET /api/v1/subs/tm/changes`

One row per change to an event's status, date, start time or venue, oldest first, so you can catch a cancellation or a moved time without reading the catalogue again. Logging began on 2026-11-21; there is nothing from before.

| Query | Meaning |
|---|---|
| `after_id` | only changes after this `change_id`; pass `next_after_id` from the previous page |
| `since` | only changes detected at or after this instant |
| `kind` | one or more of `status_changed`, `date_changed`, `time_changed`, `venue_changed`, comma separated |
| `format`, `limit` | `json` or `csv`; up to 5000 (default 1000); `next_after_id` is null on the last page |

```json
{"count": 1, "next_after_id": null, "changes": [
 {"change_id": 41, "detected_at": "2026-11-21T18:00:00+00:00", "kind": "status_changed",
  "old_value": "onsale", "new_value": "cancelled", "tm_event_id": "vvG1zZ_8p3fAa6",
  "name": "Atlanta Hawks vs. Charlotte Hornets", "event_date": "2026-11-20", "start_local_time": "19:00",
  "status": "cancelled", "segment": "Sports", "venue_name": "State Farm Arena", "venue_city": "Atlanta",
  "venue_state": "GA", "ticket_url": "https://www.ticketmaster.com/event/0E00650592505247", "tevo_event_id": 3464939}]}
```

- `old_value` and `new_value` are the status, the date (`YYYY-MM-DD` or `TBD`), the start time (`HH:MM` or `TBA`) or the venue with its city and state. The other fields are the event as it is now.
- `detected_at` is when we next read the event from Ticketmaster and saw the difference, not when Ticketmaster made the change.
- The same changes move `changed_at` on `/tm/events`, so `since` there returns a changed event too. Use whichever fits: `/tm/changes` tells you what changed.
- An event Ticketmaster stops listing is not a change here: its `last_seen_at` on `/tm/events` simply stops moving.

## 6i. AXS events and SeatGeek-primary events

Two more read-only feeds, for the same keys as the Ticketmaster ones. Names, dates, venues, status and the ticket page: **no prices and no inventory**.

### AXS: `GET /api/v1/subs/axs/events`

One row per live upcoming AXS event. By default only the events AXS itself sells (`axs_primary` true, about 48,000); `primary=false` returns the events AXS lists and another ticketer sells (about 92,000). All are in the US.

| Query | Meaning |
|---|---|
| `primary` | `false` for the events another ticketer sells. Default `true` |
| `date_from`, `date_to` | the event's local date, `YYYY-MM-DD` |
| `state` | the venue's two-letter state |
| `mapped` | `true`: only events matched to an EVO event. `false`: only those not matched |
| `q` | a search: every word must be in the name, the performers, the venue or the city |
| `since` | only rows first seen, or matched, at or after this instant |
| `format`, `limit`, `offset` | `json` or `csv`; up to 5000 (default 1000); `next_offset` is null on the last page |

```json
{"count": 1, "offset": 0, "next_offset": null, "events": [
 {"axs_event_id": 1483914, "name": "Tape B", "headliner": "Tape B", "performers": ["Tape B"], "tour_title": null,
  "category": "Music", "genre": "Dance / Electronic", "status": "Buy Tickets",
  "event_date": "2026-11-21", "start_local_time": "20:30", "start_utc": "2026-11-22T02:30:00+00:00",
  "timezone": "America/Chicago", "time_tba": false, "axs_venue_id": 126792, "venue_name": "Armory - Minneapolis",
  "venue_city": "Minneapolis", "venue_state": "MN", "venue_country": "US",
  "announce_utc": "2026-06-09T01:30:29+00:00", "onsale_utc": "2026-06-09T01:30:29+00:00", "presale_utc": null,
  "ticket_url": "https://www.axs.com/events/1483914/tape-b-tickets", "ticketer": "axs", "axs_primary": true,
  "tevo_event_id": 3412441, "tevo_event_name": "Tape B", "tevo_match_method": "venue_date",
  "terminal_path": "/terminal/event.html?event=3412441", "first_seen_at": "2026-09-23T20:15:28+00:00",
  "last_seen_at": "2026-11-21T17:23:47+00:00", "changed_at": "2026-11-19T20:04:00+00:00"}]}
```

- `status` is AXS's own button text: `Buy Tickets`, `Coming Soon`, `Sold Out`, `Cancelled` and so on.
- `changed_at` moves when the event is first seen or matched to an EVO event, not when AXS changes its status. Read `last_seen_at` for freshness: the AXS list is read every minute.

### SeatGeek primary: `GET /api/v1/subs/seatgeek/events`

One row per upcoming event where SeatGeek is the primary ticketer, for example Dallas Cowboys and Washington Commanders home games. Same query as the AXS feed, without `primary`.

```json
{"count": 1, "offset": 0, "next_offset": null, "events": [
 {"sg_event_id": 18116899, "name": "Tennessee Titans at Dallas Cowboys", "category": "nfl", "status": "normal",
  "event_date": "2026-11-22", "start_local_time": "12:00", "start_utc": "2026-11-22T18:00:00+00:00", "time_tba": false,
  "performers": ["Dallas Cowboys", "Tennessee Titans"], "sg_venue_id": null, "venue_name": "AT&T Stadium",
  "venue_city": "Arlington", "venue_state": "TX", "venue_country": "US",
  "ticket_url": "https://seatgeek.com/dallas-cowboys-tickets/11-22-2026-arlington-texas-at-t-stadium/nfl/18116899",
  "seatgeek_open_id": "e_LPCw89YNJhRKrbRXfYm4KR3tgNzjmJ", "seatgeek_primary": true,
  "tevo_event_id": 3285875, "tevo_event_name": "Tennessee Titans at Dallas Cowboys", "tevo_match_method": "matcher_v3_pm24h",
  "terminal_path": "/terminal/event.html?event=3285875", "first_seen_at": "2026-08-01T00:00:00+00:00",
  "last_seen_at": "2026-11-22T00:12:00+00:00", "changed_at": "2026-08-02T00:00:00+00:00"}]}
```

- **This feed is small on purpose.** We hold SeatGeek's own record for about 4,300 upcoming events, the ones we trade, not SeatGeek's whole catalogue. Of those, 45 were SeatGeek-primary on 2026-11-22. An event that is missing here may still be SeatGeek-primary.

## 6j. The same event on every marketplace

Every event row of `/tm/events`, `/axs/events`, `/seatgeek/events`, `/mlb/events`, `/axs/watch` and `/primary/events` carries the id we hold for the same event on each other site, so you do not have to join the feeds yourself. A null means we hold no pairing with that site, not that the site does not list the event.

| Field | The event's id on |
|---|---|
| `xmap_tevo_event_id` | EVO (Ticket Evolution): the feed's own match (`tevo_event_id`), else the one our cross-map holds. `tevo_event_id` itself is unchanged, and so is what `mapped=` filters on. Not on `/mlb/events`, `/axs/watch` or `/primary/events`, whose `tevo_event_id` is the only EVO id we hold for the row |
| `ticketmaster_event_id` | Ticketmaster: the event Ticketmaster itself sells before a resale page (not on `/tm/events`, where it is `tm_event_id`) |
| `seatgeek_event_id` | SeatGeek (not on `/seatgeek/events`, where it is `sg_event_id`) |
| `stubhub_event_id` | StubHub |
| `vivid_event_id` | Vivid Seats |
| `tickpick_event_id` | TickPick |
| `gotickets_event_id` | GoTickets |
| `axs_event_id` | AXS, as text (on `/axs/events` it is the row's own id, a number; on `/axs/watch` it repeats the row's `event_id`) |
| `aq_short_event_id` | Automatiq |

- **Where they come from.** Our hub of traded events first, then our cross-map of every site's catalogue, then (Vivid Seats and TickPick) that site's own catalogue. `GET /tm/markets` reads the same sources in the same order, so the two agree for an event both list.
- **An event with no EVO match can still be paired.** The cross-map pairs some Ticketmaster, AXS and SeatGeek events with other sites before our matcher finds the EVO event; those rows have a null `tevo_event_id` and ids here.
- **`/mlb/schedule` already carried** `sg_event_id`, `sh_event_id`, `vivid_event_id`, `tm_event_id`, `gotickets_event_id` and `aq_short_event_id` under those names; it gains `tickpick_event_id` and `axs_event_id`.
- **`since` does not see a new pairing by itself.** `changed_at` moves when the event or its EVO match changes. To pick up pairings added later, read the page again.
- **`/axs/watch` and `/primary/events`.** An AXS watch event (`source` `axs`) is looked up by its AXS id, so it is paired as `/axs/events` pairs it. An event of a box office we read ourselves (`sitickets`, `timberwolves` and the other team sites) is looked up by its EVO event, so it has ids only once `tevo_event_id` is filled. The listings calls carry no marketplace ids: join a listing to its event by `source` and `event_id`.
- In CSV the fields are the last columns.

## 6k. Box offices we poll ourselves: events and listings

Two box offices are read by us directly and served as two feeds. Each event is read on its own cadence, by its date, its price and the tickets listed: every 10 minutes on the day of the event, every 30 minutes or every hour before, at a random slot inside that interval (see `poll_every_minutes` below). Same keys as `/mlb/schedule`.

| Source | What it is | Events | Listings |
|---|---|---|---|
| `sitickets` | SI Tickets, the box office of Sports Illustrated Stadium in Harrison, NJ: Red Bull New York home matches and other stadium events such as HSBC SVNS | Yes | Yes |
| `timberwolves` | The Minnesota Timberwolves' own ticket site: every home game at Target Center | Yes, with seats available and the price range | Yes: the team's own seats (`primary`) and seats resold on the site (`resale`) |
| `lynx` | The Minnesota Lynx's own ticket site, on the same platform: home games at Target Center | None until the WNBA schedule is released; they then appear by themselves | As for `timberwolves`, once there are games |
| `nccourage`, `denversummit`, `reign`, `bostonlegacy`, `sounders`, `northcarolinafc` | The own ticket sites of NC Courage, Denver Summit, Seattle Reign and Boston Legacy (NWSL), Seattle Sounders (MLS) and North Carolina FC (USL), all on the same platform as `timberwolves` | None yet: no single matches were on sale on 2026-11-24 (Sounders, Reign and Boston Legacy sell there from the 2027 season). Matches appear by themselves when they go on sale; seasons, memberships and plans are left out | As for `timberwolves`, once there are matches |
| `axs` | The AXS watch: a list of 200 upcoming events that AXS itself sells (or an AXS-powered team shop such as the Rockets' `nba` store) at ten venues — Crypto.com Arena, Toyota Center, T-Mobile Arena, Red Rocks, RodeoHouston, PeoplesBank Arena, MGM Grand Garden Arena, Target Center (concerts only), Greek Theatre, Soldier Field — refilled nightly as events pass; sports only for major-league teams (Lakers, Kings, Rockets, Golden Knights) | Yes, with the price range, seats available and the order limits; `tevo_event_id` from the AXS export's own match | Yes: AXS's own seats (`primary`) and AXS Official Resale (`resale`), each listing a block of adjoining seats with its seat numbers, or a general-admission level with its amount. Prices are the AXS base price (the facility fee included, the service fee not: `fee` is null). Read through TicketsData, about 40 seconds a read, so a listing is 10 to 60 minutes old (`poll_every_minutes`) |

Season packages, memberships and deposits are left out. For `axs`, parking, suites, packages and passes too, and the Timberwolves and Lynx, which `timberwolves` and `lynx` carry.

```
GET /primary/events?source=sitickets&date_from=2027-02-01&available=true
GET /primary/listings?source=sitickets&event_id=2297105
GET /axs/watch?available=true                      the AXS watch on its own: /primary/events pinned to source axs
GET /axs/watch/listings?event_id=1457748           its listings: /primary/listings pinned to source axs
```

**`GET /primary/events`** takes `source`, `date_from`, `date_to`, `q` (every word must be in the name, venue or city), `available=true|false`, `mapped=true|false`, `format=json|csv`, `limit` (max 5000) and `offset`.

| Field | Meaning |
|---|---|
| `source`, `event_id` | The box office and its own id for the event. Together they identify the event |
| `name`, `event_date`, `start_local_time`, `start_utc`, `timezone` | Local date and time at the venue. `start_utc` and `timezone` are null for `sitickets` |
| `venue_name`, `venue_city`, `venue_state`, `ticket_url` | The venue and the event's page at the box office |
| `offer_id`, `order_min`, `order_max` | `timberwolves`: the public single-game offer and its order limits, where the site gives them |
| `total_available`, `price_min`, `price_max`, `currency` | `timberwolves`: seats the team says are available and the price range |
| `listings_available` | True when the event's listings can be sent right now |
| `listing_count`, `listings_as_of` | How many listings and when they were read. Null unless `listings_available` |
| `listings_withheld` | Why not: `event_started` (the event has started: we stop reading it at its start time, so we stop sending its listings), `poll_failed` (the last read of this event failed), `not_polled` (never read yet) or `poll_stale` (no good read in the last 35 minutes and the event's next slot is more than 20 minutes behind) |
| `tevo_event_id`, `tevo_match_method`, `terminal_path` | The EVO event our mapper matched, how, and its page in our terminal. Null until matched; a series or package that is not an EVO event stays null |
| `last_poll_at`, `first_seen_at`, `last_seen_at` | When we last tried the event, first saw it and last saw it listed |
| `median_price` | The median of what a buyer pays for a ticket (`all_in_price`) over the event's listings we send |
| `listed_quantity` | The tickets listed, added up over the same listings. 0 when nothing is listed; null when the listings carry no quantity |
| `poll_every_minutes` | How often this event's listings are read. By date: the day of the event 10; up to 2 days away, or a Friday, Saturday or Sunday event up to 5 days away, 30; further 60 (the longest). Then, except on the day of the event, by `median_price` (150 or more is one step faster, under 50 one step slower) and by `listed_quantity` (2,000 or more is one step faster, under 250 one step slower). The two add up, stay between 30 and 60, and together never slow an event by more than one step |
| `next_poll_at` | The slot drawn for this event's next read. Time is cut into windows as long as the event's interval and each window into 10-minute slots; the event is read once a window, at a slot drawn at random, redrawn every cycle. So two reads of an hourly event are 10 to 110 minutes apart, an hour on average |
| `ticketmaster_event_id`, `seatgeek_event_id`, `stubhub_event_id`, `vivid_event_id`, `tickpick_event_id`, `gotickets_event_id`, `axs_event_id`, `aq_short_event_id` | The same event's id on each marketplace (section 6j). Null where we hold no pairing with that site. In CSV they are the last columns |

**`GET /primary/listings`** takes `source`, `event_id`, `tevo_event_id`, `market=primary|resale`, `section`, `date_from`, `date_to`, `format`, `limit` and `offset`. Rows come cheapest first within an event.

| Field | Meaning |
|---|---|
| `source`, `event_id`, `event_name`, `tevo_event_id`, `event_date`, `start_local_time` | The event, and the EVO event it matched (null until matched) |
| `listing_id` | The box office's id for this block of seats; it stays the same from one read to the next |
| `market` | `primary`: the box office's own seats. `resale`: resold on the same site |
| `area`, `section`, `seat_row`, `seat_low`, `seat_high`, `seats` | Where the seats are. `seats` lists every seat number. A general admission block has no seats: `seat_low`, `seat_high` and `seats` are null and `general_admission` is true (`sitickets`: `seat_row` reads `GA`) |
| `quantity`, `allowed_quantities`, `max_per_order` | Seats in the block, the quantities a buyer may take from it, and the most one order may take (`sitickets`: the largest of `allowed_quantities`) |
| `order_min`, `order_max` | The event's own order limits, where the box office gives them |
| `price`, `fee`, `tax`, `all_in_price`, `currency` | Per ticket, for every source: `price` is before fees and tax, and `price` + `fee` + `tax` = `all_in_price`, what the buyer pays |
| `order_fee` | A fee charged once an order, not per ticket (`sitickets`: 0.30). Null where there is none |
| `price_estimated` | `true` where `price`, `fee` and `tax` were worked out from the all-in total and not read from the box office (`timberwolves`: its site shows only the total). `all_in_price` is never estimated |
| `price_includes_tax` | Kept for callers already reading it; `false` wherever `price` is filled |
| `ticket_type`, `delivery`, `ada`, `aisle`, `general_admission` | The price type, how the ticket is delivered, and seat flags |
| `as_of` | When this event's listings were read |

- **Only the newest pull is served.** Each read replaces an event's listings, so a listing that is gone at the box office is gone here on the next read; we send no history. `/primary/events` holds the events of the box office's last completed read: an event it no longer lists drops out of both feeds.
- **Listings are sent for 35 minutes after a good read, or until 20 minutes after the event's next slot (`next_poll_at`), whichever is later.** So an event read every hour keeps its listings between reads, and `as_of` on each listing says how old they are. A failed read deletes the event's listings on our side, so nothing old is sent. The event stays in `/primary/events` with `listings_available: false`.
- **An empty `/primary/listings` for an event does not mean it is sold out.** Check `listings_available` on the event first.
- **Obstructed-view listings are never sent.**
- **Timberwolves prices are split from the total.** The site shows one all-in figure a ticket: to the cent for the team's own seats, to the dollar for resale. We split it into `price`, `fee` (20% of the price) and `tax` (12.025% of the price) and set `price_estimated: true`; `all_in_price` is the site's own figure. `max_per_order` is never above the game's `order_max`. On the event, `price_min` and `price_max` are all-in figures.
- **Listings of every team site but `timberwolves` will carry `all_in_price` only** until that team's fee and tax are confirmed: `price`, `fee` and `tax` are null there.
- **Timberwolves listings come from a separate worker.** Until it is switched on, every Timberwolves event has `listings_withheld: poll_failed`.
- **`tevo_event_id` is filled by our event mapper**, not by the poll, so a newly listed event has a null until the mapper's next pass. Use `mapped=false` to see the ones still open.

## 7. Buy a cover

> **Single tickets (mig `20261113130000`).** A one-ticket order is bought automatically only into the exact row that was sold. A same-section cover in a better row is an offer: `action` reads `offer`, the cover has `needs_buyer_ok` and `offer_bypass: true`. Ask the buyer (on GoTickets, through [§7a](#7a-offer-a-sub-to-a-gotickets-customer): the order carries a `sub_offer` with `bypass_allowed: true`), or skip the offer and buy it here with `"confirm": true`.
>
> **Flagged covers (mig `20261113130000`).** A cover with `confirm_needed: true` is bought only when the body also carries `"confirm": true`. Without it the answer is 409 `{"error": "confirm_needed", "flags": [...]}` and nothing is requested.

Needs the `subs:buy` scope. Only covers with `"buyable": true` can be bought, and only one this job quoted for that order. This is how you confirm a sub as good to buy: we buy automatically only a one-to-one cover inside the rule in [§8](#8-how-matching-works-and-what-it-does-not-do); any other buyable cover is bought only on this call.

**Which markets.** EVO always. GoTickets while S4K has GoTickets buying turned on (mig `20261113300000`): then its covers read `buyable: true` and are bought exactly as EVO ones are. If the same `listing_id` were quoted on both markets, the EVO cover is the one bought.

Before buying we check the order against **our own copy of the order books** (mig `20261113030000`): it must be there with the same event, section, row, quantity and sale price, or the call answers 422. So alert us with the order number only; an order sent with its own details can be searched but not bought. A buy is also refused (409) when the Need-to-Sub auto-buy already has the order, or one of our order feeds marks the sale fulfilled, cancelled or rejected.

**`POST /api/v1/subs/orders/{order_number}/buy`** (newest job holding that order) or **`POST /api/v1/subs/jobs/{job_id}/orders/{order_number}/buy`** (a specific job)

```json
{"listing_id": "6833175743", "requested_by": "dana@crm"}
```

`requested_by` is optional free text naming the person; it is kept on the purchase record. The buy is held to your own `buy_max_cost_pct` ([§6f](#6f-your-own-limits-on-rebates-and-buys)) and to S4K's dollar ceilings ([§2](#2-access-keys-limits-errors)). Answers **202**:

```json
{"buy_id": 21, "state": "requested", "order_number": "659213629",
 "market": "evo", "listing_id": "6833175743", "qty": 2, "max_price_ea": 65.98}
```

**Retrying safely.** Send an `Idempotency-Key` header (or `idempotency_key` in the body) with the buy: any text of up to 80 characters that you make up once per buy. If the call times out, send it again with the same key: when the first one was accepted you get its answer back (202, with the header `Idempotent-Replay: true`) and nothing is bought twice. The same key on a different order or listing answers 422. A refused call is not remembered, so correct it and send it again under the same key. Without a key a repeat is still safe: one order can hold one live buy, so the second call answers 409 with the `buy_id` of the first. The offer call takes the key the same way.

That is a request, not a purchase yet. What happens next, and what you see in the order's `buy` object:

| `buy.request_state` | `buy.outcome` | Meaning |
|---|---|---|
| `requested` | `none` | queued; our buyer sends one buy at a time, one about every 15 seconds, so a buy behind others waits its turn |
| `buying` | `none` | being sent to the market |
| `bought` | `pending` | the market took the order; waiting for the seller. `order_id` is set |
| `bought` | `confirmed` | the seller accepted. **This is the one that means you are covered** |
| `stopped` | `rejected` / `canceled` | the seller rejected or the order was canceled; nothing was bought. See `rejection_reason`. You may buy a different cover, and we may move on to the next one ourselves (below) |
| `stopped` | `none` | we did not send it; `reasons` says why (below) |
| `unknown` | `none` | the market did not answer clearly. A person at S4K checks; do not re-buy until told |

Once the market's charge is known the `buy` also shows `profit_actual` (sale total − what was really charged, tax and fees included) and `gate_actual` / `label_actual`: `1` `Index` when the buy made a profit, `2` `S4KTrading` when tax or price turned it into breakeven or a loss.

Follow it by polling `GET /api/v1/subs/orders/{order_number}` every 15 to 30 seconds, or just keep syncing: each change re-emits the order in the feed. We re-check the market every 30 seconds at first, then less often, for up to 7 days.

**When a buy stops, we move on** (mig `20261113310000`). A stopped buy bought nothing. If it stopped for a reason that belongs to that listing (it sold, its price rose, the quantity changed, the market refused it, the seller rejected it), we let go of it within about a minute and match the order again: the automatic buy may then take the next cover, under exactly the same rules, never the listing that just stopped, and at most three attempts per order per day. While that is happening the order's `buy` is null again and `last_stopped_buy` names what was tried. A stop that is about S4K (a spend ceiling, gift cards, setup) is not retried by itself. Either way you may send a buy for a different cover at once: a stopped buy no longer answers 409.

**The `buy` object:**

| Field | Meaning |
|---|---|
| `buy_id` | our id for the purchase |
| `request_state`, `outcome` | as in the table above |
| `market` | where the buy was sent: `evo` or `gotickets` |
| `order_id` | our order number on that market — put this in your confirmation field |
| `evo_order_id` | the Ticket Evolution order number; null when the buy was sent to GoTickets (use `order_id` there) |
| `seller_state`, `order_state` | the market's own words. EVO: `pending`, `accepted`, `completed`, `rejected`, `canceled`. GoTickets: `order_state` is its purchase status (`PENDING_CONFIRMATION`, then one such as `PENDING_MOBILE_FULFILLMENT` or `MOBILE_QR_DELIVERED`), and `seller_state` reads `accepted` or `rejected` once that status is final. Go by `outcome` |
| `rejection_reason` | the seller's reason, when rejected or canceled |
| `qty`, `price_ea` | what was bought |
| `total` | what the market charged. **On EVO it can be higher than `price_ea × qty`**: tax, and a fee on some orders. On GoTickets it includes the delivery fee and tax |
| `section`, `row` | the seats bought |
| `seats` | seat numbers, e.g. `["14","15","16","17"]`. Null until the seller provides them — often only after they accept, sometimes never (general admission, or sellers who do not publish seats) |
| `reasons` | why a request was stopped |
| `status_checked_at`, `final_at` | last check with the market, and when the outcome became final |

**Why a request is stopped before buying (`reasons`):**

| Reason | Meaning |
|---|---|
| `listing_gone` | sold or pulled since the job ran |
| `price_above_ceiling` | the price rose above what the job quoted (on GoTickets: its total with delivery fee and tax came to more than the quoted price × quantity); submit again for a fresh quote |
| `short_quantity`, `split_not_allowed` | the listing can no longer supply that quantity |
| `our_own_listing` | it is S4K's own inventory |
| `over_order_cap`, `over_daily_cap`, `over_shared_ceiling` | over S4K's spend ceilings (per order, per day for this buyer, or per day across both of S4K's buyers); ask S4K |
| `unknown_format`, `no_seller_office`, `listing_read_failed`, `buy_failed` | the market would not sell it as listed |
| `tax_quote_failed`, `total_above_ceiling` | an automatic EVO buy only: EVO gave no usable total before the buy, or its total with tax was over the automatic buy's loss limit. Nothing was bought; buy it with this call if a person accepts the cost |
| `no_electronic_delivery`, `price_unknown`, `listing_unreadable`, `own_listing_check_failed` | GoTickets only: the listing has no mobile / PDF delivery, shows no price, or could not be read or checked safely |
| `gift_card_balance_short`, `gift_card_read_failed` | GoTickets only: S4K's gift cards cannot cover it right now ([§6b](#6b-balances)); ask S4K |
| `gotickets_buy_off`, `no_gt_event_id`, `gt_buyer_profile_missing`, `no_gt_buy_client` | GoTickets only: buying there is switched off or not fully set up on our side; ask S4K |

**After the seller accepts** the `buy` holds everything about the order we placed: `market`, `order_id` (`evo_order_id` too for an EVO buy), `outcome: "confirmed"`, `qty`, `price_ea`, `total` (what was charged, tax and fees included, as one figure), `profit_actual`, `section`, `row`, and `seats` once the seller gives them. Tax is not broken out separately, and there is no delivery status after acceptance.

**S4K is told too.** Every buy emails S4K's desk when the market takes the order, when its answer is unclear, and when the seller confirms, rejects or cancels (mig `20261113240000`). You do not need to tell us a buy happened.

**Guarantees.**
- A purchase is sent to its market **once** and never retried.
- One live purchase per sale: asking again for the same order, or for a sale S4K already bought by hand, answers 409.
- We never pay more per ticket than the job quoted. On GoTickets, where fees and tax are added at checkout, the whole order never costs more than the quoted price × quantity.
- A GoTickets buy is paid only from S4K's gift cards, and one of S4K's own listings is never bought.
- Buying a cover with `spare: 1` buys the extra ticket too; nothing here relists it.
- Nothing here accepts, rejects or reprices the customer's order on its marketplace.

## 7a. Offer a sub to a GoTickets customer

For an order sold on **GoTickets**, when the only covers move the buyer (gates 3 to 6, see [§8](#8-how-matching-works-and-what-it-does-not-do)), the order carries a `sub_offer`:

```json
"sub_offer": {"via": "gotickets", "ask_crm": true, "results_only": false, "gate": 5,
              "market": "evo", "listing_id": "3201", "section": "102", "row": "4",
              "rebate": null, "rebate_needed": true, "rebate_suggested": 60.00, "request": null}
```

| Gate | What we do |
|---|---|
| 1, 2 | nothing to offer: the seats are in the same section, same or better row. `sub_offer` is null |
| 3, 4 | `ask_crm: true`. On your yes we offer the customer those seats |
| 5 | `ask_crm: true` and `rebate_needed: true`: the customer is moved back, so **your yes must carry the rebate amount** (`0` for none). `rebate_suggested` is sale total − sub total |
| 6 | `results_only: true`. Never offered; you only get the results |

**Say yes:** `POST /api/v1/subs/orders/{order_number}/offer-sub` with `{"listing_id": "<sub_offer.listing_id>"}` (optional `market`, `requested_by`, and `rebate_amount`: dollars to give the customer back). **You set the rebate; we never do.** For gate 5 it is required (send `0` for no rebate) and the call answers 422 with our suggestion if it is missing; for gates 3 and 4 it is optional. It must be between 0 and your own rebate limit for the marketplace the order sold on ([§6f](#6f-your-own-limits-on-rebates-and-buys)), or the sale total while you have set none. Over it, the call answers 422 with `rebate_max` in dollars, and `rebate_suggested` never exceeds it. `sub_offer.rebate` then shows what was offered. An `Idempotency-Key` makes a retry safe, as for a buy ([§7](#7-buy-a-cover)). You may name another cover of the same order instead, as long as it is gate 3, 4 or 5. Answers 202 `{"offer_id", "state": "requested", "gate", "section", "row", "rebate"}`. Saying nothing means no offer is made.

If the cover is flagged (`confirm_needed`), add `"confirm": true`; without it the answer is 409 `{"error": "confirm_needed", "flags": [...]}` and nothing is sent to GoTickets.

We then send GoTickets one substitution request for that order and keep reading its status. Re-read the order: `sub_offer.request` shows `state` (`requested` → `sent`, or `stopped` with `reasons`, or `unknown`) and GoTickets' own `status` (`PENDING`, `CUSTOMER_REVIEW`, `ACCEPTED`, `DENIED`, `CANCELLED`, with `denial_reason`).

Rules:
- Needs the scope `subs:offer` (see `ping`). Without it the route answers 403.
- The order must be in our own copy of the GoTickets order book with the same seats and quantity. Alert us with the order number only; an order sent with its own details cannot be offered.
- One live offer per order. After a denial or a stop you may confirm another cover.
- **While an offer is waiting for the customer we leave the order alone** (mig `20261113120000`): no fresh listings are pulled for it and its `best` / `covers` are not re-matched, so the order keeps showing what the customer is being offered. That holds from your yes until the offer is accepted, stopped, denied or cancelled; then the usual re-checking resumes. The order still closes as usual.
- **When the customer accepts and the offered seats are a listing we can buy (`buyable`), we buy them** (when S4K has this switched on): exactly the quantity sold, at no more than the quoted price, inside the daily automatic-buy cap. The order then shows `action: "auto_bought"` and a `buy` to follow as in [§7](#7-buy-a-cover); `sub_offer.request.buy` says `buy_requested`, or why we did not buy (`auto_buy_off`, `order_closed`, `not_on_evo`, `needs_spare_ticket`, `already_bought_for_this_sale`, `over_daily_cap`, `ada_seating`). The listing can sell while the customer decides; then the buy stops and you are told.
- **After a denial or cancellation we check the sale before looking again** (mig `20261113120000`): GoTickets is read for the sale's own state, with our copy of the order as the fallback. If the sale is cancelled or delivered the lookup closes (`closed_reason` `order_cancelled` / `order_fulfilled`); otherwise the usual re-checking resumes and you may confirm another cover.
- **After the customer accepts** (mig `20261113120000`) we do not call the CRM: the order's `updated_at` moves, so it comes back in the sync feed ([§6](#6-keep-in-sync)) with these `sub_offer` fields, and the rest of the order is sent as normal (`best`, `covers`, `buy`):

| Field | Meaning |
|---|---|
| `accepted`, `accepted_at` | the customer said yes, and when |
| `offered_gone` | true when the seats that were offered are no longer listed; false while they are; null when we cannot tell yet |
| `accepted_next` | `buy_requested`: we are buying the seats, follow `buy` · `buy_manually`: the offered seats are still listed and we cannot buy them, buy them yourselves (the order's `action` reads `buy_manually` too) · `new_sub_needed`: the offered seats are gone and there was no one-to-one cover to buy |
| `new_best` | with `new_sub_needed`: the best cover now (`market`, `listing_id`, `section`, `row`, `gate`, `label`, `buy_qty`, `total`, `profit`); the order's `best` and `covers` carry the full detail |

- **What we buy after an acceptance.** The offered seats themselves, when they are on a market we can buy on (`not_on_evo` is the note when they are not). If they are gone, the acceptance buys nothing else: only the standing automatic one-to-one rule can ([§8](#8-how-matching-works-and-what-it-does-not-do): a buyable cover in the order's **original** section, same row or better, exact quantity, breakeven or better, or a small loss inside the limit). Any other gate is reported through `new_sub_needed` / `new_best` for you to decide.
- Accepted seats on GoTickets or SeatGeek are not bought by us. Buy them yourselves.
- Before sending we re-read the sale: a cancelled or already delivered sale, a different quantity, or a request already open stops the offer (`reasons`).
- `unknown` means we could not tell whether GoTickets received the offer. Check Seller Central; no second offer is sent for that order until S4K clears it.

## 8. How matching works, and what it does not do

**A cover is** a listing with:
- a row of the same kind as the order's (numbers with numbers, letters with letters),
- a quantity the seller's split rules allow, or a lot of exactly one more ticket (`spare: 1`),

that passes one of these gates. They are the N2S desk's own rules and names (`docs/d7_n2s_pipeline.md` §4a):

| `gate` | `label` | Seats | Cost | Buyer must agree | What we do with it |
|---|---|---|---|---|---|
| 1 | `Index` | same section, same or better row | less than the sale (a profit) | no | bought by us when automatic buys are on and the cover is on a market we can buy on; otherwise you buy it |
| 2 | `S4KTrading` | same section, same or better row | up to 200% of the sale | no | bought by us only for a `need2buy` order with the loss inside your limit; otherwise you buy it |
| 3 | `Index offer subs` | another section in the same zone, same or better row | a profit | yes | never bought by us; on a GoTickets order you may offer it to the customer |
| 4 | `offer subs s4ktrading` | another section in the same zone, same or better row | up to 200% | yes | never bought by us; on a GoTickets order you may offer it to the customer |
| 5 | `Index Down offer subs` | up to 5 rows back, same section or same zone | a profit | yes | never bought by us; on a GoTickets order you may offer it, and you set the rebate (`0` allowed) |
| 6 | `Down offer subs S4KTrading` | up to 5 rows back, same section or same zone | up to 200% | yes | shown to you only: never offered or bought on an answer |

**`GET /api/v1/subs/gates`** returns this table and the next one as JSON, for any key that may find subs: `{"gates": [{"gate", "label", "seats", "cost", "needs_buyer_ok", "what_we_do"}], "label_words": [{"word", "meaning"}], "docs": {"version", "url"}}`. It is read from this guide, so the two never differ.

A label can carry extra words after the gate's name:

| Word added to `label` | Meaning |
|---|---|
| ` zone unverified` | rows back in the same section, where we hold no zone map to confirm the price tier |
| ` obstructed view` | the listing discloses an obstructed view |
| ` single ticket` | a one-seat sale |
| ` repost single` | one spare ticket has to be bought and resold |
| ` no sale price` | no `sold_ea`, so the cost rule could not be checked |
| ` row letters differ` | a single-letter row against a double-letter row, shown either way round: we do not know which is in front |

**Accessible seats are never swapped with ordinary seats** (mig `20261117101530`). Accessible (ADA / wheelchair) seating is for the customers who need it, so this is a block and not a review. A seat counts as accessible when its section carries a marker (`204LWC`, `103WC`, `103 WC`, `ADA 12`, `Wheelchair Platform`, `Accessible 5`) or its row does (`WC`, `ADA`, `Wheelchair`). A sold accessible seat is covered only by an accessible listing; a sold ordinary seat is never covered by an accessible one. A listing on the wrong side is left out of `covers` altogether, so an order whose only listings are on the wrong side has no cover: handle it by hand. A buy or offer for such a listing is refused: 422 `invalid` when it was never quoted, 403 `forbidden` with `limit: "ada_seating"` when it comes from a lookup made before this rule. `"confirm": true` does not override it.

**Rows we cannot rank are reviewed, never bought by us** (mig `20261113450000`). A cover with any of these words is never bought automatically; you buy it with `"confirm": true` once a person has looked. A sold row that is neither a number nor one or two letters (`WC1`, `ADA`, `GA1`) gets no cover at all: handle those by hand.

**Gates 3 to 6 are searched only when the order has no gate 1 or 2 cover.** An order with a same-section, same-or-better cover is shown only those. Gates 3 to 6 move the buyer, so they are offers: `needs_buyer_ok` is true and we never buy them.

A "zone" is a set of sections we have mapped as equivalent for that team and venue. Where we hold no map, other sections are not offered. Section spelling differences such as `FLR 3` / `Floor 3` are not always bridged — send sections as the marketplace shows them.

Parking passes and S4K's own listings are never offered.

**What we buy automatically.** When the operator has it switched on, an order that is still being watched and has no purchase gets ONE cover bought for it when all of this is true: the cover is on a market we can buy on (EVO, and GoTickets while S4K has it on; the cheapest such cover wins), in the same section and the same or a better row, at a profit — or, for a `need2buy` order only, at breakeven or a loss inside your limit for the marketplace it sold on (5% of the sale total unless you set it, [§6d](#6d-the-automatic-buys-loss-limits)), after the expected tax (on EVO the real total, tax included, is asked from EVO right before the buy and must stay inside that limit) (gate 1 `Index`, or for `need2buy` a gate 2 `S4KTrading` cover inside the limit; a profitable cover is always taken first), for exactly the quantity sold, with no obstructed view, the order is not in the Need-to-Sub book, the order is in our own copy of the marketplace order book with the same event, seats, quantity and sale price the cover was matched on, and the day's automatic buys stay under $1,000. The order then shows `action: "auto_bought"` and a `buy` to follow as in [§7](#7-buy-a-cover). Anything else is never bought by us: you get the results and buy outside this API.

| `auto_buy_note` | Why it was not bought |
|---|---|
| `auto_buy_off` | automatic buying is switched off. It is off since 2026-11-16, as you asked, until we have run some orders together: every buy is one a person at the CRM confirmed with the buy call |
| `order_described_by_caller` | the order's details came from you (`order_source` `request`), not from our own books; such an order is never bought automatically |
| `no_evo_one_to_one` | no buyable cover (EVO, or GoTickets while it is on; the name is historical) in the same section and row or closer at a profit — or, for a `need2buy` order, inside its loss limit (it may be on another market, a bigger loss, a loss on an order that is not `need2buy`, or only an offer) |
| `needs_spare_ticket` | the only EVO lot has one ticket more than the sale; we never buy extra |
| `obstructed_view` | the only one has an obstructed view |
| `profit_too_thin` | the profit is under S4K's minimum (currently none: breakeven is bought) |
| `ada_seating` | the cover was quoted before the accessible-seat rule and would swap an accessible seat and an ordinary one; it is gone at the next refresh |
| `needs_crm_confirm` | the one-to-one cover is flagged (`flags`, usually `single_ticket_row_differs`): confirm it yourselves with the buy route and `"confirm": true` |
| `n2s_order` | the order is in the Need-to-Sub book, which is handled separately; also every PED Need2Buy order, which is never bought here |
| `not_in_our_books` | we could not find the order in our own copy of the order book, so we will not spend on it |
| `differs_from_our_books` | the details sent with the order differ from our copy; alert us with the order number only |
| `order_closed` | one of our order feeds marks the sale fulfilled, cancelled or rejected |
| `over_daily_cap` | it would take the day's automatic buys over the cap |
| `already_bought_for_this_sale` | a purchase already exists for this order |

**Sources, in order:**

1. **EVO, GoTickets, SeatGeek** — always, from a fresh pull.
2. **TicketsData** (StubHub, Viagogo, Vivid Seats, TickPick, Gametime, Ticketmaster) — only when `ticketsdata_fallback` is on, and by default **only for orders the first three found nothing for**. S4K can widen this (mig `20261113290000`) to orders whose best cover is not a gate 1 cover, or to every order. An order that already has a cover keeps showing it while TicketsData is asked; when the answer lands, the covers it found are added to `covers` and `best` may change. The job reads `pulling_td` until then. The search starts from whichever link we hold for the event (a StubHub id, else a SeatGeek link, else a Vivid id) and its listings are used only when the answer is clearly the same event on the same date (mig `20261114000000`). When our own SeatGeek feed has nothing for an event, SeatGeek listings can also arrive this way (`market: "seatgeek"`, `source: "ticketsdata"`).

| `ticketsdata` | Meaning |
|---|---|
| null | not asked for this order, or the fallback is off |
| `queued` | being asked now; an order that already had a cover still shows it |
| `searched` | asked; any covers found are in `covers` with `source: "ticketsdata"` |
| `failed` | the search gave nothing we could use: no answer in time, rate limited three times running, out of credit, or an answer that was not clearly this event (another night of the run, or a low-confidence match: its listings are never shown). Submit the order again later |
| `no_event_link` | we hold no StubHub, SeatGeek or Vivid link for this event, so it could not be asked (also: a parking event, or every link we hold gave a wrong answer in the last 14 days) |
| `over_limit` | the job had more events needing the fallback than one job may ask about; submit those orders in a separate job |

**Not included:**
- Seat numbers on covers. No listing feed carries them; they arrive on the `buy` after purchase.
- Buying on any market other than EVO, and GoTickets while S4K has it turned on (a cover's `buyable` says which).
- Webhooks. You poll or sync; we never call the CRM.
- TicketsData on an order that already has a cover, unless S4K has widened the search: by default the six fallback markets are searched only when EVO, GoTickets and SeatGeek found nothing.
- Automatic buys of anything but the one-to-one buyable cover described above.
- Prices are as listed. `price_note` flags the two markets where checkout adds buyer fees.

## 9. For S4K operators: switching it on

Everything ships **off**. All switches are rows in `sub_finder_config` (one row); changing them is a prod write and needs the operator's say-so (CLAUDE.md §1).

| Step | What | How |
|---|---|---|
| 1 | Apply migrations `20261112000000`, then `20261112010000` | normal migration apply |
| 2 | Issue the CRM a key | `SELECT mcp_issue_key('crm sub finder', 'external', '<who>');` returns the key itself, once — hand it over and do not store it. Its id: `SELECT id FROM mcp_api_keys WHERE label = 'crm sub finder' AND revoked_at IS NULL;`. An external key also opens the public market-data `/mcp`, nothing internal |
| 3 | Turn the API on for that key | `UPDATE sub_finder_config SET enabled = true, key_ids = key_ids \|\| <id>;` |
| 4 | Optional: TicketsData fallback | `UPDATE sub_finder_config SET td_enabled = true;` — costs 12 credits + 1 report per event asked, at most `td_max_events_per_job` (6) events per job and 3 in flight. `td_scope` (mig `20261113290000`) chooses which orders ask: `no_cover` (default: only orders with no cover), `not_one_to_one` (also orders whose best cover is not gate 1) or `all`. A wider scope asks about more events, so it spends more credits; events with a no-cover order are asked first |
| 5 | Optional: let the key buy | `UPDATE sub_finder_config SET buy_enabled = true, buy_key_ids = buy_key_ids \|\| <id>;` |
| 6 | Optional: automatic one-to-one buys (mig `20261113010000`) | `UPDATE sub_finder_config SET auto_buy_enabled = true;` — independent of step 5. Limits: `auto_buy_daily_cap_usd` (1000, counted per New York day over `manual_sub_buy` rows whose `requested_by` starts `sub finder auto`) and `auto_buy_min_profit_pct` (0 = breakeven or profit) and `auto_buy_max_loss_pct` (5: the biggest loss, as a percent of the sale total, a gate 2 cover may be bought at; 0 = breakeven only) |
| 7 | Optional: GoTickets sub offers (mig `20261113020000`) | `UPDATE sub_finder_config SET gt_offer_enabled = true, gt_offer_key_ids = gt_offer_key_ids \|\| <id>;` and `GT_SUB_OFFER_LIVE=1` on the web service. `gt_offer_auto_buy = true` also buys the EVO seats once the customer accepts (needs the manual sub buy path live; counts toward `auto_buy_daily_cap_usd`). Last tick: `GET /api/admin/gt-sub-offer/status`. Rows: `sub_finder_gt_offer` |
| 8 | Optional: take in `need2buy` items from the CRM's N2S feed (mig `20261113160000`) | `UPDATE sub_finder_config SET n2b_intake_enabled = true, n2b_key_id = <id> WHERE id;` — the lookups are filed under that key, which must be in `key_ids`. Up to `n2b_batch` (20) items a minute. What was handed over: `sub_finder_n2b_seen`. Our own Gmail-labelled PED N2B rows are not taken in, and are report-only when looked up (`sub_finder_report_only`, mig `20261113250000`) |
| 9 | Optional: carry out decisions read from the CRM's N2S feed (mig `20261113170000`) | `UPDATE sub_finder_config SET n2b_decisions_enabled = true WHERE id;` — needs step 8, and steps 5 / 7 for the buys / offers themselves. A `buy` in the feed spends money with no call from the CRM. What was carried out, and what it answered: `sub_finder_feed_decision` |
| 10 | Optional: let a key read our balances (mig `20261113270000`) | `UPDATE sub_finder_config SET balances_key_ids = balances_key_ids \|\| <id> WHERE id;` — the hourly read is cron `account_balances_hourly` (`account_balances_pull()`); rows in `account_balance_run` / `account_balance` |
| 11 | Optional: let a key read N2S auto-buy results (mig `20261113410000`) | `UPDATE sub_finder_config SET autobuys_key_ids = autobuys_key_ids \|\| <id> WHERE id;` — seeded from `balances_key_ids`. The rows are `n2s_autobuy_exec` (live mode, `buy_order_id` set), read by `sub_finder_autobuys()` |
| 12 | Optional: buy GoTickets covers too (mig `20261113300000`) | Two switches, both off, and both must be on: `UPDATE sub_finder_config SET gt_buy_enabled = true WHERE id;` lets the sub finder pick a GoTickets cover (automatic buy, CRM buy, accepted-offer buy, under the same rules as EVO), and `UPDATE manual_sub_buy_config SET gt_enabled = true WHERE id;` lets the worker send the buy. A GoTickets cover reads `buyable` only while both are on. GoTickets uses the same ceilings as EVO (`per_order_cap_usd` / `daily_cap_usd`); `gt_per_order_cap_usd` / `gt_daily_cap_usd` are empty and a number there overrides EVO's for GoTickets only. Each market's spend counts against its own day ceiling; `auto_buy_daily_cap_usd` counts both markets. Paid from gift cards only (`gt_gift_card_ids`; `/balances` shows them). The buyer details are in `manual_sub_buy_config.gt_*`, copied once from the N2S buyer. If the worker switch goes off after a request was filed, that request stops with `gotickets_buy_off` |
| 13 | Optional: move on to the next cover when a buy stops (mig `20261113310000`) | `UPDATE sub_finder_config SET buy_fallback_enabled = true WHERE id;` — once a minute `sub_finder_release_stopped()` lets go of a stopped buy whose reasons are all about the listing (`sub_finder_stop_is_listing`), so the automatic buy can take the next cover. `buy_fallback_max` (3) attempts per order per New York day; a listing that stopped for an order is not picked again for it for `buy_fallback_retry` (12 hours). A stop about a ceiling, gift cards or setup, and any `unknown`, is never released |
| 14 | Optional: let a key set the automatic buy's loss limits (mig `20261113320000`) | `UPDATE sub_finder_config SET loss_limit_key_ids = loss_limit_key_ids \|\| <id> WHERE id;` — the limits are rows in `sub_finder_loss_limit` (`site`, `max_cost_pct` 100–200; `*` = the default for every other marketplace; no row = `100 + auto_buy_max_loss_pct`). They apply to `need2buy` orders only (`sub_finder_max_loss_pct`); every other order is profit-only. Every change: `sub_finder_loss_limit_log`. Reading the limits needs no extra switch |
| 15 | Optional: the control over both buyers (mig `20261113430000`) | One row, `sub_buy_control`, above the sub finder's buyer and the N2S auto-buyer; each keeps its own switches and ceilings, and its own pace (one buy at a time, one per 15-second tick: that is the limit on buys sent together). Everything in the row ships off. **Behind `enforce = true`:** `stop` (neither buyer starts a new buy; buys already placed are still followed) and `daily_ceiling_usd` (both buyers, both markets, per New York day; a sub finder buy over it stops with `over_shared_ceiling`, an N2S buy waits). **On its own, off while NULL:** `evo_inflight_max` = at most that many EVO buys, from both buyers, waiting for a seller; the next waits (`requested`) until one is confirmed or rejected, or has gone `evo_inflight_minutes` (60) unanswered. `SELECT sub_buy_evo_inflight(), sub_buy_spent_today();` shows where both stand. The feed of both buyers' purchases is `sub_finder_buys()`, same keys as row 11 |
| 16 | One buyer: the N2S auto-buyer files into this queue (mig `20261113440000`) | Off until the N2S desk sets `n2s_autobuy_config.buyer = 'queue'` (its switch, default `own`, set by hand once the worker that knows N2S rows is the only one running). Then N2S's claim files each buy it would have sent with `manual_sub_buy_file_n2s()` (`manual_sub_buy.origin = 'n2s'`, `n2s_exec_id`, `buy_by`) and one worker sends everything: one buy per 15-second tick, **N2S rows first**. An N2S row skips this path's switch and ceilings (N2S's own ran when it filed) but obeys row 15; it is handed out only while N2S is live, not killed and not stopped for that market; past `buy_by` it stops unsent (`queue_expired`). N2S's guards and its reading of the market's answer stay N2S's code. Results go to N2S's own row in the same transaction; an unknown N2S buy flips N2S's kill switch and holds back N2S buys only, and an unknown buy of ours holds back ours only. N2S rows are followed, alerted and listed (`/buys`: `n2s_auto`) from N2S's row, never twice |
| 17 | How the TicketsData search finds the event (mig `20261114000000`) | `sub_finder_td_seeds(<tevo_event_id>)` lists the links a search can start from, best first: StubHub id (`aq_event_map.sh_event_id`), SeatGeek link (`sg_events_canonical.sg_url`), Vivid id (`aq_event_map.vivid_event_id`), across every map row of the event. An answer is used only at `td_min_confidence` (80) or more and on our event's local date; otherwise the next link is tried, at most `td_max_seeds` (2) per event per job, and the bad link goes to `sub_finder_td_seed_log` and is not asked again for 14 days. 429 is retried twice; 402 stops the job's remaining searches. Each answered search is checked against `td_budget_ok()` / `td_reports_budget_ok()` first and charged with `td_charge_credit()` after. With `td_writeback` on (default), an answer at `td_writeback_min_confidence` (90) or more gives its StubHub and Vivid ids to the event map through `event_mapper_apply()` (fill-only). `sub_finder_td_pull` shows each search: `seed`, `tried`, `note`, `match_confidence`, `match_date`, `learned` |
| 18 | The CRM's two keys, addresses, limits and the record (mig `20261116000000`) | **Keys.** `sub_finder_key (key_id, account_id, can_buy, can_offer, allowed_ips inet[], note)`: a key listed there acts for `account_id` (the id in `key_ids` / `buy_key_ids` / `gt_offer_key_ids` that the jobs are filed under) and may only read unless `can_buy` / `can_offer`. The account id may be a revoked key: it is a filing id, not a credential. Issue a key with `mcp_issue_key`, then add its row; never put it in `key_ids`. **Addresses.** `allowed_ips` restricts every call with that key; `UPDATE sub_finder_key SET allowed_ips = '{203.0.113.7}' WHERE key_id = <id>;`. `sub_finder_config.write_requires_ip = true` refuses a buy, offer or settings change from any key with no address. **In force since 2026-11-16: `client_ip_header = 'cf-connecting-ip'`.** On Render the app receives `X-Forwarded-For: <caller>, <Cloudflare edge>` and `cf-connecting-ip: <caller>` (read with the `/ping` aid below). The router takes the caller's address from that header (mig `20261116020000`), and only when the last `X-Forwarded-For` entry is inside `sub_finder_config.trusted_proxy_cidrs` (Cloudflare's published ranges as of 2026-11-16; update the list if Cloudflare publishes a new range, until then calls through it have no address). Only `cf-connecting-ip` or `true-client-ip` is accepted, sent exactly once. Checked live: `your_ip` in `GET /ping` was the caller's own address plainly and with a made-up `X-Forwarded-For` or `True-Client-IP`; Cloudflare itself rejects a request that carries its own `CF-Connecting-IP` (error 1000); a buy key locked to another address was refused from here with every one of those. **The other way (mig `20261116010000`), used when no header is named:** the `X-Forwarded-For` entry `client_ip_hops` from the end, with every entry after it inside `trusted_proxy_cidrs`; on Render that would be 2. Never set it higher than a `/ping` test with a made-up header supports. **The `/ping` aid:** `UPDATE sub_finder_config SET ping_shows_headers = true WHERE id;` makes `GET /ping` return `forwarding_headers`, the headers as they reached the app; switch it off afterwards. A new deploy takes a minute or two to take all traffic: confirm the commit is live (`list_deploys`) before trusting a test. What this rests on: every public request reaches the app through Cloudflare and then Render's router, which writes the last entry itself. A caller already inside our own Render private network could write the whole chain, so the address lock adds nothing against one; it would still need the key. **Limits.** `crm_buy_per_order_cap_usd`, `crm_buy_daily_cap_usd` (buys a CRM key asks for, checked in `sub_finder_buy`; NULL = none) and `gt_offer_rebate_max_pct` (NULL = the sale total). **Record.** `sub_finder_audit`: one row per buy, offer or loss-limit change asked through the API, refusals included; `GET /audit`. **Rotate a key:** issue the new one, add its `sub_finder_key` row, then `UPDATE mcp_api_keys SET revoked_at = now() WHERE id = <old>;` (refused from its next call). **Label and feed.** `sub_finder_need2buy` now matches `status = 'need2buy'` only; `n2b_decisions_enabled` and `auto_buy_enabled` are off since 2026-11-16 at the CRM's request |
| 19 | A second hostname for the API (temporary, operator 2026-11-16) | `render-subs-api.yaml` runs `core/subs_only.py`: the same `/api/v1/subs` router on a Render service of its own, with no storefront and **no worker**. Same database, so keys, the address lock, limits and the audit log are the same on either host; a buy or offer asked there is carried out by the main service's workers. Its counters for the per-key rate and the per-address ceiling are its own. It needs only `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, which Render copies from the main service. Starter plan since 2026-11-16 (operator: "pay the 7 for now"), so it is always on; it was created on the free plan, which sleeps after 15 idle minutes. It is still an `onrender.com` name; replace it with a custom domain when there is one. **Created 2026-11-16:** service `s4k-subs-api-siyb` (`srv-dbti97gu01pc73df7c40`), blueprint `exs-dbti89942hec73big7c0`, `https://s4k-subs-api-siyb.onrender.com`. A free-plan service receives `X-Forwarded-For: <caller>, <Cloudflare edge>, <10.x internal proxy>`, one hop more than the main service, so `10.0.0.0/8` was added to `sub_finder_config.trusted_proxy_cidrs`; the address lock was then checked live through this host, forged headers included |
| 20 | The box-office poll behind `/primary/events` and `/primary/listings` (mig `20261123171030`, section 6k) | Apply the migration, then `PRIMARY_POLL_LIVE=1` on the web service: a worker (`core/primary_poll_sync.py`) reads SI Tickets' events at Sports Illustrated Stadium and the Timberwolves' games. It wakes every 10 minutes (`PRIMARY_POLL_INTERVAL_SECONDS`, default 600: one slot) and at each wake reads only the events that are due. Cadences (operator 2026-11-23: "create update cadances based on event date and median price", "Let's set longest interval to 1 hour", "Redraw every cycle ... For events day of draw every 10 mins"; mig `20261123194030`) are rows: `primary_poll_cadence` (the ladder by days to the event: 10 minutes the day of, 30 minutes up to 2 days away or 5 for a Friday, Saturday or Sunday event, one hour further), `primary_poll_price_band` and `primary_poll_qty_band` (the shifts by median price and by tickets listed); change a row to change a cadence, e.g. `UPDATE primary_poll_cadence SET poll_every = interval '20 minutes' WHERE step = 2;`. Each read falls on a random slot of `primary_poll_config.slot` (10 minutes) inside the event's interval, redrawn every cycle (`primary_poll_next()`, stored as `primary_poll_event.next_poll_at`). The worker's interval must not be longer than the ladder's fastest step. `primary_poll_config` holds `listing_grace`, `due_slack`, `retry_after` and the fallback `listing_max_age` and stores them through `primary_poll_ingest()`, closing each pull with `primary_poll_run_done()` so the feeds serve the newest pull only. GET only. Check: `SELECT * FROM primary_poll_source;` and `SELECT source, poll_status, count(*), max(poll_ok_at) FROM primary_poll_event GROUP BY 1, 2;`. Off: unset the variable; within 35 minutes the feed stops sending listings by itself. **Timberwolves listings** are read by a second worker, a headless browser on its own service (`core/primary_poll_browser.py`, `render-primary-poll-browser.yaml`): create the service from the blueprint, set `PRIMARY_POLL_BROWSER_LIVE=1` on it, and set `PRIMARY_POLL_SOURCES=sitickets` on the web service, so each source has one poller. Without it the Timberwolves' games carry no listings. |
| 20 | The CRM sets its own limits (mig `20261116030000`, operator 2026-11-16: "the value should come from crm") | `sub_finder_crm_limit (kind, site, pct)`: `rebate_max` (0–100) and `buy_max_cost` (1–1000), percent of the sale total, `site` = the marketplace sold on or `*` for the default; set through `PUT /settings/limits` by a key that may buy or offer, history in `sub_finder_crm_limit_log`. `sub_finder_buy` and `sub_finder_gt_offer_request` read them. `sub_finder_config.gt_offer_rebate_max_pct` is now only S4K's outer bound (the lower of it and the CRM's applies) and is **NULL**: the 50 it held on 2026-11-16 was nobody's decision and was removed. `crm_buy_per_order_cap_usd` / `crm_buy_daily_cap_usd` remain S4K's dollar ceilings |
| 21 | Telling the CRM something changed (operator 2026-11-16: "just update crm upon ping") | Add a line to [What changed for you](#what-changed-for-you), newest first, in the form `- **YYYY-MM-DD** text`. `/ping` returns the ten newest as `news` once the change is deployed; no database change and no message to send. Write it for the CRM: no table names, no keys. |
| 22 | The health check the CRM reads (`GET /health`, mig `20261116210000`, operator 2026-11-16: "also add health check that feeds crm") | Nothing to switch. `sub_finder_health(key_id)` reads the last good run of each part and grades it against the two limits it returns: the CRM feed reader (`n2s_crm_direct_log`), the order book mirror (`s4kcs_orders.last_seen_at`), the caller's jobs and watched orders, the buy queue and its kill switch (`manual_sub_buy`, `manual_sub_buy_config`), GoTickets offers, `account_balance_run`, `mlb_ticket_sync` where it exists, and, since mig `20261124043030` (operator 2026-11-24: "add health of both sources to the api out health section"), each box office of `primary_poll_source` with its events from `v_primary_poll_events_feed` (a box office the workers have stopped on purpose reads `down` after an hour: there is no switch for it here). A part switched off here (`buy_enabled`, `gt_offer_enabled`, `manual_sub_buy_config.enabled`) reads `off`, not `down`. **The CRM sees `buying: down` whenever `manual_sub_buy_config.kill_switch` is on or a buy is `unknown`**, so check that buy on its market and clear it promptly (the paragraph under this table). To change a limit, change the function in a migration and the table in §2 with it. |
| 23 | The MLB schedule feed (`GET /mlb/schedule`, migs `20261116190000` collector + `20261116200000` feed, operator 2026-11-16: "send it inside the subfinder api to crm") | Nothing to switch: any key that may find subs may read it, with that key's rate and quota. It reads `v_mlb_schedule_feed`, so **the route answers 502 until `20261116200000` is applied**. The collector is cron `mlb_ticket_tick_1min` (one GET at a time to MLB's public ticketing schedule; each club and season re-read every 11 hours); it writes `mlb_ticket_game` and matches games to EVO events fill-only. Check it: `SELECT team_id, season, last_ok_at, last_games, last_error FROM mlb_ticket_sync ORDER BY last_ok_at NULLS FIRST;` and `SELECT game_type, count(*), count(ticket_url), count(tevo_event_id) FROM v_mlb_schedule_feed GROUP BY 1;`. Stop it: `SELECT cron.unschedule('mlb_ticket_tick_1min');` (the feed keeps serving what it has). The CRM sees the reader's state as the `mlb_schedule` check of `GET /health` (row 22). Source, tables and matching rules: `RESOURCES_BIBLE.md` §1, *MLB ticketing schedule*. |
| 24 | Accessible (ADA / wheelchair) seats (mig `20261117101530`, operator 2026-11-17: "it should also block because WC is ADA") | Nothing to switch, and no setting turns it off. `sub_finder_seat_is_ada(section, row)` decides what is accessible: the row test of `sub_finder_row_is_wheelchair`, or a section carrying `WC` / `ADA` as a word, `WC` straight after the section number with at most one letter between (`204LWC`, `103WC`), or the words wheelchair / accessible / handicap. `sub_finder_match` leaves out every listing whose answer differs from the sold seat's; `sub_finder_buy`, `sub_finder_gt_offer_request`, `sub_finder_autobuy` and `sub_finder_gt_offer_buy` refuse a cover or offer stored before the rule (`ada_seating`). A venue that marks accessible seats some other way is not recognised: add its marker to that one function. Check a label: `SELECT sub_finder_seat_is_ada('204LWC', '1');`. The N2S auto-buyer keeps its own row-only rule (`docs/d7_n2s_pipeline.md`). |
| 25 | What the results feed shows (mig `20261118172530`, operator 2026-11-18: "only show n2s within the timeframe allotted, ped is now merged into need2buy, and remove duplicates when it makes sense") | Nothing to switch. `GET /results` calls `sub_finder_feed(key, since, limit, offset, scope)`; `sub_finder_results` is kept as the same feed at scope `n2s`. `sub_finder_n2s_window(order)` decides where an order stands: `need2buy` for an item labelled `need2buy` or one from the PED list (`item_source = 'gmail'`), `n2s` for any other item, inside its time while the item is open and, for an alert, `timer_expires_at` is still ahead (operator 2026-11-18, asked which cut-off: "15 mins timer"); for need2buy, the event day has not passed (New York date). The CRM's "Find sub" button can look up an alert of any age; one older than 15 minutes is answered by `GET /orders/{n}` only. A row is shown when it is the order's one row, still watched and inside its time, or holds a purchase or offer not final for more than 7 days. **Buying is not changed**: a PED item is still report-only (`sub_finder_report_only`). See what the feed would show and why not: `SELECT order_number, watching, closed_reason, sub_finder_n2s_window(order_number) FROM sub_finder_order WHERE key_id = <account> ORDER BY updated_at DESC;`. The whole record: `GET /results?scope=all`. Nothing starts a lookup on an alert by itself, so an alert is in the feed only when someone looked it up inside its 15 minutes. |
| 26 | The Ticketmaster feeds (`GET /tm/events`, `GET /tm/markets`, mig `20261118220530`, operator 2026-11-18: "add the tmr discovery feed into the mlb api ... then add the sites it pairs to ... as a seperate get call") | Nothing to switch: any key that may find subs may read them. They read the views `v_tm_discovery_feed` and `v_tm_discovery_markets` over `tm_discovery_event`, which the mapping program's `tm_discovery_tick` fills (cron `tm_discovery_tick_hourly`, four calls an hour, hard budget 100 a day in `tm_discovery_quota`; mig `20261117180000`). The site ids in `/tm/markets` are the hub's (`aq_event_map`) first, then `event_xmap`, then the Vivid and TickPick catalogues matched to the same EVO event. Check the collector: `SELECT * FROM tm_discovery_quota ORDER BY day DESC LIMIT 3;` and `SELECT count(*), count(tevo_event_id) FROM tm_discovery_event;`. Stopping the collector is the mapping program's switch, not this API's: the feeds keep serving what is there. Since mig `20261118223540` (operator: "add and push all of them out including buy limits") `/tm/events` also serves 35 columns read from the stored response (`tm_discovery_event.raw`): ticket limits, SafeTix, on-sale end, times, notes, attractions, add-ons and venue detail; a value in an unexpected shape reads as null. The ticket-limit numbers are parsed from Ticketmaster's sentence by one regular expression in the view; check it with `SELECT ticket_limit, ticket_limit_numbers, ticket_limit_count FROM v_tm_discovery_feed WHERE ticket_limit IS NOT NULL AND ticket_limit_count IS NULL;`. Nothing is written to the hub: Discovery ids are text and the hub's Ticketmaster column is numeric, still an operator decision. |

Buying additionally needs the manual sub buy path live, exactly as for operator buys: `manual_sub_buy_config.enabled = true`, `kill_switch = false`, and `MANUAL_SUB_BUY_LIVE=1` on the web service. Its `per_order_cap_usd` and `daily_cap_usd` apply to CRM buys, automatic buys and operator buys together; EVO spend and GoTickets spend are each counted against the day ceiling on their own. An `unknown` outcome flips its kill switch and stops **all** buys on both markets until someone has checked the market named in `kill_reason`.

**Test the tax quote first (mig `20261113150000`):** `UPDATE manual_sub_buy_config SET tax_quote_test = true WHERE id;` makes the buy worker ask EVO for a quote on the **next buy only** and store the answer exactly as it came (or the error) in `manual_sub_buy.quote_raw`. Nothing else changes: no ceiling is checked, no signature is sent, and the buy goes ahead as usual. Once an answer is on file no more test quotes are asked. Read it with `SELECT buy_id, quote_raw FROM manual_sub_buy WHERE quote_raw IS NOT NULL;`, confirm the shape, then turn on the real check below.

**EVO's total before the buy (mig `20261113110000`, off by default):** `UPDATE manual_sub_buy_config SET tax_quote = true WHERE id;` makes the buy worker ask EVO what it will charge, tax included (`POST /v9/tax_quotes`, a calculation: nothing is bought), right before every buy, and send the quote's `tax_signature` with the order. For an **automatic one-to-one buy** the quoted total must be at most sale total × (1 + `auto_buy_max_loss_pct` / 100) — the automatic buy's own rule, applied to the real charge instead of our venue-tax estimate; over it, or with no usable quote, the row stops (`total_above_ceiling` / `tax_quote_failed`), nothing is bought, and the order's `buy` shows `stopped`. Buys a person or the customer agreed to (operator, CRM-confirmed, accepted GoTickets offer) have no such ceiling: the quote is recorded (`manual_sub_buy.quote_tax_usd`, `quote_total_usd`) and they go ahead, with or without it.

Other settings: `bg_settle_enabled` (reads no longer settle; the cron `sub_finder_settle_15s` does, mig `20261113260000`), `max_orders_per_job` (200), `pull_refresh` (2 minutes: a listing pull newer than this is reused), `settle_min_s` (20), `settle_timeout_s` (180: match with whatever has arrived), `rows_back` (5), `td_timeout_s` (150).

**To stop it:** `enabled = false` stops everything; `buy_enabled = false` stops new buy requests only; `auto_buy_enabled = false` stops automatic buys; `gt_buy_enabled = false` (or `manual_sub_buy_config.gt_enabled = false`) stops GoTickets buys; `buy_fallback_enabled = false` stops moving on to the next cover after a stopped buy; `gt_offer_enabled = false` stops new GoTickets offers (ones already sent are still followed); `td_enabled = false` stops TicketsData spend. Revoke a key with `SELECT mcp_revoke_key(<id>);`.

**EVO sales tax by venue** (mig `20261113070000`): `evo_venue_tax` holds the percent to expect per venue. Rows marked `observed` are learned hourly from our own EVO purchases (the highest tax ÷ subtotal seen there); to set one yourself: `INSERT INTO evo_venue_tax (venue_id, venue_name, tax_pct, source, note) VALUES (<tevo venue id>, '<name>', <pct>, 'manual', '<why>') ON CONFLICT (venue_id) DO UPDATE SET tax_pct = excluded.tax_pct, source = 'manual', note = excluded.note;` — a manual row is never overwritten. `sub_finder_config.evo_tax_default_pct` (0) applies to venues with no row. EVO does not tax every order at a venue, so the estimate can be high, not low.

**Where to look:** `sub_finder_job` / `sub_finder_order` (what was asked and answered), `sub_finder_td_pull` (each TicketsData call and how it ended), `manual_sub_buy` (every purchase, with `requested_by` naming the key and the person), `mcp_usage_daily` (calls per key; tools are named `subs.*`).

RULE 2 note: the one upstream write this API can cause besides the EVO buy is the GoTickets substitution request (`POST /rest/substitution-requests`, `gotickets_sub_client.py`, path-pinned, operator-authorized 2026-11-13), sent only after the CRM's yes. Its only way to spend money is a row in `manual_sub_buy`, bought by `core/manual_sub_buy.py` through the path-pinned `evo_buy_client.py`, or for a row whose `market` is `gotickets` through the path-pinned `gotickets_buy_client.py` (`POST /rest/pro/api/orders`, operator-authorized 2026-11-13). The order follow-up and every listing pull are GETs.

## 10. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `scopes` is empty | key not allow-listed yet, or the API is off — ask S4K |
| order is `unmapped` | no event id from you or the mirror, and the name + date did not match exactly one event; send `tevo_event_id` |
| order number in `not_found` | not in the CRM books we mirror (yet) and no section / row / qty sent; retry in a minute or send the row |
| job sits in `pulling` | a listing pull is slow; it is matched with whatever arrived after 3 minutes. Keep reading until it is `done` |
| a read answers 500 | rare: a dropped connection on our side; read again after 10 seconds |
| 403 on a buy for one order only | it is a PED order: report-only ([§5](#5-the-order-object)); or the buy is over a spending limit (`limit` in the answer); or it would swap an accessible seat and an ordinary one (`limit: "ada_seating"`) |
| 403 on every buy and offer | the call was sent with the read key, or with the buy key from an address that is not registered. `GET /ping` with the read key from the same server shows `your_ip`, the address to compare with what S4K registered |
| `no_cover` but you can see tickets on the site | different section spelling, a row more than 5 back, a quantity the seller will not split, or the listing appeared after the pull. Submit again |
| `price_above_ceiling` on a buy | the listing's price rose since the quote; submit the order again and buy from the new job |
| 409 on a buy | read the order: a live buy already exists for it (requested, being bought, bought, or unclear). A buy that stopped does not block a new one. If the sale was covered by hand at S4K there is nothing more to buy |
| `buy.seats` stays null | the seller has not published seat numbers; check again after `confirmed`, or look at the EVO order |
| `buy.total` is more than quoted | EVO added tax or a fee to that order; `price_ea` is still what was quoted |
| `buy.evo_order_id` is null on a bought order | the buy was sent to GoTickets: read `buy.market` and use `buy.order_id` |
| a GoTickets cover says `buyable: false` | GoTickets buying is switched off at S4K; a person buys it through `link` |
| an automatic buy stopped with `total_above_ceiling` or `tax_quote_failed` | EVO's total with tax was over the 5% loss limit, or EVO gave no total. Use the buy call if a person accepts the cost |
