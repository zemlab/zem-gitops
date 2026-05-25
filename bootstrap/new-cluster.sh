#!/bin/bash
set -euo pipefail

# Bootstrap a new cluster from scratch.
#
# Creates all required git artifacts, waits for you to commit/push,
# then runs the full helmfile bootstrap (2 phases) with OCI Vault setup
# as a hard requirement between the phases.
#
# Usage: ./new-cluster.sh <cluster-name> <bitwarden-auth-token>
# Example: ./new-cluster.sh cluster04 <bw-token>
#
# Required env vars:
#   BWS_ACCESS_TOKEN   - Bitwarden Secrets Manager machine account token (write access)
#   TS_API_KEY         - Tailscale API key (for creating ACL tags)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    echo "Usage: $0 <cluster-name> <bitwarden-auth-token>"
    echo "Example: $0 cluster04 your_bitwarden_token"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

CLUSTER="$1"
export BW_AUTH_TOKEN="$2"

# ============================================================
# Phase 0: Preflight checks
# ============================================================
echo "=== Phase 0: Preflight checks ==="

for cmd in helmfile helm kubectl oci jq openssl yq bws; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

for var in BWS_ACCESS_TOKEN TS_API_KEY; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} env var is required but not set"
        exit 1
    fi
done

if ! helm plugin list | grep -q diff; then
    echo "ERROR: helm-diff plugin is required."
    echo "       Install with: helm plugin install https://github.com/databus23/helm-diff"
    exit 1
fi

echo "All dependencies present."

echo "--- Preflight: checking OCI authentication ---"
if ! oci iam region list --output json </dev/null >/dev/null 2>&1; then
    echo "ERROR: OCI authentication failed. If using security_token auth, run: oci session refresh"
    exit 1
fi
echo "OCI auth OK"
echo ""

# ============================================================
# Phase 1: Create git artifacts
# ============================================================
echo "=== Phase 1: Creating git artifacts ==="

BOOTSTRAP_VALUES="${SCRIPT_DIR}/values/${CLUSTER}.yaml"
ARGOCD_APP="${SCRIPT_DIR}/${CLUSTER}.yaml"
CLUSTER_DIR="${REPO_ROOT}/clusters/${CLUSTER}"
GITOPS_PROJECT="${CLUSTER_DIR}/gitops.project.yaml"
INFRA_YAML="${CLUSTER_DIR}/infra.yaml"
HELMFILE="${SCRIPT_DIR}/helmfile.yaml.gotmpl"

# Fail fast if any target already exists
for f in "$BOOTSTRAP_VALUES" "$ARGOCD_APP" "$GITOPS_PROJECT" "$INFRA_YAML"; do
    if [ -f "$f" ]; then
        echo "ERROR: $f already exists. Remove it first or use bootstrap.sh to re-run an existing cluster."
        exit 1
    fi
done

# 1. bootstrap/values/<cluster>.yaml
cat > "$BOOTSTRAP_VALUES" << EOF
cluster:
  name: ${CLUSTER}

ociVault:
  enabled: false
EOF
echo "Created: ${BOOTSTRAP_VALUES}"

# 2. Add environment entry to helmfile.yaml.gotmpl (insert before the --- separator)
# Uses Python for reliable multi-line insertion before the first '---' line.
python3 - "$HELMFILE" "$CLUSTER" << 'PYEOF'
import sys

helmfile_path = sys.argv[1]
cluster = sys.argv[2]

new_env = f"  {cluster}:\n    values:\n      - values/common.yaml\n      - values/{cluster}.yaml\n"

with open(helmfile_path, 'r') as f:
    content = f.read()

# Insert before the first '---' line (document separator)
separator = '\n---\n'
if separator not in content:
    print(f"ERROR: Could not find '---' separator in {helmfile_path}")
    sys.exit(1)

if f"\n  {cluster}:\n" in content:
    print(f"WARNING: {cluster} environment already exists in {helmfile_path}, skipping.")
    sys.exit(0)

idx = content.index(separator)
new_content = content[:idx] + "\n" + new_env + content[idx:]

with open(helmfile_path, 'w') as f:
    f.write(new_content)
PYEOF
echo "Updated: ${HELMFILE} (added ${CLUSTER} environment)"

# 3. bootstrap/<cluster>.yaml (ArgoCD Application)
cat > "$ARGOCD_APP" << EOF
kind: Application
apiVersion: argoproj.io/v1alpha1
metadata:
  name: ${CLUSTER}
  namespace: gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    namespace: gitops
    server: https://kubernetes.default.svc
  project: gitops
  source:
    path: clusters/${CLUSTER}
    repoURL: https://gitlab.com/zemlab/zem-gitops.git
    targetRevision: main
  syncPolicy:
    automated:
      prune: true
EOF
echo "Created: ${ARGOCD_APP}"

# 4. clusters/<cluster>/gitops.project.yaml
mkdir -p "$CLUSTER_DIR"
cat > "$GITOPS_PROJECT" << EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: gitops
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  description: GitOps Project
  destinations:
    - namespace: "gitops"
      server: "https://kubernetes.default.svc"
    - namespace: "argocd"
      server: "https://kubernetes.default.svc"
  sourceNamespaces:
    - gitops
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  sourceRepos:
    - "https://gitlab.com/zemlab/zem-gitops"
EOF
echo "Created: ${GITOPS_PROJECT}"

