# K8up Per-Namespace Backup Isolation Plan

## Context

K8up currently uses shared global B2 credentials and a single restic password for all backups. When backup pods run in application namespaces, namespace admins can see these shared credentials, giving them access to ALL backups across the cluster. This breaks namespace-based RBAC isolation.

**Goal:** Per-namespace B2 credentials and restic keys, stored in OCI Vault (free tier), with a provisioning script to easily onboard new namespaces. Applies to all clusters (on-prem and OCI).

---

## Secret Store: OCI Vault (Recommended)

**Why OCI Vault over alternatives:**
- **Free:** DEFAULT vault type + SOFTWARE keys = $0. 150 Always Free secrets.
- **Already in use:** Vault + master key exist in `zem-infra/infra/envs/oci-zem/20-app-infra/vault.tf`
- **ESO support:** Already proven with `oci-vault-store` in `zem-external-dbs`
- **Cross-cloud:** On-prem clusters access via User Principal (API key auth)
- **Terraform-managed:** Secrets can be managed as IaC in `zem-infra`

**Security model:**
- **Per-namespace OCI user** with IAM policy scoped to only that namespace's secrets
- **Per-namespace SecretStore** (NOT ClusterSecretStore) - prevents namespace A from requesting namespace B's secrets
- Even if an OCI API key leaks, it can only read that namespace's backup credentials

**Auth chain (all cluster types):**
1. Provisioning script creates OCI user + API key per namespace, stores API key in Bitwarden
2. `zem-infra` Bitwarden ClusterSecretStore pulls ALL OCI API keys into a central infra namespace (`backup-credentials`)
3. **kubernetes-replicator** mirrors each API key secret to its target app namespace only
4. Per-namespace **SecretStore** references the local (replicated) API key secret
5. Per-namespace **ExternalSecrets** pull backup creds from OCI Vault via the namespace SecretStore

**Credential flow:**
```
Bitwarden ──► backup-credentials ns (infra, RBAC-protected)
                     │
          kubernetes-replicator (per-secret targeting)
                     │
              ┌──────┼──────┐
              ▼      ▼      ▼
          pce-prod  media  zem-ext   ← each gets ONLY its own API key
              │      │      │
         SecretStore (per-ns, scoped OCI user)
              │      │      │
         OCI Vault ─────────────────  ← each user can only read its own secrets
              │      │      │
         ExternalSecrets (B2 creds + restic pw)
```

**Keep Bitwarden for:** Infra secrets + OCI API key distribution (unchanged).
**Use OCI Vault for:** Backup credentials (B2 keys + restic passwords per namespace).

---

## B2 Bucket Strategy

Use **one shared bucket** (`zem-backups-eu`) with **per-namespace prefix-scoped API keys**:

```
zem-backups-eu/
├── cluster01/
│   ├── media-prod/        ← B2 key scoped to this prefix
│   └── ...
├── cluster02/
│   ├── zem-external-prod/ ← B2 key scoped to this prefix
│   └── ...
└── cluster03/
    ├── pce-prod/          ← B2 key scoped to this prefix
    └── ...
```

B2 application keys support `namePrefix` restriction - each key can only read/write files under its prefix. If key for `pce-prod` leaks, only `pce-prod` backups are accessible.

---

## Architecture

