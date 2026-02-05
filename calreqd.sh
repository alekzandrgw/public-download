#!/bin/bash
# Calculate required disk space for migration

set -euo pipefail

MOUNT="${1:-/}"

read -r total used free <<< "$(df -BG --output=size,used,avail "$MOUNT" | tail -1 | sed 's/G//g')"

required=$((used * 2))
additional=$((required - free))
final=$((total + (additional > 0 ? additional : 0)))

echo ""
echo "  Disk Space Calculator  ($MOUNT)"
echo "  ──────────────────────────────"
echo ""
echo "  Current"
echo "    Total        ${total} GB"
echo "    Used         ${used} GB"
echo "    Free         ${free} GB"
echo ""
echo "  Migration requirement"
echo "    Required     ${required} GB  (${used} × 2)"

if [ "$additional" -le 0 ]; then
  echo "    Additional   0 GB  (sufficient space)"
  echo "    Final disk   ${total} GB  (no changes needed)"
else
  echo "    Additional   ${additional} GB  (${required} - ${free})"
  echo "    Final disk   ${final} GB  (${total} + ${additional})"
fi

echo ""
