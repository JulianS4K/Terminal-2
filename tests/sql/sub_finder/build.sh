#!/usr/bin/env bash
# Build the sub finder test database: small stand-ins for the tables and
# functions the sub finder reads, then the real migrations in order.
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
20261111020000_manual_sub_buy.sql
20261112000000_manual_sub_buy_follow.sql
20261112010000_sub_finder_api.sql
20261113010000_sub_finder_gates_autobuy.sql
20261113020000_sub_finder_gt_offer.sql
20261113030000_sub_finder_buy_book_check.sql
20261113040000_sub_finder_autobuy_breakeven.sql
20261113060000_sub_finder_api_first.sql
20261113070000_sub_finder_evo_venue_tax.sql
20261113080000_sub_finder_gate2_loss.sql
20261113100000_sub_finder_gt_rebate.sql
stub_10_after_gt_rebate.sql
stub_05_n2s_autobuy.sql
20261113110000_manual_sub_buy_tax_quote.sql
20261113120000_sub_finder_poll_rules.sql
stub_20_after_poll_rules.sql
20261113130000_sub_finder_confirm_flags.sql
20261113140000_sub_finder_crm_notes.sql
20261113150000_manual_sub_buy_tax_quote_test.sql
stub_30_before_need2buy.sql
20261113160000_sub_finder_need2buy_intake.sql
20261113170000_sub_finder_feed_decisions.sql
20261113190000_sub_finder_need2buy_stay_live.sql
stub_40_zones.sql
20261113220000_sub_finder_match_zones_setbased.sql
20261113230000_sub_finder_sg_link_fallback.sql
stub_50_alerts.sql
20261113240000_manual_sub_buy_alerts.sql
20261113250000_sub_finder_ped_report_only.sql
20261113260000_sub_finder_background_settle.sql
20261113270000_account_balances_hourly.sql
20261113290000_sub_finder_td_scope.sql
20261113300000_sub_finder_gotickets_buy.sql
20261113310000_sub_finder_buy_fallback.sql
20261113320000_sub_finder_loss_limits.sql
stub_60_n2s_live.sql
20261113430000_sub_buy_control.sql
STEPS
