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

# Add the ready label to an issue
# Usage: self_iteration_add_ready_label "owner/repo" issue_number
self_iteration_add_ready_label() {
  local repo="$1"
  local issue_number="$2"
  
  local ready_label
  ready_label=$(self_iteration_get_ready_label)
  
  if self_iteration_is_dry_run; then
    echo "[DRY-RUN] Would add label '$ready_label' to $repo#$issue_number" >&2
    return 0
  fi
  
  gh issue edit --repo "$repo" "$issue_number" --add-label "$ready_label" 2>/dev/null
}

# Remove the ready label from an issue
# Usage: self_iteration_remove_ready_label "owner/repo" issue_number
self_iteration_remove_ready_label() {
  local repo="$1"
  local issue_number="$2"
  
  local ready_label
  ready_label=$(self_iteration_get_ready_label)
  
  if self_iteration_is_dry_run; then
    echo "[DRY-RUN] Would remove label '$ready_label' from $repo#$issue_number" >&2
    return 0
  fi
  
  gh issue edit --repo "$repo" "$issue_number" --remove-label "$ready_label" 2>/dev/null
}

# =============================================================================
# Main Execution
# =============================================================================

# Run self-iteration for a repo
# Fetches issues, evaluates, and marks ready up to available slots
# Usage: self_iteration_run "owner/repo" [issues_json]
# If issues_json not provided, fetches from GitHub
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
  
  # Get issue tracker info
  local tracker_type tracker_repo
  tracker_type=$(echo "$repo_config" | jq -r '.issue_tracker.type // "github"')
  tracker_repo=$(echo "$repo_config" | jq -r '.issue_tracker.repo // empty')
  
  if [[ "$tracker_type" != "github" ]]; then
    echo "[self-iteration] Only GitHub supported currently, got: $tracker_type" >&2
    return 0
  fi
  
  if [[ -z "$tracker_repo" ]]; then
    tracker_repo="$repo_key"
  fi
  
  # Fetch issues if not provided
  if [[ -z "$issues_json" ]]; then
    issues_json=$(self_iteration_fetch_github_issues "$tracker_repo")
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
  
  echo "[self-iteration] Marking $count issue(s) as ready for $repo_key" >&2
  
  # Add ready label to each candidate
  echo "$candidates" | jq -c '.[]' | while read -r issue; do
    local number title
    number=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title')
    
    echo "[self-iteration]   #$number: $title" >&2
    self_iteration_add_ready_label "$tracker_repo" "$number"
  done
  
  echo "$candidates"
}

# Fetch open GitHub issues for a repo (excluding already ready)
# Usage: issues=$(self_iteration_fetch_github_issues "owner/repo")
self_iteration_fetch_github_issues() {
  local repo="$1"
  
  local ready_label
  ready_label=$(self_iteration_get_ready_label)
  
  # Fetch open issues without the ready label
  # Using gh api for more control over the query
  gh api -X GET "/repos/${repo}/issues" \
    -f state=open \
    -f per_page=100 \
    --jq '[.[] | select(.pull_request == null)]' 2>/dev/null || echo "[]"
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
