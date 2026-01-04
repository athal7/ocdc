#!/usr/bin/env bash
#
# Tests for self-iteration (candidate fetching and label management)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing self-iteration..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  export OCDC_REPOS_FILE="$TEST_CONFIG_DIR/repos.yaml"
  export OCDC_WIP_STATE_FILE="$TEST_DATA_DIR/wip-state.json"
  export OCDC_CONFIG_FILE="$TEST_CONFIG_DIR/config.json"
  
  # Create main config with self-iteration settings
  cat > "$OCDC_CONFIG_FILE" << 'EOF'
{
  "self_iteration": {
    "enabled": true,
    "ready_label": "ocdc:ready",
    "dry_run": false
  },
  "wip_limits": {
    "global_max": 5
  }
}
EOF
  
  # Create repos config with new format
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  athal7/ocdc:
    repo_path: ~/code/ocdc
    issue_tracker:
      source_type: github_issue
      fetch_options:
        repo: athal7/ocdc
      ready_action:
        type: add_label
        label: "ocdc:ready"
    readiness:
      labels:
        exclude: ["blocked", "needs-design"]
      priority:
        labels:
          - label: critical
            weight: 100
          - label: high
            weight: 50
    wip_limits:
      max_concurrent: 2
EOF
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Basic Tests
# =============================================================================

test_self_iteration_library_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-self-iteration.bash" ]]; then
    echo "lib/ocdc-self-iteration.bash does not exist"
    return 1
  fi
  return 0
}

test_self_iteration_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-self-iteration.bash" 2>&1; then
    echo "Failed to source ocdc-self-iteration.bash"
    return 1
  fi
  return 0
}

# =============================================================================
# Config Tests
# =============================================================================

test_get_self_iteration_config() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  local config
  config=$(self_iteration_get_config)
  
  local enabled
  enabled=$(echo "$config" | jq -r '.enabled')
  
  assert_equals "true" "$enabled"
}

test_get_ready_label() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  local label
  label=$(self_iteration_get_ready_label)
  
  assert_equals "ocdc:ready" "$label"
}

test_is_enabled() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  if ! self_iteration_is_enabled; then
    echo "Self-iteration should be enabled"
    return 1
  fi
  return 0
}

test_is_disabled_when_config_says_so() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Override config to disable
  cat > "$OCDC_CONFIG_FILE" << 'EOF'
{
  "self_iteration": {
    "enabled": false
  }
}
EOF
  
  if self_iteration_is_enabled; then
    echo "Self-iteration should be disabled"
    return 1
  fi
  return 0
}

# =============================================================================
# Slot Calculation Tests
# =============================================================================

test_calculate_available_slots_empty() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  local slots
  slots=$(self_iteration_available_slots "athal7/ocdc")
  
  # Repo limit is 2, global is 5, both empty -> min(2, 5) = 2
  assert_equals "2" "$slots"
}

test_calculate_available_slots_with_wip() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  source "$LIB_DIR/ocdc-wip.bash"
  
  # Add one session for this repo
  wip_add_session "key1" "athal7/ocdc" "high"
  
  local slots
  slots=$(self_iteration_available_slots "athal7/ocdc")
  
  # Repo limit is 2, 1 used -> 1 available
  assert_equals "1" "$slots"
}

test_calculate_available_slots_respects_global_limit() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  source "$LIB_DIR/ocdc-wip.bash"
  
  # Add 4 sessions globally (different repos)
  wip_add_session "key1" "other/repo1" "high"
  wip_add_session "key2" "other/repo2" "high"
  wip_add_session "key3" "other/repo3" "high"
  wip_add_session "key4" "other/repo4" "high"
  
  local slots
  slots=$(self_iteration_available_slots "athal7/ocdc")
  
  # Global limit is 5, 4 used globally -> 1 available globally
  # Repo limit is 2, 0 used for this repo
  # min(2, 1) = 1
  assert_equals "1" "$slots"
}

# =============================================================================
# Candidate Selection Tests  
# =============================================================================

