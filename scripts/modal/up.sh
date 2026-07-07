#!/bin/bash

############################################################################
#
#    Agno Modal Setup (first-time provisioning)
#
#    Usage:     ./scripts/modal/up.sh
#    Redeploy:  ./scripts/modal/redeploy.sh
#    Sync env:  ./scripts/modal/env-sync.sh
#    Teardown:  ./scripts/modal/down.sh
#
#    Modal has no managed Postgres, so this sibling pairs it with Neon
#    (serverless Postgres with pgvector). up.sh: create the Neon project
#    (once; NEON_PROJECT_ID + DB_* persist to your env file) → write the
#    agentos-secrets Modal secret → `modal deploy` → pin AGENTOS_URL →
#    JWT pause → second deploy carrying the final env.
#
#    Prerequisites:
#      - modal CLI (`pip install modal` or `uv tool install modal`) +
#        `modal token new` completed
#      - neonctl (`npm i -g neonctl` or `brew install neonctl`) +
#        `neonctl auth` completed
#      - OPENAI_API_KEY set in environment (or .env / .env.production)
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${ORANGE}"
cat << 'BANNER'
     █████╗  ██████╗ ███╗   ██╗ ██████╗
    ██╔══██╗██╔════╝ ████╗  ██║██╔═══██╗
    ███████║██║  ███╗██╔██╗ ██║██║   ██║
    ██╔══██║██║   ██║██║╚██╗██║██║   ██║
    ██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝
BANNER
echo -e "${NC}"

