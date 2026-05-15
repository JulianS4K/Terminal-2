# Render Workspace Security Posture — Terminal-2

**Owner**: B1 (Security Manager — read-only on Render) · **Last full sweep**: 2026-05-15 · **Update cadence**: per-session sweep step 13 (see [`b1_operating_constraints.md`](b1_operating_constraints.md))

Living snapshot of the Render workspace serving Terminal-2 lanes. B1 diffs current `mcp__render__*` output against this doc to catch regressions.

**Lane scope**: per [`LANE_DISCIPLINE.md`](../LANE_DISCIPLINE.md) Cross-cutting Rule #6, **D1 owns Render writes exclusively**. B1 monitors only. Findings that require Render writes become PR comments to D1.

---

## Active findings (open, 2026-05-15)

| # | Severity | Finding | Action |
|---|---|---|---|
| R-1 | SEC-LOW | All 3 Terminal-2 services have `ipAllowList: 0.0.0.0/0` ("everywhere"). For `vibepass-storefront-test` (public retail) this is intended. For `vibepass-terminal-test` (broker terminal, supposed to be `@s4kent.com`-gated) and `d2-orders-dashboard` (internal ops), the IP allowlist could be a secondary defense. Auth lives at the app layer; this is belt-and-suspenders. | File [B1-NEXT-19]. PR comment to D1 (Render-write authority) — operator decision: tighten IP allowlist on internal services or accept current posture. |
| R-2 | SEC-LOW | All 3 Terminal-2 services `autoDeploy: yes` on every commit to `main`. CD is standard — but a malicious PR that gets past `pytest`/`check`/`scan` + reviewer auto-deploys to production. | File [B1-NEXT-20]. PR comment to D1: optional deploy gate (manual approve) for `vibepass-storefront-test` (public retail). |

No SEC-MED or SEC-HIGH findings.

✅ Good posture:
- No PR previews (`pullRequestPreviewsEnabled: no` on all 3) — unreviewed code can't get a public URL
- No hi-events service (Terminal-2-unrelated) consuming Terminal-2 budget — that service is `suspended`
- All services on `main` (the only branch with protection)
- All services have a defined `healthCheckPath` (`/healthz`) on web services
- Single workspace owner (`julian@s4kent.com`)

---

## Section 1 — Workspace

Source: `mcp__render__list_workspaces` + `mcp__render__get_selected_workspace`

| Field | Value |
|---|---|
| Workspace name | S4K |
| Workspace ID | `tea-d7g09jm7r5hc73d0jdkg` |
| Type | `team` |
| Owner email | `julian@s4kent.com` |

Single workspace; no multi-tenancy.

---

## Section 2 — Terminal-2 services

Source: `mcp__render__list_services` filtered to repo `https://github.com/JulianS4K/Terminal-2`

### vibepass-storefront-test (D1 lane)

| Field | Value |
|---|---|
| Service ID | `srv-d8140bnaqgkc73al4asg` |
| Type | `web_service` (python) |
| Branch | `main` |
| Auto-deploy | `yes` (on commit) |
| Build command | `pip install -r requirements.txt` |
| Start command | `uvicorn app:app --host 0.0.0.0 --port $PORT` |
| Health check | `/healthz` |
| Plan | free |
| Region | oregon |
| `ipAllowList` | `0.0.0.0/0` (everywhere) — R-1 |
| `pullRequestPreviewsEnabled` | no ✅ |
| Suspended | not_suspended |
| Created | 2026-05-11T20:46:39Z |
| URL | https://vibepass-storefront-test.onrender.com |

Public retail-facing storefront. Anon access intended.

### d2-orders-dashboard (D2 lane)

| Field | Value |
|---|---|
| Service ID | `srv-d82b4kl7vvec73b4r3r0` |
| Type | `web_service` (python) |
| Branch | `main` |
| Auto-deploy | `yes` (on commit) |
| Build command | `pip install -r requirements.txt` |
| Start command | `uvicorn d2_dashboard.main:app --host 0.0.0.0 --port $PORT` |
| Health check | `/healthz` |
| Plan | free |
| Region | oregon |
| `ipAllowList` | `0.0.0.0/0` — R-1 |
| `pullRequestPreviewsEnabled` | no ✅ |
| Suspended | not_suspended |
| Created | 2026-05-13T17:18:11Z |
| URL | https://d2-orders-dashboard.onrender.com |

