# Repository Summary

> Navigation guide for this repo. For rules and conventions, see `CLAUDE.md`.

## What this repo is

GitOps repo managing three Kubernetes clusters via ArgoCD. Holds infrastructure *chart code*, project workload *charts*, and bootstrap configuration. Both ApplicationSet drivers (project-generator/project-instance for app deployment, infra-generator for infra features) and their config trees (`projects/`, `infra/`) live in the separate `gitops` repo (`https://github.com/zemlab/gitops`, checked out at `~/git/zem/gitops`); this repo links to it per-cluster via the `bootstrap/cluster-bootstrap` chart (which wires `infra-generator`) and the static `project-generator` Application.

---

## Clusters at a glance

| Cluster | Role | Storage | Ingress | Notable |
|---------|------|---------|---------|---------|
| **cluster01** | Primary / on-prem | OpenEBS | MetalLB + nginx | Media stack, AWX, smartctl |
| **cluster03** | OCI secondary | none (OCI NLB) | cloudflare-ingress + nginx | MariaDB, OCI MySQL, pce-prod |
| **cluster04** | OCI cloud-native | Longhorn | cloudflare-ingress only | GitLab, Zenith, CNPG |

`kubectl` contexts: `<cluster>.shark-puffin.ts.net`

---

## Directory map

```
apps/
  infra/zem-<name>/     Helm wrapper charts for infra tools (28 total)
  media/                Plex, Radarr, Sonarr, Transmission, Samba
  networking/           Omada controller
  zem-external/         Calibre-web, wiki, WordPress, echo
  zem-gitlab/           GitLab runner
  zem-internal/         Homepage dashboard
  awx/                  AWX (Ansible)

bootstrap/
  helmfile.yaml.gotmpl  6 pre-ArgoCD releases (cert-manager → ESO → tailscale → ArgoCD)
  values/<cluster>.yaml Per-cluster bootstrap values
  <cluster>.yaml        Root ArgoCD Application per cluster, wires cluster-bootstrap with cluster.name
  cluster-bootstrap/    Chart: renders gitops/infra AppProjects + infra-generator Application
                        (identical across clusters bar the one cluster.name value)
  new-cluster.sh        Full new-cluster setup script
  bootstrap.sh          Re-run bootstrap on existing cluster

scripts/                Operational scripts (see below)
docs/                   Design docs and this file
```

The `gitops` repo (`~/git/zem/gitops`) holds both ApplicationSet drivers:
```
charts/
  project-generator/    ApplicationSet that discovers project-envs per cluster
  project-instance/     Per-project-env Namespace/AppProject + app ApplicationSet
  infra-generator/      ApplicationSet that discovers enabled infra features per cluster

projects/
  <project>/
    envs/<cluster>/     Per-cluster/env values passed to the project-instance chart
    <app>/app.yaml      Per-app source (often points back at this repo's apps/<...>)

infra/
  <feature>/
    app.yaml            releaseName, source (chart code path or helm repo), namespace
    values.yaml         Optional base values shared across clusters
    envs/<cluster>.yaml Presence = feature enabled on that cluster; per-cluster values
```

---

## How infra features work

1. **Enabled = an `infra/<feature>/envs/<cluster>.yaml` file exists** (in the `gitops` repo)
2. Each feature has a **wrapper chart** at `apps/infra/zem-<name>/` (in this repo) or points at an external Helm repo
3. `infra/<feature>/app.yaml` (in the `gitops` repo) supplies the source/namespace
4. The `infra-features` ApplicationSet (from `charts/infra-generator`, wired per cluster by the `infra-generator` Application rendered from `bootstrap/cluster-bootstrap`) merges the two and creates/updates one Application per enabled feature — one reconcile, no parent app-of-apps to re-sync

To add a new infra tool: create the wrapper chart in this repo, add `infra/<name>/app.yaml` in the `gitops` repo, enable per cluster with `infra/<name>/envs/<cluster>.yaml`.

---

## How projects work

Projects are application workloads (media, pce, zenith, gitlab, etc). Their driver config lives in the
`gitops` repo, not here. Each project:

- Has a **values file** at `projects/<project>/envs/<cluster>/<env>.yaml` (in the `gitops` repo)
- Gets a **project-instance** Application rendered from `charts/project-instance` (in the `gitops` repo)
- That Application creates a Namespace, AppProject, and one ApplicationSet-generated Application per app
- Most apps' charts (`apps/<...>` referenced by each `projects/*/app.yaml`) still live in **this** repo

To onboard a new project namespace: **always use `scripts/create-project.sh <cluster> <namespace>`** — it provisions OCI users, IAM policies, B2 keys, restic passwords, and OCI Vault secrets, then generates the git files.

---

## Secrets routing

Two secret stores exist on every cluster:

| Store | Type | Used for |
|-------|------|----------|
| `zem-infra` (Bitwarden) | ClusterSecretStore | Cluster-wide infra secrets (tunnel tokens, registry creds, etc.) |
| `oci-vault` (OCI Vault) | ClusterSecretStore | Per-namespace project credentials (auto-replicated) |

Infra ExternalSecrets pull from `zem-infra`. Project ExternalSecrets pull from the per-namespace `oci-vault` SecretStore (which uses credentials replicated by `project-credentials`).

---

## Key scripts

| Script | Purpose |
|--------|---------|
| `create-project.sh <cluster> <ns>` | Full project namespace onboarding |
| `remove-project.sh <cluster> <ns>` | Tear down project and all cloud resources |
| `provision-cloudflare-ingress.sh <cluster>` | Store Cloudflare API creds in OCI Vault |
| `provision-tailscale-oauth.sh <cluster>` | Create/rotate Tailscale OAuth client in Bitwarden |
| `setup-oci-vault-clustersecretstore.sh <cluster>` | One-time per-cluster OCI Vault setup |
| `store-vault-secret.sh` | Create/update arbitrary JSON secret in OCI Vault |
| `migrate-project-secrets.sh` | Rename project secrets across clusters |
| `create-mysql-backup-credentials.sh` | Setup B2 backup credentials for MariaDB |
| `oci-login.sh` | OCI session refresh helper |

---

## Bootstrap sequence

Run once per new cluster via `bootstrap/new-cluster.sh <cluster> <bw-token>`:

1. **cert-manager** — TLS foundation
2. **external-secrets** + **zem-external-secrets** — Bitwarden + OCI Vault secret stores
3. **tailscale-operator** + **zem-tailscale** — cluster joins Tailscale, subnet router configured
4. **argocd** — takes over; everything else is GitOps from here

For an existing cluster, re-run with `bootstrap/bootstrap.sh <cluster> <bw-token>`.

---

## ArgoCD conventions

- All Application CRs live in the **`gitops`** namespace (not `argocd`)
- All Applications carry `resources-finalizer.argocd.argoproj.io` — deleting cascades
- `argocd-cm` is **not** Helm-managed; patch it directly with `kubectl patch`
- The `cluster01` / `cluster03` / `cluster04` Applications (bootstrap-applied) each track `bootstrap/cluster-bootstrap` and manage `infra-generator` as a child Application

---

## Active projects per cluster

| Project | cluster01 | cluster03 | cluster04 |
|---------|-----------|-----------|-----------|
| media | ✓ | | |
| awx | ✓ | | |
| networking | ✓ | | |
| pce | | ✓ | |
| zenith | | | ✓ |
| gitlab | | | ✓ |
| zem-external | | | ✓ |
| zem-internal | | | ✓ |
