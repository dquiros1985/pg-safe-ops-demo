# pg-safe-ops-demo

Una implementación de referencia, pequeña, para una sola pregunta: **¿cómo se
evita que una consulta de limpieza corra contra la base de datos PostgreSQL
equivocada, y cómo se demuestra que los datos se pueden recuperar si ocurre?**

Todo usa nombres inventados (`pgdemo-*`, `appdb`) e identificadores en ceros.
El Terraform valida y los controles se prueban contra un PostgreSQL 16 real en
CI, pero nada se ha desplegado en una cuenta de nube. Ver
[Lo que está verificado](#lo-que-está-verificado).

## El problema

Un `DELETE` pensado para una base de pruebas corre contra una compartida. Nadie
escribió una consulta maliciosa; la falla es que ninguna capa lo detuvo:

1. **El destino era implícito.** La conexión salió de una variable de entorno,
   de una cadena de conexión pegada o del historial de la terminal. Nada
   comparó "dónde estoy" con "dónde quería estar".
2. **La identidad podía hacer cualquier cosa.** La sesión corría como dueño o
   administrador, así que `DELETE`, `TRUNCATE` y `DROP` estaban permitidos.
3. **Nada pidió confirmación.** Para las herramientas, una sentencia
   destructiva se veía igual que una inofensiva.
4. **La recuperación se suponía, no se había probado.** Había respaldos, pero
   nadie sabía cuánto tarda una restauración ni si los datos restaurados
   quedan completos.

Este repositorio pone un control en cada uno de esos cuatro puntos, y un quinto
debajo de todos: el servidor de base de datos no se puede borrar por accidente.

## Qué previene o recupera cada pieza

| # | Control | Qué evita o recupera | Dónde |
|---|---|---|---|
| 1 | **Destino fijado.** Servidor, base de datos, suscripción y ambiente son constantes en el archivo del workflow. Ningún parámetro de entrada los cambia; apuntar el pipeline a otro lado requiere un commit revisado. | Evita el "destino equivocado" | [`migrate.yml`](.github/workflows/migrate.yml) `env:` |
| 2 | **Verificación del destino.** Antes de ejecutar nada, el script le pregunta a la base quién es (`ops.instance_identity`, `current_database()`) y aborta si algo no coincide con los valores fijados. Una base sin fila de identidad nunca es un destino válido. | Evita el "destino equivocado", aunque el host o una variable estén mal | [`scripts/target-guard.sh`](scripts/target-guard.sh) |
| 3 | **Verificación del rol.** La sesión debe correr como `migrator`. Se rechazan superusuarios, roles con `CREATEROLE`/`CREATEDB`/`BYPASSRLS` y miembros de roles de administración, aunque fueran los "esperados". | Evita correr con más poder del necesario | `target-guard.sh` |
| 4 | **Roles de mínimo privilegio.** `app` lee y escribe filas, pero no puede hacer `TRUNCATE`, `DROP`, `ALTER` ni crear objetos. `migrator` es dueño del esquema, pero no puede crear roles ni tocar la fila de identidad. `dbadmin` es solo de emergencia y no hereda nada hasta que ejecuta `SET ROLE`. | Limita el alcance del daño | [`sql/roles.sql`](sql/roles.sql), [`sql/ops.sql`](sql/ops.sql) |
| 5 | **Doble llave para lo destructivo.** Cualquier `DELETE`, `TRUNCATE` o `DROP` en las migraciones pendientes se rechaza, salvo que la ejecución marque `destructive=true` **y** se escriba en `confirm` el `<servidor>/<base>` fijado. Comentarios, textos entre comillas y `ON DELETE CASCADE` no cuentan. | Convierte una ejecución destructiva en un acto deliberado, contra un destino con nombre | [`scripts/sql-guard.sh`](scripts/sql-guard.sh) |
| 6 | **Vista previa por defecto.** El modo por defecto ejecuta todos los archivos pendientes dentro de una transacción y la revierte, así el log muestra exactamente qué pasaría. El modo `apply` usa la misma transacción única y confirma: todos los archivos o ninguno. | Muestra el efecto antes de que sea real | [`scripts/run-migrations.sh`](scripts/run-migrations.sh) |
| 7 | **Sin credenciales guardadas y ventana de red corta.** El workflow se autentica con OIDC y obtiene un token de base de datos que vence en menos de una hora. Se abre una regla de firewall para el runner durante la ejecución y se cierra en un paso que corre aunque el job falle (`if: always()`). | Elimina el acceso permanente | `migrate.yml` |
| 8 | **El servidor no se puede borrar por accidente.** `prevent_destroy` detiene a Terraform; un lock `CanNotDelete` de Azure (o `deletion_protection` en RDS) detiene a todos los demás, incluso a alguien con rol Owner en el portal. Un control sobre el plan hace fallar el CI ante cualquier borrado o reemplazo. | Evita perder el servidor y sus respaldos | [`modules/postgres`](modules/postgres), [`scripts/plan-gate.sh`](scripts/plan-gate.sh) |
| 9 | **Ventana de restauración a un punto en el tiempo (PITR).** 7 días en dev, 35 (el máximo de Azure) en prod, con copia opcional de los respaldos a la región emparejada. | Recupera de cualquiera de los casos anteriores, al segundo | `modules/postgres/azure` |
| 10 | **Restauración probada, cada mes.** Un workflow programado restaura la base en un servidor temporal, compara filas marcadoras conocidas por cantidad y checksum, confirma que una fila escrita *después* del punto de restauración no aparece, registra el RTO medido en el resumen del job, borra el servidor temporal y abre un issue si algo falla. | Demuestra que la recuperación funciona y cuánto tarda | [`restore-test.yml`](.github/workflows/restore-test.yml), [`scripts/restore-validate.sh`](scripts/restore-validate.sh) |

### El mismo error, repetido

Alguien agrega `003_cleanup.sql` con `DELETE FROM app.customers WHERE ...` y
lanza el workflow de migración.

- Con los valores por defecto, `sql-guard.sh` lo rechaza antes de que el
  workflow siquiera se autentique en Azure, e indica archivo y línea.
- Con `destructive=true` pero un `confirm` vacío o equivocado, también lo
  rechaza.
- Con la confirmación correcta, la ejecución queda en **vista previa** salvo
  que se haya elegido `apply`: el `DELETE` corre, el log lo muestra y se
  revierte.
- Si alguien editara el workflow para apuntar a otro servidor, la verificación
  del destino compara la fila de identidad de la base a la que llegó y aborta;
  y la edición misma pasa por un commit revisado.
- Si todo eso fue intencional y aun así la sentencia estaba mal, los datos se
  recuperan con una restauración al momento previo a la ejecución, un
  procedimiento que la prueba mensual ya ejecutó y cronometró.

Las pruebas de base de datos repiten exactamente esta secuencia contra
PostgreSQL 16: [`tests/test-database.sh`](tests/test-database.sh).

## Lo que esto no evita

Ser precisos con los límites importa más que la lista anterior.

- **Errores fila por fila de la aplicación.** `app` conserva `DELETE` porque la
  mayoría de las aplicaciones lo necesita. Un `DELETE` defectuoso de la
  aplicación se recupera con PITR, no se previene. Si la aplicación nunca
  borra, conviene restringirlo por tabla.
- **Alguien que quita el lock a propósito.** Un lock obliga a una acción
  aparte y registrada (`Microsoft.Authorization/locks/delete`); no detiene a
  un Owner decidido. Conviene alertar sobre esa operación en el registro de
  actividad.
- **El análisis del SQL es heurístico.** Prefiere marcar de más (también marca
  `DROP DEFAULT` o un `DELETE` dentro del cuerpo de una función). Es un
  reductor de velocidad delante del modelo de roles, no un reemplazo.
- **Una copia restaurada lleva la fila de identidad del origen.** Antes de usar
  un servidor restaurado en serio, hay que volver a marcarlo con
  `sql/ops.sql`; si no, la verificación del destino lo aceptaría como el
  original.
- **La retención es un límite duro.** Un error que se descubre después de 7
  días en dev (35 en prod) no se puede deshacer con PITR. La retención de
  largo plazo requiere un respaldo aparte (respaldos en bóveda de Azure Backup,
  o AWS Backup) con su propia prueba de restauración.

### Alcance del lock y la regla de firewall

En Azure, un lock se hereda a los recursos hijos, y las reglas de firewall son
hijas del servidor. Con un lock `CanNotDelete` sobre el servidor, un pipeline
puede crear su regla de firewall temporal, pero no puede borrarla después. Por
eso el módulo recibe `lock_scope`:

- `server` (ejemplo de prod): los pipelines llegan a la base por red privada,
  así que no hay regla de firewall que limpiar.
- `database` (ejemplo de dev): el lock protege el recurso de la base de datos
  y los pipelines abren y cierran una regla de firewall por ejecución.

Con `lock_scope = "server"`, poner `NETWORK_MODE: private` en los workflows.

## Correspondencia con SOC 2

SOC 2 no exige una prueba de restauración mensual, un pipeline automatizado ni
un RTO específico. Pide que la empresa defina controles que cumplan los Trust
Services Criteria, y el auditor verifica que esos controles estén bien
diseñados y que hayan operado como se describen durante el período auditado.
La frecuencia, la automatización y la meta de RTO de abajo son **decisiones de
la empresa**; los workflows las vuelven repetibles y dejan evidencia.

Los criterios de Disponibilidad (A1) aplican solo si Availability está dentro
del alcance del informe.

| Criterio | Qué pide (parafraseado) | Controles aquí | Evidencia que queda |
|---|---|---|---|
| **A1.2** | Procesos de respaldo e infraestructura de recuperación que permitan cumplir los compromisos de disponibilidad | Retención PITR por ambiente, respaldo geo-redundante opcional, lock de borrado / deletion protection, `prevent_destroy` | Código Terraform e historial de planes; lock y retención visibles en la consola de la nube |
| **A1.3** | Se prueban los procedimientos del plan de recuperación | `restore-test` mensual con validación de datos y RTO medido contra una meta | Resumen de cada ejecución (punto de restauración, duración, verificaciones); un issue por cada ejecución fallida |
| **CC8.1** | Los cambios en infraestructura, datos y software se autorizan, prueban, aprueban e implementan de forma controlada | Destino fijado, vista previa por defecto, doble llave para lo destructivo, aprobación del ambiente antes de emitir credenciales, control de plan que falla ante borrados | Historial de ejecuciones: quién la lanzó, parámetros, salida de los controles, aprobación |
| **CC6.1** | El acceso lógico y de red a los activos protegidos está restringido | OIDC con tokens de corta duración en lugar de secretos guardados, regla de firewall por ejecución que se cierra al salir, `REVOKE ... FROM PUBLIC` | Logs de los workflows, ciclo de vida de la regla de firewall en el registro de actividad |
| **CC6.3** | El acceso se basa en roles, sigue el mínimo privilegio y permite segregación de funciones | Roles `dbadmin` / `migrator` / `app`, identidad del pipeline asociada solo a `migrator`, acceso de emergencia mediante un `SET ROLE` explícito | `sql/roles.sql`, salida de `target-guard` en cada ejecución |

GitHub conserva los logs de los workflows 90 días por defecto (configurable).
Si el período de auditoría es más largo, exportar los resúmenes a un lugar con
retención equivalente.

## Estructura del repositorio

```text
.
├── .github/workflows/
│   ├── ci.yml              fmt, validate, tflint, shellcheck, actionlint, pruebas, gitleaks
│   ├── migrate.yml         migraciones manuales: destino fijado, vista previa, controles
│   └── restore-test.yml    restauración PITR mensual, validación, RTO, limpieza, issue
├── examples/
│   ├── azure-dev/          PITR de 7 días, lock en la base, modo firewall
│   ├── azure-prod/         PITR de 35 días, respaldo geo, lock en el servidor
│   └── aws-prod/           las mismas protecciones en RDS
├── migrations/             migraciones de ejemplo
├── modules/postgres/
│   ├── azure/              Flexible Server, autenticación Entra, lock, prevent_destroy
│   └── aws/                RDS, deletion_protection, snapshot final, prevent_destroy
├── scripts/
│   ├── plan-gate.sh        falla ante cualquier borrado o reemplazo en un plan de Terraform
│   ├── restore-validate.sh compara marcadores entre el origen y la copia restaurada
│   ├── run-migrations.sh   controles, luego una sola transacción: revertir o confirmar
│   ├── sql-guard.sh        doble llave para DELETE / TRUNCATE / DROP
│   └── target-guard.sh     verificación de identidad, base de datos y rol
├── sql/
│   ├── ops.sql             fila de identidad, registro de migraciones, marcadores
│   └── roles.sql           dbadmin / migrator / app
└── tests/                  pruebas unitarias y de integración con PostgreSQL
```

## Cómo correr las pruebas

Las pruebas unitarias necesitan `bash`, `jq` y `perl`:

```bash
tests/test-plan-gate.sh
```

```bash
tests/test-sql-guard.sh
```

Las pruebas de base de datos necesitan un superusuario de un PostgreSQL 16
**desechable**. Borran y recrean `appdb`, `appdb_restored` y los tres roles:

```bash
docker run -d --rm --name pgdemo-test -e POSTGRES_PASSWORD=localtestonly -p 55432:5432 postgres:16
```

```bash
PGHOST=localhost PGPORT=55432 PGUSER=postgres PGPASSWORD=localtestonly REQUIRE_DB=1 tests/run.sh
```

Para usar el control de plan sobre un plan real:

```bash
terraform plan -out=plan.tfplan && terraform show -json plan.tfplan | scripts/plan-gate.sh
```

## Uso real en Azure

Lo que esperan los workflows; nada de esto es un secreto guardado:

1. Un registro de aplicación de Microsoft Entra con una **credencial
   federada** para este repositorio y cada ambiente de GitHub (`pgdemo-dev`,
   `pgdemo-restore-test`). Sus IDs de cliente y de tenant van en las variables
   del repositorio `AZURE_CLIENT_ID` y `AZURE_TENANT_ID`.
2. Permisos RBAC de Azure para esa identidad: leer el servidor y administrar
   sus reglas de firewall (migrate); restaurar y borrar servidores en el grupo
   de recursos (prueba de restauración).
3. Ambientes de GitHub con revisores obligatorios, para que una persona
   apruebe cada ejecución antes de que se emita cualquier credencial.
4. En la base de datos, como el grupo administrador de Entra: ejecutar
   `sql/roles.sql` y `sql/ops.sql`, crear los principales de los workflows con
   `pgaadauth_create_principal`, y luego `GRANT migrator TO "gh-pgdemo-migrator"`
   y `GRANT app TO "gh-pgdemo-restore-check"`.

## Cómo adaptarlo a tu entorno

Todos los nombres del repositorio son de ejemplo. Buscar `pgdemo`, `appdb` y
`00000000` para encontrarlos todos.

### AWS RDS

El módulo `modules/postgres/aws` ya incluye las protecciones. Los workflows
están escritos para Azure; cada paso tiene un equivalente directo en AWS:

| Paso en Azure | Equivalente en AWS |
|---|---|
| `azure/login` con OIDC | `aws-actions/configure-aws-credentials` con `role-to-assume` |
| Verificación de la suscripción | `aws sts get-caller-identity --query Account` comparado con un ID de cuenta fijado |
| Token de Entra como contraseña | `aws rds generate-db-auth-token` (autenticación IAM a la base de datos) |
| Regla de firewall temporal | `aws ec2 authorize-security-group-ingress` / `revoke-security-group-ingress` en `if: always()` |
| `az postgres flexible-server restore --restore-time` | `aws rds restore-db-instance-to-point-in-time --restore-time`, luego `aws rds wait db-instance-available` |
| `az postgres flexible-server delete` | `aws rds delete-db-instance --skip-final-snapshot --delete-automated-backups` (solo la instancia temporal) |
| Lock `CanNotDelete` | `deletion_protection = true` |

Qué cambiar:

1. **Nombres.** En `examples/aws-prod/main.tf`: `identifier`,
   `db_subnet_group_name`, `vpc_security_group_ids` y la región. El prefijo de
   restauración (`RESTORE_PREFIX` en `restore-test.yml`) debe ser distinto del
   nombre de toda instancia real, porque el paso de limpieza borra cualquier
   instancia que empiece con él.
2. **Retención.** `backup_retention_period` por ambiente, de 1 a 35 días.
   Elegirla según cuánto se podría tardar en notar un error, no solo por costo.
3. **Rol OIDC.** Crear un proveedor OIDC de IAM para
   `token.actions.githubusercontent.com` y un rol por workflow. Restringir el
   claim `sub` de la trust policy a
   `repo:<owner>/<repo>:environment:<ambiente>`, para que solo las ejecuciones
   aprobadas puedan asumirlo. Dar solo lo que cada workflow usa:
   - migrate: `rds-db:connect` para el único usuario de base de datos, y
     autorizar/revocar ingreso en el único security group (o nada, con un
     runner en red privada);
   - prueba de restauración: `rds:RestoreDBInstanceToPointInTime` desde el
     origen, y `rds:DeleteDBInstance` limitado a
     `arn:aws:rds:<región>:<cuenta>:db:<prefijo-de-restauración>*`.
4. **Usuarios de la base.** Ejecutar `sql/roles.sql` y `sql/ops.sql` como el
   usuario maestro (contraseña en Secrets Manager). Crear un login por
   workflow, darle `rds_iam` y luego `GRANT migrator` (migrate) o `GRANT app`
   (prueba de restauración).
5. **Destino fijado.** En los dos workflows, reemplazar la suscripción y el
   grupo de recursos por el ID de cuenta y la región de AWS, y poner en
   `EXPECTED_SERVER` el identificador de RDS, además de `EXPECTED_DATABASE` y
   `EXPECTED_ENVIRONMENT`. Registrar los mismos valores en la base con
   `psql -v server_name=<identificador> -v environment=<ambiente> -f sql/ops.sql`.
   Fijar también el host del endpoint, en lugar de leerlo de un parámetro.
6. **Meta de RTO.** Definir `RTO_TARGET_MINUTES` a partir de las primeras
   ejecuciones medidas y, desde ahí, tratar cualquier exceso como falla.

### Azure

1. **Nombres.** `name`, `resource_group_name`, `location`, `entra_admin_*` y
   los IDs en ceros de `examples/azure-*/main.tf`.
2. **Retención.** `backup_retention_days` (7 a 35) y
   `geo_redundant_backup_enabled`, que solo se puede definir al crear el
   servidor.
3. **OIDC.** Un registro de aplicación de Entra con una credencial federada
   por ambiente de GitHub; sus IDs van en las variables del repositorio
   `AZURE_CLIENT_ID` y `AZURE_TENANT_ID`.
4. **Destino fijado.** El bloque `env:` al inicio de los dos workflows, más
   `sql/ops.sql` con el nombre de servidor y el ambiente correspondientes.
5. **Red.** `lock_scope` y `NETWORK_MODE` en conjunto, como se explica en
   [Alcance del lock y la regla de firewall](#alcance-del-lock-y-la-regla-de-firewall).

## Lo que está verificado

| Pieza | Estado |
|---|---|
| `sql/roles.sql`, `sql/ops.sql`, todos los controles, `run-migrations.sh`, `restore-validate.sh` | Probados contra PostgreSQL 16 (`tests/test-database.sh`) |
| `plan-gate.sh`, `sql-guard.sh` | Pruebas unitarias con fixtures |
| Módulos y ejemplos de Terraform | `terraform fmt`, `terraform validate`, `tflint` |
| Workflows | `actionlint`; los pasos de Azure **no** se han ejecutado contra una suscripción real |

## Licencia

MIT, ver [LICENSE](LICENSE).
