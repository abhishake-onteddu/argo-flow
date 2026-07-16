# Argo SSO via Azure Entra ID

Entra is a hosted OIDC provider — no in-cluster IdP, no split-horizon. RBAC is
driven by **security groups** L1/L2/L3: the token's `groups` claim carries their
**Object IDs (GUIDs)**, and the `rbac-rule` annotations in
`manifests/rbac/humans.yaml` match those GUIDs. (Cloud-only Entra groups can't put
group *names* in the token — that's an Azure limitation, hence GUIDs.)

## 1. Register the application

Entra admin center (entra.microsoft.com) → **App registrations** → **New registration**

- **Name:** `argo-runbook-lab`, single-tenant
- **Redirect URI** (platform **Web**): `http://localhost:2746/oauth2/callback`
  (Entra allows `http` only for `localhost` — and it must be `localhost` here to
  match the address the browser uses. For a real host, use HTTPS.)
- From **Overview**, copy the **Application (client) ID** and **Directory (tenant) ID**.

## 2. Client secret

Certificates & secrets → **New client secret** → copy the **Value** (not the Secret ID).

## 3. Groups claim

Token configuration → **Add groups claim** → **Security groups** → check ID + Access
tokens. Without this the token carries no `groups` claim and nobody maps to anything.

## 4. Security groups — one per tier

Entra ID → **Groups** → create three security groups (e.g. `L1`, `L2`, `L3`) and copy
each **Object ID**. Add each person to the group for their tier. Then put the GUIDs in:

- `manifests/rbac/humans.yaml` — the three `rbac-rule` annotations (`'<guid>' in groups`)
- `manifests/argo-workflows/workflow-controller-configmap.yaml` — `filterGroupsRegex`
  (the three GUIDs) and the `issuer` **tenant ID**

## 5. Seal the creds and ship it (GitOps)

The client secret is committed as a **SealedSecret** (encrypted); ArgoCD applies it.

```bash
make bootstrap                                        # if not already: cluster + ArgoCD + sealed-secrets
make seal-secret CLIENT_ID=<CLIENT_ID> CLIENT_SECRET=<SECRET_VALUE>
git add -A && git commit -m "entra sso" && git push   # ArgoCD syncs config + SealedSecret
make port-forward                                      # Argo UI on http://localhost:2746
```

Open http://localhost:2746 → **Login** → sign in with an assigned Entra account.
Use `localhost` (not `127.0.0.1`) so the address matches the registered redirect URI.

## Notes

- `--auth-mode=client` stays enabled alongside `sso`, so the ServiceAccount-token
  login (the strong-audit path) still works for the test scripts.
- Cluster egress to `login.microsoftonline.com` is required (k3d/Colima has it).
- Audit-trail caveat: under `--auth-mode=sso` the k8s audit log records the mapped
  ServiceAccount, not the human — the human identity lives in Argo Server's logs.
  Token-based actions still record the real caller.
- Alternative to GUIDs: Entra **app roles** named `runbooks-l1/l2/l3` land in a
  `roles` claim with readable names; set `customGroupClaimName: roles` in the sso
  block and match `'runbooks-l2' in groups`. Cleaner rules, but you manage role
  assignment per-app instead of via central groups.
