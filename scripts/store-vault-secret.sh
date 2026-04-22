#!/bin/bash
set -euo pipefail

# Store or update a JSON secret in OCI Vault.
# Idempotent: creates if absent, updates if present.
#
# Usage:
#   ./scripts/store-vault-secret.sh <secret-name> KEY=VALUE [KEY=VALUE ...]
#   ./scripts/store-vault-secret.sh <secret-name> --json '{"KEY": "VALUE"}'
#
# Examples:
#   ./scripts/store-vault-secret.sh cluster04-zenith-staging-cnpg \
#       ACCESS_KEY_ID=abc123 SECRET_ACCESS_KEY=supersecret
#
#   ./scripts/store-vault-secret.sh my-secret --json '{"foo": "bar"}'
#
# Dependencies: oci, jq

# OCI configuration
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagyawjldswlrq2f2dnsqz2kqlzsvj6mirpcue7oqwzlyuwx7pqjha}"
OCI_VAULT_OCID="${OCI_VAULT_OCID:-ocid1.vault.oc1.uk-london-1.eruxsrmlaafja.abwgiljridwbzbxrs2vvay6b6n6x7xhi3ymapbgov36lrqmm7bkxgh3hmnka}"
OCI_VAULT_KEY_OCID="${OCI_VAULT_KEY_OCID:-ocid1.key.oc1.uk-london-1.eruxsrmlaafja.abwgiljtncunmpibvwvjygia2d3umhb6vf24axjuxuivbg52moq76tgdhdua}"

usage() {
    echo "Usage: $0 <secret-name> KEY=VALUE [KEY=VALUE ...]"
    echo "       $0 <secret-name> --json '{\"KEY\": \"VALUE\"}'"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SECRET_NAME="$1"
shift

# Build JSON payload
if [ "$1" = "--json" ]; then
    [ $# -lt 2 ] && usage
    SECRET_JSON="$2"
    # Validate JSON
    if ! echo "${SECRET_JSON}" | jq empty 2>/dev/null; then
        echo "ERROR: invalid JSON"
        exit 1
    fi
else
    # Build from KEY=VALUE pairs
    JQ_ARGS=()
    JQ_FIELDS=()
    for pair in "$@"; do
        if [[ ! "${pair}" =~ ^[A-Za-z0-9_]+=.* ]]; then
            echo "ERROR: expected KEY=VALUE, got: ${pair}"
            usage
        fi
        key="${pair%%=*}"
        val="${pair#*=}"
        JQ_ARGS+=(--arg "${key}" "${val}")
        JQ_FIELDS+=("\"${key}\": \$${key}")
    done
    FIELDS_JSON=$(IFS=', '; echo "${JQ_FIELDS[*]}")
    SECRET_JSON=$(jq -n "${JQ_ARGS[@]}" "{${FIELDS_JSON}}")
fi

# Check dependencies
for cmd in oci jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# Verify OCI auth
if ! oci iam region list --output json </dev/null >/dev/null 2>&1; then
    echo "ERROR: OCI authentication failed. If using security_token auth, run: oci session refresh"
    exit 1
fi

SECRET_B64=$(echo -n "${SECRET_JSON}" | base64)

EXISTING_OCID=$(oci vault secret list \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vault-id "${OCI_VAULT_OCID}" \
    --name "${SECRET_NAME}" \
    --output json 2>/dev/null | jq -r '.data[] | select(.["lifecycle-state"] != "PENDING_DELETION") | .id // empty' | head -1)

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
