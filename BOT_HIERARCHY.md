# BOT_HIERARCHY.md

**Quick-reference chart for who-does-what and who-can-push-where.**
**Reorg 2026-05-28 — new mandate split, D1-E1 paused until D0 is working.**

---

## 1. Hierarchy at a glance

```
                     ┌──────────────────────────────────────┐
                     │               A1                     │  ops + infra
                     │  SQL Monitor / DB Ops / Git / Connectors │
                     │  (sole prod pusher)                  │
                     └──────────────┬───────────────────────┘
                                    │ security audits →
                                    ▼
                     ┌──────────────────────────────────────┐
                     │               B1                     │  security + governance
                     │  Security + Bibles / Git / Bot Notes │
                     └──────────────┬───────────────────────┘
                                    │ D-tier coordination →
                                    ▼
                     ┌──────────────────────────────────────┐
                     │               C1                     │  project coordinator
                     │  D0-D4 Monitor + Code Drift Prevention │
                     └──────────────┬───────────────────────┘
                                    │ primary product surface ↓
                                    ▼
                     ┌──────────────────────────────────────┐
                     │               D0  ← PRIORITY         │  user visual layer
                     │  Terminal FE — visual of A1 for user │
                     │  All data flows here. Build this first│
                     └──────────────────────────────────────┘

     ┌──────────────────────────────────────────────────────────┐
     │  D1 · D2 · D3 · D4 · E1  ─── PAUSED until D0 working   │
     └──────────────────────────────────────────────────────────┘
```

---

## 2. Lane roster

| Lane | Role | Mandate (2026-05-28) | Status |
|---|---|---|---|
| **A1** | SQL Monitor / DB Ops | Monitor + fix SQL; Supabase alerts; all data sources (TEvo/SG/TD/etc.); crons; tables; git + syncs; Jira/Asana + connector health. Sole prod pusher. | **ACTIVE** |
| **B1** | Security + Governance | Security (RLS, SECDEF, CRIT patches); monitor Jira/Asana, git, bibles (governance docs), other bot notes/changelogs. | **ACTIVE** |
| **C1** | D-tier Project Coordinator | Monitor + assist D0-D4 related projects and docs; prevent code drift; daily checkpoint cadence. | **ACTIVE** |
| **D0** | Terminal FE — User Visual Layer | Primary user interface for project progress. Visual representation of everything A1 monitors. All data flows through D0. Build this first — D1-E1 paused until D0 is working. Render workspace-wide perms parity with A1. | **ACTIVE — PRIORITY** |
| **D1** | Consumer Retail | Storefront (`static/store/*`, `/api/store/*`). Reports to D0. | **PAUSED** |
| **D2** | Order Clients | 5 order-client SDKs + dashboard. Reports to D0. | **PAUSED** |
| **D3** | Broadway Scraper (sub-D2) | `broadway_client.py`, `broadway_*` tables + crons. | **PAUSED** |
| **D4** | Our Ticketing Infra | Exos schema live (phases 1–5), zero data. BLOCKED: RESEND + Stripe creds. | **PAUSED** |
| **E1** | Integration / Automation | Zapier, WhatsApp/Telegram ops, Slack alerts, webhooks. (Rebrand from Kalshi placeholder.) | **PAUSED** |

---

## 3. Bot mandates in detail

### A1 — SQL Monitor / DB Ops / Git / Connectors
- **Monitor**: Supabase alerts, cron job_run_details (failures/timeouts), table sizes + growth rates, data source freshness (TEvo/SG/TD pipelines), `v_sg_broker_429_health`, `bot_chat` unresolved flags
- **Fix**: broken crons, SQL errors, migration drift, function overload/ambiguity (§3 landmines)
- **Git**: sync `main` ↔ prod; sole pusher to `main`; PR review per `MIGRATION_CONVENTIONS.md §9`
- **Connectors**: monitor Jira/Asana task status, escalate stale items to operator
- **Author + apply**: all foundation + ops migrations; ESPN/FRED ingest; event_xref; sweep functions; cron schedules

### B1 — Security + Governance Monitor
- **Security**: RLS coverage, SECURITY DEFINER audit, CRIT/HIGH patches, anon-exposure harness
- **Governance**: monitor bibles (PROJECT_BIBLE, LANE_DISCIPLINE, BOT_HIERARCHY, AGENTS.md) for drift vs actual state; flag discrepancies
- **Git**: review security-sensitive PRs; monitor repo for secret leaks, insecure patterns
- **Bot notes**: read + audit `bot_chat` aging items; flag stale unresolved threads to A1
- **Jira/Asana**: track security + governance tickets; surface blockers to A1

### C1 — D-tier Project Coordinator + Code Drift Prevention
- **Monitor D0-D4**: track open PRs, task progress, bot_chat items addressed to D-tier bots
- **Docs**: keep D-tier design docs, wireframes, runbooks current with actual implementation
- **Code drift**: daily checkpoint — compare prod vs repo migrations; surface drift to A1
- **Assist**: unblock D-tier bots on cross-lane coordination questions; route to A1/B1 as needed
- **NO** connector integrations (moved to E1 when E1 activates)
- **NO** PR management authority (that's D0's lane)

