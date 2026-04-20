#!/bin/bash
set -euo pipefail

# Create a Tailscale OAuth client for a cluster's k8s operator and store
# credentials in Bitwarden Secrets Manager.
#
# Idempotent: if secrets already exist in Bitwarden, skips OAuth client creation.
# Use --replace to force rotation (creates new OAuth client, updates Bitwarden).
#
# Usage: ./provision-tailscale-oauth.sh [--replace] <cluster-name>
# Example: ./provision-tailscale-oauth.sh cluster04
#
# Required env vars:
#   BWS_ACCESS_TOKEN   - Bitwarden Secrets Manager machine account token (write access)
#   TS_API_KEY         - Tailscale API key (for creating ACL tags)
# Optional env vars:
#   TS_TAILNET         - Tailscale tailnet name (default: shark-puffin.ts.net)

REPLACE=false
if [ "${1:-}" = "--replace" ]; then
    REPLACE=true
    shift
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 [--replace] <cluster-name>"
    exit 1
fi

CLUSTER="$1"
TS_TAILNET="${TS_TAILNET:-shark-puffin.ts.net}"
BW_PROJECT_ID="93356527-3980-4fb1-ab38-b2b101650812"

for cmd in bws jq curl; do
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

echo "=== Provisioning Tailscale OAuth for ${CLUSTER} ==="
echo ""

# Check if secrets already exist in Bitwarden
EXISTING_ID=$(bws secret list 2>/dev/null \
    | jq -r ".[] | select(.key == \"tailscale-${CLUSTER}-client-id\" and .projectId == \"${BW_PROJECT_ID}\") | .id" || true)

if [ -n "$EXISTING_ID" ] && [ "$REPLACE" = false ]; then
    echo "Bitwarden secrets tailscale-${CLUSTER}-client-id already exist. Skipping OAuth client creation."
    echo "Use --replace to rotate credentials."
    exit 0
fi

if [ "$REPLACE" = true ] && [ -n "$EXISTING_ID" ]; then
    echo "WARNING: --replace will create a new OAuth client. The old client will remain in Tailscale admin and must be deleted manually."
    read -rp "Continue? [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "--- Ensuring Tailscale ACL tags exist ---"
curl -s -D /tmp/ts_acl_headers.txt \
    -H "Authorization: Bearer ${TS_API_KEY}" \
    -H "Accept: application/json" \
    "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/acl" \
    -o /tmp/ts_acl.json

TS_ACL_HTTP=$(grep "^HTTP/" /tmp/ts_acl_headers.txt | tail -1 | awk '{print $2}')
if [ "$TS_ACL_HTTP" -lt 200 ] || [ "$TS_ACL_HTTP" -ge 300 ]; then
    echo "ERROR: Failed to fetch Tailscale ACL (HTTP ${TS_ACL_HTTP}):"
    cat /tmp/ts_acl.json | jq . 2>/dev/null || cat /tmp/ts_acl.json
    exit 1
fi

ETAG=$(grep -i "^etag:" /tmp/ts_acl_headers.txt | tr -d '\r' | awk '{print $2}')

OPERATOR_TAG="tag:${CLUSTER}-operator"
DEVICE_TAG="tag:${CLUSTER}"

# Add tags if missing; existing values are preserved
UPDATED_ACL=$(jq \
    --arg op "$OPERATOR_TAG" \
    --arg dev "$DEVICE_TAG" \
    '
    if .tagOwners[$op] then . else .tagOwners[$op] = [] end |
    if .tagOwners[$dev] then . else .tagOwners[$dev] = [$op] end |
    (.grants[] | select((.src | contains(["group:zem-admin"])) and (.app | has("tailscale.com/cap/kubernetes"))) | .dst) |= (. + [$op] | unique)
    ' /tmp/ts_acl.json)

if [ "$UPDATED_ACL" = "$(cat /tmp/ts_acl.json)" ]; then
    echo "  Tags already exist: ${OPERATOR_TAG}, ${DEVICE_TAG}"
else
    UPDATE_HTTP=$(curl -s -o /tmp/ts_acl_update.json -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${TS_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "If-Match: ${ETAG}" \
        "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/acl" \
        -d "$UPDATED_ACL")
    if [ "$UPDATE_HTTP" -lt 200 ] || [ "$UPDATE_HTTP" -ge 300 ]; then
        echo "ERROR: Failed to update Tailscale ACL (HTTP ${UPDATE_HTTP}):"
        cat /tmp/ts_acl_update.json | jq . 2>/dev/null || cat /tmp/ts_acl_update.json
        exit 1
    fi
    echo "  Created tags: ${OPERATOR_TAG}, ${DEVICE_TAG}"
fi
echo ""

echo "--- Tailscale OAuth client ---"
echo ""
echo "  Tailscale does not expose a public API for creating OAuth clients."
echo "  Create one manually at: https://login.tailscale.com/admin/settings/oauth"
echo ""
echo "  Settings:"
echo "    Description : ${CLUSTER} k8s operator"
echo "    Tags        : tag:${CLUSTER}-operator, tag:${CLUSTER}"
echo "    Scopes      : Devices - Core (write), Auth Keys (write)"
echo ""
read -rp "  Client ID     : " TS_CLIENT_ID
read -rsp "  Client Secret : " TS_CLIENT_SECRET
echo ""

if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    echo "ERROR: Client ID and secret are required."
    exit 1
fi

echo "--- Storing credentials in Bitwarden Secrets Manager ---"

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

bws_upsert "tailscale-${CLUSTER}-client-id"     "$TS_CLIENT_ID"
bws_upsert "tailscale-${CLUSTER}-client-secret" "$TS_CLIENT_SECRET"

echo ""
echo "Done. Bitwarden secrets ready for ${CLUSTER}."
