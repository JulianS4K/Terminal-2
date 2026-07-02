#!/usr/bin/env bash
# Offline regression run for the Exos TICKET LIFECYCLE (mint → offline roster →
# HMAC door scan → transfer → claim/reissue → void) against a throwaway Postgres.
# Applies the REAL phase-1/phase-2/hardening migrations (not a hand-stub) so the
# migrated RPC bodies are what's exercised. Usage: PGHOST/PGPORT/PGUSER set, then:
#   bash tests/exos/run_lifecycle.sh <db>
set -euo pipefail
DB="${1:-exos_lifecycle_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq_lifecycle.sql"
# Real migration chain, in dependency order (phase-1 → phase-2 → check-in verify
# → scanned_by_email col → event-scope → doors-gate harden → transfer-secret fix
# → barcode-secret least-privilege → the single-call roster RPC under test).
for m in \
  20260520120000_exos_phase1_schema \
  20260520130000_exos_phase2_tickets \
  20260523160000_exos_check_in_verify \
  20260605131500_exos_checkins_scanned_by_email \
  20260605132000_exos_check_in_event_scope \
  20260702120000_exos_checkin_harden_doors_gate \
  20260702121000_exos_transfer_secret_leak_fix \
  20260702123000_exos_barcode_secret_least_privilege \
  20260702240000_exos_event_checkin_roster_rpc; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_exos_lifecycle.sql"
