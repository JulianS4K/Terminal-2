# D7 · N2S ("Need to Sub") obligation-covering pipeline

> **Doc version:** v1.45.2 (2026-11-13) — §1: N2S pulls a SeatGeek event's listings **once** (`n2s_sg_polled`, mig `20261113120000`); only the sub finder repeats it (`p_sg_repeat`). · v1.45.0 (2026-11-13) — §1 stage 5: the dry run (and so the auto-buyer) takes **Automatiq items only** (mig `20261113050000`, operator "Yes" to "limit N2S (dry run and auto-buy) to Automatiq items only"): CRM items an agent adds by hand (`item_source` `manual`) have no alert and no timer, `n2s_timer_open()` reads that as open, and they could reach the auto-buyer; they belong to the sister flow. · v1.44.0 (2026-11-13) — §0: marks the **sister flow** (sub finder API + manual sub buy: subs for orders already accepted whose tickets have a problem) as separate from N2S, and records that its covers refresh only for events N2S is working, since fleet listing polls are paused. · v1.43.0 (2026-11-12) — §2b/§6/§8: **seller notes on every suggestion** (mig `20261112030000`, operator "some suggestions prior had limited/obstructed view, add notes to output"). EVO subs had `sub_view` `unknown` and no `sub_notes`, though N2S's own EVO pull (`n2s_evo_current`) has carried `public_notes` + `view_type` since 2026-09-27; the cover queue now reads them (`n2s_evo_notes()`), the dry run stores the note it judged (`n2s_gt_order_dryrun.sub_notes`, and judges `view_type` too), the buy email and approval text show it, and the subs page shows it as text under the listing (red when obstructed) instead of only in a tooltip. `n2s_view_of()` no longer matches `limited` inside "unlimited food" or `behind` in "behind home bench". Closes D7-DATA-1 for N2S. · v1.42.0 (2026-11-12) — §1/§6: **auto-buy hardening from the EVO timing study** (mig `20261112020000`, operator "do it all"). (a) **Time for the sub's seller**: our 129 EVO purchases were accepted in a median 16 s but 1 in 10 took 8.5 min+, and nothing before a buy names the real seller (every listing shows Victory Live's office 1692); `n2s_evo_seller_window()` gives our own acceptance time at `seller_window_pct` (0.9) for listings in hand (p90 ≈ 5 min) and not (≈ 9 min). The enqueue trigger skips `not_enough_time_for_seller` when even the in-hand window does not fit, the claim (which spends the live run) hands out a buy only with that window left, and the worker re-checks with the listing's own `in_hand`. (b) **EVO tax**: cost = sub + the highest rate EVO has charged us at the venue (`n2s_evo_venue_tax_rate`, `est_tax_usd`; Camp Randall 5.5%) for every cap, approval and the profit test. (c) Time left is read from the **real clock** (a minute-tick row is inserted up to a minute after its transaction's `now()`). (d) The worker **retries a DB call once** when the connection dropped ("Server disconnected"), and `n2s_autobuy_live_record` treats a repeat of a recorded step as a no-op so a retry cannot flip `kill_switch` (an unknown outcome still flips it on every call). (e) A run the worker **stops before the buy is sent** (a guard, the fresh listing read, the seller-time check) gives the live run back; a buy EVO refused (`buy_failed`) or with an unknown outcome still counts. Not changed: the ~95 s alert-to-cover delay (CRM fetch ~43 s + the minute tick, which holds the cover lock for its ~37 s run) — a separate, measured change. · v1.41.0 (2026-11-11) — §1: **report-only subs from every TicketsData market** (mig `20261111010000`, operator "add ticket data API all secondary marketplaces", report only): cover-queue rows with `sub_source` `ticketsdata:<platform>` are now judged by `n2s_td_sub_report_capture()` under the auto-buy rules and logged to their own table `n2s_td_sub_report` (`would_buy` = buy by hand after checking the listing is still there). They never enter `n2s_gt_order_dryrun`, so nothing can enqueue a buy from them. · v1.40.0 (2026-11-11) — §1: **lead time 12 h, same-day allowed** (mig `20261111000000`, operator "12 hours before event, same day or not", for testing): `min_event_lead` 24 h → 12 h measured from the real start (`events.occurs_at_local`), new `allow_same_day` flag. · v1.39.0 (2026-11-10) — §1: **TickPick is a live sell market** (mig `20261110070000`, operator "build tickpick now"): the TickPick confirm joins `SALE_ACCEPT_WRITES`, the dry run includes TickPick sales, and a TickPick sale's allotted time is its own confirm deadline (converted to UTC by `n2s_tickpick_confirm_by`), else 540 s. · v1.38.0 (2026-11-10) — §1: **N2S × TickPick watch** (mig `20261110040000`): every minute, GET-only, `n2s_tickpick_watch_tick()` records what the vault TickPick login shows unconfirmed (`n2s_tickpick_seen`) and looks up each open N2S TickPick sale by number (`n2s_tickpick_byid_log`); `v_n2s_tickpick_watch` says per sale whether that account ever saw it — the evidence needed before TickPick auto-accept (operator 2026-11-10). · v1.37.1 (2026-11-10) — §1: TickPick token refresh live (first login 2026-11-09 22:54 UTC, token reads orders 200); tokens last 24 h, so it now refreshes inside the last 3 h (mig `20261110030000`). · v1.37.0 (2026-11-10) — §1: TickPick token auto-refresh from vault credentials (mig `20261110020000`, OAuth2 password grant to `POST /1.0/token`, hourly check); the 401s came from a token saved cut off. · v1.36.0 (2026-11-10) — §1/§6: live mode accepts the covered sale on **any market with a working token and a confirm endpoint** — EVO, GoTickets, SeatGeek, Vivid (mig `20261110010000`, `sale_accept_client.py`; operator 2026-11-10); subs are still bought on EVO only, and the worker refuses to buy when the selling market's token is missing. · v1.35.0 (2026-11-10) — §1/§6: **live executor, EVO only, one live run** (mig `20261110000000`, `core/n2s_autobuy_live.py`, `evo_buy_client.py`; operator authorization 2026-11-09): `mode` may be `live`; an EVO sub covering an EVO sale is bought from Office 3 and, once EVO accepts it, the sale is accepted as user 53658. `live_runs_allowed` = 1. Off until the web service has `N2S_AUTOBUY_LIVE=1` and the operator sets `mode = 'live'`. · v1.34.0 (2026-11-09) — §1: auto-buy executor **soft launch on EVO subs only** (mig `20261109200000`): `n2s_autobuy_config.buy_sources` (default `{tevo}`) lists the sub sources it may buy from; GoTickets subs are blocked `sub_source_disabled` until the Pro API key sees a payment method. · v1.33.0 (2026-11-09) — §1: **auto-buy executor in shadow mode** (mig `20261109030000`, `core/n2s_autobuy_exec.py`): one attempt per sale in `n2s_autobuy_exec` under `n2s_autobuy_config` limits ($250/order, $250/day, event > 24 h and not today, sub confirmed by the market's median cutoff or the sale is not accepted, no retry, approval text over $1,000, a $500 project cap that auto-stops all buying until reviewed, an email per buy with the purchase id and the sale it covers); sends nothing to any market. · v1.32.0 (2026-11-04) — §1: **order timer** (mig `20261104190000`): while an N2S order sold on EVO/GoTickets/SeatGeek/Vivid is open (alert + 20 min), `n2s_order_timer_tick()` (cron `n2s_order_timer_30s`) reads that one order's status from the market every 30 s (Vivid 60 s), GET only, and logs each state change to `n2s_order_timer_log`; `v_n2s_order_timer` gives seconds from alert / market creation to each state. · v1.31.0 (2026-11-04) — §1 stage 5: new dry-run skip `row_letter_mismatch` (mig `20261104170000`): a single-letter row against a double-letter row (H vs AA) is skipped, since AA can sit at the back or the front. · v1.30.0 (2026-10-29) — §1 stage 5: the dry run adds three skips (mig `20261029170000`): `not_enough_time` (< 6 min left on the sale timer — the seller of our buy may take minutes; our EVO purchases are accepted in seconds or auto-rejected at ~25 min), `level_mismatch` (two named levels disagree, e.g. Floor 6 vs Loge 6) and `listing_taken` (one listing covers one order); rows record `seconds_left`. Sub-listing lifetimes are tracked in `n2s_sub_listing_life` (`20261029020000`). · v1.29.0 (2026-10-28) — §1 stage 5: the auto-buy dry run now covers **EVO subs** too (`n2s_evo_order_dryrun_capture`, mig `20261028220000`; rows in the same log with `sub_source`), and only **non-PED** orders (`20261028210000`) sold on a marketplace with a **working API token** — EVO, GoTickets, SeatGeek, Vivid (`20261028213000`). · v1.28.0 (2026-10-28) — §6: **auto-cover planner (dry run only)** + `autobuy_plan` on the N2S MCP. · v1.27.0 (2026-10-28) — §6: new **N2S MCP** at `/n2s-mcp` (internal keys only): book, order, cover history, PED orders, GoTickets dry run, health, Ticketmaster primary. · v1.26.0 (2026-10-26) — §6: subs page gains a **GoTickets auto-buy dry run** panel (`/api/broker/n2s-gt-dryrun`, read-only) with a Floor/Loge level-mismatch flag. · v1.25.1 (2026-10-21) — GoTickets dry run: would_buy only on gate 1 "Index" covers (mig `20261021223000`); gates 2-6 are still logged as skips. · v1.25.0 (2026-10-21) — §1 stage 5: **GoTickets auto-buy dry run** (mig `20261021180000`): a statement trigger on `n2s_cover_queue` logs every new GoTickets cover into `n2s_gt_order_dryrun` with the order body an auto-buyer would send and its would_buy/skip decision. Nothing is sent. · v1.24.0 (2026-10-09) — §1 stage 1: **N2B (Need to Buy)** intake (mig `20261009180000`). Peddled sales whose Gmail thread carries `Need2Buy/WaitToBuy` are sent by `scripts/apps_script/n2b_sync.gs` (every 5 min, read-only on Gmail) to `n2b_ingest_from_apps_script()` and become `n2s_items` rows (`status n2b`, `item_source gmail`, `n2s_id = -order`). **No timer**: the event is re-priced every **4 hours** (`n2s_pull_all_sources`) until the label is removed (closed 30 min after leaving a full sync), the sale is cancelled, or the event is a day past. N2S rows are swept and allocated listings first (`n2s_covers`). · v1.23.0 (2026-10-06) — §1 stage 2: N2S **maps through the Automatiq hub first** (mig `20261006170040`): `n2s_hub_quick_map()` answers an order from `aq_event_map` (venue + local day + exact start minute + consistent name, unique-or-decline) the moment it lands in `n2s_crm_fetch_direct` and again at the top of each tick, firing its pulls at once; the full matcher only sees what the hub cannot answer. `n2s_aq_hub_writeback()` stores every event N2S maps that the hub lacks (`N2S-<tevo id>`), so the next order on it hits the hub. Dry run on 7 days (708 orders): 569 same, 0 different, 139 declined. · v1.22.0 (2026-09-28) — §1: SeatGeek ids now also come from **our own SeatGeek orders** (mig `20260928190000`): `sg_canonical_seed_from_orders()` runs in cron 659 (it existed but was never scheduled — 332 events were waiting), and `n2s_pull_events` resolves an SG event from `seatgeek_orders` when every order on that TEvo event agrees. Found when SeatGeek had the exact 203/D for order k9l9brp580m and we never pulled it. · v1.21.0 (2026-09-28) — §3/§6: the **panel and the external feed read different views** (mig `20260928174500`). `v_n2s_orders` (the subs panel) shows the last 24 h of non-terminal orders again, closed-window ones with `no_cover_reason = window_closed` and their most recent cover in `last_*`; `v_n2s_orders_live` (the old 10-minute-gated view, verbatim) feeds `n2s_profitable_cover_sync`, `n2s_cover_push_queue` and the book snapshot, so Albert's feed is still live-only. Found when the panel sat empty for 78 minutes between orders. · v1.20.0 (2026-09-28) — §1: SeatGeek events that SeatGeek has **expired** (400, code 421006) are recorded in `n2s_sg_expired` and never re-polled (mig `20260928153000`). Deliberately **not** a start-time cut: SeatGeek keeps selling after kickoff (60–90 events per half-hour still had listings 0–4 h after start), so expiry is taken from SeatGeek's own answer. · v1.19.0 (2026-09-27) — §1/§3/§7: **N2S polls and stores marketplace inventory on its own, apart from the terminal** (migs `20260927020000`–`20260927160500`). An order is worked for **10 minutes** after its alert (`n2s_timer_open`; the CRM gives 15, the last 5 are for accepting and buying), then it leaves polling, cover search, the panel and the feed. CRM ingest is **page 0 only**. EVO (signed direct GET), GoTickets and SeatGeek are pulled per event through N2S's own queue `n2s_mkt_pull`, as **full inventory** into `n2s_evo_current`/`n2s_gt_current`/`n2s_sg_current` with **1-hour retention**; the only thing shared with the terminal is a per-source 60 s rate timer. A 15 s `n2s_fast_land` job lands replies between ticks; CRM timeouts cut to 25 s (pg_net) / 20 s (direct, every 30 s). The terminal's own listing pollers are **paused** (event matchers kept). · v1.18.0 (2026-09-26) — §3: cron 640 runs as a single statement (mig `20260926170000`) after proving its `SET …; SELECT …` form stalled the project-wide pg_cron scheduler; direct CRM fetch to every minute and the book snapshot to :33 (`20260926144628`). · v1.17.0 (2026-09-26) — §3: `n2s_gt_map_by_name()` rewritten to an index-served time range with a `p_only_unlinked` scope (35.7 s → 1.9 s) and run in **every** cron 640 tick before the poller (mig `20260926031431`), with a 30-minute full pass as the safety net; the interim own-job variant (`20260926014415`) doubled tick length and was replaced. The N2S obligation is a 10-minute window, and a tick is one transaction every new order waits on. Function EXECUTE revoked from anon/authenticated. · v1.16.0 (2026-09-25) — §3: CRM page 0 is now fetched **both** through the tick's pg_net call and by a synchronous 20 s job (`n2s_crm_direct_20s` → `n2s_crm_fetch_direct()` via the `http` extension; migs `20260925231959` + `20260925233701`), both writing through `n2s_items_upsert()` with a newer-wins guard. Records that the ~2 min ingest lag is mostly the **CRM endpoint's own ~35–60 s response time** (not only pg_net queueing) — found when a 15 s direct timeout stalled ingest for ~16 min. Cron table corrected to the consolidated cron 640 tick. · v1.15.0 (2026-09-24) — §2: rule **3b `n2s_venue_date_time`** (mig `20260924190000`) — among same-venue, same-day, name-consistent candidates the order's local start time picks one; closes the Broadway two-shows-a-day gap (Harry Potter x3, Oh, Mary! — 4 of the 29 unmapped rows on 2026-09-24). Measured before shipping: agrees with 239 of 249 existing multi-candidate mappings; the 10 disagreements are prior mis-maps by the CRM/AQ/alias paths, left for an operator decision (fill-only). · v1.14.0 (2026-09-24) — §4/§5 + the in-DB manual (mig `20260924194804`), reviewed as the first external consumer went to connect: §5 step 2 now leads with **creating a dedicated integration user** (Add user → Create new user, Auto Confirm) instead of only adding a password to an existing Google account; §4 marks `N2S-C200` **retired** (superseded by `N2S-G200`) and adds the `G`/`V` families that the DB registry already carried; the manual's `zones` step lost a pre-`20260910620000` "gate 5/6 is NOT zone-capped" line that contradicted its own `gates` step, and `columns` now names `n2s_id`, `sub_view`, `sub_notes`. · v1.13.0 (2026-09-11) — §2/§3: **orders are now pulled BY ID the tick they arrive** (mig `20260911090000`, `n2s_order_identity_pull()` first in cron 598): an open, unmapped Vivid or GoTickets obligation whose order is not in our book gets one GET (`getOrder?orderId=`, `/rest/sales/{id}`), landed through the existing drains, and is **cross-mapped** — Vivid via `raw.productionId` = `aq_event_map.vivid_event_id` (2,533 agree / 2 disagree vs the hourly AQ-name path), GoTickets via `gotickets_event` else the hub's `gotickets_event_id`. Rules 0c/0d carry the same hub fallbacks. Records why a scheduled feed cannot do this (GoTickets drops a rejected sale from the list; Vivid's pull is status-filtered) and that every GoTickets order since the feed existed matched 7/7. · v1.12.0 (2026-09-11) — §2: the mapper now takes **identity from the marketplace books we ingest directly** (mig `20260911040000`): rule 0b EVO (`evo_orders` via the `n2s_order_key` split), 0c GoTickets (`gotickets_sales.gt_event_id` through `gotickets_event`), 0d Vivid (`vivid_orders`), 0e SeatGeek (`seatgeek_orders` → row / xref / hub), all ahead of every name/date/venue inference. Records the measurement (EVO 22/22 found, 0 disagreements; GoTickets 6/49) and **why 0d/0e map nothing yet**: the Vivid pull is `PENDING_SHIPMENT`-only and the SeatGeek pull only ever fetched page 1 ascending (2019 orders) — the latter fixed by `20260911080000`. · v1.11.0 (2026-09-11) — §3: SeatGeek snapshots are retained **indefinitely** on operator direction (mig `20260911030000`; rule + guard in `RESOURCES_BIBLE §2.14`), unlike the 15-day TEvo and GoTickets windows; records why the old "flip on resume" note was a trap and that change-only persistence (a re-pull of an unmoved listing writes no row) is a separate, unchanged decision. · v1.10.0 (2026-09-11) — §3: two poller/mapper gaps found by investigating why SeatGeek and GoTickets covered fewer open events than TEvo. (a) `sg_listings_pull_on_demand` could resolve an SG id from the hub but never fire it (the snapshot FK needs a canonical row, the drain needs an xref row) — it now **registers** hub-resolved events first (20260911010000). (b) `gt_map_events` matches on performer only and the TEvo catalogue can list a support act as primary performer — new **`n2s_gt_map_by_name()`** second pass scoped to the open N2S book, in cron 598 (20260911020000): classifies each TEvo time as offset / naive / tbd and applies a rule per shape (same-minute name+venue ≥ 0.6; same-minute venue ≥ 0.8 + performer agreement; no usable instant → date ±1 + name/venue ≥ 0.8), excludes parking/cancelled/season-ticket rows, refuses ties. 5 of 61 open events had no usable instant, which A1's exact-minute mapper can never match. Both are operator-directed cross-lane writes into A1's SG/GT tables, never overwriting an existing mapping. · v1.9.0 (2026-09-10) — §2b: new ` single ticket` suffix (`N2S-G1100`) on `cover_label` when the **sold** quantity is 1, so a label-only consumer knows the obligation is a single seat; distinct from ` repost single` (the buy is one over) and the two can co-occur; panel renders it as its own chip. · v1.8.0 (2026-09-10) — §2b/§4a: view quality is now a **suffix as well as a column** — `cover_label` gains ` obstructed view`, so a label-only consumer still sees the defect; records why `unknown` is deliberately NOT suffixed (it is the majority state, and a suffix on the majority stops carrying information). Panel strips the suffix from the gate name so the chip does not duplicate it. · v1.7.0 (2026-09-10) — new **§2b**: listing **view quality** surfaced end to end (`sub_view`/`sub_notes` on the queue, `v_n2s_orders`, the external feed and the panel), after finding that an obstructed substitute classifies as gate 1 "actionable directly". Records the three-state rule (`unknown` is not `clear`), the new `N2S-V100`/`V200` codes, and the **TEvo blind spot** — `public_notes` is read by the client but never mirrored into `listings_snapshots`, so most rows read `unknown`; closing it is an A1 change. · v1.6.0 (2026-09-10) — §4a: **the gate-5/6 row downgrade is now zone-capped** (operator reversal of "downgrade is not zone based for now"), closing the row-bound-price-tier hole the original cascade documented as accepted. Adds the `zone_ok` truth table, the new ` zone unverified` suffix (`N2S-G1000`) for venues with no curated zones, and why the unverifiable case is a suffix rather than a seventh gate. Profit/cap split is unchanged. · v1.5.0 (2026-09-10) — §2a: recorded that the **section-change guarantee is structural** (only `match_zone` can move a section, and it requires a non-null `order_zone` equal to `sub_zone`), that gate 5 inherits it, and that the one carve-out is a row downgrade inside the sold section — now stated in the integration manual rather than left implied. · v1.4.0 (2026-09-10) — new **§2a**: the gate label now crosses to the external feed (`cover_gate`/`cover_label`/`order_zone`/`sub_zone` on `n2s_profitable_cover`), after finding the manual documented a field the feed never sent while 7 of 11 live rows were consent-required gates; records the change-detection-tuple trap, the odd-gates-only rule and the fail-closed NULL. §2 rewritten: the **6-hour age-out is OFF** on operator direction (history is being retained for P&L), which cost the deadman — the reasoning is kept so it is not naively re-added. · v1.3.0 (2026-09-10) — §1: added **tier 3** (one seat over from a larger lot whose splits permit it), its two load-bearing caps and the measurement that rejected the unbounded version, plus the **global 200% cost ceiling** and its `sold_ea ≤ 0` carve-out. · v1.2.0 (2026-09-10) — §2: documented the **6-hour age-out**, done at the source inside the sync rather than as a DELETE job, with the flap trap that makes the obvious implementation self-defeating. · v1.1.0 (2026-09-10) — §4/§5: added **`N2S-A104`** (sign-in refused on an OAuth-only account) and the password-setup step, after finding every auth user on this project is Google-only with **no** Supabase password — so the documented `signInWithPassword` flow could not have worked for any existing account. · v1.0.0 (2026-09-10) — first cut. The D7 lane manual: what the pipeline
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

