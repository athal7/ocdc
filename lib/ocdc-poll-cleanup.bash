#!/usr/bin/env bash
#
# ocdc-poll-cleanup.bash - Cleanup queue management for ocdc poll
#
# Manages the cleanup queue for tracking sessions that should be cleaned up
# when their associated PRs/issues are closed or merged.
#
# Usage:
#   source "$(dirname "$0")/ocdc-poll-cleanup.bash"
#
# Functions:
#   cleanup_parse_duration          - Parse duration string (e.g., "5m") to seconds
#   cleanup_queue_add               - Add item to cleanup queue
#   cleanup_queue_remove            - Remove item from cleanup queue
#   cleanup_queue_is_queued         - Check if item is in cleanup queue
#   cleanup_queue_get_ready         - Get items ready for cleanup
#   cleanup_parse_github_pr_state   - Parse gh CLI output for PR state
#   cleanup_get_config_with_defaults - Get cleanup config with defaults
#   cleanup_should_trigger_for_reason - Check if reason should trigger cleanup
#
# Requires ocdc-paths.bash to be sourced first.

# Prevent multiple sourcing
[[ -n "${_OCDC_POLL_CLEANUP_LOADED:-}" ]] && return 0
_OCDC_POLL_CLEANUP_LOADED=1

# Source file locking if not already loaded
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "${SCRIPT_DIR}/ocdc-file-lock.bash" 2>/dev/null || true

# Default cleanup queue path (can be overridden via environment)
OCDC_CLEANUP_QUEUE_FILE="${OCDC_CLEANUP_QUEUE_FILE:-${OCDC_POLL_STATE_DIR:-$HOME/.local/share/ocdc/poll-state}/cleanup-queue.json}"

# Default cleanup configuration (JSON values where needed)
_CLEANUP_DEFAULT_ENABLED=true
_CLEANUP_DEFAULT_DELAY="5m"
_CLEANUP_DEFAULT_ON='["merged", "closed"]'
_CLEANUP_DEFAULT_ACTIONS='["kill_session", "stop_container"]'

# =============================================================================
# Duration Parsing
# =============================================================================

# Parse a duration string to seconds
# Supports: 30s, 5m, 2h, or plain number (treated as minutes)
# Usage: cleanup_parse_duration "5m"  # Returns: 300
cleanup_parse_duration() {
  local duration="$1"
  
  # Handle empty input
  if [[ -z "$duration" ]]; then
    echo "300"  # Default 5 minutes
    return 0
  fi
  
  # Parse with unit suffix
  local num unit
  if [[ "$duration" =~ ^([0-9]+)([smh])$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    
    case "$unit" in
      s) echo "$num" ;;
      m) echo "$((num * 60))" ;;
      h) echo "$((num * 3600))" ;;
    esac
    return 0
  fi
  
  # Plain number - treat as minutes (backwards compatibility)
  if [[ "$duration" =~ ^[0-9]+$ ]]; then
    echo "$((duration * 60))"
    return 0
  fi
  
  # Invalid format - return default
  echo "300"
}

# =============================================================================
# Queue File Management
# =============================================================================

# Ensure the cleanup queue file exists with valid JSON
_cleanup_ensure_queue_file() {
  if [[ ! -f "$OCDC_CLEANUP_QUEUE_FILE" ]]; then
    mkdir -p "$(dirname "$OCDC_CLEANUP_QUEUE_FILE")"
    echo '{"items":[]}' > "$OCDC_CLEANUP_QUEUE_FILE"
  fi
}

# Get the lock file path for the cleanup queue
_cleanup_queue_lock() {
  echo "${OCDC_CLEANUP_QUEUE_FILE}.lock"
}

# =============================================================================
# Queue Management - Add
# =============================================================================

