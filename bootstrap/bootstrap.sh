#!/bin/bash
set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <cluster> <bitwarden-auth-token>"
  exit 1
fi

CLUSTER="$1"
export BW_AUTH_TOKEN="$2"

# Check dependencies
for cmd in helmfile helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed or not in PATH"
    exit 1
  fi
done

if ! helm plugin list | grep -q diff; then
  echo "ERROR: helm-diff plugin is required. Install with: helm plugin install https://github.com/databus23/helm-diff"
  exit 1
fi

cd "$(dirname "$0")"

CURRENT_CONTEXT="$(kubectl config current-context)"
echo "kubectl context: ${CURRENT_CONTEXT}"
read -rp "Bootstrap ${CLUSTER} against this context? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

helmfile -e "$CLUSTER" apply --skip-diff-on-install
