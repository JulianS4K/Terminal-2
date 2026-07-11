# Code storage blueprint — Terminal-2 (2026-07-10)

> **Non-canonical, dated archive artifact** (per `CLAUDE.md §6`). Operator-requested:
> *"we need a storage blueprint for code"* — the target-state map of **how the code is
> stored and organized** across repos, processes, and deploy targets as the lanes
> decompose. Companion to the earlier verdict `docs/archive/2026-06-19-d-tier-split-analysis.md`
> ("don't split the monorepo now") and the tracking rows `BR-CODE-1` / `BR-SPLIT-1` /
> `BR-SPLIT-2` in `KANBAN.md`. Ownership authority remains `PROJECT_BIBLE §2`; this file is
> the **storage layout + decomposition sequence**, not a new ownership source.
>
> **Corrected 2026-07-10 (operator):** two lane-topology facts drive this doc and had been
> mis-stated in the first draft — (1) **D2 was merged INTO D0** (2026-07-02, `§2.3`): the
> orders dashboard is a D0 sub-surface to **consolidate**, not a surface to split onto its own
> service; (2) **fantasy is D5**, a distinct product spun OUT of the terminal, hosted on the
> shared **D0-owned** storefront shell (**surface ≠ service**, `§2.7`). The two are mirror
> images — one folded in, one split out — and the sections below now reflect that.

## TL;DR

**One monorepo, with a shared substrate core that never splits, product surfaces stored as
already-separated modules, and _deploy_ isolation — not _repo_ isolation — as the primary
decomposition axis.** The code seam that a git split would need already exists (`routers/*`
+ `core/*`); the remaining coupling is a single **runtime process**, not a single repo.
Decompose the process first (per-surface Render services); a git split is an optional,
D4-first downstream step, never the first move.

---

## 1. Storage principles (what decides where code lives)

1. **Storage follows the shared-substrate boundary, not the org chart.** Anything that is
   physically one thing at runtime — one Postgres DB, one migration history, one set of
   upstream clients — is stored **once**, in the monorepo core, and can never be split out
   without fragmenting that single thing. (`PROJECT_BIBLE §2.3` "platform substrate".)
2. **A product surface is stored as a module long before it is stored as a repo.** The
   `routers/<surface>.py` + `static/<surface>/` + `render-<surface>.yaml` triple *is* the
   storage unit. Repo extraction is a packaging step applied to an already-clean module,
   not a way to create the module.
3. **Deploy isolation delivers ~all the blast-radius protection a git split would.** The
   contamination we care about ("a D1 edit breaks D0") is a same-process failure. Separate
   processes fix it; separate repos do not (a split repo that still ships one `server:app`
   keeps the coupling and adds submodule overhead).
4. **One fact, one home** (`CLAUDE.md §6`) applies to code too: shared helpers live in
   `core/`, imported one-directionally (`server.py`/`routers/*`/`*_client.py` → `core`,
   never reverse). No product surface re-stores a shared helper.

---

## 2. Current storage topology (as-is, 2026-07-10)

**Repos:** two today — this monorepo (`julians4k/terminal-2`) + a separate `Terminal-2-ui`
repo for human coworker UI work (the human-contamination boundary is *already* a git split;
see CODEOWNERS + `forbidden-paths-check.yml`).

**Processes / deploy targets:**

