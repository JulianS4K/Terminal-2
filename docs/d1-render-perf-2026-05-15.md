# D1 Storefront — Render Service Plan Bump (Free → Starter)

**Date:** 2026-05-15
**Service:** `vibepass-storefront-test` (`srv-d8140bnaqgkc73al4asg`)
**Owner:** D1 (Consumer Retail) — per LANE_DISCIPLINE.md §Cross-cutting Rule #6

## Why

The storefront was on Render's free service tier, which sleeps after 15 min of idle traffic. Cold-start TTI on first visit was ~14 seconds end-to-end:

| Cold-start phase | Time |
|---|---|
| First `/healthz` request | TIMEOUT (>30s) — dyno asleep |
| Second `/healthz` request | 12,275 ms — uvicorn waking + serving first response |
| Third `/healthz` request | 268 ms — warm |

That's a UX failure on the very first visit — a customer landing on `/store` after a quiet stretch sees a blank tab for ~12 seconds. The Starter plan ($7/mo per service) eliminates the sleep behavior: dyno stays warm 24/7, first visit lands at the same warm latency as any subsequent request.

## Warm baseline (recorded before plan bump)

Measured 2026-05-15 ~14:35 UTC against the PR #115 deploy, mean of 3 trials:

| Endpoint | Mean | Range | Bytes |
|---|---|---|---|
| `/healthz` | 426 ms | 326–514 | — |
| `/store` (HTML) | 245 ms | 216–266 | 2,915 |
| `/api/store/events?limit=60` (catalog) | **1,860 ms** | 1,668–2,162 | 37,061 |
| `/api/store/movers` | 295 ms | 269–324 | (currently 0 events — F5 bug, fixed in PR #111) |
| `/` (root → /store) | 430 ms | 317–498 | — |
| `/static/store/store.js` | 205 ms | 182–223 | 79,220 |
| `/static/store/style.css` | 187 ms | 163–200 | 29,193 |

**Warm front-screen TTI** (HTML + static assets + catalog all factored in):
- HTML 245 ms ‖ static ~200 ms in parallel ‖ catalog 1,860 ms = **~2.1 s**

**Cold-start front-screen TTI** (before this bump):
- HTML ~12 s (dyno wake) + static + catalog = **~14 s**

## Expected post-bump

| Scenario | Before (free) | After (starter) |
|---|---|---|
| First visit after idle | ~14 s | **~2.1 s** (same as warm) |
| Subsequent visits | ~2.1 s | ~2.1 s |
| Cost | $0/mo | **$7/mo** |

After PR #111 lands (separately), the warm number drops further:
- `/api/store/home` ~50 ms (replaces catalog 1,860 ms for first paint)
- Warm front-screen TTI projected: **~450 ms with prices on cards**

## Verification after deploy

Render auto-deploys from `main` on merge. Smoke matrix:

```bash
# Confirm no more sleep — first request after >30 min idle should be ~250ms,
# not 30s TIMEOUT.
curl -w '%{http_code} time=%{time_total}\n' https://vibepass-storefront-test.onrender.com/healthz

# Latency baseline matches the warm numbers above.
for i in 1 2 3; do
  curl -sS -o /dev/null -w '  attempt %{http_code} time=%{time_total}\n' \
    https://vibepass-storefront-test.onrender.com/api/store/events?limit=60
done
```

## Cost notes

- Starter is **per-service**, not workspace-wide. The Pro workspace ($25/mo flat) is a separate billing layer that unlocks team features (preview envs, autoscaling capability, performance builds, audit logs, 25 GB bandwidth). It does **not** automatically change service plans.
- D2's `d2-orders-dashboard` service is on a separate billing line, owned by D2. If D2 wants to eliminate cold starts on their dashboard, they bump `render-d2-dashboard.yaml` themselves (D1 doesn't touch cross-lane IaC per `d1_operating_constraints.md`).

## Revert path

If we need to roll back: change `render.yaml:plan` back to `free`. Render's next deploy will provision the service on the free tier and re-introduce the sleep behavior. No data is lost on the downgrade (env vars, secrets, branch config all persist).