> **Sister flow, not N2S: subs for orders already accepted whose tickets have a problem.**
> The sub finder API (`/api/v1/subs`, `routers/subs_api.py`, D0; onboarding in
> `docs/sub_finder_api_onboarding.md`) and the manual sub buy (`core/manual_sub_buy.py`) serve
> that case. None of this document's rules apply to it: no gates, no N2S caps or live-run
> budget, no sale accept, and the N2S queue, dry run and auto-buyer never see its orders. It
> has its own switches and spend ceilings (`sub_finder_config`, `manual_sub_buy_config`).
> It shares two things with N2S: the on-demand listing pull (`n2s_pull_events`) and the
> `n2s_*_current` lists it matches against. ⚠ Those lists stay fresh (about every 3 min) only
> for events N2S itself is working. Fleet listing polls of all events have been paused since
> 2026-09-27 (`20260927043400`); since `20261023051000` only pinned performers are polled, into
> the terminal tables, which the sub finder does not read. With `sub_finder_config.refresh_pull`
> off, an accepted order whose event N2S is not working keeps the covers from its first lookup.

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

**N2B (Need to Buy) rows ride the same table** (mig `20261009180000`). A peddled sale we
still have to buy arrives as a "PEDDLING SALE RECEIVED" email; while its Gmail thread
carries `Need2Buy/WaitToBuy`, `scripts/apps_script/n2b_sync.gs` (installed in that
mailbox, every 5 min, never changes a label) sends the whole labelled set to
`n2b_ingest_from_apps_script()` (anon key + `APPSCRIPT_INGEST_SECRET`). Rows are
`status = 'n2b'`, `item_source = 'gmail'`, `n2s_id = -(our order #)` (CRM ids are
positive, so they never collide), `order_number` = the marketplace's site order.
Differences from N2S:
- **no timer** — `alert_at`/`timer_expires_at` stay NULL, which `n2s_timer_open()` reads
  as open, so the row is mapped, priced and shown until it is closed;