test_select_candidates_respects_slots() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Create test issues JSON
  local issues='[
    {"number":1,"title":"Issue 1","labels":[{"name":"high"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}},
    {"number":2,"title":"Issue 2","labels":[{"name":"critical"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}},
    {"number":3,"title":"Issue 3","labels":[{"name":"medium"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}}
  ]'
  
  local selected
  selected=$(self_iteration_select_candidates "$issues" "athal7/ocdc" 2)
  
  local count
  count=$(echo "$selected" | jq 'length')
  
  # Should select 2 (slot limit)
  assert_equals "2" "$count"
}

test_select_candidates_prioritizes_by_score() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Create test issues JSON - critical should come first
  local issues='[
    {"number":1,"title":"Low priority","labels":[{"name":"low"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}},
    {"number":2,"title":"Critical","labels":[{"name":"critical"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}}
  ]'
  
  local selected
  selected=$(self_iteration_select_candidates "$issues" "athal7/ocdc" 1)
  
  local first_number
  first_number=$(echo "$selected" | jq '.[0].number')
  
  # Critical (#2) should be selected
  assert_equals "2" "$first_number"
}

test_select_candidates_excludes_blocked() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Create test issues JSON - blocked should be excluded
  local issues='[
    {"number":1,"title":"Blocked issue","labels":[{"name":"blocked"},{"name":"critical"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}},
    {"number":2,"title":"Normal issue","labels":[{"name":"low"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}}
  ]'
  
  local selected
  selected=$(self_iteration_select_candidates "$issues" "athal7/ocdc" 2)
  
  local count
  count=$(echo "$selected" | jq 'length')
  
  # Should only select 1 (blocked excluded)
  assert_equals "1" "$count"
}

test_select_candidates_excludes_already_ready() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Issues with ready label should be excluded
  local issues='[
    {"number":1,"title":"Already ready","labels":[{"name":"ocdc:ready"}],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}},
    {"number":2,"title":"Not ready yet","labels":[],"body":"","state":"open","created_at":"2026-01-01T00:00:00Z","repository":{"full_name":"athal7/ocdc"}}
  ]'
  
  local selected
  selected=$(self_iteration_select_candidates "$issues" "athal7/ocdc" 2)
  
  local count
  count=$(echo "$selected" | jq 'length')
  
  # Should only select 1 (already-ready excluded)
  assert_equals "1" "$count"
}

# =============================================================================
# MCP Fetch Integration Tests  
# =============================================================================

test_fetch_issues_function_exists() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Verify the MCP-based fetch function exists
  if ! type self_iteration_fetch_issues &>/dev/null; then
    echo "self_iteration_fetch_issues function should exist"
    return 1
  fi
  return 0
}

test_normalize_issues_handles_empty() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  local result
  result=$(self_iteration_normalize_issues "")
  
  assert_equals "[]" "$result"
}

test_normalize_issues_handles_null() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  local result
  result=$(self_iteration_normalize_issues "null")
  
  assert_equals "[]" "$result"
}

test_normalize_issues_converts_camelcase_to_snake_case() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Input with camelCase (gh CLI format)
  local input='[{"number":1,"title":"Test","createdAt":"2026-01-01T00:00:00Z"}]'
  
  local result
  result=$(self_iteration_normalize_issues "$input")
  
  # Should have created_at (snake_case)
  local created_at
  created_at=$(echo "$result" | jq -r '.[0].created_at')
  
  if [[ "$created_at" != "2026-01-01T00:00:00Z" ]]; then
    echo "Expected created_at to be normalized, got: $created_at"
    return 1
  fi
  return 0
}

test_normalize_issues_handles_comments_array() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Input with comments as array (gh CLI format)
  local input='[{"number":1,"title":"Test","comments":[{"id":1},{"id":2}]}]'
  
  local result
  result=$(self_iteration_normalize_issues "$input")
  
  # Should convert array to count
  local comments
  comments=$(echo "$result" | jq -r '.[0].comments')
  
  assert_equals "2" "$comments"
}

test_normalize_issues_handles_comments_integer() {
  source "$LIB_DIR/ocdc-self-iteration.bash"
  
  # Input with comments as integer (REST API format)
  local input='[{"number":1,"title":"Test","comments":5}]'
  
  local result
  result=$(self_iteration_normalize_issues "$input")
  
  # Should preserve integer
  local comments
  comments=$(echo "$result" | jq -r '.[0].comments')
  
  assert_equals "5" "$comments"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Self-Iteration Tests:"

for test_func in \
  test_self_iteration_library_exists \
  test_self_iteration_can_be_sourced \
  test_get_self_iteration_config \
  test_get_ready_label \
  test_is_enabled \
  test_is_disabled_when_config_says_so \
  test_calculate_available_slots_empty \
  test_calculate_available_slots_with_wip \
  test_calculate_available_slots_respects_global_limit \
  test_select_candidates_respects_slots \
  test_select_candidates_prioritizes_by_score \
  test_select_candidates_excludes_blocked \
  test_select_candidates_excludes_already_ready \
  test_fetch_issues_function_exists \
  test_normalize_issues_handles_empty \
  test_normalize_issues_handles_null \
  test_normalize_issues_converts_camelcase_to_snake_case \
  test_normalize_issues_handles_comments_array \
  test_normalize_issues_handles_comments_integer
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
