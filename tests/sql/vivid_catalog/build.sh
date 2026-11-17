#!/usr/bin/env bash
# Build the Vivid catalogue test database: stand-ins for what the migration reads (TEvo mirror, hub, order book,
# vault, pgsql-http, pg_cron, the generic name rule), then the real migration(s) in order.
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
20261117070000_vivid_catalog.sql
20261117080000_catalogues_in_resolver.sql
20261117090000_catalog_mappers_fast.sql
20261117110000_catalog_hub_fill_skip_locked.sql
20261117120000_llm_match_judge.sql
20261117140000_catalog_venue_pairing.sql
STEPS