| Target | Kind | Serves today | Storage backing |
|---|---|---|---|
| `vibepass-storefront-test` | Python web (`uvicorn server:app`) | **D0 API + D1 store + D5 fantasy + home**, and **D2 dashboard** (dynamically `include_router`'d, `server.py:1743`) | `server.py` + all 21 `routers/*` + 24 `core/*` |
| `vibepass-terminal-test` | Static CDN | `static/*` (terminal + store + undelivered + home) | `render-d0-terminal.yaml`, `publishPath: static` |
| `d2-orders-dashboard` | Python web (idle placeholder) | nothing live — can run `uvicorn d2_dashboard.main:app` standalone | `d2_dashboard/`, `render-d2-dashboard.yaml` |

**The coupling in one sentence:** the code seam is clean (D0/D1/D5/D2 are each their own
router module), but **all of them are mounted into one `server:app` process and one deploy**
— so the isolation is code-level only, not runtime-level.

**Isolation status by surface:**

- ✅ **D4 (Bridge)** — fully isolated already: standalone npm/TS app in `d4_bridge/`, own
  `vite` build → `static/bridge/`, own `exos-*` edge functions, `firestore.rules`, and
  **value-only** DB links (`bridge_event_xref`, never writes D0 tables). Extraction-ready today.
- 🟢 **Orders dashboard (part of D0, ex-D2)** — the D2 lane was **merged into D0** on
  2026-07-02 (`§2.3`); `d2_dashboard/*` is now a D0 sub-surface and its historical
  `d2-orders-dashboard` service is a D0-owned **idle placeholder**. It is *not* a surface to
  split out — the correct move is to **consolidate it into D0** (keep it same-origin with the
  terminal, retire the idle service). See §4 step 1.
- 🟡 **D0 / D1 / D5** — clean router modules sharing the one storefront-shell process.
  **Surface ≠ service** (`§2.7`): D1 store and D5 fantasy are distinct product *surfaces*
  hosted on the **D0-owned** `vibepass-storefront-test` shell, not services of their own.
  Runtime isolation here is a deploy decision, not a code change — the modules are already
  clean.

---

## 3. Target storage topology (to-be)

Three storage tiers. The tier decides *whether* a surface can ever be stored separately.

### Tier 0 — Shared substrate — **stored once, never split**
The single-instance foundation. A repo split here fragments something that is physically one
thing and is therefore forbidden by principle 1.

| Stored unit | Path | Why it can't split |
|---|---|---|
| DB schema + data + crons | `supabase/migrations/*` | one Postgres, one linear migration history (`MIGRATION_CONVENTIONS.md`) |
| Edge functions (non-Exos) | `supabase/functions/*` (minus `exos-*`) | share `_shared/`, the same DB, the same cron-auth |
| Upstream read-only clients | 10 `*_client.py` | GET-only-by-construction guard is single-sourced (`core/readonly_guard`); shared by D0+D1 |
| Shared runtime | `core/*` (24 modules) | imported by every surface; one-directional import rule |
| CI / guards / release | `.github/*`, `bin/*`, `scripts/*` | one build, one gate set (B1 / Auditor surface) |
| Canonical docs + coordination | the `*.md` registry, `bot_chat` | closed doc set (`CLAUDE.md §6`) |
| Cross-surface FE assets | `static/_shared/`, `static/shared/` | design tokens + retail-chat widget consumed by all surfaces (§2.6 seams) |

### Tier 1 — Product surfaces — **stored as separable modules; deploy-separable now, repo-separable later**
Each is a clean module today. The near-term win is giving each its **own process/service**;
repo extraction stays optional and downstream.

| Surface | Router module | Static tree | Deploy today (surface ≠ service, `§2.7`) | Repo-separable |
|---|---|---|---|---|
| **D0** terminal | `routers/broker.py`, `routers/d0_sales.py` | `static/terminal/` | API on `vibepass-storefront-test`; static on `vibepass-terminal-test` (both D0-owned) | after Tier-0 client/`core` shim |
| **D0** orders dashboard *(ex-D2, merged in 2026-07-02)* | `d2_dashboard/` (mounted) | `d2_dashboard/` | mounted in the D0 shell; **consolidate here + retire the idle `d2-orders-dashboard` service** — do NOT re-split | with D0 |
| **D1** store | `routers/store.py` | `static/store/` | tenant of the D0-owned `vibepass-storefront-test` shell | after Tier-0 shim |
| **D5** fantasy *(distinct product, spun out of terminal)* | `/fantasy/*` block in `routers/pages.py` | `static/fantasy/` | tenant of the D0-owned `vibepass-storefront-test` shell | after Tier-0 shim |

> **Note 1 — surface ≠ service.** Owning a *surface* (its routes + static tree) is separate
> from owning the *service* it deploys on (`§2.7`). D1 and D5 own their surfaces but are hosted
> on D0's storefront shell; D0 owns three services. So "deploy isolation" here means deciding
> which surfaces share a service, not mechanically one-service-per-surface.
> **Note 2 — repo extraction** is bounded by Tier 0: a product repo would still import the
> shared `core/` + `*_client.py`, so a split means publishing that substrate as a library or
> submodule. That cost is why deploy-separation, not repo-separation, is the Tier-1 target.

### Tier 2 — Isolated product — **repo-extractable today**
| Surface | Stored units | Status |
|---|---|---|
| **D4** Bridge/Exos | `d4_bridge/`, `static/bridge/`, `supabase/functions/exos-*`, `exos_*` schema | Own build + edge fns + value-only DB link. The one surface that can become its own repo with near-zero risk — the PoC for the whole split model. |

---

## 4. Decomposition sequence (storage moves, in order)

Deploy first, repo last. Each step is independently valuable and reversible until the last.

1. **Consolidate the orders dashboard *into* D0 (do NOT re-split it).** Because D2 merged into
   D0, the target is one D0 deploy serving the terminal + orders dashboard **same-origin** —
   the idle standalone `d2-orders-dashboard` service is **retired**, not revived. Concretely:
   fold `d2_dashboard/main.py`'s `/api/d2/*` routes into D0's `routers/` package (e.g.
   `routers/d0_orders.py`) so the dashboard is a first-class D0 module rather than a bolt-on
   sub-app `include_router`'d at runtime, then drop `render-d2-dashboard.yaml`. The terminal
   Orders tab (`static/terminal/orders.js`) **stays same-origin — no cross-origin repoint, no
   CSP widening.** A `D2_MOUNT_IN_SHELL` env gate already exists in `server.py` (default
   mounted) to toggle the mount during the move; its end state is *"mounted in D0's own service
   alongside the terminal,"* not *"served by a separate d2 service."* *(This reverses the first
   draft, which mistakenly pointed the dashboard at its own service — that re-creates the D2/D0
   split the merge dissolved.)*
