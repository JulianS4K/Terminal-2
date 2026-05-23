# C1 Daily Checkpoint Runbook

**Lane**: C1 — Drift Monitor + Daily Checkpoint Merger
**Cadence**: every day at 09:00 ET (preferred); ad-hoc if alerts fire
**Purpose**: keep prod state and repo state in sync, close drift before it compounds

**Scheduled-task path (2026-05-15)**: A1 provisioned the `c1-daily-checkpoint` scheduled task. The 9-step routine below auto-fires at 09:00 daily; operator must "Run now" once from the Scheduled sidebar to pre-approve Supabase MCP + Slack MCP tools. Slack alerts on `release_health_check` new fail rows, `p0_security` / `severity=high` bot_chat entries, deploy failures (channel C0B3PR8MJ07). bot_chat remains the canonical coordination surface — bots do not post Slack directly. See bot_chat 171.

---

## Why this exists

Drift between prod (what's actually applied / running) and the repo (what's checked in) is the highest-ROI category of bugs to prevent. The pattern from `docs/release-discipline.md` §1 — "PR #92 merged after #94 sweep, defeating the sweep's protection" — keeps recurring whenever apply-then-codify discipline lapses. C1's job is to catch that within 24h, not 7 days.

The session 2026-05-14 added the `migration_drift_check()` SQL function and the `release_health_check()` smoke harness. This runbook operationalizes them.

---

## Daily routine (15-20 minutes)

### Step 1 — Sync local state (1 min)

```bash
git fetch --all --prune
git checkout main && git pull --ff-only origin main
git log --oneline -10  # quick scan: what landed since yesterday
```

