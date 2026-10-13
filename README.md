# pg-safe-ops-demo

A small reference implementation of one question: **how do you stop a cleanup
query from running against the wrong PostgreSQL database, and how do you prove
you can get the data back if it does?**

Everything here uses made-up names (`pgdemo-*`, `appdb`) and all-zero IDs. The
Terraform validates and the guards are tested against a real PostgreSQL 16 in
CI, but nothing has been deployed to a cloud account. See
[What has been verified](#what-has-been-verified).

## The problem

A `DELETE` meant for a scratch database runs against a shared one. Nobody
wrote a malicious query; the failure is that every layer let it through:

1. **The target was implicit.** The connection came from an environment
   variable, a pasted connection string or shell history. Nothing compared
   "where I am" with "where I meant to be".
2. **The identity could do anything.** The session ran as an owner or admin
   role, so `DELETE`, `TRUNCATE` and `DROP` were all allowed.
3. **Nothing asked twice.** A destructive statement looked the same to the
   tooling as a harmless one.
4. **Recovery was assumed, not proven.** Backups existed, but nobody knew how
   long a restore takes or whether the restored data is complete.

This repository puts a control on each of those four points, and a fifth one
under all of them: the database server itself cannot be deleted by accident.

## How each piece prevents or recovers

| # | Control | Stops or recovers | Where |
|---|---|---|---|
| 1 | **Pinned target.** The server, database, subscription and environment are constants in the workflow file. There is no input that overrides them; pointing the pipeline elsewhere takes a reviewed commit. | Prevents "wrong target" | [`migrate.yml`](.github/workflows/migrate.yml) `env:` |
| 2 | **Target guard.** Before anything runs, the script asks the database who it is (`ops.instance_identity`, `current_database()`) and aborts on any mismatch with the pinned values. A database with no identity row is never a valid target. | Prevents "wrong target", even when a host name or variable is wrong | [`scripts/target-guard.sh`](scripts/target-guard.sh) |
| 3 | **Role check.** The session must run as `migrator`. Superusers, `CREATEROLE`/`CREATEDB`/`BYPASSRLS` roles and members of admin roles are refused, even if they were "expected". | Prevents running with more power than needed | `target-guard.sh` |
| 4 | **Least-privilege roles.** `app` can read and write rows but cannot `TRUNCATE`, `DROP`, `ALTER` or create objects. `migrator` owns the schema but cannot create roles or touch the identity row. `dbadmin` is break-glass only and inherits nothing until it runs `SET ROLE`. | Limits the blast radius | [`sql/roles.sql`](sql/roles.sql), [`sql/ops.sql`](sql/ops.sql) |
| 5 | **Two-key destructive gate.** Any `DELETE`, `TRUNCATE` or `DROP` in pending migrations is refused unless the run sets `destructive=true` **and** types the pinned `<server>/<database>` into `confirm`. Comments, string literals and `ON DELETE CASCADE` do not count. | Makes a destructive run a deliberate act, aimed at a named target | [`scripts/sql-guard.sh`](scripts/sql-guard.sh) |
| 6 | **Preview by default.** The default mode runs every pending file inside one transaction and rolls it back, so the log shows exactly what would happen. Apply uses the same single transaction and commits: all files or none. | Shows the effect before it is real | [`scripts/run-migrations.sh`](scripts/run-migrations.sh) |
| 7 | **No stored credentials, short network window.** The workflow signs in with OIDC and gets a database token that expires within the hour. A firewall rule for the runner is opened for the run and closed in a step that runs even when the job fails (`if: always()`). | Removes standing access | `migrate.yml` |
| 8 | **The server cannot be deleted by accident.** `prevent_destroy` stops Terraform; an Azure `CanNotDelete` lock (or RDS `deletion_protection`) stops everyone else, including someone with Owner rights clicking in the portal. A plan gate fails CI on any delete or replace. | Prevents losing the server and its backups | [`modules/postgres`](modules/postgres), [`scripts/plan-gate.sh`](scripts/plan-gate.sh) |
| 9 | **Point-in-time restore window.** 7 days in dev, 35 (the Azure maximum) in prod, with backups optionally copied to the paired region. | Recovers from any of the above, to the second | `modules/postgres/azure` |
| 10 | **Tested restore, every month.** A scheduled workflow restores the database to a temporary server, checks known marker rows by count and checksum, confirms that a row written *after* the restore point is absent, writes the measured RTO to the job summary, deletes the temporary server and opens an issue on failure. | Proves recovery works and how long it takes | [`restore-test.yml`](.github/workflows/restore-test.yml), [`scripts/restore-validate.sh`](scripts/restore-validate.sh) |

### The same mistake, replayed

Someone adds `003_cleanup.sql` with `DELETE FROM app.customers WHERE ...` and
starts the migrate workflow.

- With the defaults, `sql-guard.sh` refuses before the workflow even signs in
  to Azure, and prints the file and line.
- With `destructive=true` but a wrong or empty `confirm`, it still refuses.
- With the right confirmation, the run is in **preview** unless `apply` was
  chosen: the `DELETE` runs, the log shows it, and it is rolled back.
- If the workflow file were edited to point at another server, the target
  guard compares the identity row of the database it reached and aborts; the
  edit itself is a reviewed commit.
- If all of that was intended and the statement was still wrong, the data
  comes back with a point-in-time restore to just before the run, a procedure
  the monthly test has already exercised and timed.

The database tests replay this exact sequence against PostgreSQL 16:
[`tests/test-database.sh`](tests/test-database.sh).

## What this does not stop

Being precise about the limits matters more than the list above.

- **Row-level mistakes by the application.** `app` keeps `DELETE` because most
  applications need it. A buggy `DELETE` from the app is recovered with PITR,
  not prevented. Tighten it per table if the app never deletes.
- **Someone who removes the lock on purpose.** A lock raises the bar to a
  separate, logged action (`Microsoft.Authorization/locks/delete`); it does
  not stop an Owner who means it. Alert on that operation in the activity log.
- **The SQL scanner is a heuristic.** It errs on the side of flagging (it also
  flags `DROP DEFAULT`, or a `DELETE` inside a function body). It is a speed
  bump in front of the role model, not a replacement for it.
- **A restored copy carries the source identity row.** Before a restored server
  is used for real, re-stamp it with `sql/ops.sql`, or the target guard would
  accept it as the original.
- **Retention is a hard edge.** A mistake noticed after 7 days in dev (35 in
  prod) cannot be undone with PITR. Long-term retention needs a separate
  backup (Azure Backup vaulted backups, or AWS Backup) with its own restore
  test.

### Lock scope and the firewall rule

An Azure resource lock is inherited by child resources, and firewall rules are
children of the server. With a `CanNotDelete` lock on the server, a pipeline
can create its temporary firewall rule but cannot delete it afterwards. The
module therefore takes `lock_scope`:

- `server` (prod example): the pipelines reach the database over a private
  network, so there is no firewall rule to clean up.
- `database` (dev example): the lock protects the database resource and the
  pipelines open and close a firewall rule per run.

Set `NETWORK_MODE: private` in the workflows when you use `lock_scope =
"server"`.

## SOC 2 mapping

SOC 2 does not prescribe a monthly restore test, an automated pipeline or a
specific RTO. It asks the company to define controls that meet the Trust
Services Criteria, and the auditor tests that those controls are designed
appropriately and operated as described during the audit period. The
frequency, the automation and the RTO target below are **choices the company
makes**; the workflows make them repeatable and leave evidence.

The Availability criteria (A1) apply only if Availability is in the scope of
the report.

| Criterion | What it asks for (paraphrased) | Controls here | Evidence produced |
|---|---|---|---|
| **A1.2** | Backup processes and recovery infrastructure are in place to meet availability commitments | PITR retention per environment, optional geo-redundant backups, delete lock / deletion protection, `prevent_destroy` | Terraform code and plan history; lock and retention visible in the cloud console |
| **A1.3** | Recovery plan procedures are tested | Monthly `restore-test` with data validation and a measured RTO against a target | Job summary per run (restore point, duration, checks); an issue for every failed run |
| **CC8.1** | Changes to infrastructure, data and software are authorized, tested, approved and implemented in a controlled way | Pinned target, preview by default, two-key destructive gate, environment approval before credentials are issued, plan gate that fails on deletes | Workflow run history: who started it, inputs, guard output, approval |
| **CC6.1** | Logical and network access to protected assets is restricted | OIDC with short-lived tokens instead of stored secrets, per-run firewall rule closed on exit, `REVOKE ... FROM PUBLIC` | Workflow logs, firewall rule lifecycle in the activity log |
| **CC6.3** | Access is role-based, follows least privilege, and supports segregation of duties | Roles `dbadmin` / `migrator` / `app`, pipeline identity mapped to `migrator` only, break-glass through an explicit `SET ROLE` | `sql/roles.sql`, target-guard output in every run |

GitHub keeps workflow logs for 90 days by default (configurable). If the audit
period is longer, export the run summaries somewhere with matching retention.

## Repository layout

```text
.
├── .github/workflows/
│   ├── ci.yml              fmt, validate, tflint, shellcheck, actionlint, tests, gitleaks
│   ├── migrate.yml         manual migrations: pinned target, preview default, guards
│   └── restore-test.yml    monthly PITR restore, validation, RTO, cleanup, issue
├── examples/
│   ├── azure-dev/          7-day PITR, lock on the database, firewall mode
│   ├── azure-prod/         35-day PITR, geo backup, lock on the server
│   └── aws-prod/           the same protections on RDS
├── migrations/             sample schema migrations
├── modules/postgres/
│   ├── azure/              Flexible Server, Entra auth, lock, prevent_destroy
│   └── aws/                RDS, deletion_protection, final snapshot, prevent_destroy
├── scripts/
│   ├── plan-gate.sh        fail on any delete or replace in a Terraform plan
│   ├── restore-validate.sh compare markers between source and restored copy
│   ├── run-migrations.sh   guards, then one transaction: rollback or commit
│   ├── sql-guard.sh        two-key gate for DELETE / TRUNCATE / DROP
│   └── target-guard.sh     identity, database and role check
├── sql/
│   ├── ops.sql             identity row, migration log, restore markers
│   └── roles.sql           dbadmin / migrator / app
└── tests/                  unit tests and PostgreSQL integration tests
```

## Running the tests

The unit tests need `bash`, `jq` and `perl`:

```bash
tests/test-plan-gate.sh
```

```bash
tests/test-sql-guard.sh
```

The database tests need a **throwaway** PostgreSQL 16 superuser. They drop and
recreate `appdb`, `appdb_restored` and the three roles:

```bash
docker run -d --rm --name pgdemo-test -e POSTGRES_PASSWORD=localtestonly -p 55432:5432 postgres:16
```

```bash
PGHOST=localhost PGPORT=55432 PGUSER=postgres PGPASSWORD=localtestonly REQUIRE_DB=1 tests/run.sh
```

Use the plan gate on a real plan:

```bash
terraform plan -out=plan.tfplan && terraform show -json plan.tfplan | scripts/plan-gate.sh
```

## Using it for real

What the workflows expect, none of which is a stored secret:

1. A Microsoft Entra app registration with a **federated credential** for
   this repository and the GitHub environment (`pgdemo-dev`,
   `pgdemo-restore-test`). Its client and tenant IDs go in the repository
   variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`.
2. Azure RBAC for that identity: read the server and manage its firewall rules
   (migrate); restore and delete servers in the resource group (restore test).
3. GitHub environments with required reviewers, so a person approves each run
   before any credential is issued.
4. In the database, as the Entra admin group: run `sql/roles.sql` and
   `sql/ops.sql`, create the workflow principals with
   `pgaadauth_create_principal`, then `GRANT migrator TO "gh-pgdemo-migrator"`
   and `GRANT app TO "gh-pgdemo-restore-check"`.

## Adapting this to your environment

Every name in this repository is a placeholder. Search for `pgdemo`, `appdb`
and `00000000` to find them all.

### AWS RDS

The module in `modules/postgres/aws` already carries the protections. The
workflows are written for Azure; each step has a direct AWS equivalent:

| Azure step | AWS equivalent |
|---|---|
| `azure/login` with OIDC | `aws-actions/configure-aws-credentials` with `role-to-assume` |
| Subscription check | `aws sts get-caller-identity --query Account` compared with a pinned account ID |
| Entra token as the password | `aws rds generate-db-auth-token` (IAM database authentication) |
| Temporary firewall rule | `aws ec2 authorize-security-group-ingress` / `revoke-security-group-ingress` in `if: always()` |
| `az postgres flexible-server restore --restore-time` | `aws rds restore-db-instance-to-point-in-time --restore-time`, then `aws rds wait db-instance-available` |
| `az postgres flexible-server delete` | `aws rds delete-db-instance --skip-final-snapshot --delete-automated-backups` (temporary instance only) |
| `CanNotDelete` lock | `deletion_protection = true` |

What to change:

1. **Names.** In `examples/aws-prod/main.tf`: `identifier`, `db_subnet_group_name`,
   `vpc_security_group_ids`, region. Keep the restore prefix
   (`RESTORE_PREFIX` in `restore-test.yml`) distinct from every real instance
   name, because the cleanup step deletes anything that starts with it.
2. **Retention.** `backup_retention_period` per environment, 1 to 35 days.
   Pick it from how late a mistake could be noticed, not from cost alone.
3. **OIDC role.** Create an IAM OIDC provider for
   `token.actions.githubusercontent.com` and one role per workflow. Restrict
   the trust policy's `sub` claim to
   `repo:<owner>/<repo>:environment:<environment>`, so only approved runs can
   assume it. Grant only what each workflow does:
   - migrate: `rds-db:connect` for the one database user, and ingress
     authorize/revoke on the one security group (or nothing, with a private
     runner);
   - restore test: `rds:RestoreDBInstanceToPointInTime` from the source, and
     `rds:DeleteDBInstance` limited to `arn:aws:rds:<region>:<account>:db:<restore-prefix>*`.
4. **Database users.** Run `sql/roles.sql` and `sql/ops.sql` as the master
   user (password in Secrets Manager). Create one login per workflow, give it
   `rds_iam`, then `GRANT migrator` (migrate) or `GRANT app` (restore test) to it.
5. **Target pin.** In both workflow files, replace the subscription and
   resource group with the AWS account ID and region, and set
   `EXPECTED_SERVER` to the RDS identifier, `EXPECTED_DATABASE` and
   `EXPECTED_ENVIRONMENT`. Stamp the same values into the database with
   `psql -v server_name=<identifier> -v environment=<env> -f sql/ops.sql`.
   Pin the endpoint host too, rather than reading it from an input.
6. **RTO target.** Set `RTO_TARGET_MINUTES` from the first few measured runs,
   then treat a breach as a failure.

### Azure

1. **Names.** `name`, `resource_group_name`, `location`, `entra_admin_*` and
   the all-zero IDs in `examples/azure-*/main.tf`.
2. **Retention.** `backup_retention_days` (7 to 35) and
   `geo_redundant_backup_enabled`, which can only be set when the server is
   created.
3. **OIDC.** An Entra app registration with a federated credential per
   GitHub environment; its IDs go in the `AZURE_CLIENT_ID` and
   `AZURE_TENANT_ID` repository variables.
4. **Target pin.** The `env:` block at the top of both workflows, plus
   `sql/ops.sql` with the matching server name and environment.
5. **Network.** `lock_scope` and `NETWORK_MODE` together, as described in
   [Lock scope and the firewall rule](#lock-scope-and-the-firewall-rule).

## What has been verified

| Piece | Status |
|---|---|
| `sql/roles.sql`, `sql/ops.sql`, all guards, `run-migrations.sh`, `restore-validate.sh` | Tested against PostgreSQL 16 (`tests/test-database.sh`) |
| `plan-gate.sh`, `sql-guard.sh` | Unit-tested with fixtures |
| Terraform modules and examples | `terraform fmt`, `terraform validate`, `tflint` |
| Workflows | `actionlint`; the Azure steps have **not** been run against a real subscription |

## License

MIT, see [LICENSE](LICENSE).
