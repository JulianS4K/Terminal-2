# Git Repo Security Posture — Terminal-2

**Owner**: B1 (Security Manager) · **Last full sweep**: 2026-05-15 · **Update cadence**: per-session sweep step 12 + 14 (see [`b1_operating_constraints.md`](b1_operating_constraints.md))

Living snapshot of GitHub repo security configuration. B1 diffs current `gh api` output against this doc to catch regressions.

---

## Active findings (open, 2026-05-15)

| # | Severity | Finding | Action |
|---|---|---|---|
| G-1 | SEC-HIGH | Repo `visibility: public` AND historic `CRON_SECRET` literal in commit `5297739` (now-rotated, but readable on the internet). The KANBAN.md SECURITY BACKLOG "[OPS-ONLY] History rewrite of leaked literal" item was originally scoped assuming private repo. Public posture changes the calculus. | File [B1-NEXT-11] reassessing history-rewrite priority. Operator decides whether to `git filter-repo` + force-push window. |
| G-2 | SEC-MED | `dependabot_security_updates: disabled` (also `dependabot_security_alerts` returns 403 = disabled). After the 2026-05-11 `requirements.txt` unpinning incident (SW-3 in KANBAN), Dependabot is the right tool to keep transitive deps current. | File [B1-NEXT-12]. Operator-only to enable (Settings → Code security). |
| G-3 | SEC-MED | `secret_scanning_non_provider_patterns: disabled` | File [B1-NEXT-13]. Won't catch custom-shaped secrets (e.g., `CRON_SECRET`, `APPSCRIPT_INGEST_SECRET`). Operator-only to enable. |
| G-4 | SEC-MED | `secret_scanning_validity_checks: disabled` | File [B1-NEXT-14]. Wouldn't confirm if a leaked token is still active. Operator-only. |
| G-5 | SEC-MED | No CodeQL / code-scanning analysis exists (`code-scanning/alerts` returns 404 "no analysis found"). | Already filed as [B1-NEXT-4]. Decision deferred; this confirms current state. |
| G-6 | SEC-LOW | `enforce_admins: false` — admin (`JulianS4K`) can bypass branch protection. Acceptable single-operator risk profile, but documented here. | File [B1-NEXT-15] (low-pri, operator-only). |
| G-7 | SEC-LOW | `required_signatures: false` — commits not GPG-signed. Single-operator + GitHub-server-side commits via PR merge make impersonation low-risk. | File [B1-NEXT-16] (low-pri). |
| G-8 | SEC-LOW | Actions `sha_pinning_required: false` — third-party Actions can be referenced by mutable tags (supply-chain vector). Currently using `actions/checkout@v4`, `actions/github-script@v7`, `actions/upload-artifact@v4`, `gitleaks/gitleaks-action@v2` — all tag-pinned. | File [B1-NEXT-17]. Could enable + convert to SHA pins. |

No SEC-CRIT findings.

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
