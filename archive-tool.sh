#!/bin/bash

# Archive /home directory with progress tracking
# Uses file count for accurate progress percentage

set -euo pipefail

# Configuration
SOURCE_DIR="/home"
OUTPUT_FILE="/tmp/home_backup.tar.gz"

# Exclusion patterns
EXCLUDES=(
    "*/web/www/*/public/wp-content/cache"
    "*/web/www/*/public/wp-content/uploads/bb-platform-previews"
    "litespeed"
    "jelastic"
    "*/.lscache"
)

echo "========================================"
echo "Home Directory Archive Script"
echo "========================================"
echo "Source: $SOURCE_DIR"
echo "Output: $OUTPUT_FILE"
echo ""

# Check if pv is installed
if ! command -v pv &> /dev/null; then
    echo "ERROR: 'pv' command not found. Installing..."
    yum install pv -y || { echo "Failed to install pv. Please install manually."; exit 1; }
fi

echo "Step 1: Counting files..."
echo ""

# Build find command with exclusions
FIND_CMD="find $SOURCE_DIR"
for pattern in "${EXCLUDES[@]}"; do
    FIND_CMD="$FIND_CMD -path '$pattern' -prune -o"
done
FIND_CMD="$FIND_CMD -type f -print"

# Count total files
FILE_COUNT=$(eval "$FIND_CMD" | wc -l)

echo "Found $FILE_COUNT files to archive"
echo ""
echo "Step 2: Creating compressed archive..."
echo ""

# Build find command for archiving (with null terminator)
FIND_CMD_NULL="find $SOURCE_DIR"
for pattern in "${EXCLUDES[@]}"; do
    FIND_CMD_NULL="$FIND_CMD_NULL -path '$pattern' -prune -o"
done
FIND_CMD_NULL="$FIND_CMD_NULL -type f -print0"

# Create archive with progress
eval "$FIND_CMD_NULL" \
| pv -l -s $FILE_COUNT -p -t -e -r -N "Archiving" \
| tar -czf "$OUTPUT_FILE" --null -T -

echo ""
echo "========================================"
echo "Archive created successfully!"
echo "========================================"
echo "Location: $OUTPUT_FILE"
echo "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
echo ""
echo "To transfer this file, use:"
echo "  cp $OUTPUT_FILE /mnt/destination/"
echo ""
echo "To extract on destination, use:"
echo "  tar -xzf $OUTPUT_FILE -C /home"
echo "========================================"