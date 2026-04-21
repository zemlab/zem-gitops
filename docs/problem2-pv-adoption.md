# Problem 2: PV Adoption for Stateful Apps (DR Pattern)

## Summary

When a stateful app is redeployed (new cluster, new namespace, or post-incident), ArgoCD creates a new PVC which provisions a new PV. The original PV with data still exists (if storage class uses `Retain` policy) but is not automatically re-adopted.

**Required behaviour:**
- Default: auto-provision PVs (no change to normal deploys)
- DR mode: specify existing PV name → PVC binds to it and adopts the data

## Storage Classes in Use

- **Longhorn** — cluster02, cluster04 (default SC from Longhorn helm chart)
- **OCI Block Storage** — cluster04 (cloud provider default SC)
- **openebs-hostpath** — cluster01 (local node storage)

## Issue: Default Reclaim Policy

Longhorn default storage class uses `reclaimPolicy: Delete`. When PVC is deleted, PV is also destroyed. For DR adoption to work, the PV must survive PVC deletion.

**Fix:** Override Longhorn storage class reclaim policy to `Retain` in `apps/infra/zem-longhorn/values.yaml`:

```yaml
longhorn:
  persistence:
    defaultClassReplicaCount: 2
    reclaimPolicy: Retain
```

Or create a dedicated `longhorn-retain` StorageClass for stateful workloads:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-retain
provisioner: driver.longhorn.io
reclaimPolicy: Retain
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
```

## PVC Template Pattern

Add optional `existingVolumeName` value (default empty = auto-provision). When set, PVC binds to named PV.

**values.yaml:**
```yaml
persistence:
  storageClass: longhorn
  size: 10Gi
  existingVolumeName: ""  # Set in DR to adopt existing PV
```

**pvc.yaml template:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Release.Name }}-data
spec:
  storageClassName: {{ .Values.persistence.storageClass }}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
  {{- if .Values.persistence.existingVolumeName }}
  volumeName: {{ .Values.persistence.existingVolumeName }}
  {{- end }}
```

## DR Recovery Procedure

After incident where PVC was deleted but PV retained:

```bash
# 1. List PVs and find the one with data (status: Released)
kubectl get pv | grep Released

# 2. Remove claimRef so PV becomes Available again
kubectl patch pv <pv-name> --type json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'

# 3. In cluster values file, set existingVolumeName
# e.g. clusters/cluster02/infra.yaml or project values file:
#   persistence:
#     existingVolumeName: <pv-name>

# 4. Sync ArgoCD app — PVC will bind to existing PV
```

## Stateful Apps to Update

Charts in this repo that define their own PVCs (add existingVolumeName pattern):

| App | File | Storage |
|-----|------|---------|
| plex | `apps/media/plex/templates/config.pvc.yaml` | 100Gi |
| radarr | `apps/media/radarr/templates/config.pvc.yaml` | 3Gi |
| sonarr | `apps/media/sonarr/templates/config.pvc.yaml` | 3Gi |
| transmission | `apps/media/transmission/templates/config.pvc.yaml` | 3Gi |
| wiki | `apps/zem-external/wiki/templates/pvc.yaml` | 10Gi |
| wordpress | `apps/zem-external/wordpress/templates/wordpress.pvc.yaml` | varies |

## Exceptions

**CNPG (zenith-prod):** Uses WAL archiving + continuous backup to B2. DR = restore from backup via CNPG recovery cluster spec. PV adoption not applicable — CNPG manages its own storage.

**Immich photos:** Already uses explicit PV binding (`photos.pv.yaml` + `photos.pvc.yaml` with `volumeName: photos`). Pattern already correct.
