# COWORKER_ONBOARDING.md — Terminal Design Coworker

> **Read this top-to-bottom before touching any file.** This is the contract. Violations cause backend drift and force the audit lane (me, "code") to reject your work.

---

## 1. What you're working on

**Terminal-2** is a sports-ticket broker terminal for S4K Entertainment (NBA, NFL, MLB, NHL, MLS, WNBA, plus major-event single-week stuff like F1/Tennis/Golf). Two products share one backend:

- **Broker terminal** (live URL: `https://terminal-2-production.railway.app/`, Google-OAuth gated to `@s4kent.com`) — full data, all S4K-owned + market depth, served by FastAPI on Railway.
- **Retail chatbot** (same domain, `/chat`) — public, S4K-owned tickets only.

You are working on the **broker terminal frontend**. You do NOT touch the chatbot, the API, or the DB.

**Stack you'll see**:
- Single-file vanilla JS + Chart.js 4.4 in `static/index.html` (~3000 lines). No bundler, no React.
- Backend hands you JSON over Bearer-token auth via `/api/broker/*` routes.
- Styling is CSS variables in `<style>` blocks at the top of `static/index.html`.

**Why no React/build step**: speed + audit simplicity. One file, one diff, no bundle drift.

---

## 2. Your role — frontend only, no push

You design and implement the broker terminal UI: layout, components, charts, search, watchlist, mover panels, event/performer/venue pages.

You **DO NOT**:
- Push to git. Ever. (The audit-and-push lane is owned by **code**, who reviews your diffs first.)
- Write to prod DB tables (`public.*`). Read-only via Supabase MCP for diagnostics is fine.
- Deploy edge functions.
- Schedule or modify pg_cron jobs.
- Edit backend Python (`app.py`, `evo_client.py`).
- Edit SQL migrations or the schema doc.

You **DO**:
- Edit HTML / CSS / JS in the files listed in Section 3.
- Use the `design_test` schema for any sandbox data (NOT `public.*`).
- Drop diffs / file content into `KANBAN.md` under "DOING" with a "FROM design" header so code can pick them up.
- Read `SCHEMA.md` to understand backend data shape before designing.
- Read this file's Section 7 to know what good work looks like.

---

## 3. Ownership — what you can edit

| file / glob                              | who edits     | notes |
|------------------------------------------|---------------|-------|
| `static/index.html`                      | **design**    | broker terminal — your primary canvas |
| `static/event.html`                      | **design**    | legacy event page, may be deprecated; check kanban before touching |
| `static/movers.html`                     | **design**    | full Movers report |
| `static/chat.html`                       | **design**    | retail chatbot UI |
| `static/legacy.html`                     | **design** (frozen) | old terminal kept at `/legacy`; only touch if asked |
| `design/**`                              | **design**    | design notes, mockups, Figma exports |
| `docs/retail-ui-kit.md`                  | **design**    | retail UI kit doc |
| `app.py`, `evo_client.py`, `Procfile`, `requirements.txt` | **code (review only)** | backend; if you need a new endpoint or field, write a `NEXT (design): need <endpoint/field>` entry in `KANBAN.md` |
| `supabase/functions/**`                  | **code**      | edge functions |
| `supabase/migrations/**`                 | **code**      | SQL migrations |
| `SCHEMA.md`                              | **code**      | backend canonical schema lock — read-only for design |
| `AGENTS.md`                              | **code**      | process doc |
| `KANBAN.md`                              | **shared**    | append your own DOING/DONE rows under the design column |
| `COWORKER_ONBOARDING.md` (this file)     | **code**      | read-only |
| `bin/**`, `.github/**`                   | **code**      | infra/CI |

**Rule of thumb**: if it ends in `.html`, `.css`, or is in `design/`, you can edit it. Everything else, ask.

---

## 4. Environment & access

### What you have access to (Supabase MCP)

- **Read** any table in the `public.*` schema. Use it to understand data shape before designing UI.
- **Write** any table in `design_test.*`. Use this for stub/mock data when prototyping.
- **No write** to `public.*` — even if MCP lets you, the rule is strict. Code's audit pass will revert it.

### Test schema setup

```sql
-- Run this once to confirm your sandbox is healthy:
SELECT * FROM design_test._readme;
```

Use `design_test` for:
- Stubbed event_metrics rows when you want to test rendering with synthetic data.
- Feature-flag tables for A/B'ing new layouts.
- Mock data for UI states the real prod data doesn't currently exercise.

### Local dev workflow

You can develop against live prod data — `static/index.html` calls `/api/broker/*` which is open to any browser tab on the deployed Railway URL once you've Google-signed-in.

For local iteration:
```bash
# Terminal 1 — serve the static files locally
cd static && py -3 -m http.server 8080
# Terminal 2 — point your browser at http://localhost:8080/index.html
# But: API calls will fail because there's no FastAPI running.
```

To get full local stack with auth + API, ask code to spin up Railway with a preview branch — DO NOT try to run `app.py` yourself; it requires service-role secrets you don't have.

**Easier**: edit `static/index.html` directly, ping code in `KANBAN.md` to push, then test on the deployed Railway URL. Cycle time ~3 min.

---

## 5. Backend handoff — when you need something new

If your UI needs:
- A new field in an existing endpoint
- A new endpoint
- A new data shape from the API
- A schema column

**DO NOT** add it yourself. Drop a row in `KANBAN.md` under the **NEXT (code)** column with this format:

```
### NEXT (code) — <short title>

**Need**: <what data/endpoint you need>
**Why**: <UI feature it unblocks>
**Shape**: <example JSON or SQL the frontend would consume>
**Deadline**: <if any>
**Filed by**: design · 2026-MM-DD
```

Code reviews, implements, ships. Once the new endpoint is live in prod, code moves the row to **DONE** with the commit SHA. You can then wire your UI to it.

---

## 6. Hand-off pattern — how your work reaches main

You don't push. Here's how your edits land:

1. **You edit** `static/index.html` (or whichever owned file).
2. **You append to KANBAN.md DOING column**:
   ```
   ### DOING (design) — <short title>
   - **What**: <one-line summary>
   - **Files touched**: static/index.html (lines ~XXXX-YYYY)
   - **Status**: ready for review
   - **Started**: 2026-MM-DD HH:MM
   ```
3. **Code reviews** the diff:
   - Runs `py -3 -c "import ast; ast.parse(open('app.py').read())"` (sanity, even though you didn't touch it)
   - Eyeballs the HTML diff for backend coupling, XSS, broken event handlers
   - Checks the Launch preview panel renders cleanly
4. **Code commits** in your name with a `Co-Authored-By: design` trailer:
   ```
   git commit -m "feat(terminal): <your subject>

   Co-Authored-By: design <design@s4kent.local>"
   ```
5. **Code pushes** to `main`. Railway redeploys automatically.
6. **You verify** on the live URL.
7. **Both move the row** to DONE in `KANBAN.md` with the commit SHA.

If code finds a bug, the row goes to **BLOCKED** with the bug reason. You fix and re-submit.

---

## 7. What good work looks like

### Visual quality bar

- **Robinhood / Bloomberg Terminal feel**: dense, monospaced where appropriate, no wasted space, instant feedback on hover/click.
- **Smooth transitions**: range switches fade rather than blank-flash. Hover states are crisp, not draggy.
- **Dark theme is the only theme**. Terminal users don't want light mode.
- **Mobile-responsive is NOT a goal** for the broker terminal. This is a desk tool — assume 1440px+ widescreen.

### Data hygiene

- **Never hardcode data** that should come from the API. If the data isn't in an endpoint yet, file a NEXT (code).
- **Never assume data is non-null**. Backend can return `null` for any metric column. Show "—" or hide the row.
- **Respect the product wall**: broker terminal sees everything (S4K-owned + competitor listings + wholesale). Retail chatbot must NEVER see wholesale, brokerage names, or non-S4K listings. If you ever find yourself rendering wholesale data in `chat.html`, **stop and file a `BLOCKED` row** — that's the wall and breaking it has legal implications.

### Code style

- **Single file**: keep new components inline in `static/index.html`. No bundler.
- **Vanilla JS only**: no React, Vue, jQuery, etc.
- **CSS variables for theming**: `--surface`, `--surface-2`, `--border`, `--text`, `--dim`, `--accent`, `--pos`, `--neg`. Defined at the top of `static/index.html`.
- **No external assets** unless they're already in the codebase. Inline SVGs > external images.
- **Comment sparingly**: explain WHY, not WHAT. Future-you can read the code; future-you can't read your mind.

---

## 8. Common pitfalls

- **Don't break the auth bootstrap** — `/api/public/config` is the first call; it returns Supabase URL + anon key for browser auth init. The Bearer token comes from `supabase.auth.getSession()`. If you see 401s everywhere, the bootstrap is broken.
- **Don't introduce new localStorage keys without a version suffix** — bumping `evt_chart_visible_v3` to `_v4` is the pattern when defaults change. Existing users get fresh defaults on next load.
- **Don't auto-discover series and rename them** — `_autoDiscoverSeries` lets the backend ship new metrics without a frontend deploy. If you rename a backend series, the auto-discover catches it as a new pill labeled `[auto]`. Don't try to "fix" this — it's the feature.
- **Don't add tracking / analytics** — desk tool. Internal use only.
- **Don't add user-input forms that POST to `public.*`** — all writes go through code-owned API endpoints. Frontend forms call `api(...)` which calls `/api/broker/*`.

---

## 9. Where to find things

- **What needs work next**: `KANBAN.md`
- **Backend data shape**: `SCHEMA.md` (don't edit, just read)
- **Process rules**: `AGENTS.md`
- **Past UI decisions**: `docs/broker-audit-2026-05-08.md`, `docs/terminal-data-inventory.md`, `design/main.fig.md`
- **Live URL**: `https://terminal-2-production.railway.app/`
- **Project on Supabase**: `hzrizjeaxlqcxfrtczpq` (Terminal .5)

---

## 10. First-day checklist

1. [ ] Read this file end-to-end.
2. [ ] Read `KANBAN.md` to see what's NEXT (design).
3. [ ] Skim `SCHEMA.md`'s "Active crons" + "Backend API surface" sections so you know what data is available.
4. [ ] Open `static/index.html` and orient yourself. The structure is: CSS variables → header → hero search → 3-tab watchlist → mover panels → footer. Event detail page is rendered by `loadEvent(id)` (~line 880 onward).
5. [ ] Sign in to the live Railway URL with your `@s4kent.com` Google account to see the deployed terminal.
6. [ ] Run `SELECT * FROM design_test._readme;` via Supabase MCP to confirm sandbox access.
7. [ ] Pick the top **NEXT (design)** row from KANBAN, move it to **DOING (design)**, and start.

Welcome aboard. Ask via KANBAN entries — code reads it on every commit cycle.