```
Provisioning Script (run once per namespace)
│
├─► B2: Create app key (scoped to cluster/namespace prefix)
├─► Generate random restic password
├─► OCI: Create user + API key + scoped IAM policy
├─► OCI Vault: Store B2 creds + restic password
└─► Bitwarden: Store OCI API key (for distribution to K8s)

                    ┌──────────────────────────────┐
                    │  Bitwarden                    │
                    │  - pce-prod-oci-api-key       │
                    │  - media-prod-oci-api-key     │
                    │  - ...                        │
                    └──────────────┬────────────────┘
                                   │ zem-infra ClusterSecretStore
                                   ▼
                    ┌──────────────────────────────┐
                    │  backup-credentials ns       │
                    │  (infra-labeled, RBAC-locked) │
                    │  K8s Secrets:                 │
                    │  - pce-prod-oci-creds        │
                    │  - media-prod-oci-creds      │
                    │  (annotated for replication)  │
                    └──────────────┬────────────────┘
                                   │ kubernetes-replicator
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              ┌──────────┐  ┌──────────┐  ┌──────────┐
              │ pce-prod │  │media-prod│  │ zem-ext  │
              │          │  │          │  │          │
              │ Secret:  │  │ Secret:  │  │ Secret:  │
              │ oci-creds│  │ oci-creds│  │ oci-creds│
              │    │     │  │    │     │  │    │     │
              │ SecretSt.│  │ SecretSt.│  │ SecretSt.│
              │    │     │  │    │     │  │    │     │
              │ ExtSec:  │  │ ExtSec:  │  │ ExtSec:  │
              │ b2-creds │  │ b2-creds │  │ b2-creds │
              │ restic-pw│  │ restic-pw│  │ restic-pw│
              │    │     │  │    │     │  │    │     │
              │ Schedule │  │ Schedule │  │ Schedule │
              └──────────┘  └──────────┘  └──────────┘
                    │              │              │
                    └──────────────┼──────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │  OCI Vault                    │
                    │  Each user scoped to own      │
                    │  secrets only via IAM policy  │
                    └──────────────────────────────┘
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │  Backblaze B2                 │
                    │  zem-backups-eu/              │
                    │  ├── cluster01/media-prod/    │
                    │  ├── cluster03/pce-prod/      │
                    │  └── ...                      │
                    └──────────────────────────────┘
```

---

## Ownership: Per-Deployment (Recommended)

Each deployment's app-of-apps (media, pce, zem-external) remains responsible for deploying its own `zem-backups` instance.

**Why not centralized:**
- A central chart deploying to multiple namespaces would need the `infra` AppProject to have write access to ALL app namespaces - this breaks the existing isolation
- Each deployment's AppProject (e.g., `pce-prod`) is scoped to its own namespace only (`deployments/pce/templates/appproject.yaml`)
- Per-deployment keeps ownership clear and respects ArgoCD project boundaries

**Current pattern (keep):** Each deployment has `templates/backups.application.yaml` pointing to the shared `zem-backups` chart. The chart gets enhanced with credential management.

---

## Implementation

### Step 1: Create Infra Chart for OCI API Key Distribution

**New infra feature:** `zem-backup-credentials` - a central chart that:
- Deploys to a `backup-credentials` namespace (infra-labeled)
- Creates ExternalSecrets pulling OCI API keys from Bitwarden
- Annotates each secret for kubernetes-replicator to mirror to the target namespace

**New files:**
- `apps/infra/zem-backup-credentials/Chart.yaml`
- `apps/infra/zem-backup-credentials/values.yaml`
- `apps/infra/zem-backup-credentials/templates/externalsecrets.yaml`

**values.yaml structure:**
```yaml
namespaces:
  - name: pce-prod
    bitwardenKey: pce-prod-oci-api-key      # key in Bitwarden
    targetNamespace: pce-prod                # where to replicate
  - name: media-prod
    bitwardenKey: media-prod-oci-api-key
    targetNamespace: media-prod
  # ... per namespace
```

**Template** iterates over namespaces and creates:
```yaml
{{- range .Values.namespaces }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .name }}-oci-creds
  annotations:
    replicator.v1.mittwald.de/replicate-to: {{ .targetNamespace }}
spec:
  secretStoreRef:
    name: zem-infra
    kind: ClusterSecretStore
  target:
    name: {{ .name }}-oci-creds
  data:
    - secretKey: privateKey
      remoteRef:
        key: {{ .bitwardenKey }}-private-key
    - secretKey: fingerprint
      remoteRef:
        key: {{ .bitwardenKey }}-fingerprint
    - secretKey: userOcid
      remoteRef:
        key: {{ .bitwardenKey }}-user-ocid
{{- end }}
```

**Add to `deployments/infra/values.yaml`:**
```yaml
backup-credentials:
  enabled: false
  namespace: backup-credentials
  source:
    repoURL: https://github.com/danfoster/zem-gitops
    targetRevision: main
    path: apps/infra/zem-backup-credentials
```

### Step 2: Enhance zem-backups Chart

**Modify:** `apps/infra/zem-backups/`

Current chart only has `templates/schedule.yaml`. Enhance to include:

