#!/usr/bin/env bash
#
# ocdc-readiness.bash - Issue readiness evaluation for self-iteration
#
# Evaluates whether an issue is ready to be worked on based on:
# - Label constraints (blocking labels, required labels)
# - Dependencies (blocked by references in body)
# - Priority scoring (label weights, age bonus)
#
# Usage:
#   source "$(dirname "$0")/ocdc-readiness.bash"
#   result=$(readiness_evaluate "$issue_json" "owner/repo")
#
# Required: jq

# Prevent multiple sourcing
[[ -n "${_OCDC_READINESS_LOADED:-}" ]] && return 0
_OCDC_READINESS_LOADED=1

# =============================================================================
# Module Loading
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source repo config for readiness settings
source "${SCRIPT_DIR}/ocdc-repo-config.bash"

# =============================================================================
# Label Checking
# =============================================================================

# Check if issue passes label constraints
# Usage: readiness_check_labels "$issue_json" "owner/repo"
# Returns: 0 if passes, 1 if blocked
readiness_check_labels() {
  local issue_json="$1"
  local repo_key="$2"
  
  # Get repo config
  local config
  config=$(repo_config_get_with_defaults "$repo_key")
  
  # Get exclude labels from config
  local exclude_labels
  exclude_labels=$(printf '%s' "$config" | jq -r '.readiness.labels.exclude // []')
  
  # Get blocking labels from dependencies config
  local blocking_labels
  blocking_labels=$(printf '%s' "$config" | jq -r '.readiness.dependencies.blocking_labels // []')
  
  # Merge both lists
  local all_blocked
  all_blocked=$(jq -n --argjson a "$exclude_labels" --argjson b "$blocking_labels" '$a + $b | unique')
  
  # Get issue labels (lowercase for comparison)
  local issue_labels
  issue_labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name // empty] | map(ascii_downcase)')
  
  # Check if any issue label is in blocked list
  local has_blocked
  has_blocked=$(jq -n \
    --argjson issue_labels "$issue_labels" \
    --argjson blocked "$all_blocked" \
    '$blocked | map(ascii_downcase) | . as $b | $issue_labels | any(. as $l | $b | index($l) != null)')
  
  [[ "$has_blocked" == "false" ]]
}

# =============================================================================
# Dependency Checking
# =============================================================================

# Regex patterns for dependency references
_DEPENDENCY_PATTERNS=(
  'blocked by #[0-9]+'
  'blocked by [a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+'
  'depends on #[0-9]+'
  'depends on [a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+'
  'requires #[0-9]+'
  'waiting on #[0-9]+'
  'waiting for #[0-9]+'
  'after #[0-9]+'
)

# Check if issue body has unchecked task list items (GitHub checkbox syntax)
# Returns: 0 (true) if has unchecked items, 1 (false) if no unchecked items
_has_unchecked_tasks() {
  local body="$1"
  
  # Look for unchecked checkboxes: - [ ] or * [ ]
  if echo "$body" | grep -qE '^\s*[-*]\s*\[ \]'; then
    return 0  # Has unchecked tasks (true for shell if)
  fi
  return 1  # No unchecked tasks (false for shell if)
}

# Check if issue has dependency references in body
# Usage: readiness_check_dependencies "$issue_json" "owner/repo"
# Returns: 0 if no blocking dependencies, 1 if blocked
readiness_check_dependencies() {
  local issue_json="$1"
  local repo_key="$2"
  
  # Get repo config
  local config
  config=$(repo_config_get_with_defaults "$repo_key")
  
  # Check if body reference checking is enabled
  local check_body
  check_body=$(printf '%s' "$config" | jq -r '.readiness.dependencies.check_body_references // true')
  
  if [[ "$check_body" != "true" ]]; then
    return 0
  fi
  
  # Get issue body
  local body
  body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  local body_lower
  body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')
  
  # Check explicit dependency patterns
  for pattern in "${_DEPENDENCY_PATTERNS[@]}"; do
    if echo "$body_lower" | grep -qiE "$pattern"; then
      return 1
    fi
  done
  
  # Check for unchecked task list items (inferred dependencies)
  # Only if the issue appears to be a meta/tracking issue with subtasks
  if _has_unchecked_tasks "$body"; then
    # Check if this looks like a tracking issue (has multiple checkboxes)
    local checkbox_count
    checkbox_count=$(echo "$body" | grep -cE '^\s*[-*]\s*\[[x ]\]' || echo "0")
    if [[ "$checkbox_count" -gt 1 ]]; then
      # This is likely a tracking issue with subtasks - consider it blocked
      # unless all checkboxes are checked
      local unchecked_count
      unchecked_count=$(echo "$body" | grep -cE '^\s*[-*]\s*\[ \]' || echo "0")
      if [[ "$unchecked_count" -gt 0 ]]; then
        return 1  # Has unchecked subtasks
      fi
    fi
  fi
  
  return 0
}

