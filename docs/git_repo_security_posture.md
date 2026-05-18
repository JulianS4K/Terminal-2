# Git Repo Security Posture — Terminal-2

**Owner**: B1 (Security Manager) · **Last full sweep**: 2026-05-18 (post Phase 2 operator quick wins — 6 findings closed) · **Update cadence**: per-session sweep step 12 + 14 (see [`b1_operating_constraints.md`](b1_operating_constraints.md))

Living snapshot of GitHub repo security + maintenance configuration. B1 diffs current `gh api` output against this doc to catch regressions AND to track which GitHub capabilities are utilized vs available.

---

## Active findings (open, 2026-05-17)

Original sweep G-1 through G-8 unchanged from 2026-05-15 baseline. Expanded with G-9 through G-19 from the 2026-05-17 capabilities audit.

### Original sweep (2026-05-15)

| # | Severity | Finding | Action |
|---|---|---|---|
| G-1 | SEC-HIGH | Repo `visibility: public` AND historic `CRON_SECRET` literal in commit `5297739` (now-rotated, but readable on the internet). | [B1-NEXT-11]. Operator decides `git filter-repo` window. |
| G-2 | SEC-MED | ~~`dependabot_security_updates: disabled`~~ ✅ **CLOSED 2026-05-18** — operator enabled. 0 open alerts on first scan. |
| G-3 | SEC-MED | `secret_scanning_non_provider_patterns: disabled` — **DEFERRED 2026-05-18**: requires GitHub Advanced Security (GHAS) on individual public repos. Push protection (free tier) + gitleaks CI cover the gap. Reopen if repo moves to org with GHAS. |
| G-4 | SEC-MED | `secret_scanning_validity_checks: disabled` — **DEFERRED 2026-05-18**: same GHAS-paid gate as G-3. |
| G-5 | SEC-MED | No CodeQL / code-scanning analysis (`code-scanning/alerts` returns 404). | [B1-NEXT-4]. Decision deferred. |
| G-6 | SEC-LOW | `enforce_admins: false` — admin can bypass branch protection. | [B1-NEXT-15]. Operator-only. |
| G-7 | SEC-LOW | `required_signatures: false` — commits not GPG-signed. | [B1-NEXT-16]. |
| G-8 | SEC-LOW | Actions `sha_pinning_required: false` — third-party Actions tag-pinned. | [B1-NEXT-17]. |

### Capabilities audit expansion (2026-05-17)

