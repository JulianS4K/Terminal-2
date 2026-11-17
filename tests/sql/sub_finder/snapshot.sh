#!/usr/bin/env bash
# Full definitions of the sub finder's SQL functions, one file each, in functions/.
#
# Migrations change these functions; this is what they look like once every
# migration in build.sh has run. The files are checked: a migration that changes
# a function changes its file in the same PR, so the review shows the whole
# function as it will be, not only the lines a patch touched.
#
# To change a function: copy its file into a new migration, edit it, ship the
# full CREATE OR REPLACE (MIGRATION_CONVENTIONS.md), then run.sh --update.
#
# Usage: snapshot.sh <database> check|update
set -euo pipefail
DB="$1"; MODE="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/functions"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# name, and a number when a name has several definitions (ordered by their arguments)
psql -q -X -At -F '|' -d "$DB" -c "
  SELECT p.oid,
         p.proname || CASE WHEN count(*) OVER (PARTITION BY p.proname) > 1
                           THEN '__' || row_number() OVER (PARTITION BY p.proname ORDER BY pg_get_function_identity_arguments(p.oid))
                           ELSE '' END
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind IN ('f', 'p')
     AND (p.proname LIKE 'sub\_finder%' OR p.proname LIKE 'manual\_sub\_buy%' OR p.proname LIKE 'account\_balance%'
          OR p.proname LIKE 'sub\_buy%')
   ORDER BY 2" > "$TMP/list"
while IFS='|' read -r oid name; do
  psql -q -X -At -d "$DB" -c "SELECT pg_get_functiondef($oid)" > "$TMP/$name.sql"
done < "$TMP/list"
rm "$TMP/list"

if [ "$MODE" = "update" ]; then
  rm -rf "$OUT"; mkdir -p "$OUT"; cp "$TMP"/*.sql "$OUT"/
  echo "updated $(ls "$OUT" | wc -l) function files"
  exit 0
fi
if diff -r "$OUT" "$TMP" > "$TMP.diff" 2>&1; then
  echo "ok      function definitions ($(ls "$OUT" | wc -l) files)"
else
  echo "FAILED  function definitions differ from tests/sql/sub_finder/functions (run.sh --update rewrites them)"
  head -80 "$TMP.diff"; rm -f "$TMP.diff"
  exit 1
fi
rm -f "$TMP.diff"
