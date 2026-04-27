# ApplicationSet Migration

## Problem

Changing a value in `clusters/<cluster>/projects/<project>.yaml` requires syncing 3 Applications in sequence:

```
projects → zenith-staging → zenith-backend-staging
```

Each level waits for the previous to complete before detecting drift. With ArgoCD's default refresh interval, this is slow even with auto-sync enabled.

## Current Architecture

```
projects Application (watches clusters/<cluster>/projects/)
  → <project> Application (raw manifest in projects/ dir)
    → deployments/project Helm chart (app-of-apps)
      → AppProject, Namespace, backend, frontend, project-common Applications
```

`deployments/project/` is a Helm chart generating:
- 1x AppProject (in `argocd` ns)
- 1x Namespace
- N child Applications (one per enabled service)

## Why ApplicationSet Helps

ApplicationSet controller is not an Application — it reconciles immediately when its CR changes. Cascade becomes:

```
projects → [ApplicationSet controller reconciles instantly] → service apps auto-sync
```

1 sync instead of 3.

## The Core Tension

**ApplicationSet can only generate Applications** — not AppProject or Namespace. These need a separate owner. This is the blocker for a clean general pattern.

## Options

### Option A: Split per project (2 files)

```
clusters/<cluster>/projects/
  <project>-infra.yaml   ← Application → deployments/project with all services disabled
                            (renders AppProject + Namespace only)
  <project>-appset.yaml  ← ApplicationSet → service Applications
```

- Infra changes rare → 2-sync cascade acceptable
- Service version bumps (frequent) → 1 sync only
- Reuses existing `deployments/project/` chart for infra

**Downside:** 2 files per project instead of 1.

### Option B: Fix cascade differently, keep current architecture

- **ArgoCD webhook** — git push triggers instant refresh simultaneously on all levels; cascade happens in seconds automatically
- No migration, zero architectural change

## Open Questions

1. Which is the bigger pain: multi-sync UX friction or wanting better architectural separation?
2. Is the 2-file split acceptable as a general pattern for all projects?
3. Is a webhook configured on the ArgoCD instance? (Would solve the timing issue without migration.)
