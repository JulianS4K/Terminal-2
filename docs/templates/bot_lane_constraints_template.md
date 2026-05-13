# <BOT_ID> Operating Constraints — Template

> Reusable template for codifying a single bot's lane in a multi-bot, single-writer-per-table codebase. Fill in the `<PLACEHOLDERS>` and drop the angle-brackets. Delete sections that don't apply.

`<BOT_ID>` = e.g., `D1`, `A2`, `B1`. Worktree `<worktree-name>`. Old label `<deprecated-name>` (deprecated `<date>`; see `bot_chat` rows `<n-m>`).

This doc codifies the boundaries `<BOT_ID>` operates within. **`BOT_HIERARCHY.md` (or equivalent canonical lane chart) is the source of truth — read it first.** This file fills in `<BOT_ID>`-specific operational detail that doesn't belong in the global chart.

## Scope

One-sentence statement of what `<BOT_ID>` owns end-to-end. Include the surface area (which routes / which UI / which data product). One worktree, one push surface, single-writer to `<owned tables>`.

## Read surface (allowed sources)

### External APIs (live, read-only via `<client_module>.py` — RULE N wall)

| Endpoint | Use |
|---|---|
| `GET <path>` | what for |
| `GET <path>` | what for |

Auth: `<auth scheme>`. Credentials resolved in priority order: (1) `<source>`, (2) `<source>`, (3) `<source>`. See `<resolver function>()` in `<file>`.

### Internal DB / SQL (read-only on these — `<BOT_ID>` does not write)

| Object | Owner lane | What `<BOT_ID>` uses it for |
|---|---|---|
| `<table>` | `<owner>` | `<purpose>` |
| `<view>` | `<owner>` | `<purpose>` |

If `<BOT_ID>` needs a new read, ack the owner lane in `bot_chat` (or equivalent coordination channel) first.

## Write surface (`<BOT_ID>` is the writer)

### Local files (`<BOT_ID>` lane)

- `<file>` — scope statement (e.g., "storefront routes only"). Cross-lane routes are read-only.
- `<file>` — full ownership / single-writer / append-only.
- `<file>` — read-only to `<BOT_ID>`. Modifying `<specific guards/lines>` is **forbidden** — see carve-out section below.
- `<file>` — `<BOT_ID>` may author/edit.
- `<coordination file>` — append-only, `<BOT_ID>` may add rows in `(<old-label> → <other-lane>)` style.

### DB tables (`<BOT_ID>` single-writer)

| Table | Writer pattern |
|---|---|
| `<table>` | Single-writer. Migration `<path>`. RPC `<rpc_name>(...)`. Schema: `<short schema>`. RLS enabled; service_role bypasses; all access through `<handler>` routes. |
| `<append-only table>` | Append-only multi-writer (all lanes). `<BOT_ID>` posts with `<discriminator>='<BOT_ID>'`. Use `<thread key>` to thread. |

Future tables (post-freeze): `<table_a>`, `<table_b>`. Same pattern.

### Hosting / infra (`<BOT_ID>` exclusive — sole owner per `BOT_HIERARCHY` §N)

- Service config (build/start commands, plan, region, branch)
- Env vars (read, set, delete via API)
- Deploys (trigger, restart, deactivate)
- Runtime logs (read)
- Health check path

API key lives in gitignored `<.env or secrets file>` as `<KEY_NAME>`.

## Forbidden actions

`<BOT_ID>` **must not**:

1. **Run `<destructive op>` against the prod `<resource>`.** Migrations / schema changes land via PR → `<reviewer>` review → `<applier>` applies. Preview branches allowed for validation.
2. **Push to `main`.** Only `<merge owners>` merge to `main`. `<BOT_ID>` ships via PR.
3. **Modify `<critical guard / RULE N wall>` in `<file>:<line range>`.** Future write capability lives in a sibling module (see carve-out below).
4. **Edit cross-lane files**: list specific files. Anything not explicitly in `<BOT_ID>`'s write surface above.
5. **Modify infra config on services other than `<owned services>`** (`<BOT_ID>` is sole owner of that service only).
6. **Submit to `<coordination channel>` with another lane's discriminator.** Always `<discriminator>='<BOT_ID>'`.
7. **Use the legacy `<old-label>` in new `<coordination channel>` rows.** It is deprecated. `<BOT_ID>` going forward.
8. **Echo secrets in chat or commits.** All credentials live in gitignored `<.env>` or `<settings table>`. Reference via env-var indirection.

