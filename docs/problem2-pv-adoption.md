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

```bash
# 1. List PVs in Released state
kubectl get pv | grep Released

# 2. Remove claimRef so PV becomes Available
kubectl patch pv <pv-name> --type json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'

# 3. Set existingVolumeName in cluster values, sync ArgoCD app
```
