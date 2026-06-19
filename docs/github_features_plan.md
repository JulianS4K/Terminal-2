# GitHub Features Plan — Terminal-2

**Owner**: B1 (Security Manager) · **Status**: 2026-05-18 — Phase 2 operator quick wins partially landed (4 of 7 toggles); Phase 3 content seeding now unblocked for Discussions + PVR-backed Security tab

Operator directive 2026-05-17: *"use git to its fullest extent including using discussions tab, projects tab, wiki tab and securities and quality tab and others that may assist in quality and productivity."*

This doc maps every GitHub surface to a concrete proposed use within Terminal-2's multi-bot operation, plus the operator-action needed to enable each one. Phase 1 (files in this PR) lands without operator settings changes; Phase 2/3 wait on operator enable.

---

## Surface-by-surface plan

### 🔒 Security tab — ENABLED (partially utilized) → fully utilize

**What it is**: GitHub's centralized view of all security signals: SECURITY.md policy, secret-scanning alerts, code-scanning alerts (CodeQL), Dependabot alerts, security advisories.

**Current state**: secret-scanning + push-protection ENABLED; everything else disabled.

**Phase 1 (this PR)**:
- ✅ Added [`.github/SECURITY.md`](../.github/SECURITY.md) — vulnerability disclosure policy + response SLA + scope
- ✅ Added [`.github/dependabot.yml`](../.github/dependabot.yml) — inert until operator enables (G-2)
- ✅ Added [`.github/workflows/dependency-review.yml`](../.github/workflows/dependency-review.yml) — inert until operator enables (G-2)
- ✅ Added [`.github/workflows/scorecard.yml`](../.github/workflows/scorecard.yml) — OSSF Scorecard, weekly cron, results to code-scanning + public scorecard.dev

**Phase 2 (operator must enable in Settings → Code security)** — **STATUS as of 2026-05-18**:
1. ✅ Dependabot security updates (G-2 / B1-NEXT-12) — **ENABLED 2026-05-18**, 0 open alerts on first scan
2. ✅ Dependabot security alerts — companion to #1
3. ⏸️ Secret scanning non-provider patterns (G-3 / B1-NEXT-13) — **DEFERRED** (GHAS-paid feature, not available on free individual public repo)
4. ⏸️ Secret scanning validity checks (G-4 / B1-NEXT-14) — **DEFERRED** (same GHAS gate)
5. ✅ Private Vulnerability Reporting (G-16 / B1-NEXT-46) — **ENABLED 2026-05-18**, SECURITY.md PVR link now resolves
6. 🟡 CodeQL (G-5 / B1-NEXT-4) — pending operator decision; adds `codeql.yml` workflow when chosen

**Phase 3 (after Phase 2 lands)**:
- Repository Security Advisories — draft CVE entries when first vuln surfaces (per-incident, no setup)
- Surface scorecard.dev badge in README
- Tie B1 sweep step 14 (code-scanning alerts) to the new CodeQL alerts

---

### 💬 Discussions tab — DISABLED → enable

**What it is**: Async threaded conversations, separate from Issues. Categorized. Searchable.

**Current state**: `has_discussions: false` (disabled).

**Why enable for Terminal-2**: bot_chat handles transactional cross-lane coordination. Discussions can handle:
- Long-form decisions / RFCs (currently scattered across `docs/audit-*.md`)
- Operator broadcasts that should be discoverable later (currently scattered between bot_chat broadcasts and Slack)
- Cross-bot knowledge base (Q&A — searchable past questions, replaces re-asking)

**Phase 2 — operator enables** (Settings → General → Features → Discussions) — ✅ **ENABLED 2026-05-18**, tab now live

**Phase 3 — B1 seeds these categories**:

| Category | Format | Purpose | Example seed posts |
|---|---|---|---|
| 📢 **Announcements** | Announcement | Operator → all bots, durable broadcasts. Pinnable. | "Multi-bot reorg 2026-05-15", "Testing-unified architecture (PR #168)" |
| 💡 **Ideas** | Open-ended | RFC-style proposals before code lands. Discussion ≠ commitment to ship. | "Should we add a Kalshi integration?", "Move D0 to its own service post-beta?" |
| 🤝 **Coordination** | Open-ended | Cross-lane design discussion too long for bot_chat. | "How should D1 and D2 share the `evo_orders` table for storefront returns?" |
| 📊 **Decisions** | Open-ended | Operator decisions with rationale. Replaces some `docs/audit-*.md`. | "Why we picked Render over Railway", "Why allow_forking stays true" |
| ❓ **Q&A** | Q&A (mark answer) | Knowledge base. Bots and humans search past questions. | "Why is sg_event_id 0% populated on listings_snapshots?" |
| 🎯 **Show and tell** | Show and tell | Bot demos / completed features for human visibility. | "D0 event-page v3 — 9 enrichment panels", "B1 cron heartbeat detector" |
| 🗳️ **Polls** | Poll | Operator-side multi-choice decisions. | "Cron heartbeat threshold: 2x median, 3x, or 5x?" |
| 💬 **General** | Open-ended | Misc | (catch-all) |

