#!/usr/bin/env bash
# Runs every test. The database tests need a PostgreSQL superuser in the libpq
# environment; without one they are skipped, unless REQUIRE_DB=1 (as in CI),
# where a missing database is a failure.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
status=0

"$here/test-plan-gate.sh" || status=1
"$here/test-sql-guard.sh" || status=1

if psql -X -q -d postgres -c "SELECT 1" >/dev/null 2>&1; then
  "$here/test-database.sh" || status=1
elif [ "${REQUIRE_DB:-0}" = "1" ]; then
  echo "database tests: FAIL, no PostgreSQL reachable and REQUIRE_DB=1" >&2
  status=1
else
  echo "database tests: skipped (no PostgreSQL reachable; see README, Running the tests)"
fi

exit "$status"