- **re-priced every 4 hours**, not every 2 minutes (`n2s_pull_all_sources` sweep), and
  swept after N2S rows; an event an N2S order is also on is refreshed by that order;
- **N2S claims listings first** in `n2s_covers` (an N2S buyer is on a clock);
- **lifecycle**: label still on → open (reopened if it had been closed); thread has a
  cancel label (`Need2Buy/Cancelled`, `ISSUE/Cancelled`) or a "CANCEL" subject →
  `n2b_cancelled` (sticky); absent from a full sync and unseen 30 min → `n2b_closed`
  (`label removed`); event a day past → `n2b_closed` (`event passed`).

### 2. Map — obligation to a TEvo event
`n2s_map_events()` resolves each item to a `tevo_event_id`. Until this lands the obligation
is invisible to every downstream stage: **an unmapped row can never get a cover**, because
there is no event to poll listings for.

**Identity first, inference second.** The rules run in a fixed order and every rule is
fill-only and unique-or-decline:

| Rule | `mapped_via` | Source of truth | Why it is where it is |
|---|---|---|---|
| 0 | `n2s_crm_order_identity` | `s4kcs_orders` (the CRM marketplace book) on the order key | The same order, already mapped — identity, no name compared |
| 0b | `n2s_evo_order_identity` | `evo_orders.tevo_event_id` on `n2s_order_key` (the EVO split) | EVO orders are in **no** CRM feed, but they are in our own seller book (mig `20260911040000`) |
| 0c | `n2s_gt_order_identity` | `gotickets_sales.gt_event_id` → `gotickets_event.tevo_event_id`, else the hub (`aq_event_map.gotickets_event_id`) on the sale id | GT's **own** event id, resolved by the GT mappers or the hub; unique-or-decline across both (mig `20260911040000`) |
| 0d | `n2s_vivid_order_identity` | `vivid_orders.tevo_event_id` on the Vivid order id, else the hub on `raw.productionId` (= `aq_event_map.vivid_event_id`) | Our own Vivid broker-order pull, filled by id on demand (§3 probe, mig `20260911090000`) |
| 0e | `n2s_sg_order_identity` | `seatgeek_orders` on the SG order id → tevo id from the row, else `sg_event_id` via xref, else the hub | Our SellerDirect order pull; **dormant until the pull reaches current pages** (mig `20260911080000`) |
| 1–4 | `n2s_name_date_venue`, `n2s_venue_date_*` | `events` on name + local date (+ venue guard) | Inference; only reached when no book holds the order |
| 3b | `n2s_venue_date_time` | `events` on venue + local date, the order's local **start time** picks one of several name-consistent candidates | A matinee and an evening show of the same title are two events; rules 1–4 decline both, the time separates them (mig `20260924190000`). Tiebreak only — no time match, rule 4 runs as before |
| 5 | `n2s_gt_name_alias` | `gotickets_event` as a name alias | Trusts a third party's mapping, so it runs last |
| — | `n2s_<rule>` (second pass) | `n2s_gt_map_by_name()` | Maps GT's catalogue to TEvo for the open book; see §3 |

**The Automatiq hub answers first (mig `20261006170040`).** Before any rule above,
`n2s_hub_quick_map()` looks the order up in `aq_event_map`: same venue (`tevo_venue_id` =
`cross_source_venue_resolve(venue)`), same local day, the TEvo catalogue's start **minute** equal
to the order's, names consistent (`aq_name_consistent`) — unique-or-decline, and it also declines
when the catalogue holds another name-consistent event at that venue and minute (duplicate
listings of one game). A hit is stamped `mapped_via = n2s_aq_hub` and its market pulls fire
immediately. It runs inside `n2s_crm_fetch_direct` the moment new orders land (every 30 s) and
again at the top of each tick, so `event_mapper_run` / the rules above only see orders the hub
could not answer. `n2s_aq_hub_writeback()` (each tick, after the matcher) inserts any event an N2S
order mapped to that the hub lacks (`aq_short_event_id = N2S-<tevo id>`, `aq_source = n2s`;
insert-only), so the next order for that event is answered by the hub.
Why: over 7 days 58% of orders were repeat orders for an already-mapped event, yet reached a first
cover only ~20 s sooner (65 s vs 87 s median) because the earlier mapping was never reused.
Dry run on those 708 orders: 569 same event as the matcher, **0 different**, 139 declined.

Measured 2026-09-11 before rules 0b/0c shipped: every one of the 22 EVO obligations was in
`evo_orders` (20 with a tevo id, 0 disagreements against the inference rules) yet 6 had never
mapped and the rest had waited on a name match. GoTickets: 6 of 49 in `gotickets_sales`, 0
disagreements.

