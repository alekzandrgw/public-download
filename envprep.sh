#!/bin/bash

#===============================================================
#          Environment Preparation for WordPress Migrations
#===============================================================
# Description: Manages LiteSpeed Cache and flushes caches
#              before and after WordPress site migrations
# Author: Alexander Gil
# Version: 1.0
#
# Usage:
#   Local:  ./envprep.sh --pre-migration
#           ./envprep.sh --post-migration
#
#   Remote: wget -qO- "URL?$(date +%s)" | bash -s -- --pre-migration
#           wget -qO- "URL?$(date +%s)" | bash -s -- --post-migration
#===============================================================

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LBLUE='\033[1;34m'
NC='\033[0m' # No Color

# Global variables
WPCLIFLAGS_BASE="--allow-root --skip-themes"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Generate skip-plugins flag that excludes all plugins EXCEPT the specified one
# Usage: get_skip_plugins_except "plugin-name"
get_skip_plugins_except() {
    local keep_plugin="$1"
    local plugins_to_skip
    plugins_to_skip=$(wp plugin list --field=name --skip-plugins --skip-themes $WPCLIFLAGS_BASE 2>/dev/null | grep -v "^${keep_plugin}$" | paste -sd, -)
    if [ -n "$plugins_to_skip" ]; then
        echo "--skip-plugins=${plugins_to_skip}"
    else
        echo "--skip-plugins"
    fi
}

# Get WP CLI flags for LiteSpeed commands (keeps only litespeed-cache active)
get_wpcli_flags_ls() {
    echo "$WPCLIFLAGS_BASE $(get_skip_plugins_except 'litespeed-cache')"
}

# Get WP CLI flags for Redis commands (keeps only redis-cache active)
get_wpcli_flags_redis() {
    echo "$WPCLIFLAGS_BASE $(get_skip_plugins_except 'redis-cache')"
}

# Get WP CLI flags for general commands (skips all plugins)
get_wpcli_flags() {
    echo "$WPCLIFLAGS_BASE --skip-plugins"
}

#===============================================================
# Helper Functions
#===============================================================

print_info() {
    echo -e "${LBLUE}[${TIMESTAMP} - INFO] $1${NC}"
}

print_ok() {
    echo -e "${GREEN}[${TIMESTAMP} - OK] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[${TIMESTAMP} - WARNING] $1${NC}"
}

print_error() {
    echo -e "${RED}[${TIMESTAMP} - ERROR] $1${NC}"
}

print_header() {
    echo -e "${LBLUE}$1${NC}"
}

show_usage() {
    echo ""
    echo "Usage: $0 [--pre-migration | --post-migration]"
    echo ""
    echo "Options:"
    echo "  --pre-migration   Prepare sites for migration (flush caches, export config, disable LiteSpeed)"
    echo "  --post-migration  Restore sites after migration (import config, regenerate rules, restart lsws)"
    echo ""
    echo "This script must be run as root."
    echo ""
}

#===============================================================
# User Enumeration
#===============================================================

get_site_users() {
    rapyd site list --format json | jq -r '.[].user'
}

#===============================================================
# Pre-Migration Functions
#===============================================================

handle_litespeed_cache() {
    local user="$1"
    local wp_path="/home/${user}/web/www/app/public"
    local WPCLIFLAGS WPCLIFLAGS_LS

    cd "$wp_path" || {
        print_error "Failed to access WordPress directory for user: $user"
        return 1
    }

    # Generate flags for this site
    WPCLIFLAGS=$(get_wpcli_flags)

    # Check if LiteSpeed Cache is installed
    if ! wp plugin is-installed litespeed-cache $WPCLIFLAGS 2>/dev/null; then
        print_info "LiteSpeed Cache not installed, installing..."
        if ! wp plugin install litespeed-cache --activate $WPCLIFLAGS 2>/dev/null; then
            print_error "Failed to install LiteSpeed Cache"
            return 1
        fi
        print_ok "LiteSpeed Cache installed and activated"
    fi

    # Check if LiteSpeed Cache is active
    if ! wp plugin is-active litespeed-cache $WPCLIFLAGS 2>/dev/null; then
        print_info "LiteSpeed Cache not active, activating..."
        if ! wp plugin activate litespeed-cache $WPCLIFLAGS 2>/dev/null; then
            print_error "Failed to activate LiteSpeed Cache"
            return 1
        fi
        print_ok "LiteSpeed Cache activated"
    fi

    # Generate LiteSpeed-specific flags (keeps only litespeed-cache active)
    WPCLIFLAGS_LS=$(get_wpcli_flags_ls)

    # Export LiteSpeed Cache configuration
    print_info "Exporting LiteSpeed Cache configuration..."
    if wp litespeed-option export --filename=lsconf-premig.data $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "LiteSpeed Cache configuration exported to lsconf-premig.data"
    else
        print_warning "Failed to export LiteSpeed Cache configuration"
    fi

    return 0
}

