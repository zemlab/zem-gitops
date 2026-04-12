# zem-gitops Project

## Repository Structure

This is a GitOps repository managed by ArgoCD for deploying infrastructure across multiple Kubernetes clusters.

### Key Directories

- `apps/infra/zem-<name>/` - Helm chart wrappers for infrastructure tools (each has Chart.yaml, values.yaml, templates/)
- `deployments/infra/` - App-of-apps pattern: values.yaml defines all features, templates/application.yaml generates ArgoCD Applications
- `clusters/<cluster-name>/` - Per-cluster configuration (infra.yaml, projects/, gitops.project.yaml)
- `projects/` - Application workloads (e.g., zem-collab, zem-external)

### Clusters

- **cluster01** - On-prem, uses OpenEBS/ZFS, MetalLB, Longhorn
- **cluster02** - Hosts zem-external and zem-internal projects
- **cluster03** - OCI (Oracle Cloud), uses OCI Block Storage, OCI NLB, Longhorn (disabled currently)

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

- External Secrets Operator pulls from Bitwarden vault
- Secret store configured in `apps/infra/zem-external-secrets/`
- ExternalSecret CRDs reference `remoteRefKey` for vault items

### Onboarding a New Project

Run `scripts/create-project.sh <cluster> <namespace>` to provision backup credentials for a new project namespace. This creates OCI users, IAM policies, B2 keys, and stores credentials in OCI Vault. The script outputs YAML snippets to add to git (cluster infra.yaml and project config).

See also: `scripts/setup-oci-vault-clustersecretstore.sh <cluster>` — one-time per-cluster setup for the `oci-vault` ClusterSecretStore.

### Backup Infrastructure

- **K8up** (current): Restic-based, backs up to Backblaze B2 (`zem-backups-eu` bucket)

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

### Git Remote

- Repo URL used in sources: `https://github.com/danfoster/zem-gitops`
- Default branch: `main`
- ArgoCD namespace: `argocd`
