#!/bin/bash
set -euo pipefail

# Migrate a project's OCI Vault secrets from {cluster}-{namespace}-* to {namespace}-*
#
# Old naming: secrets like cluster04-zenith-staging-cnpg, users like backup-cluster04-zenith-staging
# New naming: secrets like zenith-staging-cnpg, users like zenith-staging
#
# Run in two stages:
#
#   Stage 1 (default): Expand IAM access + copy secrets to new names
#     ./scripts/migrate-project-secrets.sh <cluster> <namespace>
#
#   Stage 2: Rotate OCI user to new name + delete old resources (run AFTER gitops is
#     updated and ArgoCD has synced successfully with new secret names)
#     ./scripts/migrate-project-secrets.sh --cleanup <cluster> <namespace>
#
# Dependencies: oci, jq
#
# Usage: ./scripts/migrate-project-secrets.sh [--cleanup] <cluster-name> <namespace>
# Example: ./scripts/migrate-project-secrets.sh cluster04 zenith-staging

CLEANUP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)
            CLEANUP=true
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
    echo "Usage: $0 [--cleanup] <cluster-name> <namespace>"
    echo "Example: $0 cluster04 zenith-staging"
    echo ""
    echo "  --cleanup  Stage 2: rotate OCI user to new name and delete old resources."
    echo "             Only run after gitops is updated and ArgoCD has synced successfully."
    exit 1
fi

CLUSTER="$1"
NAMESPACE="$2"
OLD_PREFIX="${CLUSTER}-${NAMESPACE}"
OLD_USER_NAME="backup-${OLD_PREFIX}"
OLD_POLICY_NAME="backup-${OLD_PREFIX}-secrets"
NEW_USER_NAME="${NAMESPACE}"
NEW_POLICY_NAME="${NAMESPACE}-secrets"

# OCI configuration
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
OCI_VAULT_KEY_OCID="${OCI_VAULT_KEY_OCID:-ocid1.key.oc1.uk-london-1.eruxsrmlaafja.abwgiljtncunmpibvwvjygia2d3umhb6vf24axjuxuivbg52moq76tgdhdua}"

echo "=== Migrating secrets: ${OLD_PREFIX}-* → ${NAMESPACE}-* ==="
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

