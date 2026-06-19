# Edit Coordination Protocol — file-level claim/release via `bot_chat`

Authored by D0 (2026-05-15) under the consolidated-frontend consolidation. Polite-protocol layer to prevent two bot sessions editing the same file at the same time across worktrees / lanes.

## TL;DR

Before editing a file **outside your direct write surface** (per [PROJECT_BIBLE.md §2](../PROJECT_BIBLE.md)), post a `bot_chat` `sync` event with `meta.action='claim'`. After commit, post a `release`. Other bots check active claims before starting. Auto-expire after `meta.expires_at` so crashes don't strand the file.

Uses existing `bot_chat_log()` + `sync` event_type — **no DDL, no schema change**. Adoption is per-lane choice; enforcement is by convention + PR review.

## When to use

**Required** for cross-lane edits (D0 editing `static/store/*` or `d2_dashboard/*`, etc.) and for any file in the per-service deploy infra (`render*.yaml`, `app.py`, migration filenames).

**Optional** within your direct write surface — your own worktree's surface rarely collides with other lanes.

**Not used** for `bot_chat` writes (already serialized at DB layer) or for `docs/<lane>_*.md` files (single-author by convention).

## Claim event

```sql
SELECT bot_chat_log(
  '<your bot_level>',              -- 'data-collection' for D0/D1/D2, 'admin' for A1/C1, 'security' for B1
  '<your bot_lane>',               -- 'Terminal FE', 'D1', 'D2', 'A1', etc.
  'sync',                          -- event_type
  '<one-line intent>',             -- e.g. "claim static/store/store.js — fix nav bug"
  NULL, NULL, NULL,                -- related_pr, related_mig, in_reply_to
  jsonb_build_object(
    'action', 'claim',
    'path',   '<glob or exact path>',           -- e.g. 'static/store/store.js' or 'static/store/**'
    'expires_at', (now() + interval '30 minutes')::text,
    'intent', '<one-line description>',
    'worktree', '<your worktree name, optional>'
  )
);
```

Returns the `chat_id` — record it; you'll reference it in the release.

**Defaults**: 30-minute window. Renew with a fresh `claim` on the same path if you need longer.

## Release event

```sql
SELECT bot_chat_log(
  '<your bot_level>', '<your bot_lane>', 'sync',
  'released claim <chat_id>',
  NULL, NULL, <claim_chat_id>,                  -- in_reply_to points to the claim row
  jsonb_build_object('action', 'release')
);
```

## Check-before-claim

Active claims = `sync` rows with `meta.action='claim'`, not yet expired, with no matching `release` or `revoke` in reply.

```sql
WITH claims AS (
  SELECT id, created_at, bot_lane,
         meta->>'path'   AS path,
         meta->>'intent' AS intent,
         (meta->>'expires_at')::timestamptz AS expires_at
  FROM bot_chat
  WHERE event_type = 'sync'
    AND meta->>'action' = 'claim'
    AND (meta->>'expires_at')::timestamptz > now()
),
closed AS (
  SELECT in_reply_to AS claim_id
  FROM bot_chat
  WHERE event_type = 'sync'
    AND meta->>'action' IN ('release', 'revoke')
    AND in_reply_to IS NOT NULL
)
SELECT id, bot_lane, path, intent, expires_at
FROM claims c
WHERE c.id NOT IN (SELECT claim_id FROM closed)
  AND (<your_path> LIKE c.path OR c.path LIKE '%' || <your_path> || '%')   -- naive glob match; tighten in your check
ORDER BY created_at DESC;
```

If rows return: another lane has the file. Don't claim. Options:
1. Wait for expiry / release
2. Post a `bot_chat` `question` event referencing the active claim — coordinate timing
3. If urgent + claim looks stale (long past expected work), ask A1 to `revoke`

## Revoke event (A1 / B1 only)

```sql
SELECT bot_chat_log(
  'admin', 'A1', 'sync',
  'revoke claim <chat_id> — <reason>',
  NULL, NULL, <claim_chat_id>,
  jsonb_build_object('action', 'revoke', 'reason', '<one-line>')
);
```

## Conflict resolution

- **Two simultaneous claims** on overlapping paths: lower `chat_id` wins (DB-order is the tiebreaker). The later claimer should release immediately and wait.
- **Bot crashes mid-edit**: claim auto-expires. Next claimer takes over after `expires_at`.
- **Long edit**: post a new `claim` 5 minutes before expiry with the same `path` and a new `expires_at`. Reference the prior claim in `meta.renews`.
- **Force-take** (rare): A1 or B1 posts `revoke`. Original claimer gets a `flag` ping; should pause.

## What this does NOT do

- **Enforcement**: this is polite-protocol. A bot can edit without claiming. Detection is post-hoc via PR review or git blame.
- **Sub-file granularity**: claim is path-level. Two bots editing different functions in the same file still conflict.
- **Schema integrity**: doesn't help with concurrent migration timestamp collisions (see C1's filename collision finding, `bot_chat` row 144).

## Future hardening (cross-lane to A1 / B1)

- **View `v_active_claims`**: wrap the check-before-claim SQL into a view. Reduces query duplication; same anon read access as `v_bot_chat_unresolved`.
- **Pre-commit hook**: `.githooks/pre-commit` that queries `v_active_claims` for staged file paths and blocks the commit if another lane has an active claim. Repo-wide infra; A1 authors.
- **Slack/Discord webhook**: post claim/release to a coordination channel for human visibility.
- **Expiry sweep**: nightly cron that emits a `flag` for any claim still un-released >2× its window (likely crashed bot).

## Adoption

D0 announces this protocol with a `bot_chat` `sync` event tagged for D1, D2, B1, C1, A1 — each lane acks (or pushes back) via reply. Adoption is voluntary; the protocol exists because cross-lane editing is now common enough (D0 sign-off + D-tier consolidation) to need a coordination layer.

## References

- [PROJECT_BIBLE.md §2](../PROJECT_BIBLE.md) — table + push ownership
- [PROJECT_BIBLE.md §2](../PROJECT_BIBLE.md) — per-lane write surface
- [CLAUDE.md](../CLAUDE.md) — `bot_chat_log` standing permission (project-wide)
- `bot_chat` row 157 — D-level reorg that motivated this protocol
- `bot_chat` row 144 — C1's migration filename collision audit (related coordination drift)

## Revision history

- 2026-05-15: initial — defines claim / release / revoke semantics; check-before-claim SQL; future hardening proposals
