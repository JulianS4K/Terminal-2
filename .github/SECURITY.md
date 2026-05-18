# Security Policy

## Reporting a vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

This repository is public. If you find a vulnerability in Terminal-2 or its hosted services (`vibepass-storefront-test.onrender.com`, `vibepass-terminal-test.onrender.com`, `d2-orders-dashboard.onrender.com`), report it via one of:

1. **GitHub Private Vulnerability Reporting** (preferred): https://github.com/JulianS4K/Terminal-2/security/advisories/new
2. **Email** (encrypted): julian@s4kent.com — include "SECURITY" in the subject line. PGP key on request.

Please include:
- A description of the issue + impact
- Reproduction steps (commands, payloads, URLs)
- Affected component (`app.py` route, Supabase RPC, edge function, etc.)
- Any related CVE / disclosure timeline you're working with

## Response SLA

- **Acknowledgement**: within 72 hours
- **Initial triage**: within 7 days (severity assessment + mitigation plan)
- **Fix or workaround**: within 30 days for SEC-CRIT/HIGH (per `docs/b1_operating_constraints.md` severity matrix)

## Supported versions

This is a continuously-deployed monorepo. The only supported version is the current `main` branch. Production deployments auto-deploy on `main` push via Render.

## Scope

In-scope for this policy:

- Code under `app.py`, `supabase/migrations/*`, `supabase/functions/*`, `*_client.py`
- Hosted Render services (`vibepass-storefront-test`, `vibepass-terminal-test`, `d2-orders-dashboard`)
- Edge functions deployed to Supabase project `hzrizjeaxlqcxfrtczpq`
- Authentication / authorization paths (Supabase Auth + `@s4kent.com` email gate + Apps Script `APPSCRIPT_INGEST_SECRET` + cron `CRON_SECRET`)

Out of scope:

- Third-party services (TEvo, SeatGeek, TickPick, Vivid, SeatData, ESPN, NWS) — report directly to the upstream
- Issues already documented in [`KANBAN.md §🟢 OPEN`](../KANBAN.md) under B1-NEXT-N (defense-in-depth follow-ups; not exploitable today)
- Social engineering / phishing of repo collaborators
- Denial-of-service via rate-limit exhaustion (we use rate limiting; abuse → block)

## Internal coordination

For Terminal-2 bots: security findings flow through:

1. `bot_chat` with `event_type IN ('p0_security', 'flag')` — durable, B1 owns resolution
2. [`KANBAN.md §🟢 OPEN`](../KANBAN.md) — operating ledger (severity-sorted, fixing bot deletes their row when shipping)
3. `docs/security-audit-<date>-<topic>.md` — long-form post-mortems
4. [`docs/b1_open_findings.md`](../docs/b1_open_findings.md) — superseded by KANBAN §🟢 OPEN as of 2026-05-17

See [`docs/b1_operating_constraints.md`](../docs/b1_operating_constraints.md) for B1's full charter + severity matrix.

## Hall of fame

We acknowledge reporters who follow responsible disclosure (with permission). To opt in, mention "publish my name" in your report.

_None yet — be the first._
