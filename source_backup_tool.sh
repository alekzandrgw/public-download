#!/bin/bash

# public-download/source_backup_tool.sh
# Backup tool for WordPress sites, inspired by webs-dev.sh

set -euo pipefail

# CONFIGURATION
WP_PATH="/var/www/webroot/ROOT"
WP_CLI="/home/litespeed/bin/wp"
BACKUP_DIR="$HOME/wp_backups"
DATE=$(date +"%Y%m%d_%H%M%S")
DB_DUMP="$BACKUP_DIR/db_backup_$DATE.sql"
WEB_ARCHIVE="$BACKUP_DIR/web_backup_$DATE.tar.gz"
EXCLUDES=(
    --exclude="*.log"
    --exclude="wp-content/uploads/cache"
    --exclude="wp-content/ai1wm-backups"
    --exclude="wp-content/backups"
    --exclude="wp-content/backups-dup-pro"
    --exclude="wp-content/updraft"
    --exclude="wp-content/uploads/backup-*"
    --exclude="wp-content/uploads/backwpup-*"
    --exclude="wp-content/cache"
    --exclude="wp-content/uploads/cache"
    --exclude="wp-content/w3tc-cache"
    --exclude="wp-content/wp-rocket-cache"
    --exclude="wp-content/litespeed"
    --exclude="wp-content/debug.log"
    --exclude="wp-content/error_log"
    --exclude="wp-config-backup.php"
    --exclude="error_log"
    --exclude="wp-content/uploads/wp-file-manager-pro/fm_backup"
)
MIN_SCREEN_SIZE_GB=10

mkdir -p "$BACKUP_DIR"

cd "$WP_PATH"

# Add color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

