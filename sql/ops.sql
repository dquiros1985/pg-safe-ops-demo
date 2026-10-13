-- Operational metadata the pipelines rely on. Run after roles.sql, as the
-- server administrator:
--
--   psql -X -d appdb -v server_name=pgdemo-dev-psql -v environment=dev -f sql/ops.sql
--
-- ops.instance_identity  who this database says it is. target-guard.sh
--                        compares it with the target pinned in the workflow.
--                        A point-in-time restore copies this row, so a
--                        restored copy must be re-stamped before real use.
-- ops.schema_migrations  which migration files ran, when, and as whom.
-- ops.restore_markers    known rows the restore test looks for.

\set ON_ERROR_STOP on

\if :{?server_name}
\else
DO $$ BEGIN RAISE EXCEPTION 'missing psql variable: -v server_name=...'; END $$;
\endif
\if :{?environment}
\else
DO $$ BEGIN RAISE EXCEPTION 'missing psql variable: -v environment=...'; END $$;
\endif

CREATE SCHEMA IF NOT EXISTS ops AUTHORIZATION dbadmin;

CREATE TABLE IF NOT EXISTS ops.instance_identity (
  singleton   boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  server_name text        NOT NULL,
  environment text        NOT NULL,
  stamped_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ops.instance_identity (server_name, environment)
VALUES (:'server_name', :'environment')
ON CONFLICT (singleton) DO UPDATE
  SET server_name = EXCLUDED.server_name,
      environment = EXCLUDED.environment,
      stamped_at  = now();

CREATE TABLE IF NOT EXISTS ops.schema_migrations (
  filename   text PRIMARY KEY,
  sha256     text        NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  applied_by text        NOT NULL DEFAULT session_user
);

CREATE TABLE IF NOT EXISTS ops.restore_markers (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  source     text        NOT NULL,
  payload    text        NOT NULL
);

-- Pipelines write markers through this function only; they get no direct
-- INSERT on the table.
CREATE OR REPLACE FUNCTION ops.write_marker(p_source text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  INSERT INTO ops.restore_markers (source, payload)
  VALUES (p_source, md5(random()::text || clock_timestamp()::text))
  RETURNING id
$$;

ALTER TABLE ops.instance_identity OWNER TO dbadmin;
ALTER TABLE ops.schema_migrations OWNER TO dbadmin;
ALTER TABLE ops.restore_markers   OWNER TO dbadmin;
ALTER FUNCTION ops.write_marker(text) OWNER TO dbadmin;

REVOKE ALL ON FUNCTION ops.write_marker(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.write_marker(text) TO migrator, app;

GRANT USAGE ON SCHEMA ops TO migrator, app;
GRANT SELECT         ON ops.instance_identity TO migrator, app;
GRANT SELECT, INSERT ON ops.schema_migrations TO migrator;
GRANT SELECT         ON ops.restore_markers   TO migrator, app;

-- First marker, so the first restore test has something to find.
SELECT ops.write_marker('provisioning') AS first_marker_id;
