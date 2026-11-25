#!/usr/bin/env bash
# Build the AXS watch test database: stand-ins for what the migrations read (the AXS export, pg_net, pg_cron, the vault
# helper, the TicketsData credit ledger, bot_chat, the retention table), then the real box-office poll migrations and the
# AXS watch itself.
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
stub_10_retention.sql
20261123171030_primary_poll_feed.sql
20261123183730_primary_poll_cleanup_and_announce.sql
20261123190030_primary_poll_max_age.sql
20261123192030_primary_poll_fees_and_tax.sql
20261123194030_primary_poll_cadence.sql
20261124041030_primary_poll_ends_at_start.sql
20261124190000_axs_watch.sql
20261124200000_axs_watch_listings_parse.sql
20261124203030_primary_poll_history.sql
20261124210000_axs_watch_listing_status.sql
20261124220000_axs_watch_spaced_fires.sql
20261124230000_axs_watch_no_premium.sql
20261124230030_primary_poll_split_over_limit.sql
20261124233030_axs_watch_withheld_notes.sql
20261125000000_axs_watch_worker_reader.sql
20261125010000_axs_watch_pace.sql
20261125013030_axs_watch_not_on_sale_out_of_list.sql
STEPS