flush_all_caches() {
    local user="$1"
    local wp_path="/home/${user}/web/www/app/public"
    local WPCLIFLAGS WPCLIFLAGS_LS WPCLIFLAGS_REDIS

    cd "$wp_path" || return 1

    # Generate flags for this site
    WPCLIFLAGS=$(get_wpcli_flags)

    # Flush WordPress Object Cache
    print_info "Flushing WordPress object cache..."
    if wp cache flush $WPCLIFLAGS 2>/dev/null; then
        print_ok "WordPress object cache flushed"
    else
        print_warning "Failed to flush WordPress object cache"
    fi

    # Flush Redis Cache (if installed and active)
    if wp plugin is-installed redis-cache $WPCLIFLAGS 2>/dev/null; then
        if wp plugin is-active redis-cache $WPCLIFLAGS 2>/dev/null; then
            # Generate Redis-specific flags (keeps only redis-cache active)
            WPCLIFLAGS_REDIS=$(get_wpcli_flags_redis)
            print_info "Flushing Redis cache..."
            if wp redis flush $WPCLIFLAGS_REDIS 2>/dev/null; then
                print_ok "Redis cache flushed"
            else
                print_warning "Failed to flush Redis cache"
            fi
        else
            print_info "Redis Cache plugin installed but not active, skipping"
        fi
    else
        print_info "Redis Cache plugin not installed, skipping"
    fi

    # Generate LiteSpeed-specific flags (keeps only litespeed-cache active)
    WPCLIFLAGS_LS=$(get_wpcli_flags_ls)

    # Flush LiteSpeed Page Cache
    print_info "Flushing LiteSpeed page cache..."
    if wp litespeed-purge all $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "LiteSpeed page cache flushed"
    else
        print_warning "Failed to flush LiteSpeed page cache"
    fi
}

disable_litespeed_cache() {
    local user="$1"
    local wp_path="/home/${user}/web/www/app/public"
    local WPCLIFLAGS_LS

    cd "$wp_path" || return 1

    # Generate LiteSpeed-specific flags (keeps only litespeed-cache active)
    WPCLIFLAGS_LS=$(get_wpcli_flags_ls)

    print_info "Disabling LiteSpeed Cache..."
    if wp litespeed-option set cache 0 $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "LiteSpeed Cache disabled"
    else
        print_warning "Failed to disable LiteSpeed Cache"
    fi
}

