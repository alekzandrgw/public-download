#!/bin/bash

# WordPress Import/Restore Tool
# Run as root: ./wordpress_import.sh

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SELECTED_SLUG=""
SELECTED_DOMAIN=""
SELECTED_WEBROOT=""
SELECTED_BASEDIR=""
SELECTED_USER=""
DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
BACKUP_DIR=""
DATE_PATTERN=""
SOURCE_URL=""
SOURCE_WEBROOT=""
DB_CHARSET=""
CUSTOM_LOGIN_URL=""
BB_APP_ID=""
BB_APP_KEY=""
TEMP_FILES=""
WP_CLI="/usr/local/bin/wp"
MOUNT_POINT="/mnt/v1node"
BACKUP_SOURCE="$MOUNT_POINT/wp_backups"

# Logging functions
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

# Cleanup function
cleanup() {
    if [[ -n "$TEMP_FILES" ]]; then
        rm -f $TEMP_FILES 2>/dev/null || true
        log "Cleanup completed"
    fi
}

trap cleanup EXIT

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Check for required commands
    local required_cmds=("rapyd" "jq" "rsync" "dig" "mysql" "keydb-cli")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    if [[ ! -f "$WP_CLI" ]]; then
        error "WP-CLI not found at $WP_CLI"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Display available sites and let user choose
select_site() {
    log "Fetching available sites..."
    
    local sites_json
    sites_json=$(rapyd site list --format=json 2>/dev/null)
    
    if [[ -z "$sites_json" ]] || [[ "$sites_json" == "[]" ]]; then
        error "No sites found or rapyd command failed"
        exit 1
    fi
    
    echo
    info "=== Available Sites ==="
    echo
    
    # Parse and display sites
    local slugs=()
    local count=1
    while IFS= read -r line; do
        local slug=$(echo "$line" | jq -r '.slug')
        local domain=$(echo "$line" | jq -r '.domain')
        slugs+=("$slug")
        echo "  [$count] $slug"
        echo "      Domain: $domain"
        echo
        ((count++))
    done < <(echo "$sites_json" | jq -c '.[]')
    
    # Prompt for selection
    while true; do
        prompt "Select site number [1-${#slugs[@]}]: "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "${#slugs[@]}" ]]; then
            local selected_slug="${slugs[$((selection-1))]}"
            
            # Parse full site details
            local site_data=$(echo "$sites_json" | jq -c ".[] | select(.slug == \"$selected_slug\")")
            
            SELECTED_SLUG=$(echo "$site_data" | jq -r '.slug')
            SELECTED_DOMAIN=$(echo "$site_data" | jq -r '.domain')
            SELECTED_WEBROOT=$(echo "$site_data" | jq -r '.webroot')
            SELECTED_BASEDIR=$(echo "$site_data" | jq -r '.basedir')
            SELECTED_USER=$(echo "$site_data" | jq -r '.user')
            DB_HOST=$(echo "$site_data" | jq -r '.database.db_host')
            DB_NAME=$(echo "$site_data" | jq -r '.database.db_name')
            DB_USER=$(echo "$site_data" | jq -r '.database.db_user')
            DB_PASSWORD=$(echo "$site_data" | jq -r '.database.db_password')
            
            echo
            success "Selected site: $SELECTED_SLUG"
            info "Domain: $SELECTED_DOMAIN"
            info "Webroot: $SELECTED_WEBROOT"
            info "User: $SELECTED_USER"
            break
        else
            error "Invalid selection. Please try again."
        fi
    done
}

# Check mount point and backup source
check_backup_source() {
    log "Checking backup source..."
    
    if [[ ! -d "$MOUNT_POINT" ]]; then
        error "Mount point $MOUNT_POINT does not exist"
        echo
        warning "REMINDER: Mount the volume from Virtuozzo before proceeding"
        warning "Example: mount /dev/vdb1 $MOUNT_POINT"
        echo
        exit 1
    fi
    
    if [[ ! -d "$BACKUP_SOURCE" ]]; then
        error "Backup directory $BACKUP_SOURCE does not exist"
        echo
        warning "A backup must be taken from the source server first"
        warning "Expected location: $BACKUP_SOURCE"
        echo
        exit 1
    fi
    
    success "Backup source found: $BACKUP_SOURCE"
}

