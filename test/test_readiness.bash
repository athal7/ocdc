#!/usr/bin/env bash
#
# Tests for issue readiness evaluation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing readiness evaluation..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  export OCDC_REPOS_FILE="$TEST_CONFIG_DIR/repos.yaml"
  export OCDC_WIP_STATE_FILE="$TEST_DATA_DIR/wip-state.json"
  
  # Create repos config with readiness settings
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  athal7/ocdc:
    repo_path: ~/code/ocdc
    issue_tracker:
      type: github
      repo: athal7/ocdc
    readiness:
      labels:
        exclude: ["blocked", "needs-design", "wontfix"]
      priority:
        labels:
          - label: critical
            weight: 100
          - label: high
            weight: 50
          - label: medium
            weight: 25
          - label: low
            weight: 10
        age_weight: 1
      dependencies:
        check_body_references: true
        blocking_labels: ["blocked"]
    wip_limits:
      max_concurrent: 2
EOF
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Test Issue JSON Helpers
# =============================================================================

# Create a GitHub issue JSON with optional extra fields
# Usage: create_issue_json number title labels body created_at [extra_json]
create_issue_json() {
  local number="${1:-42}"
  local title="${2:-Test issue}"
  local labels="${3:-[]}"
  local body="${4:-}"
  local created_at="${5:-2026-01-01T00:00:00Z}"
  local extra="${6:-}"
  
  local base_json
  base_json=$(jq -n \
    --argjson number "$number" \
    --arg title "$title" \
    --argjson labels "$labels" \
    --arg body "$body" \
    --arg created_at "$created_at" \
    '{
      number: $number,
      title: $title,
      labels: $labels,
      body: $body,
      state: "open",
      created_at: $created_at,
      html_url: "https://github.com/athal7/ocdc/issues/\($number)",
      comments: 0,
      reactions: {"+1": 0, "-1": 0},
      assignees: [],
      milestone: null,
      repository: {
        full_name: "athal7/ocdc",
        name: "ocdc"
      }
    }')
  
  # Merge with extra if provided
  if [[ -n "$extra" ]]; then
    echo "$base_json" | jq --argjson extra "$extra" '. * $extra'
  else
    echo "$base_json"
  fi
}

# =============================================================================
# Basic Tests
# =============================================================================

test_readiness_library_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-readiness.bash" ]]; then
    echo "lib/ocdc-readiness.bash does not exist"
    return 1
  fi
  return 0
}

test_readiness_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-readiness.bash" 2>&1; then
    echo "Failed to source ocdc-readiness.bash"
    return 1
  fi
  return 0
}

# =============================================================================
# Label Check Tests
# =============================================================================

test_issue_without_blocking_labels_is_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Normal issue" '[{"name":"bug"}]')
  
  if ! readiness_check_labels "$issue" "athal7/ocdc"; then
    echo "Issue without blocking labels should be eligible"
    return 1
  fi
  return 0
}

test_issue_with_blocking_label_is_not_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Blocked issue" '[{"name":"blocked"}]')
  
  if readiness_check_labels "$issue" "athal7/ocdc"; then
    echo "Issue with blocking label should not be eligible"
    return 1
  fi
  return 0
}

test_issue_with_exclude_label_is_not_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Needs design" '[{"name":"needs-design"}]')
  
  if readiness_check_labels "$issue" "athal7/ocdc"; then
    echo "Issue with exclude label should not be eligible"
    return 1
  fi
  return 0
}

test_issue_with_multiple_labels_one_blocking() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Mixed labels" '[{"name":"bug"},{"name":"blocked"},{"name":"high"}]')
  
  if readiness_check_labels "$issue" "athal7/ocdc"; then
    echo "Issue with one blocking label should not be eligible"
    return 1
  fi
  return 0
}

# =============================================================================
# Dependency Check Tests
# =============================================================================

test_issue_without_dependencies_is_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Independent issue" '[]' "This is a standalone issue")
  
  if ! readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue without dependencies should be eligible"
    return 1
  fi
  return 0
}

