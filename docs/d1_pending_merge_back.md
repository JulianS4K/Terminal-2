# D1 — Pending merge-back work [ARCHIVED 2026-05-16]

> **🎯 STATUS: ARCHIVED — all parked items have either landed or been superseded.** This file is kept as a historical record of the MVP-stabilization period (2026-05-13). For current D1 work, see:
> - `docs/d1_retail_finish_punchlist.md` — active sprint roadmap (sections A-J)
> - `docs/d1_operating_constraints.md` — current scope + post-reorg posture
> - `docs/d1-render-perf-2026-05-15.md` — Render plan-bump perf baseline
>
> **Status of items originally captured here:**
> - PR #76 (Sprint 1.5 UX batch on `claude/store-sql-only-demo-mode`): superseded — the 7 UX fixes were either re-implemented or rolled into PR #84 + later D1 work
> - PR #77 (D1 operating constraints doc): landed as `docs/d1_operating_constraints.md`
> - PR #79 (MVP catalog TEvo-direct): landed as PR #84 consolidated bundle
> - render.yaml healthCheckPath: `/healthz` change landed via PR #117 + subsequent edits
> - bot_chat row 68 (B1 RULE 2 carve-out for Sprint 2): still applicable — Sprint 2 remains FROZEN per the operator directive in `docs/d1_retail_finish_punchlist.md §B`. The architectural review request stays valid; no code change needed until Sprint 2 thaws
> - Sprint 4a/5 sketches: superseded by the punchlist roadmap (sections F+G)
>
> Historical context below is preserved unchanged.

---

Filed 2026-05-13 alongside PR #79 (MVP catalog TEvo-direct). Render is being repointed to `claude/d1-mvp-tevo-direct` for MVP review. Work captured here is parked on **other branches** and needs to come back when MVP shape is locked.

## PR #76 — Sprint 1.5 UX batch (parked)

Branch: `claude/store-sql-only-demo-mode`
Commit: `a8f44d2` — `ux(store): Sprint 1.5 polish — 7 audit findings landed`
Deploy status when parked: `update_failed` (deploy `dep-d81tu7ek1jcs73eml4n0`, 2026-05-13 02:35 UTC).

### What's in the commit

7 UX fixes from the static audit. Net diff: +167 / -18 across `static/store/store.js` and `static/store/style.css`. No Python touched, no `app.py` overlap with PR #79.

| # | Where | Fix |
|---|---|---|
| 1 | `store.js:401-404` + `index.html:53` | Catalog load error: replaces stuck red text with inline **Retry** button. `loadCatalog()` factored out so Retry re-fires `/api/store/events` without page reload. |
| 2 | `store.js:447-455` + `style.css:add suggest-status.error` | Search dropdown error tone: `.suggest-status.error` variant uses `--bad` color + ⚠ glyph so "Search unavailable" is visually distinct from "Searching…". |
| 3 | `store.js:1432-1433` + event.html | Missing seating chart: hide `<img>` + inject `.map-placeholder` div so 2-col event-body grid keeps its left column footprint. Without this, listings reflowed into the empty space at the 760px breakpoint. |
| 4 | `event.html:115` + `store.js:906-985` | Parking tab `aria-label="Parking, N listings"` so screen readers announce the count. `.listing-tab[aria-disabled="true"]` rule added defensively. |
| 5 | `store.js:1245-1251` | Filter apply failure: `applyFiltersAndFetch`'s catch now surfaces inline `.filter-error` pill in the filter bar (was silent `console.error`). Pill auto-clears on next successful apply. |
| 6 | `style.css:1125-1134` + `event.html:73-78` | Parking tab count: `white-space: nowrap` + `font-size: 10px` so "Parking 12" doesn't wrap on narrow viewports. |
| 8 | `index.html:15` + `event.html:15` + `style.css` | Under 760px, hide the "MVP · browse only · no real purchases" text and show just "MVP" via `font-size: 0` + `::before { content: "MVP" }` pattern. Topbar stays uncrowded on mobile without changing desktop copy. |

Audit item #7 (Reserve button `:disabled`) was **skipped during the original commit** — audit had misidentified scope; the global `.btn:disabled` rule at `style.css:562` already covered row buttons.

### Why the deploy failed