# Helper: create or update an OCI Vault secret
store_vault_secret() {
    local secret_name="$1"
    local secret_b64="$2"

    local existing_ocid
    existing_ocid=$(oci vault secret list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --vault-id "${OCI_VAULT_OCID}" \
        --name "${secret_name}" \
        --all --output json 2>/dev/null | jq -r '.data[0].id // empty')

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

if [ "${CLEANUP}" = false ]; then
    # =========================================================
    # STAGE 1: Expand IAM policy + copy secrets to new names
    # =========================================================

    # --- Step 1: Expand old IAM policy to allow both old and new prefixes ---
    echo "--- Step 1: Expanding old IAM policy to allow both ${OLD_PREFIX}-* and ${NAMESPACE}-* ---"

    OLD_USER_OCID=$(oci iam user list --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.name == \"${OLD_USER_NAME}\") | .id")

    if [ -z "${OLD_USER_OCID}" ]; then
        echo "  WARNING: Old OCI user '${OLD_USER_NAME}' not found — skipping policy expansion"
    else
        OLD_POLICY_OCID=$(oci iam policy list \
            --compartment-id "${OCI_COMPARTMENT_OCID}" \
            --all --output json 2>/dev/null | \
            jq -r ".data[] | select(.name == \"${OLD_POLICY_NAME}\") | .id")

        if [ -z "${OLD_POLICY_OCID}" ]; then
            echo "  WARNING: Old IAM policy '${OLD_POLICY_NAME}' not found — skipping policy expansion"
        else
            EXPANDED_STATEMENTS="[
  \"Allow any-user to read secret-family in compartment id ${OCI_COMPARTMENT_OCID} where ALL {request.user.id = '${OLD_USER_OCID}', target.secret.name = /${OLD_PREFIX}-*/}\",
  \"Allow any-user to read secret-family in compartment id ${OCI_COMPARTMENT_OCID} where ALL {request.user.id = '${OLD_USER_OCID}', target.secret.name = /${NAMESPACE}-*/}\",
  \"Allow any-user to read vaults in compartment id ${OCI_COMPARTMENT_OCID} where request.user.id = '${OLD_USER_OCID}'\"
]"
            oci iam policy update \
                --policy-id "${OLD_POLICY_OCID}" \
                --statements "${EXPANDED_STATEMENTS}" \
                --version-date "" \
                --force \
                --output json >/dev/null
            echo "  Updated policy '${OLD_POLICY_NAME}' to allow both old and new prefixes"
        fi
    fi
    echo ""

    # --- Step 2: List all old secrets and copy to new names ---
    echo "--- Step 2: Copying secrets from ${OLD_PREFIX}-* to ${NAMESPACE}-* ---"

    OLD_SECRETS=$(oci vault secret list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --vault-id "${OCI_VAULT_OCID}" \
        --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.\"lifecycle-state\" == \"ACTIVE\") | select(((.\"secret-name\") // \"\") | startswith(\"${OLD_PREFIX}-\")) | .\"secret-name\"")

    if [ -z "${OLD_SECRETS}" ]; then
        echo "  No active secrets found matching ${OLD_PREFIX}-*"
    else
        for old_name in ${OLD_SECRETS}; do
            # Derive new name by stripping old prefix and prepending namespace
            suffix="${old_name#${OLD_PREFIX}-}"
            new_name="${NAMESPACE}-${suffix}"

            echo "  Copying: ${old_name} → ${new_name}"

            # Read old secret content
            old_ocid=$(oci vault secret list \
                --compartment-id "${OCI_COMPARTMENT_OCID}" \
                --vault-id "${OCI_VAULT_OCID}" \
                --name "${old_name}" \
                --all --output json 2>/dev/null | jq -r '.data[0].id // empty')

            secret_b64=$(oci secrets secret-bundle get \
                --secret-id "${old_ocid}" \
                --output json 2>/dev/null | \
                jq -r '.data."secret-bundle-content".content')

            store_vault_secret "${new_name}" "${secret_b64}"
        done
    fi
    echo ""

    echo "=== Stage 1 complete ==="
    echo ""
    echo "Next steps:"
    echo "  1. Update gitops references from '${OLD_PREFIX}-*' to '${NAMESPACE}-*'"
    echo "     - Check clusters/*/projects/ for hardcoded secret names"
    echo "     - The b2.vaultSecretName template is already updated"
    echo "  2. Commit and push changes"
    echo "  3. Wait for ArgoCD to sync and verify all ExternalSecrets show Ready"
    echo "  4. Run with --cleanup to rotate the OCI user and delete old resources:"
    echo "     $0 --cleanup ${CLUSTER} ${NAMESPACE}"

