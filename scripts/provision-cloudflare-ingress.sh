#!/bin/bash
set -euo pipefail

# Provision OCI Vault secret for cloudflare-tunnel-ingress-controller
#
# Stores Cloudflare credentials as a JSON secret in OCI Vault under the name
# infra-cloudflare-ingress-<cluster>. The oci-vault ClusterSecretStore already
# has IAM read access to all infra-* secrets, so no IAM changes are needed.
#
# The secret contains: apiToken, accountId, tunnelName
#
# Dependencies: oci, jq
#
# Usage: ./scripts/provision-cloudflare-ingress.sh <cluster>
# Example: ./scripts/provision-cloudflare-ingress.sh cluster04
#
# Env vars (will be prompted if not set):
#   CLOUDFLARE_API_TOKEN  - Cloudflare API token (Zone:DNS:Edit, Zone:Zone:Read, Account:Cloudflare Tunnel:Edit)
#   CLOUDFLARE_ACCOUNT_ID - Cloudflare account ID
#   CLOUDFLARE_TUNNEL_NAME - Tunnel name (defaults to cluster name)

if [ $# -ne 1 ]; then
    echo "Usage: $0 <cluster-name>"
    echo "Example: $0 cluster04"
    exit 1
fi

CLUSTER="$1"
SECRET_NAME="infra-cloudflare-ingress-${CLUSTER}"

OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
OCI_VAULT_KEY_OCID="${OCI_VAULT_KEY_OCID:-ocid1.key.oc1.uk-london-1.eruxsrmlaafja.abwgiljtncunmpibvwvjygia2d3umhb6vf24axjuxuivbg52moq76tgdhdua}"

echo "=== Provisioning Cloudflare ingress credentials for ${CLUSTER} ==="
echo ""

# Check dependencies
for cmd in oci jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# Verify OCI auth
echo "--- Preflight: checking OCI authentication ---"
if ! oci iam region list --output json </dev/null >/dev/null 2>&1; then
    echo "ERROR: OCI authentication failed. If using security_token auth, run: oci session refresh"
    exit 1
fi
echo "OCI auth OK"
echo ""

# Collect credentials
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "--- Cloudflare API token ---"
    echo "Create at: https://dash.cloudflare.com/profile/api-tokens"
    echo "Required permissions:"
    echo "  Zone / Zone         / Read"
    echo "  Zone / DNS          / Edit"
    echo "  Account / Cloudflare Tunnel / Edit"
    echo ""
    read -rsp "Cloudflare API token: " CLOUDFLARE_API_TOKEN
    echo ""
fi

if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    echo ""
    echo "--- Cloudflare account ID ---"
    echo "Find at: https://dash.cloudflare.com -> any domain -> right sidebar"
    echo ""
    read -rp "Cloudflare account ID: " CLOUDFLARE_ACCOUNT_ID
    echo ""
fi

CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-${CLUSTER}}"
echo "Tunnel name: ${CLOUDFLARE_TUNNEL_NAME}"
echo ""

# Build JSON payload and base64-encode it
SECRET_JSON=$(jq -n \
    --arg apiToken "${CLOUDFLARE_API_TOKEN}" \
    --arg accountId "${CLOUDFLARE_ACCOUNT_ID}" \
    --arg tunnelName "${CLOUDFLARE_TUNNEL_NAME}" \
    '{"apiToken": $apiToken, "accountId": $accountId, "tunnelName": $tunnelName}')

SECRET_B64=$(echo "${SECRET_JSON}" | base64)

# Create or update the OCI Vault secret
echo "--- Storing secret: ${SECRET_NAME} ---"

EXISTING_OCID=$(oci vault secret list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vault-id "${OCI_VAULT_OCID}" \
    --name "${SECRET_NAME}" \
    --output json 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "${EXISTING_OCID}" ]; then
    oci vault secret update-base64 \
        --secret-id "${EXISTING_OCID}" \
        --secret-content-content "${SECRET_B64}" \
        --output json >/dev/null
    echo "Updated: ${SECRET_NAME}"
else
    oci vault secret create-base64 \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --vault-id "${OCI_VAULT_OCID}" \
        --key-id "${OCI_VAULT_KEY_OCID}" \
        --secret-name "${SECRET_NAME}" \
        --secret-content-content "${SECRET_B64}" \
        --output json >/dev/null
    echo "Created: ${SECRET_NAME}"
fi

echo ""
echo "=== Done ==="
echo ""
echo "Secret stored: ${SECRET_NAME}"
echo "Fields: apiToken, accountId, tunnelName=${CLOUDFLARE_TUNNEL_NAME}"
echo ""
echo "Ensure clusters/<cluster>/infra.yaml enables cloudflare-ingress with:"
echo "  cloudflare-ingress:"
echo "    enabled: true"
echo "    values:"
echo "      externalSecret:"
echo "        remoteRefKey: ${SECRET_NAME}"
