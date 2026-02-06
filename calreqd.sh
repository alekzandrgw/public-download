#!/bin/bash
# Calculate required disk space for migration

set -euo pipefail

MOUNT="${1:-/}"

read -r total used free <<< "$(df -BG --output=size,used,avail "$MOUNT" | tail -1 | sed 's/G//g')"

required_total=$((used * 2))
additional=$((required_total - total))
additional=$((additional > 0 ? additional : 0))
final=$((total + additional))

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
echo "    Required total  ${required_total} GB  (${used} × 2)"

if [ "$additional" -eq 0 ]; then
  echo "    Additional      0 GB  (sufficient disk space)"
  echo "    Final disk      ${total} GB  (no changes needed)"
else
  echo "    Additional      ${additional} GB  (${required_total} − ${total} shortfall)"
  echo "    Final disk      ${final} GB  (${total} + ${additional})"
fi

echo ""