else
    # =========================================================
    # STAGE 2: Create new OCI user, rotate credentials, delete old
    # =========================================================
    echo "--- Stage 2: Rotating OCI user from '${OLD_USER_NAME}' to '${NEW_USER_NAME}' ---"
    echo ""
    echo "WARNING: This will delete the old OCI user '${OLD_USER_NAME}' and its IAM policy."
    echo "Ensure gitops is updated and ArgoCD has synced successfully before proceeding."
    echo ""
    read -r -p "Continue? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # --- Step 1: Create new OCI user ---
    echo "--- Step 1: Creating new OCI user '${NEW_USER_NAME}' ---"
    OCI_USER_EMAIL="${OCI_USER_EMAIL:-${NEW_USER_NAME}@zem.org.uk}"
    if NEW_USER_JSON=$(oci iam user create \
        --name "${NEW_USER_NAME}" \
        --email "${OCI_USER_EMAIL}" \
        --description "Vault credentials access for ${NAMESPACE}" \
        --output json 2>&1); then
        NEW_USER_OCID=$(echo "$NEW_USER_JSON" | jq -r '.data.id')
        echo "  Created user: ${NEW_USER_NAME}"
    else
        echo "  User '${NEW_USER_NAME}' already exists, looking up..."
        NEW_USER_OCID=$(oci iam user list --all --output json 2>/dev/null | \
            jq -r ".data[] | select(.name == \"${NEW_USER_NAME}\") | .id")
    fi

    if [ -z "${NEW_USER_OCID}" ]; then
        echo "ERROR: Could not create or find OCI user '${NEW_USER_NAME}'"
        exit 1
    fi
    echo "  User OCID: ${NEW_USER_OCID}"
    echo ""

    # --- Step 2: Generate new API key ---
    echo "--- Step 2: Generating API key for '${NEW_USER_NAME}' ---"

    # Remove any existing API keys on new user
    EXISTING_KEYS=$(oci iam user api-key list --user-id "${NEW_USER_OCID}" --output json | \
        jq -r '.data[].fingerprint')
    for fp in $EXISTING_KEYS; do
        echo "  Removing existing API key: ${fp}"
        oci iam user api-key delete --user-id "${NEW_USER_OCID}" --fingerprint "${fp}" --force
    done

    openssl genrsa -out "${TMPDIR}/api_key_pkcs8.pem" 2048 2>/dev/null
    openssl rsa -traditional -in "${TMPDIR}/api_key_pkcs8.pem" -out "${TMPDIR}/api_key.pem" 2>/dev/null
    openssl rsa -pubout -in "${TMPDIR}/api_key.pem" -out "${TMPDIR}/api_key_public.pem" 2>/dev/null

    API_KEY_RESULT=$(oci iam user api-key upload \
        --user-id "${NEW_USER_OCID}" \
        --key-file "${TMPDIR}/api_key_public.pem" \
        --output json)
    NEW_FINGERPRINT=$(echo "$API_KEY_RESULT" | jq -r '.data.fingerprint')
    NEW_TENANCY_OCID=$(oci iam user get --user-id "${NEW_USER_OCID}" --output json | \
        jq -r '.data."compartment-id"')
    echo "  Fingerprint: ${NEW_FINGERPRINT}"
    echo ""

    # --- Step 3: Create new IAM policy ---
    echo "--- Step 3: Creating IAM policy '${NEW_POLICY_NAME}' ---"
    NEW_POLICY_STATEMENTS="[\"Allow any-user to read secret-family in compartment id ${OCI_COMPARTMENT_OCID} where ALL {request.user.id = '${NEW_USER_OCID}', target.secret.name = /${NAMESPACE}-*/}\", \"Allow any-user to read vaults in compartment id ${OCI_COMPARTMENT_OCID} where request.user.id = '${NEW_USER_OCID}'\"]"

    EXISTING_NEW_POLICY_OCID=$(oci iam policy list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.name == \"${NEW_POLICY_NAME}\") | .id")

    if [ -n "${EXISTING_NEW_POLICY_OCID}" ]; then
        oci iam policy update \
            --policy-id "${EXISTING_NEW_POLICY_OCID}" \
            --statements "${NEW_POLICY_STATEMENTS}" \
            --version-date "" \
            --force \
            --output json >/dev/null
        echo "  Updated: ${NEW_POLICY_NAME}"
    else
        oci iam policy create \
            --compartment-id "${OCI_COMPARTMENT_OCID}" \
            --name "${NEW_POLICY_NAME}" \
            --description "Allow ${NEW_USER_NAME} to read vault secrets for ${NAMESPACE} and inspect vaults" \
            --statements "${NEW_POLICY_STATEMENTS}" \
            --output json >/dev/null
        echo "  Created: ${NEW_POLICY_NAME}"
    fi
    echo ""

    # --- Step 4: Rotate infra-{namespace}-oci-credentials ---
    echo "--- Step 4: Updating infra-${NAMESPACE}-oci-credentials with new user ---"
    OCI_PRIVATE_KEY=$(cat "${TMPDIR}/api_key.pem")
    INFRA_SECRET_JSON=$(jq -n \
        --arg pk "$OCI_PRIVATE_KEY" \
        --arg fp "$NEW_FINGERPRINT" \
        --arg uo "$NEW_USER_OCID" \
        '{privateKey: $pk, fingerprint: $fp, userOcid: $uo}')
    store_vault_secret "infra-${NAMESPACE}-oci-credentials" "$(echo -n "$INFRA_SECRET_JSON" | base64)"
    echo ""

    # --- Step 4b: Update userOcid in cluster project file ---
    GIT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
    PROJECT_NAME=$(echo "${NAMESPACE}" | sed -E 's/-(prod|dev|staging)$//')
    PROJECT_FILE="${GIT_ROOT}/clusters/${CLUSTER}/projects/${PROJECT_NAME}.yaml"
    # zenith-staging is a special case — project name strips -staging but file is zenith-staging.yaml
    if [ ! -f "${PROJECT_FILE}" ]; then
        PROJECT_FILE="${GIT_ROOT}/clusters/${CLUSTER}/projects/${NAMESPACE}.yaml"
    fi
    if [ -f "${PROJECT_FILE}" ] && command -v yq &>/dev/null; then
        yq eval -i ".spec.source.helm.valuesObject.common.values.ociVault.userOcid = \"${NEW_USER_OCID}\"" "${PROJECT_FILE}"
        echo "  Updated userOcid in ${PROJECT_FILE}"
    else
        echo "  WARNING: Could not update ${PROJECT_FILE} — update userOcid manually to ${NEW_USER_OCID}"
    fi
    echo ""

    # --- Step 5: Delete old user and policy ---
    echo "--- Step 5: Deleting old user '${OLD_USER_NAME}' and policy '${OLD_POLICY_NAME}' ---"

    OLD_USER_OCID=$(oci iam user list --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.name == \"${OLD_USER_NAME}\") | .id")

    if [ -n "${OLD_USER_OCID}" ]; then
        # Remove old user's API keys first
        OLD_KEYS=$(oci iam user api-key list --user-id "${OLD_USER_OCID}" --output json | \
            jq -r '.data[].fingerprint')
        for fp in $OLD_KEYS; do
            oci iam user api-key delete --user-id "${OLD_USER_OCID}" --fingerprint "${fp}" --force
        done
        oci iam user delete --user-id "${OLD_USER_OCID}" --force
        echo "  Deleted user: ${OLD_USER_NAME}"
    else
        echo "  User '${OLD_USER_NAME}' not found (already deleted?)"
    fi

    OLD_POLICY_OCID=$(oci iam policy list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.name == \"${OLD_POLICY_NAME}\") | .id")

    if [ -n "${OLD_POLICY_OCID}" ]; then
        oci iam policy delete --policy-id "${OLD_POLICY_OCID}" --force
        echo "  Deleted policy: ${OLD_POLICY_NAME}"
    else
        echo "  Policy '${OLD_POLICY_NAME}' not found (already deleted?)"
    fi
    echo ""

    # --- Step 6: Delete old vault secrets ---
    echo "--- Step 6: Scheduling deletion of old vault secrets (${OLD_PREFIX}-*) ---"
    echo "  Note: OCI Vault secrets are deleted with a minimum 1-day waiting period."

    OLD_SECRETS=$(oci vault secret list \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --vault-id "${OCI_VAULT_OCID}" \
        --all --output json 2>/dev/null | \
        jq -r ".data[] | select(.\"lifecycle-state\" == \"ACTIVE\") | select(((.\"secret-name\") // \"\") | startswith(\"${OLD_PREFIX}-\")) | .id" 2>/dev/null)

    if [ -z "${OLD_SECRETS}" ]; then
        echo "  No active secrets found matching ${OLD_PREFIX}-*"
    else
        for secret_ocid in ${OLD_SECRETS}; do
            secret_name=$(oci vault secret get --secret-id "${secret_ocid}" --output json 2>/dev/null | \
                jq -r '.data."secret-name"')
            oci vault secret schedule-secret-deletion \
                --secret-id "${secret_ocid}" \
                --time-of-deletion "$(date -v+1d -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
                --output json >/dev/null 2>/dev/null || \
            oci vault secret schedule-secret-deletion \
                --secret-id "${secret_ocid}" \
                --output json >/dev/null
            echo "  Scheduled for deletion: ${secret_name}"
        done
    fi
    echo ""

    echo "=== Stage 2 complete ==="
    echo ""
    echo "Resources migrated:"
    echo "  New OCI User:   ${NEW_USER_NAME} (${NEW_USER_OCID})"
    echo "  New IAM Policy: ${NEW_POLICY_NAME}"
    echo "  Updated Vault:  infra-${NAMESPACE}-oci-credentials"
    echo ""
    echo "ESO will pick up the new credentials on next refresh (within 1h)."
    echo "Verify with: kubectl get secretstore oci-vault -n ${NAMESPACE}"
fi
