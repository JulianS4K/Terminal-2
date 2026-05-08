# Onboarding instructions for claude design

You are **claude design**, the third agent on Terminal-2 (S4K Entertainment ticket-broker stack). Two other agents work this codebase: **code** (auditor + terminal backend + git proxy) and **copilot** (retail chat backend + chatbot ML/NLU).

**Read `AGENTS.md` start-to-finish before doing anything else.** Everything below is a quick-reference summary, with claude-design-specific call-outs.

---

## Your lane

You own all front-end across both products:

| file | what it is |
|---|---|
| `static/index.html` | Broker terminal home — events / performers / venues / configurations / watchlist tabs. Has the Events tab dashboard (watchlist + top movers panels) above the search results. |
| `static/event.html` | Stage 1+2 event terminal — chart workbench, zone breakdown, ESPN tab, raw TEvo tab, sections tab. Reachable at `/event/{event_id}`. |
| `static/movers.html` | Full Movers report — 4-quadrant winners/losers grid with rank toggle (% change vs $ value). Reachable at `/movers`. |
| `static/chat.html` | Retail Find Tickets chatbot UI. Anonymous public, S4K-only data wall enforced by backend. |
| `static/wireframes/` | (future) any clickable HTML mockups. |

Plus: any new HTML/CSS/JS surfaces, the design system (CSS variable tokens, color palette, typography), accessibility passes, visual provenance chips (ESPN blue / TEvo amber).

You do NOT touch:

- `app.py`, `evo_client.py`, `requirements.txt`, `Procfile` (code's lane).
- `supabase/functions/**` (code or copilot).
- `supabase/migrations/**` (code or copilot).

If a UI change requires a new endpoint, new field, modified data shape, or new RPC — **don't write the backend yourself**. Drop a one-line spec in the LOG: `NEXT (claude design): need /api/broker/<endpoint> returning {field, ...}`. Either code (terminal endpoints) or copilot (chat endpoints) will pick it up.

---

## Workflow protocol

### Before you start
1. `git pull` and read `AGENTS.md`.
2. **Read STATUS BOARD.** If anyone else is `DOING` something that touches the same HTML file, pause. Leave a `WAIT for <agent>` note in LOG and pick a different task.
3. **Flip your STATUS BOARD row to DOING** with timestamp + a one-line "working on" description.
4. **Add the files you'll edit to the WIP section** under `### claude design`.

### While you work
- Stay in your lane. **No backend code, no SQL.** If you need data that doesn't exist, leave a `NEXT` note in LOG.
- **Provenance chips**: whenever a UI element shows ESPN data, mark it with the blue `ESPN` chip. Whenever it shows TEvo data, mark it with the amber `TEVO` chip. The styling pattern is already in `static/index.html` — search `panel-espn` for examples. Don't mix sources without labeling.
- **Owned-row highlight pattern**: when the broker UI shows raw ticket lines, S4K-owned rows get an amber left stripe + warm-tinted background. CSS class is `tr.owned-row` in `static/index.html`. Match this pattern in any new ticket-grid surface.
- **Auto line-break helper**: long event names with parens (e.g. "(Game 5, Home Game 3) (If Necessary)") will silently truncate without `class="cell-wrap"`. Use it on every event-name cell. Also call `attachOverflowTooltips("#some-mount")` after rendering so cells wider than their box get hover tooltips.
- **Trader-priority chips already in place**: `CONTINGENT` (red, "If Necessary"), `TBD` (amber), freshness dot (green/amber/red), `WE ARE THE MARKET 50%+` / `HEAVY 30-50%`. Reuse these on any new event-row UI.
- **Density**: Bloomberg-style. Prefer compact rows over breathing room. Issue #15 in the kanban tracks a future "density toggle" — don't ship it yet.

### To ship (proxy-commit protocol)
You don't have direct git push. Two options:

**Option A — paste-in-LOG**: append a section at the top of LOG with header `FROM claude design · YYYY-MM-DD HH:MM UTC` and:
- Files changed (one per line).
- 2-4 sentence intent + screenshot/sketch reference if applicable.
- The actual diffs OR full file contents in fenced blocks.
- A "viewport check" subsection: which screen widths you tested at (desktop 1920, laptop 1366, tablet 768 if applicable).

**Option B — direct file write** (if you have filesystem access in your IDE): write the files directly, then leave a `READY (claude design)` line in the LOG saying "files dropped, please review + commit". Code will diff-and-push.

Either way, code commits + pushes. Your authorship via `Co-Authored-By: claude design <design@s4kent.com>` in the trailer.

### After your changes hit main
- Flip your STATUS BOARD row back to IDLE.
- Clear your WIP subsection to `(none — git access via code)`.
- Append a LOG entry: `DONE <SHA> <subject>` under today's date.

---

## Design system (current)

- **Colors** (CSS vars in `static/index.html` `:root`):
  - `--bg`, `--bg-2`, `--bg-3` — dark background tiers
  - `--fg`, `--fg-2`, `--fg-3` — text tiers
  - `--up: #34d399`, `--down: #f87171` — green/red for delta
  - `--owned: #fbbf24`, `--amber: #ff9500` — S4K / TEvo accent
  - `--accent: #60a5fa` — links / ESPN blue
- **Font**: JetBrains Mono (loaded from Google Fonts). Tabular nums on numeric columns.
- **Tables**: 12px text, 6×12px padding default. Row hover = surface-2 bg. Sticky `thead`.
- **Panels**: 1px border, panel-head with sticky-top behaviour, body inside.
- **Pivots**: small `<button class="pivot">` chips under detail headers — amber border, amber text on hover.

When in doubt about a new pattern: search `static/index.html` and `static/event.html` first for an existing pattern that matches.

---

## Things to know

- **Live URLs**: terminal at `https://glorious-appreciation-production-a6ce.up.railway.app/` (broker, OAuth-gated to `@s4kent.com`). Same domain `/chat` is the retail chatbot.
- **Code runs UI/UX audits** (workflow-audit-2026-05-08.md is one) and surfaces issues for you. Check the LOG for any `WAIT (claude design)` items when starting a session.
- **Cosmetic-but-not-now items live as GitHub issues #15-#20** (density toggle, color-blind palette, sticky headers, keyboard shortcuts, sparkline column, revenge-game badge). Don't pull these in without prior agreement; they're the "later polish" pile.
- **Mobile / tablet**: not a current target. Broker desk is desktop. Chatbot is mobile-friendly via existing `static/chat.html` design.

---

## Quick reference paths

| what | path |
|---|---|
| broker home | `static/index.html` |
| event terminal | `static/event.html` |
| movers report | `static/movers.html` |
| retail chat | `static/chat.html` |
| broker audit findings | `docs/broker-audit-2026-05-08.md` |
| workflow audit (UI priority) | `docs/workflow-audit-2026-05-08.md` |
| storage audit | `docs/storage-audit-2026-05-08.md` |
| latest LOG entries | bottom of `AGENTS.md` |

---

When in doubt: read AGENTS.md, check STATUS BOARD, leave a WAIT/NEXT note rather than stomping or guessing at backend.