test_issue_with_blocked_by_reference_is_not_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Dependent issue" '[]' "This is blocked by #10")
  
  if readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with 'blocked by' reference should not be eligible"
    return 1
  fi
  return 0
}

test_issue_with_depends_on_reference_is_not_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Dependent issue" '[]' "Depends on #15")
  
  if readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with 'depends on' reference should not be eligible"
    return 1
  fi
  return 0
}

test_issue_with_requires_reference_is_not_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Dependent issue" '[]' "Requires #20 to be done first")
  
  if readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with 'requires' reference should not be eligible"
    return 1
  fi
  return 0
}

test_issue_with_normal_issue_reference_is_eligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Related issue" '[]' "Related to #5, see also #6")
  
  if ! readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with normal references should be eligible"
    return 1
  fi
  return 0
}

# =============================================================================
# Priority Score Tests
# =============================================================================

test_priority_score_critical() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Critical issue" '[{"name":"critical"}]')
  
  local score
  score=$(readiness_calculate_priority "$issue" "athal7/ocdc")
  
  # Should be 100 (critical weight)
  if [[ "$score" -lt 100 ]]; then
    echo "Critical issue should have score >= 100, got $score"
    return 1
  fi
  return 0
}

test_priority_score_high() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "High priority" '[{"name":"high"}]')
  
  local score
  score=$(readiness_calculate_priority "$issue" "athal7/ocdc")
  
  # Should be around 50 (high weight)
  if [[ "$score" -lt 50 ]]; then
    echo "High priority issue should have score >= 50, got $score"
    return 1
  fi
  return 0
}

test_priority_score_no_label() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "No priority" '[]')
  
  local score
  score=$(readiness_calculate_priority "$issue" "athal7/ocdc")
  
  # Should be small (just age bonus)
  if [[ "$score" -gt 50 ]]; then
    echo "Issue without priority label should have low score, got $score"
    return 1
  fi
  return 0
}

test_priority_score_multiple_labels_takes_highest() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Multi-priority" '[{"name":"low"},{"name":"high"}]')
  
  local score
  score=$(readiness_calculate_priority "$issue" "athal7/ocdc")
  
  # Should use highest (high=50), not sum
  if [[ "$score" -lt 50 ]]; then
    echo "Issue with multiple priority labels should use highest, got $score"
    return 1
  fi
  return 0
}

# =============================================================================
# Age Bonus Tests
# =============================================================================

test_older_issue_has_higher_score() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue created 30 days ago
  local old_issue
  old_issue=$(create_issue_json 42 "Old issue" '[]' "" "2025-12-01T00:00:00Z")
  
  # Issue created today
  local new_issue
  new_issue=$(create_issue_json 43 "New issue" '[]' "" "2026-01-03T00:00:00Z")
  
  local old_score new_score
  old_score=$(readiness_calculate_priority "$old_issue" "athal7/ocdc")
  new_score=$(readiness_calculate_priority "$new_issue" "athal7/ocdc")
  
  if [[ "$old_score" -le "$new_score" ]]; then
    echo "Older issue should have higher score: old=$old_score, new=$new_score"
    return 1
  fi
  return 0
}

# =============================================================================
# Full Eligibility Tests
# =============================================================================

test_evaluate_eligible_issue() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Good issue" '[{"name":"high"}]' "A good issue to work on")
  
  local result
  result=$(readiness_evaluate "$issue" "athal7/ocdc")
  
  local eligible
  eligible=$(echo "$result" | jq -r '.eligible')
  
  assert_equals "true" "$eligible"
}

test_evaluate_blocked_issue() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Blocked" '[{"name":"blocked"}]')
  
  local result
  result=$(readiness_evaluate "$issue" "athal7/ocdc")
  
  local eligible
  eligible=$(echo "$result" | jq -r '.eligible')
  
  assert_equals "false" "$eligible"
}

