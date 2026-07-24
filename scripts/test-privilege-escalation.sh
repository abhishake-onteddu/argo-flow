#!/usr/bin/env bash
# test-rbac.sh proves the model is CONFIGURED correctly.
# This proves it cannot be BYPASSED. These are the four attacks that matter.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Attack 1: L1 submits a raw Workflow choosing its own runner ServiceAccount.
#
# This is the hole. `create workflows` says nothing about which SA the
# resulting POD runs as. Without workflowRestrictions.templateReferencing=Secure
# this succeeds, the pod runs as runbook-l3-runner, and the suspend/resume
# gate is decorative -- never even reached.
# ---------------------------------------------------------------------------
echo "=== Attack 1: L1 picks its own runner SA via a raw Workflow ==="
cat > "$TMP/evil.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: escalation-attempt-
  namespace: runbooks
spec:
  serviceAccountName: runbook-l3-runner
  entrypoint: pwn
  templates:
    - name: pwn
      container:
        image: bitnami/kubectl:1.31
        command: [sh, -c]
        args: ["kubectl get secrets -A"]
YAML

TOK="$(kubectl -n argo create token l1-user --duration=5m)"
if kubectl --token="$TOK" create -f "$TMP/evil.yaml" >/dev/null 2>&1; then
  fail "L1 submitted a raw Workflow with an arbitrary serviceAccountName"
  kubectl delete wf -n argo -l '!runbook.level' --ignore-not-found >/dev/null 2>&1 || true
else
  pass "L1 cannot submit a raw Workflow (templateReferencing: Secure)"
fi

# ---------------------------------------------------------------------------
# Attack 2: L1 resumes its own suspended workflow.
# ---------------------------------------------------------------------------
echo
echo "=== Attack 2: L1 approves its own request ==="
WF="$(as_user l1-user -- submit --from workflowtemplate/restart-deployment \
      -n argo -p requestedBy=l1-user -o name 2>/dev/null | tail -1)"
WF="${WF#Workflow/}"

if [ -z "$WF" ]; then
  fail "could not submit restart-deployment as l1-user (setup problem)"
else
  if wait_for_suspend "$WF" argo 120; then
    if as_user l1-user -- resume "$WF" -n argo >/dev/null 2>&1; then
      fail "L1 resumed its own suspended workflow -- APPROVAL GATE BYPASSED"
    else
      pass "L1 cannot resume its own suspended workflow"
    fi
  else
    fail "workflow $WF never suspended"
  fi
  kubectl delete wf "$WF" -n argo --ignore-not-found >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Attack 3: L2 approves an L3-only operation.
#
# Kubernetes RBAC has no object-level granularity -- a `patch workflows` grant
# covers EVERY workflow in the namespace. Namespace separation is the only
# thing making this fail.
# ---------------------------------------------------------------------------
echo
echo "=== Attack 3: L2 approves an L3-only operation ==="
WF3="$(as_user l1-user -- submit --from workflowtemplate/cross-namespace-maintenance \
       -n argo-l3 -o name 2>/dev/null | tail -1)"
WF3="${WF3#Workflow/}"

if [ -z "$WF3" ]; then
  fail "could not submit cross-namespace-maintenance as l1-user (setup problem)"
else
  if wait_for_suspend "$WF3" argo-l3 120; then
    if as_user l2-approver -- resume "$WF3" -n argo-l3 >/dev/null 2>&1; then
      fail "L2 approved an L3-only operation -- namespace isolation broken"
    else
      pass "L2 cannot approve an L3-only operation"
    fi
    if as_user l3-approver -- resume "$WF3" -n argo-l3 >/dev/null 2>&1; then
      pass "L3 CAN approve an L3-only operation"
    else
      fail "L3 could not approve an L3-only operation"
    fi
  else
    fail "workflow $WF3 never suspended"
  fi
  kubectl delete wf "$WF3" -n argo-l3 --ignore-not-found >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Attack 4: L1 reads a runner's ServiceAccount token directly.
# ---------------------------------------------------------------------------
echo
echo "=== Attack 4: L1 steals a runner token ==="
cannot l1-user argo get secrets "L1 cannot read runner ServiceAccount tokens"
if kubectl --token="$TOK" -n argo create token runbook-l3-runner >/dev/null 2>&1; then
  fail "L1 minted a token for runbook-l3-runner"
else
  pass "L1 cannot mint a token for runbook-l3-runner"
fi

summary
