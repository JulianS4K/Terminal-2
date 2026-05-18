# GitHub Discussions seed content — Terminal-2

**Owner**: B1 (Security Manager · Phase 3 of `docs/github_features_plan.md`)
**Posted**: 2026-05-18 via GraphQL `createDiscussion` mutation
**Categories**: 6 defaults (Announcements / General / Ideas / Polls / Q&A / Show and tell)

Operator's directive 2026-05-17 enabled Discussions tab. B1 seeds these 6 categories with one welcome/anchor post each so visitors land on content, not an empty tab.

> The 2 categories originally proposed (Coordination + Decisions) are not in GitHub's default set. They get folded into General (Coordination uses `[coord]` prefix) + Announcements (Decisions use `[DECISION]` prefix) respectively. Operator can add the 2 categories later via Settings → Discussions if desired.

---

## 📢 Announcements — "Welcome to Terminal-2 Discussions"

Posted to: `Announcements` (slug `announcements`)

**Title**: `Welcome to Terminal-2 — read this first`

**Body**:

```markdown
Terminal-2 is a multi-bot orchestrated ticket-trading intelligence + retail platform. FastAPI + Supabase + Render. This Discussions tab is the place for **async, long-form, threaded** conversation. For transactional cross-bot coordination, the canonical channel is the `public.bot_chat` table inside Supabase.

## Where to find things

| Need | Go to |
|---|---|
| **What can I do?** Hard rules + lane scope + SQL macros | [`PROJECT_BIBLE.md`](../blob/main/PROJECT_BIBLE.md) |
| **What's open right now?** Severity-sorted ledger | [`KANBAN.md §🟢 OPEN`](../blob/main/KANBAN.md) |
| **What exists?** Tables/views/crons/edge-fn inventory | [`RESOURCES_BIBLE.md`](../blob/main/RESOURCES_BIBLE.md) |
| **Who can push where?** | [`BOT_HIERARCHY.md`](../blob/main/BOT_HIERARCHY.md) |
| **Report a security issue** | [Security Advisories (private)](../security/advisories/new) — DO NOT open a public issue for security |
| **Report a bug** | [Issues → "Bug report"](../issues/new?template=bug.yml) |

## How to use Discussions

- 📢 **Announcements** (this category) — Operator broadcasts, decision records, major-change notices. `[DECISION]` prefix marks operator decision records.
- 💡 **Ideas** — Pre-implementation RFCs. Use this for design proposals before code lands.
- 🤝 **General** — Cross-lane coordination too long for bot_chat. `[coord]` prefix marks coordination threads.
- ❓ **Q&A** — Knowledge base. Search past questions before re-asking.
- 🎯 **Show and tell** — Demos of shipped features.
- 🗳️ **Polls** — Operator-side multi-choice decisions.

## Conventions

- One topic per thread. Don't bury new questions inside answered ones.
- Cross-link to `KANBAN.md §🟢 OPEN` row IDs when discussing open work.
- Cross-link to PRs / commits / bot_chat row IDs for traceability.

Welcome.
```

---

## 💡 Ideas — "How to propose a feature or architecture change"

Posted to: `Ideas` (slug `ideas`)

**Title**: `RFC flow — propose changes here before writing code`

**Body**:

```markdown
## When to use Ideas (vs Issues vs bot_chat)

| Surface | Use case |
|---|---|
| **Discussions → Ideas** (here) | Anything that needs **conversation BEFORE code**: architectural shifts, new lanes, schema migrations affecting >1 table, deprecating an RPC, framework changes. The discussion produces a decision; the decision drives the PR. |
| **Issues** | Concrete, scoped feature requests with a clear "done" definition. |
| **`bot_chat` `event_type='question'`** | Transactional cross-lane asks during active work. |

## Light RFC template

When you start a new Idea, copy this scaffold into the body:

```
**Problem**: What's broken / missing / painful? Concrete examples.

**Proposed**: What we'd do. Be specific — file paths, function names, schema changes.

**Alternatives considered**: What else we ruled out + why.

**Impact**:
- Files touched:
- Migrations:
- Cross-lane writes (per `LANE_DISCIPLINE.md`):
- Reversibility:
- Smoke harness expected to change: yes/no

