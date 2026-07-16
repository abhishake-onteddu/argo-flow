#!/usr/bin/env bash
# Pure RBAC assertions. No workflows submitted. Run this first --
# if it fails, nothing downstream is trustworthy.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== L1 (requester) ==="
can    l1-user argo    create workflows
can    l1-user argo    get    workflows
cannot l1-user argo    patch  workflows        "l1-user CANNOT resume (patch) workflows"
cannot l1-user argo    update workflows        "l1-user CANNOT resume (update) workflows"
cannot l1-user argo    update workflowtemplates "l1-user CANNOT repoint a runner ServiceAccount"
cannot l1-user argo    get    secrets          "l1-user CANNOT read Secrets"
cannot l1-user runbook-demo-dev patch deployments "l1-user CANNOT patch Deployments directly"
can    l1-user argo-l3 create workflows        "l1-user CAN request an L3 operation"
cannot l1-user argo-l3 patch  workflows        "l1-user CANNOT resume L3 workflows"

echo
echo "=== L2 (approver) ==="
can    l2-approver argo    patch  workflows    "l2-approver CAN resume workflows in argo"
cannot l2-approver argo-l3 patch  workflows    "l2-approver CANNOT resume L3 workflows"
cannot l2-approver argo-l3 update workflows    "l2-approver CANNOT update L3 workflows"
cannot l2-approver runbook-demo-dev patch deployments \
       "l2-approver CANNOT patch Deployments directly (only the runner may)"
cannot l2-approver argo    get    secrets      "l2-approver CANNOT read Secrets"

echo
echo "=== L3 (senior approver) ==="
can    l3-approver argo    patch  workflows    "l3-approver CAN resume workflows in argo"
can    l3-approver argo-l3 patch  workflows    "l3-approver CAN resume L3 workflows"

echo
echo "=== Runner ServiceAccounts (executors) ==="
cannot runbook-l1-runner runbook-demo-dev patch deployments \
       "runbook-l1-runner is strictly read-only"
can    runbook-l1-runner runbook-demo-dev get   pods \
       "runbook-l1-runner CAN read pods"
can    runbook-l2-runner runbook-demo-dev patch deployments \
       "runbook-l2-runner CAN patch Deployments in runbook-demo-dev"
cannot runbook-l2-runner default patch deployments \
       "runbook-l2-runner is inert outside runbook-demo-dev"
cannot runbook-l2-runner runbook-demo-dev get secrets \
       "runbook-l2-runner CANNOT read Secrets"

summary
