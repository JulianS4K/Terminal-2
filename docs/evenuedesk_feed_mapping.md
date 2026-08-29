# eVenue Desk feed — sample-data mapping

> **What this is.** A field-by-field map of the eVenue Desk raw-blocks feed, derived by
> profiling the four sample exports the operator supplied (2026-08-19 / 2026-08-21) against
> the desk's API reference. Read this **before** authoring the client, the ingest RPC, or any
> `evd_*` table — every claim below is measured from the samples, not assumed from the docs.
>
> **Doc version:** v1.1.0 (2026-08-29) — §9: base URL + auth answered by the operator (`https://crm.s4kcs.com`, `X-API-Key`); flagged the `s4k_`/`evd_` key-prefix mismatch and the session-container egress block. · v1.0.0 (2026-08-25) — initial mapping from the four sample workbooks.

Upstream contract: the desk's consumer plane `GET /api/v1/*` (bearer `evd_…`), read-only by
construction — every endpoint is a GET and there is no write surface. RULE 2 (CLAUDE.md §2)
is satisfied by the upstream's own shape; our client still declares the canonical guard.

---

## 1. The sample corpus

| File | Sheet | Rows | Cols | What it actually is |
|---|---|---:|---:|---|
| `raw_blocks_20260819T003235Z.xlsx` | `raw blocks` | 28,254 | 22 | **All stored pulls** — line history, `ticket_uid` repeats across `pulled_at` |
| `raw_blocks_latest_20260819T004337Z.xlsx` | `raw blocks` | 23,869 | 22 | **Latest-pull-per-event feed** — the `/feed/full` shape |
| `raw_blocks_latest_20260821T140906Z.xlsx` | `raw blocks` | 82,562 | 23 | Same, 2 days later — **+1 platform, +109 events, +`max_contiguous` column** |
| `diff_demo_lasttwoscans.xlsx` | `diff` | 1,877 | 24 | **VDIFF** of the two latest feeds — `/feed/changes` shape |

Growth between the two latest feeds (2 days): events 36 → 145, hosts 13 → 31, platforms 3 → 4,
lines 23.9k → 82.6k. **The source is scaling fast — size the ingest for ~4× headroom, not for today.**

---

## 2. Canonical column grammar (`FEED_COLUMNS`, 22 fields, order preserved in every export)

Non-null % is measured on `raw_blocks_latest_20260821` (82,562 rows).

| # | Column | Type | Non-null | Grammar / measured domain | Notes |
|---:|---|---|---:|---|---|
| 1 | `internal_id` | text | **0.0%** | — | **Our** ID from the desk's Map IDs tab. Empty in every sample: *nothing is paired yet*. This is the join key we must populate. |
| 2 | `event_uid` | uuid | 100% | UUIDv5, 145 distinct | Desk-stable event identity. **Use as the event key.** |
| 3 | `event_id` | text | 100% | 4 platform grammars (§4) | Native upstream id — `acct:season:item` for Paciolan, prefix-tagged otherwise. |
| 4 | `event_name` | text | 100% | 145 distinct | Often carries the id in parens: `2026 Football (467:F26:F01)`. Not a clean title. |
| 5 | `opponent` | text | 99.4% | 131 distinct | `Football vs. Wyoming`, `K-State Football vs. Nicholls`. **Null for all non-Paciolan rows.** |
| 6 | `event_date` | text | 100% | `YYYY-MM-DD`, 32 distinct | String, **not** a date — no timezone. |
| 7 | `event_time` | text | 60.2% | **two formats**: `HH:MM` (49,518 rows) and `HH:MM:SS` (160 rows, `am.ticketmaster.com` only) | **40% missing.** Local wall time, no tz. Never assume a start instant, and never parse with a fixed `HH:MM` mask. |
| 8 | `school_host` | text | 100% | 31 hosts | The storefront host — the line's true provenance. |
| 9 | `venue` | text | 99.8% | 30 distinct | Null for all `am.ticketmaster.com` rows. |
| 10 | `platform` | text | 100% | 4 values (§4) | Derived from host by the desk. |
| 11 | `level` | text | 99.4% | 48 distinct | **Paciolan only** (100% there, 0% elsewhere). The `H:3` → level `H` / section `3` split. |
| 12 | `section` | text | 100% | 430 distinct | Post-split; **no residual `:` in any row** (verified 0). |
| 13 | `row` | text | 100%* | 224 distinct | Label, not a number: `12`, `ADA-NW`, and — ProVenue only — ranges `1-5`, `6+`. |
| 14 | `seat_low` | int | 99.9% | 1..63 | Null on qty-only lines (§5). |
| 15 | `seat_high` | int | 99.9% | 1..73 | Null on qty-only lines. |
| 16 | `qty` | int | 100%* | 1..311 | **Nullable in practice** — one GA line carries no qty. |
| 17 | `price_per_ticket` | numeric | 100% | 10..699 | **ALL-IN (fees included)**, per the API reference. Never `<= 0` in the samples. |
| 18 | `price_level` | text | 100% | 59 distinct | Upstream price code: `24`, `7R`, `D02`, `11F`. **Text, never numeric.** |
| 19 | `inventory_type` | text | 100% | 6 values | `single_game`, `other`, `season`, `primary`, `ga`, `section`. |
| 20 | `price_source` | text | 100% | 4 values | 1:1 with `platform` in every sample (§4) — redundant, and excluded from the change hash. |
| 21 | `ticket_uid` | uuid | 100% | UUIDv5 of event+section+row+seat range | **The line key.** Stable across pulls and across scans. |
| 22 | `pulled_at` | timestamptz | 100% | ISO-8601 `Z` | One distinct stamp per event in a latest feed (145/145). |

