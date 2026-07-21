# Multi-agent workflow — switching coding agents at will (on-demand reference)

> **Not a session-start bible.** Read this when you want to alternate between coding agents
> (Claude Code, Copilot, Codex, Cline, Cursor, …) on this repo — locally in VS Code or elsewhere —
> without losing the guardrails or stepping on in-flight work. The **rules** every agent must obey live
> in [`../AGENTS.md`](../AGENTS.md) (which mirrors `CLAUDE.md §1–3`); this doc is the **operations
> manual** for the handoff. Rules → `AGENTS.md`. Procedure → here. One fact, one home.

---

## 1. Why this exists

Only Claude Code auto-loads `CLAUDE.md`. Every other agent reads its own config file — or nothing. If
you switch agents casually, the new agent is blind to the SQL-read-only rule, the broker-client
GET-only invariant, the closed-doc registry, and lane scope. This doc makes switching **safe and
repeatable**: keep the per-agent configs in parity, hand off through the git working tree, and let CI
be the backstop for anything an agent misses.

## 2. Agent roster + config parity

Each agent inherits the guardrails from a different file. **When a rule changes, update every row** —
the canonical source is `CLAUDE.md §1–3` / `AGENTS.md`; the rest are thin pointers to it.

| Agent | Install surface | Config file it reads | In this repo |
|---|---|---|---|
| Claude Code | CLI / VS Code extension / web | `CLAUDE.md` (auto-loaded) + `.claude-plugins/` skills | ✅ canonical |
| GitHub Copilot | VS Code extension | `.github/copilot-instructions.md` | ✅ pointer → `AGENTS.md` |
| Cursor | VS Code fork (separate app) | `.cursor/rules/*.mdc` | ✅ `terminal2.mdc` |
| Codex / Cline / Continue / most others | VS Code extension | `AGENTS.md` (root, de-facto standard) | ✅ canonical mirror |

If you add an agent that reads some other file, add a row here **and** a thin pointer file for it that
says "read `AGENTS.md` first," then update the parity table. Never let an agent run configless.

## 3. The switch protocol (the "at will" part)

All agents share **one git working tree** — that is the handoff surface. To pass a task from agent A to
agent B:

1. **Commit or stash before you switch.** Never hand off a dirty tree mid-thought — the next agent
   can't tell your intent from half-applied edits. `git add -p && git commit -m "wip: <what>"` or
   `git stash push -m "<what>"`.
2. **One agent edits at a time.** Two agents writing the same files concurrently corrupts the tree.
   Switch sequentially; don't run parallel agents on the same branch. (Parallel work → separate
   branches / git worktrees, one agent each.)
3. **Point the new agent at the task, not the history.** Give it the goal + the files; it reads
   `AGENTS.md` → `PROJECT_BIBLE.md` for context. It does not need your previous agent's chat log.
4. **Review the diff on every handoff.** `git diff` (or the VS Code Source Control gutter) before the
   next agent builds on it. Lane discipline means you eyeball cross-lane leakage yourself — no agent
   guarantees it.
5. **Run the gates before you push** (§5), regardless of which agent produced the code.

## 4. Which agent for what (guidance, not law)

- **Claude Code** — the default here: it's the only one that loads the `.claude-plugins/` skills
  (`ship-a-migration`, `check-poll-mapping-health`) and the full lane/permission model. Use it for
  migrations, guard-sensitive work, and anything touching the broker clients or DB.
- **Copilot / inline-completion agents** — fast local authoring of UI/wiring inside a single lane.
- **Cursor / Cline / Codex** — larger multi-file refactors when you want a different model's take; the
  shared tree + `AGENTS.md` keep them inside the rails.
- **Anything read-only** (SQL investigation, "explain this") — any agent; no guardrail exposure.

## 5. Backstop — the CI gates catch what an agent misses

The *convention* rules (lane scope, cross-lane writes) rely on the agent reading `AGENTS.md`. The
*hard* rules are enforced mechanically and are `--no-verify`-proof, so a rogue agent's bad edit fails
at the PR gate no matter which agent made it. Run them locally first:

| Gate | Command |
|---|---|
| Tests + 100% coverage ratchet | `AUTH_DISABLED=true SUPABASE_URL=https://example.invalid SUPABASE_SERVICE_ROLE_KEY=test-key TEVO_TOKEN=test TEVO_SECRET=test PYTHONPATH=. pytest tests/ --cov --cov-branch --cov-fail-under=100` |
| Readonly-guard audit (broker clients GET-only) | `python scripts/check_readonly.py` |
| Docs registry (closed doc set) | `bash bin/check-docs.sh` |
| Canonical-doc tables | `python scripts/check_md_tables.py` |
| Frontend lint (no raw `innerHTML`) | `npm run lint:all` |

## 6. Keeping the configs in parity

The failure mode is drift: you tighten a rule in `CLAUDE.md` but forget the Copilot/Cursor/AGENTS
mirrors, and an alternate agent runs on a stale rule. Guard against it:

- Treat `CLAUDE.md §1–3` + `AGENTS.md` as the **single source**; the other config files only ever say
  "read `AGENTS.md`" plus a short agent-specific reminder — never a full copy that can drift.
- When you change a hard rule, grep the mirrors and update them in the same PR:
  `git grep -l "read.*AGENTS.md" .github .cursor` → the pointer files to re-check.

## 7. Where to look next
- The rules themselves → [`../AGENTS.md`](../AGENTS.md) · full lockdown → `../CLAUDE.md §1–3`
- Lane ownership map → `../PROJECT_BIBLE.md §2`
- Git/repo security posture → [`git_repo_security_posture.md`](git_repo_security_posture.md)
- Build/run the D0 terminal locally → [`d0_terminal_build.md`](d0_terminal_build.md)
