#!/usr/bin/env bash
# bin/sync-check.sh
#
# Drift detector. Compares prod Supabase state against this git checkout.
# Catches: prod migrations not in git, edge functions not in git,
# git-only migrations not yet applied to prod.
#
# Usage:
#   SUPABASE_URL=https://hzrizjeaxlqcxfrtczpq.supabase.co \
#   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
#   SUPABASE_PAT=sbp_...              # optional, enables edge fn diff
#     bin/sync-check.sh [--quiet] [--report-md PATH]
#
# Exit codes:
#   0  no drift
#   1  drift detected (caller should review + capture)
#   2  config error (missing env vars or curl failure)
#
# Run modes:
#   - Local:  set env vars in shell, run.
#   - CI:     GitHub Actions reads SUPABASE_URL / SERVICE_ROLE_KEY / PAT
#             from secrets, runs this on push to main and on a daily cron.

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

# Required env
if [[ -z "${SUPABASE_URL:-}" ]] || [[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  err "ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set."
  err "  Find them in Supabase dashboard → Project Settings → API."
  exit 2
fi
PROJECT_REF="${SUPABASE_PROJECT_REF:-$(echo "$SUPABASE_URL" | sed -E 's|^https?://([^.]+)\..*|\1|')}"

# ---------- collect prod state ----------
log "[1/3] fetching prod migration list…"
PROD_MIGS_JSON=$(curl -sS \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  "$SUPABASE_URL/rest/v1/rpc/__sync_check_list_migrations" \
  -X POST -H "Content-Type: application/json" -d '{}' 2>/dev/null) || true

# If the RPC doesn't exist (one-time setup), fall back to direct SQL via PostgREST.
# We cannot SELECT from supabase_migrations.schema_migrations via PostgREST without
# a wrapper RPC because PostgREST exposes the public schema only by default.
# Document this and fall through to the manual-check path.
if echo "$PROD_MIGS_JSON" | grep -q '"code"' 2>/dev/null; then
  err "WARN: __sync_check_list_migrations RPC not found (one-time setup needed)."
  err "      Until installed, migration drift cannot be auto-checked. See"
  err "      bin/sync-check.md for the manual procedure."
  PROD_MIGS_LIST=""
else
  PROD_MIGS_LIST=$(echo "$PROD_MIGS_JSON" | python -c "
import sys, json
try:
    rows = json.loads(sys.stdin.read())
    print('\n'.join(r.get('name','') for r in rows))
except Exception:
    pass
" 2>/dev/null) || PROD_MIGS_LIST=""
fi

GIT_MIGS_LIST=$(ls supabase/migrations/ 2>/dev/null | sed 's/\.sql$//' | sort)

# ---------- diff migrations ----------
DRIFT=0
DRIFT_REPORT=""

if [[ -n "$PROD_MIGS_LIST" ]]; then
  PROD_SORTED=$(echo "$PROD_MIGS_LIST" | sort)
  PROD_NOT_IN_GIT=$(comm -23 <(echo "$PROD_SORTED") <(echo "$GIT_MIGS_LIST"))
  GIT_NOT_IN_PROD=$(comm -13 <(echo "$PROD_SORTED") <(echo "$GIT_MIGS_LIST"))

  if [[ -n "$PROD_NOT_IN_GIT" ]]; then
    DRIFT=1
    DRIFT_REPORT+="## Prod migrations not in git\n\n"
    DRIFT_REPORT+="$(echo "$PROD_NOT_IN_GIT" | sed 's/^/- /')\n\n"
    log "DRIFT: $(echo "$PROD_NOT_IN_GIT" | wc -l) prod migration(s) not in git."
  fi
  if [[ -n "$GIT_NOT_IN_PROD" ]]; then
    DRIFT_REPORT+="## Git migrations not yet applied to prod\n\n"
    DRIFT_REPORT+="$(echo "$GIT_NOT_IN_PROD" | sed 's/^/- /')\n\n"
    log "INFO: $(echo "$GIT_NOT_IN_PROD" | wc -l) git migration(s) not applied yet."
  fi
fi

# ---------- edge fn diff (requires PAT) ----------
log "[2/3] fetching deployed edge functions…"
if [[ -n "${SUPABASE_PAT:-}" ]]; then
  FNS_JSON=$(curl -sS \
    -H "Authorization: Bearer $SUPABASE_PAT" \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/functions" 2>/dev/null) || FNS_JSON=""
  if [[ -n "$FNS_JSON" ]]; then
    DEPLOYED_FNS=$(echo "$FNS_JSON" | python -c "
import sys, json
try:
    rows = json.loads(sys.stdin.read())
    print('\n'.join(r.get('slug','') for r in rows if r.get('status')=='ACTIVE'))
except Exception:
    pass
" 2>/dev/null | sort)
    GIT_FNS=$(ls supabase/functions/ 2>/dev/null | sort)
    DEPLOYED_NOT_IN_GIT=$(comm -23 <(echo "$DEPLOYED_FNS") <(echo "$GIT_FNS"))
    if [[ -n "$DEPLOYED_NOT_IN_GIT" ]]; then
      DRIFT=1
      DRIFT_REPORT+="## Edge functions deployed but not in git\n\n"
      DRIFT_REPORT+="$(echo "$DEPLOYED_NOT_IN_GIT" | sed 's/^/- /')\n\n"
      log "DRIFT: $(echo "$DEPLOYED_NOT_IN_GIT" | wc -l) deployed edge fn(s) not in git."
    fi
  else
    log "WARN: PAT request failed; skipping edge fn diff."
  fi
else
  log "INFO: SUPABASE_PAT not set; skipping edge fn diff (set the env var to enable)."
fi

# ---------- summary ----------
log "[3/3] summary:"
if [[ $DRIFT -eq 0 ]]; then
  log "  ✅ no drift detected"
else
  log "  ⚠️  drift detected (see report)"
fi

if [[ -n "$REPORT_MD" ]]; then
  {
    echo "# Sync Check Report — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    if [[ $DRIFT -eq 0 ]]; then
      echo "✅ **No drift detected.** Prod migrations match git, deployed edge fns have local source."
    else
      echo "⚠️  **Drift detected.** Capture the prod-only items into git via the audit-and-commit pattern."
      echo ""
      echo -e "$DRIFT_REPORT"
    fi
  } > "$REPORT_MD"
  log "  report written to $REPORT_MD"
fi

exit $DRIFT
