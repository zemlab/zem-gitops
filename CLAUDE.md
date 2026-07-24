# zem-gitops Project

## Repository Structure

This is a GitOps repository managed by ArgoCD for deploying infrastructure across multiple Kubernetes clusters.

**This repo holds infra chart code + cluster wiring only.** Both generator engines — project-generator/
project-instance (app deployment) and infra-generator (infra features) — plus their config trees
(`projects/`, `infra/`) live in the separate `gitops` repo (`https://github.com/zemlab/gitops`, checked
out at `~/git/zem/gitops`). This repo's link into it is per-cluster:
`clusters/<cluster>/infra-generator.yaml` wires the `infra-generator` chart, and `project-generator` is
a static Application at the root tier.

### Key Directories

- `apps/infra/zem-<name>/` - Helm chart wrappers for infrastructure tools (each has Chart.yaml, values.yaml, templates/) — feature CODE only; per-cluster enablement lives in the `gitops` repo's `infra/<name>/` tree
- `apps/zem-<project>/`, `apps/<project>/` - Project workload chart wrappers, referenced by `projects/*/app.yaml` in the `gitops` repo (stayed here deliberately so infra and app charts share one Helm/lint pipeline)
- `clusters/<cluster-name>/` - Per-cluster configuration (`infra-generator.yaml`, `infra.appproject.yaml`, `gitops.project.yaml`)

### Clusters

- **cluster01** - On-prem, uses OpenEBS, MetalLB, Longhorn
- **cluster03** - OCI (Oracle Cloud), uses OCI Block Storage, OCI NLB
- **cluster04** - OCI (Oracle Cloud), hosts gitlab and zem-internal projects

kubectl contexts follow the pattern `<cluster>.shark-puffin.ts.net` (e.g. `cluster03.shark-puffin.ts.net`).

### How Infra Features Work

Infra is driven by an `infra-features` ApplicationSet (chart `charts/infra-generator` in the `gitops`
repo), a merge generator reading a config tree at `infra/<feature>/` (also in the `gitops` repo) — the
infra analog of `projects/`. Per cluster:

1. **Enabled = an `infra/<feature>/envs/<cluster>.yaml` file exists.** Its presence is the generator
   param source; its contents are per-cluster Helm values for that feature.
2. **`infra/<feature>/app.yaml`** supplies `releaseName`, `namespace`, `source` (git path into
   `apps/infra/zem-<name>` in zem-gitops, or an external Helm repo chart+version), optional
   `ignoreDifferences`/`syncWave`.
3. **`infra/<feature>/values.yaml`** (optional) holds base values shared across all clusters.
4. One `clusters/<cluster>/infra-generator.yaml` Application (this repo) wires the `infra-generator`
   chart per cluster — this is the ONLY per-cluster wiring file; there is no parent app-of-apps to
   re-sync. Editing an `envs/<cluster>.yaml` in the `gitops` repo takes effect in a single
   ApplicationSet reconcile.

### Adding a New Infra Tool

1. Create `apps/infra/zem-<name>/Chart.yaml` (wrapper chart with dependency) in **this repo**
2. Create `apps/infra/zem-<name>/values.yaml` (pass-through config) in **this repo**
3. In the **`gitops`** repo, create `infra/<name>/app.yaml` (+ optional `values.yaml`)
4. Enable on a cluster by adding `infra/<name>/envs/<cluster>.yaml` in the **`gitops`** repo

### Source Patterns

- **Wrapper chart** (most common): `source.path: apps/infra/zem-<name>` with Chart.yaml listing upstream dependency
- **Direct chart** (simpler tools): `source.repoURL: <helm-repo>`, `source.chart: <name>`, `source.targetRevision: <version>`

### Secrets Management

Two ClusterSecretStores exist on each cluster:

- **`zem-infra`** (Bitwarden) — cluster-scoped infra secrets. Configured via bootstrap helmfile (`zem-external-secrets` release). Used for secrets that are global to the cluster.
- **`oci-vault`** (OCI Vault) — project/namespace-scoped credentials. Set up once per cluster via `scripts/setup-oci-vault-clustersecretstore.sh <cluster>`. Used by `project-credentials` and per-namespace SecretStores. Requires `ociVault.enabled: true` in `bootstrap/values/<cluster>.yaml`.

ExternalSecrets in `project-credentials` namespace use `ClusterSecretStore/oci-vault` and replicate the resulting Secret to target namespaces via `kubernetes-replicator` (annotation: `replicator.v1.mittwald.de/replicate-to`). The per-namespace `oci-vault` SecretStore then uses those replicated credentials.

