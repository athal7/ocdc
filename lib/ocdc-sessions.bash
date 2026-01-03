#!/usr/bin/env bash
#
# ocdc-sessions.bash - tmux session management for ocdc poll
#
# Source this file to get session helper functions.
#
# Usage:
#   source "$(dirname "$0")/../lib/ocdc-sessions.bash"
#
# Functions:
#   ocdc_list_poll_sessions     - List tmux sessions with OCDC_POLL_CONFIG
#   ocdc_get_session_metadata   - Get metadata for a session
#   ocdc_is_session_orphan      - Check if session's workspace exists
#   ocdc_kill_session           - Kill session and clear poll state
#
# Requires ocdc-paths.bash to be sourced first.

# Guard against missing dependencies
if [[ -z "${OCDC_POLL_STATE_DIR:-}" ]]; then
  echo "Error: ocdc-paths.bash must be sourced before ocdc-sessions.bash" >&2
  return 1 2>/dev/null || exit 1
fi

# List all tmux sessions that have OCDC_POLL_CONFIG set
# Returns JSON array of session objects
# Each object: {"name": "session-name", "workspace": "...", "poll_config": "...", ...}
ocdc_list_poll_sessions() {
  local sessions="[]"
  
  # Check if tmux is available and has sessions
  if ! command -v tmux >/dev/null 2>&1; then
    echo "[]"
    return 0
  fi
  
  while IFS= read -r session_name; do
    [[ -z "$session_name" ]] && continue
    
    # Try to get OCDC_POLL_CONFIG from session environment
    local poll_config
    poll_config=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_POLL_CONFIG=' | cut -d= -f2- || true)
    
    # Skip sessions without OCDC_POLL_CONFIG
    [[ -z "$poll_config" ]] && continue
    
    # Get other OCDC vars
    local workspace branch item_key source_url source_type
    workspace=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_WORKSPACE=' | cut -d= -f2- || true)
    branch=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_BRANCH=' | cut -d= -f2- || true)
    item_key=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_ITEM_KEY=' | cut -d= -f2- || true)
    source_url=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_SOURCE_URL=' | cut -d= -f2- || true)
    source_type=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_SOURCE_TYPE=' | cut -d= -f2- || true)
    
    # Get session creation time
    local created
    created=$(tmux display-message -t "$session_name" -p '#{session_created}' 2>/dev/null || echo "0")
    
    # Build JSON object for this session
    local session_json
    session_json=$(jq -n \
      --arg name "$session_name" \
      --arg workspace "$workspace" \
      --arg poll_config "$poll_config" \
      --arg branch "$branch" \
      --arg item_key "$item_key" \
      --arg source_url "$source_url" \
      --arg source_type "$source_type" \
      --arg created "$created" \
      '{
        name: $name,
        workspace: $workspace,
        poll_config: $poll_config,
        branch: $branch,
        item_key: $item_key,
        source_url: $source_url,
        source_type: $source_type,
        created: ($created | tonumber)
      }')
    
    # Add to sessions array
    sessions=$(echo "$sessions" | jq --argjson s "$session_json" '. + [$s]')
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  
  echo "$sessions"
}

# Get metadata for a specific session
# Returns JSON object or exits with error if session not found
ocdc_get_session_metadata() {
  local session_name="$1"
  
  # Check session exists
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Error: Session not found: $session_name" >&2
    return 1
  fi
  
  # Get all OCDC vars
  local env_output
  env_output=$(tmux show-environment -t "$session_name" 2>/dev/null) || return 1
  
  local workspace poll_config branch item_key source_url source_type
  workspace=$(echo "$env_output" | grep '^OCDC_WORKSPACE=' | cut -d= -f2- || true)
  poll_config=$(echo "$env_output" | grep '^OCDC_POLL_CONFIG=' | cut -d= -f2- || true)
  branch=$(echo "$env_output" | grep '^OCDC_BRANCH=' | cut -d= -f2- || true)
  item_key=$(echo "$env_output" | grep '^OCDC_ITEM_KEY=' | cut -d= -f2- || true)
  source_url=$(echo "$env_output" | grep '^OCDC_SOURCE_URL=' | cut -d= -f2- || true)
  source_type=$(echo "$env_output" | grep '^OCDC_SOURCE_TYPE=' | cut -d= -f2- || true)
  
  # Get session creation time
  local created
  created=$(tmux display-message -t "$session_name" -p '#{session_created}' 2>/dev/null || echo "0")
  
  jq -n \
    --arg name "$session_name" \
    --arg workspace "$workspace" \
    --arg poll_config "$poll_config" \
    --arg branch "$branch" \
    --arg item_key "$item_key" \
    --arg source_url "$source_url" \
    --arg source_type "$source_type" \
    --arg created "$created" \
    '{
      name: $name,
      workspace: $workspace,
      poll_config: $poll_config,
      branch: $branch,
      item_key: $item_key,
      source_url: $source_url,
      source_type: $source_type,
      created: ($created | tonumber)
    }'
}

# Check if a session is orphaned (workspace doesn't exist)
# Returns 0 (true) if orphan, 1 (false) if not orphan
ocdc_is_session_orphan() {
  local session_name="$1"
  
  # Get workspace from session
  local workspace
  workspace=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_WORKSPACE=' | cut -d= -f2- || true)
  
  # No workspace set = orphan
  [[ -z "$workspace" ]] && return 0
  
  # Workspace doesn't exist = orphan
  [[ ! -d "$workspace" ]] && return 0
  
  # Workspace exists = not orphan
  return 1
}

# Kill a session and clear its entry from processed.json
ocdc_kill_session() {
  local session_name="$1"
  
  # Get item_key before killing session (for state cleanup)
  local item_key
  item_key=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_ITEM_KEY=' | cut -d= -f2- || true)
  
  # Kill the tmux session
  tmux kill-session -t "$session_name" 2>/dev/null || true
  
  # Clear from processed.json if we have an item_key
  if [[ -n "$item_key" ]] && [[ -f "$OCDC_POLL_STATE_DIR/processed.json" ]]; then
    local tmp
    tmp=$(mktemp)
    # Use trap to clean up temp file on error
    trap "rm -f '$tmp'" EXIT
    if jq --arg key "$item_key" 'del(.[$key])' "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
    else
      rm -f "$tmp"
    fi
    trap - EXIT
  fi
}

# Get list of orphaned sessions (workspace doesn't exist)
# Returns newline-separated list of session names
ocdc_list_orphaned_sessions() {
  while IFS= read -r session_name; do
    [[ -z "$session_name" ]] && continue
    
    # Check if it's an OCDC session
    local poll_config
    poll_config=$(tmux show-environment -t "$session_name" 2>/dev/null | grep '^OCDC_POLL_CONFIG=' | cut -d= -f2- || true)
    [[ -z "$poll_config" ]] && continue
    
    # Check if orphaned
    if ocdc_is_session_orphan "$session_name"; then
      echo "$session_name"
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}
