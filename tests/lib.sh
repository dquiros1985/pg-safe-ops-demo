# shellcheck shell=bash
# Minimal test helpers. Source this file; call finish at the end.

TESTS_PASSED=0
TESTS_FAILED=0
LAST_OUTPUT=""

# expect EXIT_CODE "description" command [args...]
expect() {
  local want="$1" desc="$2" rc=0
  shift 2
  LAST_OUTPUT=$("$@" 2>&1) || rc=$?
  if [ "$rc" = "$want" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ok    $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL  $desc (exit $rc, wanted $want)"
    printf '%s\n' "$LAST_OUTPUT" | sed 's/^/        | /'
  fi
}

# expect_output "description" "substring"   (checks the previous expect's output)
expect_output() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" <<<"$LAST_OUTPUT"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ok    $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL  $desc (output lacks: $needle)"
    printf '%s\n' "$LAST_OUTPUT" | sed 's/^/        | /'
  fi
}

finish() {
  echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
  [ "$TESTS_FAILED" -eq 0 ]
}
