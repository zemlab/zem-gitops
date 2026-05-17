#!/bin/bash
set -euo pipefail

# Exports all restic passwords from backup-credentials secrets across all namespaces.
# Outputs markdown table rows to stdout (no header), so output from multiple
# clusters can be concatenated.
#
# Requires: kubectl (with cluster-admin access), jq
#
# Usage:
#   # Single cluster:
#   ./scripts/export-restic-passwords.sh
#
#   # Multiple clusters (concatenate):
#   {
#     echo "# Restic Backup Passwords"
#     echo ""
#     echo "Exported: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
#     echo ""
#     echo "| Cluster | Namespace | Restic Password |"
#     echo "|---------|-----------|-----------------|"
#     for ctx in cluster01 cluster03 cluster04; do
#       kubectl config use-context "$ctx" >/dev/null
#       ./scripts/export-restic-passwords.sh
#     done
#   } > restic-passwords.md

SECRETS=$(kubectl get secrets --all-namespaces --field-selector metadata.name=backup-credentials \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null)

if [ -z "${SECRETS}" ]; then
    exit 0
fi

CLUSTER=$(kubectl config current-context)

for ns in ${SECRETS}; do
    PASSWORD=$(kubectl get secret backup-credentials -n "${ns}" -o json | \
        jq -r '.data.RESTIC_PASSWORD' | base64 -d)
    echo "| ${CLUSTER} | ${ns} | \`${PASSWORD}\` |"
done
