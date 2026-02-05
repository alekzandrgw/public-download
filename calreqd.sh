#!/bin/bash
# Calculate required disk space for migration

set -euo pipefail

MOUNT="${1:-/}"

read -r total used free <<< "$(df -BG --output=size,used,avail "$MOUNT" | tail -1 | sed 's/G//g')"

required=$((used * 2))
additional=$((required - free))
final=$((total + (additional > 0 ? additional : 0)))

C="\033[36m" B="\033[1m" D="\033[2m" R="\033[0m" G="\033[32m" Y="\033[33m" RE="\033[31m"

echo ""
echo -e "${B}  Disk Space Calculator${R}  ${D}($MOUNT)${R}"
echo -e "  ${D}──────────────────────────────${R}"
echo ""
echo -e "  ${D}Current${R}"
echo -e "    Total        ${B}${total} GB${R}"
echo -e "    Used         ${B}${used} GB${R}"
echo -e "    Free         ${B}${free} GB${R}"
echo ""
echo -e "  ${D}Migration requirement${R}"
echo -e "    Required     ${C}${required} GB${R}  ${D}(${used} × 2)${R}"

if [ "$additional" -le 0 ]; then
  echo -e "    Additional   ${G}0 GB${R}  ${D}(sufficient space)${R}"
  echo -e "    Final disk   ${G}${total} GB${R}  ${D}(no changes needed)${R}"
else
  echo -e "    Additional   ${Y}${additional} GB${R}  ${D}(${required} - ${free})${R}"
  echo -e "    Final disk   ${RE}${final} GB${R}  ${D}(${total} + ${additional})${R}"
fi

echo ""
