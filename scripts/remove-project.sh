#!/bin/bash
set -euo pipefail

# Remove a project namespace from a cluster, cleaning up all associated resources.
# Mirrors create-project.sh — run this when decommissioning or migrating a project.
#
# Removes:
# 1. OCI Vault secrets matching <cluster>-<namespace>-*
# 2. B2 application key backup-<cluster>-<namespace>
# 3. OCI IAM policy backup-<cluster>-<namespace>-secrets
# 4. OCI user backup-<cluster>-<namespace> (and their API keys)
# 5. projects/<project>/envs/<cluster>/<env>.yaml
# 6. clusters/<cluster>/infra.yaml project-credentials namespace entry
#
# Optionally migrates secrets to a new cluster before deleting:
#   --migrate-secrets-to <cluster>  Copy <old>-<ns>-* secrets to <new>-<ns>-* (skip if target exists)
#
# Usage: ./scripts/remove-project.sh [--migrate-secrets-to <cluster>] [--dry-run] <cluster> <namespace>
# Example: ./scripts/remove-project.sh cluster04 zenith-staging
#
# Dependencies: oci, b2, jq, yq

MIGRATE_TO=""
DRY_RUN=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --migrate-secrets-to)
            MIGRATE_TO="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ $# -ne 2 ]; then
    echo "Usage: $0 [--migrate-secrets-to <cluster>] [--dry-run] <cluster-name> <namespace>"
    echo "Example: $0 --migrate-secrets-to cluster04 cluster02 zenith-staging"
    exit 1
fi

CLUSTER="$1"
NAMESPACE="$2"
PREFIX="${CLUSTER}-${NAMESPACE}"

# OCI configuration
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
OCI_VAULT_KEY_OCID="${OCI_VAULT_KEY_OCID:-ocid1.key.oc1.uk-london-1.eruxsrmlaafja.abwgiljtncunmpibvwvjygia2d3umhb6vf24axjuxuivbg52moq76tgdhdua}"