### Onboarding a New Project

**Always use `scripts/create-project.sh <cluster> <namespace>` to create new projects.** Do not manually create project files. The script handles all required steps: OCI users, IAM policies, B2 keys, restic passwords, OCI Vault secrets, and generates the git files. This script must also be used when migrating an existing project to a new cluster.

**Note:** the project config files (`projects/<project>/envs/<cluster>/<env>.yaml`, `projects/<project>/<app>/app.yaml`) this script generates now live in the separate `gitops` repo (`~/git/zem/gitops`), not here — `scripts/create-project.sh` needs updating to target that repo (tracked as a follow-up from the repo split).

See also: `scripts/setup-oci-vault-clustersecretstore.sh <cluster>` — one-time per-cluster setup for the `oci-vault` ClusterSecretStore.

### Backup Infrastructure

- **K8up** (current): Restic-based, backs up to Backblaze B2 (`zem-backups-eu` bucket)

### ArgoCD Application Namespace

All ArgoCD Application CRs live in the **`gitops`** namespace, not `argocd`. The `argocd` namespace is reserved for ArgoCD system components only.

ArgoCD is configured with `application.namespaces: "gitops"` (in `apps/infra/zem-argocd/values.yaml`) to watch the `gitops` namespace. All Application manifests — including bootstrap Applications in `bootstrap/<cluster>.yaml`, cluster-level `clusters/*/infra.yaml`, and the project Applications generated by the `gitops` repo's charts — must have `namespace: gitops`.

All Application CRs carry `resources-finalizer.argocd.argoproj.io` in `metadata.finalizers`. Deleting an Application cascades to delete all managed resources. This is intentional.

### AppProject Structure

Each cluster has `clusters/<cluster>/gitops.project.yaml` defining the `gitops` AppProject. This project:
- Must list **both** `gitops` and `argocd` as destinations — `argocd` is required because AppProject resources live in the `argocd` namespace
- Must have `sourceNamespaces: [gitops]` — required for ArgoCD to accept Applications in the `gitops` namespace using this project
- Bootstrap Applications use `project: gitops`

`clusters/<cluster>/infra.appproject.yaml` (this repo, static, not Helm-rendered) defines the `infra`
AppProject (lives in `argocd` ns) used by every ApplicationSet-generated feature Application.
`destinations: namespace: '*'` deliberately — `clusterResourceWhitelist` is already `*/*`, so
enumerating namespaces would add no real restriction while forcing an edit here every time a feature
widens its reach. `sourceRepos` is the real, enumerated restriction: both `zemlab/zem-gitops` (feature
chart code) and `zemlab/gitops` (feature config), plus every external Helm repo in use. The
`project-instance` chart (in the `gitops` repo) creates per-project AppProjects. All three project
types need `sourceNamespaces: [gitops]` — defined in their own templates/manifests.

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
- `charts/infra-generator/` — infra ApplicationSet driver, reads `infra/` config tree (in the `gitops` repo, not here)
- `charts/project-generator/`, `charts/project-instance/` — project ApplicationSet drivers (in the `gitops` repo, not here)

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

Always run `helm lint` and `helm template` before committing any changes to Helm charts or values files. Broken charts cause ArgoCD app-of-apps/ApplicationSets to fail to render, taking down all child applications.

**For `charts/project-generator/`, `charts/project-instance/`, or `charts/infra-generator/` (ApplicationSet drivers, in the `gitops` repo):**
```bash
helm lint charts/project-generator charts/project-instance charts/infra-generator
helm template test charts/project-generator --set cluster.name=<cluster>
helm template test charts/project-instance --set name=<project> --set env=<env> --set cluster=<cluster>
helm template test charts/infra-generator --set cluster.name=<cluster>
```

**For `apps/infra/zem-<name>/` or `apps/zem-<name>/` (wrapper charts, in this repo):**
```bash
helm dependency update apps/infra/zem-<name>/
helm lint apps/infra/zem-<name>/
helm template test apps/infra/zem-<name>/
```

### Git Remote

- Repo URL used in sources (this repo, infra chart code + cluster wiring): `https://github.com/zemlab/zem-gitops`
- Generator repo (project-generator/project-instance/infra-generator charts + `projects/` + `infra/`): `https://github.com/zemlab/gitops`, checked out at `~/git/zem/gitops`
- Default branch: `main`
- ArgoCD namespace (system components): `argocd`
- ArgoCD Application namespace: `gitops`
