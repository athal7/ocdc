#!/usr/bin/env bash
#
# ocdc-self-iteration.bash - Self-iteration logic for automatic issue readiness
#
# Coordinates between repo config, WIP tracking, and readiness evaluation
# to automatically mark issues as ready when capacity is available.
#
# Usage:
#   source "$(dirname "$0")/ocdc-self-iteration.bash"
#   self_iteration_run "athal7/ocdc"
#
# Required: jq, gh (for GitHub label operations)

# Prevent multiple sourcing
[[ -n "${_OCDC_SELF_ITERATION_LOADED:-}" ]] && return 0
_OCDC_SELF_ITERATION_LOADED=1

# =============================================================================
# Module Loading
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required modules
source "${SCRIPT_DIR}/ocdc-paths.bash"
source "${SCRIPT_DIR}/ocdc-repo-config.bash"
source "${SCRIPT_DIR}/ocdc-wip.bash"
source "${SCRIPT_DIR}/ocdc-readiness.bash"

# =============================================================================
# Configuration
# =============================================================================

# Default self-iteration settings
_SELF_ITERATION_DEFAULT_ENABLED=false
_SELF_ITERATION_DEFAULT_READY_LABEL="ocdc:ready"
_SELF_ITERATION_DEFAULT_DRY_RUN=false