**Open questions**: things the discussion should resolve.
```

The operator (or A1) lands the resolution as a top-level comment with `[DECISION: ship | hold | reject]`. The thread closes when implementation PR merges.

## Past examples to learn from

- The testing-unified architecture (PR #168) — folded D0 + D1 + D2 onto one Render service
- The `match_to_aq_event_id` overload drop (PR #177) — sequencing-regression lesson
- The KANBAN §🟢 OPEN closure protocol (PR #209) — coordination-pattern decision

Start a new thread when you have something to propose.
```

---

## 🤝 General — "Cross-lane coordination here"

Posted to: `General` (slug `general`)

**Title**: `[coord] Cross-lane coordination — when bot_chat is too short`

**Body**:

```markdown
`bot_chat` rows are great for transactional asks ("@A1 — please apply migration X"). But sometimes a coordination thread runs longer:

- Multi-message back-and-forth between D0/D1/D2 about table ownership
- Design conversation with 3+ participants
- "Who owns this surface now that the D-tier reorg happened?"

For those, **post here with `[coord]` prefix**. The thread is durable, searchable, and stays out of the high-traffic bot_chat firehose.

## Conventions

- Title format: `[coord] <topic>` — the prefix makes filtered views easy
- @-mention the affected lanes in the body (e.g., `cc @D0 @D1`) — note GitHub @-mention only works for users, not bot lanes. Use lane names anyway for grep
- Cross-link the originating `bot_chat` row IDs
- When resolved, the operator (or originating bot) posts `[RESOLVED]` as a top-level comment + locks the thread

## What does NOT go here

- Security findings — those go to `bot_chat` `event_type='flag'` + `KANBAN.md §🟢 OPEN`
- Bug reports — those go to GitHub Issues
- Feature proposals — those go to Discussions → Ideas
- Code review — those go on the PR itself
```

---

## ❓ Q&A — Seed FAQ

Posted to: `Q&A` (slug `q-a`)

**Title**: `FAQ — common questions about Terminal-2`

**Body**:

```markdown
Quick-reference for questions that come up repeatedly. Each Q&A here is a top-level Discussion you can search; longer answers might warrant their own thread.

## Q: Why is `seatgeek_sales_snapshots.tevo_event_id` mostly null?

A: SG firehose tables don't carry TEvo IDs natively. Cross-source matching is done lazily via `aq_event_map` + `seatgeek_event_xref`. Always query by `sg_event_id` for SG-side data. PR #178 backfilled 87% of historical rows; new rows are born populated where xref exists (mig 20260517160000). See `PROJECT_BIBLE.md §3` column landmines.

## Q: Why are migrations sometimes applied to prod before the PR exists?

A: 2026-05-13 lockdown protocol — author files first, prod-apply via MCP `apply_migration` is gated separately on operator authorization. Idempotent migrations that A1 has authority over can be applied first, then codified in a PR (with "Already applied to prod" annotation in the migration header). See `MIGRATION_CONVENTIONS.md` + `docs/release-discipline.md`.

## Q: What's the difference between `bot_chat`, KANBAN, this Discussions tab, and Slack?

A: 4-surface map:
- **`bot_chat`** (Supabase table) — durable, append-only, transactional cross-bot coordination
- **`KANBAN.md §🟢 OPEN`** (repo file) — current actionable work, severity-sorted, fixing bot deletes their row when shipped
- **GitHub Discussions** (this tab) — async, long-form, threaded, for design/decision/RFC work
- **Slack** (`#terminal-2-alerts` + `#terminal-2-admin` + `#terminal-2-d0`) — operator-facing real-time signal

When in doubt: `bot_chat` for short, Discussions for long, KANBAN for state.

## Q: What's a "lane"?

A: Terminal-2 has ~10 specialized bot roles ("lanes"): A1 admin, B1 security, C1 canonical, D0 terminal FE, D1 storefront, D2 orders, D3 broadway scraper, D4 ticketing infra, E1 external markets. Each lane has its own write surface per `LANE_DISCIPLINE.md`. Cross-lane writes need coordination via `bot_chat` or PR comment.

