#!/usr/bin/env bash
set -eu

log() { echo "[init-woodpecker] $*"; }

WOODPECKER_URL="${WOODPECKER_INTERNAL_URL:-http://woodpecker-server:8000}"
WOODPECKER_PUBLIC_URL="${WOODPECKER_HOST:-http://woodpecker.localhost:8000}"
REPO_OWNER="${GITEA_ADMIN_USER:-gitops}"
REPO_NAME="platform"
GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitops}"
ADMIN_PASS="${GITEA_ADMIN_PASSWORD:-${GITEA_ADMIN_PASS:-gitops1234}}"
GITEA_PUBLIC_URL="${GITEA_PUBLIC_URL:-http://gitea.localhost:3000}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
WEBHOOK_HOST="${WOODPECKER_EXPERT_WEBHOOK_HOST:-http://woodpecker-server:8000}"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-gitopslab}"
WOODPECKER_DB_VOLUME="${WOODPECKER_DB_VOLUME:-${COMPOSE_PROJECT_NAME}_woodpecker-data}"

# Wait for Woodpecker
/workspace/scripts/wait-for.sh "${WOODPECKER_URL}/healthz"

log "Configuring Woodpecker..."

woodpecker_sql() {
    docker run --rm -v "${WOODPECKER_DB_VOLUME}:/data" nouchka/sqlite3 /data/woodpecker.sqlite "$1"
}

get_woodpecker_token() {
    local user_id="$1"
    local user_hash="$2"
    local exp
    exp=$(date +%s)
    exp=$((exp + 3600))
    docker run --rm -e USER_ID="$user_id" -e USER_HASH="$user_hash" -e EXP="$exp" python:3.11-alpine python -c "import os, json, base64, hmac, hashlib; b64url = lambda d: base64.urlsafe_b64encode(d).rstrip(b'=') .decode(); user_id = os.environ['USER_ID']; user_hash = os.environ['USER_HASH'].encode(); exp = int(os.environ['EXP']); header = {'alg': 'HS256', 'typ': 'JWT'}; payload = {'user-id': user_id, 'type': 'user', 'exp': exp}; header_b64 = b64url(json.dumps(header, separators=(',', ':')).encode()); payload_b64 = b64url(json.dumps(payload, separators=(',', ':')).encode()); msg = f'{header_b64}.{payload_b64}'; sig = hmac.new(user_hash, msg.encode(), hashlib.sha256).digest(); print(f'{msg}.{b64url(sig)}')"
}

user_row=$(woodpecker_sql "select id,hash from users where login='${REPO_OWNER}' limit 1;" | tr -d '\r' || true)
if [ -z "$user_row" ]; then
    log "=========================================="
    log "⚠️  MANUAL STEP REQUIRED"
    log "=========================================="
    log "Woodpecker user '${REPO_OWNER}' not found in database."
    log ""
    log "To complete setup:"
    log "  1. Open: ${WOODPECKER_PUBLIC_URL}"
    log "  2. Click 'Login with Gitea'"
    log "  3. Authorize the application"
    log "  4. Re-run: start.bat"
    log ""
    log "This is a ONE-TIME setup step."
    log "=========================================="
    exit 0
fi
user_id="${user_row%%|*}"
user_hash="${user_row#*|}"
woodpecker_token="$(get_woodpecker_token "$user_id" "$user_hash")"

if [ -z "$woodpecker_token" ]; then
    log "Failed to generate Woodpecker API token."
    exit 1
fi

gitea_repo_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/repos/${REPO_OWNER}/${REPO_NAME}")
gitea_repo_id=$(echo "$gitea_repo_json" | jq -r '.id // empty')
if [ -z "$gitea_repo_id" ]; then
    log "Failed to get Gitea repo id: ${gitea_repo_json}"
    exit 1
fi

repo_json=$(curl -s -H "Authorization: Bearer ${woodpecker_token}" \
    "${WOODPECKER_URL}/api/repos/lookup/${REPO_OWNER}/${REPO_NAME}" || true)
