#!/usr/bin/env bash
# Unit tests for scripts/sql-guard.sh. No database needed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
guard="$root/scripts/sql-guard.sh"
sql="$root/tests/fixtures/sql"
export EXPECTED_TARGET="pgdemo-ci-psql/appdb"

run() { env DESTRUCTIVE="$1" CONFIRM="$2" "$guard" "${@:3}"; }

echo "sql-guard"
expect 0 "real migrations pass (ON DELETE CASCADE is not a DELETE)" run false "" "$root"/migrations/*.sql
expect 0 "comments and string literals are ignored"            run false "" "$sql/comments-and-strings.sql"
expect 0 "BEGIN inside a function body is not transaction control" run false "" "$sql/plpgsql-function.sql"
expect 1 "DELETE without the flag is refused"                  run false "" "$sql/cleanup.sql"
expect_output "points at file and line"                       "cleanup.sql:3:"
expect 1 "lowercase truncate is refused"                       run false "" "$sql/lowercase-truncate.sql"
expect 1 "DROP COLUMN is refused"                              run false "" "$sql/drop-column.sql"
expect 1 "flag with a wrong confirmation is refused"           run true "pgdemo-prod-psql/appdb" "$sql/cleanup.sql"
expect 1 "flag with an empty confirmation is refused"          run true "" "$sql/cleanup.sql"
expect 0 "flag with the exact pinned target is allowed"        run true "pgdemo-ci-psql/appdb" "$sql/cleanup.sql"
expect 1 "files that open their own transaction are refused"   run false "" "$sql/own-transaction.sql"
expect 1 "one bad file in a batch refuses the batch"           run false "" "$root/migrations/001_customers.sql" "$sql/cleanup.sql"
expect 2 "missing file is a usage error"                       run false "" "$sql/nope.sql"
expect 2 "no arguments is a usage error"                       "$guard"

finish
