SHELL       := /bin/bash
REPO        := $(shell pwd)
CLUSTER     := runbook-lab
KUBECTL     := kubectl
ARGOCD_URL  := https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
SEALED_URL  := https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml

.DEFAULT_GOAL := help
.PHONY: help preflight cluster bootstrap seal-secret set-repo gitops-up \
        port-forward argocd-ui test-rbac test-l1 test-l2 test-escalation test-e2e \
        request-restart approve-as-l1 approve-as-l2 show-audit cleanup

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

preflight: ## Verify colima, k3d, kubectl, argo, kubeseal are present
	@command -v colima   >/dev/null || { echo "colima not found";   exit 1; }
	@command -v k3d      >/dev/null || { echo "k3d not found";      exit 1; }
	@command -v kubectl  >/dev/null || { echo "kubectl not found";  exit 1; }
	@command -v argo     >/dev/null || { echo "argo CLI not found"; exit 1; }
	@command -v kubeseal >/dev/null || { echo "kubeseal not found (brew install kubeseal)"; exit 1; }
	@colima status >/dev/null 2>&1 || { echo "Colima not running: colima start --runtime docker --cpu 4 --memory 9 --disk 30 --vm-type vz"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Docker API unreachable (Colima needs --runtime docker)."; exit 1; }
	@echo "preflight ok"

cluster: preflight ## Create the k3d cluster with audit logging enabled
	@mkdir -p $(REPO)/.audit && touch $(REPO)/.audit/audit.log
	@sed 's|__REPO__|$(REPO)|g' cluster/k3d.yaml > /tmp/k3d-runbook.yaml
	k3d cluster create --config /tmp/k3d-runbook.yaml
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s

## ------------------------------------------------------------- GitOps bootstrap
bootstrap: cluster ## Cluster + install ArgoCD + sealed-secrets (the only imperative step)
	$(KUBECTL) create namespace argocd --dry-run=client -o yaml | $(KUBECTL) apply -f -
	# server-side apply: the ArgoCD CRDs are too big for the client-side
	# last-applied-config annotation (256KB limit).
	$(KUBECTL) apply --server-side --force-conflicts -n argocd -f $(ARGOCD_URL)
	$(KUBECTL) apply --server-side --force-conflicts -f $(SEALED_URL)
	$(KUBECTL) -n argocd rollout status deploy/argocd-repo-server --timeout=300s
	$(KUBECTL) -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s
	@echo
	@echo "ArgoCD + sealed-secrets ready. Next:"
	@echo "  make seal-secret CLIENT_ID=<app-id> CLIENT_SECRET=<secret>   # encrypt Entra creds"
	@echo "  # set the tenant ID in manifests/argo-workflows/workflow-controller-configmap.yaml"
	@echo "  make set-repo REPO_URL=<https://github.com/you/argo-runbook-lab.git>"
	@echo "  git add -A && git commit && git push          # ArgoCD syncs from git"
	@echo "  make gitops-up                                 # apply the app-of-apps root"

seal-secret: ## Encrypt Entra creds into the committed SealedSecret. make seal-secret CLIENT_ID=.. CLIENT_SECRET=..
	@test -n "$(CLIENT_ID)" -a -n "$(CLIENT_SECRET)" || { echo "usage: make seal-secret CLIENT_ID=.. CLIENT_SECRET=.."; exit 1; }
	$(KUBECTL) create secret generic argo-server-sso -n argo \
	  --from-literal=client-id=$(CLIENT_ID) --from-literal=client-secret=$(CLIENT_SECRET) \
	  --dry-run=client -o yaml | \
	  kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller --format yaml \
	  > manifests/argo-workflows/argo-server-sso.sealedsecret.yaml
	@echo "sealed -> commit & push manifests/argo-workflows/argo-server-sso.sealedsecret.yaml"

set-repo: ## Point ArgoCD apps at your git repo. make set-repo REPO_URL=https://github.com/you/repo.git
	@test -n "$(REPO_URL)" || { echo "usage: make set-repo REPO_URL=https://github.com/you/repo.git"; exit 1; }
	@grep -rl REPLACE_WITH_YOUR_GIT_REPO_URL apps bootstrap | xargs sed -i '' 's|REPLACE_WITH_YOUR_GIT_REPO_URL|$(REPO_URL)|g'
	@echo "repoURL set to $(REPO_URL)"

gitops-up: ## Apply the app-of-apps root (after set-repo + git push)
	$(KUBECTL) apply -f bootstrap/root-app.yaml
	@echo "ArgoCD is now syncing. Watch:  make argocd-ui   (or: kubectl -n argocd get applications)"

## ------------------------------------------------------------------ access
port-forward: ## Argo Workflows UI on localhost:2746
	@echo "Argo UI: http://localhost:2746   (SSO: sign in with your Entra account)"
	$(KUBECTL) -n argo port-forward svc/argo-server 2746:2746

argocd-ui: ## ArgoCD UI on localhost:8081 (admin / initial secret below)
	@echo "ArgoCD UI: https://localhost:8081"
	@echo "admin password: $$($(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8081:443

## ---------------------------------------------------------------- tests
test-rbac: ## Assert the permission matrix (fast, no workflows)
	./scripts/test-rbac.sh

test-l1: ## L1 read-only runbook, no approval needed
	./scripts/test-l1-flow.sh

test-l2: ## Full L1-request -> suspend -> L2-approve -> restart -> verify
	./scripts/test-l2-approval-flow.sh

test-escalation: ## The four bypass attacks. Must all be denied.
	./scripts/test-privilege-escalation.sh

test-e2e: test-rbac test-l1 test-l2 test-escalation ## Everything
	@echo "all suites passed"

## ------------------------------------------------------- manual demo steps
request-restart: ## L1 submits a restart request (will suspend)
	@ARGO_TOKEN="Bearer $$($(KUBECTL) -n argo create token l1-user)" \
	  argo submit --from workflowtemplate/restart-deployment -n argo -p requestedBy=l1-user --watch

approve-as-l1: ## Attempt approval as L1. Expected: RBAC denial.
	@WF=$$($(KUBECTL) get wf -n argo -o name | tail -1 | cut -d/ -f2); \
	 ARGO_TOKEN="Bearer $$($(KUBECTL) -n argo create token l1-user)" \
	   argo resume $$WF -n argo || echo ">>> denied, as expected"

approve-as-l2: ## Approve as L2. Expected: workflow resumes.
	@WF=$$($(KUBECTL) get wf -n argo -o name | tail -1 | cut -d/ -f2); \
	 ARGO_TOKEN="Bearer $$($(KUBECTL) -n argo create token l2-approver)" \
	   argo resume $$WF -n argo

show-audit: ## Chain of custody from the Kubernetes audit log
	./scripts/show-audit.sh

cleanup: ## Delete the cluster and audit logs
	-k3d cluster delete $(CLUSTER)
	-rm -rf $(REPO)/.audit
