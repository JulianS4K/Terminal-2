# D7 · N2S ("Need to Sub") obligation-covering pipeline

> **Doc version:** v1.3.0 (2026-09-10) — §1: added **tier 3** (one seat over from a larger lot whose splits permit it), its two load-bearing caps and the measurement that rejected the unbounded version, plus the **global 200% cost ceiling** and its `sold_ea ≤ 0` carve-out. · v1.2.0 (2026-09-10) — §2: documented the **6-hour age-out**, done at the source inside the sync rather than as a DELETE job, with the flap trap that makes the obvious implementation self-defeating. · v1.1.0 (2026-09-10) — §4/§5: added **`N2S-A104`** (sign-in refused on an OAuth-only account) and the password-setup step, after finding every auth user on this project is Google-only with **no** Supabase password — so the documented `signInWithPassword` flow could not have worked for any existing account. · v1.0.0 (2026-09-10) — first cut. The D7 lane manual: what the pipeline
> does, the six stages it runs, the tables and crons that make up each one, the error-code
> registry, and how an external consumer plugs into the profitable-cover feed.

**Lane:** D7 (`PROJECT_BIBLE §2.3`) — a **named subset** of D0's terminal/broker surface.
**Not a session-start read.** Read `PROJECT_BIBLE.md` first; come here when working on N2S.

---

## 0. What problem this solves

We sell a ticket we do not hold. The marketplace order lands in the S4K CRM flagged
"needs to be substituted" — we owe the buyer seats and have to **buy replacements** before
the delivery timer expires. Doing that by hand means: read the order, find the event on
four marketplaces, eyeball which listings match the section/row/quantity we owe, work out
whether buying them loses money, and repeat. Per order. Against a clock.

This pipeline does all of that on a 1-minute loop and surfaces two things:

- **every** open obligation with its best available cover (the `subs.html` panel), and
- the subset where **buying the cover costs less than we sold for** — i.e. we still make
  money — as a live Supabase feed an external system can consume.

The pipeline never buys anything. It finds and prices covers; a human clicks the buy link.
That is a deliberate boundary, not a missing feature — see §6.

---

## 1. The six stages

Each stage writes a column the next stage reads. When something looks wrong, find the
stage that stopped rather than reading the whole chain — §4's error codes name the stage.

```
  CRM  ──▶ 1 INGEST ──▶ 2 MAP ──▶ 3 POLL ──▶ 4 MATCH ──▶ 5 QUEUE ──▶ 6 SURFACE
           n2s_items    tevo_      sources_   cover        n2s_cover_  panel +
                        event_id   pulled_at  candidates   queue       n2s_profitable_cover
```

### 1. Ingest — the CRM order book
`n2s_pull_items()` reads the CRM's read-only N2S endpoint (`crm.s4kcs.com/api/v1/n2s`,
scope `n2s:read`) and upserts into **`n2s_items`** keyed on `n2s_id`. Open obligations are
the non-terminal rows (`is_terminal = false`). `n2s_order_key` is the CRM's own order
reference — the column you use to look the order up in the CRM in real time; it is not
always the same string as `order_number`.

### 2. Map — obligation to a TEvo event
`n2s_map_events()` resolves each item's event text to a `tevo_event_id` via the AQ mapper.
Until this lands the obligation is invisible to every downstream stage: **an unmapped row
can never get a cover**, because there is no event to poll listings for.

> ⚠ **The FK landmine.** `evo_listings_poll_state.event_id` has a foreign key to
> `events.id`. Polling an event that is mapped but **not catalogued** raises `23503`, and
> because the cron runs `map(); pull();` in one transaction, the mapping rolls back with
> it. Guarded since migration `20260910330000` (the TEvo arm skips uncatalogued events and
> reports `evo_skipped_unknown`), and surfaced as `event_not_catalogued`. Do not remove
> that guard to "simplify" the poller.