**New template:** `templates/secretstore.yaml` - Per-namespace OCI Vault SecretStore:
```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: oci-vault-backups
spec:
  provider:
    oracle:
      vault: "{{ .Values.ociVault.vaultOcid }}"
      compartment: "{{ .Values.ociVault.compartmentOcid }}"
      region: "{{ .Values.ociVault.region }}"
      principalType: UserPrincipal
      auth:
        secretRef:
          privatekey:
            name: {{ .Values.ociVault.credentialSecretName }}
            key: privateKey
          fingerprint:
            name: {{ .Values.ociVault.credentialSecretName }}
            key: fingerprint
      user: "{{ .Values.ociVault.userOcid }}"  # per-namespace OCI user
      tenancy: "{{ .Values.ociVault.tenancyOcid }}"
```

**New template:** `templates/externalsecret.yaml` - Pulls backup creds from OCI Vault:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backup-b2-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault-backups
    kind: SecretStore
  target:
    name: backup-b2-credentials
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: {{ .Values.b2.secretPrefix }}-b2-access-id
    - secretKey: SECRET_ACCESS_KEY
      remoteRef:
        key: {{ .Values.b2.secretPrefix }}-b2-secret-key
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backup-restic-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: oci-vault-backups
    kind: SecretStore
  target:
    name: backup-restic-credentials
  data:
    - secretKey: password
      remoteRef:
        key: {{ .Values.b2.secretPrefix }}-restic-password
```

**Modify template:** `templates/schedule.yaml` - Add per-namespace backend:
```yaml
spec:
  backend:
    s3:
      endpoint: {{ .Values.b2.endpoint }}
      bucket: {{ .Values.b2.bucket }}
      accessKeyIDSecretRef:
        name: backup-b2-credentials
        key: ACCESS_KEY_ID
      secretAccessKeySecretRef:
        name: backup-b2-credentials
        key: SECRET_ACCESS_KEY
    repoPasswordSecretRef:
      name: backup-restic-credentials
      key: password
```

**New values structure:** `values.yaml`
```yaml
ociVault:
  vaultOcid: ""
  compartmentOcid: ""
  region: "uk-london-1"
  tenancyOcid: ""
  userOcid: ""                          # per-namespace OCI user OCID
  credentialSecretName: ""              # name of replicated secret with OCI API key

b2:
  endpoint: "https://s3.eu-central-003.backblazeb2.com"
  bucket: "zem-backups-eu"
  secretPrefix: ""  # e.g., "cluster03-pce-prod"

backup:
  schedule: "@daily-random"
check:
  schedule: "@weekly-random"
prune:
  schedule: "@weekly-random"
  retention:
    keepLast: 5
    keepDaily: 14
    keepWeekly: 8
    keepMonthly: 12
    keepYearly: 5
```

### Step 3: Remove Global Credentials from K8up

**Modify:** `apps/infra/zem-k8up/values.yaml`

Remove all `BACKUP_GLOBAL*` env vars from k8up config. The operator no longer needs global S3/restic credentials since each Schedule specifies its own backend.

**Delete:** `apps/infra/zem-k8up/templates/b2.externalsecret.yaml`
**Delete:** `apps/infra/zem-k8up/templates/restic.externalsecret.yaml`
**Delete:** `apps/infra/zem-k8up/templates/rclone-deployment.yaml`
**Delete:** `apps/infra/zem-k8up/templates/rclone-service.yaml`
**Delete:** `apps/infra/zem-k8up/templates/rclone-networkpolicy.yaml`
**Delete:** `apps/infra/zem-k8up/templates/rclone-externalsecret.yaml`
**Remove:** `rclone` section from `apps/infra/zem-k8up/values.yaml`

### Step 4: Update Deployment Backup Applications

Each deployment's `backups.application.yaml` needs to pass OCI Vault config, B2 prefix, and credential secret name.

**Modify:** `deployments/pce/templates/backups.application.yaml`
```yaml
spec:
  source:
    path: apps/infra/zem-backups
    helm:
      valuesObject:
        ociVault:
          vaultOcid: "{{ .Values.ociVault.vaultOcid }}"
          compartmentOcid: "{{ .Values.ociVault.compartmentOcid }}"
          region: "{{ .Values.ociVault.region }}"
          tenancyOcid: "{{ .Values.ociVault.tenancyOcid }}"
          userOcid: "{{ .Values.backups.ociUserOcid }}"
          credentialSecretName: "{{ .Values.backups.ociCredentialSecret }}"
        b2:
          secretPrefix: "{{ .Values.cluster }}-pce-{{ .Values.env }}"
