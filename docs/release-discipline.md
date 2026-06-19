# Release discipline — anti-drift practices

Operator directive 2026-05-14: "find a way to streamline project from here on out without having pr and code drift in future."

This doc captures the failure patterns we observed shipping today and the practices/tooling that prevent them. Companion to:
- `MIGRATION_CONVENTIONS.md` — slot reservation + ordering rules (canonical)
- `PROJECT_BIBLE.md §2` — push restrictions + lane ownership (absorbed the former BOT_HIERARCHY / LANE_DISCIPLINE)
- `RESOURCES_BIBLE.md §5` — cron tier budgets

---

## 1. Regression patterns we hit today

Brief enumeration so the practices below are grounded:

| # | What broke | When | Why we missed it |
|---|---|---|---|
| R1 | 3 fns lost pgcrypto access (`hmac`, `digest`) | PR #95 search_path sweep | Blanket `SET search_path = public, pg_temp` on 215 fns without per-fn smoke test. `evo_orders_queue` failed every 30 min for 3 hours. |
| R2 | 7 views reverted to SECURITY DEFINER | PR #92 phase 15b `CREATE OR REPLACE VIEW` | The `security_invoker=true` reloption is reset by CREATE OR REPLACE; PR #92 was authored before PR #94's sweep but merged after, so the protection vanished. |
| R3 | TickPick column mapping bugs (`status`, `total`) | RPC v1 | Built RPC from assumption about TickPick's payload shape instead of inspecting an actual response. `total` field doesn't exist → all 909 rows had NULL `total`. |
| R4 | TEVO_SECRET vs TEVO_API_SECRET (two values in vault, different) | Ad-hoc vault edits over time | No single source of truth for which secret name is canonical; 6 production functions reference one, 0 reference the other. |
| R5 | TickPick token diagnosis took several iterations | n/a | First hypothesis (truncated token) was wrong. Real issue (IP allowlist) wasn't suspected until proven via httpbin + UA-spoof. |
| R6 | `v_bot_chat_unresolved` had SECURITY DEFINER | unknown — pre-dates today | Sat undetected because PR #94 enumerated views from a stale list. Smoke harness caught it after the fact. |
| R7 | Credential exposure in chat | A1 paste error | No process gate; trust-based hygiene only. |

All seven would have been caught earlier (or prevented) by the practices below.

---

## 2. The two automatic guards (live as of today)

### 2a. `release_health_check()`

`SELECT * FROM public.release_health_check() WHERE status <> 'ok';`

Returns 7 categories of check, each rated `ok` / `warn` / `fail`:

| Class | Catches |
|---|---|
| `cron.failed_jobs_90min` | R1 (cron starts failing) |
| `cron.subhourly_jobs_silent_90min` | jobs that should fire but haven't |
| `functions.pgcrypto_missing_extensions_searchpath` | R1 directly (the search_path drift class) |
| `views.security_definer_views` | R2, R6 (any non-built-in public view missing `security_invoker=true`) |
| `fks.not_valid_fks` | hygiene backlog signal |
| `data_freshness.*` | upstream API breakage manifesting as stale rows |
| `queues.unresolved_pending_total` | pg_net request backlog from upstream failures |

**Discipline**: call this BEFORE and AFTER every `apply_migration` MCP call. Any row that flips from `ok` to `warn`/`fail` between the two calls = regression introduced by THIS migration. Roll back or follow up with a targeted fix.

Today, immediately after the function landed it surfaced R6 (the `v_bot_chat_unresolved` view we missed) — fix took 10 seconds.

### 2b. `migration_drift_check()`

`SELECT * FROM public.migration_drift_check();`

Returns the last 100 prod-applied migrations. CI workflow joins against on-disk `supabase/migrations/*.sql` to detect codification drift:
- Applied to prod but no file → "ghost" migration; codify retroactively
- File exists but not applied → either pending or stale; reconcile

**Today's gap**: this lives in SQL but the CI half (file-side join) isn't wired yet. **Punch-list item for next session**: GitHub Action that runs daily, calls `migration_drift_check()`, diffs against `ls supabase/migrations/*.sql`, opens an issue on drift.

---

## 3. Migration template (mandatory for any new admin migration)

Header comment must include these 5 lines:

```sql
-- Migration YYYYMMDDhhmmss · level:<admin|secondary|...> · lane:<Audit/Push|...> · writes:<tables/fns> · reads:<tables> · pre:<prior migrations this depends on>
-- <One-paragraph "why" — the operator directive or audit finding driving this>
--
-- ## Regression risk
-- <Which release_health_check() categories could this affect? "None" is a valid answer but it must be stated.>
--
-- ## Already applied to prod
-- Applied via MCP at <timestamp>. Idempotent (CREATE OR REPLACE / IF NOT EXISTS / DO blocks).
```

The header tells future-you and the next agent what the migration was for, what to smoke-test, and that it's already in prod. Prevents the "wait, did this apply?" question.

---

## 4. Apply-then-codify discipline

Reality on Terminal-2: A1 applies migrations via MCP `apply_migration` first, then codifies as a file in `supabase/migrations/`. This is faster than file-first + remote-apply for solo work, BUT it creates a drift window. Mitigations:

1. **Apply + codify within the same conversation turn.** Never end a session with prod ahead of repo.
2. **Every applied migration gets a corresponding file before the session-ending commit.** Run `git diff supabase/migrations/` against a fresh `mcp list_migrations` to confirm parity.
3. **The migration filename must equal the slot it occupies in prod.** Timestamp/slot collision rules → `MIGRATION_CONVENTIONS.md §3`.
4. **PR description references the applied state.** Use the "## Already applied to prod" footer convention.

---

## 5. CREATE OR REPLACE VIEW guard

The R2 pattern (views silently reverting to SECDEF) is preventable by:

- Any migration that does `CREATE OR REPLACE VIEW public.x` MUST follow with `ALTER VIEW public.x SET (security_invoker = true);` in the same migration body.
- The `release_health_check().views.security_definer_views` row will catch this if forgotten — but the discipline is to not forget.

A helper view-creator function would automate this. **Punch-list**: `public.create_or_replace_invoker_view(p_name text, p_sql text)` that wraps the two statements together.

---

## 6. RPC pattern: inspect-before-build

The R3 pattern (TickPick column mapping bugs) came from coding the RPC against an assumed payload shape. Going forward, for any new external-source ingest:

1. **One-shot probe first**: `pg_net.http_get` the live endpoint, capture the response in `net._http_response`, inspect 1–2 rows for actual field names + types before authoring the RPC.
2. **Field-name comments in the RPC body**: `o->>'wholesale_price'  -- TickPick has no top-level 'total'; this is the seller payout`. Future readers see the rationale.
3. **Keep `raw` jsonb in every order/listing/snapshot table**: lets us re-derive missed columns without re-pulling from upstream when we discover a mapping bug.

---

## 7. Vault hygiene

R4 pattern (TEVO_SECRET vs TEVO_API_SECRET):

1. **`get_app_secret` allowlist is the registry.** Any vault entry not in the allowlist is dead weight. **Punch-list**: a `release_health_check()` row "vault_orphans" — entries in `vault.secrets` not referenced by `get_app_secret` allowlist.
2. **Never edit a vault entry inline without updating the allowlist + every fn that references the name.** A rename or new-name rotation is a real coordination event; do it in a migration so the audit trail exists.
3. **Credentials NEVER paste in chat.** Use vault URLs. If a credential ends up in chat (mistake or otherwise), rotate immediately — see today's APPSCRIPT_INGEST_SECRET incident for the pattern.

---

## 8. Cross-lane diagnosis cadence

R5 (TickPick token took multiple hypotheses) — generalizable lesson: when an upstream returns 401/403, the cheap eliminations BEFORE assuming credential mismatch:

1. **Send the same token to httpbin** — confirms wire transmission is clean (rules out pg_net mangling).
2. **Spoof Google's User-Agent** — confirms UA filtering isn't the cause.
3. **Compare source IPs** — pg_net (AWS), Apps Script (Google), local Python (residential). Different egresses; if A works and B fails on the same token, suspect IP allowlist.
4. **Decode the token if it looks like a JWT** — header structure tells you signing alg + kid; truncated/header-only tokens decode to incomplete JSON.

Document the decision in `bot_chat` so future sessions don't redo the hunt.

---

## 9. bot_chat aging policy

Today's audit found 20 unresolved items in `bot_chat`, 10 of which were already implicitly addressed but never marked resolved. Going forward:

1. **A1 mid-session sweep**: every 3rd or 4th task, run `SELECT * FROM bot_chat WHERE resolved_at IS NULL AND event_type IN ('question','flag') ORDER BY created_at` and resolve anything the current session addressed.
2. **Daily aging report**: any item unresolved >7 days surfaces in a daily `release_health_check()` row (TBD — `coordination.bot_chat_aging_7d`).
3. **Resolution is cheap**: use the existing `bot_chat_resolve(p_id, p_resolver_level, p_resolver_lane, p_note)` helper; the note is the audit trail.

---

## 10. PR sequencing rules

R2 was a sequencing problem: PR #94 (sweep) and PR #92 (phase 15b) merged in an order that defeated #94's protection.

- **When a sweep PR is in flight, downstream PRs that touch the same surface** (here: views in `public`) must rebase + retest after the sweep merges, not before.
- **A1 reviews migration order in PR description.** "This depends on X" / "This may regress sweep Y if applied first" — surfaced in plain text.
- **Smoke harness runs in CI on PR merge.** If R2 had re-fired the harness post-merge, the SECDEF views regression would have shown up before downstream surface impact.

---

## Punch-list to fully realize this doc

| # | Item | Owner | Cost |
|---|---|---|---|
| P1 | GitHub Action: daily `migration_drift_check()` join vs `supabase/migrations/*.sql` filenames | A1 | 1 session |
| P2 | `public.create_or_replace_invoker_view(name, sql)` helper | A1 | small |
| P3 | `release_health_check()` extension: vault_orphans + bot_chat_aging_7d categories | A1 | small |
| P4 | Migration template stub committed to `supabase/migrations/_template.sql` | A1 | trivial |
| P5 | Pre-commit hook running `pg_format` + header-line check on new migration files | A1 | medium |

Track in next session's kanban.

---

## 11. Anti-drift checklist (added 2026-05-14)

Operator directive: "plan to decrease code drift and push all to main".

### Per-migration discipline (every time you apply a change)

1. **Before**: `SELECT * FROM public.release_health_check() WHERE status <> 'ok';` — note the rows so you know your baseline.
2. **Apply via MCP**: `apply_migration` with the same SQL you're about to write to `supabase/migrations/<name>.sql`.
3. **Codify in the SAME conversation turn**: write the migration file to disk. The filename must match the MCP migration name. Header comment must include `Already applied to prod via MCP <timestamp>`.
4. **After**: `release_health_check()` again. Any new `fail`/`warn` row that wasn't in step 1 = your migration introduced a regression. Roll back or follow up with a targeted fix.
5. **Commit + push within the same session.** Never end a session with prod ahead of repo.

### Per-session discipline (always)

- **Branch must merge to main within 24h** of last commit OR explicit deferral note in `bot_chat`.
- **A1 is sole pusher to main.** Subordinates open PRs against supervisor branch.
- **No "ghost" migrations.** Every `apply_migration` MCP call must have a corresponding `.sql` file with matching content within the same turn.

### Drift detection (runtime)

`SELECT * FROM public.migration_drift_check();` returns last 100 prod-applied migrations. CI workflow (P1 above, still pending) joins this against `ls supabase/migrations/*.sql` to detect:
- Applied to prod but no file → "ghost" migration; codify retroactively
- File exists but not applied → either pending or stale; reconcile

Until P1 ships, run drift check manually at session end.

### Push-to-main cadence (added 2026-05-14)

| Condition | Action |
|---|---|
| Single migration, low risk, smoke tested | A1 commits to feature branch + fast-forward merge to main same session |
| Multi-migration session (like 2026-05-14: 9+ migrations) | A1 commits to feature branch + opens PR against main + merges after read-through. Fast-forward preferred over merge-commit |
| Migration touches `vault.*` / `cron.*` / `auth.*` | Always PR + operator review before merge |
| Migration deprecates or renames a function/view used by other lanes | PR + flag to other lane owners via `bot_chat` first |
| Session ends with unmerged work | `bot_chat` flag stating reason + ETA for merge |

**This session (2026-05-14) merge plan**:
- Branch `claude/aq-event-map-cross-source-pk` has 11+ migrations spanning matcher / venue+performer maps / listings linkage / cron policy gate / tiered polling / Pattern A deltas / weather+ESPN backfill ops.
- All applied to prod, all codified, all health-checked.
- Merge to main via fast-forward after final commit.

---

Owner: A1.
