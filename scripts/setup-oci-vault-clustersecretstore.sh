#!/bin/bash
set -euo pipefail

# Setup the OCI IAM user and K8s secret for the oci-vault ClusterSecretStore
#
# This creates an OCI user that can read ALL infra-prefixed secrets in OCI Vault.
# The user's API key is stored as a K8s secret in the external-secrets namespace,
# which the oci-vault ClusterSecretStore references.
#
# Run this ONCE per cluster.
#
# Dependencies: oci, kubectl, jq, openssl
#
# Usage: ./setup-oci-vault-clustersecretstore.sh <cluster-name>
# Example: ./setup-oci-vault-clustersecretstore.sh cluster03

if [ $# -ne 1 ]; then
    echo "Usage: $0 <cluster-name>"
    echo "Example: $0 cluster03"
    exit 1
fi

CLUSTER="$1"
# Set KUBE_CONTEXT env var to override the kubectl/helm context (e.g. for bootstrapping without Tailscale)
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
K8S_SECRET_NAME="${K8S_SECRET_NAME:-oci-vault-auth}"
K8S_NAMESPACE="${K8S_NAMESPACE:-external-secrets}"
OCI_USER_NAME="oci-vault-${CLUSTER}"

echo "=== Setting up OCI Vault ClusterSecretStore for ${CLUSTER} ==="
echo ""

# Check dependencies
for cmd in oci kubectl jq openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# Verify OCI auth is working (security_token sessions expire)
echo "--- Preflight: checking OCI authentication ---"
if ! oci iam region list --output json </dev/null >/dev/null 2>&1; then
    echo "ERROR: OCI authentication failed. If using security_token auth, run: oci session refresh"
    exit 1
fi
echo "OCI auth OK"
echo ""

# --- Step 1: Create OCI user ---
echo "--- Step 1: Creating OCI user ---"
OCI_USER_EMAIL="${OCI_USER_EMAIL:-${OCI_USER_NAME}@zem.org.uk}"
if OCI_USER=$(oci iam user create \
    --name "${OCI_USER_NAME}" \
    --email "${OCI_USER_EMAIL}" \
    --description "ClusterSecretStore user for reading infra secrets from OCI Vault (${CLUSTER})" \
    --output json 2>&1); then
    OCI_USER_OCID=$(echo "$OCI_USER" | jq -r '.data.id')
    echo "Created user: ${OCI_USER_NAME}"
else
    echo "User ${OCI_USER_NAME} already exists, looking up..."
    OCI_USER_OCID=$(oci iam user list --all --output json 2>&1 | jq -r ".data[] | select(.name == \"${OCI_USER_NAME}\") | .id")
fi

if [ -z "${OCI_USER_OCID}" ]; then
    echo "ERROR: Could not create or find OCI user '${OCI_USER_NAME}'"
    exit 1
fi
echo "OCI User OCID: ${OCI_USER_OCID}"

# --- Step 2: Generate and upload API key ---
echo "--- Step 2: Generating API key ---"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Remove any existing API keys
EXISTING_KEYS=$(oci iam user api-key list --user-id "${OCI_USER_OCID}" --output json | jq -r '.data[].fingerprint')
for fp in $EXISTING_KEYS; do
    echo "  Removing existing API key: ${fp}"
    oci iam user api-key delete --user-id "${OCI_USER_OCID}" --fingerprint "${fp}" --force
done

openssl genrsa -out "${TMPDIR}/api_key_pkcs8.pem" 2048 2>/dev/null
openssl rsa -traditional -in "${TMPDIR}/api_key_pkcs8.pem" -out "${TMPDIR}/api_key.pem" 2>/dev/null
openssl rsa -pubout -in "${TMPDIR}/api_key.pem" -out "${TMPDIR}/api_key_public.pem" 2>/dev/null

API_KEY_RESULT=$(oci iam user api-key upload \
    --user-id "${OCI_USER_OCID}" \
    --key-file "${TMPDIR}/api_key_public.pem" \
    --output json)
OCI_FINGERPRINT=$(echo "$API_KEY_RESULT" | jq -r '.data.fingerprint')
OCI_TENANCY_OCID=$(oci iam user get --user-id "${OCI_USER_OCID}" --output json | jq -r '.data."compartment-id"')
echo "API Key Fingerprint: ${OCI_FINGERPRINT}"

# --- Step 3: Create IAM policy ---
echo "--- Step 3: Creating IAM policy ---"
POLICY_NAME="oci-vault-${CLUSTER}-infra"
POLICY_STATEMENTS="[\"Allow any-user to read secret-family in compartment id ${OCI_COMPARTMENT_OCID} where ALL {request.user.id = '${OCI_USER_OCID}', target.secret.name = /infra-*/}\", \"Allow any-user to read vaults in compartment id ${OCI_COMPARTMENT_OCID} where request.user.id = '${OCI_USER_OCID}'\"]"

# Check if policy exists and update/create accordingly
EXISTING_POLICY_OCID=$(oci iam policy list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --all --output json 2>/dev/null | jq -r ".data[] | select(.name == \"${POLICY_NAME}\") | .id")

if [ -n "${EXISTING_POLICY_OCID}" ]; then
    oci iam policy update \
        --policy-id "${EXISTING_POLICY_OCID}" \
        --statements "${POLICY_STATEMENTS}" \
        --version-date "" \
        --force \
        --output json >/dev/null
    echo "Policy updated: ${POLICY_NAME}"
else
    oci iam policy create \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --name "${POLICY_NAME}" \
        --description "Allow ${OCI_USER_NAME} to read infra-prefixed secrets and inspect vaults" \
        --statements "${POLICY_STATEMENTS}" \
        --output json >/dev/null
    echo "Policy created: ${POLICY_NAME}"
fi

# --- Step 4: Create K8s secret ---
echo "--- Step 4: Creating K8s secret ---"
kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} create secret generic "${K8S_SECRET_NAME}" \
    --namespace "${K8S_NAMESPACE}" \
    --from-file=privateKey="${TMPDIR}/api_key.pem" \
    --from-literal=fingerprint="${OCI_FINGERPRINT}" \
    --dry-run=client -o yaml | kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} apply -f -
