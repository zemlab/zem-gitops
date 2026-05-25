# zem-gitops Project

## Repository Structure

This is a GitOps repository managed by ArgoCD for deploying infrastructure across multiple Kubernetes clusters.

### Key Directories

- `apps/infra/zem-<name>/` - Helm chart wrappers for infrastructure tools (each has Chart.yaml, values.yaml, templates/)
- `deployments/infra/` - App-of-apps pattern: values.yaml defines all features, templates/application.yaml generates ArgoCD Applications
- `clusters/<cluster-name>/` - Per-cluster configuration (infra.yaml, projects/, gitops.project.yaml)
- `projects/` - Application workloads (e.g., zem-collab, zem-external)

### Clusters

- **cluster01** - On-prem, uses OpenEBS, MetalLB, Longhorn
- **cluster03** - OCI (Oracle Cloud), uses OCI Block Storage, OCI NLB
- **cluster04** - OCI (Oracle Cloud), hosts gitlab and zem-internal projects

kubectl contexts follow the pattern `<cluster>.shark-puffin.ts.net` (e.g. `cluster03.shark-puffin.ts.net`).

### How Infra Features Work

1. **Define feature** in `deployments/infra/values.yaml` under `features:` with `enabled: false` (default disabled)
2. **Each feature** has: `enabled`, `namespace`, `source` (repoURL + path or chart), optional `values`
3. **Template** at `deployments/infra/templates/application.yaml` iterates features and creates ArgoCD Applications
4. **Per-cluster overrides** in `clusters/<name>/infra.yaml` enable features and provide cluster-specific values
5. **Common values** (like cluster name) are set in `common.values` and merged with feature values

### Adding a New Infra Tool

1. Create `apps/infra/zem-<name>/Chart.yaml` (wrapper chart with dependency)
2. Create `apps/infra/zem-<name>/values.yaml` (pass-through config)
3. Add feature entry to `deployments/infra/values.yaml` (disabled by default)
4. Enable in target cluster's `clusters/<cluster>/infra.yaml`

### Source Patterns

- **Wrapper chart** (most common): `source.path: apps/infra/zem-<name>` with Chart.yaml listing upstream dependency
- **Direct chart** (simpler tools): `source.repoURL: <helm-repo>`, `source.chart: <name>`, `source.targetRevision: <version>`

### Secrets Management

Two ClusterSecretStores exist on each cluster:

- **`zem-infra`** (Bitwarden) — cluster-scoped infra secrets. Configured via bootstrap helmfile (`zem-external-secrets` release). Used for secrets that are global to the cluster.
- **`oci-vault`** (OCI Vault) — project/namespace-scoped credentials. Set up once per cluster via `scripts/setup-oci-vault-clustersecretstore.sh <cluster>`. Used by `project-credentials` and per-namespace SecretStores. Requires `ociVault.enabled: true` in `bootstrap/values/<cluster>.yaml`.

ExternalSecrets in `project-credentials` namespace use `ClusterSecretStore/oci-vault` and replicate the resulting Secret to target namespaces via `kubernetes-replicator` (annotation: `replicator.v1.mittwald.de/replicate-to`). The per-namespace `oci-vault` SecretStore then uses those replicated credentials.

### Onboarding a New Project

**Always use `scripts/create-project.sh <cluster> <namespace>` to create new projects.** Do not manually create project files. The script handles all required steps: OCI users, IAM policies, B2 keys, restic passwords, OCI Vault secrets, and generates the git files (`clusters/<cluster>/infra.yaml`, `clusters/<cluster>/projects/<project>.yaml`, `deployments/project/projects/<project>.yaml`). This script must also be used when migrating an existing project to a new cluster.

See also: `scripts/setup-oci-vault-clustersecretstore.sh <cluster>` — one-time per-cluster setup for the `oci-vault` ClusterSecretStore.

### Backup Infrastructure

- **K8up** (current): Restic-based, backs up to Backblaze B2 (`zem-backups-eu` bucket)

### ArgoCD Application Namespace

All ArgoCD Application CRs live in the **`gitops`** namespace, not `argocd`. The `argocd` namespace is reserved for ArgoCD system components only.

ArgoCD is configured with `application.namespaces: "gitops"` (in `apps/infra/zem-argocd/values.yaml`) to watch the `gitops` namespace. All Application manifests — including bootstrap Applications in `bootstrap/<cluster>.yaml`, cluster-level `clusters/*/infra.yaml` and `clusters/*/projects.yaml`, and project Applications in `clusters/*/projects/*.yaml` — must have `namespace: gitops`.

All Application CRs carry `resources-finalizer.argocd.argoproj.io` in `metadata.finalizers`. Deleting an Application cascades to delete all managed resources. This is intentional.

### AppProject Structure

Each cluster has `clusters/<cluster>/gitops.project.yaml` defining the `gitops` AppProject. This project:
- Must list **both** `gitops` and `argocd` as destinations — `argocd` is required because AppProject resources (created by the infra app-of-apps) live in the `argocd` namespace
- Must have `sourceNamespaces: [gitops]` — required for ArgoCD to accept Applications in the `gitops` namespace using this project
- Bootstrap Applications use `project: gitops`

