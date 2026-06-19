# Render Workspace Security Posture — Terminal-2

**Owner**: B1 (Security Manager — read-only on Render) · **Last full sweep**: 2026-05-16 · **Update cadence**: per-session sweep step 13 (see [`b1_operating_constraints.md`](b1_operating_constraints.md))

Living snapshot of the Render workspace serving Terminal-2 lanes. B1 diffs current `mcp__render__*` output against this doc to catch regressions.

**Lane scope**: per [`PROJECT_BIBLE.md §2`](../PROJECT_BIBLE.md) Cross-cutting Rule #6, A1 + D1 own Render writes. D2 + D0 have write scope on their own services per PROJECT_BIBLE.md §2. B1 monitors only — findings that require Render writes become PR comments to the service owner.

---

## ⚠ Testing-unified architecture (post-2026-05-16, PR #168 + #169)

**Current runtime topology** (per [PROJECT_BIBLE.md §2](../PROJECT_BIBLE.md) + [CLAUDE.md §4](../CLAUDE.md)):

```
vibepass-storefront-test (TESTING UNIFIED RUNTIME)  ◄── all runtime traffic
├── D0 /terminal, /undelivered      (D0 mounts in app.py)
├── D1 /, /store, /api/store/*      (D1 mounts in app.py — original surface)
└── D2 /api/d2/* (8 routes)         (D2 mounts via app.include_router, line 6789)

vibepass-terminal-test               ◄── D0 static CDN only (no runtime)
d2-orders-dashboard                  ◄── ALIVE but idle (beta-time placeholder)
```

**At beta**: each surface migrates back to its own service (DNS swap + un-mount from `app.py`). The 3-service segregation that existed pre-2026-05-16 is the production target; current state is intentional test-time convergence onto the always-warm starter plan.

**Security implications of unified runtime**:
- Single app process surface → single auth boundary. D0/D1/D2 routes share `require_auth` dependency injection from `app.py`. Email-gated `@s4kent.com` access flows through one JWT verification path. ✅ less attack surface than 3 isolated services.
- Render `ipAllowList` discipline now applies to ONE service (vibepass-storefront-test). The IP-allowlist hardening conversation from R-1 below collapses to one decision point.
- A misbehaving D2 endpoint can theoretically degrade D0/D1 traffic via shared process. ⚠ Render free-tier instance + starter plan dyno share one process. Defense-in-depth: keep D2 routes prefix-isolated to `/api/d2/*` (per `include_router` mount strategy in `app.py:6789`).

---

## Active findings (open, 2026-05-16)

| # | Severity | Finding | Action |
|---|---|---|---|
| R-1 | SEC-LOW | `ipAllowList: 0.0.0.0/0` ("everywhere") on `vibepass-storefront-test`. With testing-unified, this is the single live service — broker terminal (`/terminal/*`), storefront (`/store/*`), D2 dashboard (`/api/d2/*`) all share this gate. Auth lives at app layer (`require_auth` + body-gated `auth.jwt()->>'email'` on D0 RPCs); IP allowlist would be secondary defense. | [B1-NEXT-19] — PR comment to D1 (service owner). Operator decision: tighten allowlist to known operator IPs, or accept current posture. |
| R-2 | SEC-LOW | `vibepass-storefront-test` `autoDeploy: yes` on every commit to `main`. Standard CD; a malicious PR past `pytest`/`check`/`scan` + reviewer auto-deploys to the single live runtime. Higher blast radius now that 3 lanes share one service. | [B1-NEXT-20] — PR comment to D1: optional manual approval gate (Render UI) given unified-runtime blast radius. |

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

### vibepass-storefront-test (TESTING UNIFIED RUNTIME · D1 + D0 mounts + D2 router)

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

Public retail-facing storefront + UNIFIED RUNTIME hosting D0 (`/terminal`, `/undelivered`), D1 (`/`, `/store/*`, `/api/store/*`), D2 (`/api/d2/*` — 8 routes via `app.include_router(d2_router)` at `app.py:6789`). All test-time runtime traffic flows here. At beta: D0+D2 migrate back to their own services.

### d2-orders-dashboard (D2 lane · IDLE PLACEHOLDER during testing-unified)

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

Internal D2 dashboard — service ALIVE but receives no live traffic under testing-unified architecture (D2's APIRouter is mounted on `vibepass-storefront-test` instead). Kept warm as a beta-time placeholder; will be re-activated when D2 migrates off the unified shell (DNS swap + unmount from `app.py`).

### vibepass-terminal-test (D0 lane — CDN ONLY during testing-unified)

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

D0 broker terminal static frontend. Serves frontend HTML/JS only via CDN; runtime moved to `vibepass-storefront-test` under testing-unified (D0's `/terminal` route + dependents now mount on app.py). Auth happens at API layer on the unified runtime.

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

Per [`PROJECT_BIBLE.md §2`](../PROJECT_BIBLE.md) Cross-cutting Rule #6, B1 cannot write to Render. Process for findings:

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
