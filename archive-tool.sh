#!/bin/bash

# Archive /home directory with progress tracking

set -euo pipefail

SOURCE_DIR="/home"
OUTPUT_FILE="/tmp/home_backup.tar.gz"

EXCLUDES=(
    "*/web/www/*/public/wp-content/cache"
    "*/web/www/*/public/wp-content/uploads/bb-platform-previews"
    "litespeed"
    "jelastic"
    "*/.lscache"
)

echo ""
echo "  Home Directory Archive"
echo ""

# Ensure pv is available
if ! command -v pv &> /dev/null; then
    echo "  Installing pv..."
    yum install pv -y -q || { echo "  Failed to install pv."; exit 1; }
fi

# Build exclusion args for find
FIND_EXCLUDES=()
for pattern in "${EXCLUDES[@]}"; do
    FIND_EXCLUDES+=(-path "$pattern" -prune -o)
done

# Count files
echo "  Counting files..."
FILE_COUNT=$(find "$SOURCE_DIR" "${FIND_EXCLUDES[@]}" -type f -print | wc -l)
echo "  Found $FILE_COUNT files"
echo ""

# Create archive with progress bar
echo "  Archiving..."
find "$SOURCE_DIR" "${FIND_EXCLUDES[@]}" -type f -print0 \
    | pv -l -s "$FILE_COUNT" -p -t -e -N "  Progress" \
    | tar -czf "$OUTPUT_FILE" --null -T -

ARCHIVE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')

echo ""
echo "  Done! Archive: $OUTPUT_FILE ($ARCHIVE_SIZE)"
echo ""