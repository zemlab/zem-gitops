#!/bin/bash
set -euo pipefail

# Onboard a new project namespace with backup credentials
#
# Creates:
# 1. OCI user + API key (scoped to this namespace's vault secrets)
# 2. OCI IAM policy restricting user to specific secrets
# 3. B2 application key scoped to <cluster>/<namespace>/ prefix
# 4. Random restic password
# 5. Stores B2 creds + restic password in OCI Vault (for the namespace's SecretStore)
# 6. Stores OCI API key in OCI Vault (for the infra ClusterSecretStore to distribute)
#
# After running, add the following to git:
#   1. Add namespace to backup-credentials in clusters/<cluster>/infra.yaml
#   2. Add ociVault + backups config to clusters/<cluster>/projects/<project>.yaml
# See the script output for exact YAML snippets.
#
# Dependencies: oci, b2, jq, openssl
#
# Usage: ./scripts/create-project.sh <cluster-name> <namespace>
# Example: ./scripts/create-project.sh cluster03 pce-prod

if [ $# -ne 2 ]; then
    echo "Usage: $0 <cluster-name> <namespace>"
    echo "Example: $0 cluster03 pce-prod"
    exit 1
fi

CLUSTER="$1"
NAMESPACE="$2"
PREFIX="${CLUSTER}-${NAMESPACE}"

# OCI configuration
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
OCI_VAULT_KEY_OCID="${OCI_VAULT_KEY_OCID:-ocid1.key.oc1.uk-london-1.eruxsrmlaafja.abwgiljtncunmpibvwvjygia2d3umhb6vf24axjuxuivbg52moq76tgdhdua}"

# B2 configuration
B2_BUCKET="zem-backups-eu"
B2_KEY_NAME="backup-${PREFIX}"

echo "=== Provisioning backup credentials for ${PREFIX} ==="
echo ""

# Check dependencies
for cmd in oci b2 jq openssl; do
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

# Helper: create or update an OCI Vault secret
store_vault_secret() {
    local secret_name="$1"
    local secret_b64="$2"

    local existing_ocid
    existing_ocid=$(oci vault secret list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --vault-id "${OCI_VAULT_OCID}" \
        --name "${secret_name}" \
        --output json 2>/dev/null | jq -r '.data[0].id // empty')

    if [ -n "${existing_ocid}" ]; then
        oci vault secret update-base64 \
            --secret-id "${existing_ocid}" \
            --secret-content-content "${secret_b64}" \
            --output json >/dev/null
        echo "  Updated: ${secret_name}"
    else
        oci vault secret create-base64 \
            --compartment-id "${OCI_COMPARTMENT_OCID}" \
            --vault-id "${OCI_VAULT_OCID}" \
            --key-id "${OCI_VAULT_KEY_OCID}" \
            --secret-name "${secret_name}" \
            --secret-content-content "${secret_b64}" \
            --output json >/dev/null
        echo "  Created: ${secret_name}"
    fi
}

# --- Step 1: Create OCI user ---
echo "--- Step 1: Creating OCI user ---"
OCI_USER_NAME="backup-${PREFIX}"
OCI_USER_EMAIL="${OCI_USER_EMAIL:-${OCI_USER_NAME}@zem.org.uk}"
if OCI_USER=$(oci iam user create \
    --name "${OCI_USER_NAME}" \
    --email "${OCI_USER_EMAIL}" \
    --description "Backup credentials access for ${NAMESPACE} on ${CLUSTER}" \
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

# --- Step 2: Generate and upload OCI API key ---
echo "--- Step 2: Generating OCI API key ---"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Remove any existing API keys (previous interrupted runs leave orphaned keys)
EXISTING_KEYS=$(oci iam user api-key list --user-id "${OCI_USER_OCID}" --output json | jq -r '.data[].fingerprint')
for fp in $EXISTING_KEYS; do
    echo "  Removing existing API key: ${fp}"
    oci iam user api-key delete --user-id "${OCI_USER_OCID}" --fingerprint "${fp}" --force
done

openssl genrsa -out "${TMPDIR}/api_key.pem" 2048 2>/dev/null
openssl rsa -pubout -in "${TMPDIR}/api_key.pem" -out "${TMPDIR}/api_key_public.pem" 2>/dev/null

API_KEY_RESULT=$(oci iam user api-key upload \
    --user-id "${OCI_USER_OCID}" \
    --key-file "${TMPDIR}/api_key_public.pem" \
    --output json)
OCI_FINGERPRINT=$(echo "$API_KEY_RESULT" | jq -r '.data.fingerprint')
OCI_TENANCY_OCID=$(oci iam user get --user-id "${OCI_USER_OCID}" --output json | jq -r '.data."compartment-id"')
echo "API Key Fingerprint: ${OCI_FINGERPRINT}"

# --- Step 3: Create OCI IAM policy ---
echo "--- Step 3: Creating OCI IAM policy ---"
POLICY_NAME="backup-${PREFIX}-secrets"
POLICY_STATEMENTS="[\"Allow any-user to read secret-family in compartment id ${OCI_COMPARTMENT_OCID} where ALL {request.user.id = '${OCI_USER_OCID}', target.secret.name = '${PREFIX}'}\", \"Allow any-user to read vaults in compartment id ${OCI_COMPARTMENT_OCID} where request.user.id = '${OCI_USER_OCID}'\"]"

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
        --description "Allow ${OCI_USER_NAME} to read backup secrets for ${PREFIX} and inspect vaults" \
        --statements "${POLICY_STATEMENTS}" \
        --output json >/dev/null
    echo "Policy created: ${POLICY_NAME}"
fi

# --- Step 4: B2 credentials + restic password (idempotent) ---
echo "--- Step 4: Provisioning B2 credentials and restic password ---"
BACKUP_SECRET_NAME="${PREFIX}"
B2_KEY_ID=""
B2_KEY_SECRET=""
RESTIC_PASSWORD=""
B2_CREDS_VALID=false

# Check if backup credentials already exist in OCI Vault
EXISTING_BACKUP_OCID=$(oci vault secret list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vault-id "${OCI_VAULT_OCID}" \
    --name "${BACKUP_SECRET_NAME}" \
    --output json 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "${EXISTING_BACKUP_OCID}" ]; then
    echo "  Found existing vault secret: ${BACKUP_SECRET_NAME}"
    EXISTING_BACKUP_JSON=$(oci secrets secret-bundle get \
        --secret-id "${EXISTING_BACKUP_OCID}" \
        --output json 2>/dev/null | jq -r '.data."secret-bundle-content".content' | base64 -d)
    EXISTING_B2_KEY_ID=$(echo "$EXISTING_BACKUP_JSON" | jq -r '.ACCESS_KEY_ID // empty')
    EXISTING_B2_KEY_SECRET=$(echo "$EXISTING_BACKUP_JSON" | jq -r '.SECRET_ACCESS_KEY // empty')
    RESTIC_PASSWORD=$(echo "$EXISTING_BACKUP_JSON" | jq -r '.RESTIC_PASSWORD // empty')
    echo "  Preserved existing restic password from vault"

    # Validate B2 credentials by trying to list files
    if [ -n "${EXISTING_B2_KEY_ID}" ] && [ -n "${EXISTING_B2_KEY_SECRET}" ]; then
        echo "  Testing existing B2 credentials (key: ${EXISTING_B2_KEY_ID})..."
        if B2_APPLICATION_KEY_ID="${EXISTING_B2_KEY_ID}" B2_APPLICATION_KEY="${EXISTING_B2_KEY_SECRET}" \
            b2 ls --recursive --limit 1 "${B2_BUCKET}" "${CLUSTER}/${NAMESPACE}/" >/dev/null 2>&1; then
            echo "  B2 credentials are valid, reusing"
            B2_KEY_ID="${EXISTING_B2_KEY_ID}"
            B2_KEY_SECRET="${EXISTING_B2_KEY_SECRET}"
            B2_CREDS_VALID=true
        else
            echo "  B2 credentials are invalid, will create new key"
            # Clean up the dead key from B2 if it still exists
            if b2 key list 2>/dev/null | awk '{print $1}' | grep -qx "${EXISTING_B2_KEY_ID}"; then
                echo "  Deleting stale B2 key: ${EXISTING_B2_KEY_ID}"
                b2 key delete "${EXISTING_B2_KEY_ID}"
            fi
        fi
    fi
else
    echo "  No existing vault secret found, will create everything fresh"
fi

# Generate restic password if we don't have one from the vault
if [ -z "${RESTIC_PASSWORD}" ]; then
    RESTIC_PASSWORD=$(openssl rand -base64 32)
    echo "  Generated new restic password"
fi

# Create new B2 key if existing creds were invalid or missing
if [ "${B2_CREDS_VALID}" = false ]; then
    # Clean up any orphaned B2 keys with the same name
    ORPHANED_KEYS=$(b2 key list 2>/dev/null | grep "${B2_KEY_NAME}" | awk '{print $1}' || true)
    for key_id in $ORPHANED_KEYS; do
        echo "  Deleting orphaned B2 key: ${key_id}"
        b2 key delete "${key_id}"
    done

    B2_KEY_RESULT=$(b2 key create \
        --bucket "${B2_BUCKET}" \
        --name-prefix "${CLUSTER}/${NAMESPACE}/" \
        "${B2_KEY_NAME}" \
        "listBuckets,listFiles,readFiles,writeFiles,deleteFiles" 2>&1)
    B2_KEY_ID=$(echo "$B2_KEY_RESULT" | awk '{print $1}')
    B2_KEY_SECRET=$(echo "$B2_KEY_RESULT" | awk '{print $2}')
    echo "  Created new B2 key: ${B2_KEY_NAME}"
fi

# Store/update backup credentials in OCI Vault
echo "  Storing backup credentials in OCI Vault..."
BACKUP_SECRET_JSON=$(jq -n \
    --arg ak "$B2_KEY_ID" \
    --arg sk "$B2_KEY_SECRET" \
    --arg rp "$RESTIC_PASSWORD" \
    '{ACCESS_KEY_ID: $ak, SECRET_ACCESS_KEY: $sk, RESTIC_PASSWORD: $rp}')
store_vault_secret "${BACKUP_SECRET_NAME}" "$(echo -n "$BACKUP_SECRET_JSON" | base64)"

# --- Step 7: Store OCI API key in OCI Vault (for infra ClusterSecretStore distribution) ---
echo "--- Step 7: Storing OCI API key in OCI Vault ---"
INFRA_SECRET_NAME="infra-${NAMESPACE}-oci-credentials"
OCI_PRIVATE_KEY=$(cat "${TMPDIR}/api_key.pem")
INFRA_SECRET_JSON=$(jq -n \
    --arg pk "$OCI_PRIVATE_KEY" \
    --arg fp "$OCI_FINGERPRINT" \
    --arg uo "$OCI_USER_OCID" \
    '{privateKey: $pk, fingerprint: $fp, userOcid: $uo}')
store_vault_secret "${INFRA_SECRET_NAME}" "$(echo -n "$INFRA_SECRET_JSON" | base64)"

# --- Summary ---
echo ""
echo "=== Provisioning complete ==="
echo ""
echo "Resources created:"
echo "  OCI User:       ${OCI_USER_NAME} (${OCI_USER_OCID})"
echo "  OCI Policy:     ${POLICY_NAME}"
echo "  B2 Key:         ${B2_KEY_NAME} (prefix: ${CLUSTER}/${NAMESPACE}/, reused: ${B2_CREDS_VALID})"
echo "  Vault Secrets:"
echo "    ${BACKUP_SECRET_NAME} (B2 creds + restic password)"
echo "    ${INFRA_SECRET_NAME} (OCI API key for K8s distribution)"
echo ""

# --- Step 8: Update git configuration files ---
echo "--- Step 8: Updating git configuration ---"

# Get the git root directory
GIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INFRA_FILE="${GIT_ROOT}/clusters/${CLUSTER}/infra.yaml"

# Check for yq
if ! command -v yq &>/dev/null; then
    echo "WARNING: yq is not installed. Manual configuration required."
    echo ""
    echo "Add to backup-credentials values in ${INFRA_FILE}:"
    echo ""
    echo "          backup-credentials:"
    echo "            enabled: true"
    echo "            values:"
    echo "              namespaces:"
    echo "                - name: ${NAMESPACE}"
    echo "                  vaultSecretName: ${INFRA_SECRET_NAME}"
    echo "                  targetNamespace: ${NAMESPACE}"
    exit 0
fi

# Update infra.yaml with backup-credentials namespace
if [ -f "${INFRA_FILE}" ]; then
    # Check if namespace already exists
    if yq eval ".spec.source.helm.valuesObject.features.\"backup-credentials\".values.namespaces[] | select(.name == \"${NAMESPACE}\")" "${INFRA_FILE}" | grep -q "name:"; then
        echo "  Namespace ${NAMESPACE} already exists in backup-credentials config, skipping"
    else
        # Add namespace to backup-credentials
        yq eval -i ".spec.source.helm.valuesObject.features.\"backup-credentials\".values.namespaces += [{\"name\": \"${NAMESPACE}\", \"vaultSecretName\": \"${INFRA_SECRET_NAME}\", \"targetNamespace\": \"${NAMESPACE}\"}]" "${INFRA_FILE}"
        echo "  Updated ${INFRA_FILE}"
    fi
else
    echo "  WARNING: ${INFRA_FILE} not found, skipping"
fi

# Find project file
PROJECT_FILE=$(find "${GIT_ROOT}/clusters/${CLUSTER}/projects" -name "*.yaml" -type f 2>/dev/null | while read -r file; do
    if yq eval '.spec.destination.namespace' "$file" 2>/dev/null | grep -q "${NAMESPACE}"; then
        echo "$file"
        break
    fi
done)

if [ -n "${PROJECT_FILE}" ]; then
    echo "  Found project file: ${PROJECT_FILE}"

    # Update ociVault configuration
    yq eval -i ".spec.source.helm.valuesObject.ociVault.vaultOcid = \"${OCI_VAULT_OCID}\"" "${PROJECT_FILE}"
    yq eval -i ".spec.source.helm.valuesObject.ociVault.compartmentOcid = \"${OCI_COMPARTMENT_OCID}\"" "${PROJECT_FILE}"
    yq eval -i ".spec.source.helm.valuesObject.ociVault.region = \"uk-london-1\"" "${PROJECT_FILE}"
    yq eval -i ".spec.source.helm.valuesObject.ociVault.tenancyOcid = \"${OCI_TENANCY_OCID}\"" "${PROJECT_FILE}"

    # Update backups configuration
    yq eval -i ".spec.source.helm.valuesObject.backups.ociUserOcid = \"${OCI_USER_OCID}\"" "${PROJECT_FILE}"
    yq eval -i ".spec.source.helm.valuesObject.backups.ociCredentialSecret = \"${NAMESPACE}-oci-creds\"" "${PROJECT_FILE}"

    echo "  Updated ${PROJECT_FILE}"
else
    echo "  WARNING: No project file found for namespace ${NAMESPACE}"
    echo "  Add the following to your project config in clusters/${CLUSTER}/projects/<project>.yaml:"
    echo ""
    echo "        ociVault:"
    echo "          vaultOcid: \"${OCI_VAULT_OCID}\""
    echo "          compartmentOcid: \"${OCI_COMPARTMENT_OCID}\""
    echo "          region: \"uk-london-1\""
    echo "          tenancyOcid: \"${OCI_TENANCY_OCID}\""
    echo "        backups:"
    echo "          ociUserOcid: \"${OCI_USER_OCID}\""
    echo "          ociCredentialSecret: \"${NAMESPACE}-oci-creds\""
fi

echo ""
echo "Configuration files updated. Review the changes and commit to git."
