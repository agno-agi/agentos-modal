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