run() {
    if [ "${DRY_RUN}" = true ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

echo "=== Removing project ${PREFIX} ==="
[ "${DRY_RUN}" = true ] && echo "  (dry-run mode — no changes will be made)"
echo ""

# Check dependencies
for cmd in oci b2 jq yq; do
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

# --- Step 1: Discover cluster-scoped vault secrets ---
echo "--- Step 1: Discovering OCI Vault secrets for ${PREFIX} ---"
SECRETS_JSON=$(oci vault secret list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vault-id "${OCI_VAULT_OCID}" \
    --all --output json 2>/dev/null)

MATCHING_SECRETS=$(echo "${SECRETS_JSON}" | jq -r --arg prefix "${PREFIX}-" \
    '.data[] | select(.["lifecycle-state"] != "PENDING_DELETION") | select(.["secret-name"] | startswith($prefix)) | "\(.id) \(.["secret-name"])"')

if [ -z "${MATCHING_SECRETS}" ]; then
    echo "  No active vault secrets found matching ${PREFIX}-*"
else
    echo "  Found:"
    echo "${MATCHING_SECRETS}" | while read -r ocid name; do
        echo "    ${name}"
    done
fi
echo ""

# --- Step 2: Migrate secrets to new cluster (if requested) ---
if [ -n "${MIGRATE_TO}" ]; then
    NEW_PREFIX="${MIGRATE_TO}-${NAMESPACE}"
    echo "--- Step 2: Migrating ${PREFIX}-* → ${NEW_PREFIX}-* ---"

    if [ -z "${MATCHING_SECRETS}" ]; then
        echo "  No secrets to migrate."
    else
        while IFS=' ' read -r secret_ocid secret_name; do
            # Extract suffix: strip "<cluster>-<namespace>-" prefix
            SUFFIX="${secret_name#${PREFIX}-}"
            NEW_SECRET_NAME="${NEW_PREFIX}-${SUFFIX}"

            # Check if target already exists
            EXISTING=$(echo "${SECRETS_JSON}" | jq -r --arg name "${NEW_SECRET_NAME}" \
                '.data[] | select(.["lifecycle-state"] != "PENDING_DELETION") | select(.["secret-name"] == $name) | .id')

            if [ -n "${EXISTING}" ]; then
                echo "  Skipping ${secret_name} → ${NEW_SECRET_NAME} (target already exists)"
                continue
            fi

            echo "  Migrating ${secret_name} → ${NEW_SECRET_NAME}"
            SECRET_CONTENT=$(oci secrets secret-bundle get \
                --secret-id "${secret_ocid}" \
                --output json 2>/dev/null | jq -r '.data."secret-bundle-content".content')

            if [ "${DRY_RUN}" = false ]; then
                oci vault secret create-base64 \
                    --compartment-id "${OCI_COMPARTMENT_OCID}" \
                    --vault-id "${OCI_VAULT_OCID}" \
                    --key-id "${OCI_VAULT_KEY_OCID}" \
                    --secret-name "${NEW_SECRET_NAME}" \
                    --secret-content-content "${SECRET_CONTENT}" \
                    --output json >/dev/null
                echo "    Created: ${NEW_SECRET_NAME}"
            else
                echo "  [dry-run] Would create: ${NEW_SECRET_NAME}"
            fi
        done <<< "${MATCHING_SECRETS}"
    fi
    echo ""
fi

# --- Step 3: Get B2 key ID before deleting vault secrets ---
echo "--- Step 3: Looking up B2 key ---"
BACKUPS_SECRET_OCID=$(echo "${SECRETS_JSON}" | jq -r --arg name "${PREFIX}-backups" \
    '.data[] | select(.["lifecycle-state"] != "PENDING_DELETION") | select(.["secret-name"] == $name) | .id')
B2_KEY_ID=""

if [ -n "${BACKUPS_SECRET_OCID}" ]; then
    B2_KEY_ID=$(oci secrets secret-bundle get \
        --secret-id "${BACKUPS_SECRET_OCID}" \
        --output json 2>/dev/null | jq -r '.data."secret-bundle-content".content' | base64 -d | jq -r '.ACCESS_KEY_ID // empty')
    if [ -n "${B2_KEY_ID}" ]; then
        echo "  B2 key ID: ${B2_KEY_ID}"
    else
        echo "  Could not extract B2 key ID from vault secret"
    fi
else
    echo "  No ${PREFIX}-backups vault secret found"
fi
echo ""

# --- Step 4: Schedule vault secrets for deletion ---
echo "--- Step 4: Scheduling vault secrets for deletion ---"
# OCI Vault minimum deletion time is 24 hours
DELETION_TIME=$(date -u -v+1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')

if [ -z "${MATCHING_SECRETS}" ]; then
    echo "  Nothing to delete."
else
    while IFS=' ' read -r secret_ocid secret_name; do
        echo "  Scheduling deletion: ${secret_name}"
        run oci vault secret schedule-deletion \
            --secret-id "${secret_ocid}" \
            --time-of-deletion "${DELETION_TIME}" \
            --force \
            --output json >/dev/null
    done <<< "${MATCHING_SECRETS}"
fi
echo ""

# --- Step 5: Delete B2 key ---
echo "--- Step 5: Deleting B2 key backup-${PREFIX} ---"
B2_KEY_NAME="backup-${PREFIX}"
if [ -n "${B2_KEY_ID}" ]; then
    if b2 key list 2>/dev/null | awk '{print $1}' | grep -qx "${B2_KEY_ID}"; then
        echo "  Deleting B2 key: ${B2_KEY_ID}"
        run b2 key delete "${B2_KEY_ID}"
    else
        echo "  B2 key ${B2_KEY_ID} not found in B2 (may already be deleted)"
    fi
else
    # Try to find by name if we couldn't get the ID from vault
    FOUND_KEY=$(b2 key list 2>/dev/null | grep "${B2_KEY_NAME}" | awk '{print $1}' || true)
    if [ -n "${FOUND_KEY}" ]; then
        echo "  Found B2 key by name: ${FOUND_KEY}"
        run b2 key delete "${FOUND_KEY}"
    else
        echo "  No B2 key found for ${B2_KEY_NAME}"
    fi
fi
echo ""

# --- Step 6: Delete OCI IAM policy ---
echo "--- Step 6: Deleting OCI IAM policy ---"
POLICY_NAME="backup-${PREFIX}-secrets"
POLICY_OCID=$(oci iam policy list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --all --output json 2>/dev/null | jq -r --arg name "${POLICY_NAME}" \
    '.data[] | select(.name == $name) | .id')

if [ -n "${POLICY_OCID}" ]; then
    echo "  Deleting policy: ${POLICY_NAME}"
    run oci iam policy delete --policy-id "${POLICY_OCID}" --force
else
    echo "  Policy ${POLICY_NAME} not found (already deleted or never created)"
fi
echo ""

# --- Step 7: Delete OCI user ---
echo "--- Step 7: Deleting OCI user ---"
OCI_USER_NAME="backup-${PREFIX}"
OCI_USER_OCID=$(oci iam user list --all --output json 2>/dev/null | jq -r --arg name "${OCI_USER_NAME}" \
    '.data[] | select(.name == $name) | .id')

if [ -n "${OCI_USER_OCID}" ]; then
    # Delete all API keys first
    API_KEYS=$(oci iam user api-key list --user-id "${OCI_USER_OCID}" --output json 2>/dev/null | \
        jq -r '.data[].fingerprint')
    for fp in ${API_KEYS}; do
        echo "  Deleting API key: ${fp}"
        run oci iam user api-key delete --user-id "${OCI_USER_OCID}" --fingerprint "${fp}" --force
    done
    echo "  Deleting user: ${OCI_USER_NAME}"
    run oci iam user delete --user-id "${OCI_USER_OCID}" --force
else
    echo "  User ${OCI_USER_NAME} not found (already deleted or never created)"
fi
echo ""

# --- Step 8: Update git configuration ---
echo "--- Step 8: Updating git configuration ---"
GIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INFRA_FILE="${GIT_ROOT}/clusters/${CLUSTER}/infra.yaml"

# Derive project name and env from namespace
PROJECT_NAME=$(echo "${NAMESPACE}" | sed -E 's/-(prod|dev|staging)$//')
ENV=$(echo "${NAMESPACE}" | sed -E 's/^.*-(prod|dev|staging)$/\1/')
ENV_FILE="${GIT_ROOT}/projects/${PROJECT_NAME}/envs/${CLUSTER}/${ENV}.yaml"

# Remove from project-credentials namespaces
if [ -f "${INFRA_FILE}" ]; then
    if yq eval ".spec.source.helm.valuesObject.features.\"project-credentials\".values.namespaces[] | select(.name == \"${NAMESPACE}\")" "${INFRA_FILE}" 2>/dev/null | grep -q "name:"; then
        echo "  Removing ${NAMESPACE} from project-credentials in ${INFRA_FILE}"
        run yq eval -i "del(.spec.source.helm.valuesObject.features.\"project-credentials\".values.namespaces[] | select(.name == \"${NAMESPACE}\"))" "${INFRA_FILE}"
    else
        echo "  ${NAMESPACE} not found in project-credentials (already removed or never added)"
    fi
else
    echo "  WARNING: ${INFRA_FILE} not found"
fi

# Remove env file
if [ -f "${ENV_FILE}" ]; then
    echo "  Removing ${ENV_FILE}"
    run rm "${ENV_FILE}"
    # Remove empty parent dirs
    rmdir --ignore-fail-on-non-empty "${GIT_ROOT}/projects/${PROJECT_NAME}/envs/${CLUSTER}" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "${GIT_ROOT}/projects/${PROJECT_NAME}/envs" 2>/dev/null || true
else
    echo "  No env file found at ${ENV_FILE} (already removed or never created)"
fi
echo ""

echo "=== Removal complete ==="
echo ""
echo "Note: OCI Vault secrets are scheduled for deletion in 24h (OCI minimum)."
if [ -n "${MIGRATE_TO}" ]; then
    echo "Note: Secrets were migrated to ${MIGRATE_TO}-${NAMESPACE}-* (skipping any that already existed)."
fi
echo ""
echo "Manual steps may still be required:"
echo "  - Remove any infra feature references to ${NAMESPACE} in ${INFRA_FILE}"
echo "    (e.g. registry-auth.extraDestinationNamespaces, registry-auth.values.namespaces)"
echo "  - Commit and push changes to git"
echo "  - Delete the ArgoCD Application and namespace from ${CLUSTER} once traffic is migrated"
