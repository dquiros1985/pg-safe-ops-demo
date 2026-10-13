#!/usr/bin/env bash
# Connects with the usual libpq variables (PGHOST, PGDATABASE, PGUSER, ...) and
# aborts unless the database it reached is the one pinned in the workflow, and
# the session runs as the expected low-privilege role.
#
#   EXPECTED_SERVER=pgdemo-dev-psql EXPECTED_DATABASE=appdb \
#   EXPECTED_ENVIRONMENT=dev EXPECTED_ROLE=migrator scripts/target-guard.sh
#
# What it compares:
#   ops.instance_identity.server_name / environment  vs EXPECTED_SERVER / EXPECTED_ENVIRONMENT
#   current_database()                               vs EXPECTED_DATABASE
#   current_user                                     vs EXPECTED_ROLE
#   and the role must not be superuser, CREATEROLE, CREATEDB, BYPASSRLS, or a
#   member of an admin role.
#
# Exit codes: 0 = target confirmed, 1 = mismatch, 2 = usage or connection error.
set -euo pipefail

for v in EXPECTED_SERVER EXPECTED_DATABASE EXPECTED_ENVIRONMENT; do
  if [ -z "${!v:-}" ]; then
    echo "target-guard: $v is not set" >&2
    exit 2
  fi
done
expected_role="${EXPECTED_ROLE:-migrator}"

query=$(cat <<'SQL'
SELECT i.server_name,
       i.environment,
       current_database(),
       current_user,
       r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls,
       COALESCE((SELECT bool_or(pg_has_role(current_user, a.oid, 'MEMBER'))
                 FROM pg_roles a
                 WHERE a.rolname IN ('dbadmin', 'azure_pg_admin', 'rds_superuser')), false)
FROM ops.instance_identity i
JOIN pg_roles r ON r.rolname = current_user
SQL
)

if ! row=$(psql -X -A -t -q -F '|' -v ON_ERROR_STOP=1 -c "$query" 2>&1); then
  echo "target-guard: cannot read ops.instance_identity on the target:" >&2
  echo "  $row" >&2
  echo "target-guard: ABORT, a database without an identity row is never a valid target" >&2
  exit 2
fi
if [ -z "$row" ]; then
  echo "target-guard: ABORT, ops.instance_identity is empty" >&2
  exit 1
fi

IFS='|' read -r server environment database role privileged admin_member <<<"$row"

fail=0
check() {
  local what="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  ok    %-12s %s\n' "$what" "$actual"
  else
    printf '  FAIL  %-12s actual=%s expected=%s\n' "$what" "$actual" "$expected"
    fail=1
  fi
}

echo "target-guard:"
check server      "$server"       "$EXPECTED_SERVER"
check environment "$environment"  "$EXPECTED_ENVIRONMENT"
check database    "$database"     "$EXPECTED_DATABASE"
check role        "$role"         "$expected_role"
check privileged  "$privileged"   "f"
check admin-member "$admin_member" "f"

if [ "$fail" -ne 0 ]; then
  echo "target-guard: ABORT, this is not the pinned target or not the expected role" >&2
  exit 1
fi
echo "target-guard: PASS"
