#!/bin/bash

############################################################################
#
#    Agno Modal Teardown
#
#    Usage:
#      ./scripts/modal/down.sh          # asks before destroying
#      ./scripts/modal/down.sh --yes    # no prompt (CI / automation)
#
#    Stops the Modal app (the always-warm container with it) and deletes
#    the Neon Postgres project — all data in the database is deleted. The
#    agentos-secrets Modal secret is deleted too. Verify afterwards with
#    `modal app list` and `neonctl projects list`.
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
RED='\033[31m'
NC='\033[0m'

# Preflight
if ! command -v modal &> /dev/null; then
    echo "modal CLI not found. Install: pip install modal   (then: modal token new)"
    exit 1
fi
if ! command -v neonctl &> /dev/null; then
    echo "neonctl not found. Install: brew install neonctl   (then: neonctl auth)"
    exit 1
fi

# NEON_PROJECT_ID lives in the env file (persisted by up.sh).
NEON_PROJECT_ID="${NEON_PROJECT_ID:-}"
if [[ -z "$NEON_PROJECT_ID" ]]; then
    for f in .env.production .env; do
        if [[ -f "$f" ]]; then
            NEON_PROJECT_ID="$(sed -nE 's/^NEON_PROJECT_ID=(.*)$/\1/p' "$f" | head -1)"
            [[ -n "$NEON_PROJECT_ID" ]] && break
        fi
    done
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Modal Teardown${NC}"
echo ""
echo -e "This destroys:"
echo -e "  - Modal app      agentos (and the agentos-secrets secret)"
if [[ -n "$NEON_PROJECT_ID" ]]; then
    echo -e "  - Neon project   ${NEON_PROJECT_ID}  ${RED}(all data deleted)${NC}"
else
    echo -e "  ${DIM}(no NEON_PROJECT_ID found — the database, if any, must be deleted by hand)${NC}"
fi
echo ""

if [[ "$1" != "--yes" ]]; then
    printf "Type the app name (agentos) to confirm: "
    IFS= read -r CONFIRM
    if [[ "$CONFIRM" != "agentos" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo -e "${DIM}> modal app stop agentos${NC}"
modal app stop agentos \
    || echo -e "${DIM}Stop returned non-zero — verifying below${NC}"
modal secret delete agentos-secrets --yes 2> /dev/null \
    || echo -e "${DIM}Secret already gone or delete needs manual confirm: modal secret delete agentos-secrets${NC}"

if [[ -n "$NEON_PROJECT_ID" ]]; then
    echo ""
    echo -e "${DIM}> neonctl projects delete ${NEON_PROJECT_ID}${NC}"
    neonctl projects delete "$NEON_PROJECT_ID" \
        || echo -e "${DIM}Delete returned non-zero — verifying below${NC}"
fi

# Gone only when the platforms no longer list them.
if modal app list 2> /dev/null | grep -E '\bagentos\b' | grep -qiv stopped; then
    echo ""
    echo -e "${RED}${BOLD}Teardown incomplete${NC} — 'agentos' still shows non-stopped on Modal. Check: modal app list"
    exit 1
fi
if [[ -n "$NEON_PROJECT_ID" ]] && neonctl projects list --output json 2> /dev/null | grep -qF "$NEON_PROJECT_ID"; then
    echo ""
    echo -e "${RED}${BOLD}Teardown incomplete${NC} — Neon project still listed. Check: neonctl projects list"
    exit 1
fi

echo ""
echo -e "${BOLD}Done.${NC} App stopped and database gone. Verify anytime with:"
echo -e "${DIM}  modal app list${NC}"
echo -e "${DIM}  neonctl projects list${NC}"
echo ""
