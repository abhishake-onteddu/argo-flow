#!/usr/bin/env bash
# L1: read-only runbook. No approval gate. Should complete unattended.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

WF="$(as_user l1-user -- submit --from workflowtemplate/get-pod-status -n argo -o name | tail -1)"
WF="${WF#Workflow/}"
echo "submitted: $WF"

wait_for_phase "$WF" argo Succeeded 120 \
  && pass "L1 read-only runbook completed without approval" \
  || fail "L1 runbook did not succeed"

# It must have run as the l1 runner, not anything else.
actual="$(kubectl get wf "$WF" -n argo -o jsonpath='{.spec.serviceAccountName}')"
[ "$actual" = "runbook-l1-runner" ] \
  && pass "executed as runbook-l1-runner" \
  || fail "executed as '$actual' (expected runbook-l1-runner)"

kubectl logs -n argo -l "workflows.argoproj.io/workflow=$WF" --tail=20 2>/dev/null || true
summary