### D0 — Terminal FE — User Visual Layer (PRIORITY)
**Mission: be the user's single window into project health and trading intelligence.**

D0 renders two kinds of surfaces:
1. **Ops health** — visual of everything A1 monitors: cron status, 429 rates, table freshness, bot_chat feed, data source pipeline status, sync state. User sees at a glance if infra is healthy.
2. **Trading intelligence** — event detail pages, movers index, discovery gaps, performer/venue pages with all multi-source data (EVO/SG/TD).

When D0 is "working" = operator can open the terminal and immediately see:
- Whether all pipelines are running (cron health dashboard)
- Whether 429 rates are in budget
- Which data sources are fresh vs stale
- Recent bot_chat activity
- And navigate to any event/mover/discovery surface with live data

**Render**: workspace-wide permissions parity with A1. Full write authority on all services.

### D1–E1 — PAUSED
All paused until D0 is working. No new work in these lanes. Existing code stays deployed but no new PRs.

---

## 4. Push restrictions matrix

| | Prod DB (Supabase) | Prod git (`main`) | Render workspace | Edge functions | Vault / secrets |
|---|---|---|---|---|---|
| **A1** | ✅ via MCP | ✅ sole merger | ✅ workspace-wide | ✅ deploy | ✅ rotate/set |
| **B1** | ✅ CRIT security only | ✅ sec PRs only | ❌ | ✅ sec only | ✅ |
| **C1** | ❌ (author files only; A1 applies) | ❌ (A1 merges) | ❌ | ❌ | ❌ |
| **D0** | ❌ (author files only; A1 applies) | ❌ (A1 merges) | ✅ **workspace-wide parity with A1** | ❌ | ❌ |
| **D1–D4, E1** | ❌ (PAUSED) | ❌ (PAUSED) | ❌ (PAUSED) | ❌ | ❌ |

**Hard rules (immutable, per CLAUDE.md):**
- A1 is sole pusher to `main`
- B1's prod-DB write is CRIT security only — no routine ops

**D0 Render note (2026-05-16 directive, confirmed 2026-05-28 reorg):**
D0 has full workspace-wide Render permissions: all `mcp__render__*` tools, `create_*`, `select_workspace`, provisioning/deletion/ownership. No per-call operator approval required (but post a `bot_chat` flag event for transparency on customer-facing service changes).

---

## 5. Single-writer table ownership

| Lane | Tables they write |
|---|---|
| **A1** | `event_xref`, `*_xref`, `event_listing_snapshot_daily`, sweep functions, `latest_event_metrics` matview, FRED macro, ESPN tables, `event_movers_index`, `event_movers_index_history`, `discovery_gap_alerts` |
| **B1** | `pg_policies` (via migrations), RLS configs |
| **C1** | `bot_chat`, `*_canonical`, `*_resolved` sidecars, `seatgeek_event_xref` |
| **D0** | `static/terminal/*` UI files (read-only from DB perspective) |
| **D1** | `share_links` (PAUSED) |
| **D2** | `evo_orders`, `seatgeek_orders`, `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots` (PAUSED) |
| **D3** | `broadway_*` tables (PAUSED) |

---

## 6. Code-review + push workflow

1. **Branch** off `main`: `claude/<lane>-<purpose>-<id>`
2. **Migration header** (required): `-- Migration <ts> · level:<X> · lane:<Y> · writes:<...> · reads:<...>`
3. **PR** — use `.github/PULL_REQUEST_TEMPLATE.md`
4. **Apply to preview branch** via MCP — never directly to main project_id without operator OK
5. **bot_chat log** — `change_log` event with PR# linked
6. **A1 review + push** — applies migration to prod via MCP, merges PR

**Exception**: D0 may apply migrations directly when explicitly authorized per session by operator (per current working pattern).

---

## 7. Deploy infrastructure ownership

| Render service | Lane owner | Sub-implementer | Source code | IaC |
|---|---|---|---|---|
| `vibepass-terminal-test` | **D0** | D0 | `static/terminal/*` | `render-d0-terminal.yaml` |
| `vibepass-storefront-test` | **D0** | D1 (PAUSED) | `app.py`, `static/store/*` | `render.yaml` |
| `d2-orders-dashboard` | **D0** | D2 (PAUSED) | `d2_dashboard/*` | `render-d2-dashboard.yaml` |

---

## 8. Quick links

- `LANE_DISCIPLINE.md` — per-lane write/read/never-write rules (detail)
- `MIGRATION_CONVENTIONS.md` — migration + commit rules (13 sections)
- `PROJECT_BIBLE.md` — canonical playbook (read first per session)
- `CLAUDE.md` — immutable security + lockdown rules
- `docs/bot-hierarchy.mermaid` — visual diagram (needs refresh to match 2026-05-28 reorg)

Owner: A1. Update when lane assignment changes or new bot is rostered.
Last updated: 2026-05-28 reorg (operator directive).
