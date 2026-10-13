#!/usr/bin/env bash
# Refuses SQL files that delete rows or drop objects unless the run asks for it
# twice: DESTRUCTIVE=true and CONFIRM equal to the pinned target.
#
#   EXPECTED_TARGET=pgdemo-dev-psql/appdb DESTRUCTIVE=false scripts/sql-guard.sh migrations/*.sql
#
# Flags DELETE, TRUNCATE and DROP (including ALTER TABLE ... DROP COLUMN).
# Ignores comments, string literals and foreign-key rules (ON DELETE ...).
# It errs on the side of flagging: DROP DEFAULT or a DELETE inside a function
# body also needs the confirmation. Transaction control (BEGIN/COMMIT/ROLLBACK)
# is rejected because run-migrations.sh owns the transaction.
#
# Exit codes: 0 = allowed, 1 = refused, 2 = usage error.
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: sql-guard.sh FILE.sql..." >&2
  exit 2
fi

destructive="${DESTRUCTIVE:-false}"
confirm="${CONFIRM:-}"
target="${EXPECTED_TARGET:-}"

# Prints "file:line: text" for every match of the pattern in $2, after
# blanking comments and strings without changing line numbers.
scan() {
  local pattern="$1" file="$2"
  PATTERN="$pattern" perl -0777 -ne '
    my $keep_newlines = sub { my $s = shift; $s =~ tr/\n//cd; return $s };
    s{/\*.*?\*/}{ $keep_newlines->($&) }gse;      # block comments
    s{--[^\n]*}{}g;                               # line comments
    s{\x27(?:[^\x27]|\x27\x27)*\x27}{ $keep_newlines->($&) }gse;  # strings
    s{\bON(\s+)(DELETE|UPDATE)\b}{ON${1}RULE}gi;    # FK actions
    my $n = 0;
    for my $line (split /\n/, $_, -1) {
      $n++;
      print "$ARGV:$n: $line\n" if $line =~ /$ENV{PATTERN}/i;
    }
  ' "$file"
}

destructive_hits=""
txn_hits=""
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "sql-guard: no such file: $f" >&2
    exit 2
  fi
  hits=$(scan '\b(DELETE|TRUNCATE|DROP)\b' "$f")
  if [ -n "$hits" ]; then destructive_hits+="$hits"$'\n'; fi
  hits=$(scan '^\s*(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION)\s*;' "$f")
  if [ -n "$hits" ]; then txn_hits+="$hits"$'\n'; fi
done

if [ -n "$txn_hits" ]; then
  echo "sql-guard: REFUSED, migrations must not control the transaction:" >&2
  printf '%s' "$txn_hits" >&2
  exit 1
fi

if [ -z "$destructive_hits" ]; then
  if [ "$destructive" = "true" ]; then
    echo "sql-guard: destructive=true was set but no destructive statement was found; nothing extra is allowed"
  fi
  echo "sql-guard: PASS, no DELETE/TRUNCATE/DROP"
  exit 0
fi

echo "sql-guard: destructive statements found:"
printf '%s' "$destructive_hits"

if [ "$destructive" != "true" ]; then
  echo "sql-guard: REFUSED. Re-run with destructive=true and confirm=<server>/<database>." >&2
  exit 1
fi
if [ -z "$target" ]; then
  echo "sql-guard: REFUSED, EXPECTED_TARGET is not set, so the confirmation cannot be checked" >&2
  exit 2
fi
if [ "$confirm" != "$target" ]; then
  echo "sql-guard: REFUSED, confirmation '$confirm' does not match the pinned target '$target'" >&2
  exit 1
fi
echo "sql-guard: ALLOWED, destructive run confirmed for $target"
