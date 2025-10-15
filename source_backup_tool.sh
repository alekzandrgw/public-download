#!/bin/bash

#===============================================================
#                V3 Transition - Backup Tool
#===============================================================
# Description: Creates WordPress Site Backups from V1
# Author: Alexander Gil
# Version: 1.0
#===============================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
WP_PATH=""
SITE_URL=""
DB_CHARSET=""
BACKUP_DIR=""
DATE=$(date +"%Y%m%d_%H%M%S")
DB_DUMP=""
WEB_ARCHIVE=""
TEMP_FILES=""
WP_CLI="/home/litespeed/bin/wp"
MIN_SCREEN_SIZE_GB=10
MAINTENANCE_MODE_ENABLED=false
MAINTENANCE_TYPE=""
DISABLE_MAINTENANCE_ON_EXIT=false

# Site configuration variables
CUSTOM_LOGIN_URL=""
BB_APP_ID=""
BB_APP_KEY=""
CRON_JOBS=""
CUSTOM_PHP_INI=""
PHP_INI_PATH="/usr/local/lsws/lsphp/etc/php.d/998-rapyd.ini"
CRON_USER="litespeed"

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

# Function to read input with validation
read_input() {
    local prompt_text="$1"
    local variable_name="$2"
    local is_secret="${3:-false}"
    local validation_func="${4:-}"
    local allow_empty="${5:-false}"
    
    while true; do
        if [[ "$is_secret" == "true" ]]; then
            prompt "$prompt_text"
            read -s input
            echo  # Add newline after secret input
        else
            prompt "$prompt_text"
            read input
        fi
        
        if [[ -z "$input" ]] && [[ "$allow_empty" != "true" ]]; then
            error "This field cannot be empty. Please try again."
            continue
        fi
        
        # Run validation function if provided (only if input is not empty)
        if [[ -n "$input" ]] && [[ -n "$validation_func" ]] && ! $validation_func "$input"; then
            continue
        fi
        
        # Set the variable
        declare -g "$variable_name"="$input"
        break
    done
}

# Check if running in screen session
is_in_screen() {
    [[ -n "${STY:-}" ]] || [[ -n "${TMUX:-}" ]]
}

# Validation functions
validate_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "Directory '$dir' does not exist"
        return 1
    fi
    if [[ ! -f "$dir/wp-config.php" ]]; then
        error "WordPress installation not found at '$dir'"
        return 1
    fi
    return 0
}

check_disk_space() {
    # Get WordPress directory size
    local wp_size=$(du -sb "$WP_PATH" 2>/dev/null | cut -f1 || echo "0")
    
    # Get database size estimate
    local db_size=0
    db_size=$("$WP_CLI" db size --allow-root --skip-plugins --skip-themes --size_format=b --quiet 2>/dev/null | grep -oP '^\d+' || echo "0")
    
    local total_size=$((wp_size + db_size))
    local required_space=$((total_size * 110 / 100))  # Add 10% buffer
    
    # Get available space on the partition containing WP_PATH
    local available_space=$(df -B1 "$WP_PATH" | awk 'NR==2 {print $4}')
    
    # Display sizes
    echo
    info "=== Disk Space Analysis ==="
    echo "WordPress files size: $(numfmt --to=iec $wp_size)"
    echo "Database size (est.): $(numfmt --to=iec $db_size)"
    echo "Total backup size: $(numfmt --to=iec $total_size)"
    echo "Required space (with 10% buffer): $(numfmt --to=iec $required_space)"
    echo "Available disk space: $(numfmt --to=iec $available_space)"
    
    # Check if site is larger than 10GB
    local ten_gb=$((10 * 1024 * 1024 * 1024))
    if [[ $total_size -gt $ten_gb ]]; then
        echo
        warning "*** Large site detected (>10GB)!"
        echo
        
        if ! is_in_screen; then
            warning "You are NOT running in a screen/tmux session."
            warning "For large backups, it's recommended to run this in screen to prevent interruption."
            echo
            prompt "Do you want to continue anyway? (y/N): "
            read -r continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                error "Backup cancelled. Please run this script in a screen session:"
                error "  screen -S backup"
                error "  ./wordpress_backup.sh"
                exit 1
            fi
        else
            success "Running in screen/tmux session - good for large backups!"
        fi
    fi
    
    # Check if enough space is available
    if [[ $available_space -lt $required_space ]]; then
        local needed=$((required_space - available_space))
        echo
        error "*** INSUFFICIENT DISK SPACE!"
        error "You need $(numfmt --to=iec $needed) more disk space to safely complete this backup."
        error ""
        error "Please free up disk space or add more storage before proceeding."
        echo
        prompt "Do you want to continue anyway? (NOT RECOMMENDED) (y/N): "
        read -r force_continue
        if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
            exit 1
        fi
        warning "Continuing with insufficient space - backup may fail!"
    else
        success "Sufficient disk space available"
    fi
}

