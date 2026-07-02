#!/usr/bin/env bash
# Offline regression run for the Exos feature migrations against a throwaway
# Postgres. Usage: PGHOST/PGPORT/PGUSER set, then: bash tests/exos/run.sh <db>
set -euo pipefail
DB="${1:-exos_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq.sql"
for m in 180000_exos_waitlist 190000_exos_addons 200000_exos_public_api_webhooks \
         210000_exos_vouchers 220000_exos_waitlist_autoassign 230000_exos_tax 240000_exos_invoicing 250000_exos_voucher_bypass_fulfill; do
  $PSQL -f "$MIG/20260616${m}.sql"
done
# 2026-07-02 security-hardening migrations (audit fixes: check-in downgrade +
# doors gate, transfer secret leak, atomic voucher single-use + purchase limit).
for m in 20260702120000_exos_checkin_harden_doors_gate \
         20260702121000_exos_transfer_secret_leak_fix \
         20260702122000_exos_voucher_singleuse_and_limit_atomic; do
  $PSQL -f "$MIG/${m}.sql"
done
# 2026-07-02 real-event hardening (test-mode auto-expiry + waitlist IDOR). The
# reconcile-cron migration (144637) is cron.schedule-only (needs pg_cron), so it
# is intentionally NOT run in this data-layer harness.
for m in 20260702144537_exos_checkin_test_window_autoexpiry \
         20260702144607_exos_waitlist_idor_fix; do
  $PSQL -f "$MIG/${m}.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_exos_platform.sql"
