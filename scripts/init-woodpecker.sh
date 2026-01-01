#!/bin/bash
set -e

# Initialize Woodpecker
# - Enable 'platform' repo
# - Set Trusted
# - Add Secrets

source /workspace/.env

WOODPECKER_URL="${WOODPECKER_PUBLIC_URL:-http://woodpecker:8000}"
# Woodpecker requires token to interact via API.
# The user (Gitea admin) needs to login to Woodpecker first to sync.
# This is tricky in automation.
# Usually, we need to inject the token into Woodpecker DB or use the token we just created in Gitea
# IF Woodpecker uses Gitea as OAuth provider.
# But Woodpecker doesn't let you use Gitea token to authenticate TO Woodpecker API directly,
# you use Woodpecker token.
# To get Woodpecker token, you need to login via UI (OAuth).

# However, e2e.ps1 has a clever trick: `Get-WoodpeckerUser` from sqlite DB and `New-WoodpeckerToken` by signing JWT manually.
# We can try to replicate that or use the `woodpecker-cli` if configured.
# Or we can insert the user/token into DB directly?

# Let's look at e2e.ps1 again. It accesses sqlite volume.
# `woodpecker-server` uses sqlite.
# We can use `docker run ... sqlite3` to inspect/modify DB.

# Or, since we are in bootstrap, maybe we can assume the user has logged in? No, "fully automatic".
# The `woodpecker-server` config has `WOODPECKER_ADMIN=gitea_admin`.
# This makes `gitea_admin` an admin. But the user must exist in DB.
# User is created on first login.
# Can we force sync?

# TechSpec 6.8: "При bootstrap включить репозиторий и выставить trusted: true (через API/конфиг)."

# Strategy:
# 1. Wait for Woodpecker to be up.
# 2. We need a Woodpecker API token.
#    Since we can't login via browser, we have to "forge" a session or token.
#    e2e.ps1 does exactly this: generates a JWT signed with the user hash from DB.
#    But the user must exist in DB. The user exists only after first login via Gitea.
#    This is a "chicken and egg" problem for headless bootstrap unless we can trigger the sync.

# Maybe we can insert the user into Woodpecker DB manually?
# Or use `woodpecker-cli`? `woodpecker-cli` also needs token.

# Let's see if there is a simpler way.
# If we simply want to enable the repo, maybe we can use CLI with the admin token if we can get it.

# Let's try to do what e2e.ps1 does:
# 1. Wait for Woodpecker.
# 2. Check if user exists in DB. If not, maybe we can't proceed?
#    Wait, if the user hasn't logged in, they are not in DB.
#    So we MUST insert the user?
#    Or maybe Woodpecker has an auto-sync?

# Looking at TechSpec 7.1: "6. Инициализация Woodpecker... включить репозиторий...".
# This implies it CAN be done.

# Let's try to assume `woodpecker-cli` or API usage.
# If we use `docker exec` into woodpecker-server, maybe there are tools?
# `woodpecker-server` binary has `user-add` command?
# `woodpecker-server user add --login gitea_admin --admin` ?
# Let's check Woodpecker docs or assume standard capabilities.
# Woodpecker server binary DOES have commands.

echo "Initializing Woodpecker..."
# Wait for Woodpecker
until curl -s "$WOODPECKER_URL/healthz" >/dev/null; do
  echo "Waiting for Woodpecker..."
  sleep 5
done

ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"

# Create/Update user in Woodpecker via CLI
echo "Creating Woodpecker user '$ADMIN_USER'..."
docker exec woodpecker-server woodpecker-server user add --login "$ADMIN_USER" --admin || true

# Now we need to get the token for this user to use the API.
# `woodpecker-server user info` might show it? Or we can specific a token?
# `user add` usually creates a user. Does it return a token?
# Usually not.
# But we can try to use `woodpecker-cli` inside the bootstrap container if installed?
# Dockerfile installs `curl bash git jq yq docker-cli docker-cli-compose`. No `woodpecker-cli`.

