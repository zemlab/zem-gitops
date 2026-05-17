# Migrating Projects to the New projects/ Layout

## Overview

The new layout replaces the old per-cluster Application approach:

| Old | New |
|-----|-----|
| `clusters/<cluster>/projects/<project>.yaml` | deleted |
| `deployments/project/projects/<project>.yaml` | deleted |
| `clusters/<cluster>/infra.yaml` project-credentials entry | deleted |
| — | `projects/<project>/envs/<cluster>/<env>.yaml` |
| — | `projects/<project>/<app>/app.yaml` |
| — | `projects/<project>/<app>/envs/<env>.yaml` |

The `appset-instances` ApplicationSet (running on each cluster) watches `projects/*/envs/<cluster>/*.yaml` and automatically creates a `project-instance-<project>-<env>` Application, which in turn renders:
- Namespace
- AppProject
- `<project>-common-<env>` Application (OCI SecretStore + backup schedule)
- `project-apps-<project>-<env>` ApplicationSet → one Application per app with an env file

IAM credentials (OCI API key) are no longer maintained as a manual list in `infra.yaml`. Instead, `project-instance` creates an ExternalSecret in the `project-credentials` namespace; kubernetes-replicator copies the resulting Secret into the project namespace.

---

## Pre-flight: Strip Finalizers

**Do this before merging the PR.** The old top-level Application and all its child Applications carry `resources-finalizer.argocd.argoproj.io`. Deleting them with the finalizer in place cascades to delete the Namespace, AppProject, and every managed k8s resource inside it (Deployments, Pods, PVCs, etc.).

```bash
CTX=<cluster>.shark-puffin.ts.net
NS=<project>-<env>   # e.g. gitlab-prod

# Find child Applications (look for project-name in the name)
kubectl get application -n gitops --context=$CTX | grep <project>

# Strip finalizer from the top-level Application
kubectl patch application <project>-<env> -n gitops \
  --type=merge -p='{"metadata":{"finalizers":[]}}' \
  --context=$CTX

# Strip finalizer from each child Application (e.g. gitlab-runner-prod, project-common-gitlab-prod)
for app in <child-app-1> <child-app-2>; do
  kubectl patch application $app -n gitops \
    --type=merge -p='{"metadata":{"finalizers":[]}}' \
    --context=$CTX
done

# Verify all are clear
kubectl get application -n gitops --context=$CTX \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.finalizers}{"\n"}{end}' \
  | grep <project>
```

---

## Git Changes

### 1. Create `projects/<project>/envs/<cluster>/<env>.yaml`

Copy the ociVault values from the old `clusters/<cluster>/projects/<project>.yaml` valuesObject. Add `iamVaultSecretName` and `credentialSecretName`:

```yaml
env: prod
ociVault:
  vaultOcid: "<from old file>"
  compartmentOcid: "<from old file>"
  region: "uk-london-1"
  tenancyOcid: "<from old file>"
  userOcid: "<from old file>"
  iamVaultSecretName: "infra-<namespace>-oci-credentials"   # OCI Vault secret with IAM key
  credentialSecretName: "<namespace>-oci-creds"              # k8s Secret name (convention)
b2:
  prefix: "<cluster>/<namespace>"
  vaultSecretName: "<namespace>-backups"
```

The `iamVaultSecretName` is in OCI Vault. For old projects it follows `infra-<namespace>-oci-credentials`. New projects created by `scripts/create-project.sh` use `infra-<namespace>-oci-credentials` (same pattern — the script stores it under that name). Check the old `infra.yaml` project-credentials entry to confirm:

```yaml
# Old entry to look up:
- name: <namespace>
  vaultSecretName: infra-<namespace>-oci-credentials   # ← this is iamVaultSecretName
```

### 2. Create `projects/<project>/<app>/app.yaml` per app

One file per app (service). Source the values from `deployments/project/projects/<project>.yaml` services section:

**Git-based app** (chart in this repo):
```yaml
source:
  repoURL: https://github.com/danfoster/zem-gitops
  targetRevision: main
  path: apps/<project-dir>/<app-dir>
releaseName: <existing-helm-release-name>
```

**OCI/Helm registry app** (external chart registry):
```yaml
source:
  repoURL: registry.example.com/org/charts
  chart: <chart-name>
releaseName: <existing-helm-release-name>
```

**`releaseName` must exactly match the existing Helm release name** in the cluster. ArgoCD renders charts without a server-side Helm release (no `helm list` entry), so the release name affects `.Release.Name` in templates. Changing it changes rendered ConfigMap/Secret names, causing unnecessary pod restarts.

To check the existing release name, look at the old Application:
```bash
kubectl get application <old-app-name> -n gitops --context=$CTX -o jsonpath='{.spec.source.helm.releaseName}'
```

If the app uses Tailscale egress Services, add:
```yaml
ignoreDifferences:
  - group: ""
    kind: Service
    jsonPointers:
      - /spec/externalName
```
(Currently documented intent only — the ApplicationSet applies this globally. Future work to make it per-app.)

### 3. Create `projects/<project>/<app>/envs/<env>.yaml`

