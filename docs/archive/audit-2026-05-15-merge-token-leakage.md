# Merge Token-Leakage Audit — 2026-05-15

Author: C1. Charter: operator directive ("when you're merging do a full audit on code for token leakage"). Retro-audit of the 3 PRs merged in today's consolidation pass (#111, #110, #116) to seed the pattern catalog in [docs/token-discipline-rules.md](docs/token-discipline-rules.md) §"Pre-merge code audit".

## Migration filename collisions (structural — flagged to A1)

3 files now share filename prefix `20260515300000_*` on main:

| File | PR | Status |
|---|---|---|
| `20260515300000_cron_resume_with_gate_trailing_semicolon_fix.sql` | #112 (merged earlier) | applied (DB version `20260515142436`) |
| `20260515300000_security_secdef_post_pr101_compliance.sql` | #110 (today's pass) | not applied |
| `20260515300000_vivid_orders_aq_linkage.sql` | #116 (today's pass) | not applied |

2 files share `20260515320000_*`:

| File | PR | Status |
|---|---|---|
| `20260515320000_d0_read_access_grants.sql` | #115 | applied (DB version `20260515142444`) |
| `20260515320000_d2_metrics_rpcs.sql` | #116 | not applied |

Per [MIGRATION_CONVENTIONS.md](MIGRATION_CONVENTIONS.md): "On collision, bump +30 or +50. Never +1. Never +100." Convention violated. Apply ordering on prod will be alphabetical by filename suffix (Supabase tooling records `now()` as version at apply-time, not the filename prefix), so this isn't a correctness bug — but it makes "the 20260515300000 migration" ambiguous to anyone grepping. **A1 disposition recommended**: rename `#110` to `20260515300050_*` and `#116`'s d2_metrics_rpcs to `20260515320050_*` before next apply window. Low priority — pre-apply rename is safe; post-apply rename means a new migration to ALTER NOTHING.

## Token-leakage patterns observed

### Pattern 1 — Migration header bloat (PR #110)

`20260515300000_security_secdef_post_pr101_compliance.sql` header is **36 lines** (over the 15-line budget). Substantive content (SEC-HIGH/SEC-MED gap description, regression risk table) is valuable but lives better in the accompanying `docs/security-audit-2026-05-14-post-pr101.md`. The migration header should be the 3-line pointer.

**Biggest single saving**: the `pre:` field lists 10 migration timestamps. Only `20260515220000` (aq_venue_map / aq_performer_map creation) is structurally load-bearing for the RLS section. The other 9 are chronological noise.

### Pattern 2 — File-header docstrings restating PR context (PR #111)

`tests/test_store_home.py` opens with a **23-line docstring** that explains: the design rationale of `/api/store/home` (velocity-signal split), the bug fix for movers comma-pattern, the audit refs (F1, F5, doc §7d/§8). All of this lives in PR #111's description.

**Compress to ~5 lines**: "Tests for /api/store/home (catalog enrichment) and /api/store/movers (comma-pattern fix). Uses FakeSupabaseClient (no real Supabase or TEvo). See PR #111 for design rationale."

### Pattern 3 — Inline comments restating code (PR #116)

`d2_dashboard/main.py` contains comments like:
```python
# Active-only default: hide rows in known-terminal states
# (fulfilled/rejected/cancelled). NULL canonical_status (xref miss on
# an unknown source_status) is treated as active — those usually
# warrant operator attention.
if not include_terminal:
    q = q.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
```

The comment is 4 lines explaining what the next 2-line `if` does, including the NULL-handling. The `or_(...is.null,...in.(...))` reads naturally. **Compress to 1 line**: `# active = NULL canonical_status (unknown) OR not-yet-terminal`.

### Pattern 4 — Near-duplicate wrapper functions (PR #116)

`d2_dashboard/main.py` has `_fetch_evo`, `_fetch_seatgeek`, `_fetch_tickpick`, `_fetch_vivid` — each wraps `_fetch_one_source(source_name, per_page, page)` with one literal-string argument. **Collapse**: route the 4 endpoints to a single handler that takes `source` from the URL path. Saves ~12 lines + future-source linear cost.

