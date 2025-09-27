#!/bin/bash

# WordPress S3 Backup Script (Simplified with rclone copy)
# Run as root: ./backup_wordpress.sh

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
AWS_ACCESS_KEY=""
AWS_SECRET_KEY=""
AWS_REGION=""
S3_BUCKET=""
WEBROOT=""
SITE_URL=""
DB_CHARSET=""
TEMP_FILES=""

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

# Function to read input with validation
read_input() {
    local prompt_text="$1"
    local variable_name="$2"
    local is_secret="${3:-false}"
    local validation_func="${4:-}"
    
    while true; do
        if [[ "$is_secret" == "true" ]]; then
            prompt "$prompt_text"
            read -s input
            echo  # Add newline after secret input
        else
            prompt "$prompt_text"
            read input
        fi
        
        if [[ -z "$input" ]]; then
            error "This field cannot be empty. Please try again."
            continue
        fi
        
        # Run validation function if provided
        if [[ -n "$validation_func" ]] && ! $validation_func "$input"; then
            continue
        fi
        
        # Set the variable
        declare -g "$variable_name"="$input"
        break
    done
}

# Validation functions
validate_aws_region() {
    local region="$1"
    # Basic AWS region format validation
    if [[ ! "$region" =~ ^[a-z]{2,3}-[a-z]+-[0-9]$ ]]; then
        error "Invalid AWS region format. Examples: us-west-2, eu-central-1, ap-southeast-1"
        return 1
    fi
    return 0
}