**Seed content B1 prepares** (one-shot when Discussions go live):
- `docs/seed/discussions/announcements_pinned_overview.md` — pinned "Read me first" overview
- `docs/seed/discussions/decisions_*.md` — 3-5 historical decisions converted from `docs/audit-*.md`

---

### 📋 Projects tab — ENABLED (empty) → populate

**What it is**: Projects v2 — kanban / table / roadmap views over Issues + PRs with custom fields.

**Current state**: `has_projects: true` but no projects exist.

**Why use for Terminal-2**: KANBAN.md `§🟢 OPEN` is the source-of-truth (markdown, append-only). A GitHub Project mirrors it as a VISUAL board with auto-flow. The two coexist:
- KANBAN.md = canonical, structured, search-by-text, populates manually
- Project = visual, filtered views, auto-close on PR merge, drag-and-drop

**Phase 2 — operator creates a Project**:
1. Repo → Projects tab → New project → "Board" template
2. Name: "Terminal-2 Open Work"
3. Configure custom fields (B1 documents below)
4. Configure automation (auto-add new issues + auto-close on PR merge)
5. Set visibility (probably "Public" to match repo, "Private" if operator prefers)

**Phase 3 — B1 populates**:

**Custom fields** to add:
| Field | Type | Values |
|---|---|---|
| Lane | Single select | A1, B1, C1, D0, D1, D2, D3, D4, E1, Operator |
| Severity | Single select | SEC-CRIT, SEC-HIGH, SEC-MED, SEC-LOW, OPS, Product |
| Status | Single select | Triage, In Progress, Blocked, Ready for Review, Done |
| Blocked on | Text | (free-form, e.g., "G-2 Dependabot enable") |
| KANBAN ID | Text | B1-NEXT-N or other lane's ID |
| Originating PR | Number | PR number that surfaced this |

**Views** (saved query configs):
1. **By severity** (board) — columns: SEC-CRIT / HIGH / MED / LOW / OPS
2. **By lane** (board) — columns: A1 / B1 / C1 / D-tier / Operator
3. **By status** (board) — columns: Triage → In Progress → Blocked → Ready for Review → Done
4. **Operator-only** (table) — filter: Lane=Operator
5. **My queue** (table) — filter: Assignee=@me
6. **Roadmap** (timeline) — by `Originating PR` date

**Automation rules** (built-in):
- New Issue → auto-add to project, default Status=Triage
- PR opened with `closes #N` → linked issue moves to "Ready for Review"
- PR merged → linked issue moves to "Done"
- Issue closed → Status=Done

**B1 syncing protocol**:
- For each row in KANBAN §🟢 OPEN, B1 creates a matching Issue with the same ID in title (e.g., "B1-NEXT-43: Author SECURITY.md disclosure policy")
- Issue body links to the KANBAN row
- Issue auto-adds to project via automation
- When fixing bot ships PR with `closes #N`, both Issue + KANBAN row close (KANBAN row deleted per existing protocol; Issue closed by GitHub)

---

### 📖 Wiki tab — ENABLED (empty) → populate

**What it is**: Git-backed markdown wiki. Separate repo (`Terminal-2.wiki.git`). Sidebar navigation.

**Current state**: `has_wiki: true` but empty.

**Why use for Terminal-2**: Some content benefits from being detached from `main` (no CI on every change, no review gate). Good candidates:
- New-bot onboarding flow (read-frequently, edit-rarely)
- Architecture diagrams + glossary
- Operator runbooks (recovery procedures, deploy steps)
- FAQ — "Why did we do X?"

**Caveats**:
- Wiki is PUBLIC because repo is public. **Don't put secrets, internal IPs, vault names, or speculative roadmap there.**
- No CI / no review — anyone with write access can edit. CODEOWNERS doesn't apply.

**Phase 2 — operator initializes the wiki**:
1. Click the Wiki tab
2. Create the first page (auto-creates the `.wiki.git` repo)

**Phase 3 — B1 seeds these pages**:

