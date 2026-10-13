#!/usr/bin/env bash
# The as_* helpers change PG* variables inside a subshell on purpose.
# shellcheck disable=SC2030,SC2031
#
# Integration tests against a real PostgreSQL 16 (a service container in CI,
# a local container on a laptop). Needs superuser libpq settings in the
# environment: PGHOST, PGPORT, PGUSER, PGPASSWORD.
#
# Drops and recreates the databases appdb and appdb_restored and the roles
# dbadmin, migrator and app. Never point it at a server you care about.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
scripts="$root/scripts"

super_user="${PGUSER:?PGUSER (a superuser) is required}"
super_pw="${PGPASSWORD:?PGPASSWORD is required}"

# Throwaway passwords for this run only.
admin_pw=$(openssl rand -hex 16)
migrator_pw=$(openssl rand -hex 16)
app_pw=$(openssl rand -hex 16)

# Each helper runs its command in a subshell with that role's credentials.
as_super()    ( export PGUSER="$super_user" PGPASSWORD="$super_pw"; "$@" )
as_migrator() ( export PGUSER=migrator PGPASSWORD="$migrator_pw" PGDATABASE=appdb; "$@" )
as_app()      ( export PGUSER=app PGPASSWORD="$app_pw" PGDATABASE=appdb; "$@" )
as_dbadmin()  ( export PGUSER=dbadmin PGPASSWORD="$admin_pw" PGDATABASE=appdb; "$@" )
sql()         { psql -X -A -t -q -v ON_ERROR_STOP=1 "$@"; }

export EXPECTED_SERVER=pgdemo-ci-psql EXPECTED_DATABASE=appdb EXPECTED_ENVIRONMENT=ci EXPECTED_ROLE=migrator

echo "setup"
as_super sql -d postgres -c "DROP DATABASE IF EXISTS appdb_restored WITH (FORCE)"
as_super sql -d postgres -c "DROP DATABASE IF EXISTS appdb WITH (FORCE)"
as_super sql -d postgres -c "DROP ROLE IF EXISTS app, migrator, dbadmin"
as_super sql -d postgres -c "CREATE DATABASE appdb"

expect 3 "roles.sql refuses to run without password variables" \
  as_super psql -X -q -d appdb -f "$root/sql/roles.sql"
expect 0 "roles.sql creates the three roles" \
  as_super psql -X -q -d appdb -v admin_password="$admin_pw" -v migrator_password="$migrator_pw" \
  -v app_password="$app_pw" -f "$root/sql/roles.sql"
expect 0 "roles.sql is safe to re-run" \
  as_super psql -X -q -d appdb -v admin_password="$admin_pw" -v migrator_password="$migrator_pw" \
  -v app_password="$app_pw" -f "$root/sql/roles.sql"
expect 0 "ops.sql stamps the identity row" \
  as_super psql -X -q -d appdb -v server_name=pgdemo-ci-psql -v environment=ci -f "$root/sql/ops.sql"

echo "target-guard"
expect 0 "pinned target and migrator role pass"       as_migrator "$scripts/target-guard.sh"
expect 1 "another server name aborts" \
  as_migrator env EXPECTED_SERVER=pgdemo-prod-psql "$scripts/target-guard.sh"
expect_output "says which value differs"              "actual=pgdemo-ci-psql expected=pgdemo-prod-psql"
expect 1 "another environment aborts" \
  as_migrator env EXPECTED_ENVIRONMENT=prod "$scripts/target-guard.sh"
expect 1 "another database name aborts" \
  as_migrator env EXPECTED_DATABASE=appdb_prod "$scripts/target-guard.sh"
expect 2 "a database without an identity row aborts" \
  as_migrator env PGDATABASE=postgres "$scripts/target-guard.sh"
expect 1 "connected as app instead of migrator aborts" as_app "$scripts/target-guard.sh"
expect 1 "a superuser is refused even when expected" \
  as_super env PGDATABASE=appdb EXPECTED_ROLE="$super_user" "$scripts/target-guard.sh"
expect 1 "dbadmin (CREATEROLE) is refused even when expected" \
  as_dbadmin env EXPECTED_ROLE=dbadmin "$scripts/target-guard.sh"

echo "run-migrations"
expect 0 "preview runs the migrations"                as_migrator "$scripts/run-migrations.sh" preview "$root/migrations"
expect_output "preview reports the rollback"          "rolled back; nothing changed"
expect 0 "preview leaves no table behind" \
  test "$(as_migrator sql -c "SELECT to_regclass('app.customers') IS NULL")" = "t"
expect 0 "apply commits"                              as_migrator "$scripts/run-migrations.sh" apply "$root/migrations"
expect 0 "both migrations are recorded" \
  test "$(as_migrator sql -c "SELECT count(*) FROM ops.schema_migrations")" = "2"
expect 0 "second apply has nothing to do"             as_migrator "$scripts/run-migrations.sh" apply "$root/migrations"
expect_output "reports nothing pending"               "nothing pending"
expect 1 "apply refuses a migration aimed at another server" \
  as_migrator env EXPECTED_SERVER=pgdemo-prod-psql "$scripts/run-migrations.sh" apply "$root/migrations"

