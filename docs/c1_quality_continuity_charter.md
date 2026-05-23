# C1 Quality & Continuity Charter

Author: C1. Operator directive 2026-05-17. Expands C1 beyond drift + checkpoint + token-discipline to cover 6 essential duties that had **no owner** — assigned to C1 because each is a **monitor + surface + route** function needing no mutate authority (so it fits a lane that's already read-only-everywhere), and A1/B1 are already saturated.

**Model**: for every duty, C1 **detects and routes**; the **fix/execution** stays with the owning lane. C1 gains zero new write authority on prod. These extend the read-only supervisory role, they don't breach it.

## Duty 1 — Data-quality / semantic validation (silent-failure catcher)

**Gap**: every existing health check is *structural* (did the cron run? schema in sync?). None catch *semantically wrong but running* pipelines. Live precedent: `collect-listings-0-24h` returned `'DO'`, cron-green, while inserting zero rows — caught only by accidental staleness, not by design.

**How** (read-only assertion suite C1 runs in checkpoint; if we want it in `release_health_check`, C1 authors the SQL → A1 applies):
- **Succeeded-but-empty**: crons `status='succeeded'` with zero downstream row delta in-window
- **Coverage floors**: xref/AQ match-rate % under threshold (e.g. `seatgeek_event_xref` coverage of active SG events)
- **Outlier sanity**: prices beyond p99.9 bounds (the $101,998.98 class)
- **Distribution drift**: metric medians shifting >Nσ day-over-day without a volume change
- **Orphan rates**: FK-less rows climbing on cross-source tables

**Cadence**: daily (runbook Step 10). **Surface**: flag to data-owning lane; `severity=high` if a pipeline is silently wrong. **Boundary**: C1 detects; fix is A1 / D2 / owning lane.

## Duty 2 — Cost / burn-rate monitor

**Gap**: TEvo/SeatGeek/SeatData are paid; `listings_snapshots` is 3.6 GB / 8.96M rows and growing; Render + pg_net + edge-fn invocations cost. No holistic owner.

**How** (read-only): `pg_total_relation_size` per table trended weekly; row-growth rates; cron invocation volume (`cron.job_run_details`); paid-API call volume (`*_pull_log` tables); edge-fn invocation counts.

**Cadence**: weekly report `docs/c1-cost-YYYY-WW.md` + daily glance at biggest movers. **Surface**: weekly report + `flag` on anomalous growth. **Boundary**: C1 reports; spend/provisioning decisions are operator / A1.

## Duty 3 — DR / backup posture monitor

**Gap**: migrations carry `rollback` SQL but nobody owns backup existence, restore testing, or rollback speed.

**How**: verify Supabase PITR/backup is enabled + recent (read settings); maintain `docs/disaster_recovery_playbook.md` (restore steps, RTO/RPO targets, who-executes); pre-flight check before any high-blast-radius migration apply.

**Cadence**: weekly + before flagged high-risk applies. **Boundary**: C1 monitors + owns the playbook doc; restore *execution* is A1 / operator.

## Duty 4 — Operator-action queue ledger

**Gap**: a huge amount gates on operator approval (key rotations, apply-gos, vault edits) and items rot silently — Render key `rnd_WPA69…` was flagged 2026-05-15 and is still live days later.

**How**: standing ledger of every operator-pending item, derived from `bot_chat` (entries addressed to Operator / awaiting approval) + a tracked checkpoint section. Each item aged.

**Cadence**: daily (runbook Step 12). **Surface**: escalate items >48h via `flag` `severity=high` (aging sweep slacks it). **Boundary**: C1 tracks + nudges; operator executes.

## Duty 5 — Credential lifecycle monitor

**Gap**: B1 *scans for leaks* (reactive); nobody owns *proactive* rotation/expiry. Symptoms this week: Slack MCP token expired mid-session; Render key un-rotated for days.

**How**: a credential register `docs/credential_lifecycle.md` (name, type, last-rotated, rotation-due/expiry, owner). Flag approaching due dates. Complements B1's secret-scan — tracks lifecycle, doesn't duplicate leak detection.

**Cadence**: weekly + flag on approaching expiry. **Boundary**: C1 tracks + flags; rotation is operator (+ B1 coordination on security-class creds).

## Duty 6 — End-to-end product validation

**Gap**: pytest is per-PR; D0 smoke-tests its own pages. Nobody validates the *whole funnel* as a user experiences it.

**How** (read-only synthetic): hit prod GET endpoints (`/healthz` across services, `/api/store/*`, terminal RPCs via service-role read), assert non-error + sane shape; trace ingest→match→metric→display freshness end-to-end.

**Cadence**: daily (runbook Step 11) + post-deploy. **Surface**: flag breakage to owning FE/data lane. **Boundary**: C1 probes read-only; fixes are lane owners.

## What stays NOT C1's (detect-and-route, not seize-authority)

- Applying any fix or migration → A1 + operator
- Rotating any credential → operator
- Executing a restore → A1 + operator
- Changing spend / provisioning → operator / A1
- Fixing lane code → lane owner

## Cadence summary

| Duty | Daily (checkpoint) | Weekly | Ad-hoc |
|---|---|---|---|
| 1 Data-quality | Step 10 | — | on suspicion |
| 6 E2E validation | Step 11 | — | post-deploy |
| 4 Operator queue | Step 12 | — | >48h escalate |
| 2 Cost | glance | report | growth anomaly |
| 5 Credential | — | report | approaching expiry |
| 3 DR posture | — | check | pre high-risk apply |

## New artifacts C1 will create

- `docs/disaster_recovery_playbook.md` (Duty 3)
- `docs/credential_lifecycle.md` (Duty 5)
- `docs/c1-cost-YYYY-WW.md` (Duty 2, weekly series)
- Runbook Steps 10-12 (Duties 1, 6, 4)

## Ratification

Operator-directed 2026-05-17. Canonical-doc reflections (PROJECT_BIBLE §2, LANE_DISCIPLINE C1, current-state-index) are in this same PR. A1 curates PROJECT_BIBLE per its refresh policy — this PR routes to A1 for the bible edit + ratification; C1-owned docs (this charter, runbook, operating constraints) are in C1's lane.
