#!/usr/bin/env bash
# scripts/check_sync.sh — worktree freshness check for Terminal-2 sync protocol.
#
# Prints "SYNCED ✓" if the worktree's branch base is current with origin/main
# and there are no uncommitted changes. Otherwise prints a one-line delta and
# exits with a non-zero status so it can gate CI / pre-commit hooks.
#
# Usage:
#   bash scripts/check_sync.sh           # exit 0 if synced, 1 if drifted
#   bash scripts/check_sync.sh --quiet   # same, no output on success
#   bash scripts/check_sync.sh --json    # machine-readable
#
# Spec: SYNC_PROTOCOL.md §1.

set -euo pipefail

QUIET=0
JSON=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --json) JSON=1 ;;
    *) ;;
  esac
done

# 1. Are we inside a git worktree?
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git worktree" >&2
  exit 2
fi

# 2. Fetch latest origin/main without changing local state
git fetch origin main --quiet 2>/dev/null || {
  echo "WARN: could not fetch origin/main (offline?)" >&2
}

ORIGIN_MAIN_SHA=$(git rev-parse origin/main 2>/dev/null || echo "unknown")
ORIGIN_MAIN_SHORT=${ORIGIN_MAIN_SHA:0:8}
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
CURRENT_SHA=$(git rev-parse HEAD)
CURRENT_SHORT=${CURRENT_SHA:0:8}

# 3. Compute how far the branch base is behind origin/main
MERGE_BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
BEHIND=0
AHEAD=0
if [ -n "$MERGE_BASE" ]; then
  BEHIND=$(git rev-list --count "${MERGE_BASE}..origin/main" 2>/dev/null || echo 0)
  AHEAD=$(git rev-list --count "${MERGE_BASE}..HEAD" 2>/dev/null || echo 0)
fi

# 4. Uncommitted changes?
UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')

# 5. Decide
SYNCED=1
REASON=""
if [ "$BEHIND" -gt 0 ]; then
  SYNCED=0
  REASON="${BEHIND} commit(s) behind origin/main"
fi
if [ "$UNCOMMITTED" -gt 0 ]; then
  SYNCED=0
  if [ -n "$REASON" ]; then REASON="$REASON; "; fi
  REASON="${REASON}${UNCOMMITTED} uncommitted change(s)"
fi

# 6. Print
if [ "$JSON" -eq 1 ]; then
  printf '{"synced":%s,"branch":"%s","head":"%s","origin_main":"%s","behind":%s,"ahead":%s,"uncommitted":%s,"reason":"%s"}\n' \
    $([ $SYNCED -eq 1 ] && echo true || echo false) \
    "$CURRENT_BRANCH" "$CURRENT_SHORT" "$ORIGIN_MAIN_SHORT" \
    "$BEHIND" "$AHEAD" "$UNCOMMITTED" "$REASON"
elif [ "$SYNCED" -eq 1 ]; then
  if [ "$QUIET" -eq 0 ]; then
    echo "SYNCED ✓  branch=$CURRENT_BRANCH  head=$CURRENT_SHORT  origin/main=$ORIGIN_MAIN_SHORT  ahead=$AHEAD"
  fi
else
  echo "DRIFT ✗  branch=$CURRENT_BRANCH  head=$CURRENT_SHORT  origin/main=$ORIGIN_MAIN_SHORT  →  $REASON"
fi

[ "$SYNCED" -eq 1 ] && exit 0 || exit 1
