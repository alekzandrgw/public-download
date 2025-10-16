#!/bin/bash

#===============================================================
# Path & URL Replacement Script
# Replaces old paths and URLs in files across the webroot
#===============================================================

set -e

# Configuration
SUPPORTED_EXTENSIONS="*.php|*.htaccess|*.env|*.ini|*.json|*.xml|*.html|*.css"
TEMP_LOG_FILE="/tmp/path_url_replace_$(date +%s).log"

#===============================================================
# Helper Functions
#===============================================================

print_header() {
    echo ""
    echo "========================================================"
    echo "$1"
    echo "========================================================"
}

print_info() {
    echo "[INFO] $1"
}

print_success() {
    echo "[✓] $1"
}

print_warning() {
    echo "[⚠] $1"
}

print_error() {
    echo "[✗] $1" >&2
}

escape_for_sed() {
    echo "$1" | sed 's/[\/&.]/\\&/g'
}

validate_path() {
    local path="$1"
    local label="$2"
    
    if [ -z "$path" ]; then
        print_error "$label cannot be empty"
        return 1
    fi
    
    return 0
}

#===============================================================
# Path Replacement Function
#===============================================================

replace_paths() {
    local old_path="$1"
    local new_path="$2"
    
    print_header "Path Replacement"
    print_info "Old path: $old_path"
    print_info "New path: $new_path"
    
    print_info "Searching for files containing old path..."
    
    # Find files containing the old path
    local old_path_escaped=$(escape_for_sed "$old_path")
    local files_to_process=$(find . -maxdepth 10 -type f \
        \( -name "*.php" -o -name "*.htaccess" -o -name "*.env" -o -name "*.ini" -o -name "*.json" -o -name "*.xml" -o -name "*.html" -o -name "*.css" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/vendor/*" \
        ! -path "*/wp-content/cache/*" \
        ! -name "*.log" \
        -exec grep -l -F "$old_path" {} \; 2>/dev/null || true)
    
    if [ -z "$files_to_process" ]; then
        print_warning "No files found containing old path"
        return 0
    fi
    
    local file_count=$(echo "$files_to_process" | wc -l)
    print_info "Found $file_count file(s) that will be updated"
    
    # Ask for confirmation
    read -p "Proceed with path replacement? (y/N): " -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_warning "Path replacement cancelled"
        return 0
    fi
    
    local files_modified=0
    local old_path_escaped=$(escape_for_sed "$old_path")
    local old_path_slash_escaped=$(escape_for_sed "${old_path}/")
    local new_path_escaped=$(escape_for_sed "$new_path")
    
    # Process each file
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            sed -i "s|${old_path_slash_escaped}|${new_path_escaped}/|g" "$file"
            sed -i "s|${old_path_escaped}|${new_path_escaped}|g" "$file"
            
            files_modified=$((files_modified + 1))
            print_success "Updated: $file"
        fi
    done <<< "$files_to_process"
    
    print_success "Modified $files_modified file(s) with new path"
}

#===============================================================
# URL Replacement Function
#===============================================================

replace_urls() {
    local old_url="$1"
    local new_url="$2"
    
    print_header "URL Replacement"
    print_info "Old URL: $old_url"
    print_info "New URL: $new_url"
    
    print_info "Searching for files containing old URL..."
    
    # Find files containing the old URL
    local files_to_process=$(find . -maxdepth 10 -type f \
        \( -name "*.php" -o -name "*.htaccess" -o -name "*.env" -o -name "*.ini" -o -name "*.json" -o -name "*.xml" -o -name "*.html" -o -name "*.css" \) \
        ! -path "*/node_modules/*" \
        ! -path "*/vendor/*" \
        ! -path "*/wp-content/cache/*" \
        ! -name "*.log" \
        -exec grep -l "$old_url" {} \; 2>/dev/null || true)
    
    if [ -z "$files_to_process" ]; then
        print_warning "No files found containing old URL"
        return 0
    fi
    
    local file_count=$(echo "$files_to_process" | wc -l)
    print_info "Found $file_count file(s) that will be updated"
    
    # Ask for confirmation
    read -p "Proceed with URL replacement? (y/N): " -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_warning "URL replacement cancelled"
        return 0
    fi
    
    local files_modified=0
    local old_url_escaped=$(escape_for_sed "$old_url")
    local new_url_escaped=$(escape_for_sed "$new_url")
    
    # Process each file
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            sed -i "s|${old_url_escaped}|${new_url_escaped}|g" "$file"
            
            files_modified=$((files_modified + 1))
            print_success "Updated: $file"
        fi
    done <<< "$files_to_process"
    
    print_success "Modified $files_modified file(s) with new URL"
}

#===============================================================
# Main Script
#===============================================================

main() {
    print_header "Path & URL Replacement Tool"
    
    # Ask for replacement type
    echo ""
    echo "What would you like to replace?"
    echo "1) Path only"
    echo "2) URL only"
    echo "3) Both path and URL"
    read -p "Enter choice (1-3): " -r choice
    
    case $choice in
        1)
            read -p "Enter old path: " -r old_path
            read -p "Enter new path: " -r new_path
            
            validate_path "$old_path" "Old path" || exit 1
            validate_path "$new_path" "New path" || exit 1
            
            if [ "$old_path" = "$new_path" ]; then
                print_error "Old and new paths cannot be identical"
                exit 1
            fi
            
            replace_paths "$old_path" "$new_path"
            ;;
        2)
            read -p "Enter old URL: " -r old_url
            read -p "Enter new URL: " -r new_url
            
            validate_path "$old_url" "Old URL" || exit 1
            validate_path "$new_url" "New URL" || exit 1
            
            if [ "$old_url" = "$new_url" ]; then
                print_error "Old and new URLs cannot be identical"
                exit 1
            fi
            
            replace_urls "$old_url" "$new_url"
            ;;
        3)
            read -p "Enter old path: " -r old_path
            read -p "Enter new path: " -r new_path
            read -p "Enter old URL: " -r old_url
            read -p "Enter new URL: " -r new_url
            
            validate_path "$old_path" "Old path" || exit 1
            validate_path "$new_path" "New path" || exit 1
            validate_path "$old_url" "Old URL" || exit 1
            validate_path "$new_url" "New URL" || exit 1
            
            if [ "$old_path" = "$new_path" ]; then
                print_error "Old and new paths cannot be identical"
                exit 1
            fi
            
            if [ "$old_url" = "$new_url" ]; then
                print_error "Old and new URLs cannot be identical"
                exit 1
            fi
            
            replace_paths "$old_path" "$new_path"
            replace_urls "$old_url" "$new_url"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_header "Complete"
    print_success "All operations completed successfully"
}

main "$@"
