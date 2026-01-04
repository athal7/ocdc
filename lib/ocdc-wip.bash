#!/usr/bin/env bash
#
# ocdc-wip.bash - Work In Progress state tracking for self-iteration
#
# Tracks active sessions and enforces WIP limits at both global and per-repo levels.
# State is stored in ~/.local/share/ocdc/poll-state/wip-state.json
#
# Usage:
#   source "$(dirname "$0")/ocdc-wip.bash"
#   wip_add_session "org/repo-issue-42" "org/repo" "high"
#   count=$(wip_count_active)
#
# Required: jq, tmux (for sync)

# Prevent multiple sourcing
[[ -n "${_OCDC_WIP_LOADED:-}" ]] && return 0
_OCDC_WIP_LOADED=1

# =============================================================================
# Module Loading
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source paths for directory constants
if [[ -z "${OCDC_DATA_DIR:-}" ]]; then
  if [[ -f "${SCRIPT_DIR}/ocdc-paths.bash" ]]; then
    source "${SCRIPT_DIR}/ocdc-paths.bash"
  fi
  OCDC_DATA_DIR="${OCDC_DATA_DIR:-$HOME/.local/share/ocdc}"
  OCDC_POLL_STATE_DIR="${OCDC_POLL_STATE_DIR:-$OCDC_DATA_DIR/poll-state}"
fi

# Source repo config for WIP limits
source "${SCRIPT_DIR}/ocdc-repo-config.bash"

# Source file locking
source "${SCRIPT_DIR}/ocdc-file-lock.bash" 2>/dev/null || true

# WIP state file path
OCDC_WIP_STATE_FILE="${OCDC_WIP_STATE_FILE:-${OCDC_POLL_STATE_DIR}/wip-state.json}"

# Default WIP limits
_WIP_DEFAULT_GLOBAL_MAX=5
_WIP_DEFAULT_PER_REPO=3

# =============================================================================
# State File Management
# =============================================================================

# Ensure the WIP state file exists with valid JSON
_wip_ensure_state_file() {
  if [[ ! -f "$OCDC_WIP_STATE_FILE" ]]; then
    mkdir -p "$(dirname "$OCDC_WIP_STATE_FILE")"
    echo '{"sessions":{}}' > "$OCDC_WIP_STATE_FILE"
  fi
}

# Get the lock file path
_wip_lock_file() {
  echo "${OCDC_WIP_STATE_FILE}.lock"
}

# Read state file (returns JSON)
_wip_read_state() {
  _wip_ensure_state_file
  cat "$OCDC_WIP_STATE_FILE"
}

# Write state file (expects JSON on stdin or as arg)
_wip_write_state() {
  local new_state="${1:-$(cat)}"
  
  local lock_file
  lock_file=$(_wip_lock_file)
  
  if type lock_file &>/dev/null; then
    lock_file "$lock_file"
  fi
  
  echo "$new_state" > "$OCDC_WIP_STATE_FILE"
  
  if type unlock_file &>/dev/null; then
    unlock_file "$lock_file"
  fi
}

# =============================================================================
# Session Management
# =============================================================================

# Add a WIP session
# Usage: wip_add_session <key> <repo_key> <priority>
wip_add_session() {
  local key="$1"
  local repo_key="$2"
  local priority="${3:-medium}"
  
  _wip_ensure_state_file
  
  local started_at
  started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  local state
  state=$(_wip_read_state)
  
  local new_state
  new_state=$(echo "$state" | jq \
    --arg key "$key" \
    --arg repo_key "$repo_key" \
    --arg priority "$priority" \
    --arg started_at "$started_at" \
    '.sessions[$key] = {
      repo_key: $repo_key,
      priority: $priority,
      started_at: $started_at
    }')
  
  _wip_write_state "$new_state"
}

# Remove a WIP session
# Usage: wip_remove_session <key>
wip_remove_session() {
  local key="$1"
  
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  local new_state
  new_state=$(echo "$state" | jq --arg key "$key" 'del(.sessions[$key])')
  
  _wip_write_state "$new_state"
}

# Check if a session is active
# Usage: wip_is_active <key>
# Returns: 0 if active, 1 if not
wip_is_active() {
  local key="$1"
  
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq -e --arg key "$key" '.sessions[$key] != null' >/dev/null 2>&1
}

# Get session data
# Usage: data=$(wip_get_session <key>)
# Returns: JSON object with session data or empty
wip_get_session() {
  local key="$1"
  
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq -c --arg key "$key" '.sessions[$key] // empty'
}

