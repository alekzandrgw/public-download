#!/bin/bash

# Extract home backup archive

set -euo pipefail

SOURCE="/mnt/llsmp-tmp/home_backup.tar.gz"
DEST="/home"

# Retrieve archive via rsync
echo "  Syncing archive to $DEST..."
rsync -ah --progress "$SOURCE" "$DEST/"

# Count files in archive
echo ""
echo "  Counting files..."
FILE_COUNT=$(tar -tzf "$DEST/home_backup.tar.gz" | wc -l)
echo "  Found $FILE_COUNT files"
echo ""

# Extract archive (overwrites matching files, preserves the rest)
echo "  Extracting..."
tar -xzf "$DEST/home_backup.tar.gz" -C "$DEST" --overwrite -v 2>&1 \
    | awk -v total="$FILE_COUNT" '
        /^tar:/ { next }
        {
            count++
            if (count % 50 == 0 || count == total)
                printf "\r  %d / %d - %d%%", count, total, int(count * 100 / total)
        }
        END { printf "\r  %d / %d - 100%%\n", total, total }'

# Clean up
rm -f "$DEST/home_backup.tar.gz"

echo ""
echo "  Done! Files extracted to $DEST"
echo ""
