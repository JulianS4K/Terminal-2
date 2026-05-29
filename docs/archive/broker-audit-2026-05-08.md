# Broker Audit — 2026-05-08

Posing as a desk reviewing the book end-to-end. Pulled live data via Supabase MCP. Headlines first, mechanics after.

## Headlines

1. **62% of S4K notional is in contingent events.**
   - "If Necessary" / "TBD" bucket: **75 events, $6.7M owned notional, $37.9M market notional**.
   - Confirmed-state bucket: **64 events, $4.1M owned notional, $17.7M market notional**.
   - If the Knicks lose round 1 of the playoffs we wipe ~5 line items at once and re-mark ~50% of the book overnight. **This is the dominant risk on the desk.** Hedging or rotating into confirmed events is the question to ask, not "what's moving today."

2. **Concentration is severe at the top of the book.**
   - Top 5 events = ~**49% of total notional**. Top 10 = ~**71%**.
   - 4 of the top 5 are Knicks-MSG playoff slots, all "If Necessary" or TBD.
   - Knicks alone (top 4 lines) = ~40% of book.
   - Comparable: a single-name equity book where 40% sits in one ticker's near-the-money options. Acceptable if you're long-conviction Knicks, but it's not a diversified market-neutral position.

3. **We ARE the market on 6 events.**
   - 6 of 63 owned-position events: we hold **>50% of the post-parking ticket supply**. Another 15 sit at 20-50%. If we cut, market follows; can't exit at quoted screen prices.
   - These should get an "ownership ≥X%" flag in the UI so the user knows screen price is reflexive when they look at them.

## Audit details

### Freshness (event_metrics)

| bucket | count |
|---|---|
| < 1 hour | 21 |
| < 6 hours | 139 |
| < 24 hours | 290 |
| 24h+ stale | **170 (37%)** |
| 7d+ stale | **81 (18%)** |
| total events | 460 |

Stale events sit alongside fresh ones in Movers and the Performers grid with no visual flag. A 7d-old snapshot's "Δ24h" column is empty but the row still shows up. The stale slice biases the apparent "no movement" baseline.

**Fix shipped:** freshness chip per row (Movers / Watchlist / Events dashboard) — green if < 1h, amber if < 24h, red if 24h+. Stale rows still render but the user sees what they're looking at.

### Fat fingers — none

Zero events with 24h moves > 100%. Data integrity is clean. **No action.**

### Liquidity check

| bucket | count | share |
|---|---|---|
| empty book (0 tix) | 1 | 0.7% |
| thin (< 5 tix) | 3 | 2% |
| light (5–20) | 2 | 1.4% |
| healthy (> 20) | **134** | **96%** |

Markets are deep where we look. **No action.**

### Contingent exposure (the big one)

Bucket by event name pattern:

| bucket | events | owned notional | market notional |
|---|---|---|---|
| `IF_NECESSARY` (contingent) | **75** | **$6,705,410** | $37,930,799 |
| confirmed | 64 | $4,092,903 | $17,651,151 |

**62% of owned notional is conditional.** Movers / dashboard / portfolio aggregates currently treat both buckets identically. A real desk would risk-weight or quote them separately.

**Fix shipped:** any event with "If Necessary" / "TBD" in its name now renders a `CONTINGENT` chip (red-ish) on Movers + Watchlist rows. Easy to scan visually and explicitly clear in the data.

### Concentration: top-10 owned notional

| event | performer | notional | % book |
|---|---|---|---|
| TBD at NYK (R3 G2 If Necessary) | Knicks | $1,258,021 | 11.65% |
| PHI at NYK (G7 If Necessary) | Knicks | $1,084,628 | 10.04% |
| OKC at LAL (G6 If Necessary) | Lakers | $1,064,000 | 9.85% |
| PHI at NYK (G5 If Necessary) | Knicks | $1,015,239 | 9.40% |
| TBD at NYK (R3 G1 If Necessary) | Knicks | $905,643 | 8.39% |
| OKC at LAL (G3) | Lakers | $549,024 | 5.08% |
| OKC at LAL (G4) | Lakers | $529,380 | 4.90% |
| MIN at SAS (G5) | Spurs | $446,573 | 4.14% |
| NYK at PHI (G4 *confirmed*) | 76ers | $430,015 | 3.98% |
| CLE at DET (G5 If Necessary) | Pistons | $388,680 | 3.60% |

**Note:** UI doesn't currently show "% of book" anywhere. Worth adding to the portfolio view as a follow-up — broker view of "where am I sized into" matters more than per-event medians.

### Owned share by event (we vs the market)

| ownership share | events | implication |
|---|---|---|
| > 50% (we ARE the market) | **6** | 9.5% |
| 20–50% (heavy) | 15 | 24% |
| 5–20% (moderate) | 35 | 56% |
| < 5% (thin) | 7 | 11% |
| total events with any owned tix | 63 |  |

**Risk on the > 50% slice:** the screen median is reflexive. If you cut your offer 10%, the market follows. Mark-to-market against your own quote is misleading.

**Suggested follow-up (not yet shipped):** add an `owned_share` column to per-event views and warn (red) when > 30%.

### Signal-quality check (mean-reversion test)

Looked at events with snaps at t−48h, t−24h, and t≈now. For events that moved >5% yesterday (t−48 → t−24), what did they do today?

| group (yesterday) | events | avg Δ today |
|---|---|---|
| yesterday winners (>+5%) | 9 | **−2.42%** |
| yesterday losers (<−5%) | 9 | **−5.70%** |

Both groups drift down today. Winners don't persist; losers keep falling. **The Movers winners list, as currently constructed, is not a continuation signal — it's a snapshot of what already happened.** A trader using it to chase momentum would lose money on average.

This is the kind of finding that argues for a different ranking metric: persistent-mover (events with Δ in same direction over both 24h and 7d), or weighted score that down-weights one-day spikes. **Logged as future work** rather than shipped this turn.

### Stale-collector check

0 events with `occurs_at_local < now() - 24h` are still being polled. **No collector waste.**

## Shipped this turn

1. Auto line-break CSS for long event names + `attachOverflowTooltips` JS helper that adds `title=...` to truncated cells (no more silently lost "(If Necessary)" tails).
2. `CONTINGENT` chip on rows whose event name matches "If Necessary" or "TBD".
3. Freshness chip showing 🟢/🟡/🔴 next to the event name based on `latest_at` age.
4. This audit doc.

## Not shipped yet (open punch list)

- "% of book" column in the portfolio view.
- Owned-share warning when ≥ 30% (we are the market).
- Persistent-mover ranking (Δ same direction 24h AND 7d).
- Risk-weighted notional that discounts contingent events (e.g. multiply by series-survival probability — round 7 If Necessary is closer to 50% than round 4 If Necessary at the same point in series).
- Stale-event hide toggle in Movers / Performers grid (right now they pad the rows).