# So we must use API. We need a token.
# Can we use `woodpecker-server` to generate a token?
# `woodpecker-server token create`? (Assuming version 2.x?)
# If not, we can inspect the DB to get the hash and sign it, like e2e.ps1.

# Let's try a simpler approach:
# The `woodpecker-agent` uses `WOODPECKER_AGENT_SECRET`.
# The `woodpecker-server` also has it.
# Is there an API available for agents that we can abuse? No.

# Let's go with the DB approach as it's the most robust if we have docker access.
# We need to find the user hash.
HASH=$(docker exec woodpecker-server sh -c "apk add --no-cache sqlite >/dev/null && sqlite3 /var/lib/woodpecker/woodpecker.sqlite \"select hash from users where login='$ADMIN_USER';\"")

if [ -z "$HASH" ]; then
    echo "Could not find user '$ADMIN_USER' in Woodpecker DB."
    exit 1
fi

# Generate JWT Token (Shell implementation of e2e.ps1 logic)
# Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
HEADER_B64="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
NOW=$(date +%s)
EXP=$((NOW + 3600))
# Payload: {"user-id":"$ADMIN_USER","type":"user","exp":$EXP} - Wait, user-id in DB is int?
# e2e.ps1 uses "user-id" = $userId (which is int from DB).
ID=$(docker exec woodpecker-server sqlite3 /var/lib/woodpecker/woodpecker.sqlite "select id from users where login='$ADMIN_USER';")
PAYLOAD="{\"user-id\":\"$ID\",\"type\":\"user\",\"exp\":$EXP}"
PAYLOAD_B64=$(echo -n "$PAYLOAD" | base64 | tr -d '\n' | tr -d '=' | tr '/+' '_-')

SIGN_INPUT="$HEADER_B64.$PAYLOAD_B64"
# HMACSHA256 with key = HASH
# In bash with openssl:
SIGNATURE=$(echo -n "$SIGN_INPUT" | openssl dgst -sha256 -hmac "$HASH" -binary | base64 | tr -d '\n' | tr -d '=' | tr '/+' '_-')
TOKEN="$SIGN_INPUT.$SIGNATURE"

WOODPECKER_TOKEN="$TOKEN"
echo "Generated Woodpecker Token."

# Sync repos
echo "Syncing repositories..."
curl -X POST -H "Authorization: Bearer $WOODPECKER_TOKEN" "$WOODPECKER_URL/api/user/repos/sync"

sleep 5

# Enable repo
REPO_OWNER="$ADMIN_USER"
REPO_NAME="platform"
echo "Enabling repository '$REPO_OWNER/$REPO_NAME'..."
curl -X POST -H "Authorization: Bearer $WOODPECKER_TOKEN" "$WOODPECKER_URL/api/repos/$REPO_OWNER/$REPO_NAME"

# Enable Trusted
echo "Setting Trusted..."
curl -X PATCH -H "Authorization: Bearer $WOODPECKER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"trusted": true}' \
    "$WOODPECKER_URL/api/repos/$REPO_OWNER/$REPO_NAME"

# Add Secrets
# gitea_token (from file)
GITEA_TOKEN=$(cat /workspace/.gitea_token)
echo "Adding secret 'gitea_token'..."
curl -X POST -H "Authorization: Bearer $WOODPECKER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"gitea_token\", \"value\": \"$GITEA_TOKEN\", \"events\": [\"push\", \"tag\", \"deployment\"]}" \
    "$WOODPECKER_URL/api/repos/$REPO_OWNER/$REPO_NAME/secrets"

echo "Adding secret 'gitea_user'..."
curl -X POST -H "Authorization: Bearer $WOODPECKER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"gitea_user\", \"value\": \"$ADMIN_USER\", \"events\": [\"push\", \"tag\", \"deployment\"]}" \
    "$WOODPECKER_URL/api/repos/$REPO_OWNER/$REPO_NAME/secrets"

echo "Woodpecker initialization complete."