The infra app-of-apps creates an `infra` AppProject (managed resource, lives in `argocd` ns). Project app-of-apps creates per-project AppProjects. Both need `sourceNamespaces: [gitops]` — defined in their templates.

### ArgoCD ConfigMap (`argocd-cm`)

`argocd-cm` is **not managed by Helm** (`configs.cm.create: false` in `apps/infra/zem-argocd/values.yaml`). It contains cluster-specific config: dex OIDC connector, server URL, resource exclusions. Patch it directly with `kubectl patch configmap argocd-cm -n argocd`.

Custom health checks for CRDs that ArgoCD doesn't know natively are added as:
```
resource.customizations.health.<apiGroup>_<Kind>: |
  <lua script returning hs.status and hs.message>
```

Without a health check, applications containing only CRD resources will show as **Progressing** indefinitely (ArgoCD can't confirm Healthy).

### SharedResourceWarnings

When an Application is deleted but its managed resources still carry the old `argocd.argoproj.io/tracking-id` annotation, ArgoCD reports "Resource X is part of applications A and B". Fix: remove the annotation from affected resources, then hard-refresh the owning Application:

```bash
kubectl annotate <resource> argocd.argoproj.io/tracking-id- [--context ...]
kubectl annotate application <app> -n gitops argocd.argoproj.io/refresh=hard --overwrite
```

### Application Source Directories

- `apps/infra/zem-<name>/` — infra tool wrappers (Helm charts)
- `apps/zem-<project>/` — project-level app wrappers (e.g. `apps/zem-gitlab/`)
- `deployments/infra/` — infra app-of-apps
- `deployments/project/` — project app-of-apps

### Bootstrap (Pre-ArgoCD)

The `bootstrap/` directory contains a Helmfile that installs the 6 Helm releases needed before ArgoCD can manage the cluster. These are intentionally **not** managed by ArgoCD.

- `bootstrap/helmfile.yaml.gotmpl` - Declarative definition of all bootstrap releases (`.gotmpl` extension required by Helmfile v1 for Go templating)
- `bootstrap/values/` - Per-cluster values (cluster01.yaml, cluster02.yaml, cluster03.yaml)
- `bootstrap/bootstrap.sh` - Wrapper script: `./bootstrap/bootstrap.sh <cluster> <bw-token>`

**Helmfile commands** (run from `bootstrap/`):
- `helmfile -e <cluster> diff` - Show drift between declared and live state
- `helmfile -e <cluster> apply` - Reconcile (install/upgrade) all releases
- `helmfile -e <cluster> lint` - Validate chart templates
- `helmfile -e <cluster> template` - Render templates locally

**Requirements**: `helmfile`, `helm`, `kubectl`, `helm-diff` plugin

For a brand-new cluster use `bootstrap/new-cluster.sh <cluster> <bw-token>` — this runs all phases including OCI Vault setup. Use `bootstrap/bootstrap.sh` only to re-run an existing cluster.

### ExternalSecret remoteRef defaults

Always explicitly include these fields on every `remoteRef` entry to avoid a perpetual ArgoCD diff (ESO sets them as defaults on the live resource):

```yaml
remoteRef:
  key: "some-key"
  conversionStrategy: Default
  decodingStrategy: None
  metadataPolicy: None
```

### Testing Helm Charts Before Committing

Always run `helm lint` and `helm template` before committing any changes to Helm charts or values files. Broken charts cause ArgoCD app-of-apps to fail to render, taking down all child applications.

**For `deployments/project/` (project app-of-apps):**
```bash
helm template test deployments/project -f deployments/project/projects/<project>.yaml --set env=prod
```

Use `deployments/project/linter_values.yaml` for a generic test:
```bash
helm lint deployments/project -f deployments/project/linter_values.yaml
```

**For `apps/infra/zem-<name>/` or `apps/zem-<name>/` (wrapper charts):**
```bash
helm dependency update apps/infra/zem-<name>/
helm lint apps/infra/zem-<name>/
helm template test apps/infra/zem-<name>/
```

**For `deployments/infra/` (infra app-of-apps):**
```bash
helm template test deployments/infra -f clusters/<cluster>/infra.yaml
```

**Project values file requirements** — when adding a new project or service to `deployments/project/projects/<project>.yaml`:
- Always include a `common.values.ociVault` block (with empty strings) so `$.Values.common` is never nil in the template
- Always define `project-common` service with its source, even if `enabled: false`

### infra.yaml Is Not a Pure Values File

`clusters/<cluster>/infra.yaml` is an ArgoCD Application manifest, not a Helm values file. The `helm template test deployments/infra -f clusters/<cluster>/infra.yaml` command does NOT accurately reflect what ArgoCD renders — it parses the whole Application YAML as values (nesting under `apiVersion`, `spec`, etc.). Only use it to catch syntax errors; don't rely on the output to match live ArgoCD rendering.

### Git Remote

- Repo URL used in sources: `https://gitlab.com/zemlab/zem-gitops.git`
- Default branch: `main`
- ArgoCD namespace (system components): `argocd`
- ArgoCD Application namespace: `gitops`
