---
name: argo-workflow-lifecycle
description: Configure and verify the lifecycle of Argo Workflows on a Helm-installed cluster - pod garbage collection, workflow TTL, a deadline for workflows stuck waiting for approval, and the workflow archive with a retention period (archiveTTL). Use when asked to set up, change, test, or roll out workflow/pod retention or cleanup for Argo Workflows ("how long do pods/workflows stick around", "implement lifecycle", "OPS-4137"), especially on the Bitnami argo-workflows chart.
---

# Argo Workflows lifecycle

Sets how long Argo keeps pods, Workflow objects, and workflow history, then proves it works
with short timers before rolling out the real values.

## Target standard

Confirm these numbers with the user before changing anything. They are the defaults agreed
for OPS-4137; retention may be set by audit/compliance.

| Setting | Value | Effect |
|---|---|---|
| `podGC.strategy` | `OnPodSuccess` | Successful pods deleted at once; failed pods kept for debugging |
| `ttlStrategy.secondsAfterSuccess` | `86400` (1 day) | Successful Workflow object deleted after 1 day |
| `ttlStrategy.secondsAfterFailure` | `604800` (7 days) | Failed Workflow (and its kept pods) deleted after 7 days |
| `activeDeadlineSeconds` | `86400` (24 h) | A workflow still waiting for approval fails instead of hanging forever |
| `persistence.archive` | `true` | Finished workflows copied to Postgres - visible under **Archived Workflows** |
| `persistence.archiveTTL` | `30d` | Archived history kept 30 days |

## Step 1 - Inspect the environment

Do not assume anything about the target cluster. Run:

```bash
kubectl config current-context
helm list -A | grep -i argo                      # release name, namespace, chart + version
kubectl get crd workflows.argoproj.io            # Argo installed?
```

Record: release name, namespace, chart (`bitnami/argo-workflows` or `argo/argo-workflows`),
chart version, Argo version, the values file(s) used to install it, and whether a database is
configured (the archive needs Postgres or MySQL - the Bitnami chart deploys Postgres by default).

Also list what is already there, so the user knows existing workflows are NOT covered by the
new defaults:

```bash
kubectl get wf -A --no-headers | awk '{print $1, $3}' | sort | uniq -c
```

If the user's values file contains secrets (for example an SSO client secret in plain text),
point it out and keep it out of anything you write or commit.

## Step 2 - Edit the values file

Add under `controller:` (merge with existing keys; do not duplicate `controller:`):

```yaml
controller:
  # Workflow lifecycle. Applied to every workflow unless its WorkflowTemplate sets its own value.
  workflowDefaults:
    spec:
      podGC:
        strategy: OnPodSuccess
      ttlStrategy:
        secondsAfterSuccess: 86400    # 1 day
        secondsAfterFailure: 604800   # 7 days
      activeDeadlineSeconds: 86400    # approval not given within 24h -> workflow fails
  persistence:
    archive:
      enabled: true
```

### archiveTTL

- **Bitnami chart:** there is no value for `archiveTTL`. Override `controller.config` with the
  chart's own default template plus one line, using the bundled script (stdlib only):

  ```bash
  helm show values bitnami/argo-workflows --version <CHART_VERSION> > chart-values.yaml
  python <skill-dir>/scripts/build_controller_config.py chart-values.yaml 30d > controller-config.yaml
  ```

  Paste the output under `controller:` and put this comment above it:
  `# Copy of the Bitnami <version> default controller config. Overridden only to add
  # persistence.archiveTTL. Re-sync this block when upgrading the chart.`
  Always generate it from the **same chart version** that is deployed.

- **Official `argo/argo-workflows` chart:** it passes `controller.persistence` through as-is,
  so set `controller.persistence.archiveTTL: 30d` directly - no config override. Check with
  `helm show values argo/argo-workflows | grep -n -A20 "persistence:"`.

Verify the render before deploying:

```bash
helm template <release> <chart> --version <CHART_VERSION> -n <ns> -f values.yaml \
  | grep -E "archiveTTL|archive:|activeDeadline|strategy: OnPod|secondsAfter"
```

All six settings must appear in the controller ConfigMap, and any existing `sso:` block must
still be there.

## Step 3 - Test with short timers

Put short timers in a **separate** values file outside the repo (never in the real one):

