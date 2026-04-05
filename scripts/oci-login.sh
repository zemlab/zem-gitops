#!/usr/bin/env bash
set -euo pipefail

# OCI Session Management Wrapper
# This script tries to refresh an existing session first, then falls back to full authentication

PROFILE="${1:-DEFAULT}"

echo "Attempting to refresh OCI session for profile: $PROFILE"

if oci session refresh --profile "$PROFILE" 2>/dev/null; then
    echo "✓ Session refreshed successfully"
    exit 0
fi

echo "Session refresh failed or no active session found"
echo "Starting new authentication (browser will open)..."
oci session authenticate --region uk-london-1 --profile-name "$PROFILE"

echo "✓ Authentication complete"
