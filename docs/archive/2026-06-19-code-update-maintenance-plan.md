# Code-Update & Maintenance Plan — 2026-06-19

> **Status:** non-canonical durable artifact (per `CLAUDE.md §6` / README *Doc-writing rules* — a dated plan lives in `docs/archive/`, not the closed root registry). Living work items graduate to `KANBAN.md §🟢 OPEN WORK`; this file is the snapshot + cadence behind them.
>
> **Scope (operator-selected 2026-06-19):** dependency upgrades · tech-debt / KANBAN backlog · in-flight PR cleanup · CI / security hygiene.
> **Lanes:** A1 (data plane) · B1 (git/code + security) · C1 (docs/coord) · D0–D4 (FE surfaces). Push to `main` per-task; prod-DB apply A1-centralized.

---

## 0. TL;DR — the five highest-leverage moves

1. **Land the 4 dependency PRs in a controlled order** (cryptography #547 → anthropic #545 → fastapi #546 → npm #544), each on green CI. They are lower-bound bumps inside existing pins — low risk, but fastapi pulls Starlette.
2. **Resolve the SEC-HIGH `CRON_SECRET` question (B1-NEXT-11)** — it is the only exploitable-class item open and is *operator-blocked*, not code-blocked. De-hardcode the 5 `collect-listings-*` cron bodies + confirm/rotate the edge-env secret.
3. **Triage the 18 open PRs** — 5 are stale drafts (>1wk), 2 are C1 daily-checkpoint PRs that should close, 2 are exploratory POCs that should be labelled/parked. Cut the in-flight surface roughly in half.
4. **Prune ~21 orphan branches** (C1-OPS-2) — no open PR, merged-or-abandoned; confirm-merged-then-delete.
5. **Settle the Vite 6 → 8 question for `d4_bridge`** — PR #563 (manualChunks fn-form) + dependabot #544 (esbuild/vite/tsx) overlap; decide one target major and do it once.

---

## 1. Dependency upgrades

### 1.1 Policy (unchanged — do not weaken)
`requirements.txt` pins **compatible-release ranges** (`>=known-good,<next-major`). Dependabot may bump the **lower** bound; the **upper** bound is never bumped without a human verifying the major. Mirror this discipline for `d4_bridge` npm.

### 1.2 Python (`requirements.txt`) — current state & open bumps

| Package | Pin | Open PR | Notes / risk |
|---|---|---|---|
| `cryptography` | `>=48.0.0,<49` | **#547** | Security-relevant (Fernet barcode decrypt). Land **first**; clears GHSA-r6ph-v2qm-q3c2 lineage. Lazy-imported → low blast radius. |
| `anthropic` | `>=0.107.1,<1.0` | **#545** | SDK only; no runtime call path on the hot ingest. Low risk. |
| `fastapi` | `>=0.136.3,<0.137` | **#546** | **Pulls Starlette** — the one to watch. Run full `pytest` + a smoke of `/api/*` after. |
| `uvicorn[standard]` | `>=0.49.0,<0.50` | — | current |
| `requests` | `>=2.34.2,<3.0` | — | current |
| `supabase` | `>=2.31.0,<3.0` | — | current |
| `beautifulsoup4` | `>=4.15.0,<5.0` | — | current |
| `defusedxml` | `>=0.7.1,<1.0` | — | current |
| `tzdata` | `>=2026.2,<2027.0` | — | refresh yearly (IANA tz cutover) |

**Order:** #547 → #545 → #546, each merged green before the next (avoid stacking a Starlette change under unrelated diffs).

### 1.3 Node (`d4_bridge/package.json`) — needs a decision

- **#544** (dependabot) bumps `esbuild`, `vite`, `tsx`. Manifest is on `vite ^6.2.0`.
- **#563** adds a `manualChunks` **function form for Vite 8 compat** — implies a Vite 8 target is already in motion.
- **Conflict to resolve:** pick ONE target major for Vite and land #563 + #544 together so the build config and the dep bump agree. Don't merge #544 onto a v6 config if #563 is moving to v8.
- CI already type-checks + Vite-builds `d4_bridge` on every PR (`tests.yml` `typescript` job, Node 20), so a bad bump fails loudly. **Owner: D4, sign-off D0.**

### 1.4 Edge functions (Deno)
No `deno.json` / import-map pinning found under `supabase/functions/`. **Action (B1, low priority):** inventory edge-fn import URLs and pin versions; today they float. Pairs with B1-NEXT-3 (edge-fn auth inventory).

### 1.5 Cadence
- **Weekly:** review/merge open dependabot PRs (CI-green, lower-bound only).
- **Monthly:** scan for new majors; file a verification row in KANBAN before touching any upper bound.
- **Yearly:** `tzdata` refresh; re-baseline lower bounds to current known-good.

---

## 2. In-flight PR cleanup (snapshot from `KANBAN.md §🌿`, re-verify with `list_pull_requests`)

18 open PRs. Recommended dispositions:

| PR | Lane | Disposition |
|---|---|---|
| #570 | C1 | **Merged** (per recent git log #570) — drop from tracker. |
| #568 | A1 | Review + land — `sweep_old_listings` by `captured_at` (retention). |
| #564 | D4/B1 | Land — runs exos migrations + SQL tests on real Postgres (CI value). |
| #563 | D4 | **Tie to §1.3** — land with the Vite-major decision + #544. |
| #562 | B1 | Land — secret-scan allowlist false-positives (unblocks clean scans). |
| #561 | D1 | D0 sign-off → land (seat-map render). |
| #560 | D0 | Review + land (home movers default). |
| #559 | A1/D0 | Review + land (pause non-AXS TD crons; cost). |
| #547/#546/#545/#544 | B1-deps | **§1** — land in order. |
| #543 | D4 | Stale draft — refresh or close (Firebase prune). |
| #536 / #502 | C1 | Daily-checkpoint PRs — **close** (ephemeral; belongs in bot_chat, not a PR). |
| #514 / #495 | explore | POCs — label `exploratory`, park or close; don't let them age silently. |
| #506 | D0/ops | Decide: ship the Render→Actions deploy bridge or close. |
| #505 | A1/D0 | Land — `seating_chart 'null'` poison fix (data quality). |

**Orphan branches (C1-OPS-2):** ~21 `claude/*` + `a1/*` remotes with no open PR. Confirm-merged → delete; keep `release-please--*`, `dependabot/*`, `gh-pages`. One-time prune, then fold into the C1 drift sweep.

**Hygiene rule going forward:** a PR open >7 days with no CI/▶ activity gets a disposition (refresh, convert to draft, or close). No silent aging.

---

## 3. Tech-debt / KANBAN backlog — prioritized

Synthesized from `KANBAN.md §🟢 OPEN WORK`. **Severity order: SEC-HIGH → SEC-MED → SEC-LOW → OPS.** Operator-gated items can't be self-closed — they need a decision.

### 3.1 SEC-HIGH (1) — do first
- **B1-NEXT-11 — leaked/placeholder `CRON_SECRET`.** Operator-blocked. Two-part fix: (a) confirm the edge-env `CRON_SECRET` ≠ the placeholder literal (rotate if it is); (b) de-hardcode the 5 `collect-listings-*` cron bodies so the header isn't the placeholder. Then the history-rewrite-vs-accept call. **Owner: Operator + A1.**

### 3.2 SEC-MED (defense-in-depth) — schedule across the month
- **B1-NEXT-55** — systemic blanket `REVOKE … FROM anon, authenticated` on ~130 latent internal tables (RLS-off regression already fixed). *A1, gated DDL.*
- **B1-NEXT-57** — append `_health_check_anon_exposed_relations()` + pgcrypto regex fix in the next coordinated `release_health_check` migration. *A1 apply-sequencing.*
- **B1-NEXT-58 / -60** — document-or-revoke 3 ESPN anon-read tables; tighten `leads` `USING(true)` → email-claim (likely PII); apply `security_invoker`+email-gate on Tier-3 order/intel views. *D0/D1/D2 + B1.*
- **B1-NEXT-63** — optional hardening: ISO `CHECK` on `events.occurs_at_local` or a `safe_occurs_tz()` wrapper (latent only; 0 live break). *A1.*
- **B1-NEXT-31** — §6 body guard on 7 JWT-gated SECDEF RPCs — **blocked on B1 spec** (literal guard would brick anon/auth PostgREST callers). *Resolve spec first.*
- **B1-NEXT-3 / -5** — edge-fn auth inventory doc; vault-orphan `release_health_check` row.

### 3.3 SEC-LOW (hygiene) — batch quarterly
- **B1-NEXT-10** — rename migration slot collisions (`…300000` ×3, etc.); risk-check applied-state first.
- **B1-NEXT-4** — CodeQL / SAST evaluation decision doc.
- **B1-NEXT-6** — quarterly egress-payload sweep (war-games W-3/W-4).
- **B1-NEXT-62 / -64** — exos scan-attribution snapshot; governance audit-trail row.
- **Operator-only:** B1-NEXT-15/16/17 (branch-protection `enforce_admins`, signatures, SHA-pinning), -18 (Actions secrets), -19/20 (Render ipAllowList / autoDeploy), -21 (Slack MCP).

### 3.4 OPS (data-plane / product) — owner-scheduled
- **A1-OPS-22** — `aq_event_map` dup consolidation: safe-class sweep **built, dry-run**, awaiting operator apply (235 clusters; 19 conflicting-sg cases handled per-case, never blind-merged).
- **A1-OPS-21** — SG non-owned poller re-enable decision + listings retention halve drain.
- **A1-OPS-24** — social-pulse → why_signals → alerts (exploring, operator-gated).
- **A1-OPS-25** — AXS checkout/order-substitution automation **PARKED** (operator-gated, §2 security-CRIT).
- **C1-OPS-1 / -2** — workflow-skills rollout backlog; 4-domain reorg follow-ups (own-bible CI wiring, drift sweep, orphan-branch prune).
- **D0-PROD-8** — Trip Planner refinement backlog.

---

## 4. CI / security hygiene — recurring sweeps

### 4.1 Existing gates (keep green; don't weaken)
`.github/workflows/`: `tests.yml` (pytest + RULE-2 static audit + D4 tsc/Vite build + warn-only mypy) · `docs-registry-check.yml` · `forbidden-paths-check.yml` · `secret-scan.yml` · `dependency-review.yml` · `scorecard.yml` · `sync-check.yml` · `uptime-check.yml` · `pr-title-lint.yml` · `labeler.yml` · `release-please.yml`. Plus repo guards: `scripts/check_readonly.py` (RULE-2 static), `tests/test_readonly_guards.py` (RULE-2 runtime), `bin/check-docs.sh`, `bin/sync-check.sh`, `bin/graph-drift.mjs`.

### 4.2 Recurring-sweep calendar

| Cadence | Sweep | Owner | Reference |
|---|---|---|---|
| Hourly | bot_chat aging sweep (`:00` global, `:15` B1, `:45` D2) | each lane | `CLAUDE.md §5` |
| Per-PR | RULE-2 static+runtime, docs gate, forbidden-paths, secret-scan, dep-review, tests | CI | `tests.yml` |
| Weekly | Dependabot merge pass; PR-aging disposition (>7d) | B1 | §1.5 / §2 |
| Monthly | New-major scan; RLS/grants spot-check; graph-drift fold-in (`graph-drift.mjs`) | B1/C1 | §1.5 / `PROJECT_BIBLE §8` |
| Quarterly | §4 RPC-table drift (next ~2026-09); egress sweep (W-3/W-4); SAST decision; migration-slot cleanup | B1 | B1-NEXT-24/-6/-4/-10 |
| Yearly | `tzdata` refresh; lower-bound re-baseline; secret rotation review | A1/B1 | §1.5 |

### 4.3 Gaps to close
- **mypy is warn-only** (`continue-on-error: true`). Track type-debt down, then flip to blocking. *B1.*
- **Edge-fn deps unpinned** (§1.4). *B1.*
- **No CodeQL/SAST** — B1-NEXT-4 decision pending.
- **Branch protection soft** (enforce_admins / signatures / SHA-pinning off) — operator-gated B1-NEXT-15/16/17.

---

## 5. Execution sequence (suggested 2-week arc)

1. **Day 1–2:** Land dep PRs in order (§1.2) + settle Vite major (§1.3). Close C1 checkpoint PRs #536/#502; label POCs #514/#495.
2. **Day 3–4:** B1-NEXT-11 with operator (the only SEC-HIGH). Land #562 (secret-scan allowlist) to keep scans clean.
3. **Day 5–7:** Orphan-branch prune (C1-OPS-2); PR-aging disposition pass on remaining drafts.
4. **Week 2:** SEC-MED batch (B1-NEXT-55/57/58/60) as coordinated A1 migrations; operator applies A1-OPS-22 dry-run → execute.
5. **Ongoing:** adopt the §4.2 calendar; first quarterly drift pass due ~2026-09.

---

*Owner of this artifact: whichever lane drives the sweep. Update the live rows in `KANBAN.md`; this file is the dated snapshot, not the ledger.*
