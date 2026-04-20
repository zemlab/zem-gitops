#!/bin/bash
# Setup Tailscale cluster egress after tailscale operator is deployed
# This patches CoreDNS to forward ts.net queries to the k8s-nameserver
# Run this after bootstrap completes and tailscale operator is ready

set -e

NS="${TAILSCALE_NAMESPACE:-awx-prod}"

echo "=== Tailscale Cluster Egress Setup ==="

# Check if DNSConfig exists
if ! kubectl get dnsconfig ts-dns -n "$NS" &>/dev/null; then
    echo "ERROR: DNSConfig ts-dns not found in namespace $NS"
    echo "Has the tailscale operator been deployed?"
    exit 1
fi

# Wait for nameserver to be ready and get IP
echo "Waiting for nameserver to be ready..."
until TS_DNS_IP=$(kubectl get dnsconfig ts-dns -n "$NS" -o jsonpath='{.status.nameserverIP}' 2>/dev/null); do
    echo "Waiting for nameserver IP..."
    sleep 5
done
echo "Nameserver IP: $TS_DNS_IP"

# Backup current CoreDNS config
kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-backup.yaml
echo "Backed up CoreDNS to /tmp/coredns-backup.yaml"

# Read existing Corefile
CURRENT=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')

# Check if ts.net already exists
if echo "$CURRENT" | grep -q "ts.net {"; then
    echo "ts.net stub already exists in CoreDNS, skipping patch"
else
    echo "Patching CoreDNS with ts.net stub..."
    
    # Add ts.net block
    NEW_COREFILE="${CURRENT}
ts.net {
    errors
    cache 30
    forward . ${TS_DNS_IP}
}"

    # Apply patch
    NEW_COREFILE_ESCAPED=$(echo "$NEW_COREFILE" | jq -Rs '.')
    kubectl patch configmap coredns -n kube-system --type merge -p "{\"data\":{\"Corefile\":$NEW_COREFILE_ESCAPED}}"
    echo "CoreDNS patched successfully"
fi

echo -e "\n=== Setup complete ==="
echo ""
echo "AWX can now reach hosts via Tailscale DNS names."
echo "SSH to: hostname-egress.default.svc.cluster.local"