2. **Decide D0's service boundary (surface ≠ service).** The near-term isolation win is giving
   the **D0 API** its own web service instead of sharing the `vibepass-storefront-test` shell
   with D1 + D5. That is a *deploy* decision about which surfaces co-tenant, not a code change:
   D1 store and D5 fantasy are D0-shell tenants today and can stay so, or move — a D1/D5 deploy
   taking down D0 is the risk to remove. **This captures the bulk of the isolation value a git
   split would buy.**
3. **Make D5 fantasy a first-class module.** Split the `/fantasy/*` block out of
   `routers/pages.py` into `routers/fantasy.py` so the D5 product surface is a clean module
   (it is the one product still sharing a router file). It remains a tenant of the D0 shell
   unless/until step 2 moves it — surface ≠ service.
4. **(Optional PoC) Extract D4 (Bridge) as a standalone repo.** Already isolated → near-zero
   risk; validates the git-split model end-to-end (own CI, own deploy, value-only DB link)
   before anyone touches D0/D1.
5. **(Only if still warranted) Product repo splits for D0/D1/D5** — requires first publishing
   Tier-0 `core/` + `*_client.py` as a shared library/submodule (see §3 Tier-1 note). For a
   small bot-operated team, **monorepo-with-enforced-boundaries beats polyrepo**; do this only
   if independent deploy (step 2) proves insufficient.

---

## 5. Enforcement — how the layout stays true

Storage boundaries rot without a machine watching them. The gates already in place:

- **`surface-boundary-check.yml`** — warns when a PR spans >1 exclusive product surface or
  touches a §2.6 shared seam (`BR-SPLIT-2`; currently non-blocking — flip `HARD_FAIL=1` to
  gate once the branch-prefix→lane convention is confirmed).
- **`forbidden-paths-check.yml`** + `CODEOWNERS` — hard-fail on a non-owner touching protected
  backend paths (the human-contamination git boundary).
- **`§2.5` no-orphan invariant** — every top-level path resolves to exactly one owning lane;
  a new top-level path must be assigned in the PR that adds it.
- **One-directional import rule** — `server.py`/`routers/*`/`*_client.py` → `core`, never the
  reverse. This is what keeps Tier 0 extractable-in-principle and Tier 1 modules clean.

---

## 6. Bottom line

The code is **already stored for decomposition**: substrate in `core/` + `supabase/`, each
product in its own router/static/IaC module, D4 fully isolated. What is *not* yet decomposed is
the **runtime** — one process serving everything. The storage blueprint's single directive:
**separate the processes (Tier 1, steps 1–3) before separating the repos (steps 4–5), and never
separate Tier 0 at all.**