as_app sql -c "INSERT INTO app.customers (email) VALUES ('a@example.com'), ('b@example.com')"
as_super sql -d appdb -c "UPDATE app.customers SET created_at = now() - interval '2 years' WHERE email = 'a@example.com'"
cleanup_dir=$(mktemp -d "${TMPDIR:-/tmp}/pgdemo-test.XXXXXX")
trap 'rm -rf "$cleanup_dir"' EXIT
cp "$root"/migrations/*.sql "$cleanup_dir/"
cp "$root/tests/fixtures/sql/cleanup.sql" "$cleanup_dir/003_cleanup.sql"

expect 1 "a DELETE migration without the flag is refused" \
  as_migrator "$scripts/run-migrations.sh" apply "$cleanup_dir"
expect 1 "the flag with a wrong confirmation is refused" \
  as_migrator env DESTRUCTIVE=true CONFIRM=pgdemo-prod-psql/appdb "$scripts/run-migrations.sh" apply "$cleanup_dir"
expect 0 "rows are untouched after both refusals" \
  test "$(as_app sql -c "SELECT count(*) FROM app.customers")" = "2"
expect 0 "the flag with the pinned target as confirmation runs it" \
  as_migrator env DESTRUCTIVE=true CONFIRM=pgdemo-ci-psql/appdb "$scripts/run-migrations.sh" apply "$cleanup_dir"
expect 0 "only the old row was deleted" \
  test "$(as_app sql -c "SELECT string_agg(email, ',') FROM app.customers")" = "b@example.com"

echo "least privilege"
expect 0 "app can insert rows"                     as_app sql -c "INSERT INTO app.customers (email) VALUES ('c@example.com')"
expect 1 "app cannot TRUNCATE"                     as_app psql -X -q -v ON_ERROR_STOP=1 -c "TRUNCATE app.orders"
expect 1 "app cannot DROP a table"                 as_app psql -X -q -v ON_ERROR_STOP=1 -c "DROP TABLE app.orders"
expect 1 "app cannot create tables"                as_app psql -X -q -v ON_ERROR_STOP=1 -c "CREATE TABLE app.x (id int)"
expect 1 "app cannot write markers directly"       as_app psql -X -q -v ON_ERROR_STOP=1 -c "INSERT INTO ops.restore_markers (source, payload) VALUES ('x', 'x')"
expect 1 "app cannot rewrite the identity row"     as_app psql -X -q -v ON_ERROR_STOP=1 -c "UPDATE ops.instance_identity SET server_name = 'x'"
expect 1 "migrator cannot rewrite the identity row" as_migrator psql -X -q -v ON_ERROR_STOP=1 -c "UPDATE ops.instance_identity SET server_name = 'x'"
expect 1 "migrator cannot create roles"            as_migrator psql -X -q -v ON_ERROR_STOP=1 -c "CREATE ROLE intruder"
expect 0 "app can write a marker through the function" as_app sql -c "SELECT ops.write_marker('test')"

echo "restore-validate"
as_super sql -d appdb -c "INSERT INTO ops.restore_markers (created_at, source, payload) VALUES
  (now() - interval '3 hours', 'seed', 'one'), (now() - interval '2 hours', 'seed', 'two')"
as_super sql -d appdb -c "UPDATE ops.restore_markers SET created_at = now() - interval '4 hours' WHERE source IN ('provisioning', 'test')"
restore_point=$(as_super sql -d appdb -c "SELECT to_char((now() - interval '30 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")

# A PITR restore is a copy of the database as it was at the restore point.
# CREATE DATABASE ... TEMPLATE gives the same thing locally.
as_super sql -d postgres -c "CREATE DATABASE appdb_restored TEMPLATE appdb"
fresh=$(as_app sql -c "SELECT ops.write_marker('fresh')")

validate() {
  as_app "$scripts/restore-validate.sh" --source "dbname=appdb" --restored "dbname=appdb_restored" \
    --restore-point "$restore_point" "$@"
}
expect 0 "a faithful copy passes"                   validate --fresh-marker "$fresh"
expect_output "reports the four markers"            "4 on source"

as_super sql -d appdb_restored -c "DELETE FROM ops.restore_markers WHERE payload = 'two'"
expect 1 "a copy missing a marker fails"            validate --fresh-marker "$fresh"
expect_output "reports the count mismatch"          "source=4 restored=3"

as_super sql -d postgres -c "DROP DATABASE appdb_restored WITH (FORCE)"
as_super sql -d postgres -c "CREATE DATABASE appdb_restored TEMPLATE appdb"
expect 1 "a copy taken after the restore point fails" validate --fresh-marker "$fresh"
expect_output "flags the fresh marker"              "is present"

expect 1 "a restore point older than every marker fails" \
  as_app "$scripts/restore-validate.sh" --source "dbname=appdb" --restored "dbname=appdb_restored" \
  --restore-point 2000-01-01T00:00:00Z
expect 2 "missing arguments is a usage error"       as_app "$scripts/restore-validate.sh" --source "dbname=appdb"

finish
