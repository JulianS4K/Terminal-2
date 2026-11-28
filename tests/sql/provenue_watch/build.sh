#!/usr/bin/env bash
# Build the ProVenue watch test database: the AXS watch's database (the shared box-office poll and its stand-ins,
# ../axs_watch/build.sh), then the stand-ins the ProVenue watch reads (the MLB schedule, the vault, pg_net's headers)
# and the watch itself.
# Usage: build.sh <database>   (psql connection comes from the PG* variables)
set -euo pipefail
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
DB="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
MIG="$HERE/../../../supabase/migrations"
run() { psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f "$1" >/dev/null; }
"$HERE/../axs_watch/build.sh" "$DB"
run "$HERE/stub_20_provenue.sql"
for m in 20261127230000_provenue_watch.sql 20261128020000_provenue_watch_settle_safe.sql 20261128030000_provenue_watch_order_limits.sql 20261128040000_provenue_watch_crash_safe.sql 20261128050000_provenue_watch_club_order_max.sql; do run "$MIG/$m"; done
