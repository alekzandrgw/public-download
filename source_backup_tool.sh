#!/bin/bash

# WordPress Local Backup Tool
# Run as root: ./wordpress_backup.sh

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
    log "Analyzing disk space requirements..."
    
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
    echo
    
    # Check if site is larger than 10GB
    local ten_gb=$((10 * 1024 * 1024 * 1024))
    if [[ $total_size -gt $ten_gb ]]; then
        warning "*** Large site detected (>10GB)!"
        
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
    
    log "Analyzing WordPress installation..."
    
    # Change to WordPress directory
    cd "$WP_PATH" || exit 1
    
    if ! "$WP_CLI" core is-installed --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null; then
        error "WordPress not installed in '$WP_PATH'"
        exit 1
    fi
    
    # Get site information
    SITE_URL=$("$WP_CLI" option get siteurl --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | sed 's|https\?://||')
    DB_CHARSET=$("$WP_CLI" eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | tr -d '\n')
    
    success "WordPress installation detected"
    echo
    
    # Display detected values
    info "Detected WordPress Information:"
    echo "Site URL: $SITE_URL"
    echo "Database charset: $DB_CHARSET"
    echo
    
    # Backup directory configuration
    read_input "Enter backup directory path [\$HOME/wp_backups]: " "input" "false" "" "true"
    BACKUP_DIR="${input:-$HOME/wp_backups}"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Set backup file paths
    DB_DUMP="$BACKUP_DIR/db_backup_$DATE.sql"
    WEB_ARCHIVE="$BACKUP_DIR/web_backup_$DATE.tar.gz"
    
    echo
    
    # Check disk space before proceeding
    check_disk_space
    
    # Display configuration summary
    echo
    info "=== Configuration Summary ==="
    echo "WordPress Root: $WP_PATH"
    echo "Site URL: $SITE_URL"
    echo "Database charset: $DB_CHARSET"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Database Dump: $DB_DUMP"
    echo "Web Archive: $WEB_ARCHIVE"
    echo
    
    # Confirm configuration
    prompt "Is this configuration correct? (Y/N) [Default: Y]: "
    read -r confirm
    # Accept empty input (Enter key) or Y/y as confirmation
    if [[ -z "$confirm" ]] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        success "Configuration confirmed"
    else
        error "Configuration cancelled by user"
        exit 1
    fi
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
}

