#!/usr/bin/env bash
# Applies pending migrations in one transaction, after both guards pass.
#
#   scripts/run-migrations.sh preview migrations/   # runs everything, then ROLLBACK
#   scripts/run-migrations.sh apply   migrations/   # runs everything, then COMMIT
#
# Uses the libpq variables for the connection and the EXPECTED_* / DESTRUCTIVE /
# CONFIRM variables documented in target-guard.sh and sql-guard.sh.
# All files succeed together or none is kept, in both modes.
set -euo pipefail

mode="${1:-}"
dir="${2:-migrations}"
case "$mode" in
  preview) finish="ROLLBACK" ;;
  apply)   finish="COMMIT" ;;
  *) echo "usage: run-migrations.sh preview|apply [DIR]" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

"$here/target-guard.sh"

applied=$(psql -X -A -t -q -v ON_ERROR_STOP=1 -c "SELECT filename FROM ops.schema_migrations")

pending=()
for f in "$dir"/*.sql; do
  [ -e "$f" ] || continue
  if ! grep -qxF "$(basename "$f")" <<<"$applied"; then
    pending+=("$f")
  fi
done

if [ ${#pending[@]} -eq 0 ]; then
  echo "run-migrations: nothing pending"
  exit 0
fi

EXPECTED_TARGET="${EXPECTED_SERVER}/${EXPECTED_DATABASE}" "$here/sql-guard.sh" "${pending[@]}"

script=$(
  echo '\set ON_ERROR_STOP on'
  echo 'BEGIN;'
  for f in "${pending[@]}"; do
    name=$(basename "$f")
    abs=$(cd "$(dirname "$f")" && pwd)/$name
    printf "\\\\echo '>> %s'\n" "$name"
    printf "\\\\i '%s'\n" "$abs"
    echo "INSERT INTO ops.schema_migrations (filename, sha256) VALUES ('$name', '$(sha256 "$f")');"
  done
  echo "$finish;"
)

psql -X -q -v ON_ERROR_STOP=1 <<<"$script"

if [ "$mode" = "preview" ]; then
  echo "run-migrations: PREVIEW OK, ${#pending[@]} file(s) ran and were rolled back; nothing changed"
else
  echo "run-migrations: APPLIED ${#pending[@]} file(s)"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Migrations ($mode)"
    echo "Target: \`${EXPECTED_SERVER}/${EXPECTED_DATABASE}\` as \`${EXPECTED_ROLE:-migrator}\`"
    echo
    for f in "${pending[@]}"; do echo "- \`$(basename "$f")\`"; done
    echo
    if [ "$mode" = "preview" ]; then echo "Rolled back. Nothing was changed."; else echo "Committed."; fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