collect_configuration() {
    echo
    info "=== WordPress Local Backup Configuration ==="
    echo
    
    # WordPress Configuration
    info "WordPress Configuration:"
    read_input "Enter WordPress root directory path [/var/www/webroot/ROOT]: " "input" "false" "" "true"
    WP_PATH="${input:-/var/www/webroot/ROOT}"
    validate_directory "$WP_PATH" || exit 1
    
    log "Analyzing WordPress installation and disk space requirements..."
    
    # Change to WordPress directory
    cd "$WP_PATH" || exit 1
    
    if ! "$WP_CLI" core is-installed --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null; then
        error "WordPress not installed in '$WP_PATH'"
        exit 1
    fi
    
    success "WordPress installation detected"
    
    # Get site information
    SITE_URL=$("$WP_CLI" option get siteurl --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | sed 's|https\?://||')
    DB_CHARSET=$("$WP_CLI" eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | tr -d '\n')
    
    # Get custom login URL if exists
    CUSTOM_LOGIN_URL=$("$WP_CLI" option get whl_page --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null || echo "")
    
    echo
    info "=== WordPress Information ==="
    echo "Site URL: $SITE_URL"
    echo "Database charset: $DB_CHARSET"
    if [[ -n "$CUSTOM_LOGIN_URL" ]]; then
        echo "Login URL: /$CUSTOM_LOGIN_URL (custom)"
    else
        echo "Login URL: /wp-admin (default)"
    fi
    
    # Check for BuddyBoss and display info
    check_buddyboss_info
    
    # Check disk space
    check_disk_space
    
    echo
    # Calculate default backup directory (one level up from WP_PATH)
    local parent_dir=$(dirname "$WP_PATH")
    local default_backup_dir="$parent_dir/v1_backups"
    
    read_input "Enter backup directory path [$default_backup_dir]: " "input" "false" "" "true"
    BACKUP_DIR="${input:-$default_backup_dir}"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Set backup file paths
    DB_DUMP="$BACKUP_DIR/db_backup.sql"
    WEB_ARCHIVE="$BACKUP_DIR/web_backup.tar.gz"
}

cleanup() {
    echo
    log "Performing cleanup..."
    
    # Disable maintenance mode if it was enabled AND user requested it
    if [[ "$MAINTENANCE_MODE_ENABLED" == "true" ]] && [[ "$DISABLE_MAINTENANCE_ON_EXIT" == "true" ]]; then
        disable_maintenance_mode
    elif [[ "$MAINTENANCE_MODE_ENABLED" == "true" ]]; then
        info "Maintenance mode left enabled as requested"
    fi
    
    # Clean up temporary files
    if [[ -n "$TEMP_FILES" ]]; then
        rm -f $TEMP_FILES 2>/dev/null || true
        success "Removed temporary files"
    fi
    
    log "Cleanup completed"
}

