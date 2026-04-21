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

# Warn if live ArgoCD Applications exist — helmfile apply is safe but confirm intent
APP_COUNT=$(kubectl get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$APP_COUNT" -gt 0 ]; then
  echo ""
  echo "WARNING: ${APP_COUNT} ArgoCD Application(s) found on this cluster."
  echo "helmfile apply will upgrade releases in place — it will NOT delete namespaces or Applications."
  echo "If you intend to destroy ArgoCD or remove releases, that requires a MANUAL step:"
  echo "  helm uninstall <release> -n <namespace>"
  echo "  helmfile -e ${CLUSTER} destroy   # destructive — removes all releases"
  echo ""
  read -rp "Proceed with helmfile apply on live cluster ${CLUSTER}? [y/N] " confirm2
  if [[ "${confirm2}" != "y" && "${confirm2}" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

helmfile -e "$CLUSTER" apply --skip-diff-on-install
