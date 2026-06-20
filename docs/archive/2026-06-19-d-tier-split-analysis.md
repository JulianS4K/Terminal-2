# D-tier git-split analysis — Terminal-2 (2026-06-19)

> **Non-canonical, dated archive artifact** (per `CLAUDE.md §6`). Operator-requested exploration: *"do we need to split the git for the D-level projects to avoid cross-contamination of wiring?"* The actionable follow-ups live in `KANBAN.md §🟢 OPEN WORK → 🔴 URGENT` (rows `BR-CODE-1` + `BR-SPLIT-1`); this file is the evidence + reasoning.

## Verdict

**No — do not split the monorepo now, and not as the first move.** The cross-contamination of wiring is a **code/runtime coupling** problem (one `app.py`, one process), **not a git problem**. A repo boundary doesn't remove code coupling — it can cement it. The git/ownership boundaries a split would buy you **already exist**. Decouple the code first; a git split (if ever) is a cheap downstream consequence, not a substitute.

## Evidence

### Git-level boundaries already exist — and a partial split is already in place
- `.github/CODEOWNERS` — `*` → `@JulianS4K`; backend paths (`app.py`, `*_client.py`, `supabase/`, `tests/`, `.github/`) explicitly owner-gated.
- `.github/workflows/forbidden-paths-check.yml` — CI gate that **fails any PR** where a non-owner author touches the protected backend paths.
- **Coworker UI work already lives in a SEPARATE `Terminal-2-ui` repo** (stated in CODEOWNERS + the forbidden-paths workflow). The human-contamination boundary is *already* a git split.
- Plus `.github/labeler.yml` path→area mapping (`area:terminal-fe`/`storefront`/`dashboard`/`bridge`/`backend`), branch-prefix lane labels, and the CLAUDE.md/BOT_HIERARCHY lane governance + doc-registry gate.

### The actual wiring contamination is one file + one process
- **D0 (terminal) + D1 (store) routes are interleaved in the single 8,753-LOC `app.py`**, sharing `client`, `sb`, `require_auth`, the middleware stack (`_SecurityHeadersMiddleware`, `_RateLimitMiddleware`, CORS), module globals, and **one deploy** (`Procfile`: `uvicorn app:app`). A D1 edit can break D0 — same file, same process. **This is the contamination.**
- **D2 (dashboard)** is its own `FastAPI` app (`d2_dashboard/main.py`) but is `app.include_router(d2_router)`'d into the monolith at runtime (`app.py:8813`) → shares the process / middleware / deploy. It does **not** import root clients (self-contained otherwise).
- **D4 (Bridge)** is already cleanly isolated: standalone npm app (`d4_bridge/package.json`), own `vite` build → `static/bridge/`, own `exos-*` edge functions, value-only DB links (`bridge_event_xref`, never writes D0 tables). The one surface that is **not** cross-contaminated.

### Shared substrate a git split cannot separate
One Supabase DB (A1-centralized migrations in `supabase/migrations/`), shared `*_client.py` upstream clients (D0+D1), shared `static/_shared/design-tokens.css` + `static/shared/retail-chat-widget.js`, shared bibles/governance.

## Why git-split-first is the wrong lever
1. **The seam doesn't exist yet.** D0 and D1 are physically the same file — you cannot cleanly git-split them until `app.py` is decomposed.
2. **A repo boundary ≠ a runtime boundary.** Split repos but still ship one `app:app` that imports D2 = versioning/submodule overhead with the coupling intact.
3. **The "who can touch what" boundary already exists** (CODEOWNERS + forbidden-paths + lane governance) — that's the part a split would buy, and it's already enforced.

## Recommended sequence (decouple code first; split git last, if ever)
1. **`BR-CODE-1` — decompose `app.py`** into per-surface router packages (`routers/terminal`, `routers/store`, shared `core/` for auth+db+clients). *Creates the seam that doesn't exist today*; de-risked by the BR-CODE-3 route-test net (31 tests as of 2026-06-19).
2. **Per-surface Render services** (already roadmapped as "migrate-back-at-beta" / the Phase-4 service-merge checkpoint, `KANBAN NEXT (D0 — checkpoint)`). Independent deploys → a D1 deploy can't take down D0. **Delivers ~all the isolation value without a git split.**
3. **Then, only if still warranted, a git split is trivial** because clean seams exist. Readiness order: **D4** (extractable today, near-zero effort) → **D2** (already standalone FastAPI) → D0/D1 (after `app.py` is decomposed).
4. **Polyrepo caveat:** a full split fragments the shared DB/migrations, the shared clients, and the bible/governance set — each repo then needs its own CI gates + a shared-client library/submodule. For a small bot-operated team, **monorepo-with-enforced-boundaries beats polyrepo**; the high-value isolation (independent deploy + CI) is reachable without splitting.

## Near-term option
If a concrete proof-of-concept is wanted: **extract D4 (Bridge) as a standalone repo** — it is already isolated (own npm app + build + edge functions + value-only DB links), so the split is near-zero-risk and validates the seam model before touching D0/D1. Tracked as `BR-SPLIT-1` (scoped, not started — needs operator go-ahead).
