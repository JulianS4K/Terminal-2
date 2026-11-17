#!/usr/bin/env bash
# Build the venue pairer test database: stand-ins for what the migration reads (TEvo mirror, the six catalogues,
# venue maps, pg_cron), then the real migration.
# Usage: build.sh <database>   (psql connection comes from the PG* variables)
set -euo pipefail
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
DB="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
MIG="$HERE/../../../supabase/migrations"
run() { psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f "$1" >/dev/null; }

psql -q -X -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\"" 2>/dev/null
while read -r step; do
  [ -z "$step" ] && continue
  case "$step" in
    stub_*) run "$HERE/$step" ;;
    *)      run "$MIG/$step" ;;
  esac
done <<'STEPS'
stub_00_base.sql
20261117140000_catalog_venue_pairing.sql
STEPS