## Q: How do I report a security vulnerability?

A: **NOT** via a public issue. Use [Private Vulnerability Reporting](../security/advisories/new). See `.github/SECURITY.md` for the full policy + response SLA.

---

Have another question? Open a new Q&A thread.
```

---

## 🎯 Show and tell — Recent ships

Posted to: `Show and tell` (slug `show-and-tell`)

**Title**: `🎉 Recent ships (May 2026) — terminal v3 + multi-bot governance`

**Body**:

```markdown
Highlights from the May 2026 sprint:

## D0 Terminal frontend
- **PR #196** — event-page tab navigation + 3 full-list tabs + Last Snapshot panel
- **PR #205** — uncapped 3 full-list tabs + new CROSS-SOURCE METRICS panel
- **PR #203** — performer 2-mode + venue page + ESPN context tab
- **PR #202** — full movers table + SG sales column + Blind Spots panel
- **PR #186** — event-page v3: 9 enrichment panels (operator audit followup)

## A1 admin / SG bridge
- **PR #168** — testing-unified architecture (D0 + D1 + D2 mount on one Render service)
- **PR #177** — cross-source venue map + active TEvo search bridge + 2 OPS hotfixes
- **PR #178** — 87% backfill of `seatgeek_sales_snapshots.tevo_event_id`
- **PR #206** — 5 per-event metrics gaps fixed (sentiment + competitors + sections + cost cleanup + owned dist)

## B1 security / governance
- **PR #176** — cron heartbeat detector in `release_health_check()`
- **PR #209** — KANBAN §🟢 OPEN consolidated live ledger + closure-by-deletion protocol
- **PR #217** — GitHub capabilities audit (11 new findings + 27 unutilized features catalogued)
- **PR #219** — GitHub fullest-utilization Phase 1: SECURITY.md + 4 quality workflows + Issue templates
- **PR #229** — 6 G-N findings closed post operator Phase 2 quick wins

## What this enables

- Operator can see broker-level event detail across SG / TEvo / TickPick / Vivid in one view
- Bots' security drift caught + closed within hours of detection (B1 detect → A1 fix loop)
- Public-facing repo hygiene: Dependabot active, PVR live, Discussions tab open

Shipping continues. Watch `KANBAN.md §🟢 OPEN` for what's next.
```

---

## 🗳️ Polls — (skipped, no active poll)

Polls category exists but no current decision needs a poll. B1 will post one when an operator-side multi-choice decision arises (e.g., "Cron heartbeat threshold: 2x median, 3x, or 5x?" if we revisit PR #176's defaults).

---

## Posting protocol (B1 ops)

Each post above is sent via GraphQL:

```graphql
mutation {
  createDiscussion(input:{
    repositoryId: "<repo_id>",
    categoryId: "<category_id>",
    title: "<title>",
    body: "<body>"
  }) {
    discussion { number url }
  }
}
```

Repo ID: `R_kgDOSMegnc` (retrieved via `gh api graphql -f query='query{repository(owner:"JulianS4K",name:"Terminal-2"){id}}'`)

Category IDs:
- Announcements: `DIC_kwDOSMegnc4C9SEq`
- General: `DIC_kwDOSMegnc4C9SEr`
- Ideas: `DIC_kwDOSMegnc4C9SEt`
- Q&A: `DIC_kwDOSMegnc4C9SEs`
- Show and tell: `DIC_kwDOSMegnc4C9SEu`
- Polls: `DIC_kwDOSMegnc4C9SEv` (not used in this seed)

After post: B1 captures the discussion URLs in a follow-up commit to this file under each post heading.

## URLs (filled post-publish)

| Category | Post title | URL |
|---|---|---|
| Announcements | Welcome to Terminal-2 — read this first | _(pending publish)_ |
| Ideas | RFC flow — propose changes here before writing code | _(pending publish)_ |
| General | [coord] Cross-lane coordination — when bot_chat is too short | _(pending publish)_ |
| Q&A | FAQ — common questions about Terminal-2 | _(pending publish)_ |
| Show and tell | 🎉 Recent ships (May 2026) — terminal v3 + multi-bot governance | _(pending publish)_ |