# 5. clusters/<cluster>/infra.yaml skeleton
cat > "$INFRA_YAML" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra
  namespace: gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: gitops
  source:
    repoURL: https://gitlab.com/zemlab/zem-gitops
    targetRevision: main
    path: deployments/infra
    helm:
      valuesObject:
        common:
          values:
            cluster:
              name: ${CLUSTER}
        features: {}
        # TODO: enable features for ${CLUSTER}
        # Common examples:
        #   externaldns:
        #     enabled: true
        #     values:
        #       external-dns:
        #         txtOwnerId: "zem-c4"
        #   metallb:
        #     enabled: true
        #   metallb-configs:
        #     enabled: true
        #     values:
        #       addresses:
        #         - "x.x.x.x-x.x.x.x"
        #   longhorn:
        #     enabled: true
        #     values:
        #       ingress:
        #         hostname: longhorn-${CLUSTER}
        #   k8up:
        #     enabled: true
        #   kubernetes-replicator:
        #     enabled: true
        #   cloudflared:
        #     enabled: true
        #     values:
        #       externalSecret:
        #         remoteRefKey: cloudflared-token-${CLUSTER}
        #   project-credentials:
        #     enabled: true
        #     values:
        #       namespaces: []

  destination:
    server: "https://kubernetes.default.svc"
    namespace: gitops
  syncPolicy:
    automated:
      prune: true
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jsonPointers:
      - /spec/syncPolicy
EOF
echo "Created: ${INFRA_YAML}"
echo ""

# ============================================================
# Phase 2: Wait for user to commit and push
# ============================================================
echo "=== Phase 2: Commit and push required ==="
echo ""
echo "Files created:"
echo "  ${BOOTSTRAP_VALUES}"
echo "  ${HELMFILE} (updated)"
echo "  ${ARGOCD_APP}"
echo "  ${GITOPS_PROJECT}"
echo "  ${INFRA_YAML}"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  ACTION REQUIRED: commit and push these files to main.  │"
echo "  │  ArgoCD will sync clusters/${CLUSTER}/ on first start.  │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  Suggested commands:"
echo "    cd ${REPO_ROOT}"
echo "    git add bootstrap/helmfile.yaml.gotmpl bootstrap/values/${CLUSTER}.yaml \\"
echo "           bootstrap/${CLUSTER}.yaml clusters/${CLUSTER}/"
echo "    git commit -m 'feat(${CLUSTER}): add bootstrap config and cluster skeleton'"
echo "    git push"
echo ""
read -rp "Press Enter when pushed to main..."
echo ""

# ============================================================
# Phase 3: Provision Tailscale OAuth client + Bitwarden secrets
# ============================================================
echo "=== Phase 3: Provisioning Tailscale OAuth credentials ==="
echo ""

"${REPO_ROOT}/scripts/provision-tailscale-oauth.sh" "$CLUSTER"
echo ""

# ============================================================
# Phase 4: Helmfile bootstrap (phase 1 — without OCI Vault)
# ============================================================
echo "=== Phase 4: Helmfile bootstrap (phase 1) ==="
echo "Installing: cert-manager, ESO, zem-external-secrets (Bitwarden), tailscale-operator, zem-tailscale, ArgoCD"
echo ""

CURRENT_CONTEXT="$(kubectl config current-context)"
echo "kubectl context: ${CURRENT_CONTEXT}"
read -rp "Bootstrap ${CLUSTER} against this context? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi
echo ""

cd "$SCRIPT_DIR"
helmfile -e "$CLUSTER" apply --skip-diff-on-install
echo ""

# ============================================================
# Phase 5: OCI Vault setup (hard requirement)
# ============================================================
echo "=== Phase 5: OCI Vault setup ==="
echo ""

"${REPO_ROOT}/scripts/setup-oci-vault-clustersecretstore.sh" "$CLUSTER"
echo ""

# ============================================================
# Phase 6: Helmfile bootstrap (phase 2 — with OCI Vault)
# ============================================================
echo "=== Phase 6: Helmfile bootstrap (phase 2) ==="
echo "Re-applying with ociVault.enabled=true to create the OCI Vault ClusterSecretStore"
echo ""

cd "$SCRIPT_DIR"
helmfile -e "$CLUSTER" apply --skip-diff-on-install
echo ""

# ============================================================
# Phase 7: Next steps
# ============================================================
echo "=== Bootstrap complete for ${CLUSTER} ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Commit the updated OCI Vault values (written by phase 4):"
echo "     cd ${REPO_ROOT}"
echo "     git add bootstrap/values/${CLUSTER}.yaml"
echo "     git commit -m 'feat(${CLUSTER}): add oci vault bootstrap config'"
echo "     git push"
echo ""
echo "2. Customize ${INFRA_YAML} with required features."
echo "   Validate before pushing:"
echo "     helm template test ${REPO_ROOT}/deployments/infra -f ${INFRA_YAML}"
echo "     helm lint ${REPO_ROOT}/deployments/infra -f ${INFRA_YAML}"
echo ""
echo "3. For each project namespace, run:"
echo "     ${REPO_ROOT}/scripts/create-project.sh ${CLUSTER} <namespace>"
echo ""
echo "4. Verify cluster health:"
echo "     kubectl get applications -n gitops"
echo "     kubectl get clustersecretstore oci-vault -o jsonpath='{.status.conditions}'"
echo "     kubectl get secret oci-vault-auth -n external-secrets"