Internal D2 dashboard. Auth-gated at app layer; IP allowlist is belt-and-suspenders.

### vibepass-terminal-test (D0 lane — per PR #107)

| Field | Value |
|---|---|
| Service ID | `srv-d839339kh4rs73ac3s20` |
| Type | `static_site` |
| Branch | `main` |
| Auto-deploy | `yes` (on commit) |
| Build command | `echo "static assets — no build step"` |
| Publish path | `static/terminal` |
| Plan | starter |
| `ipAllowList` | `0.0.0.0/0` — R-1 |
| `pullRequestPreviewsEnabled` | no ✅ |
| Suspended | not_suspended |
| Created | 2026-05-15T03:22:54Z |
| URL | https://vibepass-terminal-test.onrender.com |

D0 broker terminal static frontend. The serves frontend HTML/JS only; auth happens at API layer (`/api/*` on storefront service routes to broker).

---

## Section 3 — Non-Terminal-2 services (informational)

Source: `mcp__render__list_services` filtered to other repos

### hi-events (suspended, unrelated)

| Field | Value |
|---|---|
| Service ID | `srv-d7g0cev7f7vs73blkc70` |
| Repo | `https://github.com/JulianS4K/Hi.Events` |
| Branch | `develop` |
| Suspended | `suspended` (suspenders: user) |

Not Terminal-2. Listed for completeness — confirms no foreign repos have active services in the workspace.

---

## Section 4 — What B1 monitors per-session

| Step | Probe | Pass condition |
|---|---|---|
| Workspace count | `mcp__render__list_workspaces` | 1 workspace (S4K), owner `julian@s4kent.com` |
| Service count | `mcp__render__list_services` | 4 (3 Terminal-2 active + 1 unrelated suspended). Any new service triggers diff check. |
| Per-service `autoDeploy` | `mcp__render__get_service` (each) | All Terminal-2 `yes` on `main` (current state) |
| Per-service `ipAllowList` | (same) | Any tightening from `0.0.0.0/0` is GOOD; any widening from a tighter state is FLAG |
| Per-service `pullRequestPreviewsEnabled` | (same) | All `no` (current state). Any flip to `yes` exposes unreviewed PR code on public URL. |
| Per-service `branch` | (same) | All on `main`. Any switch to `develop` / feature-branch is FLAG (branch protection only covers `main`). |
| Per-service `suspended` state | (same) | Track changes; suspension may indicate billing issue or operator action. |
| Deploy history | `mcp__render__list_deploys` | Successful deploys; flag failed deploys + auto-rollbacks (could indicate broken build or sabotage) |
| Logs | `mcp__render__list_logs` filtered for auth failures, 5xx spikes | Baseline within normal range. Anomalies → flag. |

---

## Section 5 — Cross-lane patch protocol for Render findings

Per [`LANE_DISCIPLINE.md`](../LANE_DISCIPLINE.md) Cross-cutting Rule #6, B1 cannot write to Render. Process for findings:

1. **SEC-CRIT / SEC-HIGH on Render**: PR comment to D1 immediately. If D1 offline >24h AND finding is exploitable, escalate to operator for direct Render Dashboard fix. B1 does NOT call `mcp__render__update_*` even under security cross-lane exception — the lane separation is hard.
2. **SEC-MED / SEC-LOW**: file in KANBAN.md, PR comment to D1 with ack-or-defer ask.

---

## Section 6 — Probe commands (reference)

```
# Workspace
mcp__render__list_workspaces
mcp__render__get_selected_workspace

# All services (current + suspended)
mcp__render__list_services

# Per-service detail
mcp__render__get_service serviceId=srv-d8140bnaqgkc73al4asg     # storefront
mcp__render__get_service serviceId=srv-d82b4kl7vvec73b4r3r0     # d2 dashboard
mcp__render__get_service serviceId=srv-d839339kh4rs73ac3s20     # d0 terminal

# Deploys
mcp__render__list_deploys serviceId=...

# Logs (auth-failure spike check)
mcp__render__list_logs resource=[<serviceIds>] text=["401" "403" "500"] direction=backward
```