repo_id=$(echo "$repo_json" | jq -r '.id // empty')

if [ -z "$repo_id" ]; then
    log "Activating Woodpecker repo ${REPO_OWNER}/${REPO_NAME}..."
    repo_json=$(curl -s -X POST -H "Authorization: Bearer ${woodpecker_token}" \
        "${WOODPECKER_URL}/api/repos?forge_remote_id=${gitea_repo_id}")
    repo_id=$(echo "$repo_json" | jq -r '.id // empty')
fi

if [ -z "$repo_id" ]; then
    log "Failed to activate Woodpecker repo: ${repo_json}"
    exit 1
fi

curl -s -X PATCH -H "Authorization: Bearer ${woodpecker_token}" -H "Content-Type: application/json" \
    -d '{"trusted":{"network":true,"security":true,"volumes":true}}' \
    "${WOODPECKER_URL}/api/repos/${repo_id}" >/dev/null

curl -s -X POST -H "Authorization: Bearer ${woodpecker_token}" \
    "${WOODPECKER_URL}/api/repos/${repo_id}/repair" >/dev/null || true

clone_http="${GITEA_URL%/}/${REPO_OWNER}/${REPO_NAME}.git"
clone_ssh="ssh://git@gitea:22/${REPO_OWNER}/${REPO_NAME}.git"
woodpecker_sql "update repos set clone='${clone_http}', clone_ssh='${clone_ssh}' where full_name='${REPO_OWNER}/${REPO_NAME}';" >/dev/null || true

fix_gitea_webhook() {
    local hooks_json
    local hook_id
    local hook_url
    local target_host
    local new_url

    hooks_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/repos/${REPO_OWNER}/${REPO_NAME}/hooks")
    hook_id=$(echo "$hooks_json" | jq -r '.[] | select(.type=="gitea") | .id' | head -n1)
    hook_url=$(echo "$hooks_json" | jq -r '.[] | select(.type=="gitea") | .config.url' | head -n1)
    if [ -z "$hook_id" ] || [ -z "$hook_url" ]; then
        return
    fi
    target_host="${WEBHOOK_HOST%/}"
    new_url=$(echo "$hook_url" | sed -E "s#^https?://[^/]+#${target_host}#")
    if [ "$new_url" = "$hook_url" ]; then
        return
    fi
    payload=$(jq -n --arg url "$new_url" '{config:{url:$url,content_type:"json"}}')
    curl -s -X PATCH -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Content-Type: application/json" \
        -d "$payload" "${GITEA_URL}/api/v1/repos/${REPO_OWNER}/${REPO_NAME}/hooks/${hook_id}" >/dev/null || true
    log "Updated Gitea webhook URL: ${new_url}"
}

fix_gitea_webhook

create_secret() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]; then
        return
    fi
    local existing
    existing=$(curl -s -H "Authorization: Bearer ${woodpecker_token}" \
        "${WOODPECKER_URL}/api/repos/${repo_id}/secrets" | jq -r --arg name "$name" '.[] | select(.name==$name) | .name' | head -n1)
    if [ -n "$existing" ]; then
        log "Secret ${name} already exists"
        return
    fi
    local payload
    payload=$(jq -n --arg name "$name" --arg value "$value" '{name:$name,value:$value,images:[],events:[]}')
    curl -s -X POST -H "Authorization: Bearer ${woodpecker_token}" -H "Content-Type: application/json" \
        -d "$payload" "${WOODPECKER_URL}/api/repos/${repo_id}/secrets" >/dev/null
    log "Secret ${name} created"
}

gitea_token=""
if [ -f /workspace/.gitea_token ]; then
    gitea_token=$(head -n1 /workspace/.gitea_token | tr -d '\r')
fi
if [ -z "$gitea_token" ]; then
    gitea_token="$ADMIN_PASS"
fi
create_secret "gitea_user" "$ADMIN_USER"
create_secret "gitea_token" "$gitea_token"

log "Woodpecker repo ready: ${REPO_OWNER}/${REPO_NAME}"