| Wiki page | Purpose | Source content |
|---|---|---|
| **Home** | Sidebar TOC + project overview | Adapted from README.md |
| **Bot directory** | One page per bot (A1, B1, ...) with role + lane + write surface | Synthesized from `PROJECT_BIBLE.md §2` + each bot's `*_operating_constraints.md` |
| **Architecture** | Component diagram, data flow, hosted services | From PROJECT_BIBLE.md §2 + RESOURCES_BIBLE.md §1 |
| **Glossary** | A→Z definitions: AQ, broker firehose, listings_snapshots, etc. | Mined from migration headers + bibles |
| **New-bot bootstrap** | First-session checklist | Pointer to PROJECT_BIBLE.md + KANBAN §🟢 OPEN + this wiki Home |
| **Operator runbooks** | Recovery procedures: "Edge function failing", "Cron silent for >24h", "Render service red" | Synthesized from existing runbooks |
| **TEvo gotchas (full)** | Extended version of PROJECT_BIBLE.md §3 with examples | Aggregated from migration comments |
| **FAQ** | "Why did we ____?" — operator/A1 decision rationale | Mined from audit docs + commit messages |

**Update cadence**: B1 syncs wiki monthly (lower priority than bibles). Major architectural changes trigger a wiki refresh PR.

---

### 🐛 Issues tab — ENABLED (lightly used) → expand

**What it is**: Standard issue tracker. Labels, milestones, assignees, projects, linked PRs.

**Current state**: `has_issues: true`. Labels exist (`bug`, `enhancement`, `level:admin` ... `level:data-collection`, etc.). Few issues filed historically — bots use bot_chat instead.