# Get self-iteration config from main config file
# Returns: JSON object with settings
self_iteration_get_config() {
  local config_file="${OCDC_CONFIG_FILE:-$HOME/.config/ocdc/config.json}"
  
  if [[ ! -f "$config_file" ]]; then
    jq -n \
      --argjson enabled "$_SELF_ITERATION_DEFAULT_ENABLED" \
      --arg ready_label "$_SELF_ITERATION_DEFAULT_READY_LABEL" \
      --argjson dry_run "$_SELF_ITERATION_DEFAULT_DRY_RUN" \
      '{enabled: $enabled, ready_label: $ready_label, dry_run: $dry_run}'
    return 0
  fi
  
  local config
  config=$(jq '.self_iteration // {}' "$config_file")
  
  # Merge with defaults
  jq -n \
    --argjson config "$config" \
    --argjson default_enabled "$_SELF_ITERATION_DEFAULT_ENABLED" \
    --arg default_ready_label "$_SELF_ITERATION_DEFAULT_READY_LABEL" \
    --argjson default_dry_run "$_SELF_ITERATION_DEFAULT_DRY_RUN" \
    '{
      enabled: ($config.enabled // $default_enabled),
      ready_label: ($config.ready_label // $default_ready_label),
      dry_run: ($config.dry_run // $default_dry_run)
    }'
}

# Check if self-iteration is enabled
# Returns: 0 if enabled, 1 if disabled
self_iteration_is_enabled() {
  local config
  config=$(self_iteration_get_config)
  
  local enabled
  enabled=$(echo "$config" | jq -r '.enabled')
  
  [[ "$enabled" == "true" ]]
}

# Get the ready label name
self_iteration_get_ready_label() {
  local config
  config=$(self_iteration_get_config)
  
  echo "$config" | jq -r '.ready_label'
}

# Check if dry-run mode is enabled
self_iteration_is_dry_run() {
  local config
  config=$(self_iteration_get_config)
  
  local dry_run
  dry_run=$(echo "$config" | jq -r '.dry_run')
  
  [[ "$dry_run" == "true" ]]
}

# =============================================================================
# Slot Calculation
# =============================================================================

# Get global WIP limit from config
_self_iteration_get_global_limit() {
  local config_file="${OCDC_CONFIG_FILE:-$HOME/.config/ocdc/config.json}"
  
  if [[ ! -f "$config_file" ]]; then
    echo "5"  # Default
    return 0
  fi
  
  local limit
  limit=$(jq -r '.wip_limits.global_max // 5' "$config_file")
  echo "$limit"
}

# Calculate available slots for a repo (min of repo limit and global limit)
# Usage: slots=$(self_iteration_available_slots "owner/repo")
self_iteration_available_slots() {
  local repo_key="$1"
  
  # Get current counts
  local repo_count global_count
  repo_count=$(wip_count_repo "$repo_key")
  global_count=$(wip_count_active)
  
  # Get limits
  local repo_limit global_limit
  repo_limit=$(_wip_get_repo_limit "$repo_key")
  global_limit=$(_self_iteration_get_global_limit)
  
  # Calculate available
  local repo_available=$((repo_limit - repo_count))
  local global_available=$((global_limit - global_count))
  
  [[ $repo_available -lt 0 ]] && repo_available=0
  [[ $global_available -lt 0 ]] && global_available=0
  
  # Return minimum
  if [[ $repo_available -lt $global_available ]]; then
    echo "$repo_available"
  else
    echo "$global_available"
  fi
}

# =============================================================================
# Candidate Selection
# =============================================================================

# Filter issues that already have the ready label
_self_iteration_filter_already_ready() {
  local issues_json="$1"
  local ready_label="$2"
  
  local ready_lower
  ready_lower=$(echo "$ready_label" | tr '[:upper:]' '[:lower:]')
  
  echo "$issues_json" | jq --arg label "$ready_lower" '
    [.[] | select(
      [.labels[]?.name // ""] | map(ascii_downcase) | index($label) == null
    )]
  '
}

# Select candidates for marking as ready
# Usage: selected=$(self_iteration_select_candidates "$issues_json" "owner/repo" slots)
self_iteration_select_candidates() {
  local issues_json="$1"
  local repo_key="$2"
  local max_slots="${3:-}"
  
  # Get available slots if not provided
  if [[ -z "$max_slots" ]]; then
    max_slots=$(self_iteration_available_slots "$repo_key")
  fi
  
  # No slots available
  if [[ "$max_slots" -le 0 ]]; then
    echo "[]"
    return 0
  fi
  
  # Get ready label
  local ready_label
  ready_label=$(self_iteration_get_ready_label)
  
  # Filter out already-ready issues
  local filtered
  filtered=$(_self_iteration_filter_already_ready "$issues_json" "$ready_label")
  
  # Evaluate and get top eligible
  readiness_get_top_eligible "$filtered" "$repo_key" "$max_slots"
}

# =============================================================================
# Label Management (GitHub)
# =============================================================================

# Add a label to a GitHub issue
# Usage: self_iteration_add_ready_label "owner/repo" issue_number [label]
self_iteration_add_ready_label() {
  local repo="$1"
  local issue_number="$2"
  local label="${3:-$(self_iteration_get_ready_label)}"
  
  if self_iteration_is_dry_run; then
    echo "[DRY-RUN] Would add label '$label' to $repo#$issue_number" >&2
    return 0
  fi
  
  gh issue edit --repo "$repo" "$issue_number" --add-label "$label" 2>/dev/null
}

# Remove a label from a GitHub issue
# Usage: self_iteration_remove_ready_label "owner/repo" issue_number [label]
self_iteration_remove_ready_label() {
  local repo="$1"
  local issue_number="$2"
  local label="${3:-$(self_iteration_get_ready_label)}"
  
  if self_iteration_is_dry_run; then
    echo "[DRY-RUN] Would remove label '$label' from $repo#$issue_number" >&2
    return 0
  fi
  
  gh issue edit --repo "$repo" "$issue_number" --remove-label "$label" 2>/dev/null
}

# =============================================================================
# Main Execution
# =============================================================================

# Run self-iteration for a repo
# Fetches issues via MCP, evaluates readiness, and executes ready_action
# Usage: self_iteration_run "repo_key" [issues_json]
# If issues_json not provided, fetches via MCP using issue_tracker config
self_iteration_run() {
  local repo_key="$1"
  local issues_json="${2:-}"
  
  # Check if enabled
  if ! self_iteration_is_enabled; then
    return 0
  fi
  
  # Get repo config
  local repo_config
  repo_config=$(repo_config_get "$repo_key")
  
  if [[ -z "$repo_config" ]]; then
    echo "[self-iteration] No config for repo: $repo_key" >&2
    return 0
  fi
  
  # Get issue tracker config
  local source_type fetch_options ready_action_type ready_action_label
  source_type=$(echo "$repo_config" | jq -r '.issue_tracker.source_type // "github_issue"')
  fetch_options=$(echo "$repo_config" | jq -c '.issue_tracker.fetch_options // {}')
  ready_action_type=$(echo "$repo_config" | jq -r '.issue_tracker.ready_action.type // "add_label"')
  ready_action_label=$(echo "$repo_config" | jq -r '.issue_tracker.ready_action.label // empty')
  
  # Use global ready_label as default if not specified in repo config
  if [[ -z "$ready_action_label" ]] && [[ "$ready_action_type" == "add_label" ]]; then
    ready_action_label=$(self_iteration_get_ready_label)
  fi
  
  # Fetch issues if not provided
  if [[ -z "$issues_json" ]]; then
    issues_json=$(self_iteration_fetch_issues "$source_type" "$fetch_options")
  fi
  
  # Calculate available slots
  local slots
  slots=$(self_iteration_available_slots "$repo_key")
  
  if [[ "$slots" -le 0 ]]; then
    echo "[self-iteration] No slots available for $repo_key" >&2
    return 0
  fi
  
  # Select candidates
  local candidates
  candidates=$(self_iteration_select_candidates "$issues_json" "$repo_key" "$slots")
  
  local count
  count=$(echo "$candidates" | jq 'length')
  
  if [[ "$count" -eq 0 ]]; then
    echo "[self-iteration] No eligible candidates for $repo_key" >&2
    return 0
  fi
  
  echo "[self-iteration] Found $count eligible issue(s) for $repo_key" >&2
  
  # Execute ready action for each candidate
  echo "$candidates" | jq -c '.[]' | while read -r issue; do
    local identifier title
    identifier=$(echo "$issue" | jq -r '.identifier // .number // .id')
    title=$(echo "$issue" | jq -r '.title')
    
    case "$ready_action_type" in
      add_label)
        local repo
        repo=$(echo "$fetch_options" | jq -r '.repo // empty')
        [[ -z "$repo" ]] && repo="$repo_key"
        echo "[self-iteration]   #$identifier: $title" >&2
        self_iteration_add_ready_label "$repo" "$identifier" "$ready_action_label"
        ;;
      none)
        echo "[self-iteration]   $identifier: $title (no action)" >&2
        ;;
      *)
        echo "[self-iteration]   $identifier: $title (unknown action: $ready_action_type)" >&2
        ;;
    esac
  done
  
  echo "$candidates"
}

