# SCOPE — what you (UI coworker) can and can't touch

This is the prose version of the rules. The mechanical enforcement
is in:
- `coworker_readonly` Postgres role (mig 20260509460000)
- `.github/CODEOWNERS` on Terminal-2 backend repo
- `.github/workflows/forbidden-paths-check.yml` CI guard
- Branch protection on `main` requiring code-owner review

---

## Two repos

| Repo | Yours? | What lives here |
|---|---|---|
| **Terminal-2** | No | Backend: FastAPI, plpgsql migrations, cron pipelines, RULE 2 enforcement |
| **Terminal-2-ui** | **Yes** | Frontend: whatever stack you choose, calls Terminal-2's API + queries Supabase via `coworker_readonly` |

You clone, branch, PR, and (if approved by audit lane) merge in
`Terminal-2-ui`. You read but don't edit anything in `Terminal-2`.

---

## What you can read

- All of `Terminal-2` source code (it's on GitHub; you have access).
- All `public.*` tables and views in Supabase via `coworker_readonly`.
- All read-only helper functions (e.g. `get_event_context(event_id)`).

## What you can write

- Anything in your `Terminal-2-ui` repo on a feature branch.
- Anything in the `design_test.*` Postgres schema (your sandbox).
- Issues + PRs in either repo.

## What you can NOT write

- `Terminal-2` repo files. CI guard rejects the PR; CODEOWNERS blocks
  merge regardless. If you need a backend change, **open an issue** in
  Terminal-2 describing the need, and the audit lane will write it.
- `public.*` Postgres tables. Role doesn't allow it.
- `vault.*` (secrets) or `cron.*` (scheduling). Role doesn't allow it.
- Any function that calls `net.http_*` (paid pulls). Role denies execute.

---

## Three legal failure modes (for your sanity)

### "I want to see if a query is fast enough"
✓ Run it via Supabase MCP with `coworker_readonly`. EXPLAIN ANALYZE works.

### "I want a new view that aggregates X"
✗ Don't create it in `public.*` — role can't, and convention says no.
✓ Prototype it in `design_test.*`, share the SQL in an issue, audit lane
  decides whether to promote to `public` (and writes the migration).

### "The API doesn't have an endpoint I need"
✗ Don't add it to `app.py` — repo doesn't accept your PRs there.
✓ Open an issue in `Terminal-2` describing what shape you need + why.
  Audit lane writes the route.

---

## Why the constraints

The data plane runs unattended on 48 active crons hitting paid APIs
(TEvo + SeatGeek + SeatData when restored). A single rogue write (or
misconfigured cron, or an experimental migration) can cost real money
or corrupt the timeline of price data we depend on for trading
decisions. **The cost of one accident is much higher than the friction
of asking the audit lane.**

This is also how the project audit (RULE 2: read-only enforcement on
TEvo/SG hosts) survives: 3 layers of static analysis + runtime guards
+ tests catch any drift toward writes. UI work, by being on a separate
repo with read-only DB access, can't drift this stack at all.

---

## When the friction is too high

If "open an issue, wait for backend change" is blocking you for >24h,
the right escalation is **DM Julian, not work-around**. Don't try to
spin up your own Postgres or fork the API to add what you need — that
fragments the data plane and creates a parallel reality where the UI
shows numbers the rest of the team can't reproduce. The whole point of
Terminal-2 is that there's one source of truth.
