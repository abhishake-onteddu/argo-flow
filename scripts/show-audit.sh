#!/usr/bin/env bash
# Reconstruct the chain of custody from the Kubernetes audit log:
# who requested, who approved, which ServiceAccount executed, what was denied.
set -euo pipefail
LOG="${1:-$(dirname "$0")/../.audit/audit.log}"
[ -f "$LOG" ] || { echo "no audit log at $LOG"; exit 1; }

python3 - "$LOG" <<'PY'
import json, sys

rows = []
for line in open(sys.argv[1], errors="ignore"):
    try: e = json.loads(line)
    except Exception: continue
    o = e.get("objectRef", {})
    res, verb = o.get("resource"), e.get("verb")
    if res not in ("workflows", "workflowtemplates", "deployments", "deployments/scale"):
        continue
    if verb not in ("create", "patch", "update", "delete"):
        continue
    code = e.get("responseStatus", {}).get("code", 0)
    user = e.get("user", {}).get("username", "?")
    user = user.replace("system:serviceaccount:", "")
    rows.append((
        e.get("requestReceivedTimestamp", "")[11:19],
        user, verb, res,
        (o.get("name") or "-")[:34],
        o.get("namespace", "-"),
        "DENIED" if code == 403 else "ok",
    ))

if not rows:
    print("no relevant audit entries yet"); sys.exit(0)

hdr = ("TIME", "IDENTITY", "VERB", "RESOURCE", "NAME", "NS", "RESULT")
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
fmt = "  ".join("{:<%d}" % x for x in w)
print(fmt.format(*hdr))
print("-" * (sum(w) + 2 * (len(w) - 1)))
for r in rows:
    print(fmt.format(*[str(x) for x in r]))
PY
