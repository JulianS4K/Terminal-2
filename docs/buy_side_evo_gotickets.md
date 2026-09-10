# Buy-side process — EVO + GoTickets — REFERENCE ONLY, NOT IMPLEMENTED

**Doc version:** v3.0.0 (2026-09-10) — the buy is placed **by hand in the
vendor console** for both vendors (operator direction 2026-09-09), so the
former "blockers" are re-framed as the operator's fill list; adds the
who-supplies-what split now encoded in `n2s_buy_intent.operator_fills` vs
`payload_gaps` (mig 20260910170000). · v2.0.0 — **CORRECTION**: GoTickets DOES
have a purchase API (Pro API `POST /orders`); v1.0.0 stated it did not. Adds
the GoTickets flow, its `expectedTotal` guard, and the measured blockers. ·
v1.0.0 — first cut, TEvo `Orders/Create` + the verification gate.

> ## ⚠ NOTHING HERE IS IMPLEMENTED, AND IT CANNOT BE WITHOUT AUTHORISATION
>
> This is the vendor's documented order-placement flow, written down so it can
> be reasoned about. It is **not** a build plan and no code in this repo does
> any of it.
>
> `POST /orders` is exactly the endpoint CLAUDE.md **Rule 2** names as
> forbidden without explicit operator authorisation. `evo_client.py` is GET-only
> *by construction* — `ALLOWED_HTTP_METHODS = frozenset({"GET"})` plus an
> `_assert_readonly_method()` that raises — and two CI gates enforce it
> (`scripts/check_readonly.py`, `tests/test_readonly_guards.py`). Implementing
> this is therefore a **security-CRIT** change and a deliberate, audited
> exception, never a quiet edit.
>
> Everything the substitution pipeline produces today is **advisory**: it names
> a listing, a price and (for GoTickets) a link. A human buys.

## 1. The order flow, as TEvo documents it

| # | Step | Endpoint | Notes |
|---|---|---|---|
| 1 | Select a ticket group | `Listings/Index` | **We already have this.** `sub_listing_id` on every TEvo cover IS a `tevo_ticket_group_id`. |
| 2 | Create / reuse the client | `Clients/Create` | Returns `client_id`. Reuse for repeat buyers; do not create duplicates. |
| 3 | Client properties | per-property create | Company, email, phone, address, card. Create BEFORE the order and keep the ids. Each has a free-text `label` (≤20 chars). |
| 4 | Payment method | — | `credit_card` (Braintree only) or `offline`. |
| 5 | Delivery method | `Shipments/Suggestions` | Takes `ticket_group_id` + `address_id`, returns a suggested method. |
| 6 | Submit | `Orders/Create` | JSON POST body. |

## 2. The parts that can cost real money

- **`offline` means "I already took the payment."** The vendor's own warning:
  you must have received payment and completed fraud review *before*
  submitting. An offline order is an irreversible commitment made on our
  say-so. This is the single sharpest edge in the flow.
- **Card data never touches TEvo.** Storing a client card requires their
  Braintree integration, which vaults it and returns a token. Without
  Braintree the API will not process payment at all — we would have to take
  the money ourselves and then submit `offline`, i.e. the sharp edge above.
- **FedEx cannot ship to PO boxes**, and must be enabled per account. Prefer
  `service_type: LEAST_EXPENSIVE` — their algorithm picks the cheapest option
  that still arrives before the event, rather than us guessing a service level.

## 3. ⚠ THE VENDOR DOC ASSUMES THE WRONG SHAPE FOR SUBBING

It is written for a **consumer-facing resale site**: the client is *your
customer*, and tickets ship to them.

Covering an N2S order is not that. **We** are the buyer, settling an
obligation we already owe on a sale that already happened somewhere else. So:

- the "client" is us or a house account, not the end buyer;
- delivery must reach the ORIGINAL marketplace's buyer, on that marketplace's
  terms, not a TEvo shipping address we chose;
- there is no checkout, no fraud review, no customer to charge — the money
  moved on the original marketplace, days ago.

Anyone building against this page without noticing that will model a customer
purchase and then discover the delivery leg does not connect to anything.

## 4. Verification comes FIRST — `n2s_cover_verify()`

Operator direction 2026-09-09: *"first we verify if the orders are good to
buy."* That gate exists today and is read-only, so it is useful with or without
a buy path.

A cover is a claim about a listing that was live **up to an hour ago**, matched
against an order that was open **when the queue last refreshed**. Both can go
stale between the match and the purchase, and a stale one costs money in a way
a stale read never does. `n2s_cover_verify()` re-checks, per cover:

| verdict | meaning |
|---|---|
| `ok` | listing still present, price unchanged or lower, order still open |
| `price_up` | still there, but dearer than quoted — `price_now` says by how much |
| `gone` | listing no longer in the newest snapshot for that event |
| `order_closed` | the N2S order is terminal — already resolved or allocated |
| `stale_data` | no snapshot for that event inside the freshness window |

`gone` and `order_closed` are the two that must hard-block a purchase.
`price_up` is a judgement call and is surfaced with the delta rather than
silently re-ranked.

## 5. If a buy path is ever authorised

Not a proposal — the questions that would need answering first:

1. **Spend caps** per order and per day, enforced in SQL, not convention.
2. **Which sources** may auto-buy. GoTickets and TEvo are different
   integrations with different failure modes.