test_evaluate_dependent_issue() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Dependent" '[]' "Blocked by #10")
  
  local result
  result=$(readiness_evaluate "$issue" "athal7/ocdc")
  
  local eligible
  eligible=$(echo "$result" | jq -r '.eligible')
  
  assert_equals "false" "$eligible"
}

test_evaluate_returns_score() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Scored issue" '[{"name":"critical"}]')
  
  local result
  result=$(readiness_evaluate "$issue" "athal7/ocdc")
  
  local score
  score=$(echo "$result" | jq -r '.score')
  
  if [[ "$score" -lt 100 ]]; then
    echo "Critical issue should have score >= 100, got $score"
    return 1
  fi
  return 0
}

test_evaluate_returns_reason_when_ineligible() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Blocked" '[{"name":"wontfix"}]')
  
  local result
  result=$(readiness_evaluate "$issue" "athal7/ocdc")
  
  local reason
  reason=$(echo "$result" | jq -r '.reason')
  
  if [[ -z "$reason" ]] || [[ "$reason" == "null" ]]; then
    echo "Ineligible issue should have a reason"
    return 1
  fi
  return 0
}

# =============================================================================
# Inferred Priority Tests
# =============================================================================

test_milestone_boosts_priority() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue with milestone (no priority label)
  local with_milestone
  with_milestone=$(create_issue_json 42 "Has milestone" '[]' "" "2026-01-01T00:00:00Z" '{"milestone":{"title":"v1.0"}}')
  
  # Issue without milestone (no priority label)  
  local without_milestone
  without_milestone=$(create_issue_json 43 "No milestone" '[]' "" "2026-01-01T00:00:00Z")
  
  local score_with score_without
  score_with=$(readiness_calculate_priority "$with_milestone" "athal7/ocdc")
  score_without=$(readiness_calculate_priority "$without_milestone" "athal7/ocdc")
  
  if [[ "$score_with" -le "$score_without" ]]; then
    echo "Issue with milestone should have higher score: with=$score_with, without=$score_without"
    return 1
  fi
  return 0
}

test_reactions_boost_priority() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue with reactions (no priority label)
  local with_reactions
  with_reactions=$(create_issue_json 42 "Has reactions" '[]' "" "2026-01-01T00:00:00Z" '{"reactions":{"+1":5}}')
  
  # Issue without reactions (no priority label)  
  local without_reactions
  without_reactions=$(create_issue_json 43 "No reactions" '[]' "" "2026-01-01T00:00:00Z")
  
  local score_with score_without
  score_with=$(readiness_calculate_priority "$with_reactions" "athal7/ocdc")
  score_without=$(readiness_calculate_priority "$without_reactions" "athal7/ocdc")
  
  if [[ "$score_with" -le "$score_without" ]]; then
    echo "Issue with reactions should have higher score: with=$score_with, without=$score_without"
    return 1
  fi
  return 0
}

test_comments_boost_priority() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue with comments (no priority label)
  local with_comments
  with_comments=$(create_issue_json 42 "Has comments" '[]' "" "2026-01-01T00:00:00Z" '{"comments":5}')
  
  # Issue without comments (no priority label)  
  local without_comments
  without_comments=$(create_issue_json 43 "No comments" '[]' "" "2026-01-01T00:00:00Z")
  
  local score_with score_without
  score_with=$(readiness_calculate_priority "$with_comments" "athal7/ocdc")
  score_without=$(readiness_calculate_priority "$without_comments" "athal7/ocdc")
  
  if [[ "$score_with" -le "$score_without" ]]; then
    echo "Issue with comments should have higher score: with=$score_with, without=$score_without"
    return 1
  fi
  return 0
}

