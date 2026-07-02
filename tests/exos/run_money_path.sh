#!/usr/bin/env bash
# Offline contract test for the money path (refund/auto-refund) the stripe-webhook
# rewrite relies on. Applies the minimal real chain onto the prereq harness:
#   prereq.sql  (auth/orgs/events/tiers/checkout_sessions/tickets stubs)
#   20260616190000_exos_addons.sql        (order/event addons + exos_refund_checkout)
#   20260702123100_exos_payment_ledger.sql (exos_order_payments/refunds + record fns)
# then runs test_money_path_refunds.sql.
#
# Usage: PGHOST/PGPORT/PGUSER set, then: bash tests/exos/run_money_path.sh [db]
set -euo pipefail
DB="${1:-exos_money_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq.sql"
$PSQL -f "$MIG/20260616190000_exos_addons.sql"
$PSQL -f "$MIG/20260702123100_exos_payment_ledger.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_money_path_refunds.sql"
