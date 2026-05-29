# Workflow Audit — Trader View — 2026-05-08

A trader's-eye sweep of the broker terminal: what info hits the screen first, what comes later, where current UI matches the workflow vs where it forces clicks/scrolls. Done same day as the data audit.

## Trader workflow (as the user articulated it)

Ranked by immediate decision impact:

1. **Trades & injury news** — biggest immediate ticket-price impact. A starting QB ruled out 4 hours before kickoff is a 30%-50% drop. Must surface FIRST.
2. **Win/loss records & team standings** — predicts upcoming sales. A 13-2 team with home-court secured prices very different from a 7-8 team out of contention.
3. **Next opponent + rivalries** — including former-team angle for traded players (Player X faces former team → narrative-driven price spikes). Cross-references injuries to named players.
4. **Other ESPN context** — division leaders, playoff seeds, gambling lines, attendance trends.
5. **Zone-level metrics** — pricing is done at zone level (Floor / Lower 100s / Upper 300s), not per-listing. Per-zone median is the unit of decision.
6. **Raw ticket data** — only on deep-dive. Default sort: **zone → qty → row → section, all descending** (per user). **S4K-owned rows highlighted** so user can compare what we have vs the rest of the market at a glance.

## Current state vs ideal

### Inline event detail (clicked from the home page Events tab)

| trader priority | current state | gap |
|---|---|---|
| 1. Injury / trade alerts | ❌ Not shown | **biggest gap** |
| 2. Standings + record | ❌ Not shown | (data exists in espn_team_snapshots) |
| 3. Next opponent + rivalry | ❌ Not shown | (data exists in espn_event_snapshots + opponents list on performer) |
| 4. Other ESPN context | ❌ Not shown | |
| 5. Zone metrics | ❌ Not shown inline | (exists on /event/{id} Stage 1 page but not the legacy inline detail) |
| 6. Raw ticket data | ✅ Shown | sort wrong (price ASC, not user's spec); owned rows not highlighted |

### `/event/{id}` Stage 1+2 page

| trader priority | current state | gap |
|---|---|---|
| 1. Injury / trade alerts | 🟡 Visible as overlay markers on chart, ESPN tab has full list | not surfaced as standalone alerts panel |
| 2. Standings + record | ✅ ESPN tab shows record + last-5 strip | |
| 3. Next opponent + rivalry | 🟡 Last-5 visible, but no explicit "next opponent" callout for the event being viewed | |
| 4. Other ESPN context | ✅ ESPN tab | |
| 5. Zone metrics | ✅ Zone breakdown table on overview pane | |
| 6. Raw ticket data | ✅ Raw TEvo tab | sort + owned highlight not yet applied |

### Performer detail (clicked from Performers tab)

| trader priority | current state | gap |
|---|---|---|
| 1. Injury / trade alerts | ✅ ESPN block injuries list at top | trades/transactions not separated from generic news |
| 2. Standings + record | ✅ Stat cards in ESPN block | |
| 3. Next opponent + rivalry | 🟡 Opponents list (now clickable) | no "next game" callout, no rivalry weighting |
| 4. Other ESPN context | ✅ Last-5 + news | |
| 5. Zone metrics | ❌ Not aggregated at performer level | (would need new RPC: zone medians across performer's events) |
| 6. Raw ticket data | ❌ Inside each event's detail | this is correct — performer view shouldn't dump raw lines |

## Shipped this turn

1. **ESPN alerts panel** at the TOP of inline event detail. Shows:
   - Active injuries for both home + away teams (red `OUT` / amber `Q` / etc.)
   - Recent transactions / news flagged with `TRANSACTION` chip when type matches
   - Standings line: home record (W-L), away record, last-5 strip
2. **Raw ticket groups re-sorted** (inline detail) to user spec: **zone → qty → row → section, all descending**. Sort indicator + headers clickable to re-sort.
3. **S4K-owned rows** in raw ticket groups now have amber left border + light amber tint background so the eye finds them instantly. New "owned" column in the raw table.

## Kanban'd (not shipped this turn — opened as GitHub issues)

Cosmetic / polish items I noticed but deferred per user's "kanban any of your cosmetic suggestions for now":

- Compact density mode (rows are 30px high — Bloomberg desks usually run 22-24px for more lines per screen)
- Color-blind palette toggle (current red/green deltas are problem for ~8% of male users)
- Sticky table headers in the inline event detail panel (they scroll out of view on long ticket lists)
- Keyboard shortcuts (`/` to focus search, `j`/`k` to navigate rows, `enter` to drill in)
- Sparkline column in zone breakdown showing 24h price tape per zone
- "Trade fingerprint" badge: when a player from team X joined team Y in the last 30 days, label the corresponding upcoming X@Y or Y@X events (revenge-game flag)

## Open from broker audit (still on the list)

- "% of book" column in portfolio view
- Owned-share warning when ≥ 30% (we ARE the market on that event)
- Persistent-mover ranking (Δ same direction over 24h AND 7d)
- Risk-weighted notional discounting contingents by series-survival probability
- Stale-event hide toggle in Movers / Performers grid