**Why a scheduled feed was never going to hold these orders — and what does.** Rules 0c/0d/0e
mapped 6 of 49 / 0 of 117 / 0 of 16 when they shipped. The keys were right; the books were not
reaching the orders:
- **GoTickets** — the list feed (`/rest/sales`) returns a sale only while it is live. Every N2S
  GoTickets order that arrived after the feed existed (20:36 UTC on 2026-09-09) matched 7/7 on
  `gt_sale_id`; the 43 before it were never seen, and a sale we fail to confirm is cancelled at
  GT and drops out of the list, so catching it in a 15-minute sync is luck. The per-sale
  endpoint (`/rest/sales/{id}`) returns it regardless, cancelled or not.
- **Vivid** — cron 207 pulls `getOrders?status=PENDING_SHIPMENT` only; the N2S-failed orders
  carry another status (867 of our rows inside the N2S id range, the N2S ids' neighbours
  present, the ids themselves absent even from raw). `getOrder?orderId=` needs no status.
- **SeatGeek** — the SellerDirect pull fetched page 1 of each status, ascending by creation,
  so the 400 rows we held were 2019–2025 orders re-upserted every 30 minutes (upstream:
  `confirmed` 6,633, `fulfilled` 582,238). Mig `20260911080000` adds the last two pages per
  status; its first cycle proves whether offset paging still works on `/orders`. There is no
  per-order endpoint, so this is the SeatGeek road.
- **TickPick** — that ingest has been off since 2026-05-31; no rule until it runs again.

So the mapper pulls the order **by id, the tick the obligation arrives** (§3,
`n2s_order_identity_pull()`, mig `20260911090000`): one GET per open unmapped Vivid/GoTickets
obligation whose order we do not hold, landed through the existing drains
(`vivid_orders_process()`, `gt_sales_drain()` — the latter now accepts the single-object
shape), then **cross-mapped** to a TEvo event: Vivid through `raw.productionId` =
`aq_event_map.vivid_event_id` (measured 2,820 hub hits on 3,935 recent orders, 2,533 agree /
2 disagree with the hourly AQ-name backfill; `raw.eventId` hits nothing), GoTickets through
`gotickets_event` else the hub's `gotickets_event_id` (765 of 1,032 recent sale events carry a
tevo id there). Ledger `n2s_order_probe`: one probe per obligation per 6 h, three attempts,
numeric order numbers only. GET-only on both hosts — RULE 2 holds.

> ⚠ **The FK landmine.** `evo_listings_poll_state.event_id` has a foreign key to
> `events.id`. Polling an event that is mapped but **not catalogued** raises `23503`, and
> because the cron runs `map(); pull();` in one transaction, the mapping rolls back with
> it. Guarded since migration `20260910330000` (the TEvo arm skips uncatalogued events and
> reports `evo_skipped_unknown`), and surfaced as `event_not_catalogued`. Do not remove
> that guard to "simplify" the poller.

### 3. Poll — four marketplaces, on demand

> **Current path (2026-09-27, mig `20260927041700`).** Everything below the box describes the
> pre-2026-09-27 poller, which read the **terminal's** change-only snapshot stores. Those stores
> keep only listings whose price or quantity moved, so "the latest capture" was never the whole
> event, and a cover search on it missed inventory. N2S now owns its polling and storage:
>
> - **Queue:** `n2s_mkt_pull` holds one row per (event, source), for EVO, GoTickets and SeatGeek.
>   `n2s_pull_events()` fires each one: EVO is a signed direct `GET /v9/ticket_groups?event_id=`
>   (HMAC in the DB, no edge function), and GoTickets and SeatGeek go out via pg_net. `n2s_mkt_drain()`
>   lands each reply as the **full current inventory** in `n2s_evo_current`, `n2s_gt_current` or `n2s_sg_current`.
> - **Only the rate timer is shared with the terminal.** When N2S pulls an event from a source, it
>   resets the terminal's timer for that event and source, and it skips any event that source pulled
>   in the last 60 s. The two pipelines never read each other's rows.
> - **Retention is 1 hour** (`20260927042100`), cleaned up by the drain. Nothing downstream needs older rows.
> - `n2s_cover_candidates()` reads **only** these three tables (plus TicketsData, unchanged).
> - **Gate:** an order is polled only while `n2s_timer_open()` is true (see §3 Cron chain).
> - `n2s_pull_events` / `n2s_pull_all_sources` are not executable by PUBLIC, anon or authenticated.
> - **SeatGeek event id resolution order (`20260928190000`):** `sg_events_canonical.tevo_event_id`, then
>   `aq_event_map`, then `seatgeek_orders` — the last only when **all** our SeatGeek orders on that TEvo
>   event name one SeatGeek event (24 events disagree: parking, playoff rounds, mis-maps). An event with
>   none of the three is never pulled from SeatGeek (~4% of mapped N2S orders over 7 days).
> - **Expired SeatGeek events are skipped (`20260928153000`).** When SeatGeek answers 400 code 421006
>   ("event has expired"), the drain records the event in `n2s_sg_expired` (7-day purge) and
>   `n2s_pull_events` never fires it again. It is not cut at start time on purpose: SeatGeek keeps
>   selling in-game, and expiry came 1 h 40 m – 4 h after start on 2026-09-27.
> - **N2S pulls a SeatGeek event once (`20261113120000`, operator 2026-11-13).** Every SeatGeek
>   pull is recorded in `n2s_sg_polled`; `n2s_pull_events` skips an event already there, whoever
>   pulled it first. EVO and GoTickets are pulled as before. Only the sub finder passes
>   `p_sg_repeat = true` and keeps pulling SeatGeek for its watched orders. `n2s_sg_current`
>   keeps an hour, so N2S sees SeatGeek listings for the hour after that one pull.
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

**Retention differs by source, and SeatGeek is the odd one out.** TEvo and GoTickets raw
listings are swept at 15 days (`retention_policy`); every SeatGeek snapshot — listings and
sales — is kept **indefinitely** (operator directive 2026-09-11, mig `20260911030000`). The
rule lives in `retention_policy` itself (`meta.never_purge`, refused-on-enable trigger) so
it cannot drift from the engine; details in `RESOURCES_BIBLE §2.14`. The trap it closes:
the SeatGeek rows were seeded disabled with a note to "flip enabled=true with the SG-listings
resume", and the on-demand puller (§3, `20260910140000`) *is* that resume — following the
note would have cut four months of history to 30 days. Unchanged and separate: the drain's
change-only insert (a re-pull of a listing whose price and quantity did not move writes no
new row), which is persistence policy, not retention.

### 4. Match — two tiers, then six gates

Matching happens in two independent dimensions, and it is easy to confuse them:

- **tiers** answer *how many do we buy* (quantity/splits) — below;
- **gates** answer *what are we allowed to do with it* (section/row/cost) — §4a.


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

### 4a. Gates — the label cascade

Every surviving candidate is classified into exactly one of six gates, checked in
order, first match wins. The label is a **workflow instruction**, not a quality score.

| Gate | Label | Section | Row | Cost |
|---|---|---|---|---|
| 1 | `Index` | exact | same or better | profitable |
| 2 | `S4KTrading` | exact | same or better | ≤200% of sale |
| 3 | `Index offer subs` | same curated zone | same or better | profitable |
| 4 | `offer subs s4ktrading` | same curated zone | same or better | ≤200% |
| 5 | `Index Down offer subs` | exact or zone | **up to 5 rows back, same zone** | profitable |
| 6 | `Down offer subs S4KTrading` | exact or zone | **up to 5 rows back, same zone** | ≤200% |

Four suffixes can be appended, in this order:

| Suffix | When | Code |
|---|---|---|
| ` zone unverified` | gate 5/6 where **neither** seat resolves to a zone — the venue has none curated, so the same-zone rule could not be checked | `N2S-G1000` |
| ` obstructed view` | `sub_view = 'obstructed'` — the source discloses a limited/obstructed view. Independent of the gate; a gate 1 row can carry it | `N2S-V100` |
| ` single ticket` | `quantity = 1` — the **sale** is for exactly one seat, the hardest quantity to source. Any gate can carry it. A different fact from ` repost single` (the **buy** is one over); a one-seat sale covered from a pair carries both | `N2S-G1100` |
| ` repost single` | `sub_qty > quantity` — the lot could not be split, so we buy one spare and repost it | `N2S-G700` |

A label can carry more than one, so consumers matching on a suffix must use a suffix test
(`LIKE '% zone unverified'`), never equality on the whole label.

**No gate = not sent.** The 200% ceiling is expressed *only* through the gates; there
is no separate filter. Nothing above it ships on any gate.

> ⚠ **"offer subs" is a hard instruction, not a hint.** Gates 1–2 keep the buyer in the
> section they purchased and are directly actionable. Gates 3–6 **move** them, so the
> buyer must accept before we purchase. `cover_gate` is a stable integer — filter on it,
> not on the label text.

**Zones are section *and* row scoped.** Many are price tiers stacked inside one section
(sections 121-124 at one venue: `Metro Gold/Plat` rows 1-6, `Metro Silver` 7-12,
`Metro Bronze` 13-22, `Metro Box` 23-35). Resolving on section alone would let a Gold
seat match a Silver seat, so `n2s_zone_of()` takes the row and **refuses ambiguity**
(returns NULL) rather than breaking a tie by `display_order` the way
`match_performer_zone()` does. Ambiguous lookups fall through to gates 5/6 — a wrong
zone label is worse than none. FIFA overlay zones and `system_placeholder` zones are
excluded.

**The gate-5/6 downgrade is zone-capped** as of `20260910620000`, reversing the
original "downgrade is not zone based for now". `zone_ok := sub_zone IS NOT DISTINCT
FROM order_zone`, which reads as three cases because the NULLs carry meaning:

| `order_zone` | `sub_zone` | Outcome |
|---|---|---|
| named | same | verified in-zone → ships, plain label |
| NULL | NULL | venue has no curated zones, nothing to cross → ships, ` zone unverified` |
| named | different | tier crossed → **no gate, not sent** |
| named | NULL | sub's row is outside every curated range for that section → **no gate, not sent** |

> ⚠ **Only `match_exact` was ever unsafe.** `match_zone` joins on `lz.zone =
> oz.order_zone`, and because `n2s_zone_of()` is scoped on section *and* row, a
> zone-branch downgrade that crossed a tier already resolved to a different zone name
> and fell out on its own. The hole was entirely in the same-section branch, which
> compared no zones at all — which is why the fix is one predicate, not a redesign.

> ⚠ **The unverifiable case is a suffix, not a seventh gate.** "No zones at this venue"
> is not a *worse* cover, it is an unchecked claim. A gate 7 would sort it below a real
> gate 6 in every consumer that orders by `cover_gate` — but a same-section two-row drop
> at an unzoned venue is not worse than a tier-verified five-row drop. The suffix leaves
> the ordering alone and still stops the label claiming a guarantee we did not make.

> ⚠ **Gates 5/6 narrowed; they were not re-pointed.** `N2S-G500`/`G600` keep their
> numbers and labels — the set they admit is now a strict subset of what it was, which
> is a narrowing, not a new meaning. Their `meaning` text is corrected in place.
> Candidates that no longer qualify get no gate and fall under `N2S-G800`.

> ⚠ **`AS MATERIALIZED` on `zrule`/`lcoord0`/`lcoord`/`evz` is load-bearing.** Postgres
> inlines a CTE referenced once, which pushes the section normalisers back into the join
> predicate and evaluates them per *comparison* — ~24M calls, a hard 60s timeout. It
> fails as a timeout rather than a wrong answer, so it looks like infrastructure. Do not
> remove it. For the same reason the exact-section and zone matches are two UNION'd
> branches, never one `OR` across relations.

### 5. Queue — one cover per obligation
`n2s_cover_queue_refresh()` writes the winning cover per obligation into
**`n2s_cover_queue`**, with `cover_cost = (sub_price_each × buy_qty) − (sold_price_each × qty)`.
**Negative `cover_cost` means we make money.** Allocation is greedy-FIFO: the oldest
obligation takes its best cover first. That is not globally optimal — see the drift note in
`KANBAN.md` (D7-PROD-2).

**GoTickets auto-buy dry run** (mig `20261021180000`): every queue rebuild fires
`n2s_gt_order_dryrun_capture()` through a statement trigger, which logs each GoTickets cover
it has not seen (one row per order + listing + quoted price) into **`n2s_gt_order_dryrun`**:
the `POST /orders` body and `decision` = `would_buy` or `skip` with `skip_reasons`. Rules and
caps are in the migration header; the trigger downgrades its own errors to a WARNING so it
cannot break the refresh. **Nothing is sent** — see `docs/buy_side_evo_gotickets.md` §5.
Since 2026-10-28 the same trigger also runs **`n2s_evo_order_dryrun_capture()`** for EVO (TEvo)
subs (live re-check against `n2s_evo_current`; our own listing → `our_own_listing`), writing to
the same table with `sub_source = 'tevo'` and the TEvo `POST /v9/orders` body. Both captures take
only non-PED orders sold on EVO, GoTickets, SeatGeek or Vivid (the markets whose tokens work;
TickPick 401 — its vault token had been saved cut off at the first `.`; since mig `20261110020000`
`tickpick_token_refresh()` (cron `tickpick_token_refresh_hourly`, :17) logs in with the vault's
`TICKPICK_USERNAME`/`TICKPICK_PASSWORD` (OAuth2 password grant, `POST /1.0/token`, the one
sanctioned plpgsql write URL) and keeps `TICKPICK_API_TOKEN` fresh, state in `tickpick_token_state`
— whether that login's account is the one N2S TickPick sales are sold from is being measured by
`v_n2s_tickpick_watch` (mig `20261110040000`): an unconfirmed TickPick order that lapses disappears,
so only a lookup while the sale is open counts — StubHub invalid credentials, no token for
Gametime/Viagogo/Ticketmaster), and
share one daily cap. Since 2026-10-29 (`20261029170000`) both also skip a cover when fewer
than **6 minutes** remain on the sale timer (`not_enough_time`), when the sold and sub sections
name **different levels** (`level_mismatch`, via `n2s_section_level`), or when another order
already has a would_buy on the **same listing** (`listing_taken`).
Since 2026-11-04 (`20261104170000`) they also skip a **single-letter vs double-letter row** pair
(`row_letter_mismatch`, e.g. sold AA, sub H).
Since 2026-11-13 (`20261113050000`, operator "Yes" to limiting N2S to Automatiq items) both take
only **Automatiq** items (`n2s_items.item_source = 'automatiq'`): the failed-order alerts with an
alert time and the 10-minute timer. The CRM intake also brings in items agents add by hand
(`manual`, no alert, no timer), and `n2s_timer_open()` reads a missing timer as open, so before
this a manual item could reach the dry run and, through it, the auto-buyer. Those are the sister
flow's (§0). The cover queue, the subs page and the feed still show every item.

### 6. Surface — panel and feed
- **`v_n2s_orders`** joins items + queue and computes `has_cover` / `no_cover_reason`;
  `/api/broker/n2s-covers` serves it to `static/terminal/subs.html`.
- **`n2s_gt_order_dryrun`** (stage 5) is served by `/api/broker/n2s-gt-dryrun` to the
  subs page's *GoTickets auto-buy — dry run* panel: latest rows, a would-buy/skip filter,
  today's ET tally and would-spend, and a ⚠ on gate-1 rows whose named level differs
  (sold *Floor 6* vs listing *Loge 6*). Read server-side because the table has no grant
  for browser roles. Read-only — there is no buy route.
- **N2S MCP** (`/n2s-mcp`, server `s4k-n2s`, `routers/n2s_mcp.py`): the desk as MCP tools, a
  separate server from the market-data `/mcp` and **internal keys only** (external → 403).
  `n2s_health` (CRM ingest, newest order, queue refresh, newest dry-run row), `n2s_book`
  (`v_n2s_orders`), `n2s_order` (book row + cover history + dry-run rows for one order),
  `n2s_cover_history`, `ped_orders` (`inbox_n2b`), `gt_dryrun` / `gt_dryrun_summary` (rows with
  `profit`, `ped`, `level_mismatch`, `would_send`; totals, per-gate profit left on the table,
  listings offered to several orders) and `tm_primary` (Ticketmaster box-office seats per section
  via TicketsData, **1 credit per call**) and `autobuy_plan`. Read-only.
