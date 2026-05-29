#!/bin/bash
set -euo pipefail

# Provision B2 backup credentials for Longhorn and store them in Bitwarden SM.
#
# Creates a B2 application key scoped to the longhorn-<cluster>/ prefix and
# stores the key ID and secret as individual Bitwarden SM secrets consumed by
# the zem-infra ClusterSecretStore ExternalSecret in apps/infra/zem-longhorn/.
#
# Idempotent: if secrets exist in Bitwarden and the B2 key is still valid, reuses
# them. Use --replace to force rotation (deletes old B2 key, creates new one).
#
# Dependencies: b2, bws, jq
#
# Required env vars:
#   BWS_ACCESS_TOKEN   - Bitwarden Secrets Manager machine account token (write access)
#
# Usage: ./scripts/create-longhorn-backup-credentials.sh [--replace] <cluster-name>
# Example: ./scripts/create-longhorn-backup-credentials.sh cluster04

REPLACE=false
if [ "${1:-}" = "--replace" ]; then
    REPLACE=true
    shift
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 [--replace] <cluster-name>"
    echo "Example: $0 cluster04"
    exit 1
fi

CLUSTER="$1"

B2_BUCKET="zem-backups-eu"
B2_KEY_NAME="longhorn-backup-${CLUSTER}"
B2_PREFIX="longhorn-${CLUSTER}/"
BW_PROJECT_ID="93356527-3980-4fb1-ab38-b2b101650812"
BW_SECRET_KEY_ID="longhorn-backup-${CLUSTER}-access-key-id"
BW_SECRET_SECRET_KEY="longhorn-backup-${CLUSTER}-secret-access-key"

echo "=== Provisioning Longhorn backup credentials for ${CLUSTER} ==="
echo ""

# Check dependencies
for cmd in b2 bws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# Check required env vars
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    echo "ERROR: BWS_ACCESS_TOKEN env var is required but not set"
    exit 1
fi

# Preflight: B2
echo "--- Preflight: checking B2 authentication ---"
if ! b2 account get >/dev/null 2>&1; then
    echo "ERROR: B2 authentication failed. Run: b2 authorize-account"
    exit 1
fi
echo "B2 auth OK"
echo ""

# Preflight: Bitwarden SM
echo "--- Preflight: checking Bitwarden SM authentication ---"
if ! bws secret list >/dev/null 2>&1; then
    echo "ERROR: Bitwarden SM authentication failed. Check BWS_ACCESS_TOKEN."
    exit 1
fi
echo "Bitwarden SM auth OK"
echo ""

# Helper: upsert a Bitwarden SM secret
bws_upsert() {
    local key="$1"
    local value="$2"
    local existing
    existing=$(bws secret list 2>/dev/null \
        | jq -r ".[] | select(.key == \"${key}\" and .projectId == \"${BW_PROJECT_ID}\") | .id" || true)
    if [ -n "$existing" ]; then
        bws secret edit "$existing" --value "$value" >/dev/null
        echo "  Updated: ${key}"
    else
        bws secret create "$key" "$value" "$BW_PROJECT_ID" >/dev/null
        echo "  Created: ${key}"
    fi
}

# --- Step 1: B2 credentials (idempotent) ---
echo "--- Step 1: Provisioning B2 application key ---"
B2_KEY_ID=""
B2_KEY_SECRET=""
B2_CREDS_VALID=false

# Check if credentials already exist in Bitwarden SM
EXISTING_KEY_ID=$(bws secret list 2>/dev/null \
    | jq -r ".[] | select(.key == \"${BW_SECRET_KEY_ID}\" and .projectId == \"${BW_PROJECT_ID}\") | .id" || true)
EXISTING_SECRET_KEY=$(bws secret list 2>/dev/null \
    | jq -r ".[] | select(.key == \"${BW_SECRET_SECRET_KEY}\" and .projectId == \"${BW_PROJECT_ID}\") | .id" || true)