One file per app-env. Presence enables the app for that env. For OCI chart apps, include `source.targetRevision` here (not in `app.yaml`) so it can differ between envs. Content also includes Helm value overrides. Can be empty for git apps with no overrides:

```yaml
{}
```

Add any env-specific values (hostnames, feature flags, etc.) that were previously in `services.<app>.values` in the old project values file.

### 4. Delete old files

```
clusters/<cluster>/projects/<project>.yaml
deployments/project/projects/<project>.yaml
```

### 5. Remove project-credentials entry from `clusters/<cluster>/infra.yaml`

```yaml
# Remove the block:
- name: <namespace>
  vaultSecretName: infra-<namespace>-oci-credentials
  targetNamespace: <namespace>
```

The new `project-instance` ExternalSecret in `project-credentials` namespace replaces this.

---

## Merge

Open a PR and merge to `main`. ArgoCD reconciles:

1. Old top-level Application pruned (no finalizer → no cascade, k8s resources survive)
2. `appset-instances` detects new env file → creates `project-instance-<project>-<env>`
3. `project-instance` syncs (waves):
   - wave -2: Namespace, ExternalSecret `<namespace>-oci-credentials` in `project-credentials` ns
   - wave -1: AppProject
   - wave 0: `<project>-common-<env>` Application, `project-apps-*` ApplicationSet
4. `project-apps-*` ApplicationSet creates one Application per app with an env file
5. Each app Application syncs → Helm renders against existing resources → in-place reconcile

---

## Post-merge Steps

### 1. Delete orphaned child Applications

The old child Applications (e.g. `<project>-runner-prod`, `project-common-<project>-prod`) are **not** automatically deleted when their parent Application is removed — ArgoCD only prunes them if it was managing them in an ApplicationSet with `prune: true`. They become orphaned.

Delete them manually (finalizer already stripped, so no cascade):

```bash
kubectl delete application <old-child-1> <old-child-2> -n gitops --context=$CTX
```

### 2. Clear stale tracking-id annotations

Resources previously managed by the old child Applications (SecretStore, ExternalSecrets, Schedule, Deployments, etc.) carry the old Application's `argocd.argoproj.io/tracking-id`. The new Applications will show SharedResource warnings until cleared.

```bash
# Resources in the project namespace from old project-common:
for resource in secretstore/oci-vault externalsecret/backup-credentials schedule/zem-backups; do
  kubectl annotate $resource -n $NS argocd.argoproj.io/tracking-id- --context=$CTX 2>/dev/null || true
done

# Hard-refresh new Applications so ArgoCD re-evaluates:
for app in <project>-common-<env> <project>-<app>-<env>; do
  kubectl annotate application $app -n gitops \
    argocd.argoproj.io/refresh=hard --overwrite --context=$CTX
done
```

### 3. Force sync if Applications are stuck

If an Application is OutOfSync/Degraded due to a stale cached render (e.g., old git commit), force a sync:

```bash
kubectl patch application <app> -n gitops --context=$CTX \
  --type=merge -p='{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD","prune":true}}}'
```

---

## Verification

```bash
CTX=<cluster>.shark-puffin.ts.net
NS=<namespace>

# New Applications healthy
kubectl get application -n gitops --context=$CTX | grep <project>

# Namespace and AppProject still exist
kubectl get ns $NS --context=$CTX
kubectl get appproject $NS -n argocd --context=$CTX

# IAM credentials secret present (created by new ExternalSecret → replicator)
kubectl get secret ${NS}-oci-creds -n $NS --context=$CTX

# ExternalSecrets synced
kubectl get externalsecret -n $NS --context=$CTX

# Workload pods still running (no unexpected restarts)
kubectl get pods -n $NS --context=$CTX

# Old Applications gone
kubectl get application -n gitops --context=$CTX | grep <project>
# Should show only: project-instance-*, <project>-common-*, <project>-<app>-*
```

---

## Common Issues

### `privateKey.name cannot be empty` (SecretStore webhook rejection)

**Cause**: `ociVault.credentialSecretName` missing from env file. The `project-common` chart needs this to configure the SecretStore.

**Fix**: Add `credentialSecretName: "<namespace>-oci-creds"` under `ociVault` in the env file and push.

### ExternalSecrets stuck in `SecretSyncedError`

**Cause**: SecretStore `oci-vault` not yet ready (just created, or `gitlab-prod-oci-creds` Secret not yet replicated).

**Fix**: Force ESO resync once SecretStore is valid:
```bash
for es in backup-credentials <app>-token; do
  kubectl annotate externalsecret $es -n $NS force-sync=$(date +%s) --overwrite --context=$CTX
done
```

### Application stuck with old error after fix pushed

**Cause**: ArgoCD cached the old git commit. Retrying with stale render.

**Fix**: Force sync with HEAD revision (see Post-merge Steps §3).

### Old child Applications still visible after merge

**Cause**: By design — deleting the parent Application without a cascade finalizer leaves children orphaned. Nobody owns them or prunes them.

**Fix**: Delete them manually (Step 1 of Post-merge Steps).