3. **Dry-run mode** that produces the exact request body and stores it without
   sending, so the flow can be reviewed against real covers.
4. **What happens when a listing vanishes between verify and purchase** — the
   window is small but non-zero, and this is where an unattended loop would
   lose money quietly.
5. **The delivery leg** (§3) — unresolved, and the reason none of the above
   matters yet.

---

# GoTickets — Pro API `POST /orders`

## ⚠ CORRECTION TO v1.0.0 OF THIS DOC

v1.0.0 said GoTickets had **no purchase API**. That was **wrong**, and the
mistake is worth understanding because it is easy to repeat: `gotickets_client.py`
is the *Broker Sales* API (`sc.gotickets.com`, `GET /rest/sales`) — the
**sell-side** book. Reading only that file leads to "there is nothing to POST to".

The buy side is a **different surface**: the **Pro API** at
`https://gotickets.com/rest/pro/api`. We ALREADY authenticate against it —
`gt_listings_poll_tick()` calls `gotickets.com/rest/pro/api/events/{id}/listings`
with the same `X-Broker-Api-Token`. The order endpoint sits right next to the
listings endpoint we poll every few minutes.

**Lesson: the absence of a capability in one client file is not evidence the
vendor lacks it.** Check the vendor's own API docs before concluding.

## The endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/payment-methods` | saved payment tokens (`token`, `cardLastFour`, `defaultPaymentMethod`) |
| GET | `/gift-cards` | gift card ids + `remainingBalance` |
| GET | `/events/{eventId}/listings` | listings; **pass `paymentMethodToken` to get `transactionRatePercentage`** |
| POST | `/orders` | create the order |

Auth: `X-Broker-Api-Token: base64(accessId:accessSecret)`, and the token needs
**Pro Access** enabled.

## `expectedTotal` is the safety valve — get it right

> `expectedTotal` — "order fails if actual total exceeds this"

This is a **native spend guard**, and better than anything we would bolt on:
the vendor refuses the order rather than overcharging. A wrong value fails in
two very different directions:

- **too low** → order rejected (`475 Price Changed Exception`). Safe, annoying.
- **too high** → **silent overpay**. This is the one that costs money.

The formula is theirs:

```
(displayPrice + tax) * quantity * (1 + transactionRatePercentage/100) = expectedTotal
```

⚠ **WE CANNOT CURRENTLY COMPUTE IT.** `gotickets_listings_snapshots` stores
`display_price`, `all_in_price`, `service_fee`, `face_value` — but **not `tax`**,
and **not `transactionRatePercentage`**, because that is only returned when the
listings call passes a `paymentMethodToken`, which our poller does not. So
`expectedTotal` must not be guessed from `all_in_price`: guessing high is
exactly the unsafe direction.

## Who supplies what (2026-09-10)

The buy is placed **by hand in the vendor console**, for both TEvo and
GoTickets. So the fields an order needs are not one undifferentiated list of
things we are missing — they split by **who owes them**, and the intent row
records that split (`n2s_buy_intent.operator_fills` vs `.payload_gaps`,
mig 20260910170000).

### The operator fills these at checkout — normal, not a defect

| Field | Vendor | Why it is theirs |
|---|---|---|
| `client_id` / buyer account | TEvo | Chosen at purchase time; no single right answer to store. |
| `payment_method` / `paymentMethodToken` | both | `GET /payment-methods` → **200 `[]`** — Pro Access IS on (403 would say otherwise) but nothing is shared account-wide. A console buy uses the card on the page. |
| `delivery_method` / `deliveryMethodId`, `address_id` | both | Depends on how the cover will reach the buyer, decided per order. |
| `emailAddress`, `phoneNumber`, `billingAddress` | GoTickets | Purchaser identity, entered at checkout. |
| `expectedTotal` | GoTickets | The **API-side** spend guard. A person at the checkout page sees the real total and confirms it by eye — the same guard, performed manually. We still cannot compute it (no `tax`, no `transactionRatePercentage`), so it must not be re-listed as ours. |
| `recipient` | GoTickets | **Permanently theirs.** See below. |

### Our side owes these — a real defect when absent

| Field | When it is missing | Consequence |
|---|---|---|
| `gt_event_id` | the TEvo event is not mapped into `gotickets_event` | The operator cannot even open the listing page. |
| a purchase path at all | the match came from SeatGeek or TicketsData | There is nothing for a human to open; the match is informational only. |

`payload_ready` reports on **this second table only**. If the operator's
checkout fields counted against it, no intent would ever read ready and the
flag would carry no information at all — and a genuine gap would be skimmed
past along with "type in your card number".

## The one thing manual entry does not solve

`recipient` is required for Mobile Transfer, Print at Home, UPS shipping and
custom delivery — i.e. most sub scenarios. For a cover the tickets must reach
the **original marketplace's buyer**, whose contact details live on
StubHub/Vivid/SeatGeek and are **not in the N2S feed**: `n2s_items` strips
`customer_name` and `customer_email` at the door, from the column list and out
of `raw` (mig 20260910030000).

That is a design decision, not a setting. Either the cover is delivered through
the original marketplace's own transfer flow (and the vendor ships to us), or
customer PII enters this system — a separate conversation with its own
consequences. Buying manually does not change it; it only moves the question
from a NULL field to a person sitting at a checkout page with nowhere to send
the tickets.
