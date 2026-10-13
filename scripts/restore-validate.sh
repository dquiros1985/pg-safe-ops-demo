#!/usr/bin/env bash
# Proves that a point-in-time restore holds exactly the data that existed at
# the restore point, using the rows in ops.restore_markers.
#
#   scripts/restore-validate.sh \
#     --source   "host=... dbname=appdb user=..." \
#     --restored "host=... dbname=appdb user=..." \
#     --restore-point 2026-01-01T06:00:00Z \
#     [--fresh-marker 42]
#
# Checks:
#   1. the source has at least one marker at or before the restore point
#   2. count and checksum of those markers are identical on both sides
#   3. the restored copy has no marker after the restore point
#   4. the marker written just before the restore (--fresh-marker) is absent
#
# Exit codes: 0 = restore verified, 1 = mismatch, 2 = usage or connection error.
set -euo pipefail

source_dsn="" restored_dsn="" restore_point="" fresh_marker=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source)        source_dsn="$2"; shift 2 ;;
    --restored)      restored_dsn="$2"; shift 2 ;;
    --restore-point) restore_point="$2"; shift 2 ;;
    --fresh-marker)  fresh_marker="$2"; shift 2 ;;
    *) echo "restore-validate: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ -z "$source_dsn" ] || [ -z "$restored_dsn" ] || [ -z "$restore_point" ]; then
  echo "usage: restore-validate.sh --source DSN --restored DSN --restore-point TS [--fresh-marker ID]" >&2
  exit 2
fi

# Same text rendering of timestamps on both sides, whatever the server default.
export PGTZ=UTC

q() {
  local dsn="$1" sql="$2"
  psql -X -A -t -q -F '|' -v ON_ERROR_STOP=1 -v rp="$restore_point" -v fresh="${fresh_marker:-0}" "$dsn" <<<"$sql"
}

fingerprint_sql=$(cat <<'SQL'
SELECT count(*),
       COALESCE(md5(string_agg(id || '|' || created_at || '|' || source || '|' || payload, ',' ORDER BY id)), 'none')
FROM ops.restore_markers
WHERE created_at <= :'rp'::timestamptz;
SQL
)

if ! src=$(q "$source_dsn" "$fingerprint_sql"); then
  echo "restore-validate: cannot query the source" >&2; exit 2
fi
if ! dst=$(q "$restored_dsn" "$fingerprint_sql"); then
  echo "restore-validate: cannot query the restored copy" >&2; exit 2
fi
after=$(q "$restored_dsn" "SELECT count(*) FROM ops.restore_markers WHERE created_at > :'rp'::timestamptz;")
fresh_found=$(q "$restored_dsn" "SELECT count(*) FROM ops.restore_markers WHERE id = :'fresh'::bigint;")

IFS='|' read -r src_count src_sum <<<"$src"
IFS='|' read -r dst_count dst_sum <<<"$dst"

fail=0
report() {
  local status="$1" what="$2" detail="$3"
  printf '  %-5s %-34s %s\n' "$status" "$what" "$detail"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "| $status | $what | $detail |" >>"$GITHUB_STEP_SUMMARY"
  fi
  if [ "$status" = "FAIL" ]; then fail=1; fi
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### Restore validation (restore point %s)\n\n| Result | Check | Detail |\n|---|---|---|\n' \
    "$restore_point" >>"$GITHUB_STEP_SUMMARY"
fi

echo "restore-validate: restore point $restore_point"
if [ "$src_count" -ge 1 ]; then
  report ok "markers before restore point" "$src_count on source"
else
  report FAIL "markers before restore point" "source has none, nothing to compare"
fi
if [ "$src_count" = "$dst_count" ]; then
  report ok "marker count matches" "$dst_count"
else
  report FAIL "marker count matches" "source=$src_count restored=$dst_count"
fi
if [ "$src_sum" = "$dst_sum" ]; then
  report ok "marker checksum matches" "$dst_sum"
else
  report FAIL "marker checksum matches" "source=$src_sum restored=$dst_sum"
fi
if [ "$after" = "0" ]; then
  report ok "nothing after restore point" "0 rows"
else
  report FAIL "nothing after restore point" "$after rows"
fi
if [ -n "$fresh_marker" ]; then
  if [ "$fresh_found" = "0" ]; then
    report ok "fresh marker absent" "id $fresh_marker"
  else
    report FAIL "fresh marker absent" "id $fresh_marker is present"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "restore-validate: FAIL" >&2
  exit 1
fi
echo "restore-validate: PASS"
