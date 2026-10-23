# S4K Market MCP — onboarding (5 minutes)

> **Doc version:** v1.1.0 (2026-10-23) — +`price_forecast` (predicted clearing price per section with a band and the signals behind it) and the "Predict a price" recipe. · v1.0.0 (2026-10-21) — first release of the self-serve external tier (14 tools, per-key limits, freshness on every answer).

Live-event market data for your bot, over the [Model Context Protocol](https://modelcontextprotocol.io): event / performer / venue search, SeatGeek sales pace, price history and zone prices, the daily top-sellers chart, performer trends, multi-source price movers, competing events, prediction markets, sports state, news and weather. Read-only. Every answer tells you how fresh it is.

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
- `demand_context` — chart rank, injuries, attendance, weather.

Omit `section` to get the event's best-selling sections. A forecast with `realized_sample_n: 0` rests on asks and priors only — treat its band as wide. Pair it with `event_market` (sales pace) and `prediction_markets` (game odds) for the full picture.

## 4. Reading the answers

- **Ids.** `event_id` / `tevo_event_id` are TEvo event ids; `performer_id` / `venue_id` likewise. Get them from `search` or `search_events`.
- **Time.** `occurs_at_local` is the venue's local time; fields ending `_utc` are UTC.
- **Freshness.** Tools return `freshness: {as_of, age_hours, stale}` for the rows they used (`stale` = older than 48 h). `data_freshness` lists every feed. Cadences: SeatGeek sales, prediction markets, sports state and news update within minutes; the chart, movers and performer trends are daily; **the TEvo get-in price feed (`event_prices`) has been paused since 2026-09-27 and reports `stale: true`** until it resumes.
- **Prices** are listing/sale prices in USD as published by the marketplace (SeatGeek `broadcast_price` is the seller's price before fees).
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
