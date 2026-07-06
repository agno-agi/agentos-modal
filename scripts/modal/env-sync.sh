#!/bin/bash

############################################################################
#
#    Agno Modal Environment Sync
#
#    Usage:
#      ./scripts/modal/env-sync.sh             # syncs .env.production
#      ./scripts/modal/env-sync.sh .env        # syncs .env instead
#
#    Rewrites the agentos-secrets Modal secret from the env file (every
#    non-NEON_* key, plus PGSSLMODE=require for Neon TLS) and redeploys —
#    secrets are read at container start, so the redeploy is what applies
#    them. Multi-line values (PEM-formatted JWT_VERIFICATION_KEY) are
#    handled correctly.
#
############################################################################

set -e

# Colors
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ENV_FILE="${1:-.env.production}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "File not found: $ENV_FILE"
    echo "Usage: $0 [path/to/env] (default: .env.production)"
    exit 1
fi
if ! command -v modal &> /dev/null; then
    echo "modal CLI not found. Install: pip install modal   (then: modal token new)"
    exit 1
fi

echo ""
echo -e "${BOLD}Syncing env vars from ${ENV_FILE} to the agentos-secrets Modal secret...${NC}"
echo ""

# Parse the env file, treating PEM blocks (and other multiline values) as a
# single variable.
SECRET_ARGS=()
count=0
current_key=""
current_value=""

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

    case "$current_key" in
        NEON_*)
            # Provisioning config for the scripts, not app environment.
            ;;
        *)
            echo -e "${DIM}  Setting ${current_key}${NC}"
            SECRET_ARGS+=("${current_key}=${current_value}")
            count=$((count + 1))
            ;;
    esac

    current_key=""
    current_value=""
done < "$ENV_FILE"

if [[ "$count" -eq 0 ]]; then
    echo "Nothing to sync from ${ENV_FILE}."
    exit 1
fi

# Neon requires TLS; libpq honors PGSSLMODE so the portable core needs no change.
SECRET_ARGS+=("PGSSLMODE=require")

modal secret create --force agentos-secrets "${SECRET_ARGS[@]}" > /dev/null

echo ""
echo -e "${BOLD}Redeploying so the running container picks the secret up...${NC}"
modal deploy modal_app.py > /dev/null

echo ""
echo -e "${BOLD}Done.${NC} Synced ${count} variable(s)."
echo ""
