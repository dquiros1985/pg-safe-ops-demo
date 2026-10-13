#!/usr/bin/env bash
# Unit tests for scripts/plan-gate.sh. No cloud, no Terraform needed: the
# fixtures are trimmed copies of `terraform show -json` output.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
gate="$root/scripts/plan-gate.sh"
fx="$root/tests/fixtures"

echo "plan-gate"
expect 0 "no changes passes"                    "$gate" "$fx/plan-noop.json"
expect 0 "create and update pass"               "$gate" "$fx/plan-create-update.json"
expect_output "summary counts creates"          "create=1 update=1 replace=0 delete=0"
expect 1 "delete fails"                         "$gate" "$fx/plan-delete.json"
expect_output "names the deleted address"       "DELETE   module.postgres.azurerm_management_lock.this"
expect 1 "replace (delete then create) fails"   "$gate" "$fx/plan-replace.json"
expect_output "shows the reason"                "replace_because_cannot_update"
expect 1 "create-before-destroy replace fails"  "$gate" "$fx/plan-replace-cbd.json"
expect 0 "plan without resource_changes passes" "$gate" "$fx/plan-empty.json"
expect 2 "non-plan JSON is rejected"            "$gate" "$fx/not-a-plan.json"
expect 2 "missing file is rejected"             "$gate" "$fx/does-not-exist.json"
expect 1 "reads the plan from stdin"            sh -c "\"$gate\" < \"$fx/plan-delete.json\""

finish
