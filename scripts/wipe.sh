#!/usr/bin/env bash
set -euo pipefail

log() { echo "[wipe] $*"; }

log "Detecting container runtime..."
COMPOSE_CMD="docker compose"

if ! command -v docker &> /dev/null; then
    if command -v podman-compose &> /dev/null; then
        log "Docker not found. Using podman-compose."
        COMPOSE_CMD="podman-compose"
    elif command -v podman &> /dev/null && podman compose version &> /dev/null; then
        log "Docker not found. Using podman compose."
        COMPOSE_CMD="podman compose"
    else
        log "Error: Neither docker nor podman-compose found."
        exit 1
    fi
fi

log "Stopping containers..."
$COMPOSE_CMD down -v

log "Cleaning up local artifacts..."
rm -f .gitea_token

log "Removing K3d cluster..."
k3d cluster delete gitopslab 2>/dev/null || true

log "Environment wiped."
