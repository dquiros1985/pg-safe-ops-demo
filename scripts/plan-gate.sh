#!/usr/bin/env bash
# Fails when a Terraform plan would delete or replace any resource.
#
#   terraform show -json plan.tfplan | scripts/plan-gate.sh
#   scripts/plan-gate.sh plan.json
#
# Exit codes: 0 = no deletes or replaces, 1 = at least one, 2 = bad input.
# A replace shows up in the plan as ["delete","create"] or ["create","delete"],
# so looking for "delete" in the action list catches both.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "plan-gate: jq is required" >&2; exit 2; }

src="${1:--}"
if [ "$src" != "-" ] && [ ! -f "$src" ]; then
  echo "plan-gate: no such file: $src" >&2
  exit 2
fi
json=$(cat -- "$src")

if ! jq -e 'type == "object" and has("format_version")' >/dev/null 2>&1 <<<"$json"; then
  echo "plan-gate: input is not the output of 'terraform show -json <plan>'" >&2
  exit 2
fi

summary=$(jq -r '
  [.resource_changes[]? | .change.actions] as $a
  | "create=\([$a[] | select(. == ["create"])] | length)"
  + " update=\([$a[] | select(. == ["update"])] | length)"
  + " replace=\([$a[] | select(length == 2 and index("delete") != null)] | length)"
  + " delete=\([$a[] | select(. == ["delete"])] | length)"
' <<<"$json")

offenders=$(jq -r '
  .resource_changes[]?
  | select(.change.actions | index("delete") != null)
  | (if .change.actions == ["delete"] then "DELETE " else "REPLACE" end)
    + "  " + .address
    + (if .action_reason then "  (" + .action_reason + ")" else "" end)
' <<<"$json")

echo "plan-gate: $summary"
if [ -n "$offenders" ]; then
  echo "plan-gate: FAIL, this plan destroys resources:" >&2
  printf '  %s\n' "$offenders" >&2
  exit 1
fi
echo "plan-gate: PASS, nothing is deleted or replaced"