```yaml
# lifecycle-test-values.yaml
controller:
  workflowDefaults:
    spec:
      podGC: { strategy: OnPodSuccess }
      ttlStrategy: { secondsAfterSuccess: 120, secondsAfterFailure: 300 }
      activeDeadlineSeconds: 300
```

Note the current Helm revision for rollback (`helm history <release> -n <ns>`), then:

```bash
helm upgrade <release> <chart> --version <CHART_VERSION> -n <ns> -f values.yaml -f lifecycle-test-values.yaml --wait
kubectl -n <ns> rollout restart deploy/<release>-controller deploy/<release>-server
kubectl -n <ns> rollout status deploy/<release>-controller
```

Submit three workflows, labelled so they are easy to find:

1. **Success** - any read-only WorkflowTemplate: `argo -n <ns> submit --from workflowtemplate/<name> -l lifecycle-test=success`
2. **Failure** - a workflow whose container runs `exit 1` (label `lifecycle-test=failure`)
3. **Unapproved** - a template with a `suspend` approval step; do not resume it (label `lifecycle-test=unapproved`)

Expected (verified on Argo v3.7.1, Bitnami chart 13.0.6):

| Check | How | Expected |
|---|---|---|
| Pod GC on success | `kubectl -n <ns> get pods -l workflows.argoproj.io/workflow=<wf>` | Pod gone seconds after success |
| Failed pod kept | same, for the failure workflow | Pod still there (`Error`) |
| Success TTL | `kubectl -n <ns> wait wf/<wf> --for=delete --timeout=240s` | Deleted ~2 min after `finishedAt` |
| Failure TTL | same | Deleted ~5 min after finish; its pod deleted with it |
| Approval deadline | `argo -n <ns> get <wf>` | Fails at 5:00, approval node says `Step exceeded its deadline` |
| Archive | `GET /api/v1/archived-workflows?namespace=<ns>&listOptions.labelSelector=lifecycle-test` with a bearer token, or UI → Archived Workflows | All three listed after the cluster deleted them |

Use `kubectl wait` to wait for these instead of `sleep`. If the server requires auth, create
a token for a ServiceAccount that can list workflows (`kubectl -n <ns> create token <sa>`).

## Step 4 - Roll out the real values

```bash
helm upgrade <release> <chart> --version <CHART_VERSION> -n <ns> -f values.yaml --wait
kubectl -n <ns> rollout restart deploy/<release>-controller deploy/<release>-server
kubectl -n <ns> get cm <release>-controller -o jsonpath='{.data.config}' \
  | grep -E "archiveTTL|archive:|activeDeadline|strategy|secondsAfter"
```

Check the **new** controller pod's log (`kubectl logs deploy/...` can pick the old, terminating
pod right after a restart - select the Running pod explicitly):
`archiveTTL: 720h0m0s` and `Persistence Session created successfully`, and no `level=error`/`fatal`.

Rollback if needed: `helm rollback <release> <previous-revision> -n <ns>`.

Do not commit unless the user asks.

## Things to tell the user

- **Existing workflows are not covered.** Workflows created before the change keep their old
  spec - including ones still suspended at approval. Clean them up once, after listing them
  for the user to confirm:
  `argo -n <ns> list --older 7d`, then `argo -n <ns> delete --completed --older 7d`;
  delete never-finished ones by name.
- **Logs of successful runs are lost immediately.** Argo reads logs from the pod, and
  `OnPodSuccess` deletes it at once - `argo logs <wf>` returns nothing, and archived workflows
  have no logs. To keep logs, add `artifactRepository` with `archiveLogs: true` (Azure Blob,
  S3, or MinIO) with a matching 30-day bucket lifecycle rule. Alternatives: remove `podGC`
  (logs live as long as the workflow) or `deleteDelayDuration: 24h`.
- **The archive grows with every run.** A CronWorkflow running every minute adds ~43,000
  archive rows a month. Suspend or slow down test crons before enabling the archive.
  `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` only limit live objects.
- **Templates can override defaults.** `workflowDefaults` only fill in what a template does not
  set, so a runbook that needs longer retention sets its own `ttlStrategy`.
- **`retentionPolicy` conflicts with time-based retention.** A cap like `completed: 50` deletes
  workflows before their TTL. Only add it if the user wants a count limit.
- **Chart upgrades:** on the Bitnami chart, regenerate the `controller.config` block from the
  new chart version, or new chart features are silently lost.