If anything looks unexpected (commits you don't recognize, weird merge structure), pause and surface to A1 via `bot_chat`.

### Step 2 — Migration drift check (2 min)

```sql
SELECT * FROM public.migration_drift_check();
```

The function returns rows from `supabase_migrations.schema_migrations` for the last 100 applied migrations. Compare against `ls supabase/migrations/*.sql`:

**Scenario A — applied to prod but no file**:
```bash
# For each "ghost" migration, find the timestamp + name and check if anyone forgot to commit:
ls supabase/migrations/ | grep <ts-prefix>
git log --all --oneline -- "*<ts-prefix>*"
```
If genuinely missing: post `flag` to `bot_chat`, route to A1 to codify retroactively. Example:
```sql
SELECT public.bot_chat_log('admin','Audit/Push','flag',
  'Drift: migration <ts> applied to prod but no file. Run pg_dump and codify.',
  p_related_mig := '<ts>');
```

**Scenario B — file exists but not applied**:
```sql
SELECT name FROM supabase_migrations.schema_migrations
  WHERE name = '<ts>' UNION SELECT '<not applied>' WHERE NOT EXISTS (
    SELECT 1 FROM supabase_migrations.schema_migrations WHERE name = '<ts>'
  );
```
Two cases:
- **Intentional staging** (file authored but apply gated on operator) → leave it, note in checkpoint summary
- **Forgotten** → flag to A1; suggest apply

### Step 3 — Health check delta (2 min)

```sql
SELECT * FROM public.release_health_check() WHERE status <> 'ok';
```

Compare to yesterday's checkpoint baseline (stored in `docs/c1-checkpoint-<yesterday>.md`):

- **Same set of rows** → no change, log "no health regressions"
- **New `warn` rows** → flag to lane owner, ask for resolution within 48h
- **New `fail` rows** → block any pending merges until resolved; escalate to A1

Specific row types and routing:
| Check | Owner |
|---|---|
| `cron.failed_jobs_90min` | A1 (admin lane) |
| `cron.subhourly_jobs_silent_90min` | A1 |
| `functions.pgcrypto_missing_extensions_searchpath` | A1 |
| `views.security_definer_views` | B1 |
| `fks.not_valid_fks` | A1 |
| `data_freshness.*` | respective ingest-lane owner (D1 for vivid/tickpick, D2 for evo, etc.) |
| `queues.unresolved_pending_total` | A1 if pending count climbing |

### Step 4 — PR backlog review (5 min)

```bash
gh pr list --state open --json number,title,headRefName,createdAt,updatedAt,labels --limit 50
```

For each open PR:
- **<24h old, has activity** → leave it, lane owner is working
- **24-72h old, no activity** → comment asking lane owner for ETA
- **>72h old, no activity** → tag for stale-close at next checkpoint
- **>7 days old** → close with stale-close comment; reopen if work resumes

PRs labeled `security` (B1's): coordinate with B1 before merging or closing; never stale-close those without B1 sign-off.

### Step 5 — Merge eligible PRs (varies)

Per push-protocol: A1 has final-merge authority on contentious cases. C1 merges PRs that meet ALL:
1. CI green (CHECK_RUN_STATUS=success on the latest commit)
2. No new health-check regressions (Step 3 baseline)
3. Approved by lane owner (or A1 if cross-lane)
4. Not in B1's security queue without B1 sign-off

For each eligible PR:

```bash
# Pre-merge token-leakage audit (operator directive 2026-05-15, bot_chat 139 + 141):
gh pr view <num> --json files --template '{{range .files}}{{.path}}{{"\n"}}{{end}}'
# Scan diff for the 8 patterns in docs/token-discipline-rules.md §"Pre-merge code audit"
# (file-header bloat, pre: mega-lists, restate-code comments, near-duplicates, dead code, etc.)
# Findings → bot_chat flag to lane owner. Merge proceeds unless structural waste.

# Then merge:
gh pr merge <num> --squash  # or --merge per repo convention
```

Document each merge + any leakage findings in the daily checkpoint summary.

### Step 6 — Stale branch sweep (2 min)

```bash
# Local branches that diverged from main >14 days ago AND have no open PR:
git for-each-ref --format='%(refname:short) %(committerdate:relative)' refs/remotes/origin/ \
  | grep -E '(months|years|2 weeks|3 weeks)' \
  | head -20
```

For each: comment in `bot_chat` listing them; lane owners reclaim or close.

### Step 7 — Write the daily summary (3 min)

Author `docs/c1-checkpoint-<YYYY-MM-DD>.md`:

```markdown
# C1 Checkpoint — 2026-MM-DD

## Drift status
- migration_drift_check: <N rows> | drift: <yes/no, count>
- release_health_check: <N non-ok> | new vs yesterday: <list>

## PRs landed today
- #<num> <title> → merge commit <oid>

## PRs awaiting action
- #<num> <title> | age: <Nd> | next step: <comment-eta / stale-close-eta / blocked-on>

## Bot_chat resolution count
- opened: <N>
- resolved: <N>
- unresolved >7d: <N>

## Open follow-ups for A1 / B1
- <list>

## Tomorrow's watch items
- <list>
```

Commit to repo:
```bash
git checkout -b claude/c1-checkpoint-<date>
git add docs/c1-checkpoint-<date>.md
git commit -m "chore(c1): daily checkpoint <date>"
git push -u origin claude/c1-checkpoint-<date>
gh pr create --base main --title "chore(c1): daily checkpoint <date>" ...
gh pr merge --merge --auto
```

### Step 8 — Post bot_chat entry (1 min)

```sql
SELECT public.bot_chat_log(
  p_level := 'admin',
  p_lane := 'C1',
  p_event_type := 'status',
  p_message := 'Daily checkpoint 2026-MM-DD complete. <summary>. See docs/c1-checkpoint-<date>.md'
);
```

> Note (2026-05-15): runbook originally specified `event_type='checkpoint'` but that value is not in the `bot_chat_event_type_check` constraint allowlist. Using `'status'` until either the constraint is widened or this runbook is patched (open follow-up #11 in [docs/c1-checkpoint-2026-05-15.md](docs/c1-checkpoint-2026-05-15.md)).

### Step 9 — Token discipline audit (2 min)

Added 2026-05-15 per operator directive (bot_chat 139). Charter: C1 owns token monitor + minimization alongside drift monitoring.

```sql
-- Oversized bot_chat posts in the last 24h (rule: <=1500 chars; see docs/token-discipline-rules.md)
SELECT id, bot_lane, event_type, length(message) AS chars, left(message, 80) AS preview
FROM public.bot_chat
WHERE created_at > now() - interval '24 hours'
  AND length(message) > 1500
ORDER BY chars DESC;
```

```bash
# Bloated migration headers in the last 24h (rule: <=15 lines)
for f in $(git log --since="24 hours ago" --name-only --pretty="" -- supabase/migrations/ | sort -u); do
  hdr=$(awk '/^[^-]/{exit} {print}' "$f" 2>/dev/null | wc -l)
  [ "$hdr" -gt 15 ] && echo "$hdr  $f"
done
```

Flag findings in `bot_chat` as `event_type='flag'`. Original author re-compresses on next post; old entries are tracked but not retroactively edited.

### Step 10 — Data-quality / semantic validation (3 min)

Added 2026-05-17 (Quality & Continuity charter, Duty 1). Catches *semantically wrong but running* pipelines that structural checks miss.

```sql
-- Succeeded-but-empty: crons green but no downstream rows in window (the silent-success class)
-- Coverage floor: active SG events lacking an xref bridge
SELECT 'sg_xref_coverage' AS check,
       round(100.0 * count(*) FILTER (WHERE x.sg_event_id IS NOT NULL) / nullif(count(*),0), 1) AS pct_bridged
FROM public.sg_events_canonical c
LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = c.sg_event_id
WHERE c.sg_event_date >= current_date;
-- Outlier sanity: listings beyond p99.9 price bound (suite/dataquality class)
-- Distribution drift: metric medians shifting >Nσ day-over-day without volume change
```

Flag anomalies to the data-owning lane; `severity=high` if a pipeline is silently producing wrong/empty output. **C1 detects; fix is A1/D2/owning lane.**

### Step 11 — End-to-end product validation (2 min)

Charter Duty 6. Read-only synthetic smoke across the funnel.

```bash
# Service liveness + sane shape (read-only GETs)
curl -fsS https://vibepass-storefront-test.onrender.com/healthz
curl -fsS "https://vibepass-storefront-test.onrender.com/api/store/events?limit=5" | head -c 200
# Funnel freshness: ingest → match → metric → display (latest snapshot age per stage)
```

Flag breakage to owning FE/data lane.

### Step 12 — Operator-action queue (1 min)

Charter Duty 4. Track everything gated on operator action so nothing rots.

```sql
SELECT id, created_at::timestamp(0), left(message, 100) AS item,
       round(extract(epoch FROM now() - created_at)/3600, 1) AS hours_open
FROM public.bot_chat
WHERE resolved_at IS NULL
  AND (message ILIKE '%@operator%' OR message ILIKE '%operator action%'
       OR message ILIKE '%operator approv%' OR message ILIKE '%rotat%')
ORDER BY created_at;
```

Surface as checkpoint "Operator action queue" section. Escalate items >48h via `flag` `severity=high`.

### Weekly (not daily) — Duties 2, 3, 5

- **Cost** (Duty 2): `docs/c1-cost-YYYY-WW.md` — `pg_total_relation_size` trend, row-growth, cron + paid-API call volume. Flag anomalous growth.
- **DR posture** (Duty 3): verify Supabase PITR on + recent; maintain `docs/disaster_recovery_playbook.md`. Pre-flight before high-risk applies.
- **Credential lifecycle** (Duty 5): maintain `docs/credential_lifecycle.md` register; flag approaching expiry/rotation-due.

Full spec: `docs/c1_quality_continuity_charter.md`.

---

## Escalation rules

| Condition | Action |
|---|---|
| New `fail` row in health-check that wasn't there yesterday | Pause all merges, page A1 in `bot_chat` |
| Drift detected: applied-to-prod but no file >24h old | Flag to A1, require codification within 24h |
| Same warn row persists 3+ checkpoints without resolution | Escalate to operator via `bot_chat` `flag` with `severity=high` |
| Security-class drift (auth, vault, RLS) | Page B1 immediately; do not wait for next checkpoint |
| Two consecutive checkpoints missed (>48h gap) | Operator-level escalation; either C1 instance is stuck or process needs revision |

---

## What's IN C1's lane

- Merging PRs (within push-protocol)
- Closing stale PRs (after warning)
- Writing checkpoint summaries
- Posting drift flags to `bot_chat`
- Reading any table, function, view, log

## What's OUT of C1's lane (delegate)

- Writing migrations to FIX drift → A1
- Fixing security findings → B1
- Changing bot-lane code → respective lane owner (PR comment)
- Render workspace mutations → A1 (or service-owner bot for their own service)
- Vault edits → A1 + operator
- Cron schedule changes → A1

---

## First checkpoint after reassignment

The first checkpoint after the 2026-05-14 reassignment (this run) should produce `docs/c1-checkpoint-2026-05-15.md` and include:

- Inventory: 7+ migrations applied today (universal AQ matcher, venue/performer maps, tier 1.5, listings linkage, cron policy gate, max-staleness floor, listings cadence halve, sales freshness 60min, classifier v2, listings deltas, TEvo→SG matcher, format-fix)
- PRs merged: 100-108 inclusive (all under PR #100+ from this session)
- Drift status: zero (all applied-to-prod migrations have corresponding files)
- Health check baseline: ~8 non-ok rows expected (post-cron-resume aftermath, will clear)
- Open follow-ups: rotate the screenshotted Render key; B1 retrofit migration for §6 SECDEF convention (4-11 functions)
