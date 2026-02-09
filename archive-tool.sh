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
    "*.log"
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
TAR_ERR="/tmp/wp-archive-tar.err"
: > "$TAR_ERR"

set +eo pipefail
(cd "$SOURCE_DIR" && find . "${FIND_EXCLUDES[@]}" -type f -print0 \
    | tar -czf "$OUTPUT_FILE" --null -T - --warning=no-file-changed -v 2>"$TAR_ERR") \
    | awk -v total="$FILE_COUNT" '
        {
            count++
            if (count % 50 == 0 || count == total)
                printf "\r  %d / %d - %d%%", count, total, int(count * 100 / total)
        }
        END { printf "\r  %d / %d - 100%%\n", total, total }'
TAR_EXIT=${PIPESTATUS[0]}
set -eo pipefail

echo ""

# Check for errors
if [[ $TAR_EXIT -ne 0 ]] || [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "  [ERROR] Archive creation failed (exit code: $TAR_EXIT)" >&2
    if [[ -s "$TAR_ERR" ]]; then
        echo "  [ERROR] tar output:" >&2
        sed 's/^/    /' "$TAR_ERR" >&2
    fi
    rm -f "$TAR_ERR"
    exit 1
fi

# Show non-fatal warnings if any
if [[ -s "$TAR_ERR" ]]; then
    echo "  [WARNING] Non-fatal errors during archive creation:"
    sed 's/^/    /' "$TAR_ERR"
    echo ""
fi
rm -f "$TAR_ERR"

ARCHIVE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')

echo "  Done! Archive: $OUTPUT_FILE ($ARCHIVE_SIZE)"
echo ""