validate_s3_bucket() {
    local bucket="$1"
    # Basic S3 bucket name validation
    if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9\-]*[a-z0-9]$ ]] || [[ ${#bucket} -lt 3 ]] || [[ ${#bucket} -gt 63 ]]; then
        error "Invalid S3 bucket name. Must be 3-63 chars, lowercase, numbers, hyphens only"
        return 1
    fi
    return 0
}

validate_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "Directory '$dir' does not exist"
        return 1
    fi
    return 0
}

collect_configuration() {
    echo
    info "=== WordPress S3 Backup Configuration ==="
    echo
    
    # AWS Configuration
    info "AWS Configuration:"
    read_input "Enter AWS Access Key ID: " "AWS_ACCESS_KEY"
    read_input "Enter AWS Secret Access Key: " "AWS_SECRET_KEY" "true"
    read_input "Enter AWS Region (e.g., us-west-2): " "AWS_REGION" "false" "validate_aws_region"
    read_input "Enter S3 Bucket Name: " "S3_BUCKET" "false" "validate_s3_bucket"
    
    echo
    info "WordPress Configuration:"
    read_input "Enter WordPress root directory path [/var/www/webroot/ROOT]: " "input"
    WEBROOT="${input:-/var/www/webroot/ROOT}"
    validate_directory "$WEBROOT" || exit 1
    
    # Display configuration summary
    echo
    info "=== Configuration Summary ==="
    echo "AWS Region: $AWS_REGION"
    echo "S3 Bucket: $S3_BUCKET"
    echo "WordPress Root: $WEBROOT"
    echo
    
    # Confirm configuration
    prompt "Is this configuration correct? (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        error "Configuration cancelled by user"
        exit 1
    fi
}

cleanup() {
    log "Performing cleanup..."
    
    # Remove rclone config
    if rclone config show myaws >/dev/null 2>&1; then
        rclone config delete myaws
        log "Removed rclone configuration"
    fi
    
    # Clean up temporary files
    if [[ -n "$TEMP_FILES" ]]; then
        cd "$WEBROOT/../" && rm -f $TEMP_FILES 2>/dev/null || true
        log "Removed temporary files: $TEMP_FILES"
    fi
    
    # Remove rclone if it was installed by this script
    if command -v rclone &> /dev/null; then
        prompt "Remove rclone from system? (y/N): "
        read -r remove_rclone
        if [[ "$remove_rclone" =~ ^[Yy]$ ]]; then
            yum remove -y rclone
            log "Removed rclone from system"
        fi
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
    
    if ! command -v yum &> /dev/null; then
        error "yum package manager not found"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

install_rclone() {
    log "Installing rclone..."
    
    if command -v rclone &> /dev/null; then
        warning "rclone is already installed"
    else
        yum install -y rclone
        log "rclone installed successfully"
    fi
}

setup_rclone() {
    log "Setting up rclone configuration..."
    
    rclone config create myaws s3 \
        provider AWS \
        env_auth false \
        access_key_id "$AWS_ACCESS_KEY" \
        secret_access_key "$AWS_SECRET_KEY" \
        region "$AWS_REGION"
    
    # Test connection
    log "Testing S3 connection..."
    if ! rclone lsd myaws:$S3_BUCKET >/dev/null 2>&1; then
        error "Failed to connect to S3 bucket '$S3_BUCKET'"
        error "Please check your AWS credentials and bucket name"
        exit 1
    fi
    
    log "rclone configuration completed successfully"
}

get_wordpress_info() {
    log "Getting WordPress information..."
    
    # Change to WordPress directory
    cd "$WEBROOT" || {
        error "Failed to access WordPress directory '$WEBROOT'"
        exit 1
    }
    
    # Check if WordPress is installed
    if ! wp core is-installed --allow-root --skip-plugins --skip-themes --quiet; then
        error "WordPress not installed in '$WEBROOT'"
        exit 1
    fi
    
    # Get site URL and charset
    SITE_URL=$(wp option get siteurl --allow-root --skip-plugins --skip-themes --quiet | sed 's|https\?://||')
    DB_CHARSET=$(wp eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes --quiet | tr -d '\n')
    
    if [[ -z "$SITE_URL" ]] || [[ -z "$DB_CHARSET" ]]; then
        error "Failed to get WordPress information"
        exit 1
    fi
    
    log "Site URL: $SITE_URL"
    log "Database charset: $DB_CHARSET"
}

export_database() {
    log "Exporting database..."
    
    # Change to WordPress directory
    cd "$WEBROOT" || {
        error "Failed to access WordPress directory '$WEBROOT'"
        exit 1
    }
    
    # Export database
    if ! wp db export ../stg-db-export.sql --default-character-set="$DB_CHARSET" --allow-root --skip-plugins --skip-themes --quiet; then
        error "Database export failed"
        exit 1
    fi
    
    local db_size=$(stat -c%s "$WEBROOT/../stg-db-export.sql" 2>/dev/null || echo "0")
    log "Database exported successfully ($(numfmt --to=iec $db_size))"
}

create_archive() {
    log "Creating website archive..."
    
    # Get directory size for progress estimation
    local webroot_size=$(du -sb "$WEBROOT" 2>/dev/null | cut -f1 || echo "0")
    info "Archiving $(numfmt --to=iec $webroot_size) of data..."
    
    # Change to parent directory
    cd "$WEBROOT/../" || {
        error "Failed to access parent directory of '$WEBROOT'"
        exit 1
    }
    
    # Create archive with exclusions
    if ! tar -czf ROOT.tar.gz \
        --exclude='ROOT/wp-content/ai1wm-backups' \
        --exclude='ROOT/wp-content/backups' \
        --exclude='ROOT/wp-content/backups-dup-pro' \
        --exclude='ROOT/wp-content/updraft' \
        --exclude='ROOT/wp-content/uploads/backup-*' \
        --exclude='ROOT/wp-content/uploads/backwpup-*' \
        --exclude='ROOT/wp-content/cache' \
        --exclude='ROOT/wp-content/uploads/cache' \
        --exclude='ROOT/wp-content/w3tc-cache' \
        --exclude='ROOT/wp-content/wp-rocket-cache' \
        --exclude='ROOT/wp-content/litespeed' \
        --exclude='ROOT/wp-content/debug.log' \
        --exclude='ROOT/wp-content/error_log' \
        --exclude='ROOT/wp-config-backup.php' \
        --exclude='ROOT/error_log' \
        --exclude='ROOT/wp-content/ewww' \
        --exclude='ROOT/wp-content/smush-webp' \
        --exclude='ROOT/wp-content/uploads/wp-file-manager-pro/fm_backup' \
        ROOT; then
        error "Failed to create archive"
        exit 1
    fi
    
    local archive_size=$(stat -c%s "ROOT.tar.gz" 2>/dev/null || echo "0")
    log "Website archive created successfully ($(numfmt --to=iec $archive_size))"
}

upload_to_s3() {
    log "Uploading backup files to S3..."
    
    # Change to directory with backup files
    cd "$WEBROOT/../" || {
        error "Failed to access backup directory"
        exit 1
    }
    
    # Get file sizes for progress tracking
    local db_size=$(stat -c%s "stg-db-export.sql" 2>/dev/null || echo "0")
    local archive_size=$(stat -c%s "ROOT.tar.gz" 2>/dev/null || echo "0")
    local total_size=$((db_size + archive_size))
    
    info "Upload size: $(numfmt --to=iec $total_size)"
    info "Destination: s3://$S3_BUCKET/$SITE_URL/"
    
    # Upload database file
    log "Uploading database export..."
    if ! rclone copy stg-db-export.sql "myaws:$S3_BUCKET/$SITE_URL/" --progress; then
        error "Failed to upload database export"
        exit 1
    fi
    
    # Upload website archive
    log "Uploading website archive..."
    if ! rclone copy ROOT.tar.gz "myaws:$S3_BUCKET/$SITE_URL/" --progress; then
        error "Failed to upload website archive"
        exit 1
    fi
    
    log "All files uploaded successfully"
    
    # Set temp files for cleanup
    TEMP_FILES="ROOT.tar.gz stg-db-export.sql"
}

verify_backup() {
    log "Verifying backup in S3..."
    
    # List files in S3 to verify
    local s3_files
    s3_files=$(rclone ls "myaws:$S3_BUCKET/$SITE_URL" 2>/dev/null || true)
    
    if [[ -z "$s3_files" ]]; then
        error "Failed to verify backup in S3 - no files found"
        exit 1
    fi
    
    # Check that both required files exist
    if ! echo "$s3_files" | grep -q "ROOT.tar.gz"; then
        error "Website archive not found in S3"
        exit 1
    fi
    
    if ! echo "$s3_files" | grep -q "stg-db-export.sql"; then
        error "Database export not found in S3"
        exit 1
    fi
    
    info "Backup contents:"
    echo "$s3_files" | while read -r size file; do
        echo "  - $file ($(numfmt --to=iec $size))"
    done
    
    log "Backup verification completed successfully"
}

display_summary() {
    echo
    info "=== Backup Summary ==="
    echo "✅ WordPress site: $SITE_URL"
    echo "✅ S3 Location: s3://$S3_BUCKET/$SITE_URL/"
    echo "✅ Files uploaded:"
    echo "   - ROOT.tar.gz (Website files)"
    echo "   - stg-db-export.sql (Database export)"
    echo "✅ Database charset: $DB_CHARSET"
    echo
    log "WordPress backup completed successfully!"
    echo
}

main() {
    echo
    info "=== WordPress S3 Backup Script ==="
    echo
    
    collect_configuration
    echo
    
    check_prerequisites
    install_rclone
    setup_rclone
    get_wordpress_info
    export_database
    create_archive
    upload_to_s3
    verify_backup
    display_summary
}

# Run main function
main