persist_env_var() {
    local key="$1" value="$2" file="$3" tmp
    if [[ -z "$file" ]]; then
        return
    fi
    [[ -f "$file" ]] || touch "$file"
    if grep -qE "^[#[:space:]]*${key}=" "$file"; then
        tmp="$(mktemp)"
        if sed -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"; then
            cat "$tmp" > "$file"
        fi
        rm -f "$tmp"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

persist_multiline_env_var() {
    local key="$1" value="$2" file="$3" tmp line skipping=0 value_part
    if [[ -z "$file" ]]; then
        return
    fi
    if [[ ! -f "$file" ]]; then
        printf '%s="%s"\n' "$key" "$value" > "$file"
        return
    fi
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$skipping" == 1 ]]; then
            [[ "$line" == *"-----END"* ]] && skipping=0
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            value_part="${line#*=}"
            if [[ "$value_part" == *"-----BEGIN"* && "$value_part" != *"-----END"* ]]; then
                skipping=1
            fi
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

load_env_file() {
    local line current_key="" current_value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$current_key" ]]; then
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        fi
        if [[ -z "$current_key" ]]; then
            current_key="${line%%=*}"
            current_value="${line#*=}"
        else
            current_value="${current_value}
${line}"
        fi
        if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
            continue
        fi
        current_value="${current_value#\"}"
        current_value="${current_value%\"}"
        current_value="${current_value#\'}"
        current_value="${current_value%\'}"
        export "${current_key}=${current_value}"
        current_key=""
        current_value=""
    done < "$1"
}

capture_pasted_jwt_verification_key() {
    local line pasted="$1"
    pasted="${pasted#export JWT_VERIFICATION_KEY=}"
    pasted="${pasted#JWT_VERIFICATION_KEY=}"
    [[ "$pasted" != *"-----BEGIN"* ]] && return 1
    while [[ "$pasted" != *"-----END"* ]]; do
        if ! IFS= read -r line; then
            break
        fi
        pasted="${pasted}
${line}"
    done
    [[ "$pasted" != *"-----BEGIN"* || "$pasted" != *"-----END"* ]] && return 1
    pasted="${pasted#\"}"
    pasted="${pasted%\"}"
    pasted="${pasted#\'}"
    pasted="${pasted%\'}"
    JWT_VERIFICATION_KEY="$pasted"
    export JWT_VERIFICATION_KEY
}

# (Re)write the agentos-secrets Modal secret from the current environment.
write_modal_secret() {
    local args=(
        "OPENAI_API_KEY=${OPENAI_API_KEY}"
        "RUNTIME_ENV=${RUNTIME_ENV:-prd}"
        "DB_HOST=${DB_HOST}"
        "DB_PORT=${DB_PORT:-5432}"
        "DB_USER=${DB_USER}"
        "DB_PASS=${DB_PASS}"
        "DB_DATABASE=${DB_DATABASE}"
        "PGSSLMODE=require"
    )
    [[ -n "$AGENTOS_URL" ]] && args+=("AGENTOS_URL=${AGENTOS_URL}")
    [[ -n "$JWT_VERIFICATION_KEY" ]] && args+=("JWT_VERIFICATION_KEY=${JWT_VERIFICATION_KEY}")
    [[ -n "$PARALLEL_API_KEY" ]] && args+=("PARALLEL_API_KEY=${PARALLEL_API_KEY}")
    [[ -n "$SLACK_BOT_TOKEN" ]] && args+=("SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}")
    [[ -n "$SLACK_SIGNING_SECRET" ]] && args+=("SLACK_SIGNING_SECRET=${SLACK_SIGNING_SECRET}")
    modal secret create --force agentos-secrets "${args[@]}" > /dev/null
}

ENV_FILE=""
[[ -f .env.production ]] && ENV_FILE=".env.production"
[[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"
if [[ -n "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
    echo -e "${DIM}Loaded ${ENV_FILE}${NC}"
fi

# Preflight
if ! command -v modal &> /dev/null; then
    echo "modal CLI not found. Install: pip install modal   (then: modal token new)"
    exit 1
fi
if ! command -v neonctl &> /dev/null; then
    echo "neonctl not found. Install: brew install neonctl   (then: neonctl auth)"
    exit 1
fi
if ! command -v python3 &> /dev/null; then
    echo "python3 is required (it parses neonctl output)."
    exit 1
fi
if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "OPENAI_API_KEY not set. Add to .env (or .env.production) or export it."
    exit 1
fi
if ! modal app list > /dev/null 2>&1; then
    echo "Modal CLI not authenticated. Run: modal token new"
    exit 1
fi
if ! neonctl me > /dev/null 2>&1; then
    echo "neonctl not authenticated. Run: neonctl auth"
    exit 1
fi

# Neon project — created once; connection facts persist to the env file so
# re-runs (and env-sync/down) reuse them.
if [[ -z "$DB_HOST" || -z "$DB_PASS" ]]; then
    echo ""
    echo -e "${BOLD}Creating Neon Postgres project...${NC}"
    NEON_JSON="$(neonctl projects create --name agentos --output json)"
    eval "$(printf '%s' "$NEON_JSON" | python3 -c '
import json, sys
from urllib.parse import urlparse

d = json.load(sys.stdin)
project_id = d.get("project", {}).get("id", "")
uris = d.get("connection_uris") or []
uri = uris[0]["connection_uri"] if uris else ""
u = urlparse(uri)
print(f"NEON_PROJECT_ID={project_id}")
print(f"DB_HOST={u.hostname or \"\"}")
print(f"DB_PORT={u.port or 5432}")
print(f"DB_USER={u.username or \"\"}")
print(f"DB_PASS={u.password or \"\"}")
print(f"DB_DATABASE={(u.path or \"/\").lstrip(\"/\")}")
')"
    if [[ -z "$DB_HOST" || -z "$DB_PASS" ]]; then
        echo "Couldn't parse the Neon connection URI. Inspect: neonctl projects list"
        exit 1
    fi
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var NEON_PROJECT_ID "$NEON_PROJECT_ID" "$ENV_FILE"
    persist_env_var DB_HOST "$DB_HOST" "$ENV_FILE"
    persist_env_var DB_PORT "$DB_PORT" "$ENV_FILE"
    persist_env_var DB_USER "$DB_USER" "$ENV_FILE"
    persist_env_var DB_PASS "$DB_PASS" "$ENV_FILE"
    persist_env_var DB_DATABASE "$DB_DATABASE" "$ENV_FILE"
    echo -e "${DIM}Neon project ${NEON_PROJECT_ID} (connection saved to ${ENV_FILE})${NC}"
else
    echo -e "${DIM}Reusing database from ${ENV_FILE:-the environment} (DB_HOST set)${NC}"
fi

echo ""
echo -e "${BOLD}Writing Modal secret (agentos-secrets)...${NC}"
write_modal_secret

echo ""
echo -e "${BOLD}Deploying to Modal (first build takes a few minutes)...${NC}"
echo ""
modal deploy modal_app.py

# The URL is stable across redeploys: https://<workspace>--agentos.modal.run
WORKSPACE="$(modal profile current 2> /dev/null | tr -d '[:space:]')"
APP_URL="https://${WORKSPACE}--agentos.modal.run"

if [[ -z "$AGENTOS_URL" ]]; then
    AGENTOS_URL="$APP_URL"
    ENV_FILE="${ENV_FILE:-.env.production}"
    persist_env_var AGENTOS_URL "$AGENTOS_URL" "$ENV_FILE"
    echo -e "${DIM}Set AGENTOS_URL=${AGENTOS_URL}${NC}"
fi

AUTH_REQUIRES_JWT=1
[[ "${RUNTIME_ENV:-prd}" == "dev" ]] && AUTH_REQUIRES_JWT=""

if [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_VERIFICATION_KEY" && -z "$JWT_JWKS_FILE" && -t 0 ]]; then
    echo ""
    echo -e "${BOLD}JWT_VERIFICATION_KEY not set${NC} — AgentOS won't serve production traffic without auth."
    echo -e "  1. Open ${BOLD}https://os.agno.com${NC} -> Connect OS -> Live -> enter ${APP_URL}"
    echo -e "  2. Name it ${BOLD}Live AgentOS${NC}"
    echo -e "  3. Note: Live AgentOS Connections are a paid feature; use ${BOLD}PLATFORM30${NC} to get 1 month off"
    echo -e "  4. Go to Settings -> OS & Security -> turn ${BOLD}Token-Based Authorization (JWT)${NC} on"
    echo -e "  5. Copy the public key"
    echo -e "  6. Paste the full PEM block at the prompt below, or save it in ${ENV_FILE:-.env.production}"
    echo ""
    echo -e "  Paste JWT_VERIFICATION_KEY now, or press Enter after saving it:"
    JWT_INPUT=""
    IFS= read -r JWT_INPUT || true
    if [[ -n "$JWT_INPUT" ]]; then
        if capture_pasted_jwt_verification_key "$JWT_INPUT"; then
            ENV_FILE="${ENV_FILE:-.env.production}"
            persist_multiline_env_var JWT_VERIFICATION_KEY "$JWT_VERIFICATION_KEY" "$ENV_FILE"
            echo -e "${DIM}  Saved JWT_VERIFICATION_KEY to ${ENV_FILE}${NC}"
        else
            echo -e "${BOLD}Warning:${NC} couldn't parse the pasted JWT_VERIFICATION_KEY."
        fi
    fi
    [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] && load_env_file "$ENV_FILE"
fi

if [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_VERIFICATION_KEY" && -z "$JWT_JWKS_FILE" ]]; then
    echo ""
    echo -e "${DIM}No JWT auth config — the app will refuse traffic until you add${NC}"
    echo -e "${DIM}JWT_VERIFICATION_KEY to ${ENV_FILE:-.env.production} and run ./scripts/modal/env-sync.sh.${NC}"
fi

# Second deploy: the secret now carries AGENTOS_URL (+ JWT if minted).
# Secrets are read at container start, so a redeploy applies them.
echo ""
echo -e "${BOLD}Applying final env (second deploy)...${NC}"
write_modal_secret
modal deploy modal_app.py > /dev/null

echo ""
echo -e "${BOLD}Done.${NC}"
echo -e "${DIM}URL:            ${APP_URL}  (docs at /docs, MCP at /mcp)${NC}"
echo -e "${DIM}Logs:           modal app logs agentos${NC}"
echo -e "${DIM}Sync env vars:  ./scripts/modal/env-sync.sh  (defaults to .env.production)${NC}"
[[ -n "$APP_URL" ]] && echo -e "${DIM}Connect apps:   uvx agno connect --url ${APP_URL}  (Claude Desktop + coding agents; mints a service-account token — see README)${NC}"
echo -e "${DIM}Teardown:       ./scripts/modal/down.sh${NC}"
echo ""
