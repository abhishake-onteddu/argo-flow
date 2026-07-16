#!/usr/bin/env bash
# The full happy path, with real verification that a restart occurred and that
# the RUNNER -- not the human -- made the Kubernetes change.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

NS=runbook-demo-dev
DEP=demo-app

before="$(kubectl get pods -n "$NS" -l app="$DEP" -o jsonpath='{.items[*].metadata.name}')"
echo "pods before: $before"

echo "--- L1 submits restart request ---"
WF="$(as_user l1-user -- submit --from workflowtemplate/restart-deployment \
      -n argo -p requestedBy=l1-user -o name | tail -1)"
WF="${WF#Workflow/}"
echo "workflow: $WF"

wait_for_suspend "$WF" argo 120 \
  && pass "workflow entered Suspended state" \
  || { fail "workflow never suspended"; summary; }

echo "--- L1 attempts to resume (must be denied) ---"
if as_user l1-user -- resume "$WF" -n argo >/dev/null 2>&1; then
  fail "L1 resumed the workflow"
else
  pass "L1 resume denied by Kubernetes RBAC"
fi

echo "--- L2 resumes: this IS the approval ---"
if as_user l2-approver -- resume "$WF" -n argo >/dev/null 2>&1; then
  pass "L2 resumed the workflow"
else
  fail "L2 could not resume"; summary
fi

wait_for_phase "$WF" argo Succeeded 240 \
  && pass "workflow Succeeded" \
  || fail "workflow did not succeed"

after="$(kubectl get pods -n "$NS" -l app="$DEP" -o jsonpath='{.items[*].metadata.name}')"
echo "pods after:  $after"
[ "$before" != "$after" ] \
  && pass "pod set changed -- the restart really happened" \
  || fail "pod names identical -- deployment was NOT actually restarted"

kubectl rollout status "deploy/$DEP" -n "$NS" --timeout=60s >/dev/null 2>&1 \
  && pass "rollout healthy" || fail "rollout unhealthy"

echo "--- which identity patched the Deployment? ---"
LOG="$(dirname "$0")/../.audit/audit.log"
if [ -f "$LOG" ]; then
  actor="$(python3 - "$LOG" <<'PY'
import json, sys
actor = ""
for line in open(sys.argv[1], errors="ignore"):
    try: e = json.loads(line)
    except Exception: continue
    o = e.get("objectRef", {})
    if o.get("resource") == "deployments" and e.get("verb") in ("patch", "update"):
        if e.get("responseStatus", {}).get("code", 200) < 300:
            actor = e.get("user", {}).get("username", "")
print(actor)
PY
)"
  case "$actor" in
    *runbook-l2-runner*) pass "Deployment patched by runbook-l2-runner, not by the human" ;;
    "")                  fail "no successful Deployment mutation found in audit log" ;;
    *)                   fail "Deployment patched by unexpected identity: $actor" ;;
  esac
else
  fail "audit log not found at $LOG"
fi

summary