- **Auto-cover planner — DRY RUN ONLY** (`core/n2s_autobuy.py`, operator 2026-10-28: "build but
  dont run, dry runs only … NO PUSHING OUT"). Per open order it builds the six-step plan — sale
  still active (`in_window` / `event_live`; `event_live` means *still sellable*, not *started*) →
  1-1 Index sub (gate 1, profitable, full quantity, not obstructed, named levels agree) → sub is
  not ours (`n2s_evo_current.is_owned`, `n2s_sg_current.is_broker_owned`; GoTickets: Seller
  Central `GET /rest/listings/{id}` empty 200 / 404 = not ours, made live) → BUY request → purchase-confirmed
  read → ACCEPT request on the selling market — with every write `sent: False`. The module
  imports no HTTP library; RULE 2 and `check_readonly.py` are unchanged. Endpoints checked
  2026-10-28: buy on GoTickets Pro `POST /orders`, TEvo v9 `POST /orders`, TickPick
  `POST /pro/orders` (SeatGeek has none — manual); accept on GoTickets
  `POST /rest/sales/{id}/confirm`, TEvo `POST /v9/orders/{id}/accept`, TickPick
  `POST /orders/{n}/confirmation`, SeatGeek SellerDirect `PATCH /order`. **Not yet read** (accept
  blocked in the plan): Vivid, StubHub, Gametime, Viagogo, Ticketmaster. Measured 2026-10-28:
  the cover search has no own-inventory filter, though no live cover was on our listings.
- **Auto-buy executor — SHADOW MODE** (mig `20261109030000`, `core/n2s_autobuy_exec.py`, operator
  2026-11-09). Every dry-run `would_buy` gets **one** row in `n2s_autobuy_exec` (`UNIQUE n2s_id`: a
  sale is attempted once, never retried) with state `shadow_buy` / `awaiting_approval` / `blocked` /
  `off` and the `reasons[]`. Limits live in the one-row `n2s_autobuy_config`: **$250 per order and
  $250 per day** to start, 3 buys/day, one buy per event per day, a listing used once, circuit
  breaker after 2 failures/day, event start **> `min_event_lead`** away (24 h; **12 h since `20261111000000`**, measured
  from the real start: `events.occurs_at_local`, else venue-local read as UTC) and **not today** (America/New_York;
  skipped while `allow_same_day`, true since `20261111000000`; reason `event_within_24h` = within `min_event_lead`),
  profit > 0 (**no minimum margin**), live price not above the quote, live read ≤ 120 s old.
  **Allotted time** per selling market = the median alert-to-auto-reject from the order timer
  (`v_n2s_market_cutoff`, ≥ 3 samples, rejects under 5 min excluded — measured 2026-11-09: EVO
  746 s from 15, SeatGeek 1,160 s from 3), else the CRM's 900 s; the sub must be **confirmed by
  cutoff − 60 s** (`sub_confirm_by`) or the sale is **not accepted**. Subs over **$1,000** wait for
  approval: `n2s_autobuy_notify_tick()` (cron `n2s_autobuy_notify_1min`) texts the operator through
  Twilio (SMS or WhatsApp, `notify_channel`) once `notify_to` / `notify_from` are set; the answer is
  `n2s_autobuy_approve(n2s_id, true|false)`; an unanswered request lapses at `sub_confirm_by`.
  **Project cap** (operator 2026-11-09: "for now 500 cap on entire project"): every buy ever
  committed in the current mode, on any market, counts against `project_cap_usd` (**$500**); a buy
  that would otherwise go through but would cross it is blocked and **all buying auto-stops**
  (`project_stopped`, with `project_stopped_reason`), as does reaching the cap exactly; while
  stopped every buy is blocked `stopped_pending_review` until the operator runs
  `n2s_autobuy_resume([new_cap])`. Shadow and a future live mode count separately. EVO buys come
  from Office 3 (`evo_buyer_office_id` 42029) and EVO accepts carry `reviewer_id` 53658.
  **Buy email** (operator 2026-11-09): the same tick emails `email_to` (default the operator)
  through Resend for every buy with a `buy_order_id` — the purchase id on EVO / GoTickets and the
  sale order it covers — and for shadow buys too when `email_shadow` is on; it emails once when
  the project cap auto-stops buying. Enqueues lock the config row (`FOR UPDATE`) so concurrent would_buys
  cannot both pass a cap.
  **Soft launch: EVO subs only** (operator 2026-11-09, mig `20261109200000`): `buy_sources`
  (default `{tevo}`) — GoTickets subs are blocked `sub_source_disabled` because the Pro API key sees
  no payment method (`GET /rest/pro/api/payment-methods` → `[]`); re-enable with
  `UPDATE n2s_autobuy_config SET buy_sources = '{tevo,gotickets}'`.
  **Live mode — EVO only, one live run** (operator authorization 2026-11-09: "I authorize EVO only,
  build the live executor, limit to only 1 live run for testing"; mig `20261110000000`). In
  `mode = 'live'` the trigger also blocks a sale not sold on EVO (`sell_market_not_live`, from
  `live_sell_markets` = `{evo}`), a non-EVO sub (`sub_source_not_live`) and anything once the live
  runs are used up (`live_runs_used_up`); a row that passes gets state `live_buy`. The web worker
  (`server.py` → `core/n2s_autobuy_live.py`, every 15 s, only with env `N2S_AUTOBUY_LIVE=1`) takes
  one row at a time from `n2s_autobuy_live_claim()` (config row lock + `FOR UPDATE SKIP LOCKED` +
  a 180 s lease with its own `lease_token`; a new buy uses up a live run **before** anything is
  sent) and records each step with `n2s_autobuy_live_record()`, which only writes under that
  unexpired lease — the worker re-checks it right before each market write, and a row left in
  `buying` past its lease becomes `buy_unknown` and sets `kill_switch`. Steps land in `phase`: `buying` → `buy_sent` → `sub_accepted` → `accepted`, or
  `stopped` / `buy_unknown` / `accept_failed` / `accept_unknown`. The buy step re-checks the
  guards, reads the ticket group fresh (not ours — brokerage 1768 / `owned`; enough tickets; a split
  that fits; wholesale × qty not above our quote; event further out than `min_event_lead` by EVO's
  `event.occurs_at_local` — its `occurs_at` is local time with a misleading Z — and the row's stored
  `event_start_utc`) and
  sends **one** `POST /v9/orders` (seller = the ticket group's office, buyer Office 3, `evopay`,
  shipment type from the ticket-group format to Office 3's delivery email `evo_email_address_id`).
  The poll step reads our purchase: accepted → reads the sale and, only while it is still
  `pending`, `POST /v9/orders/{id}/accept` with `reviewer_id` 53658; rejected → stop; not accepted
  by `sub_confirm_by` → stop, sale **not** accepted. Nothing is retried and no sale is ever
  rejected. A write whose outcome is unknown (timeout / 5xx) stops the row **and sets
  `kill_switch`**. `n2s_autobuy_outcome_tick()` (cron `n2s_autobuy_outcome_1min`) emails the
  outcome of each live row once it ends. Live spend counts apart from shadow spend.
  **Any selling market with a token and a confirm endpoint** (operator 2026-11-10, mig
  `20261110010000`): `live_sell_markets` = `{evo,gotickets,seatgeek,vivid}` (+ `tickpick`, `20261110070000`). A non-EVO sale is
  accepted through `sale_accept_client.py` — GoTickets `POST /rest/sales/{id}/confirm`, SeatGeek
  SellerDirect `PATCH /order` (`status=confirmed`), Vivid `POST /webservices/v1/confirmOrder`
  (`apiToken`, `orderId`, `shipNow=false`; a `<success>false</success>` body counts as rejected) —
  each pinned to its (method, host, path) by `SALE_ACCEPT_WRITES`. "Still waiting for us" is
  GoTickets `sellerStatus` UNCONFIRMED, SeatGeek `status` submitted/pending/open, Vivid `<status>`
  UNCONFIRMED (the same reads as the order timer).
  **TickPick** (operator 2026-11-10, mig `20261110070000`, after the watch showed 3 of 3 N2S TickPick
  sales visible to our seller login while open): `POST /1.0/orders/{n}/confirmation` (empty
  `ConfirmOrderRequest`), pending = `seller_status` Unconfirmed, Canceled / Rejected / Busted after
  an accept = `sale_rejected_after_accept`. The token is read from the Vault on every use (it is
  replaced about daily). Before buying, the worker re-reads the TickPick sale and stops
  (`sale_not_pending` / `sale_read_failed`) unless our login shows it Unconfirmed — an unconfirmed
  TickPick sale lapses and vanishes (404). TickPick states each sale's own deadline (10 min for a
  same-day event, 60 min later out, 2026-11-09 samples) in the venue's local time;
  `n2s_tickpick_watch_tick` stores it in UTC as `n2s_tickpick_seen.confirm_by` and the enqueue
  trigger uses it as the cutoff, else 540 s until the watch has seen the sale. The worker reads the tokens through
  `get_app_secret` (GoTickets added to its whitelist) and refuses to buy (`no_sale_accept_token`)
  when the selling market's token is missing. The GoTickets and Vivid confirm request formats were
  never exercised by the dry run (their specs could not be fetched), so the first live accept on
  each is its first real test; a failure is `accept_failed` and emails the operator, who can
  still confirm by hand. **Every accept is verified** (operator 2026-11-10): ~3 s after a 2xx
  accept the worker re-reads the sale with the same status read; it is `accepted` only if the
  market shows it has left pending and is not rejected/cancelled — else `accept_failed` with reason
  `accept_unverified` (still pending, or the re-read failed) or `sale_rejected_after_accept`. Go live:
  `N2S_AUTOBUY_LIVE=1` on the web service, then `UPDATE n2s_autobuy_config SET mode = 'live'`;
  stop: `kill_switch = true` or `mode = 'shadow'`; another run: raise `live_runs_allowed`. The
  `POST /v9/orders` body follows Office 3's own purchase orders; TEvo's Orders/Create page could
  not be read, so the first live run is also the body's first real test (a 4xx just stops the row).
- **`n2s_profitable_cover`** is a real **table** (not a view) holding only rows where
  `profit > 0`, synced by diff and published to Supabase Realtime. This is the external feed.
  It carries `cover_gate` / `cover_label` / `order_zone` / `sub_zone` — see §2a.

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

**The 6-hour age-out is OFF (2026-09-10, operator direction).** It was built, shipped and
then deliberately removed: the operator wants the full history retained to measure
profit/loss potential over time, and an expiry that reaps rows destroys exactly the series
being measured. `n2s_cover_history` (append-only) and `n2s_book_snapshot` (hourly exposure)
now carry the long-run record; the feed carries current state only.

> ⚠ **Turning it off cost us a deadman, and nothing replaced it.** While the cap was live, a
> stalled poll chain emptied the feed within 6 hours rather than serving buy links priced
> against dead inventory — an empty feed is an honest failure, a stale one is not. With the
> cap off, a stall now leaves the last known covers sitting on the wire indefinitely. Restoring
> it is one predicate in the sync's `src` CTE; a freshness signal that does not delete rows
> would be the better replacement.
>
> ⚠ **If it is ever restored, do NOT implement it as a `DELETE … WHERE first_seen_at <
> now() - '6 hours'` job.** The sync is a per-minute diff: deleting a row that is *still*
> profitable just gets it re-INSERTed on the next tick with a fresh `first_seen_at`. That is a
> 6-hourly delete/insert **flap**, not an expiry — it emits phantom DELETE+INSERT events to
> every subscriber (each of which they must treat as real), and resets the very timestamp it
> ages on, so nothing ever expires. Any age measured on a *target-table* column is
> self-defeating for the same reason. The shipped version filtered on `captured_at` in the
> `src` set, because that survives a delete/insert round trip and is the honest measure of how
> old the market data behind a buy link is. `updated_at` would be wrong twice over: the sync
> writes only on genuine change, so it means *last changed*, not *last confirmed* — ageing on
> it would delete the most stable covers first. A NULL `captured_at` failed closed.

---

## 2a. The gate label must reach the feed, not just the panel

The cascade classifies every cover (§4a), `n2s_cover_queue` stores the label, `v_n2s_orders`
exposes it and the subs panel colours it. For a day, that was the whole story — and
`n2s_profitable_cover`, the one surface that leaves the building, carried none of it. The
manual's own "gates" step already told integrators to read `cover_label` before acting on a
row, so we were documenting a field the feed did not send. A documented field that does not
exist is worse than an undocumented one: the reader trusts it.

It is the **safety** field, not a nicety. When the gap was found, 7 of the 11 rows on the wire
were gates 3 and 5 — the buyer moved to another section in the same zone, or up to five rows
further back — and each of those must be offered to the buyer and accepted *before* the
purchase. A receiver sorting by `profit` descending and following `buy_url` reads the top row
as "$1,126 profit, go buy it". That is the wrong action, and nothing in the payload said so.

> ⚠ **Any surface that carries `buy_url` must carry `cover_gate` beside it.** The buy link is
> the instruction to act; the gate is the permission to. Shipping one without the other is
> the whole failure mode this lane exists to prevent — we are data control and labelling, and
> the label has to survive the border.

**The section-change guarantee is structural, and it is now published.** A different
`sub_section` is only ever produced by one of the two branches that build the candidate
universe in `n2s_cover_candidates`: `match_zone`, which requires `order_zone IS NOT NULL`,
`lz.zone = oz.order_zone`, and that the normalised sections actually differ. The other branch,
`match_exact`, pins the section. So a section change with no zone match is not filtered out
downstream — it is never a candidate. Gate 5 inherits this: it carries no section predicate of
its own, so a gate 5 row is either same-section-worse-row or same-zone-different-section-worse-row.

**The row is held to the same rule as of `20260910620000`** — see §4a. `match_exact` used
to compare no zones at all, so a +5 move inside one section could cross a row-bound price
tier; gates 5/6 now require `sub_zone IS NOT DISTINCT FROM order_zone`, and a downgrade we
can see crossing a zone gets no gate. The one case that still ships unverified is a venue
with no curated zones on either side, and it says so in the label (` zone unverified`).

Three details in `n2s_profitable_cover_sync()`:

- The four columns ride through `src`, the INSERT list, the `ON CONFLICT` update **and the
  `IS DISTINCT FROM` change-detection tuple**. The last is the easy one to miss: without it a
  cover that is re-gated (same listing, new classification) does not count as changed, so no
  UPDATE, so no Realtime event — and a subscriber sits on a stale label indefinitely. That
  failure is silent on both sides.
- **Only the odd gates can appear here.** The feed is `v_n2s_orders WHERE cover_cost < 0`,
  i.e. profitable; gates 2/4/6 are the at-or-under-200%-of-cost arms, which are by definition
  not profitable. An even gate in this table means something upstream is wrong. The manual
  says so rather than listing six gates a reader of this feed will never see.
- A NULL label **fails closed**. It means the classification was lost in our pipeline, not
  that the row is safe; the manual instructs receivers to hold such a row and report
  `N2S-G900`, and never to read a missing label as gate 1.

---

## 2b. Sightlines are a second axis, and we are blind on most of it

An obstructed-view substitute against a clear-view sold seat classifies as **gate 1
`Index`** — same section, same-or-better row, cheaper, "actionable directly". It is a real
downgrade needing the buyer's consent, and until `20260910630000` nothing in the payload
said so. Same failure shape as the tier-crossing downgrade, in a dimension the cascade
never looked at.

`sub_view` is **three-state** (`obstructed` / `clear` / `unknown`) and must never be
collapsed to a boolean:

| Source | Signal | Result |
|---|---|---|
| `seatgeek` | `has_limited_view` (its own `lv` flag) + `seller_notes` | real answer |
| `gotickets` | `notes` (free text) | real answer where notes exist |
| `tevo` | `public_notes` + `view_type` from N2S's own pull (`n2s_evo_current`), via `n2s_evo_notes()` | real answer where the seller wrote a note (since `20261112030000`) |
| `ticketsdata` | nothing (and the vendor is off) | always `unknown` |

> ⚠ **TEvo was the blind spot until 2026-11-12, and TEvo is most of the book.** When this
> section was first written N2S read `listings_snapshots`, which had no `public_notes`. Since
> `20260927041700` N2S pulls EVO itself into `n2s_evo_current`, which keeps `public_notes` and
> `view_type`, but the queue went on reading notes for GoTickets and SeatGeek only, so every
> EVO sub still read `unknown` with no text. `20261112030000` reads them. `unknown` now means
> the listing itself carries no note or view type (or has left the list), which is still "we
> could not check", never "clear".
>
> **People read `sub_notes`, not just `sub_view`.** The note is shown as text under every
> suggestion (subs page, dry-run panel, buy email, approval text, MCP). The classifier is a
> regex; the seller's words are the evidence.

**Why the queue and not the cascade.** View quality is a property of the *listing*, not of
how the listing matched. Threading it through `n2s_cover_candidates` would mean ten anchored
edits inside the 250-line function whose last four revisions each cost a 60s-timeout cycle,
to compute something that does not participate in the match. `n2s_cover_queue_refresh()`
enriches from the same snapshot rows keyed on `(source, listing id, event, captured_at)`.

**A column *and* a suffix.** `sub_view` is the field a machine should branch on — a consumer
filtering on `cover_gate` should not have to parse a label to discover the seat is obstructed.
But a defect that lives only in a column nobody rendered is not surfaced, so `cover_label`
also gains ` obstructed view`, appended in the refresh (which DELETEs and rebuilds the whole
queue each run, so it cannot accumulate).

> ⚠ **Only `obstructed` becomes a suffix; `unknown` stays a column.** `unknown` is the state
> of *most* rows today, and a suffix carried by the majority stops carrying information — it
> would train readers to skip the tail of every label, which is exactly where ` repost single`
> and ` zone unverified` live. The label is a workflow instruction: `obstructed` changes the
> action, `unknown` does not. The classifier vocabulary is **shared with the scanner's confidence
rule** (`20260811273000` and siblings); widen both together or neither. `20261112030000`
> *narrowed* only N2S's copy, to stop two false matches seen in live notes (`limited` inside
> "unlimited food", `behind` in "behind home bench"); the scanner's copy (D0) still has both.

## 3. Cron chain

| Job | Schedule | What it does |
|---|---|---|
| `n2s_fast_land_15s` (job 665) | every 15 s | `n2s_fast_land()` — exits cheaply when nothing is waiting; otherwise, under the shared `n2s_cover_stage` advisory lock (the tick takes the same lock), drains `n2s_mkt_pull` replies → queue refresh → history → feed sync → push drain/queue. Replies land between ticks instead of waiting up to a minute. (20260927045900) |
| `n2s_crm_direct_20s` (job 660) | **every 30 s**; command `SELECT public.n2s_crm_fetch_direct(150, 0, 20000);` (20260927160500) | `n2s_crm_fetch_direct(150, 0, …)` — synchronous GET of CRM page 0 (sorted `updated_at` DESC) through the `http` extension, upserted in the same statement; runs **alongside** the tick's pg_net page 0, newest write wins. Logged per fetch in `n2s_crm_direct_log` (2-day window). (20260925231959, 20260925233701) |
| cron 640 `n2s_pipeline_tick_1min` | every minute, back-to-back; command is ONE statement `SELECT public.n2s_pipeline_tick(200);` (see note) | `n2s_pipeline_tick()` — one budgeted chain: drain the pg_net CRM replies → order-identity pull → **Automatiq-hub quick map** → mapper (only what the hub declined) → **hub write-back** → **GoTickets name matcher, scoped to events with no GoTickets link (~2 s)** → `n2s_pull_all_sources` (so a new link is polled the same tick) → queue refresh / history / feed sync → sub ping → push outbox → **fire CRM page 0 only via pg_net (25 s timeout)** for the next tick. Since 2026-09-27 it drains `n2s_mkt_pull` first, polls with `p_refresh_after`/`p_sweep_after` = 2 min, and only for orders where `n2s_timer_open()` is true (20260927030000, 20260927030200, 20260927160500) |
| `n2s_gt_map_by_name_full_30min` | `13,43 * * * *` | `n2s_gt_map_by_name()` **full pass** — catches a second GoTickets listing for an event that already has one link (~7 s). The scoped pass runs inside every tick. (20260926031431) |
| `n2s_book_snapshot_hourly` | `37 * * * *` | `n2s_book_snapshot_take()` — open/covered/uncovered exposure, so the P&L series measures what we did NOT cover too |

Jobs 598, 602, `n2s_pull_1min` and `n2s_cover_push_1min` were folded into cron 640; 599/601/603
remain scheduled but **inactive**.

**Paused terminal listing pollers (2026-09-27, `20260927043400`).** N2S has priority on the marketplace
rate limits and nobody reads the terminal's listing history, so these are `active = false`:
628/629/630 (GoTickets poll/drain/deal scan), 639 (SeatGeek broker listings), 321 and 330–334, and 627.
The **event matchers keep running**. To resume one, run `cron.alter_job(jobid, active := true)`.

> ⚠ **The panel is not gated; the feed is (20260928174500).** `v_n2s_orders` (panel) = last 24 h +
> live orders; `v_n2s_orders_live` (feed, snapshot) = the 10-minute gate below. Point any new
> external consumer at `_live`, never at the panel view.
>
> ⚠ **The 10-minute gate is the whole contract (20260927020000, 20260927023400).** `n2s_timer_open(expires_at, expired, alert_at)`
> is true until `alert_at + 10 min`, or `expires_at − 5 min` when there is no alert time, and false once the CRM marks the order expired.
> It gates `n2s_pull_all_sources`, `n2s_cover_candidates` and `v_n2s_orders`, so the panel and Albert's feed
> only show orders still in the window. History keeps one closing `gone` row per order.
>
> ⚠ **CRM timeouts (20260927160500).** With a 60 s pg_net timeout, a hung CRM request held a
> pg_net batch, and every other reply in that batch waited behind it. At 25 s (pg_net) and 20 s (direct, every 30 s),
> direct success went from ~73% to 93–100% (p50 1.9 s).

> ⚠ **The CRM endpoint is the slow part — measure before "fixing" the queue (2026-09-25).**
> A typical 2 min 5 s from CRM creation to `n2s_items` looked like pg_net queueing: the tick's
> three pages always "answered" at the same instant (typical 62 s, never under 34 s) and 19%
> died on the 60 s timeout. 20260925231959 took page 0 off pg_net onto a synchronous fetch with a
> 15 s timeout — and **every** direct call timed out with 0 bytes received, stalling new-order
> ingest for ~16 min, because `crm.s4kcs.com/api/v1/n2s/items` itself takes ~35–60 s per call,
> **regardless of page size** (limit=20 also exceeded 45 s; limit=150 answered in 49.9 s).
> 20260925233701 put page 0 back on pg_net and gave the direct path a 50 s timeout; both now run.
> The remaining ~78 s reply-to-drain wait (the drain only runs at the start of the next tick) is
> ours and separable. The CRM latency is not: it needs a cheaper endpoint on the CRM side
> (e.g. an `updated_since` filter, or a push).
>
> ⚠ **The GoTickets name matcher must stay cheap, and stay in the tick (2026-09-26).** Its old
> date predicate was a `CASE` over expressions of `g.event_time_utc` that no index could serve:
> a sequential scan of ~186k unlinked GoTickets events and ~4.8 M join evaluations — 35.7 s even
> for 26 events, and it rescanned events that already had a link. It is now a half-open range per
> event (`win_lo`/`win_hi`, served by `idx_gt_event_time`; verified pair-for-pair identical, 34,415
> each way) plus `p_only_unlinked`, which makes the in-tick pass ~2 s. Moving it to its own job
> instead (20260926014415) was measured and reverted: it competed with the tick for the database,
> ran 2–4 min, made no links and doubled tick length. Don't reintroduce either.
>
> ⚠ **Cron 640's command must stay a single statement (20260926170000).** As
> `SET statement_timeout='240s'; SELECT n2s_pipeline_tick(200);` it stalled pg_cron's single
> scheduler for the whole project: 88.7% of all job starts landed within 1 s of a tick end, and
> the stall caused most of the ~2k daily "job startup timeout" failures. As one statement: 16.1%,
> startup timeouts −37%, '20 seconds' jobs on time, tick p50 52 → 36 s. The tick's own 200 s
> budget and `cron_try_lock` guard replace the 240 s timeout.
>
> ⚠ **Two writers, one guard.** The direct fetch and the tick's drain both go through
> `n2s_items_upsert()`, which only updates a row when the incoming `n2s_updated_at` is at least
> as new as the stored one — a pg_net reply captured before a direct fetch but drained after it
> must never roll an order back. Keep every writer on that helper.

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
| `N2S-C200` | cover | **Retired 2026-09-10** — superseded by `N2S-G200`. | Said unprofitable covers never leave the building; the gate cascade now labels them S4KTrading. Row kept so old lookups resolve. |
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
| `N2S-G100` | gate | Gate 1 `Index` — exact section, same row or better, profitable. | Directly actionable. |
| `N2S-G200` | gate | Gate 2 `S4KTrading` — exact section, cost ≤ 200% of the sale. | Trading decision, not a fault. Not on the external feed. |
| `N2S-G300` | gate | Gate 3 `Index offer subs` — same curated zone, different section, profitable. | **Offer to the buyer first.** |
| `N2S-G400` | gate | Gate 4 `offer subs s4ktrading` — same zone, ≤ 200%. | Offer first; also costs more than the sale. |
| `N2S-G500` | gate | Gate 5 `Index Down offer subs` — up to 5 rows back, same zone, profitable. | Offer first. |
| `N2S-G600` | gate | Gate 6 `Down offer subs S4KTrading` — up to 5 rows back, same zone, ≤ 200%. | Offer first. |
| `N2S-G700` | gate | Suffix ` repost single` — `sub_qty` = obligation + 1. | Buy `sub_qty`, repost the spare. |
| `N2S-G800` | gate | No gate — over the ceiling, too far back, or no unambiguous zone. | Expected; the cover is withheld on purpose. |
| `N2S-G900` | gate | A feed row with `cover_label`/`cover_gate` NULL. | Fail closed; report the `n2s_id`. Pipeline fault on our side. |
| `N2S-G1000` | gate | Suffix ` zone unverified` — gate 5/6 at a venue with no curated zones. | Judge the row drop yourself; the zone rule could not be checked. |
| `N2S-G1100` | gate | Suffix ` single ticket` — the sale is one seat. | Read `sub_qty`; may co-occur with ` repost single`. |
| `N2S-V100` | view | `sub_view = 'obstructed'`. | Offer first whatever the gate; quote `sub_notes`. |
| `N2S-V200` | view | `sub_view = 'unknown'` — the listing carries no note or view data. | Not "clear". Read the listing yourself (§2b). |
| `N2S-A104` | access | `Invalid login credentials` on an account that has **no Supabase password** — it signs in via Google/OAuth. | Retrying the password never works: an OAuth password is a different credential and GoTrue holds no hash to check. Set a real Supabase password (step 3 of `n2s_integration_doc`). A headless receiver cannot use an OAuth-only account at all. |

---

## 5. Consuming the feed (external)

Full step-by-step, versioned and queryable, is seeded into **`public.n2s_integration_doc`**
(read it in order with `select * from n2s_integration_doc order by step_no`). Short version:

1. Get the project URL and the **publishable** (anon) key. Never the `service_role` key —
   it bypasses RLS on every table in the project, so handing it to a receiver hands over the
   whole database.
2. **Create a dedicated integration user with a Supabase password.** ⚠ A Google/OAuth
   password is *not* one: if the user signs in through a provider, GoTrue stores no
   password hash and `signInWithPassword` returns `Invalid login credentials` however many
   times the correct Google password is typed (`N2S-A104`). Every account on this project
   is Google-only (10 of 10 on 2026-09-24), so none works as-is. Operator side: confirm
   Authentication → Sign In / Providers → **Email** is enabled, then Authentication → Users
   → **Add user → Create new user** with an address naming the integration (not a person),
   a strong password, and **Auto Confirm User** ticked. Adding a password to an existing
   account (dashboard or Auth Admin API) is the fallback, not the default — on a staff login
   a leak is an account takeover. **Never** set one with `UPDATE auth.users … crypt(...)`:
   a value passed through a SQL console lands in the Postgres query log. The integrator's
   first sign-in fills `auth.users.last_sign_in_at`, which is the operator-side proof it
   worked.
3. Sign in as a real Supabase Auth user. The feed grants `SELECT` to `authenticated` only;
   `anon` gets nothing (`N2S-A101`).
4. Read current state: `GET /rest/v1/n2s_profitable_cover?select=*&order=profit.desc`.
5. Subscribe for changes: Realtime `postgres_changes` on `public.n2s_profitable_cover`,
   events `INSERT`/`UPDATE`/`DELETE`. RLS applies to the socket exactly as to the read.
6. Treat a `DELETE` as **"this cover is gone"** — un-flag it. `REPLICA IDENTITY FULL` means
   the event carries the full old row, so you know which order it was.

The columns a buyer needs: **`cover_label` first** (see §2a — it says whether the row may be
acted on at all), then `order_number` (and `order_key` to find it in the CRM), `sub_section`,
`sub_row`, `sub_qty`, `buy_url`, `profit`.

---

## 6. Hard boundaries

These are not style preferences. Each has a guard behind it.

- **The pipeline never writes to a marketplace — except the two operator-authorized EVO
  writes** (2026-11-09): `POST /v9/orders` (buy the sub) and `POST /v9/orders/{id}/accept`
  (accept our own sale), only from `evo_buy_client.py`, whose guard pins POST to exactly those
  paths (`EVO_WRITE_PATHS`, required verbatim by `scripts/check_readonly.py`). No holds, no
  reprice, no reject — `RULE 2`, `CLAUDE.md`. Every other `*_client.py` is GET-only by
  construction (`ALLOWED_HTTP_METHODS = frozenset({"GET"})` + `_assert_readonly_method()` that
  raises), audited by `scripts/check_readonly.py` and `tests/test_readonly_guards.py`. Weakening
  either, or adding a write path, is a **security-CRIT** change.
- **The push outbox refuses listing-source hosts at runtime** (`N2S-P104`). A webhook URL
  is operator-supplied config, so the guard is in the drain, not only in CI.
- **No secret reaches the receiver.** `get_app_secret()` enforces a `current_user` assert
  *and* a hard name whitelist raising `42501`. Extend the whitelist additively; never relax
  the assert.
- **Nothing is bought automatically unless the operator turns live mode on** — EVO only,
  `live_runs_allowed` runs (1), every cap above. Otherwise the pipeline surfaces a link and a human
  clicks it.

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
- **D7-DATA-1** — ~~TEvo `public_notes` never reaches `sub_view`~~ **closed for N2S
  2026-11-12** (`20261112030000`: the queue reads `n2s_evo_current`). `listings_snapshots`
  (A1) still has no notes before 2026-09-11; N2S no longer reads it. See §2b.
- **Parking passes cannot be covered (2026-09-27).** A parking order maps to the game's event, and
  `n2s_cover_candidates` excludes ancillary listings (`is_ancillary`), so a parking obligation never
  gets a candidate. Deliberately left for now on operator direction.
- **pg_net batching delays landing.** A pg_net reply becomes visible only when its whole batch
  completes, and `_http_response.created` holds the batch **start** time, so it misleads latency
  analysis. `n2s_fast_land` cannot land a reply earlier than its batch. A synchronous (`http`
  extension) marketplace fetch would remove the delay; it has not been built.
- **CRM requests still hang sometimes.** The shorter timeouts limit how long a hung request blocks,
  but the hang itself is on the CRM side and needs its owners.