# =============================================================================
# Priority Scoring
# =============================================================================

# Calculate priority score for an issue
# Usage: score=$(readiness_calculate_priority "$issue_json" "owner/repo")
# Returns: integer score
readiness_calculate_priority() {
  local issue_json="$1"
  local repo_key="$2"
  
  # Get repo config
  local config
  config=$(repo_config_get_with_defaults "$repo_key")
  
  # Get priority label weights
  local priority_labels
  priority_labels=$(printf '%s' "$config" | jq -c '.readiness.priority.labels // []')
  
  # Get age weight
  local age_weight
  age_weight=$(printf '%s' "$config" | jq -r '.readiness.priority.age_weight // 1')
  
  # Get issue labels (lowercase)
  local issue_labels
  issue_labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name // empty] | map(ascii_downcase)')
  
  # Calculate label score (take highest matching weight)
  local label_score=0
  local weight
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    
    local label
    label=$(printf '%s' "$entry" | jq -r '.label' | tr '[:upper:]' '[:lower:]')
    weight=$(printf '%s' "$entry" | jq -r '.weight // 0')
    
    # Check if issue has this label
    local has_label
    has_label=$(printf '%s' "$issue_labels" | jq --arg l "$label" 'index($l) != null')
    
    if [[ "$has_label" == "true" ]] && [[ "$weight" -gt "$label_score" ]]; then
      label_score=$weight
    fi
  done < <(printf '%s' "$priority_labels" | jq -c '.[]')
  
  # Calculate age bonus (days since creation * weight)
  # Handle both snake_case (tests) and camelCase (gh CLI) field names
  local created_at
  created_at=$(printf '%s' "$issue_json" | jq -r '.created_at // .createdAt // empty')
  
  local age_bonus=0
  if [[ -n "$created_at" ]]; then
    local now_epoch created_epoch days_old
    now_epoch=$(date +%s)
    
    # Parse ISO timestamp to epoch (try macOS then Linux)
    if created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null); then
      : # macOS succeeded
    else
      created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "$now_epoch")
    fi
    
    days_old=$(( (now_epoch - created_epoch) / 86400 ))
    age_bonus=$(echo "$days_old * $age_weight" | bc 2>/dev/null || echo "$days_old")
  fi
  
  # Inferred priority signals (when no explicit priority label)
  local inferred_bonus=0
  if [[ "$label_score" -eq 0 ]]; then
    # Milestone boost: issues in a milestone are likely more important
    local milestone
    milestone=$(printf '%s' "$issue_json" | jq -r '.milestone.title // empty')
    if [[ -n "$milestone" ]]; then
      inferred_bonus=$((inferred_bonus + 20))
    fi
    
    # Reactions boost: issues with positive reactions have community interest
    # Handle both REST API format (.reactions."+1") and gh CLI format (.reactionGroups)
    local reactions
    reactions=$(printf '%s' "$issue_json" | jq -r '
      if .reactions then .reactions."+1" // .reactions.THUMBS_UP // 0
      elif .reactionGroups then [.reactionGroups[] | select(.content == "THUMBS_UP") | .users.totalCount // 0] | add // 0
      else 0 end
    ')
    if [[ "$reactions" -gt 0 ]]; then
      # Cap at 30 points (prevents gaming)
      local reaction_bonus=$((reactions * 5))
      [[ $reaction_bonus -gt 30 ]] && reaction_bonus=30
      inferred_bonus=$((inferred_bonus + reaction_bonus))
    fi
    
    # Comment count boost: more discussion = more important
    # Handle both integer (REST API) and array (gh CLI) formats
    local comments
    comments=$(printf '%s' "$issue_json" | jq -r '
      if .comments | type == "array" then .comments | length
      else .comments // 0 end
    ')
    if [[ "$comments" -gt 0 ]]; then
      # Cap at 20 points
      local comment_bonus=$((comments * 2))
      [[ $comment_bonus -gt 20 ]] && comment_bonus=20
      inferred_bonus=$((inferred_bonus + comment_bonus))
    fi
    
    # Assignee boost: assigned issues should be prioritized
    local assignee_count
    assignee_count=$(printf '%s' "$issue_json" | jq '[.assignees // [] | length] | .[0]')
    if [[ "$assignee_count" -gt 0 ]]; then
      inferred_bonus=$((inferred_bonus + 15))
    fi
  fi
  
  # Total score
  local total=$((label_score + age_bonus + inferred_bonus))
  echo "$total"
}

# =============================================================================
# Full Evaluation
# =============================================================================

# Evaluate issue readiness
# Usage: result=$(readiness_evaluate "$issue_json" "owner/repo")
# Returns: JSON {eligible: bool, score: int, reason: string|null}
readiness_evaluate() {
  local issue_json="$1"
  local repo_key="$2"
  
  # Check labels
  if ! readiness_check_labels "$issue_json" "$repo_key"; then
    jq -n '{eligible: false, score: 0, reason: "has_blocking_label"}'
    return 0
  fi
  
  # Check dependencies
  if ! readiness_check_dependencies "$issue_json" "$repo_key"; then
    jq -n '{eligible: false, score: 0, reason: "has_dependency"}'
    return 0
  fi
  
  # Calculate priority score
  local score
  score=$(readiness_calculate_priority "$issue_json" "$repo_key")
  
  jq -n --argjson score "$score" '{eligible: true, score: $score, reason: null}'
}

# =============================================================================
# Batch Evaluation
# =============================================================================

# Evaluate multiple issues and return sorted by score
# Usage: results=$(readiness_evaluate_batch "$issues_json_array" "owner/repo")
# Returns: JSON array of {issue: ..., eligible: bool, score: int} sorted by score desc
readiness_evaluate_batch() {
  local issues_json="$1"
  local repo_key="$2"
  
  local results=()
  local count
  count=$(printf '%s' "$issues_json" | jq 'length')
  
  for ((i=0; i<count; i++)); do
    # Extract issue using jq index to avoid bash string handling issues
    local issue
    issue=$(printf '%s' "$issues_json" | jq -c ".[$i]")
    
    [[ -z "$issue" ]] && continue
    
    local eval_result
    eval_result=$(readiness_evaluate "$issue" "$repo_key")
    
    local eligible score
    eligible=$(printf '%s' "$eval_result" | jq -r '.eligible')
    score=$(printf '%s' "$eval_result" | jq -r '.score')
    
    # Build result using jq slurp to avoid --argjson issues with special chars
    local result
    result=$(printf '%s\n%s' "$issue" "$eval_result" | jq -s '
      {issue: .[0], eligible: .[1].eligible, score: .[1].score}
    ')
    
    results+=("$result")
  done
  
  # Combine and sort by score descending
  printf '%s\n' "${results[@]}" | jq -s 'sort_by(-.score)'
}

# Get top N eligible issues
# Usage: top=$(readiness_get_top_eligible "$issues_json_array" "owner/repo" 3)
# Returns: JSON array of top N eligible issues
readiness_get_top_eligible() {
  local issues_json="$1"
  local repo_key="$2"
  local limit="${3:-5}"
  
  local evaluated
  evaluated=$(readiness_evaluate_batch "$issues_json" "$repo_key")
  
  echo "$evaluated" | jq --argjson limit "$limit" \
    '[.[] | select(.eligible == true)] | .[0:$limit] | map(.issue)'
}
