#!/usr/bin/env bash
# Regression run for mig 20260924200848 (audit 2026-09-24): cross-org quota
# mapping, the double-transfer claw-back race, and waitlist self-edit. Reuses the
# lifecycle prereq + real migration chain, adds cart holds / quotas / waitlist.
#   bash tests/exos/run_audit_hardening.sh <db>
set -euo pipefail
DB="${1:-exos_audit_hardening_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq_lifecycle.sql"
$PSQL -f "$DIR/prereq_audit_hardening.sql"
for m in \
  20260520120000_exos_phase1_schema \
  20260520130000_exos_phase2_tickets \
  20260523160000_exos_check_in_verify \
  20260605131500_exos_checkins_scanned_by_email \
  20260605132000_exos_check_in_event_scope \
  20260702120000_exos_checkin_harden_doors_gate \
  20260702121000_exos_transfer_secret_leak_fix \
  20260702123000_exos_barcode_secret_least_privilege \
  20260702123000_exos_cart_holds \
  20260702123030_exos_quotas \
  20260616180000_exos_waitlist \
  20260911060000_exos_ticket_attendee_name \
  20260911131000_exos_rsvp_release \
  20260924200848_exos_audit_hardening_quota_transfer_waitlist; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_audit_hardening.sql"
