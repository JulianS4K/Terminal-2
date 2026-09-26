#!/usr/bin/env bash
# P0 regression run (2026-09-24): the platform chain from run.sh PLUS the real
# checkout/fulfillment layer (cart holds, quotas, payment ledger, tier-1 wiring)
# and the P0 migrations, in chronological order. Runs the existing platform
# suite (must still pass) and then test_p0.sql.
#   bash tests/exos/run_p0.sh <db>
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq.sql"
for m in \
  20260523230000_exos_issue_to_email 20260605132500_exos_claim_free_tickets \
  20260616180000_exos_waitlist 20260616190000_exos_addons 20260616200000_exos_public_api_webhooks \
  20260616210000_exos_vouchers 20260616220000_exos_waitlist_autoassign 20260616230000_exos_tax \
  20260616240000_exos_invoicing 20260616250000_exos_voucher_bypass_fulfill \
  20260702120000_exos_checkin_harden_doors_gate 20260702121000_exos_transfer_secret_leak_fix \
  20260702122000_exos_voucher_singleuse_and_limit_atomic \
  20260702123000_exos_cart_holds 20260702123030_exos_quotas 20260702123100_exos_payment_ledger \
  20260702123200_exos_tier1_wiring \
  20260702144537_exos_checkin_test_window_autoexpiry 20260702144607_exos_waitlist_idor_fix \
  20260911050000_exos_invoice_counters_rls 20260911051000_exos_event_reminders \
  20260911060000_exos_ticket_attendee_name 20260911070000_exos_event_reminders_hardening \
  20260911130000_exos_event_analytics 20260911131000_exos_rsvp_release \
  20260911132000_exos_comp_batch 20260911133000_exos_event_series \
  20260924205115_exos_p0_refund_ledger 20260924205508_exos_p0_voucher_per_ticket \
  20260924205916_exos_p0_hold_caps 20260924210103_exos_p0_quota_aware_mints \
  20260703122000_exos_tier_price_schedule 20260924211840_exos_all_in_price_tax \
  20260924215000_exos_fulfill_all_or_nothing 20260924223000_exos_checkout_attribution \
  20260924230000_exos_event_geo 20260924233000_exos_promoters \
  20260924234500_exos_fan_referrals 20260925000000_exos_voucher_unlocked_tier \
  20260925001000_exos_event_series_codes_fix 20260925003000_exos_trial_run_fixes \
  20260925010000_exos_trial_run_fixes_2 20260925012000_exos_presale_vouchers \
  20260925013000_exos_scanner_no_buyer_email 20260925020000_exos_webhook_claim \
  20260925021000_exos_p1_db_hardening 20260926000000_exos_advisor_cleanup; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_exos_platform.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_p0.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fulfill_all_or_nothing.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_checkout_attribution.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_geo.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promoters.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fan_referrals.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_voucher_tier.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_series_codes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_trial_run_fixes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_trial_run_fixes_2.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_presale_vouchers.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_edge_p1.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_p1_db_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_advisor_cleanup.sql"
# Replay: every pending migration again, in order, must be a no-op.
for m in 20260924215000_exos_fulfill_all_or_nothing 20260924223000_exos_checkout_attribution \
  20260924230000_exos_event_geo 20260924233000_exos_promoters 20260924234500_exos_fan_referrals \
  20260925000000_exos_voucher_unlocked_tier 20260925001000_exos_event_series_codes_fix \
  20260925003000_exos_trial_run_fixes 20260925010000_exos_trial_run_fixes_2 \
  20260925012000_exos_presale_vouchers 20260925013000_exos_scanner_no_buyer_email \
  20260925020000_exos_webhook_claim 20260925021000_exos_p1_db_hardening \
  20260926000000_exos_advisor_cleanup; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_replay_idempotent.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_edge_p1.sql"