test_assignee_boosts_priority() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue with assignee (no priority label)
  local with_assignee
  with_assignee=$(create_issue_json 42 "Has assignee" '[]' "" "2026-01-01T00:00:00Z" '{"assignees":[{"login":"user1"}]}')
  
  # Issue without assignee (no priority label)  
  local without_assignee
  without_assignee=$(create_issue_json 43 "No assignee" '[]' "" "2026-01-01T00:00:00Z")
  
  local score_with score_without
  score_with=$(readiness_calculate_priority "$with_assignee" "athal7/ocdc")
  score_without=$(readiness_calculate_priority "$without_assignee" "athal7/ocdc")
  
  if [[ "$score_with" -le "$score_without" ]]; then
    echo "Issue with assignee should have higher score: with=$score_with, without=$score_without"
    return 1
  fi
  return 0
}

test_explicit_label_overrides_inferred() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Issue with critical label (should use label, not inferred)
  local with_label
  with_label=$(create_issue_json 42 "Critical" '[{"name":"critical"}]' "" "2026-01-01T00:00:00Z")
  
  local score
  score=$(readiness_calculate_priority "$with_label" "athal7/ocdc")
  
  # Should be at least 100 (critical weight), inferred bonuses don't add
  if [[ "$score" -lt 100 ]]; then
    echo "Issue with critical label should have score >= 100, got $score"
    return 1
  fi
  return 0
}

# =============================================================================
# Inferred Dependency Tests
# =============================================================================

test_issue_with_unchecked_tasks_is_blocked() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local body="## Tasks
- [ ] Task 1
- [ ] Task 2
- [x] Task 3"
  
  local issue
  issue=$(create_issue_json 42 "Tracking issue" '[]' "$body")
  
  if readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with unchecked tasks should be blocked"
    return 1
  fi
  return 0
}

test_issue_with_all_checked_tasks_is_not_blocked() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local body="## Tasks
- [x] Task 1
- [x] Task 2
- [x] Task 3"
  
  local issue
  issue=$(create_issue_json 42 "Completed tracking" '[]' "$body")
  
  if ! readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with all checked tasks should not be blocked"
    return 1
  fi
  return 0
}

test_issue_with_single_checkbox_not_blocked() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  # Single checkbox is likely not a tracking issue
  local body="Checklist:
- [ ] Review before merging"
  
  local issue
  issue=$(create_issue_json 42 "Simple issue" '[]' "$body")
  
  # Single checkbox shouldn't block - could just be a reminder
  if ! readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with single checkbox should not be blocked"
    return 1
  fi
  return 0
}

test_after_reference_is_dependency() {
  source "$LIB_DIR/ocdc-readiness.bash"
  
  local issue
  issue=$(create_issue_json 42 "Sequenced issue" '[]' "Do this after #15")
  
  if readiness_check_dependencies "$issue" "athal7/ocdc"; then
    echo "Issue with 'after #X' reference should be blocked"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Readiness Evaluation Tests:"

for test_func in \
  test_readiness_library_exists \
  test_readiness_can_be_sourced \
  test_issue_without_blocking_labels_is_eligible \
  test_issue_with_blocking_label_is_not_eligible \
  test_issue_with_exclude_label_is_not_eligible \
  test_issue_with_multiple_labels_one_blocking \
  test_issue_without_dependencies_is_eligible \
  test_issue_with_blocked_by_reference_is_not_eligible \
  test_issue_with_depends_on_reference_is_not_eligible \
  test_issue_with_requires_reference_is_not_eligible \
  test_issue_with_normal_issue_reference_is_eligible \
  test_priority_score_critical \
  test_priority_score_high \
  test_priority_score_no_label \
  test_priority_score_multiple_labels_takes_highest \
  test_older_issue_has_higher_score \
  test_evaluate_eligible_issue \
  test_evaluate_blocked_issue \
  test_evaluate_dependent_issue \
  test_evaluate_returns_score \
  test_evaluate_returns_reason_when_ineligible \
  test_milestone_boosts_priority \
  test_reactions_boost_priority \
  test_comments_boost_priority \
  test_assignee_boosts_priority \
  test_explicit_label_overrides_inferred \
  test_issue_with_unchecked_tasks_is_blocked \
  test_issue_with_all_checked_tasks_is_not_blocked \
  test_issue_with_single_checkbox_not_blocked \
  test_after_reference_is_dependency
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
