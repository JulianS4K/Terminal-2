# SYNC_PROTOCOL.md

**Goal: shrink the time from "a bot has a change ready" to "every other bot is back in sync with prod."**

Companion to `BOT_HIERARCHY.md` (who can push) and `MIGRATION_CONVENTIONS.md` (how to push). This is *how fast*.

Why this doc exists: in the last two weeks we hit 5 migration-timestamp collisions, one 9928-line deploy-branch drift, multiple ad-hoc apply-before-PR cycles, and inconsistent `bot_chat` posting cadence. The protocol below codifies the patterns that worked and bans the ones that caused drift.

---

## 1. What "synced" means

A bot is **synced** when *all three* of these hold:

1. Its worktree's branch base = `origin/main` HEAD
2. Every prod-applied migration is reflected in `supabase/migrations/` on `main`
3. Its identity row in `bot_chat` is current (last `change_log` / `sync` event ≤ last A1 SYNC CHECKPOINT)

A1 verifies (1) + (2) before merging any PR. Each bot self-verifies (3) when they pick up the next baton.

**One-liner check** (run inside your worktree):

```bash
bash scripts/check_sync.sh
```

(Prints `SYNCED ✓` or a delta. Source in `scripts/check_sync.sh`.)

---

## 2. Three tracks (pick one per PR)

| Track | When to use | A1 review SLA | Apply-before-PR? |
|---|---|---|---|
| 🟢 **Fast** | Docs-only (`*.md`), repo-config, comments, cron-cadence tweaks (no DDL), edge-fn redeploys identical-source | ≤ 30 min (A1 will batch + merge) | N/A |
| 🟡 **Careful** | Any DDL (`CREATE TABLE`, `ALTER`, `DROP`, function changes), new cron jobs, new edge functions, schema-relevant `app.py` changes | ≤ 1 business day | Allowed if idempotent + reversible (§5) |
| 🔴 **Emergency** | P0 security patch (B1 lane) OR site-down storefront fix OR data-loss prevention | Same hour; A1 + author paired | Allowed; post-mortem mandatory |

If a PR mixes Fast and Careful work, it's **Careful** — split if you want a Fast lane.

---

## 3. Pre-PR checklist (every track)

Author runs through these before opening the PR:

```
[ ] git fetch origin && git rebase origin/main   (or merge — choice is yours,
                                                  but base must be current)
[ ] bash scripts/check_sync.sh                   (must print SYNCED)
[ ] Migration timestamp reserved (§4) — only for Careful track DDL
[ ] Migration header line present + accurate
    (-- Migration <ts> · level:<X> · lane:<Y> · writes:<...> · reads:<...> · pre:<...>)
[ ] If SECURITY DEFINER added: REVOKE FROM PUBLIC + GRANT TO service_role +
    body-assert current_user (PR #67/#68 convention)
[ ] If new cron job: not at :02 / :05 / :07 minute marks (those clusters are
    saturated — see RESOURCES_BIBLE.md §5; pick :03 / :04 / :06 / :08)
[ ] PR template fully filled (level, lane, branch, what, migrations,
    tables-touched, cross-lane writes, pre-reqs, test plan)
```

A1 will close any Careful PR missing any of these without review.

---

## 4. Migration slot reservation (kills timestamp collisions)

Pre-2026-05-13, multiple bots wrote files with the same `YYYYMMDDHHMMSS` timestamp and discovered the collision only at PR open. We hit this 5 times in two weeks. Reservation eliminates it.

**Rule**: before writing the migration file, post a `slot_reserve` event in `bot_chat`:

```sql
SELECT bot_chat_log(
  '<level>', '<lane>', 'slot_reserve',
  'reserving 20260513003000 for <short purpose>',
  NULL,                                    -- related_pr (none yet)
  '20260513003000_<short_filename>.sql',  -- related_mig
  NULL
);
```

Slot is yours for **6 hours**; if your PR isn't open by then, A1 may release the slot. Check open reservations before claiming:

```sql
SELECT created_at, bot_lane, related_mig, message
FROM bot_chat
WHERE event_type = 'slot_reserve'
  AND created_at > now() - interval '6 hours'
ORDER BY related_mig;
```