# Set up cleanup trap
trap cleanup EXIT

check_prerequisites() {
    log "Checking prerequisites..."
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    if [[ ! -f "$WP_CLI" ]]; then
        error "WP-CLI not found at $WP_CLI"
        exit 1
    fi
    
    # Check if numfmt exists
    if ! command -v numfmt &> /dev/null; then
        error "numfmt command not found (part of coreutils)"
        exit 1
    fi
    
    success "Prerequisites check passed"
    echo ""
}

check_buddyboss_info() {
    local bb_app_installed=$("$WP_CLI" plugin list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-app" && echo "yes" || echo "no")
    local bb_theme_installed=$("$WP_CLI" theme list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-theme" && echo "yes" || echo "no")
    
    if [[ "$bb_app_installed" == "yes" ]] || [[ "$bb_theme_installed" == "yes" ]]; then
        echo
        info "=== BuddyBoss Installation Found ==="
        echo "BuddyBoss App Plugin: $bb_app_installed"
        echo "BuddyBoss Theme: $bb_theme_installed"
        
        if [[ "$bb_app_installed" == "yes" ]]; then
            BB_APP_ID=$("$WP_CLI" option pluck bbapps bbapp_app_id --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null || echo "N/A")
            BB_APP_KEY=$("$WP_CLI" option pluck bbapps bbapp_app_key --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null || echo "N/A")
            echo "BuddyBoss App ID: $BB_APP_ID"
            echo "BuddyBoss App Key: $BB_APP_KEY"
        fi
    fi
}

check_buddyboss_installation() {
    local bb_app_installed=$("$WP_CLI" plugin list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-app" && echo "yes" || echo "no")
    local bb_theme_installed=$("$WP_CLI" theme list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-theme" && echo "yes" || echo "no")
    
    # Return status for maintenance mode decision
    if [[ "$bb_app_installed" == "yes" ]] || [[ "$bb_theme_installed" == "yes" ]]; then
        return 0  # BuddyBoss detected
    else
        return 1  # No BuddyBoss
    fi
}

check_multisite() {
    if "$WP_CLI" config has MULTISITE --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null; then
        echo "Yes"
    else
        echo "No"
    fi
}

get_multisite_domains() {
    # Only get domains if it's a multisite installation
    if [[ "$(check_multisite)" == "Yes" ]]; then
        "$WP_CLI" site list --allow-root --skip-plugins --skip-themes --fields=url --format=json --quiet 2>/dev/null \
            | jq -r '.[].url' \
            | sed -E 's|https?://||;s|/||g' \
            | paste -sd,
    else
        echo ""
    fi
}

enable_maintenance_mode() {
    echo
    
    # Always check for BuddyBoss components first
    local bb_app_installed=$("$WP_CLI" plugin list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-app" && echo "yes" || echo "no")
    local bb_theme_installed=$("$WP_CLI" theme list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-theme" && echo "yes" || echo "no")
    
    if [[ "$bb_app_installed" == "yes" ]] || [[ "$bb_theme_installed" == "yes" ]]; then
        # BuddyBoss detected
        
        if [[ "$bb_theme_installed" == "yes" ]]; then
            prompt "Enable BuddyBoss Theme's maintenance mode? (Y/N) [Default: Y]: "
            read -r enable_bb_theme
            enable_bb_theme=${enable_bb_theme:-Y}
            
            if [[ "$enable_bb_theme" =~ ^[Yy]$ ]]; then
                "$WP_CLI" option patch update buddyboss_theme_options maintenance_mode 1 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
                local mode=$("$WP_CLI" option pluck buddyboss_theme_options maintenance_mode --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null || echo "0")
                
                if [[ "$mode" == "1" ]]; then
                    success "BuddyBoss Theme maintenance mode enabled"
                    echo ""
                    MAINTENANCE_MODE_ENABLED=true
                    MAINTENANCE_TYPE="bb_theme"
                else
                    warning "Failed to enable BuddyBoss Theme maintenance mode"
                fi
            fi
        fi
        
        if [[ "$bb_app_installed" == "yes" ]]; then
            echo  # Add blank line before App prompt
            prompt "Enable BuddyBoss App's maintenance mode? (Y/N) [Default: Y]: "
            read -r enable_bb_app
            enable_bb_app=${enable_bb_app:-Y}
            
            if [[ "$enable_bb_app" =~ ^[Yy]$ ]]; then
                "$WP_CLI" option patch update bbapp_settings app_maintenance_mode 1 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
                local mode=$("$WP_CLI" option pluck bbapp_settings app_maintenance_mode --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null || echo "0")
                
                if [[ "$mode" == "1" ]]; then
                    success "BuddyBoss App maintenance mode enabled"
                    echo
                    MAINTENANCE_MODE_ENABLED=true
                    if [[ "$MAINTENANCE_TYPE" == "bb_theme" ]]; then
                        MAINTENANCE_TYPE="bb_both"
                    else
                        MAINTENANCE_TYPE="bb_app"
                    fi
                else
                    warning "Failed to enable BuddyBoss App maintenance mode"
                fi
            fi
        fi
    else
        # Standard WordPress
        prompt "Set WordPress in maintenance mode? (Y/N) [Default: Y]: "
        read -r enable_wp_maint
        enable_wp_maint=${enable_wp_maint:-Y}
        
        if [[ "$enable_wp_maint" =~ ^[Yy]$ ]]; then
            "$WP_CLI" plugin install simple-maintenance --activate --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
            local active=$("$WP_CLI" plugin is-active simple-maintenance --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null && echo "active" || echo "inactive")
            
            if [[ "$active" == "active" ]]; then
                success "WordPress maintenance mode enabled"
                MAINTENANCE_MODE_ENABLED=true
                MAINTENANCE_TYPE="wp_simple"
            else
                warning "Failed to activate maintenance mode plugin"
            fi
        fi
    fi
    
    # Ask if maintenance mode should be disabled after backup
    if [[ "$MAINTENANCE_MODE_ENABLED" == "true" ]]; then
        prompt "Disable maintenance mode after backup completes? (y/N) [Default: N]: "
        read -r disable_maintenance
        if [[ "$disable_maintenance" =~ ^[Yy]$ ]]; then
            DISABLE_MAINTENANCE_ON_EXIT=true
            info "Maintenance mode will be disabled after backup"
        else
            DISABLE_MAINTENANCE_ON_EXIT=false
            info "Maintenance mode will remain enabled after backup"
        fi
    fi
}

disable_maintenance_mode() {
    log "Disabling maintenance mode..."
    
    case "$MAINTENANCE_TYPE" in
        bb_theme)
            "$WP_CLI" option patch update buddyboss_theme_options maintenance_mode 0 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
            success "BuddyBoss Theme maintenance mode disabled"
            ;;
        bb_app)
            "$WP_CLI" option patch update bbapp_settings app_maintenance_mode 0 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
            success "BuddyBoss App maintenance mode disabled"
            ;;
        bb_both)
            "$WP_CLI" option patch update buddyboss_theme_options maintenance_mode 0 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
            "$WP_CLI" option patch update bbapp_settings app_maintenance_mode 0 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
            success "BuddyBoss maintenance modes disabled"
            ;;
        wp_simple)
            "$WP_CLI" plugin deactivate simple-maintenance --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null || true
            success "WordPress maintenance mode disabled"
            ;;
    esac
}

export_database() {
    log "Exporting database..."
    
    cd "$WP_PATH" || {
        error "Failed to access WordPress directory '$WP_PATH'"
        exit 1
    }

    # Read DB creds from wp-config.php
    local WP_CONF="wp-config.php"
    if [[ ! -f "$WP_CONF" ]]; then
        error "wp-config.php not found in $WP_PATH"
        exit 1
    fi

    # Extract defines from wp-config.php
    extract_wp_define() {
        local key="$1"
        grep -E "define\(\s*['\"]${key}['\"]" "$WP_CONF" \
          | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/" \
          | tr -d '\r' | head -n1
    }

    local DB_NAME DB_USER DB_PASSWORD DB_HOST
    DB_NAME=$(extract_wp_define "DB_NAME")
    DB_USER=$(extract_wp_define "DB_USER")
    DB_PASSWORD=$(extract_wp_define "DB_PASSWORD")
    DB_HOST=$(extract_wp_define "DB_HOST")

    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_HOST" ]]; then
        error "Failed to read DB credentials from wp-config.php"
        exit 1
    fi

    local HOST_OPT="" PORT_OPT="" SOCKET_OPT=""
    if [[ "$DB_HOST" == /* ]]; then
        SOCKET_OPT="--socket=$DB_HOST"
    elif [[ "$DB_HOST" == *":"* ]]; then
        local host_part="${DB_HOST%%:*}"
        local rest="${DB_HOST#*:}"
        if [[ "$rest" =~ ^[0-9]+$ ]]; then
            HOST_OPT="--host=$host_part"; PORT_OPT="--port=$rest"
        elif [[ "$rest" == /* ]]; then
            SOCKET_OPT="--socket=$rest"
        else
            HOST_OPT="--host=$DB_HOST"
        fi
    else
        HOST_OPT="--host=$DB_HOST"
    fi

    local OUT_SQL="$DB_DUMP"
    local ERR_LOG="$BACKUP_DIR/log-db-export.err"
    : > "$ERR_LOG"
    
    # Add error log to temp files for cleanup
    TEMP_FILES="$TEMP_FILES $ERR_LOG"

    local GTID_ARG=""
    mysqldump --help 2>/dev/null | grep -q -- "--set-gtid-purged" && GTID_ARG="--set-gtid-purged=OFF"
    local COLSTAT_ARG=""
    mysqldump --help 2>/dev/null | grep -q -- "--column-statistics" && COLSTAT_ARG="--column-statistics=0"

    local BASE_ARGS=(
        --user="$DB_USER"
        --default-character-set="${DB_CHARSET:-utf8mb4}"
        --single-transaction
        --quick
        --hex-blob
        --skip-lock-tables
        --triggers
        --routines
        --events
        --max-allowed-packet=512M
        --net-buffer-length=1048576
        --add-drop-table
        --skip-comments
        --no-tablespaces
    )
    [[ -n "$HOST_OPT"   ]] && BASE_ARGS+=("$HOST_OPT")
    [[ -n "$PORT_OPT"   ]] && BASE_ARGS+=("$PORT_OPT")
    [[ -n "$SOCKET_OPT" ]] && BASE_ARGS+=("$SOCKET_OPT")
    [[ -n "$GTID_ARG"   ]] && BASE_ARGS+=("$GTID_ARG")
    [[ -n "$COLSTAT_ARG" ]] && BASE_ARGS+=("$COLSTAT_ARG")

    set +e
    MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" > "$OUT_SQL" 2>>"$ERR_LOG" &
    local dump_pid=$!

    while kill -0 $dump_pid 2>/dev/null; do
        if [[ -f "$OUT_SQL" ]]; then
            local current_size
            current_size=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
            echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $current_size)     "
        fi
        sleep 2
    done

    wait $dump_pid
    local exit_status=$?
    set -e
    echo 

    # fallback
    if [[ $exit_status -ne 0 || ! -s "$OUT_SQL" ]]; then
        warning "Initial dump failed (see $ERR_LOG). Retrying without routines/events…"
        rm -f "$OUT_SQL"

        local SAFE_ARGS=(
            --user="$DB_USER"
            --default-character-set="${DB_CHARSET:-utf8mb4}"
            --single-transaction
            --quick
            --hex-blob
            --skip-lock-tables
            --triggers
            --max-allowed-packet=512M
            --net-buffer-length=1048576
            --add-drop-table
            --skip-comments
            --no-tablespaces
        )
        [[ -n "$HOST_OPT"    ]] && SAFE_ARGS+=("$HOST_OPT")
        [[ -n "$PORT_OPT"    ]] && SAFE_ARGS+=("$PORT_OPT")
        [[ -n "$SOCKET_OPT"  ]] && SAFE_ARGS+=("$SOCKET_OPT")
        [[ -n "$COLSTAT_ARG" ]] && SAFE_ARGS+=("$COLSTAT_ARG")

        set +e
        MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" > "$OUT_SQL" 2>>"$ERR_LOG" &
        dump_pid=$!

        while kill -0 $dump_pid 2>/dev/null; do
            if [[ -f "$OUT_SQL" ]]; then
                local current_size2
                current_size2=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
                echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $current_size2)     "
            fi
            sleep 2
        done

        wait $dump_pid
        exit_status=$?
        set -e
        echo

        if [[ $exit_status -ne 0 || ! -s "$OUT_SQL" ]]; then
            error "Database export failed. See $ERR_LOG"
            exit 1
        fi
    fi

    local db_size
    db_size=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
    success "Database exported successfully ($(numfmt --to=iec $db_size))"
    echo
}

create_archive() {
    log "Creating website archive..."
    
    # Get directory size for progress estimation
    local webroot_size=$(du -sb "$WP_PATH" 2>/dev/null | cut -f1 || echo "0")
    info "Archiving $(numfmt --to=iec $webroot_size) of data..."
    
    # Make temp files unique to this run
    local tmp_tar_err="$BACKUP_DIR/wp-backup-tar.err"
    
    # Add to temp files list for cleanup
    TEMP_FILES="$TEMP_FILES $tmp_tar_err"
    
    # Create archive with exclusions in background
    tar -czf "$WEB_ARCHIVE" \
        --exclude='wp-content/ai1wm-backups' \
        --exclude='wp-content/backups' \
        --exclude='wp-content/backups-dup-pro' \
        --exclude='wp-content/updraft' \
        --exclude='wp-content/uploads/backup-*' \
        --exclude='wp-content/uploads/backwpup-*' \
        --exclude='wp-content/cache' \
        --exclude='wp-content/uploads/cache' \
        --exclude='wp-content/w3tc-cache' \
        --exclude='wp-content/wp-rocket-cache' \
        --exclude='wp-content/litespeed' \
        --exclude='wp-content/debug.log' \
        --exclude='wp-content/error_log' \
        --exclude='wp-config-backup.php' \
        --exclude='error_log' \
        --exclude='wp-content/ewww' \
        --exclude='wp-content/smush-webp' \
        --exclude='wp-content/uploads/wp-file-manager-pro/fm_backup' \
        --exclude='*.log' \
        -C "$WP_PATH" . 2>"$tmp_tar_err" || true &
    local tar_pid=$!
    
    # Monitor progress
    while kill -0 $tar_pid 2>/dev/null; do
        if [[ -f "$WEB_ARCHIVE" ]]; then
            local current_size=$(stat -c%s "$WEB_ARCHIVE" 2>/dev/null || echo "0")
            echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $current_size)     "
        fi
        sleep 2
    done
    
    # Wait for process to complete and check exit status
    wait $tar_pid
    local exit_status=$?
    
    echo # New line after progress
    
    # Show any errors from tar (but do not exit unless tar failed)
    if [[ -s "$tmp_tar_err" ]]; then
        warning "Non-fatal errors during archive creation (see below):"
        cat "$tmp_tar_err"
    fi
    
    if [[ $exit_status -ne 0 ]] || [[ ! -s "$WEB_ARCHIVE" ]]; then
        error "Archive creation failed"
        exit 1
    fi
    
    local archive_size=$(stat -c%s "$WEB_ARCHIVE" 2>/dev/null || echo "0")
    success "Website archive created successfully ($(numfmt --to=iec $archive_size))"
    echo
}

collect_server_configuration() {
    # Cron jobs and PHP config already collected in collect_configuration
    # Collect remaining items here
    
    # Collect cron jobs for litespeed user
    CRON_JOBS=$(crontab -u "$CRON_USER" -l 2>/dev/null || echo "")
    
    # Collect custom PHP configuration
    if [[ -f "$PHP_INI_PATH" ]]; then
        CUSTOM_PHP_INI=$(cat "$PHP_INI_PATH" 2>/dev/null || echo "")
    fi
}

confirm_configuration() {
    echo
    info "=== Configuration Summary ==="
    echo "WordPress Root: $WP_PATH"
    echo "Site URL: $SITE_URL"
    echo "Database charset: $DB_CHARSET"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Database Dump: $DB_DUMP"
    echo "Web Archive: $WEB_ARCHIVE"
    
    if [[ "$MAINTENANCE_MODE_ENABLED" == "true" ]] && [[ "$DISABLE_MAINTENANCE_ON_EXIT" == "true" ]]; then
        echo "BuddyBoss maintenance modes disabled: True"
    elif [[ "$MAINTENANCE_MODE_ENABLED" == "true" ]]; then
        echo "BuddyBoss maintenance modes disabled: False (will remain enabled)"
    fi
    
    echo
    
    # Confirm configuration
    prompt "Is this configuration correct? (Y/N) [Default: Y]: "
    read -r confirm
    # Accept empty input (Enter key) or Y/y as confirmation
    if [[ -z "$confirm" ]] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        success "Configuration confirmed"
        echo
    else
        error "Configuration cancelled by user"
        exit 1
    fi
}

export_configuration() {
    log "Exporting server configuration..."
    
    local config_file="$BACKUP_DIR/server_config.txt"
    
    # Create human-readable configuration file
    cat > "$config_file" << EOF
# WordPress Backup Configuration
# Generated: $(date +'%Y-%m-%d %H:%M:%S')
MULTISITE=$(check_multisite)
PRIMARY_DOMAIN=$SITE_URL
SECONDARY_DOMAINS=$(get_multisite_domains)
DB_CHARSET=$DB_CHARSET
CUSTOM_LOGIN_URL=$CUSTOM_LOGIN_URL
WP_PATH=$WP_PATH
BB_APP_ID=$BB_APP_ID
BB_APP_KEY=$BB_APP_KEY

EOF

    success "Configuration exported to: server_config.txt"

    # Export cron jobs if any exist
    if [[ -n "$CRON_JOBS" ]]; then
        echo "$CRON_JOBS" > "$BACKUP_DIR/cron_jobs.txt"
        success "Cron jobs exported to: cron_jobs.txt"
    fi

    # Export custom PHP configuration if it exists
    if [[ -n "$CUSTOM_PHP_INI" ]]; then
        echo "$CUSTOM_PHP_INI" > "$BACKUP_DIR/custom_php.ini"
        cat >> "$config_file" << EOF

EOF
        success "Custom PHP config exported to: custom_php.ini"
    fi
    
    echo
}

verify_backup() {
    log "Verifying backup files..."
    
    # Check that both files exist and are not empty
    if [[ ! -f "$DB_DUMP" ]] || [[ ! -s "$DB_DUMP" ]]; then
        error "Database dump not found or empty"
        exit 1
    fi
    
    if [[ ! -f "$WEB_ARCHIVE" ]] || [[ ! -s "$WEB_ARCHIVE" ]]; then
        error "Website archive not found or empty"
        exit 1
    fi
    
    local db_size=$(stat -c%s "$DB_DUMP" 2>/dev/null || echo "0")
    local archive_size=$(stat -c%s "$WEB_ARCHIVE" 2>/dev/null || echo "0")
    
    echo
    info "Backup files created:"
    echo "  [OK] $(basename "$DB_DUMP") ($(numfmt --to=iec $db_size))"
    echo "  [OK] $(basename "$WEB_ARCHIVE") ($(numfmt --to=iec $archive_size))"
    
    # Check for configuration files
    if [[ -f "$BACKUP_DIR/server_config.txt" ]]; then
        echo "  [OK] server_config.txt"
    fi
    if [[ -f "$BACKUP_DIR/cron_jobs.txt" ]]; then
        echo "  [OK] cron_jobs.txt"
    fi
    if [[ -f "$BACKUP_DIR/custom_php.ini" ]]; then
        echo "  [OK] custom_php.ini"
    fi
    
    echo
    success "Backup verification completed successfully"
}

display_summary() {
    echo
    echo "==============================================================="
    info "              *** BACKUP COMPLETED SUCCESSFULLY ***"
    echo "==============================================================="
    echo
    echo ">> Backup Details:"
    echo "   - WordPress site: $SITE_URL"
    echo "   - Backup location: $BACKUP_DIR"
    echo
    echo ">> Files Created:"
    echo "   - Database: $(basename "$DB_DUMP") ($DB_CHARSET charset)"
    echo "   - Web files: $(basename "$WEB_ARCHIVE")"
    if [[ -f "$BACKUP_DIR/server_config.txt" ]]; then
        echo "   - Configuration: server_config.txt"
    fi
    if [[ -f "$BACKUP_DIR/cron_jobs.txt" ]]; then
        echo "   - Cron jobs: cron_jobs.txt"
    fi
    if [[ -f "$BACKUP_DIR/custom_php.ini" ]]; then
        echo "   - PHP config: custom_php.ini"
    fi
    echo
    
    # Display important configuration values
    echo ">> Site Configuration:"
    if [[ -n "$CUSTOM_LOGIN_URL" ]]; then
        echo "   - Custom Login URL: /$CUSTOM_LOGIN_URL"
    else
        echo "   - Login URL: /wp-admin (default)"
    fi
    
    if [[ -n "$BB_APP_ID" ]] && [[ "$BB_APP_ID" != "N/A" ]]; then
        echo "   - BuddyBoss App ID: $BB_APP_ID"
        echo "   - BuddyBoss App Key: $BB_APP_KEY"
    fi
    
    if [[ -n "$CRON_JOBS" ]]; then
        local cron_count=$(echo "$CRON_JOBS" | grep -v '^#' | grep -v '^$' | wc -l)
        echo "   - Cron jobs: $cron_count job(s) backed up"
    fi
    
    if [[ -n "$CUSTOM_PHP_INI" ]]; then
        echo "   - Custom PHP config: Yes ($PHP_INI_PATH)"
    fi
    echo
    
    echo ">> Full Paths:"
    echo "   - $DB_DUMP"
    echo "   - $WEB_ARCHIVE"
    if [[ -f "$BACKUP_DIR/server_config.txt" ]]; then
        echo "   - $BACKUP_DIR/server_config.txt"
    fi
    if [[ -f "$BACKUP_DIR/cron_jobs.txt" ]]; then
        echo "   - $BACKUP_DIR/cron_jobs.txt"
    fi
    if [[ -f "$BACKUP_DIR/custom_php.ini" ]]; then
        echo "   - $BACKUP_DIR/custom_php.ini"
    fi
    echo
    echo "==============================================================="
    echo
}

main() {
    echo
    echo "==============================================================="
    info "               V3 Transition - Backup Tool"
    echo "==============================================================="
    echo
    
    collect_configuration
    enable_maintenance_mode
    confirm_configuration
    check_prerequisites
    export_database
    create_archive
    collect_server_configuration
    export_configuration
    verify_backup
    display_summary
}

# Run main function
main
