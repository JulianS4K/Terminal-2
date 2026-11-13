# S4K Sub Finder API — onboarding

> **Doc version:** v1.6.12 (2026-11-13) — the fields we ask the CRM to add to its N2S feed (decision, confirm, rebate, order status); the CRM can start a lookup by labelling an item `need2buy` in its own N2S feed, which we already poll (mig `20261113160000`). · v1.6.10 (2026-11-13) — §9: `tax_quote_test`, the tax quote's first run only stores EVO's raw answer (mig `20261113150000`). · v1.6.9 (2026-11-13) — §6a: a `notes` field the CRM can write on an order, with the alert or through `POST /orders/{n}/notes` (mig `20261113140000`). · v1.6.8 (2026-11-13) — covers carry `flags` / `confirm_needed`; a flagged cover is never bought automatically and the CRM's yes needs `"confirm": true`; a single ticket auto-buys only into the exact row, another row is an offer the CRM may bypass (mig `20261113130000`). · v1.6.7 (2026-11-13) — the buy path can ask EVO for its total, tax included, before buying (`manual_sub_buy_config.tax_quote`, mig `20261113110000`): an automatic buy stops when that total breaks its rule. · v1.6.6 (2026-11-13) — while a GoTickets sub offer waits for the customer we stop pulling listings and re-matching the order; once accepted, polling resumes and matching EVO seats are bought; SeatGeek is pulled on every round for watched orders (mig `20261113120000`). · v1.6.4 (2026-11-13) — GoTickets offers: the rebate amount is now yours to send (`rebate_amount`); we only suggest one. · v1.6.2 (2026-11-13) — the automatic buy also takes a same-section cover at a loss of 5% of the sale or less; a finished buy shows `profit_actual` / `gate_actual`. · v1.6.1 (2026-11-13) — an EVO cover's `total` and `profit` now include the sales tax we expect at that venue (`subtotal`, `tax_pct`, `tax_est` on the cover). · v1.6.0 (2026-11-13) — order details, sale price and live status now come from the marketplace's own order feed first (GoTickets, TickPick, Vivid, SeatGeek, EVO), the CRM's books second; `order_source` gains `api`. · v1.5.1 (2026-11-13) — the automatic buy takes a cover at breakeven or profit; the 10% minimum is gone. · v1.5.0 (2026-11-13) — GoTickets orders: `sub_offer` on the order and `POST /orders/{n}/offer-sub`, the CRM's yes to offering the customer a gate 3–5 sub through GoTickets ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)). · v1.4.1 (2026-11-13) — a confirmed buy ([§7](#7-buy-an-evo-cover)) is checked against our own order books first. · v1.4.0 (2026-11-13) — every cover now carries the N2S **gate** and label; other sections in the same zone are searched when the order's own section has nothing ([§8](#8-how-matching-works-and-what-it-does-not-do)); each order says what to do next in `action`; the clean one-to-one EVO cover can be **bought automatically** (off by default, $1,000 a day). · v1.2.0 (2026-11-12) — the integration we ask for is now one **"Needs sub" checkbox** that alerts us with the order number (`POST /orders/{n}/needs-sub`); the doc leads with it. · v1.1.0 (2026-11-12) — simplified around how the CRM holds orders: send just order numbers or the CRM's own rows, and read / buy by order number with no job id. · v1.0.0 (2026-11-12) — first version: find substitutes for any order (EVO, GoTickets, SeatGeek, then TicketsData as a fallback), sync results with `updated_since`, ask for an EVO cover to be bought and follow it to confirmed / rejected with seat numbers.

For the CRM team. You send us orders that need a substitute ("sub"); we pull fresh listings, and you read back the best replacement tickets for each order. If you are allowed to, you can also ask us to buy an EVO replacement and then follow that purchase until the seller confirms or rejects it.

Code: `routers/subs_api.py` · SQL: migrations `20261112000000` (buy follow-up) and `20261112010000` (the API) · operator switches: [§9](#9-for-s4k-operators-switching-it-on).

**Contents:** [The one thing to build](#the-one-thing-we-ask-you-to-build-a-needs-sub-checkbox) · [1 Quick start](#1-quick-start-5-minutes) · [2 Access](#2-access-keys-limits-errors) · [3 Submit orders](#3-submit-orders) · [4 Read results](#4-read-results) · [5 The order object](#5-the-order-object) · [6 Keep in sync](#6-keep-in-sync) · [7 Buy an EVO cover](#7-buy-an-evo-cover) · [8 Rules and limits](#8-how-matching-works-and-what-it-does-not-do) · [9 Operators](#9-for-s4k-operators-switching-it-on) · [10 Troubleshooting](#10-troubleshooting)

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
| `cover` | the `best` cover: market, section, row, quantity, price, profit or loss, and its `link`. A **Buy** button if `best.buyable` is true and your key may buy ([§7](#7-buy-an-evo-cover)) |
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

- **The label.** Set the item's `status` (or `status_label`, or `label_status`) to `need2buy`. Spacing, case and punctuation do not matter (`Need2Buy`, `need-2-buy`, `need_to_buy`, `N2B` all count).
- **What we take from the item.** Its `order_number` and `marketplace`. Everything else we look up ourselves, as for an alert. `seller_notes` becomes the order's `notes`.
- **Reading the answer** is unchanged: `GET /api/v1/subs/orders/{order_number}` or the sync feed, with your key. Your API has no write surface, so we write nothing back to the CRM.
- **It takes the whole path**, the automatic buy included ([§8](#8-how-matching-works-and-what-it-does-not-do)). An item in the feed that is not labelled `need2buy` is left to the Need-to-Sub pipeline as before.
- **Taking the label off** (or resolving the item) stops the watch: `closed_reason` `left_crm_n2s`. Labelling it again starts a fresh lookup.
- The checkbox call above still works and can be used alongside the label.

### What we ask you to add to your N2S feed

The label starts a lookup. With the additions below, the rest of the conversation could run through the same feed, and you would not have to call us for anything except reading the answer. They are in the order that helps most. **None of these is read yet except where it says "read today"**: tell S4K which you can add and under what names, and we wire each one as it appears.

**A. So we see a labelled item quickly**

| Ask | Why |
|---|---|
| `need2buy` as a real status in `GET /n2s/meta`, usable as `GET /n2s/items?status=need2buy` | we could ask for exactly the labelled items instead of scanning the book |
| newest change first by default, or `sort=updated_at&order=desc` honoured on `GET /n2s/items` | our 30-second poll reads the first 150 items; a newly labelled item must be among them |
| `updated_since=<instant>` on `GET /n2s/items` | lets us ask only for what changed, however large the book is |

**B. So your decision reaches us without a call**

| Field on the item | Values | Replaces | What we would do |
|---|---|---|---|
| `sub_decision` | `buy` · `offer` · `none` | the buy and offer-sub calls | `buy`: buy the listing named below. `offer`: send the GoTickets substitution. `none`: do nothing |
| `sub_listing_id`, `sub_market` | the `listing_id` and `market` of the cover you chose, exactly as we returned them | `listing_id` in those calls | act only on a cover we quoted for that order |
| `sub_confirm` | `true` when a person has seen the cover's `flags` and accepts them | `"confirm": true` | required for a flagged cover, and for buying a one-ticket cover in another row instead of offering it |
| `sub_rebate_amount` | dollars, `0` allowed | `rebate_amount` | sent with a GoTickets offer; required when the sub is rows back |
| `sub_decided_by`, `sub_decided_at` | who, and a UTC instant | `requested_by` | we act **once per `sub_decided_at`**, so a decision is never carried out twice; change the instant to decide again |

**Which answer each gate and suffix needs.** These are the only responses we need from you; everything else we decide or do ourselves.

| What the best cover is | What we do by ourselves | The answer we need in your feed |
|---|---|---|
| Gate 1 `Index`, on EVO, no suffix (a one-ticket order: exact row) | buy it | none |
| Gate 2 `S4KTrading`, on EVO, loss of 5% of the sale or less, no suffix | buy it | none |
| Gate 1 or 2 that we did not buy (loss over 5%, or over a spending limit) | nothing | `sub_decision: buy` + `sub_listing_id` |
| Gate 1 or 2 on GoTickets / SeatGeek / TicketsData markets | nothing: we can only buy on EVO | none; a person buys it through `link` |
| Gate 3 `Index offer subs` / gate 4 `offer subs s4ktrading` | nothing | GoTickets order: `sub_decision: offer` + `sub_listing_id`. Other marketplaces: you ask the buyer, then `sub_decision: buy` if the cover is on EVO |
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

After a GoTickets customer accepts and the offered seats are gone (`accepted_next: "new_sub_needed"`), the same tables apply to `new_best`: send a new answer with a new `sub_decided_at`.

**C. So we stop sooner and match better**

| Field on the item | Why |
|---|---|
| `order_status` (`open` · `cancelled` · `delivered` · `rejected`) | we stop watching the moment you know the sale is over, instead of waiting for the marketplace's feed |
| `marketplace_order_id` when it differs from `order_number` | GoTickets substitutions are sent against GoTickets' own order id |
| `in_hand_date`, `delivery_type` (read today when present) | so we do not suggest tickets that cannot be delivered in time |
| `seller_notes` (**read today**: becomes the order's `notes`) | your notes travel with the order |

**What stays as it is.** We cannot write to the CRM, so you still read our answer from us: `GET /api/v1/subs/orders/{order_number}` or the sync feed. If you would rather we called you when an answer changes, give S4K a URL and we can add that.

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

# 3. Optional, if your key may buy: buy the EVO cover you were quoted, then keep reading
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

**Authentication.** Send the key as `X-API-Key: <key>` (preferred) or `Authorization: Bearer <key>`. A key only works here after S4K has added it to the sub finder's allow-list, and it only ever sees the jobs it submitted.

**`GET /api/v1/subs/ping`** tells you what the key may do:

```json
{"ok": true, "key_label": "crm", "scopes": ["subs:find", "subs:buy"],
 "max_orders_per_job": 200, "ticketsdata_fallback": true, "generated_at": "2026-11-12T20:00:00.000000Z"}
```

| Scope | Means |
|---|---|
| `subs:find` | may submit orders and read results |
| `subs:buy` | may also ask for an EVO cover to be bought |

An empty `scopes` list means the key is valid but not yet allow-listed (or the API is switched off).

**Limits.** Each key has a per-minute rate and a daily call quota (defaults 60 per minute and 2,000 per day; S4K can raise them). Every call counts, including polls. There is also a per-IP ceiling of 600 calls per minute on this path.

**Errors.** Every error is JSON: `{"error": "<code>", "detail": "<human text>"}`.

| HTTP | `error` | Meaning | What to do |
|---|---|---|---|
| 401 | `unauthorized` | key missing, wrong, revoked or expired | check the header and the key |
| 403 | `forbidden` | key not allow-listed, API off, or buying not enabled for it | ask S4K |
| 404 | `not_found` | no such job / order for this key | check the ids; jobs are per key |
| 409 | `conflict` | a buy already exists for this order or sale, or the order number repeats in the job | read the order to see the existing buy |
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

**`GET /api/v1/subs/jobs/{job_id}`** — the whole job with every order; use it for batches. Reading (either route, or the sync feed in [§6](#6-keep-in-sync)) is also what moves a job forward, so keep polling.

| `status` | Meaning |
|---|---|
| `pulling` | fresh EVO / GoTickets / SeatGeek listings are being fetched |
| `pulling_td` | those are matched; TicketsData is being asked about the orders still uncovered |
| `done` | every order is answered |

```json
{"job_id": "...", "status": "done", "order_count": 30, "created_at": "...", "done_at": "...",
 "summary": {"cover": 23, "no_cover": 6, "unmapped": 1},
 "items": [ { "...order object..." } ]}
```

Suggested polling: every 10 seconds; expect `done` in 20 seconds to 3 minutes, a little longer when TicketsData is involved. Results are a snapshot from that moment: listings sell, so act on them soon, and submit again for a fresh look.

**`GET /api/v1/subs/jobs/{job_id}/orders/{order_number}`** — the same single-order read, pinned to one job (for when you submitted the same order more than once and want an older answer).

## 5. The order object

| Field | Meaning |
|---|---|
| `job_id`, `order_number`, `site`, `section`, `row`, `qty`, `sold_ea`, `venue` | the order as we understood it |
| `order_source` | where its details came from: `api` (the marketplace's own order feed), `n2s` or `marketplace` (our mirror of that CRM book), `request` (you sent them) |
| `notes`, `notes_at` | your own free text on this order and when it was last written ([§6a](#6a-notes-on-an-order)); null when none |
| `tevo_event_id`, `event_name`, `event_date` | the event we matched it to |
| `state` | `pending` (not answered yet) · `cover` · `no_cover` · `unmapped` (event not recognised) |
| `action` | what to do with the answer: `auto_bought` (we bought it, see `buy`) · `buy_manually` (a same-section, same-or-better cover exists: buy it yourselves) · `offer` (only a move to another section or rows back was found: ask the buyer first, then buy it yourselves) · `review` (the only cover costs more than twice the sale) · `none` |
| `sub_offer` | GoTickets orders only: the sub we can offer the customer and how that offer stands ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)); otherwise null |
| `auto_buy_note` | why we did not buy it automatically ([§8](#8-how-matching-works-and-what-it-does-not-do)); null when we did |
| `best` | the recommended cover: lowest gate first, then cheapest total. Null without a cover |
| `covers` | up to 3 covers per market, best first |
| `markets_searched` | which sources were searched for this order |
| `ticketsdata` | the fallback's status for this order (see [§8](#8-how-matching-works-and-what-it-does-not-do)); null when it was not needed |
| `buy` | the purchase, if one was requested ([§7](#7-buy-an-evo-cover)); otherwise null |
| `updated_at` | last change to this order — the sync cursor field |

**A cover:**

| Field | Meaning |
|---|---|
| `market` | `evo`, `gotickets`, `seatgeek`, or via TicketsData: `stubhub`, `viagogo`, `vivid`, `tickpick`, `gametime`, `ticketmaster` |
| `source` | `native` (our own feed) or `ticketsdata` |
| `listing_id` | the market's listing id |
| `section`, `row` | where the replacement seats are |
| `row_relation` | `better`, `same`, or `back` (up to 5 rows behind — the customer is being moved back) |
| `gate`, `label` | which rule the cover passed, 1 (best) to 6, and its name as the N2S desk uses it ([§8](#8-how-matching-works-and-what-it-does-not-do)). `gate` is null and the label is `over 200% of sale` for a same-section cover that costs more than twice the sale |
| `needs_buyer_ok` | true for gates 3 to 6: the buyer is moved to another section or further back, so they must agree first |
| `flags`, `confirm_needed` | what is off about this cover, as codes: `zone_unverified` (rows back and neither seat has a known zone), `obstructed_view`, `single_ticket_row_differs` (a one-ticket order, and the sub is not in the row that was sold), `repost_single` (the listing forces one more ticket than was sold), `no_sale_price`. `confirm_needed` is true when there is any flag: we never act on such a cover by ourselves, and your yes must carry `"confirm": true` ([§7](#7-buy-an-evo-cover), [§7a](#7a-offer-a-sub-to-a-gotickets-customer)) |
| `zone` | the curated zone of the replacement seats, on covers from another section |
| `view` | `obstructed` when the listing says so; otherwise null |
| `listing_qty` | tickets in the listing |
| `buy_qty` | how many you would have to buy; can be `qty + 1` when the seller only sells the lot whole |
| `spare` | `buy_qty - qty`: tickets left over to resell |
| `price_ea`, `total` | listed price per ticket, and the expected cost for `buy_qty`. On EVO the total **includes the sales tax we expect at that venue** |
| `subtotal`, `tax_pct`, `tax_est` | the listed cost for `buy_qty`, the venue's expected EVO sales tax percent, and that tax in dollars (0 on other markets, and at venues where EVO has never taxed us) |
| `profit` | `sold_ea × qty − total`; negative is a loss. Null without `sold_ea` |
| `price_note` | `before buyer fees` on StubHub and Viagogo, where the checkout price is higher than shown |
| `link` | where to see it. The listing itself for EVO (and SeatGeek when available), the event page otherwise; can be null |
| `buyable` | true only for EVO — the only market this API can buy on |
| `listing_seen_at` | when we last saw the listing |

Loss-making covers are returned on purpose, with the loss in `profit`. Deciding what loss is acceptable is yours.

## 6. Keep in sync

**`GET /api/v1/subs/results?updated_since=<instant>&limit=<1-1000>&offset=<n>`** — every answered order of your key that changed at or after `updated_since`, oldest change first, in the CRM's own envelope:

```json
{"count": 200, "total": 431, "limit": 200, "offset": 0,
 "items": [ "...order objects..." ], "generated_at": "2026-11-12T20:05:11.482913Z"}
```

The mirror recipe, same as the CRM's N2S feed:

1. First run: call with no `updated_since`; page with `offset` until `offset + count >= total`.
2. Save the `generated_at` of the **first page** of that run.
3. Next run: pass it as `updated_since`. Repeat.

Upsert by (`job_id`, `order_number`). An order can come round more than once: you will see it again when its buy is requested, bought, confirmed or rejected, or when seat numbers arrive. Orders still `pending` are not in the feed.

Calling the feed also moves your open jobs forward, so a client that only ever syncs still gets its answers.

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

## 7. Buy an EVO cover

> **Single tickets (mig `20261113130000`).** A one-ticket order is bought automatically only into the exact row that was sold. A same-section cover in a better row is an offer: `action` reads `offer`, the cover has `needs_buyer_ok` and `offer_bypass: true`. Ask the buyer (on GoTickets, through [§7a](#7a-offer-a-sub-to-a-gotickets-customer): the order carries a `sub_offer` with `bypass_allowed: true`), or skip the offer and buy it here with `"confirm": true`.
>
> **Flagged covers (mig `20261113130000`).** A cover with `confirm_needed: true` is bought only when the body also carries `"confirm": true`. Without it the answer is 409 `{"error": "confirm_needed", "flags": [...]}` and nothing is requested.

Needs the `subs:buy` scope. Only covers with `"buyable": true` can be bought, and only one this job quoted for that order. This is how you confirm a sub as good to buy: we buy automatically only a gate 1 (`Index`) cover; any other EVO cover is bought only on this call.

Before buying we check the order against **our own copy of the order books** (mig `20261113030000`): it must be there with the same event, section, row, quantity and sale price, or the call answers 422. So alert us with the order number only; an order sent with its own details can be searched but not bought. A buy is also refused (409) when the Need-to-Sub auto-buy already has the order, or one of our order feeds marks the sale fulfilled, cancelled or rejected.

**`POST /api/v1/subs/orders/{order_number}/buy`** (newest job holding that order) or **`POST /api/v1/subs/jobs/{job_id}/orders/{order_number}/buy`** (a specific job)

```json
{"listing_id": "6833175743", "requested_by": "dana@crm"}
```

`requested_by` is optional free text naming the person; it is kept on the purchase record. Answers **202**:

```json
{"buy_id": 21, "state": "requested", "order_number": "659213629",
 "listing_id": "6833175743", "qty": 2, "max_price_ea": 65.98}
```

That is a request, not a purchase yet. What happens next, and what you see in the order's `buy` object:

| `buy.request_state` | `buy.outcome` | Meaning |
|---|---|---|
| `requested` | `none` | queued; our buyer picks it up within about 15 seconds |
| `buying` | `none` | being sent to EVO |
| `bought` | `pending` | EVO took the order; waiting for the seller. `evo_order_id` is set |
| `bought` | `confirmed` | the seller accepted. **This is the one that means you are covered** |
| `stopped` | `rejected` / `canceled` | the seller rejected or the order was canceled; nothing was bought. See `rejection_reason`. You may buy a different cover |
| `stopped` | `none` | we did not send it; `reasons` says why (below) |
| `unknown` | `none` | EVO did not answer clearly. A person at S4K checks; do not re-buy until told |

Once EVO's charge is known the `buy` also shows `profit_actual` (sale total − what EVO really charged, tax included) and `gate_actual` / `label_actual`: `1` `Index` when the buy made a profit, `2` `S4KTrading` when tax or price turned it into breakeven or a loss.

Follow it by polling `GET /api/v1/subs/orders/{order_number}` every 15 to 30 seconds, or just keep syncing: each change re-emits the order in the feed. We re-check EVO every 30 seconds at first, then less often, for up to 7 days.

**The `buy` object:**

| Field | Meaning |
|---|---|
| `buy_id` | our id for the purchase |
| `request_state`, `outcome` | as in the table above |
| `evo_order_id` | the Ticket Evolution order number — put this in your confirmation field |
| `seller_state`, `order_state` | EVO's own words (`pending`, `accepted`, `completed`, `rejected`, `canceled`) |
| `rejection_reason` | the seller's reason, when rejected or canceled |
| `qty`, `price_ea` | what was bought |
| `total` | what EVO charged. **Can be higher than `price_ea × qty`**: EVO adds a fee on some orders |
| `section`, `row` | the seats bought |
| `seats` | seat numbers, e.g. `["14","15","16","17"]`. Null until the seller provides them — often only after they accept, sometimes never (general admission, or sellers who do not publish seats) |
| `reasons` | why a request was stopped |
| `status_checked_at`, `final_at` | last EVO check, and when the outcome became final |

**Why a request is stopped before buying (`reasons`):**

| Reason | Meaning |
|---|---|
| `listing_gone` | sold or pulled since the job ran |
| `price_above_ceiling` | the price rose above what the job quoted; submit again for a fresh quote |
| `short_quantity`, `split_not_allowed` | the listing can no longer supply that quantity |
| `our_own_listing` | it is S4K's own inventory |
| `over_order_cap`, `over_daily_cap` | over S4K's spend ceilings; ask S4K |
| `unknown_format`, `no_seller_office`, `listing_read_failed`, `buy_failed` | EVO would not sell it as listed |

**Guarantees.**
- A purchase is sent to EVO **once** and never retried.
- One live purchase per sale: asking again for the same order, or for a sale S4K already bought by hand, answers 409.
- We never pay more per ticket than the job quoted.
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

**Say yes:** `POST /api/v1/subs/orders/{order_number}/offer-sub` with `{"listing_id": "<sub_offer.listing_id>"}` (optional `market`, `requested_by`, and `rebate_amount`: dollars to give the customer back). **You set the rebate; we never do.** For gate 5 it is required (send `0` for no rebate) and the call answers 422 with our suggestion if it is missing; for gates 3 and 4 it is optional. It must be between 0 and the sale total. `sub_offer.rebate` then shows what was offered. You may name another cover of the same order instead, as long as it is gate 3, 4 or 5. Answers 202 `{"offer_id", "state": "requested", "gate", "section", "row", "rebate"}`. Saying nothing means no offer is made.

If the cover is flagged (`confirm_needed`), add `"confirm": true`; without it the answer is 409 `{"error": "confirm_needed", "flags": [...]}` and nothing is sent to GoTickets.

We then send GoTickets one substitution request for that order and keep reading its status. Re-read the order: `sub_offer.request` shows `state` (`requested` → `sent`, or `stopped` with `reasons`, or `unknown`) and GoTickets' own `status` (`PENDING`, `CUSTOMER_REVIEW`, `ACCEPTED`, `DENIED`, `CANCELLED`, with `denial_reason`).

Rules:
- Needs the scope `subs:offer` (see `ping`). Without it the route answers 403.
- The order must be in our own copy of the GoTickets order book with the same seats and quantity. Alert us with the order number only; an order sent with its own details cannot be offered.
- One live offer per order. After a denial or a stop you may confirm another cover.
- **While an offer is waiting for the customer we leave the order alone** (mig `20261113120000`): no fresh listings are pulled for it and its `best` / `covers` are not re-matched, so the order keeps showing what the customer is being offered. That holds from your yes until the offer is accepted, stopped, denied or cancelled; then the usual re-checking resumes. The order still closes as usual.
- **When the customer accepts and the offered seats are an EVO listing, we buy them** (when S4K has this switched on): exactly the quantity sold, at no more than the quoted price, inside the daily automatic-buy cap. The order then shows `action: "auto_bought"` and a `buy` to follow as in [§7](#7-buy-an-evo-cover); `sub_offer.request.buy` says `buy_requested`, or why we did not buy (`auto_buy_off`, `order_closed`, `not_on_evo`, `needs_spare_ticket`, `already_bought_for_this_sale`, `over_daily_cap`). The listing can sell while the customer decides; then the buy stops and you are told.
- **After a denial or cancellation we check the sale before looking again** (mig `20261113120000`): GoTickets is read for the sale's own state, with our copy of the order as the fallback. If the sale is cancelled or delivered the lookup closes (`closed_reason` `order_cancelled` / `order_fulfilled`); otherwise the usual re-checking resumes and you may confirm another cover.
- **After the customer accepts** (mig `20261113120000`) we do not call the CRM: the order's `updated_at` moves, so it comes back in the sync feed ([§6](#6-keep-in-sync)) with these `sub_offer` fields, and the rest of the order is sent as normal (`best`, `covers`, `buy`):

| Field | Meaning |
|---|---|
| `accepted`, `accepted_at` | the customer said yes, and when |
| `offered_gone` | true when the seats that were offered are no longer listed; false while they are; null when we cannot tell yet |
| `accepted_next` | `buy_requested`: we are buying EVO seats, follow `buy` · `buy_manually`: the offered seats are still listed and we cannot buy them, buy them yourselves (the order's `action` reads `buy_manually` too) · `new_sub_needed`: the offered seats are gone and there was no one-to-one cover to buy |
| `new_best` | with `new_sub_needed`: the best cover now (`market`, `listing_id`, `section`, `row`, `gate`, `label`, `buy_qty`, `total`, `profit`); the order's `best` and `covers` carry the full detail |

- **What we buy after an acceptance.** The offered seats themselves, when they are an EVO listing. If they are gone, the acceptance buys nothing else: only the standing automatic one-to-one rule can ([§8](#8-how-matching-works-and-what-it-does-not-do): an EVO cover in the order's **original** section, same row or better, exact quantity, breakeven or better, or a small loss inside the limit). Any other gate is reported through `new_sub_needed` / `new_best` for you to decide.
- Accepted seats on GoTickets or SeatGeek are not bought by us. Buy them yourselves.
- Before sending we re-read the sale: a cancelled or already delivered sale, a different quantity, or a request already open stops the offer (`reasons`).
- `unknown` means we could not tell whether GoTickets received the offer. Check Seller Central; no second offer is sent for that order until S4K clears it.

## 8. How matching works, and what it does not do

**A cover is** a listing with:
- a row of the same kind as the order's (numbers with numbers, letters with letters),
- a quantity the seller's split rules allow, or a lot of exactly one more ticket (`spare: 1`),

that passes one of these gates. They are the N2S desk's own rules and names (`docs/d7_n2s_pipeline.md` §4a):

| `gate` | `label` | Seats | Cost |
|---|---|---|---|
| 1 | `Index` | same section, same or better row | less than the sale (a profit) |
| 2 | `S4KTrading` | same section, same or better row | up to 200% of the sale |
| 3 | `Index offer subs` | another section in the same zone, same or better row | a profit |
| 4 | `offer subs s4ktrading` | another section in the same zone, same or better row | up to 200% |
| 5 | `Index Down offer subs` | up to 5 rows back, same section or same zone | a profit |
| 6 | `Down offer subs S4KTrading` | up to 5 rows back, same section or same zone | up to 200% |

Words added to a label: ` zone unverified` (rows back in the same section, where we hold no zone map to confirm the price tier), ` obstructed view`, ` single ticket` (a one-seat sale), ` repost single` (one spare ticket has to be bought and resold), ` no sale price` (no `sold_ea`, so the cost rule could not be checked).

**Gates 3 to 6 are searched only when the order has no gate 1 or 2 cover.** An order with a same-section, same-or-better cover is shown only those. Gates 3 to 6 move the buyer, so they are offers: `needs_buyer_ok` is true and we never buy them.

A "zone" is a set of sections we have mapped as equivalent for that team and venue. Where we hold no map, other sections are not offered. Section spelling differences such as `FLR 3` / `Floor 3` are not always bridged — send sections as the marketplace shows them.

Parking passes and S4K's own listings are never offered.

**What we buy automatically.** When the operator has it switched on, an order that is still being watched and has no purchase gets ONE cover bought for it when all of this is true: the cover is on EVO, in the same section and the same or a better row, at a profit, at breakeven, or at a loss of no more than 5% of the sale total after the expected tax (gate 1 `Index`, or a gate 2 `S4KTrading` cover inside that limit; a profitable cover is always taken first), for exactly the quantity sold, with no obstructed view, the order is not in the Need-to-Sub book, the order is in our own copy of the marketplace order book with the same event, seats, quantity and sale price the cover was matched on, and the day's automatic buys stay under $1,000. The order then shows `action: "auto_bought"` and a `buy` to follow as in [§7](#7-buy-an-evo-cover). Anything else is never bought by us: you get the results and buy outside this API.

| `auto_buy_note` | Why it was not bought |
|---|---|
| `auto_buy_off` | automatic buying is switched off |
| `no_evo_one_to_one` | no EVO cover in the same section and row or closer at a profit, breakeven or a loss within the 5% limit (it may be on another market, a bigger loss, or only an offer) |
| `needs_spare_ticket` | the only EVO lot has one ticket more than the sale; we never buy extra |
| `obstructed_view` | the only one has an obstructed view |
| `profit_too_thin` | the profit is under S4K's minimum (currently none: breakeven is bought) |
| `needs_crm_confirm` | the one-to-one cover is flagged (`flags`, usually `single_ticket_row_differs`): confirm it yourselves with the buy route and `"confirm": true` |
| `n2s_order` | the order is in the Need-to-Sub book, which is handled separately |
| `not_in_our_books` | we could not find the order in our own copy of the order book, so we will not spend on it |
| `differs_from_our_books` | the details sent with the order differ from our copy; alert us with the order number only |
| `order_closed` | one of our order feeds marks the sale fulfilled, cancelled or rejected |
| `over_daily_cap` | it would take the day's automatic buys over the cap |
| `already_bought_for_this_sale` | a purchase already exists for this order |

**Sources, in order:**

1. **EVO, GoTickets, SeatGeek** — always, from a fresh pull.
2. **TicketsData** (StubHub, Viagogo, Vivid Seats, TickPick, Gametime, Ticketmaster) — **only for orders the first three found nothing for**, and only when `ticketsdata_fallback` is on. An order that already has a cover never triggers it.

| `ticketsdata` | Meaning |
|---|---|
| null | not needed, or the fallback is off |
| `searched` | asked; any covers found are in `covers` with `source: "ticketsdata"` |
| `failed` | TicketsData did not answer usably (timeout or rate limit); submit the order again later |
| `no_event_link` | we hold no StubHub id for this event, so it could not be asked |
| `over_limit` | the job had more events needing the fallback than one job may ask about; submit those orders in a separate job |

**Not included:**
- Seat numbers on covers. No listing feed carries them; they arrive on the `buy` after purchase.
- Buying on any market other than EVO.
- Webhooks. You poll or sync; we never call the CRM.
- Automatic buys of anything but the one-to-one EVO cover described above.
- Prices are as listed. `price_note` flags the two markets where checkout adds buyer fees.

## 9. For S4K operators: switching it on

Everything ships **off**. All switches are rows in `sub_finder_config` (one row); changing them is a prod write and needs the operator's say-so (CLAUDE.md §1).

| Step | What | How |
|---|---|---|
| 1 | Apply migrations `20261112000000`, then `20261112010000` | normal migration apply |
| 2 | Issue the CRM a key | `SELECT mcp_issue_key('crm sub finder', 'external', '<who>');` returns the key itself, once — hand it over and do not store it. Its id: `SELECT id FROM mcp_api_keys WHERE label = 'crm sub finder' AND revoked_at IS NULL;`. An external key also opens the public market-data `/mcp`, nothing internal |
| 3 | Turn the API on for that key | `UPDATE sub_finder_config SET enabled = true, key_ids = key_ids \|\| <id>;` |
| 4 | Optional: TicketsData fallback | `UPDATE sub_finder_config SET td_enabled = true;` — costs 12 credits + 1 report per event asked, at most `td_max_events_per_job` (6) events per job and 3 in flight |
| 5 | Optional: let the key buy | `UPDATE sub_finder_config SET buy_enabled = true, buy_key_ids = buy_key_ids \|\| <id>;` |
| 6 | Optional: automatic one-to-one buys (mig `20261113010000`) | `UPDATE sub_finder_config SET auto_buy_enabled = true;` — independent of step 5. Limits: `auto_buy_daily_cap_usd` (1000, counted per New York day over `manual_sub_buy` rows whose `requested_by` starts `sub finder auto`) and `auto_buy_min_profit_pct` (0 = breakeven or profit) and `auto_buy_max_loss_pct` (5: the biggest loss, as a percent of the sale total, a gate 2 cover may be bought at; 0 = breakeven only) |
| 7 | Optional: GoTickets sub offers (mig `20261113020000`) | `UPDATE sub_finder_config SET gt_offer_enabled = true, gt_offer_key_ids = gt_offer_key_ids \|\| <id>;` and `GT_SUB_OFFER_LIVE=1` on the web service. `gt_offer_auto_buy = true` also buys the EVO seats once the customer accepts (needs the manual sub buy path live; counts toward `auto_buy_daily_cap_usd`). Last tick: `GET /api/admin/gt-sub-offer/status`. Rows: `sub_finder_gt_offer` |
| 8 | Optional: take in `need2buy` items from the CRM's N2S feed (mig `20261113160000`) | `UPDATE sub_finder_config SET n2b_intake_enabled = true, n2b_key_id = <id> WHERE id;` — the lookups are filed under that key, which must be in `key_ids`. Up to `n2b_batch` (20) items a minute. What was handed over: `sub_finder_n2b_seen`. Our own Gmail-labelled N2B rows are not taken in |

Buying additionally needs the manual sub buy path live, exactly as for operator buys: `manual_sub_buy_config.enabled = true`, `kill_switch = false`, and `MANUAL_SUB_BUY_LIVE=1` on the web service. Its `per_order_cap_usd` and `daily_cap_usd` apply to CRM buys, automatic buys and operator buys together. An `unknown` outcome flips its kill switch and stops **all** manual buys until someone has checked EVO.

**Test the tax quote first (mig `20261113150000`):** `UPDATE manual_sub_buy_config SET tax_quote_test = true WHERE id;` makes the buy worker ask EVO for a quote on the **next buy only** and store the answer exactly as it came (or the error) in `manual_sub_buy.quote_raw`. Nothing else changes: no ceiling is checked, no signature is sent, and the buy goes ahead as usual. Once an answer is on file no more test quotes are asked. Read it with `SELECT buy_id, quote_raw FROM manual_sub_buy WHERE quote_raw IS NOT NULL;`, confirm the shape, then turn on the real check below.

**EVO's total before the buy (mig `20261113110000`, off by default):** `UPDATE manual_sub_buy_config SET tax_quote = true WHERE id;` makes the buy worker ask EVO what it will charge, tax included (`POST /v9/tax_quotes`, a calculation: nothing is bought), right before every buy, and send the quote's `tax_signature` with the order. For an **automatic one-to-one buy** the quoted total must be at most sale total × (1 + `auto_buy_max_loss_pct` / 100) — the automatic buy's own rule, applied to the real charge instead of our venue-tax estimate; over it, or with no usable quote, the row stops (`total_above_ceiling` / `tax_quote_failed`), nothing is bought, and the order's `buy` shows `stopped`. Buys a person or the customer agreed to (operator, CRM-confirmed, accepted GoTickets offer) have no such ceiling: the quote is recorded (`manual_sub_buy.quote_tax_usd`, `quote_total_usd`) and they go ahead, with or without it.

Other settings: `max_orders_per_job` (200), `pull_refresh` (2 minutes: a listing pull newer than this is reused), `settle_min_s` (20), `settle_timeout_s` (180: match with whatever has arrived), `rows_back` (5), `td_timeout_s` (150).

**To stop it:** `enabled = false` stops everything; `buy_enabled = false` stops new buy requests only; `auto_buy_enabled = false` stops automatic buys; `gt_offer_enabled = false` stops new GoTickets offers (ones already sent are still followed); `td_enabled = false` stops TicketsData spend. Revoke a key with `SELECT mcp_revoke_key(<id>);`.

**EVO sales tax by venue** (mig `20261113070000`): `evo_venue_tax` holds the percent to expect per venue. Rows marked `observed` are learned hourly from our own EVO purchases (the highest tax ÷ subtotal seen there); to set one yourself: `INSERT INTO evo_venue_tax (venue_id, venue_name, tax_pct, source, note) VALUES (<tevo venue id>, '<name>', <pct>, 'manual', '<why>') ON CONFLICT (venue_id) DO UPDATE SET tax_pct = excluded.tax_pct, source = 'manual', note = excluded.note;` — a manual row is never overwritten. `sub_finder_config.evo_tax_default_pct` (0) applies to venues with no row. EVO does not tax every order at a venue, so the estimate can be high, not low.

**Where to look:** `sub_finder_job` / `sub_finder_order` (what was asked and answered), `sub_finder_td_pull` (each TicketsData call and how it ended), `manual_sub_buy` (every purchase, with `requested_by` naming the key and the person), `mcp_usage_daily` (calls per key; tools are named `subs.*`).

RULE 2 note: the one upstream write this API can cause besides the EVO buy is the GoTickets substitution request (`POST /rest/substitution-requests`, `gotickets_sub_client.py`, path-pinned, operator-authorized 2026-11-13), sent only after the CRM's yes. Its only way to spend money is a row in `manual_sub_buy`, bought by `core/manual_sub_buy.py` through the path-pinned `evo_buy_client.py`. The order follow-up and every listing pull are GETs.

## 10. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `scopes` is empty | key not allow-listed yet, or the API is off — ask S4K |
| order is `unmapped` | no event id from you or the mirror, and the name + date did not match exactly one event; send `tevo_event_id` |
| order number in `not_found` | not in the CRM books we mirror (yet) and no section / row / qty sent; retry in a minute or send the row |
| job sits in `pulling` | a listing pull is slow; it is matched with whatever arrived after 3 minutes. Keep reading — a job only moves when it is read |
| `no_cover` but you can see tickets on the site | different section spelling, a row more than 5 back, a quantity the seller will not split, or the listing appeared after the pull. Submit again |
| `price_above_ceiling` on a buy | the listing's price rose since the quote; submit the order again and buy from the new job |
| 409 on a buy | read the order: a buy already exists for it. If the sale was covered by hand at S4K there is nothing more to buy |
| `buy.seats` stays null | the seller has not published seat numbers; check again after `confirmed`, or look at the EVO order |
| `buy.total` is more than quoted | EVO added a fee to that order; `price_ea` is still what was quoted |