### Pattern 5 — Audit refs in code (PR #111)

`tests/test_store_home.py` ends its module docstring with: `Audit ref: F1 (catalog enrichment gap) + F5 (movers comma bug) + docs/d1-bot-continues-here-rustling-sunrise.md §7d / §8.`

The doc reference is a *snapshot* — it points at a session-specific worktree handoff file. In 30 days when someone reads the test, `d1-bot-continues-here-rustling-sunrise.md` will either be archived or stale. **Drop entirely**: the test name + the PR description are the canonical refs.

## Disposition

All findings flagged for next-PR remediation. Retroactive trim is low-priority — these are calibration cases for the rulebook, not blockers.

Lane action items (forward-looking):
- **B1** — next migration: ≤15-line header, `pre:` field only load-bearing deps.
- **D1** — next file: trim test docstrings to 5 lines; cite PR not session docs.
- **D2** — next `main.py` change: collapse near-duplicate wrappers; comments explain WHY not WHAT.

## Estimated savings if rules followed forward

Rough order-of-magnitude per typical PR:
- Migration header: ~25 lines saved (20 → 5)
- Test file docstrings: ~15 lines saved per new test file
- Inline restate-code comments: variable, often ~10-30 lines per substantial file
- Near-duplicate wrappers: usually only 5-15 lines, but compounds with each new variant

Per PR rough estimate: 50-100 lines of pure prose/comment savings. Across a 7-PR week, that's ~500 lines = ~3-5k tokens of read overhead per bot session that reads the codebase.

## Pattern catalog → rulebook

These 5 patterns are now codified in [docs/token-discipline-rules.md](docs/token-discipline-rules.md) §"Pre-merge code audit". Future merges run the audit at PR-merge time; findings ride to lane owners as bot_chat flags.

## Round 2 deeper-audit findings (post-#117/#118 merge)

### Consolidation status on Cluster C RLS-ERROR backlog

The 7 ERROR `rls_disabled_in_public` lints from this morning's `get_advisors` resolve as:

| Table | Status |
|---|---|
| `aq_venue_map` | **fixed** in PR #110 (codified `20260515300000_…`, apply pending) |
| `aq_performer_map` | **fixed** in PR #110 |
| `cron_pause_state_20260514` | **tracked** B1-NEXT-7 (KANBAN.md) |
| `sg_event_priority_state` | **tracked** B1-NEXT-7 |
| `sg_priority_policy` | **tracked** B1-NEXT-7 |
| `cron_policy` | **not in B1-NEXT-7** — likely admin-only (no anon GRANT); lint noise vs real exposure |
| `cron_gate_decisions` | **not in B1-NEXT-7** — same |

The 2 not in B1-NEXT-7 are flagged by `get_advisors` (lint-level: all public tables checked) but not by B1's anon-callable inventory (operational-level: filters by effective anon access). Disposition: either enable RLS with `admin_only` policy (closes the lint, zero behavior change — Cluster A drift infra item) or accept the lint with a documented exception. **C1 recommendation**: enable RLS + admin_only policy in B1's next migration; the 2 tables join F-1/2/3 in `B1-NEXT-7` scope.

### B1 PR #118 doc audit (no leakage findings)

- `docs/b1_operating_constraints.md` (182 lines) — appropriate for a self-contract; matches the C1 + D1 pattern.
- `docs/anon_callable_surface_inventory.md` (168 lines) — a model living-inventory format. Table-based, clear criteria, F-N numbering scheme that scales. Recommend other lanes adopt this pattern when they need a structured "active findings" view.
- `docs/security-audit-2026-05-14-post-pr101.md` (238 lines) — well-organized audit. TL;DR up top, structured findings table, separate verification protocols. Matches the bar set by `audit-2026-05-14-data-stability.md`.

These are *not* token-bloated for their type; they're the right length for what they document.

### Convergent observation on migration collisions

B1's `KANBAN.md` `B1-NEXT-10` independently flagged the same migration slot collisions C1 flagged in bot_chat 144/146. Two independent observers reaching the same finding strengthens the case for the rename pass — both C1 and B1 will track it; A1 picks the resolution window.
