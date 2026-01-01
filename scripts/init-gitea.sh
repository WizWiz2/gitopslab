#!/bin/bash
set -e

# Initialize Gitea
# - Create admin user
# - Create 'platform' repo
# - Init content (if empty)
# - Create Access Token

source /workspace/.env

GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"
ADMIN_PASS="${GITEA_ADMIN_PASSWORD:-secret123}"
REPO_NAME="platform"

echo "Initializing Gitea at $GITEA_URL..."

# Wait for Gitea API
until curl -s "$GITEA_URL/api/v1/version" >/dev/null; do
  echo "Waiting for Gitea API..."
  sleep 5
done

# Create Admin User
# Gitea admin creation via CLI in the container is easier usually, but here we are in bootstrap container.
# We must use API or rely on initial env vars if Gitea supports it (it usually does GITEA__security__INSTALL_LOCK=true).
# Actually, Gitea creates admin from env vars on first run if configured.
# Let's assume the user is created by Gitea itself via docker-compose env vars.
# If not, we would need to use `gitea admin user create` via ssh or `docker exec`.
# Looking at docker-compose, there are no admin user env vars for Gitea image directly (only GITEA__server...).
# Wait, run-e2e.ps1 uses GITEA_ADMIN_USER/PASS from .env.
# If Gitea image didn't create it, we need to create it.
# But we don't have access to run `gitea` binary here.
# We can try to register via API or assume it's set up.
# TechSpec says "Bootstrap... Create user".
# To create user via API, we need a token or we need to be able to register.
# Standard Gitea allows registration.

# Try to create admin user via 'gitea' command in the gitea container?
# We can use `docker` or `ssh`. We have docker socket mounted.
# BOOTSTRAP_TRACE=true in docker-compose, and docker socket mounted.
# DOCKER_HOST is set to tcp://10.88.0.1:2375 (podman) or socket.

echo "Creating Gitea admin user '$ADMIN_USER'..."
docker exec -u 1000 gitea gitea admin user create --admin --username "$ADMIN_USER" --password "$ADMIN_PASS" --email "admin@localhost" || true

# Create Repository
echo "Creating repository '$REPO_NAME'..."
curl -X POST -u "$ADMIN_USER:$ADMIN_PASS" \
     -H "Content-Type: application/json" \
     -d "{\"name\": \"$REPO_NAME\", \"private\": false, \"auto_init\": false}" \
     "$GITEA_URL/api/v1/user/repos" || true

# Initialize content
# We need to push the current workspace content to Gitea.
# We are in /workspace.
echo "Pushing initial content to Gitea..."
git config --global user.email "bootstrap@localhost"
git config --global user.name "Bootstrap"
git config --global init.defaultBranch main

# Create a temporary directory for git operations to avoid messing up mounted volume
TMP_DIR=$(mktemp -d)
cp -r /workspace/* "$TMP_DIR/"
# Don't copy .git if it exists in workspace (host)
rm -rf "$TMP_DIR/.git"

cd "$TMP_DIR"
git init
git remote add origin "$GITEA_URL/$ADMIN_USER/$REPO_NAME.git"
git add .
git commit -m "Initial commit from bootstrap" || true
git push -u origin main -f || echo "Push failed, maybe already exists or auth issue"

# Create Token for CI/Argo
echo "Creating Gitea Access Token..."
TOKEN_NAME="platform-token"
# Check if exists (list tokens not easily possible without token, catch-22, unless we use basic auth)
# Delete old one just in case?
# API to create token: POST /users/{username}/tokens
RESPONSE=$(curl -s -X POST -u "$ADMIN_USER:$ADMIN_PASS" \
     -H "Content-Type: application/json" \
     -d "{\"name\": \"$TOKEN_NAME\", \"scopes\": [\"repo\", \"admin:repo_hook\", \"user\"]}" \
     "$GITEA_URL/api/v1/users/$ADMIN_USER/tokens")

TOKEN=$(echo "$RESPONSE" | jq -r .sha1)

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "Could not create token (maybe already exists?). Trying to reuse logic or just failing."
    # If we can't get the token, subsequent steps will fail.
    # But usually this script runs once.
    # If token exists, we can't retrieve it. We might need to delete it first.
    # But listing requires token. Basic auth works for listing tokens? Yes.
    # List tokens:
    EXISTING_ID=$(curl -s -u "$ADMIN_USER:$ADMIN_PASS" "$GITEA_URL/api/v1/users/$ADMIN_USER/tokens" | jq -r ".[] | select(.name == \"$TOKEN_NAME\") | .id")
    if [ ! -z "$EXISTING_ID" ]; then
        echo "Deleting existing token ID $EXISTING_ID..."
        curl -s -X DELETE -u "$ADMIN_USER:$ADMIN_PASS" "$GITEA_URL/api/v1/users/$ADMIN_USER/tokens/$EXISTING_ID"
        # Recreate
        RESPONSE=$(curl -s -X POST -u "$ADMIN_USER:$ADMIN_PASS" \
             -H "Content-Type: application/json" \
             -d "{\"name\": \"$TOKEN_NAME\", \"scopes\": [\"repo\", \"admin:repo_hook\", \"user\"]}" \
             "$GITEA_URL/api/v1/users/$ADMIN_USER/tokens")
        TOKEN=$(echo "$RESPONSE" | jq -r .sha1)
    fi
fi

if [ "$TOKEN" == "null" ]; then
    echo "Failed to generate token. Response: $RESPONSE"
    exit 1
fi

echo "Generated Token: $TOKEN"
# Save token for other scripts
echo "$TOKEN" > /workspace/.gitea_token
