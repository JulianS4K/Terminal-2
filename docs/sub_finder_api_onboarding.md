# S4K Sub Finder API — onboarding

> **Doc version:** v1.6.6 (2026-11-13) — while a GoTickets sub offer is out for an order we stop pulling listings and re-matching it; SeatGeek is pulled on every round for watched orders (mig `20261113120000`). · v1.6.2 (2026-11-13) — the automatic buy also takes a same-section cover at a loss of 5% of the sale or less; a finished buy shows `profit_actual` / `gate_actual`. · v1.6.1 (2026-11-13) — an EVO cover's `total` and `profit` now include the sales tax we expect at that venue (`subtotal`, `tax_pct`, `tax_est` on the cover). · v1.6.0 (2026-11-13) — order details, sale price and live status now come from the marketplace's own order feed first (GoTickets, TickPick, Vivid, SeatGeek, EVO), the CRM's books second; `order_source` gains `api`. · v1.5.1 (2026-11-13) — the automatic buy takes a cover at breakeven or profit; the 10% minimum is gone. · v1.5.0 (2026-11-13) — GoTickets orders: `sub_offer` on the order and `POST /orders/{n}/offer-sub`, the CRM's yes to offering the customer a gate 3–5 sub through GoTickets ([§7a](#7a-offer-a-sub-to-a-gotickets-customer)). · v1.4.1 (2026-11-13) — a confirmed buy ([§7](#7-buy-an-evo-cover)) is checked against our own order books first. · v1.4.0 (2026-11-13) — every cover now carries the N2S **gate** and label; other sections in the same zone are searched when the order's own section has nothing ([§8](#8-how-matching-works-and-what-it-does-not-do)); each order says what to do next in `action`; the clean one-to-one EVO cover can be **bought automatically** (off by default, $1,000 a day). · v1.2.0 (2026-11-12) — the integration we ask for is now one **"Needs sub" checkbox** that alerts us with the order number (`POST /orders/{n}/needs-sub`); the doc leads with it. · v1.1.0 (2026-11-12) — simplified around how the CRM holds orders: send just order numbers or the CRM's own rows, and read / buy by order number with no job id. · v1.0.0 (2026-11-12) — first version: find substitutes for any order (EVO, GoTickets, SeatGeek, then TicketsData as a fallback), sync results with `updated_since`, ask for an EVO cover to be bought and follow it to confirmed / rejected with seat numbers.

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

## 7. Buy an EVO cover

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
              "rebate": 60.00, "request": null}
```

| Gate | What we do |
|---|---|
| 1, 2 | nothing to offer: the seats are in the same section, same or better row. `sub_offer` is null |
| 3, 4 | `ask_crm: true`. On your yes we offer the customer those seats |
| 5 | `ask_crm: true`, with `rebate` = sale total − sub total (a gate 5 sub is always cheaper). On your yes we offer the seats with that rebate |
| 6 | `results_only: true`. Never offered; you only get the results |

**Say yes:** `POST /api/v1/subs/orders/{order_number}/offer-sub` with `{"listing_id": "<sub_offer.listing_id>"}` (optional `market`, `requested_by`). You may name another cover of the same order instead, as long as it is gate 3, 4 or 5. Answers 202 `{"offer_id", "state": "requested", "gate", "section", "row", "rebate"}`. Saying nothing means no offer is made.

We then send GoTickets one substitution request for that order and keep reading its status. Re-read the order: `sub_offer.request` shows `state` (`requested` → `sent`, or `stopped` with `reasons`, or `unknown`) and GoTickets' own `status` (`PENDING`, `CUSTOMER_REVIEW`, `ACCEPTED`, `DENIED`, `CANCELLED`, with `denial_reason`).

Rules:
- Needs the scope `subs:offer` (see `ping`). Without it the route answers 403.
- The order must be in our own copy of the GoTickets order book with the same seats and quantity. Alert us with the order number only; an order sent with its own details cannot be offered.
- One live offer per order. After a denial or a stop you may confirm another cover.
- **While an offer is out we leave the order alone** (mig `20261113120000`): no fresh listings are pulled for it and its `best` / `covers` are not re-matched, so the order keeps showing what the customer was offered. That holds from your yes until the offer is stopped, denied or cancelled (then the usual re-checking resumes), and after an acceptance. The order still closes as usual.
- **When the customer accepts and the offered seats are an EVO listing, we buy them** (when S4K has this switched on): exactly the quantity sold, at no more than the quoted price, inside the daily automatic-buy cap. The order then shows `action: "auto_bought"` and a `buy` to follow as in [§7](#7-buy-an-evo-cover); `sub_offer.request.buy` says `buy_requested`, or why we did not buy (`auto_buy_off`, `order_closed`, `not_on_evo`, `needs_spare_ticket`, `already_bought_for_this_sale`, `over_daily_cap`). The listing can sell while the customer decides; then the buy stops and you are told.
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

Buying additionally needs the manual sub buy path live, exactly as for operator buys: `manual_sub_buy_config.enabled = true`, `kill_switch = false`, and `MANUAL_SUB_BUY_LIVE=1` on the web service. Its `per_order_cap_usd` and `daily_cap_usd` apply to CRM buys, automatic buys and operator buys together. An `unknown` outcome flips its kill switch and stops **all** manual buys until someone has checked EVO.

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