## Coordination triggers

`<BOT_ID>` must file a `<coordination channel>` flag/sync row **before** any of:

- Adding a new read against a table/view `<BOT_ID>` doesn't already use → ack owner lane
- Proposing a new column/index on a shared read source → `<reviewer>` review
- Touching security posture (CSP, RLS, auth flow) → `<security lane>` review
- Adding a new outbound service call → security review (CSP update etc.)
- Any change that affects PII surface → security review
- Lifting `<critical guard>` (sprint carve-out) → architectural sign-off
- New scheduled job → `<scheduler owner>` review

## Carve-out / freeze conditions (if applicable)

`<feature>` is **mock today / frozen**. Storefront/UI carries an indicator badge.

Unfreezes only when **all N** are true:

1. **Operator-side**: external dependency confirmed (vendor onboarding, contract, mechanics).
2. **Architectural sign-off**: Filed in `<coordination channel>` row `<n>`. Proposed shape:
   - New module `<sibling_module>.py` (NOT modifying the existing guard)
   - Scoped allowlist: `frozenset({...})`
   - Scope: specific endpoints only
   - Existing guard untouched (`<tests>` keeps passing)
   - `<canonical doc>` section updated
3. **Front-end shipped**: prerequisite sprints in main, indicator badge removable.

## Verification / smoke after every `<BOT_ID>` PR merge

After merge + deploy from `main`:

```bash
curl <url>/healthz
# expect: <known good shape>

curl <url>/<key route>
# expect: <known good shape>, <SLA>

curl <url>/<another key route>
# expect: <known good shape>
```

Post `<coordination channel>` status (`<discriminator>='<BOT_ID>'`, `event_type='change_log'`) referencing the merged PR # + smoke results.

## References

- `BOT_HIERARCHY.md` (or equivalent) — canonical lane chart + push matrix
- `<MIGRATION_CONVENTIONS.md>` — repo migration discipline
- `<SCHEMA.md>` — RULE N (read-only wall, security boundaries)
- Other lane docs that intersect `<BOT_ID>`'s surface

## Revision history

| Date | What | Why |
|---|---|---|
| `<YYYY-MM-DD>` | Initial draft | `<BOT_ID>` codifies own constraints. Filed by `<BOT_ID>` as a self-imposed contract; `<reviewer>` reviews via PR. |

---

## How to use this template

1. **Copy** to a new file in your project's docs directory: `docs/<bot-id>_operating_constraints.md`.
2. **Read your project's `BOT_HIERARCHY.md`** (or whatever the canonical lane chart is called). The lane discipline doc complements it, it doesn't replace it.
3. **Fill in placeholders top-down.** Each `<PLACEHOLDER>` is a decision point — if you can't answer it, that's a coordination question to surface with the team before you start writing code.
4. **Delete sections that don't apply.** Carve-out / freeze section is only relevant if your lane has a future-state write capability gated behind external dependencies.
5. **File as a PR for review** by the lane that owns canonical / architecture review. The doc itself is a self-contract; review confirms the contract terms match what other lanes expect.
6. **Update revision history** when your lane's boundaries change (new tables owned, scope expanded, etc.). Don't silently mutate the constraints — every change goes through PR.

## Why this pattern works

The lane discipline doc is a **self-imposed contract** with three benefits:

1. **Onboarding speed**: a new agent / new contributor reads ~150 lines and knows exactly what they can and can't touch. No spelunking through commit history to discover boundaries by accident.
2. **Coordination cost reduction**: explicit "must file before" list eliminates 80% of cross-lane Slack/chat traffic. Lanes know when they need to coordinate vs when they can move alone.
3. **Audit trail**: when a lane DOES violate its constraints (intentionally — e.g., emergency security fix), the deviation is visible against an explicit baseline. No ambiguity about whether the violation was a coordination failure or a known exception.

The doc lives **in the codebase**, not in a wiki or notion page, so it versions with the code and can't drift out of sync with the actual files it references.
