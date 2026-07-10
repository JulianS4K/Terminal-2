# Code storage blueprint — Terminal-2 (2026-07-10)

> **Non-canonical, dated archive artifact** (per `CLAUDE.md §6`). Operator-requested:
> *"we need a storage blueprint for code"* — the target-state map of **how the code is
> stored and organized** across repos, processes, and deploy targets as the lanes
> decompose. Companion to the earlier verdict `docs/archive/2026-06-19-d-tier-split-analysis.md`
> ("don't split the monorepo now") and the tracking rows `BR-CODE-1` / `BR-SPLIT-1` /
> `BR-SPLIT-2` in `KANBAN.md`. Ownership authority remains `PROJECT_BIBLE §2`; this file is
> the **storage layout + decomposition sequence**, not a new ownership source.

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
- 🟡 **D2 (orders dashboard)** — own FastAPI app (`d2_dashboard/main.py`) + own service
  definition, but currently mounted into the shell. Un-mount = standalone.
- 🟡 **D0 / D1 / D5** — clean router modules sharing one process. Un-mount needs a per-surface
  web service, not a code change.

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

| Surface | Router module | Static tree | Service IaC | Deploy-separable | Repo-separable |
|---|---|---|---|---|---|
| **D0** terminal + orders dash | `routers/broker.py`, `routers/d0_sales.py`, `d2_dashboard/` | `static/terminal/`, `d2_dashboard/` | `render-d0-terminal.yaml`, `render-d2-dashboard.yaml` | ✅ ready | after Tier-0 client/`core` shim |
| **D1** store | `routers/store.py` | `static/store/` | (shares `render.yaml` shell) | ✅ ready | after Tier-0 shim |
| **D5** fantasy | `/fantasy/*` block in `routers/pages.py` | `static/fantasy/` | (shares `render.yaml` shell) | 🟡 needs its block split from `pages.py` first | later |

> **Note:** D0/D1/D5 repo extraction is bounded by Tier 0 — a product repo would still need to
> import the shared `core/` + `*_client.py`, so a split here means publishing that substrate as
> an installable library or git submodule. That cost is why deploy-separation, not repo-separation,
> is the Tier-1 target.

### Tier 2 — Isolated product — **repo-extractable today**
| Surface | Stored units | Status |
|---|---|---|
| **D4** Bridge/Exos | `d4_bridge/`, `static/bridge/`, `supabase/functions/exos-*`, `exos_*` schema | Own build + edge fns + value-only DB link. The one surface that can become its own repo with near-zero risk — the PoC for the whole split model. |

---

## 4. Decomposition sequence (storage moves, in order)

Deploy first, repo last. Each step is independently valuable and reversible until the last.

1. **Un-mount D2 dashboard from the shell.** Stop `include_router`'ing `d2_dashboard.main`
   into `server.py` (`server.py:1743`); run it on its own `d2-orders-dashboard` service
   (`uvicorn d2_dashboard.main:app` — the service + IaC already exist). Smallest real
   deploy-separation, zero new infra. *(Lowest risk — the standalone app already exists.)*
2. **Give D0 terminal + D1 store their own web services.** Two `render-*.yaml` web services,
   each starting `server:app` but with a surface-scoped router set (or a thin per-surface
   entrypoint that mounts only its routers). A D1 deploy can then never take down D0 —
   **this captures the bulk of the isolation value a git split would buy.**
3. **Split the D5 `/fantasy/*` block out of `routers/pages.py`** into `routers/fantasy.py`
   so fantasy is a first-class module (it is the one Tier-1 surface still sharing a router
   file). Then it can move to its own service like D0/D1.
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
