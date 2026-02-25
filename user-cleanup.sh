#!/usr/bin/env bash
# =============================================================================
# migrations-user-cleanup.sh
# Finds and deletes any user whose email matches migrations@rapyd.cloud or
# migrations+<anything>@rapyd.cloud from every WordPress site on this node.
#
# Usage (direct):  bash migrations-user-cleanup.sh
# Usage (piped):   wget -qO- https://example.com/migrations-user-cleanup.sh | bash
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# Email pattern: migrations@rapyd.cloud  OR  migrations+<anything>@rapyd.cloud
EMAIL_PATTERN='^migrations(\+[^@]+)?@rapyd\.cloud$'

# WP-CLI base flags – always skip extras and suppress PHP notices/warnings
WP_FLAGS="--skip-themes --skip-plugins --skip-packages"
REDIRECT="2>/dev/null"

# ---------------------------------------------------------------------------
# 0. Verify dependencies
# ---------------------------------------------------------------------------
for cmd in rapyd wp jq sudo; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 1. Fetch site list
# ---------------------------------------------------------------------------
log "Fetching site list from rapyd..."
SITE_JSON=$(rapyd site list --format=json 2>/dev/null) || {
    err "Failed to retrieve site list."
    exit 1
}

SITE_COUNT=$(echo "$SITE_JSON" | jq 'length')
log "Found $SITE_COUNT site(s) to process."

if [[ "$SITE_COUNT" -eq 0 ]]; then
    log "No sites found. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Process each site
# ---------------------------------------------------------------------------
TOTAL_DELETED=0
TOTAL_NOT_FOUND=0
TOTAL_ERRORS=0

while IFS= read -r SITE; do
    SLUG=$(echo "$SITE"    | jq -r '.slug')
    WEBROOT=$(echo "$SITE" | jq -r '.webroot')
    SITE_USER=$(echo "$SITE" | jq -r '.user')
    STATE=$(echo "$SITE"   | jq -r '.state')

    log "--- Site: $SLUG (user: $SITE_USER, state: $STATE) ---"

    # Skip disabled sites
    if [[ "$STATE" != "ENABLED" ]]; then
        warn "Site '$SLUG' is not ENABLED (state=$STATE). Skipping."
        continue
    fi

    # Validate webroot exists
    if [[ ! -d "$WEBROOT" ]]; then
        warn "Webroot '$WEBROOT' does not exist for site '$SLUG'. Skipping."
        ((TOTAL_ERRORS++)) || true
        continue
    fi

    # Validate site user exists on the system
    if ! id "$SITE_USER" &>/dev/null; then
        warn "System user '$SITE_USER' does not exist for site '$SLUG'. Skipping."
        ((TOTAL_ERRORS++)) || true
        continue
    fi

    # ------------------------------------------------------------------
    # 2a. Search for matching users
    # ------------------------------------------------------------------
    # List all user emails, one per line, then grep for the pattern.
    # We run as the site user via sudo for proper filesystem/cache access.
    log "Searching for migrations user in '$SLUG'..."

    MATCHED_IDS=()

    # Retrieve all users with their login/email in tabular form
    # (wp user list outputs: ID, user_login, user_email, ...)
    USER_LIST=$(sudo -u "$SITE_USER" -- \
        wp user list \
            --path="$WEBROOT" \
            $WP_FLAGS \
            --fields=ID,user_email \
            --format=csv \
            --allow-root \
        2>/dev/null) || {
        warn "Failed to list users for site '$SLUG'. Skipping."
        ((TOTAL_ERRORS++)) || true
        continue
    }

    # Walk through each line (skip CSV header)
    while IFS=',' read -r UID EMAIL; do
        [[ "$UID" == "ID" ]] && continue          # skip header
        EMAIL=$(echo "$EMAIL" | tr -d '"')         # strip any quotes
        if echo "$EMAIL" | grep -qiP "$EMAIL_PATTERN"; then
            log "  Found matching user: ID=$UID  email=$EMAIL"
            MATCHED_IDS+=("$UID")
        fi
    done <<< "$USER_LIST"

    # ------------------------------------------------------------------
    # 2b. Delete matched users
    # ------------------------------------------------------------------
    if [[ ${#MATCHED_IDS[@]} -eq 0 ]]; then
        log "  No matching users found in '$SLUG'."
        ((TOTAL_NOT_FOUND++)) || true
        continue
    fi

    for UID in "${MATCHED_IDS[@]}"; do
        log "  Deleting user ID $UID from site '$SLUG'..."
        DELETE_OUTPUT=$(sudo -u "$SITE_USER" -- \
            wp user delete "$UID" \
                --path="$WEBROOT" \
                $WP_FLAGS \
                --yes \
                --allow-root \
            2>&1) && {
            log "  Deleted user ID $UID successfully."
            ((TOTAL_DELETED++)) || true
        } || {
            err "  Failed to delete user ID $UID from '$SLUG': $DELETE_OUTPUT"
            ((TOTAL_ERRORS++)) || true
        }
    done

done < <(echo "$SITE_JSON" | jq -c '.[]')

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------
log "=========================================="
log "Done."
log "  Sites where user was found & deleted : $TOTAL_DELETED"
log "  Sites where user was not found       : $TOTAL_NOT_FOUND"
log "  Sites with errors / skipped          : $TOTAL_ERRORS"
log "=========================================="
