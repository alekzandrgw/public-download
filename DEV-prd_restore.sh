#!/bin/bash

#===============================================================
#                V3 Transition - Restore Tool
#===============================================================
# Description: Restores WordPress sites from V1 backups to V3
# Author: Alexander Gil
# Version: 1.0
#===============================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LBLUE='\033[1;34m'
NC='\033[0m' # No Color

# Global variables
MOUNTPOINT="/mnt/v1node"
BACKUP_SOURCE="${MOUNTPOINT}/v1_backups"
WPCLIFLAGS="--skip-plugins --skip-themes --quiet --allow-root"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="/tmp/v3_restore_${TIMESTAMP}.log"

# V1 Variables (parsed from server_config.txt)
V1_MULTISITE=""
V1_PRIMARY_DOMAIN=""
V1_SECONDARY_DOMAINS=""
V1_WP_PATH=""

# V3 Variables (parsed from site selection)
V3SITESLUG=""
V3SITEURL=""
V3SITEPATH=""
V3SITEUSER=""
V3SITEBASEDIR=""
V3SITEAPPDIR=""

# V3 Database Variables
V3SITEDBNAME=""
V3SITEDBUSER=""
V3SITEDBPASS=""
V3SITEDBHOST="127.0.0.1"

# V3 Redis Variables
V3SITEREDISHOST=""
V3SITEREDISSCHEME=""
V3SITEREDISPORT=""

# User choices
REPLACE_URL="N"
DISABLE_MAINTENANCE="Y"

#===============================================================
# Helper Functions
#===============================================================

print_info() {
    echo -e "${LBLUE}[INFO] $1${NC}" | tee -a "$LOGFILE"
}

print_ok() {
    echo -e "${GREEN}[OK] $1${NC}" | tee -a "$LOGFILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOGFILE"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOGFILE"
}

print_header() {
    echo -e "${LBLUE}$1${NC}" | tee -a "$LOGFILE"
}

is_in_screen() {
    [[ -n "${STY:-}" ]]
}

log_output() {
    echo "$1" | tee -a "$LOGFILE"
}

# --- MU-plugins toggle helpers ---
MU_DIR=""
MU_DIR_TMP=""

disable_mu_plugins() {
    MU_DIR="$V3SITEPATH/wp-content/mu-plugins"
    MU_DIR_TMP="$V3SITEAPPDIR/temp/mu-plugins.disabled"

    if [ -d "$MU_DIR" ]; then
        mkdir -p "$(dirname "$MU_DIR_TMP")"
        mv "$MU_DIR" "$MU_DIR_TMP"
    fi
}

enable_mu_plugins() {
    if [ -d "$MU_DIR_TMP" ] && [ ! -d "$MU_DIR" ]; then
        mv "$MU_DIR_TMP" "$MU_DIR"
    fi
}

trap enable_mu_plugins EXIT

