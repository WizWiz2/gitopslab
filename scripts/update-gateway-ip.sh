#!/usr/bin/env bash
# Auto-update HOST_GATEWAY_IP in .env based on k3d network gateway

set -euo pipefail

ENV_FILE="${1:-.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found"
  exit 1
fi

# Detect k3d network gateway IP
GATEWAY_IP=$(podman network inspect k3d --format "{{range .IPAM.Config}}{{.Gateway}}{{end}}" 2>/dev/null || echo "")

if [ -z "$GATEWAY_IP" ]; then
  echo "WARNING: Could not detect k3d network gateway IP, keeping current value"
  exit 0
fi

# Update or add HOST_GATEWAY_IP in .env
if grep -q "^HOST_GATEWAY_IP=" "$ENV_FILE"; then
  # Update existing value
  sed -i "s/^HOST_GATEWAY_IP=.*/HOST_GATEWAY_IP=$GATEWAY_IP/" "$ENV_FILE"
  echo "Updated HOST_GATEWAY_IP=$GATEWAY_IP in $ENV_FILE"
else
  # Add new value
  echo "HOST_GATEWAY_IP=$GATEWAY_IP" >> "$ENV_FILE"
  echo "Added HOST_GATEWAY_IP=$GATEWAY_IP to $ENV_FILE"
fi
