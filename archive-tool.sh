#!/bin/bash

# Archive /home directory with progress tracking

set -euo pipefail

SOURCE_DIR="/home"
OUTPUT_FILE="/tmp/home_backup.tar.gz"

EXCLUDES=(
    "*/wp-content/cache"
    "*/bb-platform-previews"
    "./litespeed"
    "./jelastic"
    "*/.lscache"
)

# Build exclusion args for find
FIND_EXCLUDES=()
for pattern in "${EXCLUDES[@]}"; do
    FIND_EXCLUDES+=(-path "$pattern" -prune -o)
done

# Count files
echo "  Counting files..."
FILE_COUNT=$(cd "$SOURCE_DIR" && find . "${FIND_EXCLUDES[@]}" -type f -print | wc -l)
echo "  Found $FILE_COUNT files"
echo ""

# Create archive with progress
echo "  Archiving..."
(cd "$SOURCE_DIR" && find . "${FIND_EXCLUDES[@]}" -type f -print0 \
    | tar -czf "$OUTPUT_FILE" --null -T - -v 2>&1) \
    | awk -v total="$FILE_COUNT" '
        /^tar:/ { next }
        {
            count++
            if (count % 50 == 0 || count == total)
                printf "\r  %d / %d - %d%%", count, total, int(count * 100 / total)
        }
        END { printf "\r  %d / %d - 100%%\n", total, total }'

ARCHIVE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')

echo ""
echo "  Done! Archive: $OUTPUT_FILE ($ARCHIVE_SIZE)"
echo ""