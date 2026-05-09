# Data reality check — Supabase findings vs prior design assumptions (2026-05-08)

> **Trigger**: Julian asked me to "see what information Supabase has" before running the third sim doc. The answer reshaped my mental model enough that the prior 2 sim docs need calibration before edge-cases land.
>
> **What this doc is**: a fact-check pass against live data. 12 findings, mapped to which prior design doc each affects, with recommended surgical edits (not rewrites).
>
> **Project**: `hzrizjeaxlqcxfrtczpq` (Terminal .5).

---

## 0. TL;DR

The simulation docs assumed signals existed that don't (yet) — and missed signals that do. The bigger surprise: **TEvo carries 99% of the analytical weight**, not the 3-pricing-set framing I was operating on. SeatData and SeatGeek are real but xref'd to only 1 TEvo event each. ESPN is rich for MLB/NBA/MLS but ABSENT for NFL/NHL/WNBA athletes. Wikipedia is NOT future — already ingested with 126 performer summaries + 25 rivalries. `performer_zones` (179) + `performer_zone_rules` (3553) exist as **zone geometry storage** (which sections/rows belong to which zone) — but the pricer RULES (Smart/Dumb, deltas, spacings) are NOT in our DB; those live in the existing AQ system.

---

## 1. The 12 findings

### Finding 1 · TEvo carries 99% of analytical weight
- `event_metrics`: 28,342 snapshots across 634 events (avg 44.7 snapshots / event, max 403, history 2026-04-23 → 2026-05-09 = 16 days). This is the strongest signal by an order of magnitude.
- `seatgeek_event_metrics`: 377 rows but **all for 1 TEvo-xref'd event**. SG metrics is essentially Knicks-G5-only in our system.
- `seatdata_event_stats`: **0 rows**. The SeatData stats rollup hasn't been computed yet.
- `seatdata_sales_snapshots`: 254 rows but **all for 1 TEvo-xref'd event** (Knicks G5).

**Affects**: terminal-only-redesign (the "3 pricing data sets" framing), both sim docs (every chart-band overlay assumed SG/SD signals).

### Finding 2 · SeatGeek xref gap is the highest-value backfill
- `seatgeek_seller_listings`: 200 listings covering **25 distinct SG events** but only **1 xref'd to TEvo**.
- `seatgeek_orders`: 400 orders covering **186 distinct SG events** but **0 xref'd to TEvo**.
- The SG raw data is rich; the TEvo↔SG matching is the gap.

**Affects**: any UI that depends on `unified_orders_by_event WHERE tevo_event_id = X` — currently most SG orders are invisible at the event level. **Prioritize the SG xref backfill** as a blocking task before broader rollout.

### Finding 3 · ESPN athletes only NBA/MLB/MLS
- `espn_athletes`: 857 rows total → **MLB 545 / NBA 281 / MLS 31**.
- ZERO athletes for NFL, NHL, WNBA, World Cup, NCAA.
- `espn_injury_snapshot_latest`: 1973 active injuries — but only for the 3 leagues with athlete data.

**Affects**: sports sim doc heavily.
- NFL-2 (MNF singleton with player overlays) → no NFL player data exists; degrade to team/news/standings only.
- NHL scenarios (1-5) → no NHL player data; injury overlays still work via team mapping but player-specific narratives don't.
- WNBA-1 (Caitlin Clark single-star) → **CRITICAL** — no WNBA athletes ingested; the entire sim's premise (player presence drives demand) has no data backing. Can still do team-level but not Clark-specific.
- MLS scenarios → 31 athletes is thin; works for the biggest names but not deep.
- F1/Tennis/Golf scenarios → ESPN doesn't track these athletes anyway; they always assumed sparse player data.
- **NBA + MLB scenarios** → fully supported.

### Finding 4 · Wikipedia is ALREADY ingested
- `wiki_summary`: 126 rows — performer summaries with description, extract, thumbnail_url, founded_year, championships, meta jsonb.
- `wiki_rivalries`: 25 rows.
- `wiki_seasons`: 0 rows (the season-by-season historical data is the gap).

**Affects**: non-sports sim doc treated Wikipedia as FUTURE in every scenario. It's PRESENT for 126 performers. The non-sports performer LP "artist context blurb" can wire NOW for those 126 performers.