remove_lscache_files() {
    local user="$1"
    local lscache_dir="/home/${user}/web/.lscache"

    if [ -d "$lscache_dir" ]; then
        print_info "Removing LiteSpeed cache files..."
        rm -rf "${lscache_dir:?}"/* 2>/dev/null || true
        print_ok "LiteSpeed cache files removed"
    else
        print_info "LiteSpeed cache directory not found, skipping"
    fi
}

clean_htaccess() {
    local user="$1"
    local htaccess_path="/home/${user}/web/www/app/public/.htaccess"

    if [ -f "$htaccess_path" ]; then
        print_info "Cleaning LiteSpeed rules from .htaccess..."
        if grep -q "BEGIN LSCACHE" "$htaccess_path" 2>/dev/null; then
            sed -i '/BEGIN LSCACHE/,/END LSCACHE/d' "$htaccess_path"
            print_ok "LiteSpeed rules removed from .htaccess"
        else
            print_info "No LiteSpeed rules found in .htaccess"
        fi
    else
        print_info ".htaccess file not found, skipping"
    fi
}

#===============================================================
# Post-Migration Functions
#===============================================================

restore_litespeed_config() {
    local user="$1"
    local wp_path="/home/${user}/web/www/app/public"
    local WPCLIFLAGS_LS

    cd "$wp_path" || {
        print_error "Failed to access WordPress directory for user: $user"
        return 1
    }

    # Check if export file exists
    if [ ! -f "lsconf-premig.data" ]; then
        print_warning "LiteSpeed configuration export file not found, skipping import"
        return 0
    fi

    # Generate LiteSpeed-specific flags (keeps only litespeed-cache active)
    WPCLIFLAGS_LS=$(get_wpcli_flags_ls)

    # Import LiteSpeed Cache configuration
    local import_success=false
    print_info "Importing LiteSpeed Cache configuration..."
    if wp litespeed-option import lsconf-premig.data $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "LiteSpeed Cache configuration imported"
        import_success=true
    else
        print_warning "Failed to import LiteSpeed Cache configuration - manual intervention required"
    fi

    # Disable cache for logged-in users
    print_info "Disabling cache for logged-in users..."
    if wp litespeed-option set cache-priv false $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "Cache disabled for logged-in users"
    else
        print_warning "Failed to disable cache for logged-in users"
    fi

    # Delete the export file only after successful import
    if [ "$import_success" = true ]; then
        print_info "Removing LiteSpeed configuration export file..."
        rm -f "lsconf-premig.data" && print_ok "lsconf-premig.data deleted"
    else
        print_warning "Keeping lsconf-premig.data for manual intervention"
    fi
}

regenerate_litespeed_rules() {
    local user="$1"
    local wp_path="/home/${user}/web/www/app/public"
    local WPCLIFLAGS_LS

    cd "$wp_path" || return 1

    # Generate LiteSpeed-specific flags (keeps only litespeed-cache active)
    WPCLIFLAGS_LS=$(get_wpcli_flags_ls)

    print_info "Regenerating LiteSpeed Cache rules..."
    if wp litespeed-purge all $WPCLIFLAGS_LS 2>/dev/null; then
        print_ok "LiteSpeed Cache rules regenerated"
    else
        print_warning "Failed to regenerate LiteSpeed Cache rules"
    fi
}

restart_openlitespeed() {
    print_info "Stopping OpenLiteSpeed..."
    if ! systemctl stop lsws 2>/dev/null; then
        print_warning "Failed to stop OpenLiteSpeed"
    fi

    print_info "Terminating lingering lsphp processes..."
    pkill -9 lsphp 2>/dev/null || true

    print_info "Starting OpenLiteSpeed..."
    if systemctl start lsws 2>/dev/null; then
        print_ok "OpenLiteSpeed restarted successfully"
    else
        print_error "Failed to start OpenLiteSpeed"
        return 1
    fi
}

#===============================================================
# Main Mode Handlers
#===============================================================

run_pre_migration() {
    print_header ""
    print_header "==============================================================="
    print_header "            Pre-Migration Environment Preparation"
    print_header "==============================================================="
    print_header ""

    local users
    users=$(get_site_users)

    if [ -z "$users" ]; then
        print_error "No sites found"
        exit 1
    fi

    for user in $users; do
        print_header ""
        print_info "Processing user: $user"
        print_header "---------------------------------------------------------------"

        # Step 1: Handle LiteSpeed Cache plugin
        if ! handle_litespeed_cache "$user"; then
            print_warning "Skipping remaining steps for user: $user"
            continue
        fi

        # Step 2: Flush all caches (before disabling)
        flush_all_caches "$user"

        # Step 3: Disable LiteSpeed Cache
        disable_litespeed_cache "$user"

        # Step 4: Remove LiteSpeed cache files
        remove_lscache_files "$user"

        # Step 5: Clean .htaccess
        clean_htaccess "$user"

        print_ok "Pre-migration completed for user: $user"
    done

    print_header ""
    print_header "==============================================================="
    print_header "       Pre-Migration Preparation Completed Successfully"
    print_header "==============================================================="
    print_header ""
}

run_post_migration() {
    print_header ""
    print_header "==============================================================="
    print_header "            Post-Migration Environment Restoration"
    print_header "==============================================================="
    print_header ""

    local users
    users=$(get_site_users)

    if [ -z "$users" ]; then
        print_error "No sites found"
        exit 1
    fi

    for user in $users; do
        print_header ""
        print_info "Processing user: $user"
        print_header "---------------------------------------------------------------"

        # Step 1: Restore LiteSpeed Cache configuration
        restore_litespeed_config "$user"

        # Step 2: Regenerate LiteSpeed Cache rules
        regenerate_litespeed_rules "$user"

        print_ok "Post-migration completed for user: $user"
    done

    # Step 3: Restart OpenLiteSpeed (once, after all sites)
    print_header ""
    restart_openlitespeed

    print_header ""
    print_header "==============================================================="
    print_header "       Post-Migration Restoration Completed Successfully"
    print_header "==============================================================="
    print_header ""
}

#===============================================================
# Main Execution
#===============================================================

main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi

    # Check for required commands
    if ! command -v rapyd &> /dev/null; then
        print_error "rapyd command not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq command not found"
        exit 1
    fi

    if ! command -v wp &> /dev/null; then
        print_error "wp (WP-CLI) command not found"
        exit 1
    fi

    # Parse arguments
    local pre_migration=false
    local post_migration=false

    for arg in "$@"; do
        case "$arg" in
            --pre-migration)
                pre_migration=true
                ;;
            --post-migration)
                post_migration=true
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $arg"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate that exactly one flag is provided
    if [ "$pre_migration" = true ] && [ "$post_migration" = true ]; then
        print_error "Cannot use both --pre-migration and --post-migration at the same time"
        show_usage
        exit 1
    fi

    if [ "$pre_migration" = false ] && [ "$post_migration" = false ]; then
        print_error "You must specify either --pre-migration or --post-migration"
        show_usage
        exit 1
    fi

    # Execute the appropriate mode
    if [ "$pre_migration" = true ]; then
        run_pre_migration
    else
        run_post_migration
    fi

    # Auto-delete script if running from a file (not piped)
    if [ -f "$SCRIPT_PATH" ] && [[ "$SCRIPT_PATH" != "bash" ]] && [[ "$SCRIPT_PATH" != "-bash" ]]; then
        print_info "Cleaning up script file..."
        rm -f -- "$SCRIPT_PATH" && print_ok "Script deleted: $SCRIPT_PATH"
    fi
}

# Run main function with all arguments
main "$@"