# =============================================================================
# Counting Functions
# =============================================================================

# Count total active sessions
# Usage: count=$(wip_count_active)
wip_count_active() {
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq '.sessions | length'
}

# Count active sessions for a specific repo
# Usage: count=$(wip_count_repo <repo_key>)
wip_count_repo() {
  local repo_key="$1"
  
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq --arg repo "$repo_key" \
    '[.sessions | to_entries[] | select(.value.repo_key == $repo)] | length'
}

# =============================================================================
# WIP Limit Checking
# =============================================================================

# Get global WIP limit from config or default
_wip_get_global_limit() {
  # TODO: Read from global config when implemented
  echo "$_WIP_DEFAULT_GLOBAL_MAX"
}

# Get repo WIP limit from config or default
_wip_get_repo_limit() {
  local repo_key="$1"
  
  local config
  config=$(repo_config_get_with_defaults "$repo_key")
  
  if [[ -n "$config" ]]; then
    local limit
    limit=$(echo "$config" | jq -r '.wip_limits.max_concurrent // empty')
    if [[ -n "$limit" ]] && [[ "$limit" != "null" ]]; then
      echo "$limit"
      return 0
    fi
  fi
  
  echo "$_WIP_DEFAULT_PER_REPO"
}

# Check if under global WIP limit
# Usage: wip_check_global_limit
# Returns: 0 if under limit, 1 if at/over limit
wip_check_global_limit() {
  local current
  current=$(wip_count_active)
  
  local limit
  limit=$(_wip_get_global_limit)
  
  [[ $current -lt $limit ]]
}

# Check if under repo WIP limit
# Usage: wip_check_repo_limit <repo_key>
# Returns: 0 if under limit, 1 if at/over limit
wip_check_repo_limit() {
  local repo_key="$1"
  
  local current
  current=$(wip_count_repo "$repo_key")
  
  local limit
  limit=$(_wip_get_repo_limit "$repo_key")
  
  [[ $current -lt $limit ]]
}

# =============================================================================
# Available Slots
# =============================================================================

# Get number of available global slots
# Usage: slots=$(wip_available_slots)
wip_available_slots() {
  local current
  current=$(wip_count_active)
  
  local limit
  limit=$(_wip_get_global_limit)
  
  local available=$((limit - current))
  [[ $available -lt 0 ]] && available=0
  
  echo "$available"
}

# Get number of available slots for a repo
# Usage: slots=$(wip_available_slots_repo <repo_key>)
wip_available_slots_repo() {
  local repo_key="$1"
  
  local current
  current=$(wip_count_repo "$repo_key")
  
  local limit
  limit=$(_wip_get_repo_limit "$repo_key")
  
  local available=$((limit - current))
  [[ $available -lt 0 ]] && available=0
  
  echo "$available"
}

# =============================================================================
# Listing Functions
# =============================================================================

# List all active sessions
# Usage: sessions=$(wip_list_sessions)
# Returns: JSON array of sessions
wip_list_sessions() {
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq '[.sessions | to_entries[] | {key: .key} + .value]'
}

# List sessions for a specific repo
# Usage: sessions=$(wip_list_sessions_repo <repo_key>)
# Returns: JSON array of sessions
wip_list_sessions_repo() {
  local repo_key="$1"
  
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  echo "$state" | jq --arg repo "$repo_key" \
    '[.sessions | to_entries[] | select(.value.repo_key == $repo) | {key: .key} + .value]'
}

# =============================================================================
# Sync with Tmux
# =============================================================================

# Sync WIP state with actual tmux sessions
# Removes entries for sessions that no longer exist
# Usage: wip_sync_with_tmux
wip_sync_with_tmux() {
  _wip_ensure_state_file
  
  local state
  state=$(_wip_read_state)
  
  # Get list of actual tmux sessions with OCDC_ITEM_KEY
  local active_keys=()
  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    
    local item_key
    item_key=$(tmux show-environment -t "$session" OCDC_ITEM_KEY 2>/dev/null | cut -d= -f2- || true)
    
    if [[ -n "$item_key" ]]; then
      active_keys+=("$item_key")
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  
  # Build JSON array of active keys
  local active_json
  active_json=$(printf '%s\n' "${active_keys[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  
  # Filter state to only include active sessions
  local new_state
  new_state=$(echo "$state" | jq --argjson active "$active_json" \
    '.sessions = (.sessions | with_entries(select(.key | IN($active[]))))')
  
  _wip_write_state "$new_state"
}

# =============================================================================
# Exports
# =============================================================================

export OCDC_WIP_STATE_FILE