# =============================================================================
# Issue Fetching (MCP-based)
# =============================================================================

# Fetch issues using MCP with the specified source type and options
# Usage: issues=$(self_iteration_fetch_issues "source_type" "$fetch_options_json")
# Returns: JSON array of issues normalized to common format
self_iteration_fetch_issues() {
  local source_type="$1"
  local fetch_options="$2"
  
  # Default to github_issue if not specified
  [[ -z "$source_type" ]] && source_type="github_issue"
  [[ -z "$fetch_options" ]] && fetch_options='{}'
  
  # Fetch via MCP, sanitize control chars, and normalize in one pipeline
  # Control chars (U+0000-U+001F except \n \r \t) in issue bodies break JSON parsing
  node "${SCRIPT_DIR}/ocdc-mcp-fetch.js" "$source_type" "$fetch_options" 2>/dev/null | \
    perl -pe 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g' | \
    _self_iteration_normalize_json || echo "[]"
}

# Internal: normalize JSON from stdin to common issue format
# Handles GitHub (number, body, html_url) and Linear (identifier, description, url)
# Note: Control chars should already be sanitized by perl before this function
_self_iteration_normalize_json() {
  jq '
    [.[] | {
      # Use number for GitHub, identifier for Linear
      number: (.number // .identifier // null),
      # Keep Linear identifier separately for display
      identifier: (.identifier // null),
      # Keep Linear id for API calls
      id: (.id // null),
      title: .title,
      # body for GitHub, description for Linear
      body: (.body // .description // ""),
      state: .state,
      # html_url for GitHub, url for Linear
      html_url: (.html_url // .url // ""),
      created_at: (.created_at // .createdAt // null),
      # Normalize labels to [{name: "..."}] format
      labels: (
        if (.labels | type) == "array" then
          if (.labels | length) > 0 and (.labels[0] | type) == "object" then .labels
          else [.labels[] | {name: .}]
          end
        else []
        end
      ),
      assignees: (.assignees // []),
      milestone: .milestone,
      # Linear team info
      team: .team,
      comments: (
        if (.comments | type) == "array" then (.comments | length)
        elif (.comments | type) == "number" then .comments
        else 0
        end
      ),
      reactions: (
        if .reactions then .reactions
        elif .reactionGroups then
          (.reactionGroups // [] | 
            map(select(.content == "THUMBS_UP") | {"+1": (.users.totalCount // 0)}) |
            add // {"+1": 0}
          )
        else {"+1": 0}
        end
      ),
      repository: .repository
    }]
  ' 2>/dev/null || echo "[]"
}

# Normalize issue JSON to consistent field names
# Handles both GitHub API (snake_case) and gh CLI (camelCase) formats
# Usage: normalized=$(self_iteration_normalize_issues "$issues_json")
# Or:    echo "$json" | self_iteration_normalize_issues
self_iteration_normalize_issues() {
  local issues_json="${1:-$(cat)}"
  
  # Handle empty input
  if [[ -z "$issues_json" ]] || [[ "$issues_json" == "null" ]]; then
    echo "[]"
    return 0
  fi
  
  # Sanitize control chars and normalize via internal function
  printf '%s' "$issues_json" | \
    perl -pe 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g' | \
    _self_iteration_normalize_json
}

# Run self-iteration for all configured repos
# Usage: self_iteration_run_all
self_iteration_run_all() {
  if ! self_iteration_is_enabled; then
    return 0
  fi
  
  local repos
  repos=$(repo_config_list)
  
  while IFS= read -r repo_key; do
    [[ -z "$repo_key" ]] && continue
    self_iteration_run "$repo_key"
  done <<< "$repos"
}
