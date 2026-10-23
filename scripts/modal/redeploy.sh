#!/bin/bash

############################################################################
#
#    Agno Modal Redeploy
#
#    Usage: ./scripts/modal/redeploy.sh
#
#    Redeploys the app: Modal rebuilds the image from the Dockerfile
#    (cached layers where nothing changed) and rolls the always-warm
#    container. Run ./scripts/modal/up.sh first for initial provisioning.
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

if ! command -v modal &> /dev/null; then
    echo "modal CLI not found. Install: pip install modal   (then: modal token new)"
    exit 1
fi
if ! modal app list > /dev/null 2>&1; then
    echo "Modal CLI not authenticated. Run: modal token new"
    exit 1
fi

# modal_app.py reads AGENTOS_CHECKPOINTS at deploy time; carry the env file's
# setting so a redeploy never silently drops the /data volume.
ENV_FILE=""
[[ -f .env.production ]] && ENV_FILE=".env.production"
[[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"
if [[ -n "$ENV_FILE" && -z "$AGENTOS_CHECKPOINTS" ]]; then
    AGENTOS_CHECKPOINTS="$(sed -nE 's/^AGENTOS_CHECKPOINTS=//p' "$ENV_FILE" | tr -d "\"'" | head -1)"
fi
export AGENTOS_CHECKPOINTS

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Redeploying agentos${NC}"
echo ""
echo -e "${DIM}> modal deploy modal_app.py::modal_app${NC}"
echo ""
modal deploy modal_app.py::modal_app

echo ""
echo -e "${BOLD}Done.${NC}"
echo -e "${DIM}Logs: modal app logs agentos${NC}"
echo ""