Pick the next free `YYYYMMDD<HHMMSS>` block at least **10 minutes** ahead of every active reservation. Examples in flight today:
- `20260513001000` LEM matview (A1, merged #71)
- `20260513002000` reddit stop (A1, merged #72)
- `20260513003000` reserved for the next admin migration
- `20260513010000+` C1 lane next block

Spacing convention: A1 picks `*0000` slots, C1 picks `*5000`, B1 picks `*9000`. Within a lane, increment by `001000` (one minute) per migration in the same session.

---

## 5. Apply-before-PR (Careful track speed lever)

Background: when a migration is **idempotent** (`CREATE OR REPLACE`, `CREATE … IF NOT EXISTS`, `DROP … IF EXISTS`, `cron.unschedule … IF EXISTS`), and the change is **reversible** (no data destruction without an opt-in flag), A1 may apply via MCP **before** opening the PR. The PR then becomes an idempotent codification — re-applying it against current prod is a no-op.

This is what shipped PRs #71 and #72 in the same day they were authored.

### When apply-before-PR is allowed
- ✅ `CREATE OR REPLACE FUNCTION` (function bodies)
- ✅ `CREATE INDEX IF NOT EXISTS`, `DROP INDEX IF EXISTS`
- ✅ `CREATE MATERIALIZED VIEW … WITH NO DATA` + populating REFRESH (data is recoverable)
- ✅ `cron.schedule(…)` + `cron.unschedule(…)` — both idempotent
- ✅ `GRANT` / `REVOKE` adjustments
- ✅ `COMMENT ON …`
- ✅ Adding rows to seed/config tables with `ON CONFLICT DO NOTHING`

### When apply-before-PR is BANNED
- ❌ `DROP TABLE` / `DROP COLUMN` / `DROP TYPE` (data loss)
- ❌ `ALTER TABLE … DROP CONSTRAINT … CASCADE` (cascade reach not auditable)
- ❌ Any change that breaks a currently-running consumer mid-flight (e.g. removing a view referenced by `app.py`)
- ❌ Anything that crosses lanes without prior `bot_chat` ack from the affected lane

### Procedure when allowed
1. Apply via MCP (`apply_migration` or `execute_sql` if migration history is contended)
2. Open the PR with the migration file matching the applied state exactly
3. PR body MUST include: `## Already applied to prod\nApplied via MCP at <timestamp UTC>. This PR is the idempotent codification.`
4. PR template's Test plan must include: `[x] Re-apply against current prod state is a no-op (verified by guards)`

A1's review then only checks the codification matches prod state.

---

## 6. PR open → merge timeline

| Step | Owner | Target time |
|---|---|---|
| Author opens PR | author | T0 |
| `bot_chat` event: `change_log` linking PR# | author | T0 + 2 min |
| A1 reviews (or batches with other PRs in queue) | A1 | T0 + 30 min (Fast) / 1 day (Careful) |
| A1 merges with squash + delete-branch | A1 | as ready |
| A1 verifies prod state matches | A1 | T0 + merge + 5 min |
| A1 SYNC CHECKPOINT broadcast | A1 | after a batch of merges |
| Other bots pull `origin/main` into their worktrees | each bot | within 1 hour of broadcast |
| Each bot replies `sync` event in bot_chat (optional but nice) | each bot | within 1 day |

A1's merge style is **always**: `gh pr merge <N> --squash --delete-branch`. Linear history, branch numbers preserved in commit subjects, no merge-commit clutter.

---

## 7. SYNC CHECKPOINT broadcast format

After A1 merges a batch of PRs (typically 2–5 in one sitting), A1 posts a single `broadcast` event to `bot_chat`:

```
SYNC CHECKPOINT <YYYY-MM-DD> — main HEAD <short-sha>.
Merged: #<n1> <title>, #<n2> <title>, … (Also #<n> <other-lane> landed in parallel.)
Prod state matches main on all admin-lane writes.

Next batons:
- D1: <one line>
- C1: <one line>

A1 idle — ready for the next directive.
```

Example (yesterday's): `bot_chat` row 75 — landed PRs #71/#72/#74/#75, mentioned #78 (B1) in parallel, pointed D1 at `docs/evo_store_next_steps.md` and C1 at the row 65 advisor flags.

Other bots, on seeing a SYNC CHECKPOINT:
1. `git fetch origin && git rebase origin/main` (or merge — they pick)
2. `bash scripts/check_sync.sh` to confirm SYNCED
3. Read any baton aimed at their lane
4. Optionally post `sync` event acknowledging

---

## 8. Branch + PR naming (for grep-ability)

### Branch naming

```
claude/<lane-short>-<purpose-slug>
```

- `<lane-short>` = `a1` / `b1` / `c1` / `d0` / `d1` / `d2` / `d3` (lowercase the lane code)
- `<purpose-slug>` = 2–4 hyphenated words

Examples that work:
- `claude/a1-lem-matview-fix`
- `claude/d1-retail-finish-notes`
- `claude/c1-canonical-phase13`
- `claude/b1-rls-coverage`

Branch names without the lane prefix get warned (not blocked) — historical names like `claude/store-sql-only-demo-mode` are grandfathered.

### PR title

```
<type>(<lane>): <short imperative>[, optional context]
```

- `<type>` = `feat` / `fix` / `chore` / `docs` / `perf` / `refactor` (Conventional Commits)
- `<lane>` = same as branch
- Squash-merge commit subject will be `<type>(<lane>): <short imperative> (#<pr>)` — already what we're doing

Examples that work:
- `feat(admin): convert latest_event_metrics to matview (P1 escalation)`
- `chore(admin): stop reddit cron pipeline (P0 resource pressure)`
- `fix(security): REVOKE EXECUTE FROM PUBLIC on PR #66 SECURITY DEFINER fns`

---

## 9. Conflict + drift response

**Migration timestamp collision** (two `slot_reserve` events for the same `YYYYMMDDHHMMSS`):
- Earlier `created_at` wins
- Later bot picks the next slot (per §4 spacing convention) and posts a replacement `slot_reserve`
- If the loser already wrote the file, they rename and `git mv`

**Deploy-branch drift** (Render or other long-lived deploy branches behind `main`):
- D1 (Render owner) runs `git merge origin/main` into the deploy branch weekly OR repoints the service at `main`
- Other deploy branches: same pattern, owner of the service handles it
- Documented per-service in `RESOURCES_BIBLE.md` §10

**Stale fork** (a bot's worktree is hours behind):
- On any merge-conflict at push time, the bot rebases against `origin/main` first
- If conflict persists in their own files, they resolve locally
- If conflict crosses lanes, post `bot_chat` event_type `question` and tag the other lane

**Cross-lane write detected in review**:
- A1 marks the PR with `level:cross-lane`, holds merge
- Author pings the affected lane in `bot_chat` and waits for ack
- After ack, A1 merges

---

## 10. Daily sync ritual (optional, ≤ 60 seconds)

Each active bot, once per workday:

```bash
cd <your worktree>
git fetch origin
bash scripts/check_sync.sh

# If SYNCED — done.
# If not synced and you have no in-flight work:
git rebase origin/main

# If not synced AND you have uncommitted in-flight work:
git stash && git rebase origin/main && git stash pop
```

Then check `bot_chat` for the latest SYNC CHECKPOINT:

```sql
SELECT id, message FROM bot_chat
WHERE event_type IN ('broadcast', 'sync_checkpoint')
ORDER BY id DESC LIMIT 3;
```

If the latest broadcast names your lane in "next batons," that's your work.

---

## 11. Speed wins this protocol unlocks

| Speed lever | Before | After |
|---|---|---|
| Migration timestamp collisions | 5 incidents in 2 weeks → rename + force-push cycles | `slot_reserve` claim before write; collisions self-resolve at claim time |
| A1 review bottleneck for docs | Docs-only PRs sat in queue with DDL | Fast track has 30-min SLA; A1 batches them |
| Apply-before-PR not codified | Done ad-hoc with no audit trail | Explicit `## Already applied to prod` section in PR body |
| Sync state ambiguous after a merge | Each bot guesses when to pull | SYNC CHECKPOINT broadcast triggers the pull |
| Branch + PR grep | Inconsistent naming → can't find your branch | `claude/<lane>-<slug>` + `<type>(<lane>):` convention |
| Deploy-branch drift | 9928 lines behind (the Render branch incident) | Weekly merge by service owner OR repoint at main |
| First-time-bot ramp-up | Hunt for docs across the repo | `START_HERE.md` → `BOT_HIERARCHY.md` → `SYNC_PROTOCOL.md` → `MIGRATION_CONVENTIONS.md` |

---

## 12. Open questions / future tightenings

- **CI auto-deploy** for migrations + edge fns once the PR merges — currently A1 applies via MCP. Track on KANBAN. (`CI auto-deploy for migrations + edge fns` is on A1's pending list.)
- **Auto-rebase on green CI** — GitHub auto-merge with required status checks. Project setting; A1 will enable when branch protection rules are tightened.
- **`bot_chat` `sync_checkpoint` as a first-class event_type** vs the current `broadcast` overload — needs a small migration to add to the enum.

A1 to revise §4 / §5 / §7 as the SLAs prove out. Push back via `bot_chat` `event_type='question'` if any rule slows you down rather than speeding you up.

---

Owner: A1. Reviewers: B1 (security), C1 (canonical scope), D1 (storefront workflow).