prompt() {
    echo -e "${CYAN}$1${NC}"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Check requirements
if [[ ! -f "$WP_CLI" ]]; then
    error "WP-CLI not found at $WP_CLI"
    exit 1
fi

if [[ ! -f "$WP_PATH/wp-config.php" ]]; then
    error "WordPress installation not found at $WP_PATH"
    exit 1
fi

# Check if numfmt exists
if ! command -v numfmt >/dev/null 2>&1; then
    numfmt() { cat; }  # Fallback if numfmt not available
fi

# Make temp files unique to this run
TMP_PREFIX="/tmp/wp-backup-${DATE}"
TMP_DB_EXPORT="${TMP_PREFIX}-db.sql"
TMP_DB_ERR="${TMP_PREFIX}-db.err"

# 1. Site Details
log "Gathering site details..."

SITE_URL=$($WP_CLI option get siteurl --allow-root --skip-plugins --skip-themes) || { error "Failed to get site URL. Check WP_CLI path and permissions."; exit 1; }
DB_CHARSET=$($WP_CLI eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes 2>/dev/null | tr -d '\n' || echo "utf8")
WEB_SIZE=$(du -sh . | awk '{print $1}')
DB_SIZE_BYTES=$($WP_CLI db size --allow-root --size_format=b --skip-plugins --skip-themes --quiet) || { echo "Failed to get DB size."; exit 1; }
DB_SIZE=$(numfmt --to=iec $DB_SIZE_BYTES)
TOTAL_SIZE_BYTES=$(($(du -sb . | awk '{print $1}') + $DB_SIZE_BYTES))
TOTAL_SIZE=$(numfmt --to=iec $TOTAL_SIZE_BYTES)

# BuddyBoss checks
BB_APP_INSTALLED=$($WP_CLI plugin list --allow-root --skip-plugins --skip-themes | grep -q "buddyboss-app" && echo "yes" || echo "no")
BB_THEME_INSTALLED=$($WP_CLI theme list --allow-root --skip-plugins --skip-themes | grep -q "buddyboss-theme" && echo "yes" || echo "no")

info "Site Details:"
echo "  Site URL: $SITE_URL"
echo "  Database Charset: $DB_CHARSET"
echo "  Web Files Size: $WEB_SIZE"
echo "  Database Size: $DB_SIZE"
echo "  Total Estimated Site Size: $TOTAL_SIZE"
echo "  BuddyBoss App Plugin: $BB_APP_INSTALLED"
echo "  BuddyBoss Theme: $BB_THEME_INSTALLED"

if [[ "$BB_APP_INSTALLED" == "yes" ]]; then
    BB_APP_ID=$($WP_CLI option pluck bbapps bbapp_app_id --allow-root --skip-plugins --skip-themes)
    BB_APP_KEY=$($WP_CLI option pluck bbapps bbapp_app_key --allow-root --skip-plugins --skip-themes)
    echo "BuddyBoss App ID: $BB_APP_ID"
    echo "BuddyBoss App Key: $BB_APP_KEY"
fi

# 2. Disk Analysis
log "Analyzing disk space..."
AVAIL_DISK_BYTES=$(df --output=avail . | tail -1)
REQUIRED_BYTES=$(echo "$TOTAL_SIZE_BYTES * 1.1" | bc | awk '{print int($1)}')
REQUIRED_HR=$(numfmt --to=iec $REQUIRED_BYTES)
AVAIL_HR=$(numfmt --to=iec $AVAIL_DISK_BYTES)

if (( AVAIL_DISK_BYTES < REQUIRED_BYTES )); then
    warning "Not enough disk space."
    error "Available: $AVAIL_HR, Required: $REQUIRED_HR"
    error "Please add at least $(numfmt --to=iec $((REQUIRED_BYTES - AVAIL_DISK_BYTES))) more disk space."
    exit 1
fi

# Screen detection
if [[ -z "$STY" && -z "$TMUX" && $((TOTAL_SIZE_BYTES/1024/1024/1024)) -ge $MIN_SCREEN_SIZE_GB ]]; then
    warning "Site is larger than ${MIN_SCREEN_SIZE_GB}GB."
    warning "It is recommended to run this script inside a screen session:"
    info "  screen -S wpbackup"
    warning "Then re-run this script inside the screen session."
    prompt "Continue anyway? [Y/N] - Default [N]: "
    read -r CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
fi

# 3. Maintenance Mode
if [[ "$BB_APP_INSTALLED" == "yes" || "$BB_THEME_INSTALLED" == "yes" ]]; then
    prompt "Enable BuddyBoss Theme's maintenance mode? [Y/N] - Default [Y]: "
    read -r ENABLE_BB_THEME
    ENABLE_BB_THEME=${ENABLE_BB_THEME:-Y}
    if [[ "$ENABLE_BB_THEME" =~ ^[Yy]$ && "$BB_THEME_INSTALLED" == "yes" ]]; then
        $WP_CLI option patch update buddyboss_theme_options maintenance_mode 1 --allow-root --skip-themes --skip-plugins
        MODE=$($WP_CLI option pluck buddyboss_theme_options maintenance_mode --allow-root --skip-themes --skip-plugins)
        if [[ "$MODE" != "1" ]]; then
            error "Failed to enable BuddyBoss Theme maintenance mode."
            exit 1
        fi
        success "BuddyBoss Theme maintenance mode enabled."
    fi

    prompt "Enable BuddyBoss App's maintenance mode? [Y/N] - Default [Y]: "
    read -r ENABLE_BB_APP
    ENABLE_BB_APP=${ENABLE_BB_APP:-Y}
    if [[ "$ENABLE_BB_APP" =~ ^[Yy]$ && "$BB_APP_INSTALLED" == "yes" ]]; then
        $WP_CLI option patch update bbapp_settings app_maintenance_mode 1 --allow-root --skip-themes --skip-plugins
        MODE=$($WP_CLI option pluck bbapp_settings app_maintenance_mode --allow-root --skip-themes --skip-plugins)
        if [[ "$MODE" != "1" ]]; then
            error "Failed to enable BuddyBoss App maintenance mode."
            exit 1
        fi
        success "BuddyBoss App maintenance mode enabled."
    fi
else
    prompt "Set WordPress in maintenance mode? [Y/N] - Default [Y]: "
    read -r ENABLE_WP_MAINT
    ENABLE_WP_MAINT=${ENABLE_WP_MAINT:-Y}
    if [[ "$ENABLE_WP_MAINT" =~ ^[Yy]$ ]]; then
        $WP_CLI plugin install simple-maintenance --activate --allow-root --skip-themes --skip-plugins
        ACTIVE=$($WP_CLI plugin is-active simple-maintenance --allow-root --skip-themes --skip-plugins && echo "active" || echo "inactive")
        if [[ "$ACTIVE" != "active" ]]; then
            error "Failed to activate maintenance mode plugin."
            exit 1
        fi
        success "WordPress maintenance mode enabled."
    fi
fi

# 4. Database Export
log "Exporting database..."

"$WP_CLI" db export "$TMP_DB_EXPORT" --default-character-set="$DB_CHARSET" --allow-root --skip-plugins --skip-themes --quiet --force 2>"$TMP_DB_ERR" || true &
export_pid=$!

while kill -0 $export_pid 2>/dev/null; do
    if [[ -f "$TMP_DB_EXPORT" ]]; then
        current_size=$(stat -c%s "$TMP_DB_EXPORT" 2>/dev/null || echo "0")
        echo -ne "\r${BLUE}[INFO]${NC} Current DB export size: $(numfmt --to=iec $current_size)     "
    fi
    sleep 2
done
echo

wait $export_pid
EXPORT_STATUS=$?

if [[ $EXPORT_STATUS -ne 0 || ! -s "$TMP_DB_EXPORT" ]]; then
    error "Database export failed."
    [[ -f "$TMP_DB_ERR" ]] && cat "$TMP_DB_ERR"
    exit 1
fi

mv "$TMP_DB_EXPORT" "$DB_DUMP"
rm -f "$TMP_DB_ERR"
success "Database exported to $DB_DUMP"

# 5. Web Files Compression
log "Compressing web files..."
if ! tar czf "$WEB_ARCHIVE" "${EXCLUDES[@]}" .; then
    error "Failed to create archive"
    exit 1
fi
success "Web files archived to $WEB_ARCHIVE"

# 6. Summary
echo
echo "==============================================================="
info "              *** BACKUP COMPLETED SUCCESSFULLY ***"
echo "==============================================================="
echo
echo ">> Backup Details:"
echo "   - Site URL: $SITE_URL"
echo "   - Database Dump: $DB_DUMP"
echo "   - Web Archive: $WEB_ARCHIVE"
echo "   - Database Size: $DB_SIZE"
echo "   - Total Size: $TOTAL_SIZE"
if [[ "$BB_APP_INSTALLED" == "yes" ]]; then
    echo "   - BuddyBoss App ID: $BB_APP_ID"
    echo "   - BuddyBoss App Key: $BB_APP_KEY"
fi
echo "==============================================================="

# Clean up temp files
cleanup() {
    log "Cleaning up temporary files..."
    rm -f "${TMP_PREFIX}"*
    success "Temporary files cleaned up"
}

# Register cleanup on script exit
trap cleanup EXIT