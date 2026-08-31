#!/usr/bin/env bash
# Extended lifecycle run that ALSO applies the 2026-07-13 migrations
# (Ed25519/v2 barcodes + idempotent check-in) on top of the real chain, then
# runs the existing lifecycle test (regression on the replaced RPC) + the new
# v2/idempotency assertions. Usage: PGHOST/PGPORT/PGUSER set, then:
#   bash tests/exos/run_my_migrations.sh <db>
set -euo pipefail
DB="${1:-exos_mine_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq_lifecycle.sql"
for m in \
  20260520120000_exos_phase1_schema \
  20260520130000_exos_phase2_tickets \
  20260523160000_exos_check_in_verify \
  20260605131500_exos_checkins_scanned_by_email \
  20260605132000_exos_check_in_event_scope \
  20260702120000_exos_checkin_harden_doors_gate \
  20260702121000_exos_transfer_secret_leak_fix \
  20260702123000_exos_barcode_secret_least_privilege \
  20260702240000_exos_event_checkin_roster_rpc \
  20260713120000_exos_ed25519_offline_crash_hardening \
  20260713170000_exos_api_check_in; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_exos_lifecycle.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_my_checkin.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_my_api_checkin.sql"