`render.yaml:32` sets `healthCheckPath: /`. The storefront landing page route is heavier than `/healthz` (90KB JS + CSS). On Render free-tier cold-start dyno, the healthcheck on `/` timed out before the server settled. Build succeeded, server detected port 10000, but Render flagged `update_failed` after 18 minutes of retries. The previous successful deploy (`268cae3`) stayed live, so the user-facing site was never down — it just didn't pick up the Sprint 1.5 fixes.

### Recommended re-merge sequence

1. Merge PR #79 (MVP catalog) to `main` after operator review.
2. Cherry-pick `a8f44d2` (Sprint 1.5) onto a new branch off `main`. No conflicts expected — `app.py` vs JS/CSS, fully orthogonal.
3. **Before triggering deploy**, patch `render.yaml`:
   ```diff
   - healthCheckPath: /
   + healthCheckPath: /healthz
   ```
   `/healthz` is sub-50ms warm and doesn't load static assets — won't time out on cold dyno boot.
4. Open PR for the Sprint 1.5 cherry-pick + healthcheck path swap. Single PR keeps the deploy-fix coupled to the cherry-pick that triggered the failure.
5. After merge, the next deploy from `main` should ship Sprint 1.5 + the healthcheck fix.
6. Smoke after deploy: `/healthz` 200; `/store` renders the Retry button on simulated catalog 500; MVP badge shrinks to "MVP" under 760px viewport.

### Open question to reconcile during merge-back

The Sprint 1.5 #1 fix wires Retry to `/api/store/events`. Post-MVP that endpoint is TEvo-direct. The Retry button still works (same path, same failure modes), so no code change needed — but worth confirming the error message in the catch ("Couldn't load events:") still reads naturally if TEvo returns a 502 instead of Supabase.

## bot_chat row 68 — B1 RULE 2 carve-out (still pending B1)

Architectural review request for Sprint 2 (real purchase path). Filed 2026-05-13. B1 hasn't responded. This is a *future* work item — Sprint 2 is frozen until:
- All front-end sprints (1, 1.5, 3, 4a) shipped
- TEvo merchant-of-record onboarding confirmed
- B1 sign-off on `evo_orders_client.py` sibling-module shape

No action needed during MVP review; just remember it exists when Sprint 2 thaws.

## PR #77 — D1 operating constraints doc

Branch: `claude/d1-operating-constraints`. Self-contract doc, no code. Filed for A1 review same day. Independent of MVP / Sprint 1.5 — merge whenever convenient.

## Sprint 4a / Sprint 5 sketches (plan-only)

From `~/.claude/plans/smooth-coalescing-garden.md`:
- **Sprint 4a**: OG tags + Twitter card + JSON-LD `Organization`/`Event` on `/store` and `/store/event/:id`. Favicon waits on operator asset.
- **Sprint 5**: `Cache-Control: public, max-age=300` on `/static/store/*`, footer with copyright + `git rev-parse --short HEAD` version line, terser minification of `store.js`.

These haven't been started. Both are independent of MVP shape; revisit after MVP is locked.

## Render deploy state at parking time

| Field | Value |
|---|---|
| Service | `vibepass-storefront-test` (`srv-d8140bnaqgkc73al4asg`) |
| Source branch (at parking time) | `claude/store-sql-only-demo-mode` |
| Last successful deploy | `dep-d81qk0osfn5c738slgrg` @ commit `268cae3` (status: `live`) |
| Last failed deploy | `dep-d81tu7ek1jcs73eml4n0` @ commit `a8f44d2` (Sprint 1.5) |
| `healthCheckPath` in render.yaml | `/` — change to `/healthz` next merge |
| Free-tier behavior | sleeps after 15min idle, ~50s cold start to `/healthz`, <1s warm |

## TL;DR for the merge-back operator

1. Merge PR #79 → main.
2. Cherry-pick `a8f44d2` onto a branch off main.
3. Change `render.yaml` line 32: `healthCheckPath: /` → `/healthz`.
4. PR + merge that.
5. Repoint Render service from `claude/d1-mvp-tevo-direct` (MVP testing branch) back to `main`.
6. Smoke. Retire `claude/store-sql-only-demo-mode` and `claude/d1-mvp-tevo-direct` once green.
