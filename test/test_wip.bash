#!/usr/bin/env bash
#
# Tests for WIP (Work In Progress) state tracking
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing WIP state tracking..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Set up WIP state file location
  export OCDC_WIP_STATE_FILE="$TEST_DATA_DIR/wip-state.json"
  export OCDC_REPOS_FILE="$TEST_CONFIG_DIR/repos.yaml"
  
  # Create a basic repos config for testing
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  org/repo1:
    repo_path: ~/code/repo1
    wip_limits:
      max_concurrent: 2
  
  org/repo2:
    repo_path: ~/code/repo2
    wip_limits:
      max_concurrent: 1
  
  org/repo3:
    repo_path: ~/code/repo3
EOF
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Basic Tests
# =============================================================================

test_wip_library_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-wip.bash" ]]; then
    echo "lib/ocdc-wip.bash does not exist"
    return 1
  fi
  return 0
}

test_wip_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-wip.bash" 2>&1; then
    echo "Failed to source ocdc-wip.bash"
    return 1
  fi
  return 0
}

# =============================================================================
# Session Tracking Tests
# =============================================================================

test_add_wip_session() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  local count
  count=$(wip_count_active)
  
  assert_equals "1" "$count"
}

test_add_multiple_wip_sessions() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  wip_add_session "org/repo1-issue-43" "org/repo1" "medium"
  wip_add_session "org/repo2-issue-1" "org/repo2" "low"
  
  local count
  count=$(wip_count_active)
  
  assert_equals "3" "$count"
}

test_remove_wip_session() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  wip_add_session "org/repo1-issue-43" "org/repo1" "medium"
  
  wip_remove_session "org/repo1-issue-42"
  
  local count
  count=$(wip_count_active)
  
  assert_equals "1" "$count"
}

test_remove_nonexistent_session() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  # Should not error
  wip_remove_session "nonexistent-key"
  
  local count
  count=$(wip_count_active)
  
  assert_equals "1" "$count"
}

test_is_session_active() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  if ! wip_is_active "org/repo1-issue-42"; then
    echo "Session should be active"
    return 1
  fi
  return 0
}

test_is_session_not_active() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  if wip_is_active "nonexistent-key"; then
    echo "Session should not be active"
    return 1
  fi
  return 0
}

# =============================================================================
# Per-Repo Count Tests
# =============================================================================

test_count_repo_sessions() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  wip_add_session "org/repo1-issue-43" "org/repo1" "medium"
  wip_add_session "org/repo2-issue-1" "org/repo2" "low"
  
  local count
  count=$(wip_count_repo "org/repo1")
  
  assert_equals "2" "$count"
}

test_count_repo_sessions_empty() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  local count
  count=$(wip_count_repo "org/repo2")
  
  assert_equals "0" "$count"
}

# =============================================================================
# WIP Limit Tests
# =============================================================================

test_check_global_limit_under() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  # Default global limit is 5
  if ! wip_check_global_limit; then
    echo "Should be under global limit"
    return 1
  fi
  return 0
}

test_check_global_limit_at() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  # Add 5 sessions (default global limit)
  wip_add_session "key1" "org/repo1" "high"
  wip_add_session "key2" "org/repo1" "high"
  wip_add_session "key3" "org/repo2" "high"
  wip_add_session "key4" "org/repo2" "high"
  wip_add_session "key5" "org/repo3" "high"
  
  # Should be at limit
  if wip_check_global_limit; then
    echo "Should be at global limit"
    return 1
  fi
  return 0
}

test_check_repo_limit_under() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  # org/repo1 has limit of 2
  if ! wip_check_repo_limit "org/repo1"; then
    echo "Should be under repo limit"
    return 1
  fi
  return 0
}

test_check_repo_limit_at() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  # org/repo2 has limit of 1
  wip_add_session "org/repo2-issue-1" "org/repo2" "high"
  
  if wip_check_repo_limit "org/repo2"; then
    echo "Should be at repo limit"
    return 1
  fi
  return 0
}

