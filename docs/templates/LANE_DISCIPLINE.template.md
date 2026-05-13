# LANE_DISCIPLINE.md — TEMPLATE for multi-bot projects

> **How to use:** Copy this file to `LANE_DISCIPLINE.md` at your repo root. Replace every `<<…>>` placeholder. Delete any lane (`A1`, `B1`, etc.) you don't need; rename them to match your project's structure. The companion `BOT_HIERARCHY.md` template is the quick-reference matrix; this doc holds the per-lane operating detail.
>
> **Origin:** This template is generalized from the Terminal-2 multi-bot ticketing project (2026-05-13 lockdown). The core ideas: explicit per-lane write surfaces, single-writer-per-table rule, security/governance separation, and an explicit cross-cutting "deploy infrastructure" ownership section.

---

# LANE_DISCIPLINE.md — per-lane operating rules

Each bot writes only to its assigned files / tables / crons / edge functions. Out-of-lane writes require PR comment to the lane owner first.

**Companion to `BOT_HIERARCHY.md`** (repo root) — that doc is the quick-reference: hierarchy diagram, push restrictions matrix, single-writer table ownership, fast-path workflow. **This doc is the detail**: per-lane writes / never-writes / function-call rules / client-response filters.

**Per-bot self-contracts** sit one layer below this. Bots may author their own deep operational detail file at `docs/<bot>_operating_constraints.md`.

When a per-bot doc exists, it MUST be consistent with this doc and `BOT_HIERARCHY.md`. If a conflict surfaces, this doc + BOT_HIERARCHY.md win until reconciled.

See also: `docs/bot-hierarchy.mermaid` (visual diagram) and `MIGRATION_CONVENTIONS.md` (migration / commit conventions that overlay this scope map).

## Lane assignments

| ID  | Lane                         | Active bot   | Status |
|-----|------------------------------|--------------|--------|
| A1  | Admin / Audit / Push         | `<<bot-id>>` | active |
| B1  | Security Manager             | `<<bot-id>>` | active |
| C1  | Supervisor / Coordination    | `<<bot-id>>` | active |
| D1  | <<surface-1-name>>           | `<<bot-id>>` | active |
| D2  | <<surface-2-name>>           | `<<bot-id>>` | active |
| Dn  | <<surface-n-name>>           | unassigned   | future |

## Per-lane restrictions

### A1 — Admin / Audit / Push

