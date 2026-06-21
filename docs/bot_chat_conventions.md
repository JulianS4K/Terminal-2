# `bot_chat` Conventions

Author: C1. First version: 2026-05-15 (part of Cluster D of the audit + consolidation plan).

`public.bot_chat` is the canonical cross-lane coordination surface. This doc codifies how to use it so the unresolved view stays a signal, not noise. Pairs with [CLAUDE.md](CLAUDE.md) §"Global operator rules" and [PROJECT_BIBLE.md §2](PROJECT_BIBLE.md §2).

## Canonical `bot_lane` values

| Value | Meaning |
|---|---|
| `A1` | Admin / push lane |
| `B1` | Security / test-prod lane |
| `C1` | Drift monitor / checkpoint lane |
| `D0` | Terminal FE |
| `D1` | Consumer retail |
| `D2` | Order clients (orders-dashboard) |
| `D3` | Broadway |
| `D4` | Future / reserved |
| `P1` | Product lane (if used) |
| `Operator` | Manual operator action (not a bot) |

**Casing is significant**: use uppercase letter + digit. As of 2026-05-15 the table contains drift values (`c1`, `Audit/Push`, `Terminal FE`, `canonical`) — these predate this convention and should be migrated to canonical via a one-time operator-authorized `UPDATE` in Cluster D-2.

`p_level` (lower-cased descriptive label of the bot's level in the hierarchy):
- `admin` — A1, B1, C1, S1 (the supervisor tier)
- `data-collection` — D0–D4 (the lane tier)
- `secondary-sales` — historical, see migration notes

## Event types (schema-enforced)

The `bot_chat_event_type_check` constraint enforces this set:
`change_log | question | flag | sync | status | collision | broadcast | p0_security`

| Type | Meaning | Typical resolution |
|---|---|---|
| `change_log` | A historical record of work that landed. Not "open" — informational. | Resolved on creation; no follow-up expected. |
| `broadcast` | An announcement that all lanes should see. | Resolved when the audience has read it (sweep after 48h). |
| `flag` | Open issue, needs investigation. | Resolved when the issue is fixed or rejected. |
| `question` | Asking for input from a specific lane. | Resolved when answered. |
| `sync` | Checkpoint / state snapshot. | Resolved on next checkpoint or after 24h. |
| `status` | A reply or status update. Usually `in_reply_to` an open `flag` or `question`. | Resolved with the parent. |
| `collision` | Two lanes wrote to the same surface; investigation required. | Resolved when ownership is decided. |
| `p0_security` | Security-class drift. Pages B1 immediately. | Resolved when patch lands. |

> **Note (drift item 2026-05-15)**: The C1 daily checkpoint runbook references `event_type='checkpoint'`, but that value is **not** in the constraint allowlist. Until that's reconciled (Cluster A), use `status` for the Step 8 daily summary entry. The constraint or the runbook must change — operator + A1 decide which.

## Closing entries — `bot_chat_resolve()`

`bot_chat_resolve(p_id, p_resolver_level, p_resolver_lane, p_note)` sets `resolved_at` and `resolved_by_*` columns. Use this — not just a `status` reply — to close an entry. A `status` reply that doesn't also call `bot_chat_resolve()` leaves the row in `v_bot_chat_unresolved` indefinitely.

**Anti-pattern observed today** (2026-05-15, ~50% of replies): A1 posts an `event_type='status'` with `in_reply_to=<flag_id>` describing the fix, but does not call `bot_chat_resolve(<flag_id>)`. The flag stays unresolved forever. Example: id 129 (A1 fix to bot_chat 128 §A) — 128 is still in the unresolved view.

**Three options** for fixing this (decision pending, plan §"Open questions" Q2):
1. Update `v_bot_chat_unresolved` to auto-exclude rows that have a `status` reply with `in_reply_to=<row.id>`. Lowest friction.
2. Require A1 (and all replying lanes) to also call `bot_chat_resolve()` after each `status` reply. More explicit; more steps.
3. Refactor to use `bot_chat_resolve()` as the canonical close — `status` events become rare. Cleanest model; requires retraining.

C1 recommendation: option 1 — the view is cheap to change and reflects intent.

## When to use `flag` vs `question` vs `status`

| Situation | Use |
|---|---|
| Found a bug or drift that needs investigation | `flag` |
| Need a specific decision or piece of info from another lane | `question` |
| Replying to someone else's `flag` or `question` | `status` (with `in_reply_to`) |
| Routine work landed (PR merged, migration applied) | `change_log` |
| Important state change everyone should know | `broadcast` |
| Two lanes both edited the same file/table | `collision` |
| Security/auth/RLS regression | `p0_security` (immediate) |

## Sweep protocol — what C1's daily routine does

Daily at the end of the checkpoint:
1. `SELECT id FROM public.bot_chat WHERE resolved_at IS NULL AND event_type IN ('change_log','broadcast') AND created_at < now() - interval '48 hours'` — these are by-nature historical, safe to bulk-resolve
2. For each, call `bot_chat_resolve(id, 'admin', 'C1', 'C1 daily sweep YYYY-MM-DD — historical, no action needed')`
3. Report count in the daily checkpoint summary

Open `flag` / `question` / `collision` / `p0_security` are **never** bulk-resolved by C1 — they need their owners to confirm closure.

## Cross-lane file-claim protocol (2026-05-15, D0-shipped)

When editing a file outside your direct write surface, post a `sync` event with `meta` payload `{action:'claim', path:'<file>', expires_at:'<iso>', intent:'<short>'}` *before* the edit. After commit, post a follow-up `sync` with `meta.action='release'` + `in_reply_to=<claim_id>`. Conflict rule: lower `id` wins; later claimer releases + waits. Stale claims auto-expire (default 30 min). A1/B1 may `revoke`.

Canonical doc: [docs/edit_coordination_protocol.md](docs/archive/edit_coordination_protocol.md) (PR #113, pending merge). C1 adopts the pattern for any future cross-lane writes; in-lane writes (own docs, own conventions) need no claim.

## Related docs

- [CLAUDE.md](CLAUDE.md) §1 — standing permissions on `bot_chat` writes
- [PROJECT_BIBLE.md §2](PROJECT_BIBLE.md §2) — who owns which lane
- [PROJECT_BIBLE.md §2](PROJECT_BIBLE.md §2) — push restrictions matrix
- [docs/c1_daily_checkpoint_runbook.md](docs/archive/c1_daily_checkpoint_runbook.md) — C1's runbook (Step 8 is the bot_chat sweep + summary post)
- [docs/edit_coordination_protocol.md](docs/archive/edit_coordination_protocol.md) — file-claim protocol for cross-lane writes
- **bot_chat 187** (A1, 2026-05-15) — canonical Slack directive: channel matrix (`#terminal-2-alerts` / `#admin` / `#d0`), per-bot posting rules, escalation-via-bot_chat table (`event_type='p0_security'` or `flag` + `meta.severity='high'` → Slack page next hourly aging sweep), loop-prevention rule (Slack-originated posts get replied in bot_chat, not Slack). Aging sweep + daily checkpoint digest are the only writers to `#terminal-2-alerts`. **⚠ Slack posting is DISABLED as of 2026-06-21** — the `terminal-2-*` channels are unreachable in the connected `s4kent` workspace; skip all Slack posts and use `bot_chat` only. Authoritative notice + re-enable steps: `docs/b1_operating_constraints.md` → *Slack posture monitoring*.
