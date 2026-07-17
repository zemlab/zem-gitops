# Repository Summary

> Navigation guide for this repo. For rules and conventions, see `CLAUDE.md`.

## What this repo is

GitOps repo managing three Kubernetes clusters via ArgoCD. Holds infrastructure features, project workload *charts*, and bootstrap configuration. The application-deployment engine and `projects/` config now live in the separate `gitops` repo (`https://github.com/zemlab/gitops`, checked out at `~/git/zem/gitops`); this repo links to it via one bridge — the `project-generator` feature in `deployments/infra/values.yaml`.

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
  new-cluster.sh        Full new-cluster setup script
  bootstrap.sh          Re-run bootstrap on existing cluster

clusters/
  <cluster>/
    infra.yaml          ArgoCD Application — enables/configures infra features
    gitops.project.yaml ArgoCD AppProject definition

deployments/
  infra/                App-of-apps: renders an ArgoCD Application per enabled feature
    values.yaml         Master feature registry (all features defined here); the
                        "project-generator" feature is the bridge to the gitops repo

scripts/                Operational scripts (see below)
docs/                   Design docs and this file
```

The `gitops` repo (`~/git/zem/gitops`) holds the app-deployment engine:
```
charts/
  project-generator/    ApplicationSet that discovers project-envs per cluster
  project-instance/     Per-project-env Namespace/AppProject + app ApplicationSet

projects/
  <project>/
    envs/<cluster>/     Per-cluster/env values passed to the project-instance chart
    <app>/app.yaml      Per-app source (often points back at this repo's apps/<...>)
```

---

## How infra features work

1. Every feature is **defined** (disabled by default) in `deployments/infra/values.yaml`
2. Each feature has a **wrapper chart** at `apps/infra/zem-<name>/`
3. Each cluster **enables** features it needs in `clusters/<cluster>/infra.yaml`
4. ArgoCD renders `deployments/infra` with the cluster's `valuesObject` → creates one Application per enabled feature

To add a new infra tool: create the wrapper chart, add the feature to `values.yaml`, enable it in the target cluster's `infra.yaml`.

> `helm template test deployments/infra -f clusters/<cluster>/infra.yaml` catches syntax errors but does NOT accurately reflect ArgoCD rendering (infra.yaml is an Application manifest, not a pure values file).

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
- The `cluster03` / `cluster04` Applications (bootstrap-applied) each track `clusters/<cluster>/` and manage `infra` as a child Application

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
