# main.fig.md — Design source of truth

> Markdown stand-in for a Figma file. Mirror what would be in Figma here so anyone reading the repo (any of the 3 agents, future contributors) gets the design system without needing Figma access.

> **Maintained by**: claude design.
> **Last updated**: 2026-05-08 (initial scaffold by code).

---

## Figma source

_(claude design: when you have a real Figma file, paste the public/share link here. Until then this doc is the truth.)_

- **Figma URL**: _none yet_
- **Last synced from Figma**: _n/a_

---

## Products covered

| product | live URL | static file | status |
|---|---|---|---|
| Broker terminal — home | `https://glorious-appreciation-production-a6ce.up.railway.app/` | `static/index.html` | ✅ live |
| Broker terminal — event page | `https://.../event/{event_id}` | `static/event.html` | ✅ live (Stage 1 + 2 metric workbench) |
| Broker terminal — movers report | `https://.../movers` | `static/movers.html` | ✅ live (% change + $ value modes) |
| Retail Find Tickets chatbot | `https://.../chat` | `static/chat.html` | ✅ live |
| Retail landing / leads page | _none yet_ | _t.b.d._ | 🟡 backend ready (mig 20260508023000), UI pending |

---

## Design system (current)

Extracted from `static/index.html` `:root`. When new tokens are added, update both there and here.

### Colors

| token | hex | usage |
|---|---|---|
| `--bg` | `#0a0c0f` | page background, deepest |
| `--bg-2` | `#11151c` | header/strip backgrounds |
| `--bg-3` | `#1a2029` | inset borders, divider tone |
| `--surface` | `#121519` | primary panel background |
| `--surface-2` | `#181c22` | hover state, sub-panels |
| `--border` | `#232830` | default border |
| `--border-hi` | `#2e343d` | emphasized border |
| `--text` | `#dfe3e8` | body text |
| `--dim` | `#6b737d` | secondary text, labels |
| `--dimmer` | `#464c54` | tertiary, disabled |
| `--amber` | `#ff9500` | S4K accent · TEvo provenance · primary CTA |
| `--amber-dim` | `#b66a00` | hover-pre, button border |
| `--up` | `#34d399` | green / positive delta / fresh-data dot |
| `--down` | `#f87171` | red / negative delta / contingent / out-status / stale dot |
| `--owned` | `#fbbf24` | owned-row left stripe |
| `--accent` | `#60a5fa` | hyperlinks · ESPN provenance |

### Typography

- **Body**: `JetBrains Mono` (Google Fonts), 12px / line-height 1.45.
- **Numbers**: `font-variant-numeric: tabular-nums` for alignment in tables.
- **Headings**: 14px, weight 500, amber.
- **Labels** (`<label>` for form fields): 11px uppercase, letter-spacing 0.08em, `--dim`.

### Surface chrome

- **Panel**: 1px `--border`, sticky `<thead>`, panel-head with subtle bg.
- **TEvo blocks**: amber `TEVO` chip in the header (`background:#3a2a10;color:var(--amber)`).
- **ESPN blocks**: blue `ESPN` chip (`background:#1e3a5f;color:#93c5fd`), blue accent border, dark-blue header strip.
- **Owned rows**: amber left stripe (2px `--amber`) + warm-tinted bg (`rgba(255,149,0,0.05)`) + amber price cell.

### Chips & badges

| chip | bg | fg | when |
|---|---|---|---|
| `CONTINGENT` | `#3a1010` | `#fca5a5` | event name matches "If Necessary" |
| `TBD` | `#332512` | `#fcd34d` | event name has "TBD" token |
| `WE ARE THE MARKET 50%+` | `#3a1010` | `#fca5a5` | `cur_owned_share >= 0.50` |
| `HEAVY 30-50%` | `#332512` | `#fcd34d` | `cur_owned_share` in `[0.30, 0.50)` |
| `S4K` | `#3a2a10` | `--amber` | row is S4K-owned in raw ticket-group tables |
| Freshness `●` | dynamic | green/amber/red | based on `latest_at` age (<1h / <24h / >24h) |

---

## Layout patterns

### Broker home (`static/index.html`)
- Topbar: brand · nav (📈 movers, 💬 retail chat) · db status · clock.
- Tabs: events, performers, venues, configurations, watchlist.
- Events tab: search form + Watchlist panel + Top Movers panel (both hide on manual search, restore on clear).
- Detail view: header + ESPN alerts (top, blue chrome) + zone breakdown + raw TEvo (re-sorted: zone ↓ qty ↓ row ↓ section ↓, S4K rows highlighted).

### Event terminal (`static/event.html`)
- Three-panel: chart pane (top, full width) + side detail pane.
- Chart workbench: `+ ADD METRIC` button opens grouped picker. Active metrics rendered as removable pills. Per-injury markers as severity-colored vertical lines with hover tooltip.
- Tabs: zones / sections / ESPN / raw TEvo.

### Movers (`static/movers.html`)
- 4-quadrant grid: owned-winners · owned-losers · market-winners · market-losers.
- Toggles: window (6h / 24h / 3d / 7d) · level (events / performers / venues) · segment (both / owned / market) · rank (% change / $ value).

### Retail chat (`static/chat.html`)
- Mobile-first single-column.
- Chat history scroll + suggestion chips above input.
- Manual express-lane: Performer dropdown + Date dropdown below the chat input (backed by `search_performers_for_chat` + `search_events_by_date` RPCs).

---

## Wireframes (claude design fills in)

> When you sketch new layouts, drop them here as ASCII wireframes or link to PNG/SVG exports in `design/exports/`.

_Empty — no pending design work this turn (cleanup mode per user direction)._

---

## Open UI questions for the desk

1. Mobile / tablet for broker terminal — current target is desktop only. Stay there?
2. Density toggle (#15 in kanban) — when do we ship?
3. Color-blind palette toggle (#16) — when do we ship?
4. Retail landing page (mig 20260508023000 added the leads backend) — claude design + copilot need to align on what the landing flow looks like before any HTML lands.

---

## Update log

| date | by | change |
|---|---|---|
| 2026-05-08 | code | initial scaffold (extracted current design system from `static/index.html` `:root`) |
