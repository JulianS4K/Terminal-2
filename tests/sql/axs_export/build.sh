#!/usr/bin/env bash
# Build the AXS export test database: the AXS watch stubs (pg_net, the vault helper, safe_jsonb, the
# TicketsData credit ledger, axs_export_event) plus axs_export_sync as it stands before the cursor
# migration, then the real export migrations.
# Usage: build.sh <database>   (psql connection comes from the PG* variables)
set -euo pipefail
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
DB="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
MIG="$HERE/../../../supabase/migrations"
run() { psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f "$1" >/dev/null; }

psql -q -X -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\"" 2>/dev/null
run "$HERE/../axs_watch/stub_00_base.sql"
run "$HERE/stub_05_export.sql"
run "$MIG/20261115010000_axs_export_cursor_paging.sql"
run "$MIG/20261125163500_axs_export_tick_lost_response.sql"
run "$MIG/20261125170500_axs_export_type_override.sql"