test_check_repo_limit_uses_default() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  # org/repo3 has no explicit limit, should use default (3)
  wip_add_session "key1" "org/repo3" "high"
  wip_add_session "key2" "org/repo3" "high"
  
  # Should still be under default limit of 3
  if ! wip_check_repo_limit "org/repo3"; then
    echo "Should be under default repo limit"
    return 1
  fi
  return 0
}

# =============================================================================
# Available Slots Tests
# =============================================================================

test_get_available_slots_global() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "key1" "org/repo1" "high"
  wip_add_session "key2" "org/repo1" "high"
  
  local slots
  slots=$(wip_available_slots)
  
  # Default global is 5, 2 used = 3 available
  assert_equals "3" "$slots"
}

test_get_available_slots_repo() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "key1" "org/repo1" "high"
  
  local slots
  slots=$(wip_available_slots_repo "org/repo1")
  
  # org/repo1 limit is 2, 1 used = 1 available
  assert_equals "1" "$slots"
}

# =============================================================================
# Session Data Tests
# =============================================================================

test_get_session_data() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  local data
  data=$(wip_get_session "org/repo1-issue-42")
  
  local repo_key
  repo_key=$(echo "$data" | jq -r '.repo_key')
  
  assert_equals "org/repo1" "$repo_key"
}

test_get_session_priority() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "critical"
  
  local data
  data=$(wip_get_session "org/repo1-issue-42")
  
  local priority
  priority=$(echo "$data" | jq -r '.priority')
  
  assert_equals "critical" "$priority"
}

test_session_has_started_at() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "org/repo1-issue-42" "org/repo1" "high"
  
  local data
  data=$(wip_get_session "org/repo1-issue-42")
  
  local started_at
  started_at=$(echo "$data" | jq -r '.started_at')
  
  if [[ -z "$started_at" ]] || [[ "$started_at" == "null" ]]; then
    echo "Session should have started_at timestamp"
    return 1
  fi
  return 0
}

# =============================================================================
# List Sessions Tests
# =============================================================================

test_list_all_sessions() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "key1" "org/repo1" "high"
  wip_add_session "key2" "org/repo2" "medium"
  
  local sessions
  sessions=$(wip_list_sessions)
  
  local count
  count=$(echo "$sessions" | jq 'length')
  
  assert_equals "2" "$count"
}

test_list_sessions_by_repo() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  wip_add_session "key1" "org/repo1" "high"
  wip_add_session "key2" "org/repo1" "medium"
  wip_add_session "key3" "org/repo2" "low"
  
  local sessions
  sessions=$(wip_list_sessions_repo "org/repo1")
  
  local count
  count=$(echo "$sessions" | jq 'length')
  
  assert_equals "2" "$count"
}

# =============================================================================
# Sync with Tmux Tests
# =============================================================================

test_sync_removes_stale_sessions() {
  source "$LIB_DIR/ocdc-wip.bash"
  
  # Add sessions without actual tmux sessions
  wip_add_session "stale-key" "org/repo1" "high"
  
  # Sync should remove sessions without tmux
  wip_sync_with_tmux
  
  local count
  count=$(wip_count_active)
  
  # Should be 0 since no actual tmux sessions exist
  assert_equals "0" "$count"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "WIP State Tracking Tests:"

for test_func in \
  test_wip_library_exists \
  test_wip_can_be_sourced \
  test_add_wip_session \
  test_add_multiple_wip_sessions \
  test_remove_wip_session \
  test_remove_nonexistent_session \
  test_is_session_active \
  test_is_session_not_active \
  test_count_repo_sessions \
  test_count_repo_sessions_empty \
  test_check_global_limit_under \
  test_check_global_limit_at \
  test_check_repo_limit_under \
  test_check_repo_limit_at \
  test_check_repo_limit_uses_default \
  test_get_available_slots_global \
  test_get_available_slots_repo \
  test_get_session_data \
  test_get_session_priority \
  test_session_has_started_at \
  test_list_all_sessions \
  test_list_sessions_by_repo \
  test_sync_removes_stale_sessions
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