\* `row` and `qty` are 100% populated at the sheet level but each has exactly one null row in the
2026-08-21 sample — see §5. **Model both as nullable.**

---

## 3. Keys and invariants (all verified against the samples)

| Invariant | Evidence | Consequence for our schema |
|---|---|---|
| `ticket_uid` is unique **within a latest feed** | 23,869/23,869 and 82,562/82,562 distinct | PK of a `current` table. |
| `(ticket_uid, pulled_at)` is unique **in the history export** | 28,254/28,254 distinct over 23,886 uids | PK of a `history` table. |
| The `fx_` fallback key is **1:1 with `ticket_uid`** | `event_id\|level\|section\|row\|seat_low\|seat_high\|price_level` → identical cardinality in all 4 files | The documented fallback is safe when a uid is absent. |
| `qty == seat_high - seat_low + 1` on every seat-numbered line | **0 mismatches / 106,348 rows** | A seat-numbered line *is* a contiguous run. Enforce as a CHECK; a violation means parser drift. |
| `seat_low <= seat_high` always | 0 violations | CHECK constraint. |
| A latest feed carries exactly **one `pulled_at` per event** | 36/36 and 145/145 | "Latest stored pull per event" confirmed — dedupe on ingest is unnecessary. |
| Only `price_per_ticket` ever moves on a surviving line | Across 22,793 common uids over 2 days: 62 price changes, **0** section/row/qty/seat changes | Price history is the only per-line time series worth keeping. |

**Line survival:** 22,793 of 23,869 uids (95.5%) survived the 2-day window; 11,986 of those were
not even re-pulled (identical `pulled_at`). The feed is quiet — **`/feed/changes` polling is cheap
and is the correct ingest path**; `/feed/full` is a baseline-reset call, not a poll.

---

## 4. Platform fidelity matrix — *the most important finding*

The four platforms are **not the same shape**. A single "seat block" model silently mangles two of them.

| | `paciolan` | `ticketmaster-web` | `ticketmaster` | `provenue` |
|---|---|---|---|---|
| Rows (2026-08-21) | 82,107 (99.5%) | 220 | 160 | 75 |
| Events / hosts | 140 / 28 | 1 / `www.ticketmaster.com` | 3 / `am.ticketmaster.com` | 1 / `mlb.tickets.com` |
| `event_id` grammar | `467:F26:F01` (`acct:season:item`) | `tmw:cota:3A00642D96C856BF` | `tmlvgp:57:GS26KZ19` | `pv:21:9643173` |
| `price_source` | `matrix` | `quickpicks` | `priceData` | `provenue` |
| `level` | **100%** | — | — | — |
| `seat_low`/`seat_high` | 100% | 99.5% | 98.1% | **0%** |
| `row` | label (`12`, `ADA-NW`) | label | label | **range string** (`1-5`, `6+`) or null |
| `event_time` | 60% | **0%** | 100% | 100% |
| `opponent` | 100% | **0%** | **0%** | **0%** |
| `venue` | 100% | 100% | **0%** | 100% |
| `qty` range | 1–56 | 2–8 | 1–23 | **1–311** |
| `inventory_type` | `single_game` / `other` / `season` | `primary` / `ga` | `single_game` / `section` | `primary` |
| **Granularity** | **seat block** | seat block | seat block / zone | **section aggregate** |

**The ProVenue rule:** `mlb.tickets.com` lines are **not seat blocks**. They are section-level
availability aggregates — no seat numbers, `row` holds a range string or nothing, and `qty` runs
to 311. Treating a ProVenue row as a contiguous seat block invents seats that do not exist.
Derive a `seat_granularity` column on ingest (`seat_block` when `seat_low IS NOT NULL`, else
`aggregate`) and gate every seat-level consumer on it.

---

## 5. Qty-only lines (79 rows, 0.1%)

Lines with no seat numbers, by kind:

| Kind | n | Shape |
|---|---:|---|
| ProVenue section aggregates | 75 | `inventory_type='primary'`, qty 1–311, `row` = range or null |
| Ticketmaster zone rows | 3 | `inventory_type='section'`, e.g. `KZ2107` Koval Zone, qty 2–23 |
| GA admission | 1 | `inventory_type='ga'`, F1 USGP Saturday Admission, section `GA12`, **`qty` is null** |

`inventory_type IN ('ga','section','primary')` is the reliable signal that seat numbers are absent —
but `seat_low IS NULL` is the direct test and should be preferred.

---

## 6. Delta semantics — the diff workbook reconciles exactly

`diff_demo_lasttwoscans.xlsx` is precisely the VDIFF between the two latest feeds:

| `change` | n | Verified against the block files |
|---|---:|---|
| `added` | 739 | 739/739 present in `0821`, **0** in `0819` ✓ |
| `changed` | 62 | 62/62 present in **both** ✓ |
| `removed` | 1,076 | 1,076/1,076 in `0819`, **0** in `0821` ✓ — and the set is *identical* to the computed `0819 − 0821` gone-set ✓ |

Two extra columns on the diff sheet: `change` (first column) and `changed_fields` (last).

- `changed_fields` is populated **only** on `change='changed'` rows (62/62), format
  `"field: old -> new"`, semicolon-separated for multiples (none in this sample).
- Every one of the 62 named `price_per_ticket` — consistent with `HASH_FIELDS` = `FEED_COLUMNS`
  minus `price_source`, `ticket_uid`, `pulled_at` (so a re-stamp of identical lines is not a change).
- The row itself carries the **new** value; the old value survives only inside `changed_fields`.
- `removed` rows are last-known full rows — usable as the "likely sold" signal.

Note the added-row count is small (739) because the diff covers only the 16 **re-pulled** events;
the 109 genuinely new events in the `0821` feed contribute 59,769 new lines that this per-event
diff does not describe. **A first sight of an event is not a delta — handle new events on the
`/feed/full` path, not the changes path.**

---

## 7. Drift findings (raise with the desk owner before wiring)

1. **`max_contiguous` appeared** in the 2026-08-21 export (column 17, right after `qty`) and is
   **100% empty**. It is *not* in the documented `FEED_COLUMNS`. Ingest must key rows **by column
   name, never by position**, and tolerate unknown columns rather than failing.
2. **`internal_id` is empty in 100% of sample rows.** The desk's Map IDs pairing has not been done
   for us. Until it is, `event_uid` is our only stable join and every AQ cross-match must go through
   the mapper (`PROJECT_BIBLE §0`).
3. **`price_source` is fully determined by `platform`** in all four samples. Store it, but do not
   treat it as independent signal until a counter-example appears.
4. **`event_name` embeds the `event_id`** for Paciolan (`2026 Football (467:F26:F01)`) and is a
   season label, not a matchup — `opponent` is the matchup field, and it is Paciolan-only.
5. **`event_time` is not one format.** 160 `am.ticketmaster.com` rows carry `HH:MM:SS`
   (all `16:30:00`); everything else is `HH:MM`. Parse permissively.

---

## 8. Proposed landing shape

Keyed to what the samples actually support (names provisional, pending the migration):

| Target | Grain | Key | Source |
|---|---|---|---|
| `evd_events` | one row per desk event | `event_uid` | identity columns 1–10 |
| `evd_lines_current` | current inventory | `ticket_uid` | `/feed/full`, replaced by `/feed/changes` upserts |
| `evd_line_price_history` | price moves only | `(ticket_uid, observed_at)` | `changed_fields` price transitions |
| `evd_feed_cursor` | one row per token | — | `as_of` from the last `/feed/changes`, for the `since` cursor |

Derived-on-ingest columns not present upstream: `seat_granularity` (§4), `is_seat_numbered`,
and a normalized `event_start` only where `event_time` is present (60%).

---

## 9. Open questions for the desk owner

1. Is `max_contiguous` coming to the API `FEED_COLUMNS`, and what does it mean when populated?
2. Can our `internal_id` values be loaded into Map IDs — and do we push them, or does the desk pull?
3. ~~What is the desk's reachable base URL?~~ **Answered 2026-08-29 (operator):**
   `https://crm.s4kcs.com`, consumer plane `/api/v1/*`, auth `X-API-Key: s4k_…`. Note the key
   prefix is `s4k_`, not the `evd_` this reference documents — so the marketplace plane may not
   be endpoint-identical to §2 below. Only `GET /api/v1/ping` is confirmed; everything else is
   still transcribed-not-verified, which is why the poller lands responses raw (see §8).
   The desk is **not** reachable from the Claude Code session container — its egress policy
   returns a gateway 403 for `crm.s4kcs.com` — so live verification must run from prod or from
   an environment whose network policy allows the host.
4. Expected `/feed/changes` poll cadence, and whether a missed poll can be recovered without a
   full baseline reset (a `/feed/full` call **rewrites** the token's baseline).