#===============================================================
# File-based Path Replacement Helper
#===============================================================
update_path_in_files() {
    local files_modified=0
    local temp_backup_dir="${V3SITEAPPDIR}/temp/file_backups_path"
    
    print_info "Searching for files containing old path..."
    
    # Create backup directory
    mkdir -p "$temp_backup_dir"
    
    # Find files containing the old path (with or without trailing slash)
    # Limit depth to 10, exclude common directories
    local files_to_process=$(find "$V3SITEPATH" -maxdepth 10 -type f \
        \( -name "*.php" -o -name "*.htaccess" -o -name "*.env" -o -name "*.ini" -o -name "*.json" -o -name "*.xml" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/vendor/*" \
        ! -path "*/wp-content/uploads/*" \
        ! -path "*/wp-content/cache/*" \
        -exec grep -l -E "${V1_WP_PATH}(/|[^/])" {} \; 2>/dev/null)
    
    if [ -z "$files_to_process" ]; then
        log_output "No files found containing old path"
        return 0
    fi
    
    # Process each file
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            # Create backup
            local backup_file="${temp_backup_dir}/$(basename "$file").backup"
            cp "$file" "$backup_file"
            
            # Escape special characters for sed
            local old_path_escaped=$(echo "$V1_WP_PATH" | sed 's/[\/&]/\\&/g')
            local old_path_slash_escaped=$(echo "${V1_WP_PATH}/" | sed 's/[\/&]/\\&/g')
            local new_path_escaped=$(echo "$V3SITEPATH" | sed 's/[\/&]/\\&/g')
            
            # Replace both variations (with and without trailing slash)
            sed -i "s|${old_path_slash_escaped}|${new_path_escaped}/|g" "$file"
            sed -i "s|${old_path_escaped}|${new_path_escaped}|g" "$file"
            
            files_modified=$((files_modified + 1))
            log_output "Updated path in: $file"
        fi
    done <<< "$files_to_process"
    
    log_output "Modified $files_modified file(s) with new path"
}

#===============================================================
# File-based URL Replacement Helper
#===============================================================
update_url_in_files() {
    local files_modified=0
    local temp_backup_dir="${V3SITEAPPDIR}/temp/file_backups_url"
    
    print_info "Searching for files containing old URL..."
    
    # Create backup directory
    mkdir -p "$temp_backup_dir"
    
    # Find files containing the old URL
    # Limit depth to 10, exclude common directories
    local files_to_process=$(find "$V3SITEPATH" -maxdepth 10 -type f \
        \( -name "*.php" -o -name "*.htaccess" -o -name "*.env" -o -name "*.ini" -o -name "*.json" -o -name "*.xml" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/vendor/*" \
        ! -path "*/wp-content/uploads/*" \
        ! -path "*/wp-content/cache/*" \
        -exec grep -l "${V1_PRIMARY_DOMAIN}" {} \; 2>/dev/null)
    
    if [ -z "$files_to_process" ]; then
        log_output "No files found containing old URL"
        return 0
    fi
    
    # Process each file
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            # Create backup
            local backup_file="${temp_backup_dir}/$(basename "$file").backup"
            cp "$file" "$backup_file"
            
            # Escape special characters for sed
            local old_domain_escaped=$(echo "$V1_PRIMARY_DOMAIN" | sed 's/[\/&.]/\\&/g')
            local new_domain_escaped=$(echo "$V3SITEURL" | sed 's/[\/&.]/\\&/g')
            
            # Replace the domain (preserving the protocol that's already in the file)
            sed -i "s|${old_domain_escaped}|${new_domain_escaped}|g" "$file"
            
            files_modified=$((files_modified + 1))
            log_output "Updated URL in: $file"
        fi
    done <<< "$files_to_process"
    
    log_output "Modified $files_modified file(s) with new URL"
}

#===============================================================
# Pre-flight Validation
#===============================================================

validate_commands() {
    print_header ""
    print_header "==============================================================="
    print_header "                V3 Transition - Restore Tool"
    print_header "==============================================================="
    print_header ""
    print_header "=== Prerequisites Check ==="
    print_header ""
    print_header "=== Required Packages Validation ==="
    print_header ""
    
    local missing_commands=()
    local required_commands=("wp" "rapyd" "mysql" "rsync" "tar" "dig" "keydb-cli" "jq" "lswsctrl")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        print_error "Missing required commands:"
        for cmd in "${missing_commands[@]}"; do
            print_error "  - $cmd"
        done
        exit 1
    fi
    
    print_ok "All required packages are available"
    echo ""
}

#===============================================================
# Prerequisites Check
#===============================================================

check_prerequisites() {
    
    print_info "Checking backup source..."
    
    # Check mount point
    if [ ! -d "$MOUNTPOINT" ]; then
        print_error "Mount point ${MOUNTPOINT} does not exist."
        print_warning "Mount the volume from Virtuozzo before proceeding"
        exit 1
    fi
    
    # Check backup source directory
    if [ ! -d "$BACKUP_SOURCE" ]; then
        print_error "Backup source directory not found. Generate the source backup by running this script in the source V1 container as root:"
        echo ""
        echo "wget https://raw.githubusercontent.com/alekzandrgw/public-download/refs/heads/main/source_backup_tool.sh && chmod +x source_backup_tool.sh && ./source_backup_tool.sh"
        echo ""
        exit 1
    fi
    
    log_output "Found backup directory ${BACKUP_SOURCE}"
    
    # Check required files
    local required_files=("db_backup.sql" "web_backup.tar.gz" "server_config.txt" "cron_jobs.txt" "custom_php.ini")
    for file in "${required_files[@]}"; do
        if [ ! -f "${BACKUP_SOURCE}/${file}" ]; then
            print_error "Required file not found: ${file}"
            exit 1
        fi
        log_output "Found ${file}"
    done
    
    echo ""
    print_ok "Backup source found"
}

#===============================================================
# Disk Space Analysis
#===============================================================

analyze_disk_space() {
    print_header ""
    print_info "Analyzing disk space requirements..."
    print_header ""
    print_header "=== Disk Space Summary ==="
    
    # Get file sizes
    local web_size=$(du -sh "${BACKUP_SOURCE}/web_backup.tar.gz" | awk '{print $1}')
    local db_size=$(du -sh "${BACKUP_SOURCE}/db_backup.sql" | awk '{print $1}')
    
    # Get sizes in bytes for calculations
    local web_bytes=$(du -sb "${BACKUP_SOURCE}/web_backup.tar.gz" | awk '{print $1}')
    local db_bytes=$(du -sb "${BACKUP_SOURCE}/db_backup.sql" | awk '{print $1}')
    local total_bytes=$((web_bytes + db_bytes))
    
    # Calculate required space with 20% buffer
    local required_bytes=$((total_bytes * 120 / 100))
    
    # Get available disk space in bytes (in root filesystem)
    local available_bytes=$(df / | tail -1 | awk '{print $4}')
    local available_bytes_actual=$((available_bytes * 1024))
    
    # Convert to human readable for display
    local total_size=$(numfmt --to=iec-i --suffix=B $total_bytes 2>/dev/null || echo "$((total_bytes / 1024 / 1024))M")
    local required_size=$(numfmt --to=iec-i --suffix=B $required_bytes 2>/dev/null || echo "$((required_bytes / 1024 / 1024))M")
    local available_size=$(numfmt --to=iec-i --suffix=B $available_bytes_actual 2>/dev/null || echo "$((available_bytes_actual / 1024 / 1024))M")
    
    log_output "WordPress files archive size: ${web_size}"
    log_output "Database archive size: ${db_size}"
    log_output "Total archives size: ${total_size}"
    log_output "Required space (with 20% buffer): ${required_size}"
    log_output "Available disk space: ${available_size}"
    
    print_header ""
    
    # Check if site is large (>10GB)
    local total_gb=$((total_bytes / 1024 / 1024 / 1024))
    if [ $total_gb -gt 10 ]; then
        print_warning "*** Large site detected (>10GB)!"
        print_header ""
        
        if is_in_screen; then
            print_ok "Running in screen session - good for large backups!"
        fi
    fi
    
    # Check if sufficient space
    if [ $available_bytes_actual -lt $required_bytes ]; then
        local additional_bytes=$((required_bytes - available_bytes_actual))
        local additional_gb=$((additional_bytes / 1024 / 1024 / 1024 + 1))
        print_warning "Not enough available disk space!!! Recommended additional disk space: ${additional_gb}GB"
        
        if [ $total_gb -gt 10 ]; then
            print_warning "Large site detected (>10GB)! Once additional disk space is added, run the script inside a screen session:"
            echo ""
            echo "screen -S backup"
            echo ""
        fi
        exit 1
    else
        print_ok "Sufficient disk space available"
    fi
}

#===============================================================
# Parse Server Config
#===============================================================

parse_server_config() {
    local config_file="${BACKUP_SOURCE}/server_config.txt"
    
    # Parse .env style file
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z $key ]] && continue
        
        # Remove quotes if present
        value="${value%\"}"
        value="${value#\"}"
        
        case $key in
            MULTISITE)
                V1_MULTISITE="$value"
                ;;
            PRIMARY_DOMAIN)
                V1_PRIMARY_DOMAIN="$value"
                ;;
            SECONDARY_DOMAINS)
                V1_SECONDARY_DOMAINS="$value"
                ;;
            WP_PATH)
                V1_WP_PATH="$value"
                ;;
        esac
    done < "$config_file"
    
    # Remove trailing slash from V1_WP_PATH
    V1_WP_PATH="${V1_WP_PATH%/}"
}

#===============================================================
# Import Preparation
#===============================================================

import_preparation() {
    print_header ""
    print_header "=== Import Preparation ==="
    print_header ""
    
    print_info "Fetching available sites..."
    
    # Get sites from rapyd
    local sites_json=$(rapyd site list --format json)
    local site_count=$(echo "$sites_json" | jq '. | length')
    
    if [ "$site_count" -eq 0 ]; then
        print_error "No sites found"
        exit 1
    fi
    
    # Display sites
    for i in $(seq 0 $((site_count - 1))); do
        local slug=$(echo "$sites_json" | jq -r ".[$i].slug")
        local domain=$(echo "$sites_json" | jq -r ".[$i].domain")
        local user=$(echo "$sites_json" | jq -r ".[$i].user")
        local webroot=$(echo "$sites_json" | jq -r ".[$i].webroot")
        
        echo "[$((i + 1))] $slug | $domain | $user | $webroot"
    done
    
    echo ""
    
    # Get user selection
    local selected_index=-1
    while true; do
        read -p "Enter the site number to use as restore target: " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$site_count" ]; then
            selected_index=$((selection - 1))
            break
        else
            print_error "Invalid selection. Please enter a number between 1 and $site_count"
        fi
    done
    
    # Parse selected site
    V3SITESLUG=$(echo "$sites_json" | jq -r ".[$selected_index].slug")
    V3SITEURL=$(echo "$sites_json" | jq -r ".[$selected_index].domain")
    V3SITEPATH=$(echo "$sites_json" | jq -r ".[$selected_index].webroot")
    V3SITEUSER=$(echo "$sites_json" | jq -r ".[$selected_index].user")
    V3SITEBASEDIR=$(echo "$sites_json" | jq -r ".[$selected_index].basedir")
    V3SITEAPPDIR="${V3SITEBASEDIR}/www/app"
    
    # Remove trailing slash from V3SITEPATH
    V3SITEPATH="${V3SITEPATH%/}"
    
    # Move log file to proper location if temp directory will be created
    local new_logfile="${V3SITEAPPDIR}/restore_${TIMESTAMP}.log"
    if [ -f "$LOGFILE" ] && [ "$LOGFILE" != "$new_logfile" ]; then
        mkdir -p "${V3SITEAPPDIR}" 2>/dev/null || true
        cp "$LOGFILE" "$new_logfile" 2>/dev/null || true
        LOGFILE="$new_logfile"
    fi
    
    echo ""
    
    # Parse server config before asking questions
    parse_server_config
    
    # Ask about URL replacement only if source domain contains rapydapps.cloud
    if [[ "$V1_PRIMARY_DOMAIN" == *"rapydapps.cloud"* ]]; then
        while true; do
            read -p "Replace URL with [${V3SITEURL}]? Y/N [Default N]: " url_choice
            url_choice=${url_choice:-N}
            if [[ "$url_choice" =~ ^[YyNn]$ ]]; then
                REPLACE_URL=$(echo "$url_choice" | tr '[:lower:]' '[:upper:]')
                break
            else
                print_error "Invalid input. Please enter Y or N"
            fi
        done
        echo ""
    fi
    
    # Ask about maintenance mode
    while true; do
        read -p "Disable maintenance mode(s) once the restore is complete? Y/N [Default Y]: " maint_choice
        maint_choice=${maint_choice:-Y}
        if [[ "$maint_choice" =~ ^[YyNn]$ ]]; then
            DISABLE_MAINTENANCE=$(echo "$maint_choice" | tr '[:lower:]' '[:upper:]')
            break
        else
            print_error "Invalid input. Please enter Y or N"
        fi
    done
    
    echo ""
    
    # Display restore operation summary
    print_header "=== Restore Operation Summary ==="
    print_header ""
    log_output "Backup source: ${BACKUP_SOURCE}"
    log_output "Multisite detected: ${V1_MULTISITE}"
    log_output "Primary domain: ${V1_PRIMARY_DOMAIN}"
    
    if [ -n "$V1_SECONDARY_DOMAINS" ]; then
        log_output "Secondary domain(s): ${V1_SECONDARY_DOMAINS}"
    fi
    
    log_output "Restore target: ${V3SITEURL}"
    
    if [[ "$V1_PRIMARY_DOMAIN" == *"rapydapps.cloud"* ]]; then
        log_output "Replace URL: ${REPLACE_URL}"
    fi
    
    log_output "Disable maintenance mode(s): ${DISABLE_MAINTENANCE}"
    log_output "Old WordPress path: ${V1_WP_PATH}"
    log_output "New WordPress path: ${V3SITEPATH}"
    
    print_header ""
    
    if [ "$V1_MULTISITE" = "Yes" ]; then
        print_info "Multisite installation detected. All sub-site domains will be automatically mapped to the target site."
        print_header ""
    fi
    
    read -p "Press Enter to begin the restore operation."
}

#===============================================================
# Backup Current Site
#===============================================================

backup_current_site() {
    print_header ""
    print_header "=== Backing Up Current Site ==="
    print_header ""
    
    print_info "Backing up existing site..."
    
    # Export database
    cd "$V3SITEPATH"
    wp db export $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "Default database exported successfully"
    
    # Rename current directory
    mv "${V3SITEAPPDIR}/public" "${V3SITEAPPDIR}/public-backup"
    
    print_ok "Existing site backed up to: ${V3SITEAPPDIR}/public-backup"
}

#===============================================================
# Download Backup
#===============================================================

download_backup() {
    print_header ""
    print_header "=== Downloading Backup ==="
    print_header ""
    
    print_info "Creating new webroot..."
    su "$V3SITEUSER" -c "mkdir -p $V3SITEPATH"
    print_ok "New webroot ready: ${V3SITEPATH}"
    
    print_header ""
    print_info "Creating temp directory..."
    su "$V3SITEUSER" -c "mkdir -p ${V3SITEAPPDIR}/temp"
    print_ok "Temp directory ready: ${V3SITEAPPDIR}/temp"
    
    print_header ""
    print_info "Downloading backup files..."
    su "$V3SITEUSER" -c "rsync -aP ${BACKUP_SOURCE}/ ${V3SITEAPPDIR}/temp/" 2>&1 | tee -a "$LOGFILE"
    print_ok "Backup files successfully downloaded"
}

#===============================================================
# Extract Archive
#===============================================================

extract_archive() {
    print_header ""
    print_header "=== Restoring Backup ==="
    print_header ""
    
    print_info "Extracting WordPress archive..."
    
    # Start extraction in background
    su "$V3SITEUSER" -c "tar -xzf ${V3SITEAPPDIR}/temp/web_backup.tar.gz -C $V3SITEPATH" &
    local tar_pid=$!
    
    # Monitor extraction progress
    while kill -0 $tar_pid 2>/dev/null; do
        local current_size=$(du -sh "$V3SITEPATH" 2>/dev/null | awk '{print $1}' || echo "0")
        echo -ne "\rExtracting: ${current_size}..."
        sleep 3
    done
    
    wait $tar_pid
    
    echo ""
    local final_size=$(du -sh "$V3SITEPATH" | awk '{print $1}')
    print_ok "Archive extracted successfully [Size ${final_size}]"
}

#===============================================================
# Temporarily Disable Object Cache
#===============================================================

temp_disable_cache() {
    print_header ""
    print_info "Temporarily disabling KeyDB integration with WordPress"
    
    cd "${V3SITEAPPDIR}/public-backup"
    wp cache flush $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "Object cache flushed"
    
    wp config set WP_REDIS_DISABLED true --raw $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "KeyDB integration disabled"
    
    # Suppress the "OK" in console, but log it
	keydb_cli_output=$(keydb-cli -s /var/run/redis/redis.sock flushall 2>&1)
	echo "$keydb_cli_output" >> "$LOGFILE"
    log_output "KeyDB flushed"
    
    print_ok "KeyDB integration disabled and cache flushed"
}

#===============================================================
# Drop Default Database
#===============================================================

drop_default_db() {
    print_header ""
    print_info "Dropping current database.."
    
    cd "${V3SITEAPPDIR}/public-backup"
    wp db reset --yes $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    
    print_ok "Database dropped successfully"
}

#===============================================================
# Import Database
#===============================================================

import_database() {
    print_header ""
    print_info "Importing database backup..."
    
    # Extract credentials from backed up config
    cd "$V3SITEPATH"
    V3SITEDBNAME=$(wp config get DB_NAME --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS)
    V3SITEDBUSER=$(wp config get DB_USER --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS)
    V3SITEDBPASS=$(wp config get DB_PASSWORD --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS)
    
    # Import database
    local error_log="${V3SITEAPPDIR}/temp/temp_import_err.log"
    mysql -h "$V3SITEDBHOST" -u "$V3SITEDBUSER" -p"$V3SITEDBPASS" "$V3SITEDBNAME" -f < "${V3SITEAPPDIR}/temp/db_backup.sql" 2> "$error_log"
    
    # Display non-fatal errors if any
    if [ -s "$error_log" ]; then
        print_info "Non-fatal errors during database import (see below):"
        # Show unique error lines, truncated to 100 chars
        sort -u "$error_log" | while read -r line; do
            echo "${line:0:100}..." | tee -a "$LOGFILE"
        done
    fi
    
    print_ok "Database imported successfully"
}

#===============================================================
# Update WordPress Constants
#===============================================================

update_wp_constants() {
    print_header ""
    print_info "Updating WordPress Constants..."
    
    cd "$V3SITEPATH"
    
    # Update database constants
    wp config set DB_NAME "$V3SITEDBNAME" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "DB_NAME updated"
    
    wp config set DB_USER "$V3SITEDBUSER" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "DB_USER updated"
    
    wp config set DB_PASSWORD "$V3SITEDBPASS" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "DB_PASSWORD updated"
    
    print_ok "Database constants updated"
    
    # Update Redis constants
    # Check and set WP_REDIS_DISABLED
    if ! wp config is-true WP_REDIS_DISABLED $WPCLIFLAGS 2>/dev/null; then
        wp config set WP_REDIS_DISABLED true --raw $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "WP_REDIS_DISABLED added/updated"
    fi
    
    # Remove WP_REDIS_PATH
    if wp config has WP_REDIS_PATH $WPCLIFLAGS 2>/dev/null; then
        wp config delete WP_REDIS_PATH $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "WP_REDIS_PATH removed"
    fi
    
    # Extract and update Redis settings from backup
    V3SITEREDISHOST=$(wp config get WP_REDIS_HOST --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS 2>/dev/null || echo "")
    V3SITEREDISSCHEME=$(wp config get WP_REDIS_SCHEME --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS 2>/dev/null || echo "")
    V3SITEREDISPORT=$(wp config get WP_REDIS_PORT --config-file="${V3SITEAPPDIR}/public-backup/wp-config.php" $WPCLIFLAGS 2>/dev/null || echo "")
    
    if [ -n "$V3SITEREDISHOST" ]; then
        wp config set WP_REDIS_HOST "$V3SITEREDISHOST" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "WP_REDIS_HOST updated"
    fi
    
    if [ -n "$V3SITEREDISSCHEME" ]; then
        wp config set WP_REDIS_SCHEME "$V3SITEREDISSCHEME" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "WP_REDIS_SCHEME updated"
    fi
    
    if [ -n "$V3SITEREDISPORT" ]; then
        wp config set WP_REDIS_PORT "$V3SITEREDISPORT" $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "WP_REDIS_PORT updated"
    fi
    
    print_ok "Redis constants updated"
    print_ok "WordPress constants updated successfully"
}

#===============================================================
# Update WordPress Path
#===============================================================

update_wp_path() {
    print_header ""
    print_info "Updating WordPress path in files and database..."
    
    cd "$V3SITEPATH"
    
    # Update paths in files first
    update_path_in_files
    
    # Database update
    disable_mu_plugins
    WP_CLI_DISABLE_MU_PLUGINS=1 wp search-replace "$V1_WP_PATH" "$V3SITEPATH" $WPCLIFLAGS --all-tables 2>&1 | tee -a "$LOGFILE"
    
    print_ok "WordPress path updated successfully"
}

#===============================================================
# Update Site URL
#===============================================================

update_site_url() {
    if [ "$REPLACE_URL" != "Y" ]; then
        return
    fi
    
    print_header ""
    print_info "Updating site URL in files and database to [${V3SITEURL}]..."
    
    cd "$V3SITEPATH"
    
    # Update URLs in files first
    update_url_in_files
    
    # Database updates
    wp search-replace "https://${V1_PRIMARY_DOMAIN}" "https://${V3SITEURL}" $WPCLIFLAGS --all-tables 2>&1 | tee -a "$LOGFILE"
    
    # Check for Elementor
    if wp plugin is-installed elementor $WPCLIFLAGS 2>/dev/null && wp plugin is-active elementor $WPCLIFLAGS 2>/dev/null; then
        wp elementor replace-urls "https://${V1_PRIMARY_DOMAIN}" "https://${V3SITEURL}" --allow-root 2>&1 | tee -a "$LOGFILE"
    fi
    
    wp cache flush $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    
    print_ok "Site URL updated successfully"
}

#===============================================================
# Disable Maintenance Modes
#===============================================================

disable_maintenance_modes() {
    if [ "$DISABLE_MAINTENANCE" != "Y" ]; then
        return
    fi
    
    print_header ""
    print_info "Disabling maintenance mode(s)..."
    
    cd "$V3SITEPATH" || {
        error "Failed to access site path: $V3SITEPATH"
        return 1
    }
    
    # Check for Simple Maintenance plugin
    if wp plugin is-installed simple-maintenance $WPCLIFLAGS 2>/dev/null; then
        if wp plugin is-active simple-maintenance $WPCLIFLAGS 2>/dev/null; then
            wp plugin deactivate simple-maintenance $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        fi
        wp plugin uninstall simple-maintenance $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
        log_output "Simple Maintenance plugin deactivated and uninstalled"
    else
        # BuddyBoss App maintenance mode
        if wp option pluck bbapp_settings app_maintenance_mode $WPCLIFLAGS >/dev/null 2>&1; then
            wp option patch update bbapp_settings app_maintenance_mode 0 $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
            log_output "BuddyBoss App maintenance deactivated"
        fi

        # BuddyBoss Theme maintenance mode
        if wp option pluck buddyboss_theme_options maintenance_mode $WPCLIFLAGS >/dev/null 2>&1; then
            wp option patch update buddyboss_theme_options maintenance_mode 0 $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
            log_output "BuddyBoss Theme maintenance mode deactivated"
        fi
    fi
    
    print_ok "Maintenance mode(s) successfully disabled"
}

#===============================================================
# Flush Cache and Restore KeyDB Integration
#===============================================================

flush_cache_restore_keydb() {
    print_header ""
    print_info "Flushing cache and restoring KeyDB integration..."
    
    cd "$V3SITEPATH" || {
        error "Failed to access site path: $V3SITEPATH"
        return 1
    }

    wp cache flush $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "Object cache flushed"

    wp config set WP_REDIS_DISABLED false --raw $WPCLIFLAGS 2>&1 | tee -a "$LOGFILE"
    log_output "KeyDB integration re-enabled"

    # Suppress the "OK" in console, but log it
    keydb_cli_output=$(keydb-cli -s /var/run/redis/redis.sock flushall 2>&1)
    echo "$keydb_cli_output" >> "$LOGFILE"
    log_output "KeyDB flushed"

    print_ok "KeyDB integration restored and cache flushed"
}


#===============================================================
# Restore PHP Settings
#===============================================================

restore_php_settings() {
    print_header ""
    print_info "Restoring PHP settings.."
    
    cp "${V3SITEAPPDIR}/temp/custom_php.ini" "/home/${V3SITEUSER}/web/php/998-rapyd.ini"
    
    lswsctrl condrestart 2>&1 | tee -a "$LOGFILE"
    
    print_ok "PHP settings restored"
}

#===============================================================
# Restore Cron Jobs
#===============================================================

restore_cron_jobs() {
    print_header ""
    print_info "Restoring cron jobs..."
    
    local cron_source="${V3SITEAPPDIR}/temp/cron_jobs.txt"
    local cron_dest="/var/spool/cron/${V3SITEUSER}"
    local cron_temp="${V3SITEAPPDIR}/temp/cron_jobs_updated.txt"
    
    # Check if source file exists
    if [ ! -f "$cron_source" ]; then
        print_warning "Cron jobs file not found, skipping"
        return 0
    fi
    
    # Check if source file is empty
    if [ ! -s "$cron_source" ]; then
        print_warning "Cron jobs file is empty, skipping"
        return 0
    fi
    
    # Copy to temp file for processing
    cp "$cron_source" "$cron_temp"
    
    # Update paths in cron jobs (handle both with and without trailing slash)
    local old_path_escaped=$(echo "$V1_WP_PATH" | sed 's/[\/&]/\\&/g')
    local old_path_slash_escaped=$(echo "${V1_WP_PATH}/" | sed 's/[\/&]/\\&/g')
    local new_path_escaped=$(echo "$V3SITEPATH" | sed 's/[\/&]/\\&/g')
    
    sed -i "s|${old_path_slash_escaped}|${new_path_escaped}/|g" "$cron_temp"
    sed -i "s|${old_path_escaped}|${new_path_escaped}|g" "$cron_temp"
    
    # Update URLs in cron jobs if URL replacement was requested
    if [ "$REPLACE_URL" = "Y" ]; then
        local old_domain_escaped=$(echo "$V1_PRIMARY_DOMAIN" | sed 's/[\/&.]/\\&/g')
        local new_domain_escaped=$(echo "$V3SITEURL" | sed 's/[\/&.]/\\&/g')
        sed -i "s|${old_domain_escaped}|${new_domain_escaped}|g" "$cron_temp"
    fi
    
    # Copy to final destination
    cp "$cron_temp" "$cron_dest"
    
    # Append newline
        echo "" >> "$cron_dest"
    
    # Set proper permissions (cron requires specific permissions)
    chmod 600 "$cron_dest"
    chown "$V3SITEUSER:$V3SITEUSER" "$cron_dest"
    
    log_output "Cron jobs restored for user: $V3SITEUSER"
    
    print_ok "Cron jobs restored successfully"
}

#===============================================================
# Assign Domains
#===============================================================

check_www_resolvable() {
    local domain=$1
    local timeout=5
    
    # Check if www subdomain is resolvable with timeout
    if timeout $timeout dig +short "www.${domain}" | grep -q .; then
        return 0
    else
        return 1
    fi
}

assign_domains() {
    # Skip domain assignment if primary domain is rapydapps.cloud
    if [[ "$V1_PRIMARY_DOMAIN" == *"rapydapps.cloud" ]]; then
    	echo ""
        print_info "Skipping domain assignment (rapydapps.cloud domain detected)"
        return 0
    fi
    
    print_header ""
    print_info "Assigning domain(s).."
    
    local assigned_domains=()
    
    # Assign primary domain
    local www_flag=""
    if check_www_resolvable "$V1_PRIMARY_DOMAIN"; then
        www_flag="--www"
    fi
    
    if rapyd domain add --domain "$V1_PRIMARY_DOMAIN" $www_flag --slug "$V3SITESLUG" 2>&1 | tee -a "$LOGFILE"; then
        if [ -n "$www_flag" ]; then
            assigned_domains+=("$V1_PRIMARY_DOMAIN" "www.$V1_PRIMARY_DOMAIN")
        else
            assigned_domains+=("$V1_PRIMARY_DOMAIN")
        fi
    else
        print_warning "Failed to assign domain: $V1_PRIMARY_DOMAIN"
    fi
    
    # Assign secondary domains if they exist
    if [ -n "$V1_SECONDARY_DOMAINS" ]; then
        IFS=',' read -ra DOMAINS <<< "$V1_SECONDARY_DOMAINS"
        for domain in "${DOMAINS[@]}"; do
            www_flag=""
            if check_www_resolvable "$domain"; then
                www_flag="--www"
            fi
            
            if rapyd domain add --domain "$domain" $www_flag --slug "$V3SITESLUG" 2>&1 | tee -a "$LOGFILE"; then
                if [ -n "$www_flag" ]; then
                    assigned_domains+=("$domain" "www.$domain")
                else
                    assigned_domains+=("$domain")
                fi
            else
                print_warning "Failed to assign domain: $domain"
            fi
        done
    fi
    
    # Print success message with all assigned domains
    if [ ${#assigned_domains[@]} -gt 0 ]; then
        local domains_list=$(IFS=', '; echo "${assigned_domains[*]}")
        print_ok "Domain(s) [${domains_list}] successfully assigned"
    fi
}

#===============================================================
# Cleanup
#===============================================================

cleanup() {
    print_header ""
    print_header "=== Running Cleanup ==="
    print_header ""
    
    print_info "Removing temp files..."
    rm -rf "${V3SITEAPPDIR}/temp"
    log_output "Temp directory [${V3SITEAPPDIR}/temp] and its content removed"
    
    print_ok "Cleanup complete"
}

#===============================================================
# Print Summary
#===============================================================

print_summary() {
    print_header ""
    print_header "==============================================================="
    print_header "       *** SITE IMPORT COMPLETED SUCCESSFULLY ***"
    print_header "==============================================================="
    print_header ""
    log_output "The site has been successfully imported but there are steps pending."
    print_header ""
    log_output "Before running the complementary script, complete these actions:"
    print_header ""
    log_output "1. Transfer the IP from v1"
    log_output "2. Transfer domains from v1"
    log_output "3. Associate the domain to this site through Rapyd Dashboard"
    log_output "4. Update DNS"
    print_header ""
    log_output "Once DNS changes have propagated, run the complementary script."
    print_header ""
    print_header "==============================================================="
    print_header ""
    print_info "Log file saved to: ${LOGFILE}"
}

#===============================================================
# Main Execution
#===============================================================

main() {
    # Validate commands first
    validate_commands
    
    # Run prerequisite checks
    check_prerequisites
    
    # Analyze disk space
    analyze_disk_space
    
    # Import preparation and user input
    import_preparation
    
    # Backup current site
    backup_current_site
    
    # Download backup files
    download_backup
    
    # Extract archive
    extract_archive
    
    # Temporarily disable cache
    temp_disable_cache
    
    # Drop current database
    drop_default_db
    
    # Import database
    import_database
    
    # Update WordPress constants
    update_wp_constants
    
    # Update WordPress path
    update_wp_path
    
    # Update site URL (if needed)
    update_site_url
    
    # Disable maintenance modes (if requested)
    disable_maintenance_modes
    
    # Flush cache and restore KeyDB
    flush_cache_restore_keydb
    
    # Restore PHP settings
    restore_php_settings
    
    # Restore cron jobs
    restore_cron_jobs
    
    # Assign domains
    assign_domains
    
    # Cleanup
    cleanup
    
    # Enable mu-plugins
    enable_mu_plugins
    
    # Print summary
    print_summary
}

# Run main function
main
