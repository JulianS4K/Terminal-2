#!/usr/bin/env bash
# Sub finder SQL scenario tests.
#
# Builds a database from small stand-ins plus the real sub finder migrations
# (build.sh), then runs each file in scenarios/ against a fresh copy and
# compares what it prints with expected/<name>.out. A scenario fails when its
# output changes — so a migration that alters behaviour must update the
# expected file in the same PR, where the diff is reviewed.
#
#   run.sh            run every scenario, fail on any difference
#   run.sh --update   rewrite the expected files from the current output
#
# It also checks functions/: the full definition of every sub finder function
# as the migrations leave it (snapshot.sh). --update rewrites those too.
#
# A new migration that touches the sub finder is added to the list in build.sh.
# psql connects using the standard PG* environment variables.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="sub_finder_test_tpl"
DB="sub_finder_test"
UPDATE=0; [ "${1:-}" = "--update" ] && UPDATE=1

"$HERE/build.sh" "$TPL"
fail=0
if [ "$UPDATE" = 1 ]; then "$HERE/snapshot.sh" "$TPL" update; else "$HERE/snapshot.sh" "$TPL" check || fail=1; fi
cd "$HERE/scenarios"
for f in *.sql; do
  name="${f%.sql}"
  psql -q -X -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\" TEMPLATE \"$TPL\"" 2>/dev/null
  got="$(psql -q -X -d "$DB" -f "$f" 2>&1 || true)"
  if [ "$UPDATE" = 1 ]; then
    printf '%s\n' "$got" > "$HERE/expected/$name.out"
    echo "updated $name"
  elif [ "$got" == "$(cat "$HERE/expected/$name.out" 2>/dev/null)" ]; then
    echo "ok      $name"
  else
    echo "FAILED  $name"
    diff <(cat "$HERE/expected/$name.out" 2>/dev/null) <(printf '%s\n' "$got") || true
    fail=1
  fi
done
psql -q -X -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "DROP DATABASE IF EXISTS \"$TPL\"" 2>/dev/null
exit $fail