check_buddyboss_installation() {
    log "Checking for BuddyBoss components..."
    
    local bb_app_installed=$("$WP_CLI" plugin list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-app" && echo "yes" || echo "no")
    local bb_theme_installed=$("$WP_CLI" theme list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-theme" && echo "yes" || echo "no")
    
    echo
    info "BuddyBoss Installation Status:"
    echo "BuddyBoss App Plugin: $bb_app_installed"
    echo "BuddyBoss Theme: $bb_theme_installed"
    
    if [[ "$bb_app_installed" == "yes" ]]; then
        BB_APP_ID=$("$WP_CLI" option pluck bbapps bbapp_app_id --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null || echo "N/A")
        BB_APP_KEY=$("$WP_CLI" option pluck bbapps bbapp_app_key --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null || echo "N/A")
        echo "BuddyBoss App ID: $BB_APP_ID"
        echo "BuddyBoss App Key: $BB_APP_KEY"
    fi
    echo
    
    # Return status for maintenance mode decision
    if [[ "$bb_app_installed" == "yes" ]] || [[ "$bb_theme_installed" == "yes" ]]; then
        return 0  # BuddyBoss detected
    else
        return 1  # No BuddyBoss
    fi
}

enable_maintenance_mode() {
    log "Configuring maintenance mode..."
    
    if check_buddyboss_installation; then
        # BuddyBoss detected
        local bb_app_installed=$("$WP_CLI" plugin list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-app" && echo "yes" || echo "no")
        local bb_theme_installed=$("$WP_CLI" theme list --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | grep -q "buddyboss-theme" && echo "yes" || echo "no")
        
        if [[ "$bb_theme_installed" == "yes" ]]; then
            prompt "Enable BuddyBoss Theme's maintenance mode? (Y/N) [Default: Y]: "
            read -r enable_bb_theme
            enable_bb_theme=${enable_bb_theme:-Y}
            
            if [[ "$enable_bb_theme" =~ ^[Yy]$ ]]; then
                "$WP_CLI" option patch update buddyboss_theme_options maintenance_mode 1 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
                local mode=$("$WP_CLI" option pluck buddyboss_theme_options maintenance_mode --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null || echo "0")
                
                if [[ "$mode" == "1" ]]; then
                    success "BuddyBoss Theme maintenance mode enabled"
                    MAINTENANCE_MODE_ENABLED=true
                    MAINTENANCE_TYPE="bb_theme"
                else
                    warning "Failed to enable BuddyBoss Theme maintenance mode"
                fi
            fi
        fi
        
        if [[ "$bb_app_installed" == "yes" ]]; then
            prompt "Enable BuddyBoss App's maintenance mode? (Y/N) [Default: Y]: "
            read -r enable_bb_app
            enable_bb_app=${enable_bb_app:-Y}
            
            if [[ "$enable_bb_app" =~ ^[Yy]$ ]]; then
                "$WP_CLI" option patch update bbapp_settings app_maintenance_mode 1 --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null
                local mode=$("$WP_CLI" option pluck bbapp_settings app_maintenance_mode --allow-root --skip-themes --skip-plugins --quiet 2>/dev/null || echo "0")
                
                if [[ "$mode" == "1" ]]; then
                    success "BuddyBoss App maintenance mode enabled"
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
        echo
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
    
    echo
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
    
    # Make temp files unique to this run
    local tmp_db_export="/tmp/wp-backup-${DATE}-db.sql"
    local tmp_db_err="/tmp/wp-backup-${DATE}-db.err"
    
    # Add to temp files list for cleanup
    TEMP_FILES="$tmp_db_export $tmp_db_err"
    
    # Start database export processing in background
    "$WP_CLI" db export "$tmp_db_export" --default-character-set="$DB_CHARSET" --allow-root --skip-plugins --skip-themes --quiet --force 2>"$tmp_db_err" || true &
    local export_pid=$!
    
    # Monitor progress
    while kill -0 $export_pid 2>/dev/null; do
        if [[ -f "$tmp_db_export" ]]; then
            local current_size=$(stat -c%s "$tmp_db_export" 2>/dev/null || echo "0")
            echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $current_size)     "
        fi
        sleep 2
    done
    
    # Wait for process to complete and check exit status
    wait $export_pid
    local exit_status=$?
    
    echo # New line after progress
    
    # Show any errors from export (but do not exit unless export failed)
    if [[ -s "$tmp_db_err" ]]; then
        warning "Non-fatal errors during database export (see below):"
        cat "$tmp_db_err"
    fi
    
    if [[ $exit_status -ne 0 ]] || [[ ! -s "$tmp_db_export" ]]; then
        error "Database export failed"
        exit 1
    fi
    
    # Move to final location
    mv "$tmp_db_export" "$DB_DUMP"
    
    local db_size=$(stat -c%s "$DB_DUMP" 2>/dev/null || echo "0")
    success "Database exported successfully ($(numfmt --to=iec $db_size))"
}

create_archive() {
    log "Creating website archive..."
    
    # Get directory size for progress estimation
    local webroot_size=$(du -sb "$WP_PATH" 2>/dev/null | cut -f1 || echo "0")
    info "Archiving $(numfmt --to=iec $webroot_size) of data..."
    
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
        -C "$WP_PATH" . 2>/dev/null &
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
    
    if [[ $exit_status -ne 0 ]]; then
        error "Failed to create archive"
        exit 1
    fi
    
    local archive_size=$(stat -c%s "$WEB_ARCHIVE" 2>/dev/null || echo "0")
    success "Website archive created successfully ($(numfmt --to=iec $archive_size))"
}

export_configuration() {
    log "Exporting server configuration..."
    
    local config_file="$BACKUP_DIR/server_config_$DATE.txt"
    local restore_script="$BACKUP_DIR/restore_config_$DATE.sh"
    
    # Create human-readable configuration file
    cat > "$config_file" << EOF
# WordPress Backup Configuration
# Generated: $(date +'%Y-%m-%d %H:%M:%S')
# Site URL: $SITE_URL

## Site Information
SITE_URL=$SITE_URL
DB_CHARSET=$DB_CHARSET
CUSTOM_LOGIN_URL=$CUSTOM_LOGIN_URL

## BuddyBoss Configuration
BB_APP_ID=$BB_APP_ID
BB_APP_KEY=$BB_APP_KEY

## Cron Jobs (litespeed user)
# To restore: crontab -u litespeed - < cron_jobs_${DATE}.txt
EOF

    if [[ -n "$CRON_JOBS" ]]; then
        echo "$CRON_JOBS" > "$BACKUP_DIR/cron_jobs_$DATE.txt"
        success "Cron jobs exported to: cron_jobs_$DATE.txt"
    fi

    # Export custom PHP configuration
    if [[ -n "$CUSTOM_PHP_INI" ]]; then
        echo "$CUSTOM_PHP_INI" > "$BACKUP_DIR/custom_php_$DATE.ini"
        cat >> "$config_file" << EOF

## Custom PHP Configuration
# Original file: $PHP_INI_PATH
# To restore: cp custom_php_${DATE}.ini /usr/local/lsws/lsphp/etc/php.d/998-rapyd.ini
# Then restart: systemctl restart lsws
EOF
        success "Custom PHP config exported to: custom_php_$DATE.ini"
    fi

    # Create automated restore script
    cat > "$restore_script" << 'EOFSCRIPT'
#!/bin/bash
# WordPress Backup Restore Script
# Auto-generated configuration restore script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE_STAMP="DATE_PLACEHOLDER"

echo "=== WordPress Configuration Restore ==="
echo

# Restore custom PHP configuration
if [[ -f "$SCRIPT_DIR/custom_php_${DATE_STAMP}.ini" ]]; then
    echo -n "Restore custom PHP configuration? (y/N): "
    read -r restore_php
    if [[ "$restore_php" =~ ^[Yy]$ ]]; then
        cp "$SCRIPT_DIR/custom_php_${DATE_STAMP}.ini" /usr/local/lsws/lsphp/etc/php.d/998-rapyd.ini
        systemctl restart lsws
        echo "[OK] Custom PHP configuration restored"
    fi
fi

# Restore cron jobs
if [[ -f "$SCRIPT_DIR/cron_jobs_${DATE_STAMP}.txt" ]]; then
    echo -n "Restore cron jobs for litespeed user? (y/N): "
    read -r restore_cron
    if [[ "$restore_cron" =~ ^[Yy]$ ]]; then
        crontab -u litespeed "$SCRIPT_DIR/cron_jobs_${DATE_STAMP}.txt"
        echo "[OK] Cron jobs restored"
    fi
fi

echo
echo "Configuration restore completed!"
EOFSCRIPT

    # Replace placeholder with actual date
    sed -i "s/DATE_PLACEHOLDER/$DATE/g" "$restore_script"
    chmod +x "$restore_script"
    
    success "Configuration exported to: server_config_$DATE.txt"
    success "Restore script created: restore_config_$DATE.sh"
    
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
    if [[ -f "$BACKUP_DIR/server_config_$DATE.txt" ]]; then
        echo "  [OK] server_config_$DATE.txt"
    fi
    if [[ -f "$BACKUP_DIR/cron_jobs_$DATE.txt" ]]; then
        echo "  [OK] cron_jobs_$DATE.txt"
    fi
    if [[ -f "$BACKUP_DIR/custom_php_$DATE.ini" ]]; then
        echo "  [OK] custom_php_$DATE.ini"
    fi
    if [[ -f "$BACKUP_DIR/restore_config_$DATE.sh" ]]; then
        echo "  [OK] restore_config_$DATE.sh"
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
    if [[ -f "$BACKUP_DIR/server_config_$DATE.txt" ]]; then
        echo "   - Configuration: server_config_$DATE.txt"
    fi
    if [[ -f "$BACKUP_DIR/cron_jobs_$DATE.txt" ]]; then
        echo "   - Cron jobs: cron_jobs_$DATE.txt"
    fi
    if [[ -f "$BACKUP_DIR/custom_php_$DATE.ini" ]]; then
        echo "   - PHP config: custom_php_$DATE.ini"
    fi
    if [[ -f "$BACKUP_DIR/restore_config_$DATE.sh" ]]; then
        echo "   - Restore script: restore_config_$DATE.sh"
    fi
    echo
    
    # Display important configuration values
    echo ">> Site Configuration:"
    if [[ -n "$CUSTOM_LOGIN_URL" ]]; then
        echo "   - Custom Login URL: /$CUSTOM_LOGIN_URL"
    else
        echo "   - Custom Login URL: /wp-admin (default)"
    fi
    
    if [[ -n "$BB_APP_ID" ]] && [[ "$BB_APP_ID" != "N/A" ]]; then
        echo "   - BuddyBoss App ID: $BB_APP_ID"
        echo "   - BuddyBoss App Key: $BB_APP_KEY"
    fi
    
    if [[ -n "$CRON_JOBS" ]]; then
        local cron_count=$(echo "$CRON_JOBS" | grep -v '^#' | grep -v '^

main() {
    echo
    echo "==============================================================="
    info "         WordPress Local Backup Tool v1.0"
    echo "==============================================================="
    echo
    
    collect_configuration
    check_prerequisites
    check_buddyboss_installation
    detect_site_configuration
    enable_maintenance_mode
    export_database
    create_archive
    export_configuration
    verify_backup
    display_summary
}

# Run main function
main | wc -l)
        echo "   - Cron jobs: $cron_count job(s) detected"
    fi
    
    if [[ -n "$CUSTOM_PHP_INI" ]]; then
        echo "   - Custom PHP config: Yes ($PHP_INI_PATH)"
    fi
    echo
    
    echo ">> Full Paths:"
    echo "   - $DB_DUMP"
    echo "   - $WEB_ARCHIVE"
    if [[ -f "$BACKUP_DIR/server_config_$DATE.txt" ]]; then
        echo "   - $BACKUP_DIR/server_config_$DATE.txt"
    fi
    if [[ -f "$BACKUP_DIR/restore_config_$DATE.sh" ]]; then
        echo "   - $BACKUP_DIR/restore_config_$DATE.sh"
    fi
    echo
    echo "==============================================================="
    echo
}

main() {
    echo
    echo "==============================================================="
    info "         WordPress Local Backup Tool v1.0"
    echo "==============================================================="
    echo
    
    collect_configuration
    check_prerequisites
    enable_maintenance_mode
    export_database
    create_archive
    verify_backup
    display_summary
}

# Run main function
main