# Find and select backup files
find_backup_files() {
    log "Searching for backup files..."
    
    # Find all backup sets (groups with same timestamp)
    local db_backups=($(find "$BACKUP_SOURCE" -name "db_backup_*.sql" -type f | sort -r))
    
    if [[ ${#db_backups[@]} -eq 0 ]]; then
        error "No database backup files found in $BACKUP_SOURCE"
        exit 1
    fi
    
    echo
    info "=== Available Backup Sets ==="
    echo
    
    local backup_dates=()
    local count=1
    for db_file in "${db_backups[@]}"; do
        local basename=$(basename "$db_file")
        local date_pattern=$(echo "$basename" | sed 's/db_backup_\(.*\)\.sql/\1/')
        backup_dates+=("$date_pattern")
        
        local date_formatted=$(echo "$date_pattern" | sed 's/\([0-9]\{8\}\)_\([0-9]\{6\}\)/\1 \2/' | awk '{print substr($1,1,4)"-"substr($1,5,2)"-"substr($1,7,2)" "substr($2,1,2)":"substr($2,3,2)":"substr($2,5,2)}')
        
        echo "  [$count] Backup from $date_formatted"
        ((count++))
    done
    
    # Prompt for selection
    while true; do
        prompt "Select backup number [1-${#backup_dates[@]}]: "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "${#backup_dates[@]}" ]]; then
            DATE_PATTERN="${backup_dates[$((selection-1))]}"
            success "Selected backup from: $DATE_PATTERN"
            break
        else
            error "Invalid selection. Please try again."
        fi
    done
    
    # Set backup file paths
    BACKUP_DIR="$BACKUP_SOURCE"
    local db_dump="$BACKUP_DIR/db_backup_${DATE_PATTERN}.sql"
    local web_archive="$BACKUP_DIR/web_backup_${DATE_PATTERN}.tar.gz"
    local server_config="$BACKUP_DIR/server_config_${DATE_PATTERN}.txt"
    
    # Verify all required files exist
    if [[ ! -f "$db_dump" ]]; then
        error "Database backup not found: $db_dump"
        exit 1
    fi
    
    if [[ ! -f "$web_archive" ]]; then
        error "Web archive not found: $web_archive"
        exit 1
    fi
    
    if [[ ! -f "$server_config" ]]; then
        error "Server config not found: $server_config"
        exit 1
    fi
    
    success "All backup files verified"
    
    # Parse server configuration
    parse_server_config "$server_config"
}

# Parse server configuration file
parse_server_config() {
    local config_file="$1"
    
    log "Parsing server configuration..."
    
    SOURCE_URL=$(grep "^SITE_URL=" "$config_file" | cut -d'=' -f2)
    DB_CHARSET=$(grep "^DB_CHARSET=" "$config_file" | cut -d'=' -f2)
    CUSTOM_LOGIN_URL=$(grep "^CUSTOM_LOGIN_URL=" "$config_file" | cut -d'=' -f2)
    BB_APP_ID=$(grep "^BB_APP_ID=" "$config_file" | cut -d'=' -f2)
    BB_APP_KEY=$(grep "^BB_APP_KEY=" "$config_file" | cut -d'=' -f2)
    
    echo
    info "=== Source Site Configuration ==="
    echo "Source URL: $SOURCE_URL"
    echo "Database Charset: $DB_CHARSET"
    if [[ -n "$CUSTOM_LOGIN_URL" ]]; then
        echo "Custom Login URL: /$CUSTOM_LOGIN_URL"
    fi
    if [[ -n "$BB_APP_ID" ]]; then
        echo "BuddyBoss App ID: $BB_APP_ID"
        echo "BuddyBoss App Key: $BB_APP_KEY"
    fi
}

# Copy backup files to destination
copy_backup_files() {
    log "Copying backup files to destination..."
    
    local dest_dir="$SELECTED_BASEDIR/www/app/web_backups"
    mkdir -p "$dest_dir"
    
    info "Syncing from $BACKUP_SOURCE to $dest_dir..."
    rsync -avh --progress "$BACKUP_SOURCE/" "$dest_dir/" || {
        error "Failed to copy backup files"
        exit 1
    }
    
    # Update BACKUP_DIR to new location
    BACKUP_DIR="$dest_dir"
    
    success "Backup files copied successfully"
}

# Backup current public directory and create new one
prepare_webroot() {
    log "Preparing webroot..."
    
    local public_dir="$SELECTED_BASEDIR/www/app/public"
    local backup_public="$SELECTED_BASEDIR/www/app/public-backup"
    
    # Backup existing public directory
    if [[ -d "$public_dir" ]]; then
        info "Backing up current public directory..."
        mv "$public_dir" "$backup_public" || {
            error "Failed to backup public directory"
            exit 1
        }
        success "Current site backed up to: public-backup"
    fi
    
    # Create new empty public directory
    mkdir -p "$public_dir"
    
    # Extract web archive
    log "Extracting web archive..."
    local web_archive="$BACKUP_DIR/web_backup_${DATE_PATTERN}.tar.gz"
    
    tar -xzf "$web_archive" -C "$public_dir" || {
        error "Failed to extract web archive"
        exit 1
    }
    
    success "Web files extracted successfully"
}

# Extract database credentials from backup wp-config.php
extract_old_config() {
    log "Extracting configuration from backup..."
    
    local backup_config="$SELECTED_BASEDIR/www/app/public-backup/wp-config.php"
    
    if [[ ! -f "$backup_config" ]]; then
        warning "Backup wp-config.php not found, skipping Redis config extraction"
        return 0
    fi
    
    # Extract values using grep and sed
    extract_define() {
        local key="$1"
        local file="$2"
        grep -E "define\(\s*['\"]${key}['\"]" "$file" 2>/dev/null \
          | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]?([^'\"]*)['\"]?.*/\1/" \
          | tr -d '\r' | head -n1
    }
    
    # Extract all Redis configuration values
    declare -gA REDIS_CONFIG
    local redis_vars=("WP_REDIS_HOST" "WP_REDIS_PORT" "WP_REDIS_PASSWORD" "WP_REDIS_DATABASE" "WP_REDIS_PREFIX" "WP_REDIS_SCHEME" "WP_REDIS_CLIENT" "WP_REDIS_TIMEOUT" "WP_REDIS_READ_TIMEOUT" "WP_REDIS_RETRY_INTERVAL")
    
    for var in "${redis_vars[@]}"; do
        local value=$(extract_define "$var" "$backup_config")
        if [[ -n "$value" ]]; then
            REDIS_CONFIG["$var"]="$value"
            info "Found $var: $value"
        fi
    done
}

# Update wp-config.php with new database credentials
update_wp_config() {
    log "Updating wp-config.php with new credentials..."
    
    cd "$SELECTED_WEBROOT" || {
        error "Failed to access webroot: $SELECTED_WEBROOT"
        exit 1
    }
    
    # Update database credentials
    "$WP_CLI" config set DB_HOST "$DB_HOST" --allow-root --skip-plugins --skip-themes --raw || warning "Failed to set DB_HOST"
    "$WP_CLI" config set DB_NAME "$DB_NAME" --allow-root --skip-plugins --skip-themes --raw || warning "Failed to set DB_NAME"
    "$WP_CLI" config set DB_USER "$DB_USER" --allow-root --skip-plugins --skip-themes --raw || warning "Failed to set DB_USER"
    "$WP_CLI" config set DB_PASSWORD "$DB_PASSWORD" --allow-root --skip-plugins --skip-themes --raw || warning "Failed to set DB_PASSWORD"
    
    # Set DB_CHARSET from backup
    if [[ -n "$DB_CHARSET" ]]; then
        "$WP_CLI" config set DB_CHARSET "$DB_CHARSET" --allow-root --skip-plugins --skip-themes --raw || warning "Failed to set DB_CHARSET"
    fi
    
    success "wp-config.php updated with new credentials"
}

# Flush all caches
flush_caches() {
    log "Flushing caches..."
    
    cd "$SELECTED_WEBROOT" || return 1
    
    "$WP_CLI" cache flush --allow-root --skip-plugins --skip-themes 2>/dev/null || warning "wp cache flush failed"
    keydb-cli -s /var/run/redis/redis.sock flushall 2>/dev/null || warning "Redis flushall failed"
    
    success "Caches flushed"
}

# Disable Redis temporarily
disable_redis() {
    log "Temporarily disabling Redis..."
    
    cd "$SELECTED_WEBROOT" || return 1
    
    "$WP_CLI" config set WP_REDIS_DISABLED true --allow-root --skip-plugins --skip-themes --raw || warning "Failed to disable Redis"
    
    success "Redis disabled"
}

# Import database
import_database() {
    log "Importing database..."
    
    local db_dump="$BACKUP_DIR/db_backup_${DATE_PATTERN}.sql"
    local err_log="$BACKUP_DIR/import_error_${DATE_PATTERN}.log"
    TEMP_FILES="$TEMP_FILES $err_log"
    
    info "Importing into: $DB_NAME"
    info "Database size: $(du -h "$db_dump" | cut -f1)"
    
    # Import with error handling
    MYSQL_PWD="$DB_PASSWORD" mysql -u"$DB_USER" -h"$DB_HOST" "$DB_NAME" -f < "$db_dump" 2>>"$err_log" || {
        error "Database import failed. Check error log: $err_log"
        exit 1
    }
    
    if [[ -s "$err_log" ]]; then
        warning "Database import completed with warnings. Check: $err_log"
    else
        success "Database imported successfully"
    fi
}

# Replace URLs in database
replace_urls() {
    log "Checking if URL replacement is needed..."
    
    cd "$SELECTED_WEBROOT" || return 1
    
    local source_url_clean="$SOURCE_URL"
    local target_url="$SELECTED_DOMAIN"
    
    # Only replace if source was not a rapydapps.cloud domain
    if [[ "$source_url_clean" == *"rapydapps.cloud"* ]]; then
        info "Source URL is rapydapps.cloud domain, skipping URL replacement"
        return 0
    fi
    
    echo
    info "=== URL Replacement ==="
    echo "Source URL: https://$source_url_clean"
    echo "Target URL: https://$target_url"
    echo
    
    prompt "Proceed with URL replacement? (Y/n): "
    read -r confirm
    confirm=${confirm:-Y}
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warning "URL replacement skipped"
        return 0
    fi
    
    # Perform search-replace
    log "Replacing URLs in database..."
    "$WP_CLI" search-replace "https://$source_url_clean" "https://$target_url" --allow-root --skip-plugins --skip-themes || warning "Search-replace failed"
    "$WP_CLI" search-replace "http://$source_url_clean" "https://$target_url" --allow-root --skip-plugins --skip-themes || warning "Search-replace (http) failed"
    
    # Check for Elementor and replace URLs
    if "$WP_CLI" plugin is-installed elementor --allow-root 2>/dev/null; then
        log "Elementor detected, replacing URLs..."
        "$WP_CLI" elementor replace-urls "https://$source_url_clean" "https://$target_url" --allow-root --skip-plugins --skip-themes || warning "Elementor replace-urls failed"
    fi
    
    success "URL replacement completed"
}

# Replace webroot paths
replace_paths() {
    log "Checking for webroot path replacement..."
    
    cd "$SELECTED_WEBROOT" || return 1
    
    # Default old webroot path
    local old_root="/var/www/webroot/ROOT"
    local new_root="$SELECTED_WEBROOT"
    
    echo
    info "=== Path Replacement ==="
    echo "Old webroot: $old_root"
    echo "New webroot: $new_root"
    echo
    
    prompt "Are these paths correct? (Y/n): "
    read -r confirm_paths
    confirm_paths=${confirm_paths:-Y}
    
    if [[ ! "$confirm_paths" =~ ^[Yy]$ ]]; then
        prompt "Enter old webroot path: "
        read -r old_root
        prompt "Enter new webroot path: "
        read -r new_root
    fi
    
    # Replace in database
    log "Replacing paths in database..."
    "$WP_CLI" search-replace "$old_root" "$new_root" --allow-root --skip-plugins --skip-themes || warning "Path search-replace in DB failed"
    
    # Replace in files
    log "Replacing paths in configuration files..."
    find "$SELECTED_WEBROOT" -type f \( -name "*.php" -o -name "*.ini" -o -name "*.conf" -o -name "*.env" -o -name ".htaccess" -o -name "wp-config.php" \) \
        -exec sed -i "s|$old_root|$new_root|g" {} + 2>/dev/null || warning "Path replacement in files failed"
    
    success "Path replacement completed"
}

# Flush WordPress caches and regenerate
finalize_wordpress() {
    log "Finalizing WordPress configuration..."
    
    cd "$SELECTED_WEBROOT" || return 1
    
    # Flush rewrite rules
    "$WP_CLI" rewrite flush --allow-root --skip-plugins --skip-themes || warning "Rewrite flush failed"
    
    # Flush Elementor CSS if installed
    if "$WP_CLI" plugin is-installed elementor --allow-root 2>/dev/null; then
        "$WP_CLI" elementor flush-css --allow-root --skip-plugins --skip-themes || warning "Elementor flush-css failed"
    fi
    
    # Final cache flush
    flush_caches
    
    success "WordPress finalized"
}

# Copy custom PHP configuration
copy_php_config() {
    local custom_php="$BACKUP_DIR/custom_php_${DATE_PATTERN}.ini"
    
    if [[ ! -f "$custom_php" ]]; then
        info "No custom PHP configuration found, skipping"
        return 0
    fi
    
    log "Copying custom PHP configuration..."
    
    local php_dir="/home/$SELECTED_USER/web/php"
    mkdir -p "$php_dir"
    
    cp "$custom_php" "$php_dir/998-rapyd.ini" || {
        warning "Failed to copy custom PHP config"
        return 1
    }
    
    success "Custom PHP configuration copied"
    
    # Restart LSWS
    log "Restarting LSWS..."
    lswsctrl condrestart || warning "LSWS restart failed"
    
    success "LSWS restarted"
}

# Add domains to site
add_domains() {
    # Skip if source was rapydapps.cloud
    if [[ "$SOURCE_URL" == *"rapydapps.cloud"* ]]; then
        info "Source was rapydapps.cloud, skipping domain addition"
        return 0
    fi
    
    log "Checking domain configuration..."
    
    local source_domain="$SOURCE_URL"
    
    # Check if www version resolves
    local www_resolves=false
    if dig +short "www.$source_domain" 2>/dev/null | grep -q '^[0-9]'; then
        www_resolves=true
        info "WWW version of domain resolves"
    fi
    
    echo
    prompt "Add source domain ($source_domain) to this site? (Y/n): "
    read -r add_domain
    add_domain=${add_domain:-Y}
    
    if [[ "$add_domain" =~ ^[Yy]$ ]]; then
        log "Adding domain: $source_domain"
        
        if [[ "$www_resolves" == "true" ]]; then
            rapyd domain add --domain "$source_domain" --www --slug "$SELECTED_SLUG" || warning "Failed to add domain with www"
        else
            rapyd domain add --domain "$source_domain" --slug "$SELECTED_SLUG" || warning "Failed to add domain"
        fi
        
        success "Domain added: $source_domain"
    fi
    
    # Prompt for additional domains
    echo
    prompt "Add additional domains? (y/N): "
    read -r add_more
    
    if [[ "$add_more" =~ ^[Yy]$ ]]; then
        prompt "Enter comma-separated list of domains: "
        read -r domains_input
        
        IFS=',' read -ra domains <<< "$domains_input"
        
        for domain in "${domains[@]}"; do
            domain=$(echo "$domain" | xargs)  # Trim whitespace
            
            # Validate with dig
            if ! dig +short "$domain" 2>/dev/null | grep -q '^[0-9]'; then
                warning "Domain $domain does not resolve, skipping"
                continue
            fi
            
            log "Adding domain: $domain"
            
            # Check www version
            if dig +short "www.$domain" 2>/dev/null | grep -q '^[0-9]'; then
                rapyd domain add --domain "$domain" --www --slug "$SELECTED_SLUG" || warning "Failed to add $domain"
            else
                rapyd domain add --domain "$domain" --slug "$SELECTED_SLUG" || warning "Failed to add $domain"
            fi
            
            success "Added: $domain"
        done
    fi
}

# Set primary domain
set_primary_domain() {
    # Skip if source was rapydapps.cloud
    if [[ "$SOURCE_URL" == *"rapydapps.cloud"* ]]; then
        info "Source was rapydapps.cloud, skipping primary domain change"
        return 0
    fi
    
    log "Configuring primary domain..."
    
    local domains_json
    domains_json=$(rapyd domain list --format=json 2>/dev/null)
    
    if [[ -z "$domains_json" ]]; then
        warning "Failed to fetch domain list"
        return 1
    fi
    
    # Find the source domain ID
    local domain_id
    domain_id=$(echo "$domains_json" | jq -r ".[] | select(.domain == \"$SOURCE_URL\" and .site_slug == \"$SELECTED_SLUG\") | .id")
    
    if [[ -z "$domain_id" ]]; then
        warning "Source domain not found in domain list, skipping primary domain change"
        return 0
    fi
    
    log "Setting $SOURCE_URL as primary domain..."
    rapyd domain set-primary --domain_id "$domain_id" || {
        warning "Failed to set primary domain"
        return 1
    }
    
    success "Primary domain set: $SOURCE_URL"
}

# Display final instructions
display_final_message() {
    echo
    echo "==============================================================="
    success "       *** SITE IMPORT COMPLETED SUCCESSFULLY ***"
    echo "==============================================================="
    echo
    info "The site has been successfully imported but there are steps pending."
    echo
    echo ">> Before running the complementary script, complete these actions:"
    echo
    echo "   1. Transfer the IP from v1"
    echo "   2. Transfer domains from v1"
    echo "   3. Associate the domain to this site through Rapyd Dashboard"
    echo "   4. Update DNS"
    echo
    warning "Once DNS changes have propagated, run the complementary script."
    echo
    echo ">> Import Summary:"
    echo "   - Site: $SELECTED_SLUG"
    echo "   - Domain: $SELECTED_DOMAIN"
    echo "   - Source: $SOURCE_URL"
    echo "   - Webroot: $SELECTED_WEBROOT"
    echo
    echo "==============================================================="
    echo
}

# Main function
main() {
    echo
    echo "==============================================================="
    info "         WordPress Import/Restore Tool v1.0"
    echo "==============================================================="
    echo
    
    check_prerequisites
    select_site
    check_backup_source
    find_backup_files
    
    echo
    prompt "Proceed with import? (Y/n): "
    read -r proceed
    proceed=${proceed:-Y}
    
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        warning "Import cancelled by user"
        exit 0
    fi
    
    copy_backup_files
    prepare_webroot
    extract_old_config
    update_wp_config
    flush_caches
    disable_redis
    flush_caches
    import_database
    replace_urls
    replace_paths
    finalize_wordpress
    copy_php_config
    add_domains
    set_primary_domain
    display_final_message
}

# Run main function
main