**Why expand**:
- External contributors / users need an inbound channel (Issues are public-facing; bot_chat isn't)
- Long-running tasks (e.g., "Implement real-purchase checkout") work better as Issues with milestones than bot_chat threads
- Issues link bidirectionally to PRs (`closes #N`) for traceability

**Phase 1 (this PR)**:
- ✅ Added [`.github/ISSUE_TEMPLATE/bug.yml`](../.github/ISSUE_TEMPLATE/bug.yml)
- ✅ Added [`.github/ISSUE_TEMPLATE/feature.yml`](../.github/ISSUE_TEMPLATE/feature.yml)
- ✅ Added [`.github/ISSUE_TEMPLATE/config.yml`](../.github/ISSUE_TEMPLATE/config.yml) — disables blank issues, links to Security/Discussions/KANBAN

**Phase 2 — B1 creates 1 Issue per row in KANBAN §🟢 OPEN**:
- Tagged with `level:*` label per lane
- Body links to KANBAN §🟢 OPEN row + relevant docs
- Adds to "Terminal-2 Open Work" project (Phase 3 of Projects tab)
- When PR ships, `closes #N` removes the KANBAN row + closes the Issue

**Phase 3** — Milestones for sprint planning:
- "Beta launch" milestone — pulls all blocker Issues into one view
- "Q3 2026" / monthly cadence milestones for non-blocker work

---

### 🚀 Actions tab — ENABLED (4 workflows) → 8 workflows + improvements

**What it is**: CI / scheduled workflows.

**Current state**: 4 active — `forbidden-paths-check.yml`, `sync-check.yml`, `tests.yml`, `secret-scan.yml`.

**Phase 1 (this PR — 4 new workflows)**:
- ✅ [`.github/workflows/scorecard.yml`](../.github/workflows/scorecard.yml) — weekly OSSF Scorecard
- ✅ [`.github/workflows/labeler.yml`](../.github/workflows/labeler.yml) — auto-label PRs (paths + branch prefix)
- ✅ [`.github/workflows/dependency-review.yml`](../.github/workflows/dependency-review.yml) — block PRs adding vulnerable deps (inert until G-2)
- ✅ [`.github/workflows/pr-title-lint.yml`](../.github/workflows/pr-title-lint.yml) — enforce `<type>(<lane>): <msg>` format

**Phase 2 (after operator enables CodeQL)**:
- `.github/workflows/codeql.yml` — SAST scanning, results to Security tab

**Phase 3 (nice-to-have)**:
- `release-drafter.yml` — auto-draft release notes from merged PRs
- `stale.yml` — close abandoned issues/PRs (low priority — bots squash-merge fast)

---

### 🏷️ Releases / Tags — UNUSED → use for production checkpoints

**What it is**: Git tags + release notes published on the Releases page.

**Current state**: No tags, no releases.

**Why use**:
- Anchor "what's in production right now" — currently you can't quickly answer "what was running on 2026-05-15?" without `git log`
- Operator can hand-cut releases as production-freeze checkpoints
- Release notes auto-generated from merged PRs (with `release-drafter` workflow)

**Phase 2 — operator cuts the first tag**:
```bash
git tag -a v0.1.0-beta -m "Pre-launch beta — multi-bot orchestration, testing-unified architecture"
git push origin v0.1.0-beta
```

**Phase 3 — B1 authors `release-drafter.yml`** that auto-drafts the next release on every merge to main.

---

### 📊 Insights tab — READ-ONLY → integrate into B1 sweep

**What it is**: Code frequency, contributors, traffic (clones + visitors), pulse, dependency graph, network, forks.

**Current state**: All available; not actively monitored.

**Phase 2 — B1 integrates into per-session sweep**:
- New sweep step 21: "Insights anomaly check" — manual web-view of Traffic + Forks tabs; flag if visitor count >10× baseline or new fork from an unknown account
- Set up a weekly digest scheduled task (B1) that posts to `#terminal-2-alerts` if Pulse shows >50% drop in commit activity or >2x increase in fork count

---

### 🔧 Other capabilities being utilized

| Capability | Current | Plan |
|---|---|---|
| Branch protection on `main` | ENABLED | Tighten per G-14/G-15 (operator decision) |
| CODEOWNERS | ENABLED | Keep as-is (`@JulianS4K` owns everything) |
| PR template | ENABLED | Already comprehensive (per `docs/pr_governance.md`) |
| Topics + description | EMPTY | Operator adds: `ticket-trading`, `fastapi`, `supabase`, `multi-bot`, `claude-code` + 1-line description |
| GitHub Pages | NOT IN USE | Defer — wiki covers public-facing docs needs |
| Sponsors / FUNDING.yml | NOT APPLICABLE | Single-operator proprietary |
| Co-pilot integration | Operator-side | (No repo-level config) |

---

## Cumulative operator-action checklist

**Quick wins** — STATUS as of 2026-05-18:

1. Settings → Code security:
   - ✅ Dependabot security updates (enabled 2026-05-18)
   - ⏸️ Secret-scanning non-provider patterns (DEFERRED — GHAS-paid)
   - ⏸️ Secret-scanning validity checks (DEFERRED — GHAS-paid)
   - ✅ Private Vulnerability Reporting (enabled 2026-05-18)
   - 🟡 CodeQL → "Default" setup (pending operator decision)

2. Settings → General → Features:
   - ✅ Discussions ON (enabled 2026-05-18)
   - ✅ Wiki kept ON per fullest-extent directive (B1 will seed)
   - ✅ Projects kept ON per fullest-extent directive (B1 will create board)
   - ✅ Automatically delete head branches (enabled 2026-05-18)

3. Settings → General → Pull Requests:
   - 🟡 "Always suggest updating pull request branches" — pending operator
   - 🟡 Allow auto-merge — pending operator decision

4. Settings → General → repo metadata:
   - ⏸️ Description + topics — SKIPPED 2026-05-18 (operator noted UI didn't surface these fields)

5. 🟡 Repo → Projects tab → New project "Terminal-2 Open Work" — pending operator

6. 🟡 Repo → Wiki tab → Create first page — pending operator

7. ✅ Repo → Discussions tab — operator enabled 2026-05-18, B1 to seed categories

**After operator quick wins** — B1 follow-up PRs:
- B1 authors `.github/workflows/codeql.yml` (after CodeQL enabled)
- B1 seeds Discussions categories + first few posts
- B1 seeds Wiki pages (Home, Bot directory, Architecture, Glossary, Runbooks, FAQ)
- B1 creates Issues mirroring KANBAN §🟢 OPEN rows + auto-adds them to the Project
- B1 cuts first `v0.1.0-beta` tag with release notes

---

## Files added in this PR (Phase 1)

```
.github/
├── SECURITY.md                          ← Security tab
├── CONTRIBUTING.md                      ← Issues tab + new-contributor onboarding
├── dependabot.yml                       ← Security tab (inert until G-2)
├── labeler.yml                          ← PR labeler config
├── ISSUE_TEMPLATE/
│   ├── bug.yml
│   ├── feature.yml
│   └── config.yml
└── workflows/
    ├── scorecard.yml                    ← OSSF Scorecard weekly
    ├── labeler.yml                      ← PR auto-label by paths + branch prefix
    ├── dependency-review.yml            ← Block vulnerable deps in PRs (inert until G-2)
    └── pr-title-lint.yml                ← Enforce PR title format

docs/
└── github_features_plan.md              ← This doc
```

---

**Refresh cadence**: B1 updates this doc when:
- Operator enables one of the Phase 2 items (mark complete inline)
- New GitHub feature releases that's worth evaluating
- Quarterly review (next: 2026-08)