```

Each deployment's `values.yaml` gets shared OCI Vault config and per-deployment backup settings. Per-cluster overrides happen in `clusters/<name>/projects/*.yaml`:

```yaml
# clusters/cluster03/projects/pce.yaml
helm:
  valuesObject:
    env: prod
    cluster: cluster03
    ociVault:
      vaultOcid: "ocid1.vault..."
      compartmentOcid: "ocid1.compartment..."
      region: "uk-london-1"
      tenancyOcid: "ocid1.tenancy..."
    backups:
      ociUserOcid: "ocid1.user...pce-prod-backup"
      ociCredentialSecret: "pce-prod-oci-creds"
```

Similarly for `clusters/cluster01/projects/media.yaml`, etc.

**Fix:** The media deployment currently points to `apps/common/zem-backups` which doesn't exist. Fix to `apps/infra/zem-backups`.

### Step 5: Provisioning Script

**New file:** `scripts/provision-backup-namespace.sh`

```bash
#!/bin/bash
# Usage: ./provision-backup-namespace.sh <cluster-name> <namespace>
# Example: ./provision-backup-namespace.sh cluster03 pce-prod
#
# Creates:
# 1. OCI user + API key (scoped to this namespace's vault secrets)
# 2. OCI IAM policy restricting user to specific secrets
# 3. B2 application key scoped to <cluster>/<namespace>/ prefix
# 4. Random restic password
# 5. Stores B2 creds + restic password in OCI Vault
# 6. Stores OCI API key in Bitwarden (for distribution to K8s)
```

The script will:
1. **OCI user:** `oci iam user create` - e.g., `backup-<cluster>-<namespace>`
2. **OCI API key:** `oci iam user api-key upload` - generates keypair, uploads public key
3. **OCI IAM policy:** Create policy scoping user to secrets named `<cluster>-<namespace>-*`
4. **B2 key:** `b2 create-key` scoped to bucket `zem-backups-eu` with `namePrefix: <cluster>/<namespace>/`
5. **Restic password:** `openssl rand -base64 32`
6. **Store in OCI Vault:** `oci vault secret create-base64` for B2 creds + restic password
7. **Store in Bitwarden:** OCI API key (private key + fingerprint + user OCID) via `bws` CLI
8. **Print:** Summary of created resources + values to add to cluster config YAML

**Dependencies:** `oci`, `b2`, `bws` (Bitwarden Secrets CLI), `jq`, `openssl`

### Step 6: Add `backup-credentials` Entry to `zem-backup-credentials` Chart

For each new namespace, add an entry to the `zem-backup-credentials` chart values (via cluster config). The provisioning script outputs the required YAML snippet.

Also add `backup-credentials` namespace to the `zem-infra` ClusterSecretStore conditions (or label it `infra: "true"`).

### Step 7: Per-Cluster Configuration

**Modify:** `clusters/cluster03/infra.yaml` - pass OCI Vault config to external-secrets:
```yaml
features:
  external-secrets:
    values:
      ociVault:
        enabled: true
        vaultOcid: "ocid1.vault.oc1...."
        compartmentOcid: "ocid1.compartment.oc1...."
        principalType: "InstancePrincipal"
```

Similarly for cluster01/cluster02 with `principalType: "UserPrincipal"`.

---

## Files Summary

| Action                                      | Path                                                               | Notes                                                            |
| ------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------- |
| **New infra chart: zem-backup-credentials** |                                                                    |                                                                  |
| Create                                      | `apps/infra/zem-backup-credentials/Chart.yaml`                     | Chart metadata                                                   |
| Create                                      | `apps/infra/zem-backup-credentials/values.yaml`                    | Namespace list for OCI API key distribution                      |
| Create                                      | `apps/infra/zem-backup-credentials/templates/externalsecrets.yaml` | Pulls OCI API keys from Bitwarden, annotates for replication     |
| **Enhanced zem-backups chart**              |                                                                    |                                                                  |
| Modify                                      | `apps/infra/zem-backups/values.yaml`                               | Add `ociVault` + `b2` config blocks                              |
| Create                                      | `apps/infra/zem-backups/templates/secretstore.yaml`                | Per-namespace OCI Vault SecretStore                              |
| Create                                      | `apps/infra/zem-backups/templates/externalsecret.yaml`             | Per-namespace B2 + restic creds from OCI Vault                   |
| Modify                                      | `apps/infra/zem-backups/templates/schedule.yaml`                   | Add per-namespace backend config                                 |
| **K8up cleanup**                            |                                                                    |                                                                  |
| Modify                                      | `apps/infra/zem-k8up/values.yaml`                                  | Remove globals + rclone config                                   |
| Delete                                      | `apps/infra/zem-k8up/templates/b2.externalsecret.yaml`             |                                                                  |
| Delete                                      | `apps/infra/zem-k8up/templates/restic.externalsecret.yaml`         |                                                                  |
| Delete                                      | `apps/infra/zem-k8up/templates/rclone-deployment.yaml`             |                                                                  |
| Delete                                      | `apps/infra/zem-k8up/templates/rclone-service.yaml`                |                                                                  |
| Delete                                      | `apps/infra/zem-k8up/templates/rclone-networkpolicy.yaml`          |                                                                  |
| Delete                                      | `apps/infra/zem-k8up/templates/rclone-externalsecret.yaml`         |                                                                  |
| **Deployments**                             |                                                                    |                                                                  |
| Modify                                      | `deployments/pce/templates/backups.application.yaml`               | Add OCI Vault + B2 values                                        |
| Modify                                      | `deployments/media/templates/backups.application.yaml`             | Fix path + add values                                            |
| Modify                                      | `deployments/zem-external/templates/backups.application.yaml`      | Add OCI Vault + B2 values                                        |
| **Infra deployment**                        |                                                                    |                                                                  |
| Modify                                      | `deployments/infra/values.yaml`                                    | Add `backup-credentials` feature (disabled)                      |
| **Cluster configs**                         |                                                                    |                                                                  |
| Modify                                      | `clusters/cluster01/infra.yaml`                                    | Enable backup-credentials + namespace list                       |
| Modify                                      | `clusters/cluster01/projects/media.yaml`                           | Add `cluster` + `ociVault` + `backups` values                    |
| Modify                                      | `clusters/cluster02/infra.yaml`                                    | Enable backup-credentials + namespace list                       |
| Modify                                      | `clusters/cluster02/projects/zem-external.yaml`                    | Add `cluster` + `ociVault` + `backups` values                    |
| Modify                                      | `clusters/cluster03/infra.yaml`                                    | Enable backup-credentials + namespace list                       |
| Modify                                      | `clusters/cluster03/projects/pce.yaml`                             | Add `cluster` + `ociVault` + `backups` values                    |
| **Provisioning**                            |                                                                    |                                                                  |
| Create                                      | `scripts/provision-backup-namespace.sh`                            | Full provisioning: OCI user + B2 key + vault secrets + Bitwarden |

---

## Migration Strategy

1. **Phase 1:** Deploy OCI Vault ClusterSecretStore alongside existing Bitwarden store
2. **Phase 2:** Run provisioning script for existing namespaces (pce-prod, media-prod, zem-external-prod)
3. **Phase 3:** Deploy enhanced zem-backups chart to one namespace first (e.g., pce-prod on cluster03)
4. **Phase 4:** Verify backup works end-to-end with per-namespace creds
5. **Phase 5:** Roll out to all namespaces on all clusters
6. **Phase 6:** Remove global credentials from K8up

---

## Verification

1. Run provisioning script for a test namespace
2. Verify OCI Vault secrets exist: `oci vault secret list`
3. Verify ExternalSecrets sync: `kubectl get externalsecret -n <ns>`
4. Verify K8up Schedule has backend config: `kubectl get schedule -n <ns> -o yaml`
5. Trigger a manual backup and confirm it writes to the correct B2 prefix
6. Verify namespace A's credentials cannot access namespace B's backup prefix
7. Test restore from the per-namespace backup

---

## Notes

- **OCI Vault free tier:** 150 Always Free secrets, SOFTWARE keys are free. More than enough for per-namespace backup creds.
- **B2 application keys** support `namePrefix` restriction, scoping access to a specific path within the bucket.
- **K8up Schedule backend:** The K8up Schedule CRD supports per-schedule `spec.backend` configuration, overriding any global settings.
- **Velero removed from scope:** CSI snapshots for OCI can be revisited independently later.

## Sources

- [OCI Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [ESO Oracle Vault Provider](https://external-secrets.io/latest/provider/oracle-vault/)
- [B2 Application Keys](https://www.backblaze.com/docs/cloud-storage-application-keys)
- [B2 Pricing](https://www.backblaze.com/cloud-storage/pricing)
