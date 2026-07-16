#!/usr/bin/env bash
# Shared helpers. Every assertion either passes loudly or exits non-zero.
set -uo pipefail

PASS=0
FAIL=0

pass() { printf '\033[32mPASS\033[0m: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '\033[31mFAIL\033[0m: %s\n' "$1"; FAIL=$((FAIL + 1)); }

summary() {
  echo
  echo "----------------------------------------"
  printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
  echo "----------------------------------------"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

sa() { echo "system:serviceaccount:argo:$1"; }

# Assert a subject CAN do something.
# usage: can <sa> <namespace> <verb> <resource> [description]
can() {
  local s="$1" ns="$2" verb="$3" res="$4"
  local desc="${5:-$1 can $verb $res in $ns}"
  if kubectl auth can-i "$verb" "$res" -n "$ns" --as="$(sa "$s")" -q 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc  (expected ALLOWED, got denied)"
  fi
}

# Assert a subject CANNOT do something.
# This is the important direction. A suite that only tests the happy path
# proves nothing at all about a privilege model.
cannot() {
  local s="$1" ns="$2" verb="$3" res="$4"
  local desc="${5:-$1 CANNOT $verb $res in $ns}"
  if kubectl auth can-i "$verb" "$res" -n "$ns" --as="$(sa "$s")" -q 2>/dev/null; then
    fail "$desc  (expected DENIED, got allowed -- privilege escalation)"
  else
    pass "$desc"
  fi
}

# Mint a short-lived token for a ServiceAccount and run argo as that identity.
# usage: as_user <sa> -- <argo args...>
as_user() {
  local s="$1"
  shift 2 # drop sa and the literal --
  local tok
  tok="$(kubectl -n argo create token "$s" --duration=10m)" || return 1
  ARGO_TOKEN="Bearer $tok" argo "$@"
}

# Poll until a workflow reaches a phase.
wait_for_phase() {
  local wf="$1" ns="$2" want="$3" t="${4:-120}" got=""
  for _ in $(seq "$t"); do
    got="$(kubectl get wf "$wf" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$got" = "$want" ] && return 0
    case "$got" in Failed | Error) return 1 ;; esac
    sleep 1
  done
  echo "timeout: $wf never reached $want (last=${got:-<none>})" >&2
  return 1
}

# Poll until the workflow is parked on a Suspend node.
wait_for_suspend() {
  local wf="$1" ns="$2" t="${3:-120}"
  for _ in $(seq "$t"); do
    if kubectl get wf "$wf" -n "$ns" -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
nodes = d.get("status", {}).get("nodes", {}).values()
sys.exit(0 if any(n.get("type") == "Suspend" and n.get("phase") == "Running" for n in nodes) else 1)
'; then return 0; fi
    sleep 1
  done
  return 1
}