# Add an item to the cleanup queue
# Usage: cleanup_queue_add <key> <poll_id> <reason> <tmux_session> <clone_path> <source_url> <source_type> <delay>
cleanup_queue_add() {
  local key="$1"
  local poll_id="$2"
  local reason="$3"
  local tmux_session="$4"
  local clone_path="$5"
  local source_url="$6"
  local source_type="$7"
  local delay="${8:-5m}"
  
  _cleanup_ensure_queue_file
  
  # Check if already queued
  if cleanup_queue_is_queued "$key"; then
    return 0  # Already queued, skip
  fi
  
  # Calculate timestamps
  local queued_at cleanup_after delay_seconds
  queued_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  delay_seconds=$(cleanup_parse_duration "$delay")
  
  # Calculate cleanup_after time
  # macOS date doesn't support -d, use different approach
  local now_epoch cleanup_epoch
  now_epoch=$(date +%s)
  cleanup_epoch=$((now_epoch + delay_seconds))
  
  # Format as ISO timestamp (works on both macOS and Linux)
  # macOS uses -r, Linux uses -d "@epoch"
  if cleanup_after=$(date -u -r "$cleanup_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
    : # macOS succeeded
  else
    # Linux fallback
    cleanup_after=$(date -u -d "@$cleanup_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$queued_at")
  fi
  
  # Build item JSON
  local item_json
  item_json=$(jq -n \
    --arg key "$key" \
    --arg poll_id "$poll_id" \
    --arg reason "$reason" \
    --arg queued_at "$queued_at" \
    --arg cleanup_after "$cleanup_after" \
    --arg tmux_session "$tmux_session" \
    --arg clone_path "$clone_path" \
    --arg source_url "$source_url" \
    --arg source_type "$source_type" \
    '{
      key: $key,
      poll_id: $poll_id,
      reason: $reason,
      queued_at: $queued_at,
      cleanup_after: $cleanup_after,
      tmux_session: $tmux_session,
      clone_path: $clone_path,
      source_url: $source_url,
      source_type: $source_type
    }')
  
  # Add to queue with locking
  local lock_file
  lock_file=$(_cleanup_queue_lock)
  lock_file "$lock_file"
  
  local tmp
  tmp=$(mktemp)
  jq --argjson item "$item_json" '.items += [$item]' "$OCDC_CLEANUP_QUEUE_FILE" > "$tmp"
  mv "$tmp" "$OCDC_CLEANUP_QUEUE_FILE"
  
  unlock_file "$lock_file"
}

# =============================================================================
# Queue Management - Remove
# =============================================================================

# Remove an item from the cleanup queue
# Usage: cleanup_queue_remove <key>
cleanup_queue_remove() {
  local key="$1"
  
  _cleanup_ensure_queue_file
  
  local lock_file
  lock_file=$(_cleanup_queue_lock)
  lock_file "$lock_file"
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" '.items = [.items[] | select(.key != $key)]' "$OCDC_CLEANUP_QUEUE_FILE" > "$tmp"
  mv "$tmp" "$OCDC_CLEANUP_QUEUE_FILE"
  
  unlock_file "$lock_file"
}

# =============================================================================
# Queue Management - Query
# =============================================================================

# Check if an item is in the cleanup queue
# Usage: cleanup_queue_is_queued <key>
# Returns: 0 if queued, 1 if not
cleanup_queue_is_queued() {
  local key="$1"
  
  _cleanup_ensure_queue_file
  
  jq -e --arg key "$key" '.items[] | select(.key == $key)' "$OCDC_CLEANUP_QUEUE_FILE" >/dev/null 2>&1
}

# Get all items that are ready for cleanup (cleanup_after has passed)
# Usage: cleanup_queue_get_ready
# Returns: JSON array of ready items
cleanup_queue_get_ready() {
  _cleanup_ensure_queue_file
  
  local now_epoch
  now_epoch=$(date +%s)
  
  # Read all items and filter those ready for cleanup
  jq -c '.items[]' "$OCDC_CLEANUP_QUEUE_FILE" 2>/dev/null | while read -r item; do
    local cleanup_after cleanup_epoch
    cleanup_after=$(echo "$item" | jq -r '.cleanup_after')
    
    # Parse ISO timestamp to epoch
    # Try macOS format first, then Linux
    if cleanup_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cleanup_after" +%s 2>/dev/null); then
      : # macOS succeeded
    else
      cleanup_epoch=$(date -d "$cleanup_after" +%s 2>/dev/null || echo "9999999999")
    fi
    
    if [[ $now_epoch -ge $cleanup_epoch ]]; then
      echo "$item"
    fi
  done
}

# Get a specific item from the queue by key
# Usage: cleanup_queue_get <key>
# Returns: JSON object or empty
cleanup_queue_get() {
  local key="$1"
  
  _cleanup_ensure_queue_file
  
  jq -c --arg key "$key" '.items[] | select(.key == $key)' "$OCDC_CLEANUP_QUEUE_FILE" 2>/dev/null
}

# List all items in the cleanup queue
# Usage: cleanup_queue_list
# Returns: JSON array of all items
cleanup_queue_list() {
  _cleanup_ensure_queue_file
  
  jq -c '.items' "$OCDC_CLEANUP_QUEUE_FILE" 2>/dev/null
}

# =============================================================================
# PR State Detection
# =============================================================================

# Parse GitHub PR state from gh CLI output
# Usage: cleanup_parse_github_pr_state '{"state":"MERGED","mergedAt":"..."}'
# Returns: JSON {"should_cleanup": bool, "reason": "merged"|"closed"|null}
cleanup_parse_github_pr_state() {
  local gh_output="$1"
  
  local state merged_at
  state=$(echo "$gh_output" | jq -r '.state // ""' | tr '[:upper:]' '[:lower:]')
  merged_at=$(echo "$gh_output" | jq -r '.mergedAt // ""')
  
  local should_cleanup="false"
  local reason="null"
  
  if [[ "$state" == "merged" ]] || [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
    should_cleanup="true"
    reason="merged"
  elif [[ "$state" == "closed" ]]; then
    should_cleanup="true"
    reason="closed"
  fi
  
  jq -n --argjson should_cleanup "$should_cleanup" --arg reason "$reason" \
    '{should_cleanup: $should_cleanup, reason: (if $reason == "null" then null else $reason end)}'
}

# Check the state of a GitHub PR using gh CLI
# Usage: cleanup_check_github_pr_state <owner/repo> <pr_number>
# Returns: JSON {"should_cleanup": bool, "reason": "merged"|"closed"|null}
cleanup_check_github_pr_state() {
  local repo="$1"
  local pr_number="$2"
  
  local gh_output
  if ! gh_output=$(gh pr view --repo "$repo" "$pr_number" --json state,mergedAt 2>/dev/null); then
    # Failed to get PR state - assume still open
    echo '{"should_cleanup": false, "reason": null}'
    return 0
  fi
  
  cleanup_parse_github_pr_state "$gh_output"
}

# Check if a source URL's item should be cleaned up
# Usage: cleanup_check_source_state <source_type> <source_url>
# Returns: JSON {"should_cleanup": bool, "reason": "merged"|"closed"|null}
cleanup_check_source_state() {
  local source_type="$1"
  local source_url="$2"
  
  case "$source_type" in
    github_pr)
      # Parse URL: https://github.com/owner/repo/pull/123
      if [[ "$source_url" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
        local repo="${BASH_REMATCH[1]}"
        local pr_number="${BASH_REMATCH[2]}"
        cleanup_check_github_pr_state "$repo" "$pr_number"
      else
        echo '{"should_cleanup": false, "reason": null}'
      fi
      ;;
    github_issue)
      # Parse URL: https://github.com/owner/repo/issues/123
      if [[ "$source_url" =~ github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then
        local repo="${BASH_REMATCH[1]}"
        local issue_number="${BASH_REMATCH[2]}"
        # Check issue state using gh CLI
        local gh_output
        if gh_output=$(gh issue view --repo "$repo" "$issue_number" --json state 2>/dev/null); then
          local state
          state=$(echo "$gh_output" | jq -r '.state // ""' | tr '[:upper:]' '[:lower:]')
          if [[ "$state" == "closed" ]]; then
            echo '{"should_cleanup": true, "reason": "closed"}'
            return 0
          fi
        fi
      fi
      echo '{"should_cleanup": false, "reason": null}'
      ;;
    *)
      # Unknown source type - don't cleanup
      echo '{"should_cleanup": false, "reason": null}'
      ;;
  esac
}

# =============================================================================
# Cleanup Configuration
# =============================================================================

# Get cleanup config with defaults applied
# Usage: cleanup_get_config_with_defaults '{"delay": "10m"}'
# Returns: JSON with all fields populated
cleanup_get_config_with_defaults() {
  local config_json="$1"
  
  # Handle empty or null input
  if [[ -z "$config_json" ]] || [[ "$config_json" == "null" ]]; then
    config_json='{}'
  fi
  
  # Merge with defaults
  jq -n \
    --argjson config "$config_json" \
    --argjson default_enabled "$_CLEANUP_DEFAULT_ENABLED" \
    --argjson default_on "$_CLEANUP_DEFAULT_ON" \
    --argjson default_actions "$_CLEANUP_DEFAULT_ACTIONS" \
    --arg default_delay "$_CLEANUP_DEFAULT_DELAY" \
    '{
      enabled: ($config.enabled // $default_enabled),
      delay: ($config.delay // $default_delay),
      on: ($config.on // $default_on),
      actions: ($config.actions // $default_actions)
    }'
}

# Check if a reason should trigger cleanup based on config
# Usage: cleanup_should_trigger_for_reason '{"on": ["merged"]}' "merged"
# Returns: 0 if should trigger, 1 if not
cleanup_should_trigger_for_reason() {
  local config_json="$1"
  local reason="$2"
  
  # Get the 'on' array from config (with defaults)
  local on_array
  on_array=$(cleanup_get_config_with_defaults "$config_json" | jq -r '.on')
  
  # Check if reason is in the array
  echo "$on_array" | jq -e --arg reason "$reason" 'index($reason) != null' >/dev/null 2>&1
}

# Get the list of cleanup actions from config
# Usage: cleanup_get_actions '{"actions": ["kill_session"]}'
# Returns: space-separated list of actions
cleanup_get_actions() {
  local config_json="$1"
  
  cleanup_get_config_with_defaults "$config_json" | jq -r '.actions[]'
}

# =============================================================================
# Cleanup Execution
# =============================================================================

# Execute a single cleanup action
# Usage: cleanup_execute_action <action> <tmux_session> <clone_path>
# Returns: 0 on success, 1 on failure (with warning logged)
cleanup_execute_action() {
  local action="$1"
  local tmux_session="$2"
  local clone_path="$3"
  
  case "$action" in
    kill_session)
      _cleanup_action_kill_session "$tmux_session"
      ;;
    stop_container)
      _cleanup_action_stop_container "$clone_path"
      ;;
    remove_clone)
      _cleanup_action_remove_clone "$clone_path"
      ;;
    *)
      echo "[cleanup] Unknown action: $action" >&2
      return 1
      ;;
  esac
}

# Kill tmux session
_cleanup_action_kill_session() {
  local session="$1"
  
  if [[ -z "$session" ]]; then
    return 0
  fi
  
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
}

# Stop devcontainer
_cleanup_action_stop_container() {
  local clone_path="$1"
  
  if [[ -z "$clone_path" ]] || [[ ! -d "$clone_path" ]]; then
    return 0
  fi
  
  # Use ocdc down if available
  if command -v ocdc >/dev/null 2>&1; then
    ocdc down "$clone_path" 2>/dev/null || true
  fi
}

# Remove clone directory (with safety check)
_cleanup_action_remove_clone() {
  local clone_path="$1"
  
  if [[ -z "$clone_path" ]] || [[ ! -d "$clone_path" ]]; then
    return 0
  fi
  
  # Safety check: only remove if in clones directory
  local clones_dir="${OCDC_CLONES_DIR:-$HOME/.cache/devcontainer-clones}"
  if [[ "$clone_path" != "$clones_dir"/* ]]; then
    echo "[cleanup] Refusing to remove clone outside clones directory: $clone_path" >&2
    return 1
  fi
  
  # Safety check: don't remove if git is dirty
  if ! ocdc_is_safe_to_remove "$clone_path" 2>/dev/null; then
    echo "[cleanup] Skipping remove_clone (uncommitted/unpushed changes): $clone_path" >&2
    return 1
  fi
  
  rm -rf "$clone_path"
  
  # Clean up empty parent directories
  local parent
  parent=$(dirname "$clone_path")
  if [[ -d "$parent" ]] && [[ -z "$(ls -A "$parent" 2>/dev/null)" ]]; then
    rmdir "$parent" 2>/dev/null || true
  fi
}

# Execute all cleanup actions for an item
# Usage: cleanup_execute_all <tmux_session> <clone_path> <actions_json_array>
cleanup_execute_all() {
  local tmux_session="$1"
  local clone_path="$2"
  local actions_json="$3"
  
  # Parse actions array
  local action
  while IFS= read -r action; do
    [[ -z "$action" ]] && continue
    cleanup_execute_action "$action" "$tmux_session" "$clone_path"
  done < <(echo "$actions_json" | jq -r '.[]')
}


