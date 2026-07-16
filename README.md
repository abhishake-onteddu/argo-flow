# argo-runbook-lab

A local Kubernetes environment for testing **Argo Workflows with L1/L2/L3 controlled
privilege escalation** — the model described in ADR-0020.

Runs on Colima, deployed via ArgoCD (GitOps). SSO is via Azure Entra ID (see docs/entra-setup.md);
the core approval model needs no cloud account and works with token auth alone.

---

## What this proves

The ADR's central claim:

> Approval is enforced via RBAC, not workflow parameters. Actual approval is
> determined by who resumes the workflow, and by RBAC permissions.

This repo turns that sentence into executable assertions. There is no `echo
"deployment successful"` anywhere. Every test either mutates a real Deployment
or is rejected by a real API server.

```
L1 submits request
      │
      ▼
 precheck runs as runbook-l1-runner   (read-only)
      │
      ▼
 workflow SUSPENDS  ◄──── L1 tries to resume → 403 Forbidden
      │
      │  L2 runs `argo resume` → PATCH on the Workflow object
      │  This IS the approval. There is no separate approval API.
      ▼
 restart runs as runbook-l2-runner    (mutating, namespace-scoped)
      │
      ▼
 Deployment restarted. Audit log shows the runner did it, not the human.
```

---

## Prerequisites

```bash
brew install k3d kubectl argo kubeseal

colima start --runtime docker --cpu 4 --memory 9 --disk 30 --vm-type vz
```

Colima **must** use `--runtime docker` — k3d talks to the Docker API.

## Layout (GitOps)

Everything except the cluster and the ArgoCD/sealed-secrets bootstrap is deployed
**declaratively via ArgoCD**, from Kustomize directories in this repo:

```
cluster/                  k3d config (infra, not GitOps)
bootstrap/root-app.yaml   app-of-apps root Application
apps/                     one ArgoCD Application per component (sync-waves order them)
manifests/                the actual resources, each a Kustomize dir:
  argo-workflows/           remote Argo install + patches (Secure, SSO, argo-server args) + SealedSecret
  rbac/                     runner + human SAs, Roles/Bindings, rbac-rule annotations
  runbooks/                 the L1/L2/L3 WorkflowTemplates
  demo-apps/                demo-app Deployment + demo-stateful StatefulSet
docs/entra-setup.md       Azure Entra app-registration walkthrough
```

## Setup (GitOps via ArgoCD)

ArgoCD syncs from a **git repo URL**, so this must be pushed to a remote
(GitHub/GitLab) that the cluster can reach.

```bash
make bootstrap                                    # cluster + ArgoCD + sealed-secrets
make seal-secret CLIENT_ID=<id> CLIENT_SECRET=<v> # encrypt Entra creds -> committed SealedSecret
# set your tenant ID in manifests/argo-workflows/workflow-controller-configmap.yaml
make set-repo REPO_URL=<https://github.com/you/argo-runbook-lab.git>
git add -A && git commit -m "gitops" && git push
make gitops-up                                    # apply the app-of-apps; ArgoCD syncs the rest
make argocd-ui                                    # watch it converge (or: kubectl -n argocd get applications)
```

Then validate:

| Command | What it does |
|---|---|
| `make test-rbac` | Permission matrix. Fast, no workflows. Run this first. |
| `make test-l1` | Read-only runbook completes with no approval. |
| `make test-l2` | Request → suspend → L1 denied → L2 approves → restart → verify. |
| `make test-escalation` | Four bypass attacks. All must be denied. |
| `make show-audit` | Chain of custody from the Kubernetes audit log. |

## Manual demo

```bash
make port-forward &                          # Argo UI at :2746
kubectl -n argo create token l2-approver     # paste as the UI bearer token

make request-restart      # suspends
make approve-as-l1        # denied
make approve-as-l2        # resumes, restarts, verifies
make show-audit
```

`make show-audit` prints something like:

```
TIME      IDENTITY                VERB    RESOURCE     NAME                      NS                RESULT
09:14:02  argo:l1-user            create  workflows    restart-deployment-x7k2p  argo              ok
09:15:31  argo:l1-user            patch   workflows    restart-deployment-x7k2p  argo              DENIED
09:16:44  argo:l2-approver        patch   workflows    restart-deployment-x7k2p  argo              ok
09:16:49  argo:runbook-l2-runner  patch   deployments  demo-app                  runbook-demo-dev  ok
09:18:10  argo:l2-approver        patch   workflows    cross-ns-maint-9bb41      argo-l3           DENIED
```

Read top to bottom: who asked, who was refused, who approved, which
ServiceAccount executed, and what a cross-tier approval attempt looks like
when it's blocked.