**Writes:**
- Core backend files shared across lanes (coordinate before edit)
- Foundation migrations (schema, canonical data, cross-lane infra)
- Governance docs: `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, `<<other-governance-docs>>`
- Ledger reconciliation in `<<migration-ledger-table>>`
- Cron schedules in audit-lane namespace

**Reads:** everything.

**Authority:**
- Sole pusher to `main`
- Reviews all PRs against `MIGRATION_CONVENTIONS.md §<<n>>` checklist
- Approves merges

### B1 — Security Manager

**Writes (cross-cutting allowed):**
- Security backlog (`KANBAN.md` or equivalent)
- Security runbooks (`docs/security-runbook-*.md`)
- Hand-apply gate set: `docs/proposed-migrations/*_security_*.sql`
- Auto-apply set: `<<migrations-dir>>/*_security_*.sql`
- Shared auth helpers (`<<auth-shared-dir>>`)
- Per-lane patches for security CRIT/HIGH (must coordinate via PR comment to lane owner)

**Reads:** everything.

**Authority:**
- Middle-man review between supervisor (C1) and admin (A1) for security-sensitive PRs
- Resolves `event_type IN ('p0_security', 'flag')` in coordination table
- Owns hand-apply gate for sensitive migrations (RLS, secret rotations, etc.)

### C1 — Supervisor / Coordination

**Writes:**
- Supervisor-lane migrations (xref governance, queue health views, sweep functions)
- Cross-lane coordination table (`bot_chat` or equivalent) — schema + helper functions
- Audit docs in `docs/*-audit-*.md`, `docs/*-handoff-*.md`
- Lane discipline + supervisor protocols (this file)

**Reads:** everything.

**Authority:**
- Supervises subordinate lanes (D1+)
- Routes signals to/from A1, B1
- Logs change_log / sync rows in coordination table on each PR landing

### D1 — <<surface-1-name>>

**Writes (source files):**
- `<<lane-specific-files>>` (coordinate with A1 on shared files)
- `<<lane-specific-static-assets>>`
- `<<lane-specific-tables>>` migrations
- Coordination table writes if D1 owns chat-style surface

**Never writes (source files):**
- Other lanes' source files
- Edge functions outside the lane's namespace
- Infrastructure migrations shared across lanes

**May invoke (server-side function calls):**
- Other lanes' read-safe functions when the use case is read-only/search
- `*_public` RPCs designed for the consumer surface
- Lane-appropriate views (e.g. `<<retail_*>>` views)

**Never invokes:**
- Lane-private RPCs (admin / internal / brokerage-only)
- Direct upstream API paths that return privileged data

**Must filter from any client response:**
- `<<sensitive-fields>>` (e.g. wholesale prices, internal cost, brokerage IDs)
- `<<provenance-flags>>` that reveal internal inventory position
- Tokens, secrets, vault references
- Raw upstream rows that haven't been filtered through a `*_public` wrapper
- Any column not whitelisted by an explicit public-RPC

**Filter pattern:** call public-RPC → response only contains client-safe fields → serialize that to client. Never dump raw privileged rows.

**Reads:** core context tables shared across lanes.

**Owns deploy infra:**
- `<<deploy-target-name>>` (sole owner — see Cross-cutting Rule #6). Other subordinates are explicitly barred from this deploy surface.

### D2 / D3 / Dn — additional subordinate lanes

Follow the D1 pattern. Each subordinate lane should declare:
- **Writes** — exact files, tables, crons
- **Never writes** — explicit list of forbidden surfaces
- **Reads** — context tables it can query
- **Owns deploy infra** — if any, or "none" if shared

## Cross-cutting rules

1. **Shared files** — propose changes via PR comment to the owner before editing:
   - `<<shared-backend-file>>` (A1 owns; subordinates have specific namespaces)
   - Dependency pinning files (A1 owns pinning shape; lanes add own deps)
   - Governance docs (`MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, this file)
   - Hierarchy visualizations (C1 maintains)
   - Security backlog (B1 + A1 share)

2. **Single-writer per table** — see `MIGRATION_CONVENTIONS.md §<<n>>`. Each table has one owning lane that writes; others read.

3. **Security cross-cutting exception** — B1 may patch any file when fixing a security CRIT/HIGH, but must surface the patch via PR comment to the affected lane.

4. **Out-of-lane writes** — require PR comment to lane owner before push. If lane owner is offline, surface as `flag` in coordination table for B1 / A1 resolution.

5. **SECURITY DEFINER convention** (or your platform's equivalent privileged-function pattern) — every new privileged function must ship in one migration with:
   - `REVOKE EXECUTE ... FROM PUBLIC, <<unprivileged-roles>>`
   - Explicit `GRANT EXECUTE ... TO <<service-role>>`
   - Body-level `current_user` (or equivalent) assertion at function entry
   - All three lines together, every time

6. **Deploy infrastructure ownership** — per-lane infra exclusivity:
   - **`<<deploy-target-A>>`** — owned by `<<lane>>` exclusively. Specifies what deploys here, who can provision services, modify env vars, configure crons, etc. No other lane may push/deploy here without explicit operator approval.
   - **`<<deploy-target-B>>`** — current legacy deploy or shared platform. Governance: `<<who-owns-it>>`.
   - **`<<data-platform>>`** — shared platform; per-table ownership via `MIGRATION_CONVENTIONS §<<n>>`. RLS / access coverage maintained by B1.
   - **Future lanes** — when scope activates, lane gets its own deploy target. Choice deferred until then.

7. **Operator-lockdown rules (global)** — apply to every bot, supersede prior MCP-applied autonomy:
   - **SQL/database writes** — read-only by default. Need explicit operator permission for any `INSERT` / `UPDATE` / `DELETE` / DDL / `apply_migration` against prod. Exceptions: coordination-table writes via designed helper functions (standing permission); database branch creation (copy-on-write, no prod mutation); migration file authoring (application separately gated).
   - **Upstream third-party APIs (every integration)** — read-only by default. Search / GET endpoints OK. Order creation, holds, reservations, inventory mutations, webhook config, seller-side config — all require explicit authorization. Applies uniformly to every `*_client.py` integration regardless of upstream provider (ticketing APIs, data brokers, scraping targets, etc.).
   - **HTML / UI / wiring** — free reign on lane-assigned UI files. Build, iterate, refactor without per-step approval. Operator may explicitly route HTML work to a bot outside its default lane (this is the override path; document the routing).

## Enforcement

- A1 catches violations during §<<n>> review
- B1 catches security-class violations
- C1 catches lane-discipline violations in supervised work
- All violations logged as `flag` in coordination table; resolved by B1 (security findings) or A1 (governance)

---

## Template usage notes

- **Renaming lanes:** keep the A1/B1/C1 + D-series pattern even if you rename them; the hierarchy depth (admin → security → supervisor → subordinates) maps to most projects.
- **Project without security manager:** delete B1; have A1 do double duty. The CRIT/HIGH lockdown gate still applies, just under A1's name.
- **Project with just one subordinate:** delete D2+. Keep D1's pattern; it's the read/write/invoke/filter scaffolding that matters.
- **No deploy infra split:** delete Cross-cutting Rule #6 entirely. Keep Rule #7 — that's the operator lockdown and is platform-agnostic.
- **No coordination table:** strip references to `bot_chat`; substitute PR comments. The operating rules don't depend on a shared table, just on a place to surface cross-lane signals.