if [ -n "$EXISTING_KEY_ID" ] && [ -n "$EXISTING_SECRET_KEY" ] && [ "$REPLACE" = false ]; then
    STORED_KEY_ID=$(bws secret get "$EXISTING_KEY_ID" 2>/dev/null | jq -r '.value' || true)
    STORED_SECRET_KEY=$(bws secret get "$EXISTING_SECRET_KEY" 2>/dev/null | jq -r '.value' || true)

    if [ -n "$STORED_KEY_ID" ] && [ -n "$STORED_SECRET_KEY" ]; then
        echo "  Found existing Bitwarden secrets. Validating B2 key ${STORED_KEY_ID}..."
        if B2_APPLICATION_KEY_ID="${STORED_KEY_ID}" B2_APPLICATION_KEY="${STORED_SECRET_KEY}" \
            b2 ls "b2://${B2_BUCKET}/${B2_PREFIX}" >/dev/null 2>&1; then
            echo "  B2 credentials are valid, reusing"
            B2_KEY_ID="$STORED_KEY_ID"
            B2_KEY_SECRET="$STORED_SECRET_KEY"
            B2_CREDS_VALID=true
        else
            echo "  B2 credentials are invalid, will rotate"
            # Delete the stale B2 key if it still exists
            if b2 key list 2>/dev/null | awk '{print $1}' | grep -qx "${STORED_KEY_ID}"; then
                echo "  Deleting stale B2 key: ${STORED_KEY_ID}"
                b2 key delete "${STORED_KEY_ID}"
            fi
        fi
    fi
elif [ "$REPLACE" = true ] && [ -n "$EXISTING_KEY_ID" ]; then
    echo "  --replace: rotating credentials"
    STORED_KEY_ID=$(bws secret get "$EXISTING_KEY_ID" 2>/dev/null | jq -r '.value' || true)
    if [ -n "$STORED_KEY_ID" ]; then
        if b2 key list 2>/dev/null | awk '{print $1}' | grep -qx "${STORED_KEY_ID}"; then
            echo "  Deleting existing B2 key: ${STORED_KEY_ID}"
            b2 key delete "${STORED_KEY_ID}"
        fi
    fi
else
    echo "  No existing credentials found"
fi

# Create new B2 key if existing creds were invalid/missing/replaced
if [ "${B2_CREDS_VALID}" = false ]; then
    # Clean up any orphaned B2 keys with the same name
    ORPHANED_KEYS=$(b2 key list 2>/dev/null | grep " ${B2_KEY_NAME} " | awk '{print $1}' || true)
    for key_id in $ORPHANED_KEYS; do
        echo "  Deleting orphaned B2 key: ${key_id}"
        b2 key delete "${key_id}"
    done

    B2_KEY_RESULT=$(b2 key create \
        --bucket "${B2_BUCKET}" \
        --name-prefix "${B2_PREFIX}" \
        "${B2_KEY_NAME}" \
        "listBuckets,listFiles,readFiles,writeFiles,deleteFiles")
    B2_KEY_ID=$(echo "$B2_KEY_RESULT" | awk '{print $1}')
    B2_KEY_SECRET=$(echo "$B2_KEY_RESULT" | awk '{print $2}')
    echo "  Created B2 key: ${B2_KEY_NAME} (${B2_KEY_ID})"
fi

# --- Step 2: Store credentials in Bitwarden SM ---
echo "--- Step 2: Storing credentials in Bitwarden SM ---"
if [ "${B2_CREDS_VALID}" = true ]; then
    echo "  Credentials unchanged, skipping Bitwarden update"
else
    bws_upsert "${BW_SECRET_KEY_ID}"     "${B2_KEY_ID}"
    bws_upsert "${BW_SECRET_SECRET_KEY}" "${B2_KEY_SECRET}"
fi

# --- Summary ---
echo ""
echo "=== Provisioning complete ==="
echo ""
echo "Resources created:"
echo "  B2 Key:         ${B2_KEY_NAME} (id: ${B2_KEY_ID}, prefix: ${B2_PREFIX}, reused: ${B2_CREDS_VALID})"
echo "  BWS Secret:     ${BW_SECRET_KEY_ID}"
echo "  BWS Secret:     ${BW_SECRET_SECRET_KEY}"
echo ""
echo "Ensure clusters/${CLUSTER}/infra.yaml longhorn values include:"
echo ""
echo "              backup:"
echo "                b2AccessKeyIdSecret: \"${BW_SECRET_KEY_ID}\""
echo "                b2SecretAccessKeySecret: \"${BW_SECRET_SECRET_KEY}\""
echo "              longhorn:"
echo "                defaultBackupStore:"
echo "                  backupTarget: \"s3://${B2_BUCKET}@eu-central-003/longhorn-${CLUSTER}\""