---

## Two design decisions worth understanding

### 1. `templateReferencing: Secure` is load-bearing

`create workflows` says nothing about which ServiceAccount the resulting *pod*
runs as. Without this one line in `workflow-controller-configmap`, an L1 user
submits:

```yaml
spec:
  serviceAccountName: runbook-l3-runner   # L1 picks its own executor
```

…and the entire approval gate is bypassed — never even reached. `Secure` forces
every Workflow to be a `workflowTemplateRef` with no spec override, so
`serviceAccountName` is pinned inside a WorkflowTemplate that L1 cannot modify.

Attack 1 in `test-privilege-escalation.sh` submits exactly that manifest.

### 2. Namespace separation is the *only* thing that stops L2 approving L3 work

Kubernetes RBAC has no object-level granularity. A `patch workflows` grant
applies to **every** workflow in the namespace. There is no way to express
"L2 may resume this workflow but not that one."

So L3 workflows live in `argo-l3`, where L2 has no permissions at all. This
isn't defence-in-depth — it's load-bearing. Any design that puts L2 and L3
workflows in one namespace cannot enforce the distinction the ADR requires.

---

## What is deliberately not here

This is Phase 1. It targets a plain nginx Deployment on purpose.

| Not included | Why |
|---|---|
| The four-service demo app | Runbooks are parameterized on `namespace` + `deployment`. Pointing them at a real app is a values change, not a rewrite. |
| Argo Events, MinIO, Helm, CI/CD pipeline | Nothing in the approval model depends on them. |
| Prometheus / Grafana / Loki | The audit log is the evidence that matters here. |

## SSO via Azure Entra ID

Argo runs `--auth-mode=sso` **alongside** `--auth-mode=client`. Entra **security
groups** (L1/L2/L3) map to the ServiceAccounts via the `rbac-rule` annotations in
`manifests/rbac/humans.yaml`, which match the group **Object IDs (GUIDs)** carried
in the `groups` claim (cloud-only Entra groups can't put names in the token).
`filterGroupsRegex` in the sso block trims the claim to the three groups.

### Set up the Azure app registration

Full walkthrough in `docs/entra-setup.md`; the short version:

1. **Entra admin center** (entra.microsoft.com) → **App registrations** → **New registration**
   - Name `argo-runbook-lab`, single-tenant
   - Redirect URI (**Web**): `http://localhost:2746/oauth2/callback`
     (Entra allows `http` only for `localhost`, not `127.0.0.1`)
2. From the app **Overview**, copy the **Application (client) ID** and **Directory (tenant) ID**.
3. **Certificates & secrets** → **New client secret** → copy the **Value** (not the Secret ID).
4. **Token configuration** → **Add groups claim** → **Security groups** (ID + Access tokens).
5. **Groups** → create three security groups; copy each **Object ID** into the three
   `rbac-rule` annotations in `manifests/rbac/humans.yaml` and into `filterGroupsRegex`
   + the `issuer` tenant ID in `manifests/argo-workflows/workflow-controller-configmap.yaml`.
6. Add each person to the appropriate group (no group = authenticates but maps to nothing).
7. Seal the client creds and let ArgoCD apply everything:

   ```bash
   make seal-secret CLIENT_ID=<CLIENT_ID> CLIENT_SECRET=<SECRET_VALUE>
   git add -A && git commit -m "sso" && git push     # ArgoCD syncs the SealedSecret + config
   ```

   Then open http://localhost:2746 → **Login** → sign in with the assigned Entra account.
   Use `localhost` (not `127.0.0.1`) so the address matches the registered redirect URI.

Audit-trail caveat: under `--auth-mode=sso` Argo acts *as* the mapped
ServiceAccount, so the Kubernetes audit log records `argo:l2-approver` (the SA),
**not** the human — the human's identity lives only in Argo Server's logs. The
token path (`--auth-mode=client`, used by the test scripts) still records the real
caller, so "Kubernetes audit logs prove who approved" holds for token auth but
becomes "Argo Server logs + Kubernetes audit logs" for SSO. Worth knowing before
someone reads a test report as stronger than it is.

---

## Status

Executed against a live k3d cluster (Argo Workflows v3.6, k3s 1.31). The L1/L2/L3
runbooks run, the approval gate and escalation blocks hold, the audit log records
the chain of custody, and SSO works against Azure Entra ID.

Run `make test-rbac` first. It needs no workflows and will tell you immediately
whether the permission model landed correctly.

---

## Local testing only

The ServiceAccounts here stand in for real humans. Nothing in this repo should
be applied to a cluster you care about.
