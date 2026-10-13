-- Least-privilege roles for one application database.
--
--   dbadmin   break-glass owner of the ops schema. Not used by any pipeline.
--             NOINHERIT: holding migrator/app membership gives nothing until
--             an explicit SET ROLE, which shows up in the logs.
--   migrator  owns the app schema and runs schema migrations. No superuser,
--             no CREATEROLE, no CREATEDB.
--   app       what the application connects as: read and write rows in the
--             app schema. Cannot TRUNCATE, cannot DROP or ALTER anything.
--
-- Run once per database as the server administrator (the Entra admin group on
-- Azure, the master user on RDS, postgres locally). Safe to re-run.
--
--   psql -X -d appdb \
--     -v admin_password="$DBADMIN_PASSWORD" \
--     -v migrator_password="$MIGRATOR_PASSWORD" \
--     -v app_password="$APP_PASSWORD" \
--     -f sql/roles.sql
--
-- Passwords arrive as psql variables, so they are never written into this
-- file or into shell history when the caller reads them with `read -s`.
-- With Entra ID or IAM authentication the passwords go unused: grant the
-- role to the identity instead, e.g. GRANT migrator TO "gh-pgdemo-migrator".

\set ON_ERROR_STOP on

\if :{?admin_password}
\else
DO $$ BEGIN RAISE EXCEPTION 'missing psql variable: -v admin_password=...'; END $$;
\endif
\if :{?migrator_password}
\else
DO $$ BEGIN RAISE EXCEPTION 'missing psql variable: -v migrator_password=...'; END $$;
\endif
\if :{?app_password}
\else
DO $$ BEGIN RAISE EXCEPTION 'missing psql variable: -v app_password=...'; END $$;
\endif

-- Roles are cluster-wide; create the ones that do not exist yet.
SELECT format('CREATE ROLE %I', r)
FROM unnest(ARRAY['dbadmin', 'migrator', 'app']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

ALTER ROLE dbadmin  LOGIN NOSUPERUSER NOCREATEDB CREATEROLE   NOINHERIT NOBYPASSRLS PASSWORD :'admin_password';
ALTER ROLE migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT   NOBYPASSRLS PASSWORD :'migrator_password';
ALTER ROLE app      LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT   NOBYPASSRLS PASSWORD :'app_password'
  CONNECTION LIMIT 50;

-- Fail fast instead of queueing behind a lock or running for hours.
ALTER ROLE migrator SET lock_timeout = '5s';
ALTER ROLE migrator SET statement_timeout = '15min';
ALTER ROLE app      SET statement_timeout = '30s';
ALTER ROLE app      SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE migrator SET search_path = app;
ALTER ROLE app      SET search_path = app;

-- Nobody gets in by default; each role is let in explicitly.
REVOKE ALL ON DATABASE :"DBNAME" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"DBNAME" TO dbadmin, migrator, app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- The app schema belongs to migrator: only migrator can change its shape.
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION migrator;
ALTER SCHEMA app OWNER TO migrator;
GRANT USAGE ON SCHEMA app TO app;

-- Row access for app, on tables that exist now and tables migrator creates
-- later. TRUNCATE, REFERENCES and TRIGGER are deliberately left out.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app;

-- Break-glass path: dbadmin can SET ROLE to either, but inherits nothing.
GRANT migrator TO dbadmin;
GRANT app TO dbadmin;
