# S4K Market MCP — onboarding (5 minutes)

> **Doc version:** v1.4.0 (2026-10-27) — +`seat_map`: the venue's seat map coloured by sold (or asking) price per section, returned as an SVG and a self-contained HTML page to show as an artifact (§3e). · v1.3.1 (2026-10-27) — `price_forecast` adds team form (`form_mult` from both teams' win/loss records) and caps every prior at 2× the live ask; `game_context` answers live (records, form, players out, buzz, win odds) with the feature store as a second layer; `zone_prices` flags `thin` zones; `team_report` drops injury notes not seen in 7 days. · v1.3.0 (2026-10-27) — +5 market-depth tools: `event_sales` (every SeatGeek sale, now for every game we poll), `zone_prices` (live market by seating zone with 24 h change), `zone_trend` (daily zone history), `game_context` (records, betting line, injuries, buzz, rivalry, TV, weather, primary vs resale for one game), `model_price_prediction` (learned per-zone price model, Knicks home games); `query_public_view` gains `zone_metrics`, `zone_price_observations`, `v_ml_knicks_price_latest`; new §3d recipes. · v1.2.0 (2026-10-23) — +`team_report` (a team's live TEvo/SeatGeek/GoTickets inventory, trends, ESPN, Reddit, Kalshi, roster and weather in one call), +`get_started` and the `s4k://onboarding` resource / `get_started` prompt served on connect; `price_forecast` now returns `confidence` + `warning` and anchors a no-sales estimate to the live market. · v1.1.0 (2026-10-23) — +`price_forecast` (predicted clearing price per section with a band and the signals behind it) and the "Predict a price" recipe. · v1.0.0 (2026-10-21) — first release of the self-serve external tier (14 tools, per-key limits, freshness on every answer).

Live-event market data for your bot, over the [Model Context Protocol](https://modelcontextprotocol.io): event / performer / venue search, every SeatGeek sale and the sales pace, the market by seating zone (live and daily), price history, two price predictors, the daily top-sellers chart, performer trends, multi-source price movers, competing events, per-game demand context (records, betting line, injuries, news buzz, weather), prediction markets, sports state and news. Read-only. Every answer tells you how fresh it is.

This file is served at `/developers/docs.md` on the host you got your key from, so an agent can read it directly.

## 1. Get a key (1 minute)

1. Open `/developers` on the host and **Sign in with Google**.
2. Click **Create key**. Copy it now — it is shown once and stored only as a hash.
3. Free tier: **60 requests/minute, 2,000/day**, up to 500 rows per query. One live key per account; creating a new key retires the previous one.

Endpoint: `https://<host>/mcp` · transport: Streamable HTTP (stateless JSON) · auth: `Authorization: Bearer <key>` (or `X-API-Key: <key>`).

## 2. Connect (1 minute)

**Claude Code**
```bash
claude mcp add --transport http s4k-market https://<host>/mcp \
  --header "Authorization: Bearer YOUR_KEY"
```

**Claude Desktop / Cursor / Windsurf / any JSON-configured client** — add to the client's MCP config:
```json
{
  "mcpServers": {
    "s4k-market": {
      "url": "https://<host>/mcp",
      "headers": { "Authorization": "Bearer YOUR_KEY" }
    }
  }
}
```

**ChatGPT (custom connector / Agents SDK)** — add a remote MCP server with the URL above and the `Authorization` header.

**Python (official `mcp` client, 2.x)**
```python
import asyncio, httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

async def main():
    async with httpx.AsyncClient(headers={"Authorization": "Bearer YOUR_KEY"}) as http:
        async with streamable_http_client("https://<host>/mcp", http_client=http) as (read, write):
            async with ClientSession(read, write) as s:
                await s.initialize()
                hit = await s.call_tool("search", {"query": "Lakers"})
                print(hit.content[0].text)

asyncio.run(main())
```
(On `mcp` 1.x the import is `streamablehttp_client(url, headers=...)` and it yields `(read, write, _)`.)

**Plain HTTP (JSON-RPC)** — no client library needed:
```bash
curl -s https://<host>/mcp \
  -H "Authorization: Bearer YOUR_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"Lakers"}}}'
```
List tools with `{"method":"tools/list"}`.

## 3. First three calls (2 minutes)

On connect the server's instructions tell your assistant to call **`get_started`** first; clients that show MCP resources and prompts also list this guide as `s4k://onboarding` and a `get_started` prompt.

```text
search(query="Lakers")                       → performer ids, venue ids, upcoming event ids (TEvo ids)
event_market(event_id=3226757, days=30)      → the event + SeatGeek sales per day + competing events
data_freshness()                             → every feed's as-of time, age and cadence
```
Then branch out:

```text
top_market_events(limit=25)                  → today's top-selling chart with rank moves
price_movers(window_days=30, direction="up", source="seatgeek")
performer_trend(performer_id=51427, days=90)
event_prices(event_id=3226757)               → get-in history, zones, weather, 24 h direction
price_forecast(event_id=3226757)             → predicted clearing price for the best-selling sections
team_report(team="New York Knicks")          → a team's whole market + context in one call (§3c)
event_sales(event_id=…, section="226")      → every sale: time, price, qty, section, row + summary (§3d)
zone_prices(event_id=…)                      → live asks by seating zone, change vs 24 h ago (§3d)
zone_trend(event_id=…, zone="Lower Center")  → that zone's daily history
game_context(event_id=…)                     → records, line, injuries, buzz, rivalry, TV, weather
model_price_prediction(event_id=…)           → learned per-zone price with p10–p90 (Knicks home games)
seat_map(event_id=…)                         → the venue map coloured by price per section — an HTML artifact (§3e)
prediction_markets(event_id=…) | (performer_id=…) | (league="NFL")
sports_context(league="nfl")   news(league="NFL")   event_weather(event_id=…)
query_public_view(view="sg_market_chart", filters=[{"column":"rank","op":"lte","value":10}])
```

## 3b. Predict a price (the common question)

Ask your assistant in plain words, for example:

```text
What will section 226 at Cardinals at Cowboys on Nov 1 clear at, and should I list above or below that?
```

With this server connected, the assistant calls `search` to get the event id, then `price_forecast(event_id, section="226")`, and answers from:

- `expected_clearing` — the predicted sale price per ticket (USD, before fees).
- `lo` / `hi` — the calibrated range; most sales land inside it.
- `price_heading_24h` and `over_ask_spike_prob_pct` — where asks are heading and the chance of a sale above ask.
- `signals` — what the number is built from, each with its weight: recent sales in that section (`realized_sale`, with `realized_sample_n`), current asks × the category's sold-to-ask ratio, section and opponent history.
- `demand_context` — chart rank, injuries, attendance, weather, both teams' records; `form_mult` — the team-form factor (home win% weighted 0.30, opponent 0.15, shrunk by games played so the first weeks barely move it, capped ±15 %).
- Priors (section, opponent, away-team draw, history) are capped at 2× the live ask, so a stale prior can't push the number above the market.

Omit `section` to get the event's best-selling sections (or, when it has no recent sales, the sections with the most tickets listed). Every forecast carries `confidence` (`high` ≥ 8 realized sales used, `medium` ≥ 3, else `low`). With no realized sales the model leans on priors; if that lands above every current ask, `expected_clearing` is re-anchored to the live ask × sold-to-ask ratio, the raw number moves to `model_estimate`, and a `warning` says so. Pair it with `event_market` (sales pace) and `prediction_markets` (game odds) for the full picture.

## 3c. A team in one call

```text
team_report(team="New York Knicks")                        # or the TEvo performer id, "16303"
team_report(team="16303", since="2026-10-01", max_games=5, home_only=false)
```

Per upcoming game (home games by default): `evo_now` / `sg_now` (get-in, median, p25–p75, tickets on TEvo and SeatGeek), `gt_seen_24h` (GoTickets), `sg_sales_30d`, `trend_daily` (one point per day since `since`), `kalshi` (win odds), `weather` and `data_quality` (`live` = captured in the last 6 h, `stale`, `none`). For the team: `standing`, `recent_results` (with the spread), `roster`, `injuries`, `transactions`, `player_value` (ticket-price lift when a player plays), `espn_news`, `reddit`, `kalshi_futures`, `team_market_daily` and `sales_daily`. `since` defaults to when we started polling the team's games. Everything is processed metrics — never raw listings — and `data_notes` lists any gap (no Reddit posts, games without a recent capture). Follow with `price_forecast(event_id)` for a price.

## 3d. Market depth — sales, zones, context, the learned model

```text
event_sales(event_id=3465633, days=14, section="floor", min_quantity=2, limit=100)
zone_prices(event_id=3465633)
zone_trend(event_id=3465633, zone="Upper Corner", days=30)
game_context(event_id=3465633)                     # or capture_date="2026-10-25" for an earlier day
model_price_prediction()                           # all upcoming Knicks home games
```

- **`event_sales`** — individual SeatGeek sales (all sellers), newest first, with `summary` (sales, tickets, min / p25 / median / p75 / max). Every game we poll gets its sales pulled daily, every 6 h in the last 48 h and once after the game, so recent and final sales are both there. `price` is the seller's price per ticket before fees.
- **`zone_prices`** — the current market per seating zone (zones with fewer than 10 tickets on TEvo are flagged `thin: true` — on game day most are; read `event_sales` for what actually sold) (curated per venue where we have a seat map, else lower / club / upper / floor): tickets, listings, sections, get-in, p25–p90 asks, plus `getin_change_24h_pct`, `median_change_24h_pct` and `tickets_change_24h`. A shrinking ticket count with a rising get-in is a zone selling through.
- **`zone_trend`** — one row per zone per day from the nightly feature store: tickets, get-in, p25 / median / p75 and the day-over-day move (`vel_tickets_sold`, `vel_getin_delta_pct`, `vel_median_delta_pct`).
- **`game_context`** — what drives demand for that game. `live`: both teams' records, streaks and seeds, players out per side, Reddit / X buzz, attendance rank, weather alert; `form_mult` (the team-form factor `price_forecast` applies); `win_odds` from Kalshi / Polymarket. `feature_store` (nightly): spread, total, moneylines, star player and injury status, rivalry, national TV, box-office vs resale floor, holiday, competing events — `freshness.feature_store` says how old it is, and `data_notes` says when a game has no ESPN link yet.
- **`model_price_prediction`** — a model trained daily on every catalogued sale predicts what a pair in each zone sells for now, with a p10–p90 band. `run.metrics` reports its held-out error next to two baselines (the zone's median ask, the zone's historical median), so you can see how much to trust it. Today it covers New York Knicks home games; `price_forecast` covers every event per section.

## 3e. The seat map (an artifact)

```text
seat_map(event_id=3465617)                       # median SeatGeek sale per section, last 30 days
seat_map(event_id=3465617, metric="ask")         # median asking price per section right now (TEvo)
seat_map(event_id=3465617, days=7)
```

Returns three MCP content blocks:

1. **JSON summary** — `legend` (five price bands, cheap → expensive), `sections` (each priced section with its median and the sales or tickets behind it), `sections_on_map` / `sections_priced`, `sections_unplaced` (marketplace section names we could not place on the drawing), `freshness`.
2. **`image/svg+xml`** (`s4k://seatmap/<event>/<metric>.svg`) — the venue's own seat map with every section filled by its price band (grey = no data) and a hover title per section ("Middle Level Sideline 225: $259 median sale (6 sales)").
3. **`text/html`** (`s4k://seatmap/<event>/<metric>.html`) — a self-contained page: the coloured map, the legend and a section table; light and dark mode. **Show this one to the user as an artifact** (Claude: render it as an HTML artifact; other clients: save and open it).

Sections are matched through our marketplace-section → map crosswalk for the event's venue configuration, falling back to the section number. Sections with a single sale are coloured like the rest — check the sales count in the table before reading much into one.

## 4. Reading the answers

- **Ids.** `event_id` / `tevo_event_id` are TEvo event ids; `performer_id` / `venue_id` likewise. Get them from `search` or `search_events`.
- **Time.** `occurs_at_local` is the venue's local time; fields ending `_utc` are UTC.
- **Freshness.** Tools return `freshness: {as_of, age_hours, stale}` for the rows they used (`stale` = older than 48 h). `data_freshness` lists every feed. Cadences: SeatGeek sales, prediction markets, sports state and news update within minutes; zone captures follow each game's polling cadence (minutes near the event, daily far out); the chart, movers, performer trends, `zone_trend` / `game_context` (feature store) and the learned model are daily; **the TEvo get-in price feed (`event_prices`) has been paused since 2026-09-27 and reports `stale: true`** until it resumes.
- **Prices** are listing/sale prices in USD as published by the marketplace (SeatGeek `broadcast_price` is the seller's price before fees).
- **Zones vs sections.** `price_forecast` and `event_sales` work per marketplace section ("226"); `zone_prices`, `zone_trend` and `model_price_prediction` per seating zone (a group of sections). Zone names come from `zone_prices`.
- **Prediction markets** give implied probability 0..1 (`yes_price`) from Kalshi / Polymarket, linked to our events and teams.

## 5. Limits and errors

| HTTP | body | meaning |
|---|---|---|
| 401 | `{"error":"missing or invalid API key"}` | no / revoked key — mint one at `/developers` |
| 429 | `{"error":"rate limited","retry_after_seconds":60}` | over 60 req/min — back off |
| 429 | `{"error":"daily quota exhausted","resets_at":"00:00 UTC"}` | over 2,000/day |
| 200 + `isError: true` | tool-level error, e.g. `{"error":"event 5 not found"}` | fix the arguments |

`query_public_view` with an unknown view returns the full list of views and columns instead of failing.

## 6. What you will never get here

Our own inventory, orders, customers or wholesale prices. The external tier's column lists are explicit; the catalog at `/api/mcp/catalog` shows exactly what each view exposes.

## 7. Rules

Public market data from public sources; information, not advice — check `freshness` before acting on a number. Keys are personal; rotate by creating a new one. Need higher limits or a feed that isn't here? Email the address on `/developers` with what you're building.