### 3. Poll — four marketplaces, on demand
`n2s_pull_all_sources()` fans out to TEvo, SeatGeek, TicketsData and SeatData for every
mapped event with an open obligation, and stamps `n2s_items.sources_pulled_at`.

**Polling is triggered by the order, not by a timetable.** When an order arrives and maps,
its sources are pulled in the same tick — the operator's requirement was "poll as the order
comes in and is mapped and then give result". A slow safety-net sweep still runs behind it
so nothing sits forever if a trigger is missed.

Two guards matter and must both stay:
- a **fire-time in-flight guard** per source, so a double call does not re-fire 30 TEvo
  requests and re-queue 33 SeatGeek ones. Snapshot-freshness alone does **not** work here:
  async sources have no snapshot yet at the moment of the second call.
- a **separate budget** for newly-mapped events (`p_new_max`), so a burst of new orders
  cannot starve the steady-state refresh.

### 4. Match — two tiers
Per obligation, candidate listings at the same event are matched in two tiers and the
cheapest of the best tier wins.

- **Tier 1 — exact or split.** The lot is exactly the quantity we owe, or it is larger and
  our quantity is an allowed split (`o.quantity = ANY(l.splits)`). We buy exactly what we owe.
- **Tier 2 — one-seat over-delivery.** The lot is *one more* than we owe and is only
  sellable whole. We buy `qty + 1` and eat the spare seat. This exists because a 4-seat lot
  in the same section and row is often **cheaper in total** than the 3 we actually need.

