#!/bin/bash

# Extract home backup archive

set -euo pipefail

SOURCE="/mnt/llsmp-tmp/home_backup.tar.gz"
DEST="/home"

# Retrieve archive via rsync
echo "  Syncing archive to $DEST..."
rsync -ah --progress "$SOURCE" "$DEST/"

# Extract archive (overwrites matching files, preserves the rest)
echo ""
echo "  Extracting..."
tar -xzf "$DEST/home_backup.tar.gz" -C "$DEST" --overwrite

# Clean up
rm -f "$DEST/home_backup.tar.gz"

echo ""
echo "  Done! Files extracted to $DEST"
echo ""