| # | Severity | Finding | Action |
|---|---|---|---|
| G-9 | SEC-LOW | `allow_forking: true` on public repo. Forks clone full history including the leaked `CRON_SECRET` commit `5297739`. Compounds G-1. | [B1-NEXT-40]. Operator decision — typically allow_forking stays true unless concerned about derivative works; the real fix is G-1 history-rewrite. |
| G-10 | SEC-LOW | ~~`delete_branch_on_merge: false`~~ ✅ **CLOSED 2026-05-18** — operator enabled. |
| G-11 | SEC-LOW | `has_wiki/projects/downloads: true` — **SUPERSEDED 2026-05-18** by operator "use to fullest extent" directive. Wiki + Projects now intentionally enabled. Discussions added (was false → true). Downloads stays on (no operational impact). |
| G-12 | SEC-MED | ~~No `SECURITY.md` security disclosure policy.~~ ✅ **CLOSED 2026-05-18** by [PR #219](https://github.com/JulianS4K/Terminal-2/pull/219) — `.github/SECURITY.md` published. |
| G-13 | SEC-LOW | No `LICENSE` file. Public repo without license = full copyright reserved (US default). Proprietary code; intentional. README footer should call this out. | Document, no action. |
| G-14 | SEC-LOW | Branch protection — `required_approving_review_count` not set, CODEOWNERS review not required, `dismiss_stale_reviews` not set. Currently any user with push access (only `JulianS4K`) can merge to `main` without explicit review. | [B1-NEXT-44]. Operator decision — single-operator profile may or may not require formal review gate. |
| G-15 | SEC-LOW | `required_conversation_resolution: false` on branch protection. PRs can merge with unresolved review comments. | [B1-NEXT-45]. Operator-only. |
| G-16 | SEC-LOW | ~~No private vulnerability reporting enabled.~~ ✅ **CLOSED 2026-05-18** — operator enabled. SECURITY.md "preferred" link now resolves. |
| G-17 | SEC-LOW | ~~No `actions/dependency-review-action` in CI.~~ ✅ **CLOSED 2026-05-18** by [PR #219](https://github.com/JulianS4K/Terminal-2/pull/219) + Dependabot enable (G-2). Workflow now active on PRs touching `requirements.txt` / `workflows/*`. |
| G-18 | SEC-LOW | ~~No OSSF Scorecard workflow.~~ ✅ **CLOSED 2026-05-18** by [PR #219](https://github.com/JulianS4K/Terminal-2/pull/219) — `.github/workflows/scorecard.yml` runs Mondays 12:00 UTC. |
| G-19 | SEC-LOW | ~~No `.github/dependabot.yml` for version updates.~~ ✅ **CLOSED 2026-05-18** by [PR #219](https://github.com/JulianS4K/Terminal-2/pull/219) + Dependabot enable (G-2). Weekly pip + gh-actions schedule active. |

No SEC-CRIT findings.

---

## Section 7 — Available capabilities NOT YET utilized

Audit of GitHub features available to this repo that aren't currently in use, organized by purpose. Each entry: capability, current state, recommended action, who-can-do.

### Security capabilities (12 items)

| Capability | Current | Recommendation | Owner |
|---|---|---|---|
| CodeQL code-scanning | Not enabled (G-5) | Add `.github/workflows/codeql.yml` after operator approves B1-NEXT-4 | B1 authors, Operator approves |
| Dependabot security updates | Disabled (G-2) | Enable via Settings → Code security | Operator |
| Dependabot version updates | No `dependabot.yml` (G-19) | Add `.github/dependabot.yml` with weekly pip+gh-actions schedule | B1 authors (after G-2) |
| Secret scanning non-provider patterns | Disabled (G-3) | Enable; catches `CRON_SECRET`, `APPSCRIPT_INGEST_SECRET` shapes | Operator |
| Secret scanning validity checks | Disabled (G-4) | Enable; confirms whether leaked tokens still active | Operator |
| Private Vulnerability Reporting (PVR) | Not enabled (G-16) | Enable; gives researchers a private channel | Operator |
| Repository Security Advisories | Not used | Draft CVE workflow when first vuln surfaces; no setup needed | Operator (per-incident) |
| dependency-review-action workflow | Missing (G-17) | Add as PR check after Dependabot enabled | B1 authors |
| OSSF Scorecard | Missing (G-18) | Add `.github/workflows/scorecard.yml` — weekly score + badge | B1 authors |
| Required CODEOWNERS review | Not set on branch protection (G-14) | Branch protection rule update | Operator |
| Required conversation resolution | Disabled (G-15) | Branch protection rule update | Operator |
| Dismiss stale reviews | Not set (G-14) | Branch protection rule update | Operator |
| SHA pinning for Actions | Disabled (G-8) | Enable + convert workflow refs from `@v4` → `@<sha>` | Operator + B1 |
| Required commit signatures | Disabled (G-7) | Operator decision; single-operator profile makes low-priority | Operator |
| Enforce admins on branch protection | Disabled (G-6) | Operator decision; bypass acceptable for single-op | Operator |

### Maintenance capabilities (8 items)

| Capability | Current | Recommendation | Owner |
|---|---|---|---|
| Auto-delete head branches | Disabled (G-10) | Enable; saves manual cleanup (B1 deleted 14 orphans 2026-05-17) | Operator |
| Auto-merge | Disabled | Could enable with required reviews + green CI to free operator time | Operator |
| Stale PR/issue closer workflow | Missing | Low priority — bots don't generate stale PRs (squash-merged quickly) | Skip unless needed |
| PR labeler workflow | Missing | Auto-label by branch prefix (`a1/*` → `level:admin`, `claude/d0-*` → terminal). Reduces manual labeling. | B1 authors |
| PR size labeler | Missing | Flag mega-PRs (e.g., >500 LOC). Low priority. | Skip |
| `SECURITY.md` | Missing (G-12) | Author at `.github/SECURITY.md`: report channel = bot_chat or GitHub PVR (after G-16) | B1 authors |
| `CONTRIBUTING.md` | Missing | Author at `.github/CONTRIBUTING.md`: bot-only contributions; for outside contributors, route to `bot_chat`. Mostly aspirational since this is internal. | B1 authors (low pri) |
| `LICENSE` | Missing (G-13) | Proprietary; intentional. README footer notes "proprietary, internal use." | None |

### Observability capabilities (4 items)

| Capability | Current | Recommendation | Owner |
|---|---|---|---|
| GitHub Insights tab | Available, not actively reviewed | Per-session B1 sweep could spot-check Insights → Traffic for unusual external access | B1 (manual web view; no API access for traffic data without admin scope) |
| Workflow run history | Available via `gh run list` | Already used ad-hoc; could add to per-session sweep as step 21 if needed | B1 |
| Actions usage report | Org-level only | N/A (user repo, not org) | N/A |
| Dependency graph | Implicit via Dependabot when enabled | Will activate when G-2 enabled | Auto |

### Workflow / process capabilities (3 items)

| Capability | Current | Recommendation | Owner |
|---|---|---|---|
| Rulesets | None (`repos/.../rulesets` returned empty) | Newer than branch protection; more flexible (file-path restrictions, commit message regex). Branch protection currently covers needs — defer until specific use case. | Future |
| Required workflows | Org-level only | N/A (user repo) | N/A |
| Repository topics | Empty | Add: `ticket-trading`, `fastapi`, `supabase`, `multi-bot`, `claude-code` for discoverability. Or leave empty if intentionally low-profile. | Operator |
| Repository description | `null` | Add 1-line description visible on GitHub homepage. Currently shows blank under repo name. | Operator |

---

## Section 8 — Recommended next steps (prioritized)

### Quick wins (operator, ~5 min total via web UI)

1. **`delete_branch_on_merge: true`** — Settings → General → "Automatically delete head branches"
2. **Enable Dependabot security updates** — Settings → Code security → Dependabot
3. **Enable secret-scanning non-provider patterns** — Settings → Code security
4. **Enable secret-scanning validity checks** — Settings → Code security
5. **Enable Private Vulnerability Reporting** — Settings → Code security
6. **Disable `has_wiki`, `has_projects`, `has_downloads`** if unused — Settings → General → Features
7. **Add repo description + topics** — Settings → General

### B1-authored follow-ups (after operator quick wins)

1. `.github/SECURITY.md` — vuln disclosure policy referencing PVR + bot_chat
2. `.github/dependabot.yml` — weekly pip + gh-actions version updates
3. `.github/workflows/dependency-review.yml` — block PRs adding vulnerable deps (after Dependabot live)
4. `.github/workflows/scorecard.yml` — OSSF Scorecard weekly run + badge
5. `.github/workflows/labeler.yml` — auto-label PRs by branch prefix (`a1/*`, `claude/d0-*`, etc.)

### Operator-only larger decisions

1. CodeQL — B1-NEXT-4 still pending evaluation
2. Branch protection tightening (required reviews + CODEOWNERS + conversation resolution) — G-14/15
3. SHA pinning for Actions — G-8
4. History rewrite for leaked `CRON_SECRET` — G-1

---

## Section 1 — Branch protection on `main`

Source: `gh api repos/JulianS4K/Terminal-2/branches/main/protection`

| Setting | State | Notes |
|---|---|---|
| Required status checks | ✅ ENABLED, strict mode | Contexts: `pytest`, `check`, `scan` |
| Required signatures | ❌ disabled | G-7 |
| Enforce admins | ❌ disabled | G-6 |
| Required linear history | ❌ disabled | Acceptable; merge commits allowed |
| Allow force pushes | ✅ BLOCKED | |
| Allow deletions | ✅ BLOCKED | |
| Block creations | ❌ disabled | Default behavior; non-issue |
| Required conversation resolution | ❌ disabled | PR comments don't need to be resolved at merge |
| Lock branch | ❌ disabled | |
| Allow fork syncing | ❌ disabled | |

---

## Section 2 — Repo-level settings

Source: `gh api repos/JulianS4K/Terminal-2`

| Setting | State | Notes |
|---|---|---|
| `visibility` | **public** | G-1 |
| `private` | false | |
| `default_branch` | `main` | |
| `allow_squash_merge` | true | Multi-strategy allowed; not security-critical |
| `allow_merge_commit` | true | |
| `allow_rebase_merge` | true | |
| `allow_auto_merge` | false | Defensive default — auto-merge would land PRs without manual gate |
| `allow_update_branch` | false | |
| `delete_branch_on_merge` | false | Hygiene; orphan branches accumulate but no security risk |
| `web_commit_signoff_required` | false | DCO not enforced; OK for single-operator |

### security_and_analysis

| Feature | State | Notes |
|---|---|---|
| `secret_scanning` | ✅ enabled | |
| `secret_scanning_push_protection` | ✅ enabled | Pushes containing detectable secrets are blocked |
| `secret_scanning_non_provider_patterns` | ❌ disabled | G-3 |
| `secret_scanning_validity_checks` | ❌ disabled | G-4 |
| `dependabot_security_updates` | ❌ disabled | G-2 |

---

## Section 3 — Hooks, deploy keys, collaborators

Source: `gh api repos/JulianS4K/Terminal-2/{hooks,keys,collaborators}`

| Surface | State |
|---|---|
| Webhooks | None (empty) ✅ |
| Deploy keys | None (empty) ✅ |
| Collaborators | `JulianS4K` only — admin, maintain, pull, push, triage ✅ |

---

## Section 4 — GitHub Actions configuration

Source: `gh api repos/JulianS4K/Terminal-2/actions/permissions` + `.../actions/permissions/workflow`

| Setting | State | Notes |
|---|---|---|
| Actions enabled | ✅ true | |
| `allowed_actions` | `all` | All Actions allowed. Could tighten to `selected` with allowlist; low priority since single-operator. |
| `sha_pinning_required` | ❌ false | G-8 |
| `default_workflow_permissions` | `read` ✅ | Workflows get read-only `GITHUB_TOKEN` by default; individual workflows opt-in to write |
| `can_approve_pull_request_reviews` | false ✅ | Workflows cannot self-approve PRs |

### Active workflows

| Workflow | Trigger | Purpose | B1 review status |
|---|---|---|---|
| `forbidden-paths-check.yml` | PR | Author-gate on backend files | Reviewed (A1-authored) |
| `sync-check.yml` | push main + daily + manual | Migration / edge-fn drift detection | Reviewed (A1-authored) |
| `tests.yml` | PR (per PR #126) | pytest test gate | Reviewed (D-tier reorg, PR #126) |
| `secret-scan.yml` | PR + weekly + manual | gitleaks secret scanning | Authored by B1 (PR #118) |

### Actions secrets (names only — values never logged)

Per `gh api repos/JulianS4K/Terminal-2/actions/secrets`: query returned empty list at sweep time. This likely indicates the secrets configured for `sync-check.yml` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PAT`) are present but the API was filtered, OR they aren't set.

**Action**: B1 to verify with operator next session that workflow-required secrets are populated. If not set, `sync-check.yml` fails silently — track as [B1-NEXT-18].

---

## Section 4b — Slack integration surface

No active Slack integration in the repo or repo-level GitHub Apps. Slack references are incidental (`docs/security-runbook-2026-05-11.md` mentions Slack DM as an out-of-band password-delivery channel; `COWORKER_ONBOARDING.md` directs coworkers to GitHub issues over Slack).

### Probes (per-session)

| Area | Command | Current state |
|---|---|---|
| Slack tokens / webhooks in repo | `gitleaks` via `.github/workflows/secret-scan.yml` (catches `xoxb-*`, `xoxp-*`, etc.) + grep for `hooks.slack.com/services/`, `SLACK_*` env names | 0 findings |
| Slack-posting workflows | `grep -liE 'slack' .github/workflows/*.yml` | None |
| Slack GitHub App | `gh api repos/JulianS4K/Terminal-2/installation` (requires admin scope; returned 401 with current token) | Unable to verify without operator-scope token; track [B1-NEXT-21] |
| Webhooks pointing to Slack | `gh api repos/JulianS4K/Terminal-2/hooks` | Empty list |

No findings. Future Slack workspace monitoring requires operator to install a Slack MCP — filed as [B1-NEXT-21].

## Section 5 — Security alerts (open, 2026-05-15)

| Surface | Open count | Notes |
|---|---|---|
| Secret-scanning alerts | 0 (empty result) ✅ | Push-protection has been blocking — good |
| Code-scanning alerts | N/A — no analysis configured | G-5 / [B1-NEXT-4] |
| Dependabot alerts | N/A — disabled | G-2 / [B1-NEXT-12] |

---

## Section 6 — Sweep SQL / commands (reference)

```bash
# Branch protection
gh api repos/JulianS4K/Terminal-2/branches/main/protection

# Full repo settings
gh api repos/JulianS4K/Terminal-2 --jq '{private,visibility,default_branch,security_and_analysis,allow_auto_merge,allow_update_branch,web_commit_signoff_required}'

# Webhooks (expect empty)
gh api repos/JulianS4K/Terminal-2/hooks --jq '.[] | {id,name,events,active,url:.config.url}'

# Deploy keys (expect empty)
gh api repos/JulianS4K/Terminal-2/keys

# Collaborators (expect only JulianS4K)
gh api repos/JulianS4K/Terminal-2/collaborators --jq '.[] | {login,permissions}'

# Actions config
gh api repos/JulianS4K/Terminal-2/actions/permissions
gh api repos/JulianS4K/Terminal-2/actions/permissions/workflow

# Actions secrets (names only)
gh api repos/JulianS4K/Terminal-2/actions/secrets --jq '.secrets[] | {name,created_at,updated_at}'

# Alerts (require admin scope)
gh api "repos/JulianS4K/Terminal-2/secret-scanning/alerts?state=open"
gh api "repos/JulianS4K/Terminal-2/code-scanning/alerts?state=open"
gh api "repos/JulianS4K/Terminal-2/dependabot/alerts?state=open"
```