- **Tier 3 — one seat over, from a *larger* lot.** The lot is bigger than `qty + 1`, and
  `qty + 1` is one of its permitted splits. This reaches inventory tiers 1b and 2 both miss:
  a 6-seat lot with splits `[2,4,6]` against an obligation of 3 matches neither (3 isn't a
  permitted split; the lot isn't 4) — but the seller *will* sell 4.

Tier order is the first sort key, so a tier-1 or tier-2 cover always outranks a tier-3 one
even when tier 3 is nominally cheaper: buying exactly what we owe beats a marginal saving
that leaves us holding a seat. A listing matching both tier 1b and tier 3 is assigned tier 1,
so we buy what we owe rather than one extra.

> ⚠ **Both caps on tier 3 are load-bearing.** It buys `qty + 1` and *never* a larger
> permitted split, and it is admitted only at `cover_cost ≤ 0`. Generalising to "the cheapest
> permitted split ≥ qty" was measured before being rejected: it reached 11 orders, **10 were
> worse than the cover that order already had**, and the one genuinely new cover was a
> **$2,022 loss**. Restrictive singleton splits like `[4]` on a 4-lot mean *buy all four or
> nothing*, so covering 2 costs 4 — and one case would have bought **6 seats to cover 1**
> ($4,244 against an $862 alternative). Tier 3 is the only arm whose admission depends on
> price, because it is the only one where we choose to buy a spare seat off a lot we were not
> otherwise touching.

**A global 200% ceiling applies to every tier.** A candidate is dropped unless
`sub_total ≤ 2 × sold value`, filtered *before* ranking so an over-cap candidate cannot
occupy one of the `p_per_order` slots a cheaper cover should have had.

> ⚠ **This hides covers that exist.** At cutover it removed 17 of 49 — the worst at 880%
> (sold 5 seats for $26.25, cover $231.05). None were profitable, so the external feed was
> unaffected, but the obligation does **not** go away when its cover is hidden: those orders
> now read "no cover" when the truthful statement is "a cover exists, above the ceiling".
>
> ⚠ The `sold_ea ≤ 0` carve-out is not sloppiness. A naive cap gives a zero-priced order a
> ceiling of zero, so *every* cover fails and the obligation becomes permanently uncoverable
> with no explanation — a live hazard, since `PROJECT_BIBLE §3` records GoTickets CRM orders
> carrying price `0.00`. When the ceiling cannot be computed, it is skipped, not enforced.

> ⚠ The whole-lot guard is symmetric on purpose: a lot equal to our quantity still has to
> be sellable whole (`l.splits IS NULL OR l.q = ANY(l.splits)`). Dropping either side of
> that lets us "buy" a lot the marketplace would not actually sell us in one piece.

### 5. Queue — one cover per obligation
`n2s_cover_queue_refresh()` writes the winning cover per obligation into
**`n2s_cover_queue`**, with `cover_cost = (sub_price_each × buy_qty) − (sold_price_each × qty)`.
**Negative `cover_cost` means we make money.** Allocation is greedy-FIFO: the oldest
obligation takes its best cover first. That is not globally optimal — see the drift note in
`KANBAN.md` (D7-PROD-2).

### 6. Surface — panel and feed
- **`v_n2s_orders`** joins items + queue and computes `has_cover` / `no_cover_reason`;
  `/api/broker/n2s-covers` serves it to `static/terminal/subs.html`.
- **`n2s_profitable_cover`** is a real **table** (not a view) holding only rows where
  `profit > 0`, synced by diff and published to Supabase Realtime. This is the external feed.

---

## 2. Why the feed is a table and syncs by diff

Two decisions here are easy to "clean up" into something broken.

**It must be a table.** Realtime replicates the write-ahead log, and a view produces no WAL
of its own. `v_n2s_orders` therefore cannot be the feed no matter how convenient it looks.

**The sync must be a diff.** The obvious implementation — delete all, insert all, once a
minute — emits a delete plus an insert for every row every minute. A subscriber then sees
constant churn and can never distinguish a real change from a rewrite; Realtime would be
technically working and practically useless. So `n2s_profitable_cover_sync()` writes only
genuine differences: new covers INSERT, changed covers UPDATE (behind an `IS DISTINCT FROM`
guard, so an identical row emits nothing), covers that stopped being profitable DELETE.
**A quiet minute produces zero events** — which is exactly what makes an event meaningful.

`REPLICA IDENTITY FULL` is set so a DELETE event carries the row that went away. With the
default (primary key only) a subscriber learns an `n2s_id` vanished but not which order it
was — useless for un-flagging something already shown to a human.

**Covers age out at 6 hours, at the source.** A cover whose underlying listing snapshot
(`captured_at`) is older than 6 hours is excluded from the sync's `src` set, so the existing
diff deletes it once and never re-adds it.

> ⚠ **Never re-implement this as a `DELETE … WHERE first_seen_at < now() - '6 hours'` job.**
> The sync is a per-minute diff: deleting a row that is *still* profitable just gets it
> re-INSERTed on the next tick with a fresh `first_seen_at`. That is a 6-hourly delete/insert
> **flap**, not an expiry — it emits phantom DELETE+INSERT events to every subscriber (each of
> which they must treat as real), and resets the very timestamp it ages on, so nothing ever
> expires. Any age measured on a *target-table* column is self-defeating for the same reason.
>
> `captured_at` is used because it survives a delete/insert round trip and is the honest
> measure of how old the market data behind a buy link is. `updated_at` would be wrong twice
> over: the sync writes only on genuine change, so it means *last changed*, not *last
> confirmed* — ageing on it would delete the most stable covers first. A NULL `captured_at`
> fails closed.
>
> In steady state this reaps nothing (the poller re-captures continuously). Its value is as a
> **deadman**: if the poll chain stalls, the feed empties itself within 6 hours instead of
> serving buy links priced against dead inventory. An empty feed is an honest failure; a
> stale one is not.

---

## 3. Cron chain

| Job | Schedule | What it does |
|---|---|---|
| `n2s_pull_1min` | every minute | CRM ingest → `n2s_items` |
| cron 598 | every minute | `n2s_map_events(true); n2s_pull_all_sources();` — map, then poll the newly-mapped |
| cron 602 | every minute | `n2s_cover_queue_refresh(); n2s_profitable_cover_sync();` — match, queue, publish |
| `n2s_cover_push_1min` | every minute | drains `n2s_cover_push` — **inert** unless a webhook URL secret is set |

> ⚠ **pg_cron cannot rename a job in place**, and adding a defaulted parameter alongside an
> existing signature makes a zero-argument cron call **ambiguous** (you must `DROP` first).
> Change a schedule with `cron.alter_job(jobid, schedule := …)` — `cron.job` is not directly
> writable and raises `42501`.

---

## 4. Error codes

The canonical registry lives **in the database** — `public.n2s_error_code` — so an external
consumer can read it without this repository. This section is the same content; the table is
the source of truth if they ever disagree.

Codes are stable. A code is never re-pointed at a different meaning; a superseded code is
retired and a new one issued.

| Code | Category | Meaning | What to do |
|---|---|---|---|
| `N2S-C000` | cover | Cover found. Not an error. | — |
| `N2S-C100` | cover | `no_match` — sources were polled, nothing matched section/row/qty. | Normal. The obligation stays open and re-checks every minute. |
| `N2S-C200` | cover | Cover found but **not profitable** (`cover_cost ≥ 0`). | Visible in the panel; deliberately absent from the external feed. |
| `N2S-M100` | mapping | `unmapped` — no `tevo_event_id`. | The obligation cannot be covered at all. Map the event. |
| `N2S-M101` | mapping | `event_not_catalogued` — mapped to an id absent from `public.events`. | Ingest the event. Polling it would raise `23503` and roll the mapping back. |
| `N2S-S100` | source | `awaiting_source_pull` — mapped, sources not yet polled. | Transient; clears within a tick. Persistent = the poller is stuck. |
| `N2S-S101` | source | TEvo arm skipped an uncatalogued event (`evo_skipped_unknown`). | Companion to `N2S-M101`; this is the guard working. |
| `N2S-S102` | source | TicketsData returned `403 quota_exhausted`. | Vendor quota, not our cap. Backs off automatically. |
| `N2S-S103` | source | TicketsData **fell back to the shared account** (`using_shared_account = true`). | The N2S credentials are unseeded, so this lane is drawing on quota other callers depend on. Seed the vault pair. |
| `N2S-S104` | source | Our own daily cap reached. | Lane safety, working as designed. |
| `N2S-I100` | ingest | CRM endpoint unreachable or non-200. | Check the endpoint; the order book stops advancing. |
| `N2S-I101` | ingest | CRM rejected our key. | The N2S key is invalid or rotated. |
| `N2S-I102` | ingest | Upsert batch aborted — the feed repeated a `(source, id)` pair inside one payload. | Intermittent by nature: a clean manual run proves nothing. |
| `N2S-I103` | ingest | Typed-field cast failure — the feed ships `"None"`/empty strings in date and price fields. | A bare cast aborts the whole batch; coerce first. |
| `N2S-P000` | push | Webhook delivered (2xx). | — |
| `N2S-P100` | push | No webhook URL configured — the outbox is inert. | **Current state, by design.** The Supabase feed is the delivery path. |
| `N2S-P101` | push | Receiver returned 4xx. | Receiver rejected the payload; check the token and shape. |
| `N2S-P102` | push | Receiver returned 5xx. | Receiver-side failure; retried. |
| `N2S-P103` | push | No response before timeout. | — |
| `N2S-P104` | push | **Blocked by the RULE-2 host guard.** | The configured URL points at a listing-source host. This is a hard stop, never a config nit — see §6. |
| `N2S-A100` | access | `401` — missing or invalid `apikey`. | The consumer sent no key or a wrong one. |
| `N2S-A101` | access | `permission denied` / `42501`. | Reading as `anon`. The feed grants `authenticated` only. |
| `N2S-A102` | access | `200 OK` with an **empty array**. | Not an error and not necessarily empty data — RLS filtered it. Confirm the JWT is a real signed-in user. |
| `N2S-A103` | access | Realtime subscription opens then receives nothing. | Same RLS rule applies to the socket. Also check the table is in the `supabase_realtime` publication. |
| `N2S-A104` | access | `Invalid login credentials` on an account that has **no Supabase password** — it signs in via Google/OAuth. | Retrying the password never works: an OAuth password is a different credential and GoTrue holds no hash to check. Set a real Supabase password (step 3 of `n2s_integration_doc`). A headless receiver cannot use an OAuth-only account at all. |

---

## 5. Consuming the feed (external)

Full step-by-step, versioned and queryable, is seeded into **`public.n2s_integration_doc`**
(read it in order with `select * from n2s_integration_doc order by step_no`). Short version:

1. Get the project URL and the **publishable** (anon) key. Never the `service_role` key —
   it bypasses RLS on every table in the project, so handing it to a receiver hands over the
   whole database.
2. **Make sure the account actually has a Supabase password.** ⚠ A Google/OAuth password is
   *not* one: if the user signs in through a provider, GoTrue stores no password hash and
   `signInWithPassword` returns `Invalid login credentials` however many times the correct
   Google password is typed (`N2S-A104`). Every account on this project today is
   Google-only. Set one in Authentication → Users (Email provider must be enabled), or via
   the Auth Admin API — **never** with `UPDATE auth.users … crypt(...)`, because a value
   passed through a SQL console lands in the Postgres query log.
3. Sign in as a real Supabase Auth user. The feed grants `SELECT` to `authenticated` only;
   `anon` gets nothing (`N2S-A101`).
4. Read current state: `GET /rest/v1/n2s_profitable_cover?select=*&order=profit.desc`.
5. Subscribe for changes: Realtime `postgres_changes` on `public.n2s_profitable_cover`,
   events `INSERT`/`UPDATE`/`DELETE`. RLS applies to the socket exactly as to the read.
6. Treat a `DELETE` as **"this cover is gone"** — un-flag it. `REPLICA IDENTITY FULL` means
   the event carries the full old row, so you know which order it was.

The columns a buyer needs: `order_number` (and `order_key` to find it in the CRM),
`sub_section`, `sub_row`, `sub_qty`, `buy_url`, `profit`.

---

## 6. Hard boundaries

These are not style preferences. Each has a guard behind it.

- **The pipeline never writes to a marketplace.** No order creation, no holds, no
  reprice — `RULE 2`, `CLAUDE.md`. Every `*_client.py` is GET-only by construction
  (`ALLOWED_HTTP_METHODS = frozenset({"GET"})` + `_assert_readonly_method()` that raises),
  audited by `scripts/check_readonly.py` and `tests/test_readonly_guards.py`. Weakening
  either is a **security-CRIT** change.
- **The push outbox refuses listing-source hosts at runtime** (`N2S-P104`). A webhook URL
  is operator-supplied config, so the guard is in the drain, not only in CI.
- **No secret reaches the receiver.** `get_app_secret()` enforces a `current_user` assert
  *and* a hard name whitelist raising `42501`. Extend the whitelist additively; never relax
  the assert.
- **Nothing is bought automatically.** The pipeline surfaces a link. A human clicks it.

---

## 7. Known gaps

Tracked as D7 cards in `KANBAN.md` — do not re-discover these:

- **D7-OPS-1** — `TICKETSDATA_N2S_USERNAME`/`PASSWORD` are whitelisted and coded for but
  **never seeded**, so the drain silently falls back to the exhausted shared account.
- **D7-OPS-2** — `td_budget_ok()` returns TRUE throughout that outage, which is why an
  ~18-hour gap was invisible.
- **D7-SEC-1** — the N2S key was pasted in plaintext in an earlier session and is in the
  Postgres query log. **It should be rotated.**
- **D7-PROD-2** — greedy-FIFO allocation is not globally optimal.
- **D7-OPS-3** — `get_app_secret()` is not in the `§2.6` seam map, so seam review is blind
  to security controls carried in migrations.
