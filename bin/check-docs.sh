#!/usr/bin/env bash
# bin/check-docs.sh
#
# Documentation anti-regrowth gate (Layer 3). Enforces the CLOSED canonical
# doc set so doc-sprawl can't regrow. Modeled on bin/sync-check.sh.
#
# Three checks:
#   1. CLOSED REGISTRY — every root-level *.md must appear in the README.md
#      registry table, and every registry entry must exist on disk. The README
#      registry table is the single source of truth; this script parses it.
#   2. NO WORKING NOTES IN docs/ — no tracked file under docs/ (outside
#      docs/archive/) may match a dated / working-note pattern:
#        *YYYY-MM-DD*, *checkpoint-*, *handoff*, *audit*, *session*
#      ("checkpoint-" is hyphen-delimited so durable docs like
#       c1_daily_checkpoint_runbook.md are not falsely flagged.)
#      Those belong in bot_chat / KANBAN.md, or — if a durable dated artifact
#      is truly needed — docs/archive/YYYY-MM-DD-<topic>.md.
#   3. DOC VERSION HEADERS — every registry doc except CHANGELOG.md (which is
#      release-please-generated) must carry a `**Doc version:**` line, so doc
#      and section changes are version-tracked. See README "Doc-writing rules".
#
# Usage:
#   bin/check-docs.sh [--quiet] [--report-md PATH]
#
# Exit codes:
#   0  clean (root *.md == registry, no stray working notes)
#   1  violation (caller / CI should fail the PR)
#   2  config error (README.md or git unavailable)
#
# Run modes:
#   - Local:  bin/check-docs.sh
#   - CI:     .github/workflows/docs-registry-check.yml runs this on every PR
#             and on push to main. A non-zero exit fails the check (server-side;
#             --no-verify cannot skip it).

set -euo pipefail

QUIET=0
REPORT_MD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --report-md) REPORT_MD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { [[ $QUIET -eq 1 ]] || echo "$*"; }
err() { echo "$*" >&2; }

# Locate repo root (script lives in bin/)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f README.md ]]; then
  err "ERROR: README.md not found at repo root ($REPO_ROOT)."
  exit 2
fi

VIOLATION=0
REPORT=""

# ---------- check 1: closed registry ----------
log "[1/3] checking root *.md against the README registry…"

# Parse the registry table. Rows look like:  | [`NAME.md`](NAME.md) | … |
# (backticks below are literal — the whole pattern is single-quoted).
REGISTRY=$(grep -oE '^\|[[:space:]]*\[`[^`]+\.md`\]' README.md \
  | sed -E 's/.*`([^`]+\.md)`.*/\1/' | sort -u)

if [[ -z "$REGISTRY" ]]; then
  err "ERROR: could not parse any doc names from the README registry table."
  err "       Expected rows of the form:  | [\`NAME.md\`](NAME.md) | … |"
  exit 2
fi

# Root-level *.md actually present on disk (maxdepth 1 == repo root only).
ROOT_MD=$(find . -maxdepth 1 -type f -name '*.md' | sed 's#^\./##' | sort -u || true)

NOT_IN_REGISTRY=$(comm -23 <(echo "$ROOT_MD") <(echo "$REGISTRY") || true)
MISSING_FROM_DISK=$(comm -13 <(echo "$ROOT_MD") <(echo "$REGISTRY") || true)

if [[ -n "$NOT_IN_REGISTRY" ]]; then
  VIOLATION=1
  REPORT+="## Root .md files NOT in the README registry\n\n"
  REPORT+="These exist at repo root but the registry doesn't list them. Either add the\n"
  REPORT+="fact to an existing canonical doc and delete these, or move them to docs/archive/.\n\n"
  REPORT+="$(echo "$NOT_IN_REGISTRY" | sed 's/^/- /')\n\n"
  log "VIOLATION: $(echo "$NOT_IN_REGISTRY" | grep -c .) root .md not in registry."
fi

if [[ -n "$MISSING_FROM_DISK" ]]; then
  VIOLATION=1
  REPORT+="## Registry entries with no file on disk\n\n"
  REPORT+="The README registry lists these but they don't exist at repo root.\n"
  REPORT+="Fix the registry table or restore the file.\n\n"
  REPORT+="$(echo "$MISSING_FROM_DISK" | sed 's/^/- /')\n\n"
  log "VIOLATION: $(echo "$MISSING_FROM_DISK" | grep -c .) registry entr(ies) missing from disk."
fi

# ---------- check 2: no working notes in docs/ outside archive ----------
log "[2/3] checking docs/ for stray dated / working-note files…"

DOCS_FILES=$(find docs -type f 2>/dev/null | sed 's#^\./##' | grep -v '^docs/archive/' || true)
BAD_DOCS=$(echo "$DOCS_FILES" \
  | grep -iE '([0-9]{4}-[0-9]{2}-[0-9]{2})|checkpoint-|handoff|audit|session' || true)

if [[ -n "$BAD_DOCS" ]]; then
  VIOLATION=1
  REPORT+="## Working-note files in docs/ (move to docs/archive/)\n\n"
  REPORT+="Dated / audit / checkpoint / handoff / session files don't belong in docs/.\n"
  REPORT+="Use bot_chat or KANBAN.md for ephemeral work, or docs/archive/ for durable history.\n\n"
  REPORT+="$(echo "$BAD_DOCS" | sed 's/^/- /')\n\n"
  log "VIOLATION: $(echo "$BAD_DOCS" | grep -c .) working-note file(s) in docs/."
fi

# ---------- check 3: doc version headers ----------
log "[3/3] checking registry docs carry a **Doc version:** line…"

MISSING_VERSION=""
while IFS= read -r doc; do
  [[ -z "$doc" ]] && continue
  [[ "$doc" == "CHANGELOG.md" ]] && continue   # release-please-generated; not hand-versioned
  if [[ -f "$doc" ]] && ! grep -qE '\*\*Doc version:\*\*' "$doc"; then
    MISSING_VERSION+="$doc"$'\n'
  fi
done <<< "$REGISTRY"

if [[ -n "$MISSING_VERSION" ]]; then
  VIOLATION=1
  REPORT+="## Registry docs missing a Doc version line\n\n"
  REPORT+="Every canonical doc except CHANGELOG.md must carry a \`**Doc version:**\` line under\n"
  REPORT+="its title (semver). See README *Doc-writing rules*.\n\n"
  REPORT+="$(echo "$MISSING_VERSION" | sed '/^$/d; s/^/- /')\n\n"
  log "VIOLATION: $(echo "$MISSING_VERSION" | sed '/^$/d' | grep -c .) registry doc(s) missing a Doc version line."
fi

# ---------- summary ----------
if [[ $VIOLATION -eq 0 ]]; then
  log "✅ docs registry clean: root *.md == README registry; no stray working notes in docs/; all docs versioned."
else
  log "⚠️  docs registry violations detected (see report)."
fi

if [[ -n "$REPORT_MD" ]]; then
  {
    echo "# Docs Registry Check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    if [[ $VIOLATION -eq 0 ]]; then
      echo "✅ **Clean.** Root \`*.md\` matches the README registry; no stray working notes in \`docs/\`."
    else
      echo "⚠️  **Violations detected.** The canonical doc set is CLOSED — see README registry + CLAUDE.md §6."
      echo ""
      echo -e "$REPORT"
    fi
  } > "$REPORT_MD"
  log "  report written to $REPORT_MD"
fi

exit $VIOLATION
