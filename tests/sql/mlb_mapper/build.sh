#!/usr/bin/env bash
# Build the MLB mapper test database: stand-ins for the tables the MLB schedule migrations read
# (TEvo mirror, hub, SeatGeek catalogue, registries, pg_net, pg_cron), then the real migrations in order.
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
20261116190000_mlb_ticket_schedule.sql
20261116200000_mlb_schedule_feed.sql
20261116220000_mlb_feed_seatgeek.sql
20261116230000_milb_ticket_schedule.sql
20261117000000_mlb_ticket_mapper.sql
STEPS