### Finding 5 · `performer_zones` + `performer_zone_rules` already exist (zone GEOMETRY, not rules)
- `performer_zones`: 179 — zone definitions with `(performer_id, venue_id, name, display_order, source)`.
- `performer_zone_rules`: 3553 — section-row geometry per zone: `(zone_id, section_from, section_to, row_from, row_to)`.
- This is **WHICH sections/rows belong to which named zone** for each (performer, venue) combo. NOT the pricing rule config.
- The pricer rule config (Smart/Dumb, SG2-SG6 deltas, top-of-range, max-step-drop, etc. — what was in Julian's CSV) lives in the **AQ system**, not in our Supabase.

**Affects**: terminal-only-redesign called for a NEW `zone_pricer` table. The geometry half exists; the rule-storage half doesn't. **`zone_pricer` ingest from AQ → our DB is still needed**, but it's a pure import (rules), not a from-scratch design.

### Finding 6 · `event_sentiment` is 18 events only
- The composite formula is in `compute_buyer_sentiment(event_id)` and the table exists, but only 18 rows are populated (all from earlier ad-hoc backfills).

**Affects**: every sim that surfaces a "sentiment ribbon" or "sentiment KPI" today gets a fallback. Until the cron backfills broadly, the sentiment band is decorative for most events.

### Finding 7 · 0 EVO orders (CRON_SECRET issue)
- `evo_orders`: 0 rows (confirmed audit's known external dep).
- `unified_orders` total = 654 = 400 SG + 254 SD + 0 EVO.

**Affects**: any panel showing "our outbound TEvo orders" is empty. The Undelivered Window we designed is currently SG-only + SD-only. Once Railway's `CRON_SECRET` lands, EVO orders flow.

### Finding 8 · 1538 events total · 1228 games · 130 concerts · 178 null type
- The system has grown — 1538 events vs the 822 cited in code's redesign memo (mid-week).
- Sports : non-sports ratio = 9.4 : 1 by event count.
- Concert PERFORMERS (445 in metadata) outnumber concert EVENTS (130). Most concert performers have no upcoming events tracked — an inventory-coverage gap, not a data-shape problem.

**Affects**: non-sports sim doc — the "tour-wide" sims work but the universe of comparable tours we have data for is small (~130 concerts spread across 445 performers = sparse per-performer).

### Finding 9 · `major_event_calendar` (14) — tentpole registry exists
- 14 rows covering Super Bowl, Stanley Cup Final, MLS Cup, etc. with windows, recurrence, venue context.

**Affects**: sports sim's NFL-4 (Super Bowl), NHL-1 (Cup G7), MLS-5 (MLS Cup Final), MD-3 (Masters), etc. — all should reference this registry rather than treat the events as ad-hoc. Mega-event mode auto-detects from this.

### Finding 10 · `venue_assets` is broader than I claimed
- 111 venues have assets (vs the "top ~30" cited in MEDIA_ASSETS doc).
- Hero images / map URLs are available for substantially more of the catalog than I'd assumed.

**Affects**: media assets doc — recommend updating "seeded for top ~30" to "seeded for 111 venues" + a query to identify which of the 126 distinct venues are missing.

### Finding 11 · `zone_metrics` (18K) + `section_metrics` (2M) + `listings_snapshots` (8.5M) are massive
- This is the densest signal in the system. Pricing depth is real.
- These tables can support per-zone sales-velocity, per-section premium curves, listing-life-cycle analytics — none of which are surfaced in the design.

**Affects**: terminal-only-redesign undersold this. The Event Workbench's zone breakdown panel should query `zone_metrics` time-series, not just latest. The Section Premium Curve in T3 (Venue Pulse) should aggregate `section_metrics` historically — not a "future" computation.

### Finding 12 · `chat_corpus` (79) — chatbot training already structured
- Plus auxiliary tables: `chat_aliases` (9), `chat_audit_findings` (16), `chat_corpus`, `chat_glossary_known`, `chat_rate_limits`, `chat_stopwords`, `chat_term_freq_in/out`, `chat_term_frequency`.
- The chatbot training pipeline is partially built. The retail-site doc proposed a NEW `retail_events` table for telemetry; the existing `chat_*` tables suggest the chatbot already has its own corpus + frequency analytics.

**Affects**: retail-site-2026-05-08.md — the chatbot training section over-claimed novelty. Some pipeline is built; recommend cross-referencing existing tables.

---

## 2. What this means for the prior docs

| Doc | Severity | What needs to change |
|---|---|---|
| `terminal-only-redesign-2026-05-08.md` | **HIGH** | Re-scope: TEvo is the analytical core, not "3 pricing sets equally". `zone_pricer` is half-existing (geometry) + half-missing (rules). Add `wiki_summary` to the data-source map (was missing). Note `performer_zone_rules` as the geometry layer. Lower the priority of "broad SD/SG signals" since coverage is 1 event each. |
| `simulations-non-sports-2026-05-08.md` | **MEDIUM** | Move Wikipedia from FUTURE to PRESENT (126 performers). Note that sound-stage non-sports universe is small (~130 events). The 5 sim shapes still work; the data backing for them is leaner than implied. |
| `simulations-sports-2026-05-08.md` | **HIGH** | NFL/NHL/WNBA player-driven scenarios degrade to team-only. WNBA-1 (Caitlin Clark) needs an explicit "no athlete data today" caveat. Reference `major_event_calendar` for tentpole detection. NBA + MLB scenarios are fully supported as written. |
| `MEDIA_ASSETS_2026-05-08.md` | LOW | Update "top ~30 venues seeded" to "111 venues with assets" + a small note that the long tail is the remaining ~15 venues out of 126 distinct. |
| `retail-site-2026-05-08.md` | LOW | Cross-reference `chat_*` tables; the proposed `retail_events` is complementary, not a from-scratch corpus. |

---

## 3. Recommended surgical edits

I can apply these without rewriting docs. Each is a single-section addition or a corrected paragraph:

**Edit A — terminal-only-redesign §1**: add a "Data reality 2026-05-08" subsection clarifying that TEvo is the dominant signal; SD/SG are conceptually present but practically Knicks-G5-only.

**Edit B — terminal-only-redesign §4** (schema additions): correct `zone_pricer` from "P1 NEW table" to "P1 INGEST from AQ; geometry already in `performer_zones` + `performer_zone_rules`". Add `wiki_summary` as an existing-not-future data source (move from "what's missing" to "already wired" list).

**Edit C — simulations-non-sports**: search-and-replace "FUTURE — Wikipedia" → "PRESENT — `wiki_summary` (126 performers covered)". Add a "data reality" note to §2 calibrating coverage.

**Edit D — simulations-sports §3 (NBA), §4 (NFL), §5 (NHL), §6 (WNBA)**: add per-section a "Data caveat" line. NBA/MLB green; NFL/NHL/WNBA degrade to team/news only.

**Edit E — sports sim WNBA-1 specifically**: rewrite scenario to "Caitlin Clark team-level demand" since athlete-row doesn't exist for WNBA. Caveat clearly.

**Edit F — sports sim cross-cutting §10**: add reference to `major_event_calendar` driving tentpole detection.

---

## 4. What I'm NOT changing

These hold up under data scrutiny:

- **The 6 view templates** (T1-T6 + Pricing Queue + Series/Season/Tour) — all data-supported.
- **The Allocation View** addition (per Julian's many-to-many call) — schema needs the new `inventory_allocation` table (still NEW), unaffected by Supabase findings.
- **The custom-zone overlay** — still NEW; `performer_zones` is geometry but per-user analytical cuts are different.
- **The Event Workbench's chart band** with multi-source overlays — graceful-degrade pattern was already specified; degrades naturally when SD/SG aren't xref'd.
- **The cross-source coverage 4-light badge** — `entity_event_map.sources_count` is the right backing; the data just shows 1-2 lights for 99.9% of events today (which is honest).
- **The Pricing Queue T4 surface** — read-only "suggested ask" + CSV export remains the right v1 (per audit RULE 2: never POST/PUT to TEvo).

---

## 5. New things this exposes

Things I should ADD to the design from the Supabase findings:

1. **`major_event_calendar` integration** — Mega-event mode auto-detects from this 14-row registry rather than ad-hoc flags. Add a "tentpole" badge per event hero.
2. **`wiki_rivalries` (25)** — rivalry premium detection has a curated source. The NHL-4 "Original Six rivalry" sim should query this rather than infer.
3. **`why_signals` (3 rows)** — weather infrastructure is in place but stub data. Reserve a "weather card" slot on outdoor-event hero; degrade gracefully when source is empty.
4. **`zone_metrics` time-series** — never surfaced today. Add a "zone price drift" mini-chart to the Event Workbench zone breakdown drawer.
5. **`section_metrics` historical** — 2M rows. Section premium curves on T3 Venue Pulse should aggregate this over a configurable window (default 30d, expand to 90d for venues with deeper history).
6. **AQ ↔ TEvo xref** — the Pricer-CSV's pricing-rules need to come INTO our DB. Either as a new `aq_zone_pricer` table or as fields on `performer_zones`. Code-side decision.

---

## 6. SeatGeek xref backfill — high-value standalone task

Worth pulling out:
- 186 distinct SG events have orders in our system; 0 are TEvo-xref'd.
- 25 distinct SG events have seller listings; 1 is TEvo-xref'd.
- The xref is a name-matching task (the SG event_name + venue_name + occurs_at can be matched against TEvo events).

Filing this as a code-side suggestion:
- Add to NEXT (code): "SG event xref backfill — match the 186 SG events with orders in our DB to their TEvo equivalents via name+venue+date. Likely matches a substantial chunk of our active book."
- Without this, `unified_orders_by_event WHERE tevo_event_id = X` shows zero SG orders for almost every event in our system. Order-book panels will look empty.

---

## 7. Recommendation for next steps

I see 3 paths:

1. **Apply edits A-F now** (surgical), then proceed to edge-case + UI-element sims doc with calibrated assumptions. ~30 min for edits + the sim doc.

2. **Skip the edits — log them as known calibrations + push forward with the edge-cases doc**, noting the data reality at the top of that doc. Faster but the prior 2 docs stay misaligned with reality.

3. **Fully revise the prior 2 docs** with the new findings woven through. Slowest, cleanest result. Probably overkill for a checkpoint.

I recommend **(1)** — surgical edits + new sim doc — because the sport scenarios specifically need calibration before more downstream work builds on them.

---

## 8. Status

Filed by: design · 2026-05-08
Trigger: Julian's "see what Supabase has" instruction, run before the third sim doc.
12 findings, 6 edits proposed, 1 backfill task surfaced for code.
Awaiting Julian's call on path (1) / (2) / (3).
