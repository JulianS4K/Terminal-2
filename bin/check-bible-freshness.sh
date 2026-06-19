#!/usr/bin/env bash
# bin/check-bible-freshness.sh
#
# Bible-freshness gate. Forces a bot to update the docs in the SAME PR as a
# change that the bibles are supposed to describe — before it can merge to main.
# Implements RULE 0 ("categorize all new data / keep the doc in the same PR",
# RESOURCES_BIBLE) + the same-PR doc discipline mechanically.
#
# Rule: if the PR touches a "needs-doc" path (a new/changed migration, source
# client, edge function, or deploy IaC) but changes NO canonical doc, FAIL —
# unless the author opts out with a documented reason (see escape hatch).
#
# Escape hatch (for legit no-doc changes — bugfix migration, refactor, etc.):
#   put a line `BIBLE-OK: <reason>` in ANY commit message in the PR range,
#   or set env BIBLE_OK=<reason>. The reason is required (not just the token).
#
# Usage:
#   bin/check-bible-freshness.sh [--base <ref>] [--quiet]
#     --base   ref to diff against (default: origin/main; CI passes the PR base)
#
# Exit: 0 clean/ok · 1 violation (no doc + no opt-out) · 2 config error

set -euo pipefail

BASE="origin/main"
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)  BASE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
log() { [[ $QUIET -eq 1 ]] || echo "$*"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO_ROOT"

# Merge base — tolerate a shallow/cousin history.
if ! MB="$(git merge-base "$BASE" HEAD 2>/dev/null)"; then
  MB="$BASE"  # fall back to the raw ref; diff still works in most CI setups
fi

CHANGED="$(git diff --name-only "$MB"...HEAD 2>/dev/null || git diff --name-only "$MB" HEAD)"
if [[ -z "$CHANGED" ]]; then
  log "✅ bible-freshness: no changes vs $BASE."
  exit 0
fi

# Paths whose change is expected to be reflected in a bible.
#  - migrations  → RESOURCES_BIBLE (inventory) / PROJECT_BIBLE §3 landmines, §4 RPCs
#  - *_client.py → RESOURCES_BIBLE §1 (external services) + §7 RULE 2 client list
#  - edge fns    → RESOURCES_BIBLE §6
#  - deploy IaC  → PROJECT_BIBLE §2.7 (deploy infra)
NEEDS_DOC="$(echo "$CHANGED" | grep -E \
  '^supabase/migrations/.*\.sql$|(^|/)[a-z0-9_]+_client\.py$|^supabase/functions/[^_][^/]*/|render.*\.ya?ml$' \
  || true)"

if [[ -z "$NEEDS_DOC" ]]; then
  log "✅ bible-freshness: no doc-bearing paths touched."
  exit 0
fi

# Did a canonical doc change too? (root *.md = registry docs, or docs/ refs)
DOC_TOUCHED="$(echo "$CHANGED" | grep -E '^[^/]+\.md$|^docs/' || true)"
if [[ -n "$DOC_TOUCHED" ]]; then
  log "✅ bible-freshness: doc-bearing change is accompanied by a doc update."
  exit 0
fi

# Escape hatch — documented opt-out.
REASON=""
if [[ -n "${BIBLE_OK:-}" ]]; then
  REASON="$BIBLE_OK"
else
  # any commit in the range carrying `BIBLE-OK: <reason>`
  REASON="$(git log "$MB"..HEAD --format='%B' 2>/dev/null \
    | grep -iE '^BIBLE-OK:[[:space:]]*\S' | head -1 | sed -E 's/^[Bb][Ii][Bb][Ll][Ee]-[Oo][Kk]:[[:space:]]*//' || true)"
fi
if [[ -n "$REASON" ]]; then
  log "✅ bible-freshness: opt-out accepted — \"$REASON\""
  exit 0
fi

# Violation.
echo "❌ bible-freshness: doc-bearing changes with no doc update and no opt-out." >&2
echo "" >&2
echo "Changed paths that should be reflected in a bible:" >&2
echo "$NEEDS_DOC" | sed 's/^/  - /' >&2
echo "" >&2
echo "Do ONE of:" >&2
echo "  1. Update the owning doc in this PR (RULE 0 — same PR as the change):" >&2
echo "     • new/changed table·view·RPC·cron·edge-fn → RESOURCES_BIBLE.md (+ PROJECT_BIBLE §3 if a new column landmine, §4 if a hot RPC)" >&2
echo "     • new external service / secret           → RESOURCES_BIBLE.md §1 / §7" >&2
echo "     • new source client (*_client.py)         → RESOURCES_BIBLE.md §1 + RULE 2 client list" >&2
echo "     • deploy/IaC change                       → PROJECT_BIBLE.md §2.7" >&2
echo "  2. If no doc change is warranted, add to a commit message:  BIBLE-OK: <reason>" >&2
exit 1