echo "K8s secret created: ${K8S_SECRET_NAME} in ${K8S_NAMESPACE}"

# --- Summary ---
echo ""
echo "=== Setup complete for ${CLUSTER} ==="
echo ""
echo "Resources created:"
echo "  OCI User:              ${OCI_USER_NAME} (${OCI_USER_OCID})"
echo "  OCI Policy:            ${POLICY_NAME} (reads infra-* secrets)"
echo "  K8s Secret:            ${K8S_SECRET_NAME} in ${K8S_NAMESPACE}"
echo ""

# --- Step 5: Update bootstrap values ---
echo "--- Step 5: Updating bootstrap configuration ---"

# Get the git root directory (script is in scripts/, go up one level)
GIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP_VALUES="${GIT_ROOT}/bootstrap/values/${CLUSTER}.yaml"

# Check for yq
if ! command -v yq &>/dev/null; then
    echo "WARNING: yq is not installed. Manual configuration required."
    echo ""
    echo "The oci-vault ClusterSecretStore is managed by the zem-external-secrets Helm chart."
    echo "Add the following to bootstrap/values/${CLUSTER}.yaml and run 'helmfile -e ${CLUSTER} apply':"
    echo ""
    echo "ociVault:"
    echo "  enabled: true"
    echo "  vault: ${OCI_VAULT_OCID}"
    echo "  compartment: ${OCI_COMPARTMENT_OCID}"
    echo "  region: uk-london-1"
    echo "  user: ${OCI_USER_OCID}"
    echo "  tenancy: ${OCI_TENANCY_OCID}"
    exit 0
fi

# Update bootstrap values file
if [ -f "${BOOTSTRAP_VALUES}" ]; then
    # Check if ociVault already exists
    if yq eval '.ociVault.enabled' "${BOOTSTRAP_VALUES}" 2>/dev/null | grep -q "true"; then
        echo "  OCI Vault already enabled in ${BOOTSTRAP_VALUES}, updating values"
    else
        echo "  Enabling OCI Vault in ${BOOTSTRAP_VALUES}"
    fi

    yq eval -i ".ociVault.enabled = true" "${BOOTSTRAP_VALUES}"
    yq eval -i ".ociVault.vault = \"${OCI_VAULT_OCID}\"" "${BOOTSTRAP_VALUES}"
    yq eval -i ".ociVault.compartment = \"${OCI_COMPARTMENT_OCID}\"" "${BOOTSTRAP_VALUES}"
    yq eval -i ".ociVault.region = \"uk-london-1\"" "${BOOTSTRAP_VALUES}"
    yq eval -i ".ociVault.user = \"${OCI_USER_OCID}\"" "${BOOTSTRAP_VALUES}"
    yq eval -i ".ociVault.tenancy = \"${OCI_TENANCY_OCID}\"" "${BOOTSTRAP_VALUES}"

    echo "  Updated ${BOOTSTRAP_VALUES}"
    echo ""
    echo "Configuration file updated. Run 'helmfile -e ${CLUSTER} apply' to deploy the ClusterSecretStore."
else
    echo "  WARNING: ${BOOTSTRAP_VALUES} not found"
    echo "  Add the following to bootstrap/values/${CLUSTER}.yaml:"
    echo ""
    echo "ociVault:"
    echo "  enabled: true"
    echo "  vault: ${OCI_VAULT_OCID}"
    echo "  compartment: ${OCI_COMPARTMENT_OCID}"
    echo "  region: uk-london-1"
    echo "  user: ${OCI_USER_OCID}"
    echo "  tenancy: ${OCI_TENANCY_OCID}"
fi
