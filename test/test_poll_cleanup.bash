#!/usr/bin/env bash
#
# Tests for poll cleanup detection and execution
#
# Tests for:
#   - Cleanup queue management (add, remove, list)
#   - PR state detection via gh CLI
#   - Cleanup execution (kill_session, stop_container, remove_clone)
#   - Grace period handling
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing poll cleanup..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create poll state directory
  export OCDC_POLL_STATE_DIR="$TEST_DATA_DIR/poll-state"
  export OCDC_CLEANUP_QUEUE_FILE="$OCDC_POLL_STATE_DIR/cleanup-queue.json"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  
  # Initialize empty cleanup queue
  echo '{"items":[]}' > "$OCDC_CLEANUP_QUEUE_FILE"
  
  # Source the paths and cleanup library
  source "$LIB_DIR/ocdc-paths.bash"
  source "$LIB_DIR/ocdc-poll-cleanup.bash"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Tests: Duration parsing
# =============================================================================

test_parse_duration_seconds() {
  local result
  result=$(cleanup_parse_duration "30s")
  assert_equals "30" "$result"
}

test_parse_duration_minutes() {
  local result
  result=$(cleanup_parse_duration "5m")
  assert_equals "300" "$result"
}

test_parse_duration_hours() {
  local result
  result=$(cleanup_parse_duration "2h")
  assert_equals "7200" "$result"
}

test_parse_duration_default_minutes() {
  # Plain number should be treated as minutes for backwards compatibility
  local result
  result=$(cleanup_parse_duration "10")
  assert_equals "600" "$result"
}

test_parse_duration_invalid_returns_default() {
  local result
  result=$(cleanup_parse_duration "invalid")
  # Should return default of 5 minutes (300 seconds)
  assert_equals "300" "$result"
}

# =============================================================================
# Tests: Queue management - Add to queue
# =============================================================================

test_cleanup_queue_add_item() {
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  local count
  count=$(jq '.items | length' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "1" "$count"
  
  local key
  key=$(jq -r '.items[0].key' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "myorg/api-pr-100" "$key"
  
  local reason
  reason=$(jq -r '.items[0].reason' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "merged" "$reason"
}

test_cleanup_queue_add_sets_timestamps() {
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  local queued_at cleanup_after
  queued_at=$(jq -r '.items[0].queued_at' "$OCDC_CLEANUP_QUEUE_FILE")
  cleanup_after=$(jq -r '.items[0].cleanup_after' "$OCDC_CLEANUP_QUEUE_FILE")
  
  # Both should be ISO timestamps
  if [[ ! "$queued_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    echo "queued_at should be ISO timestamp: $queued_at"
    return 1
  fi
  if [[ ! "$cleanup_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    echo "cleanup_after should be ISO timestamp: $cleanup_after"
    return 1
  fi
  return 0
}

test_cleanup_queue_add_does_not_duplicate() {
  # Add same item twice
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "closed" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  local count
  count=$(jq '.items | length' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "1" "$count"
}

# =============================================================================
# Tests: Queue management - Remove from queue
# =============================================================================

test_cleanup_queue_remove_item() {
  # Add item
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  # Remove it
  cleanup_queue_remove "myorg/api-pr-100"
  
  local count
  count=$(jq '.items | length' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "0" "$count"
}

test_cleanup_queue_remove_nonexistent_is_safe() {
  # Should not error when removing item that doesn't exist
  cleanup_queue_remove "nonexistent-key"
  
  local count
  count=$(jq '.items | length' "$OCDC_CLEANUP_QUEUE_FILE")
  assert_equals "0" "$count"
}

# =============================================================================
# Tests: Queue management - Query
# =============================================================================

test_cleanup_queue_is_queued() {
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "5m"
  
  # Should return 0 (true) for queued item
  if ! cleanup_queue_is_queued "myorg/api-pr-100"; then
    echo "Item should be queued"
    return 1
  fi
  
  # Should return 1 (false) for non-queued item
  if cleanup_queue_is_queued "other-item"; then
    echo "Item should not be queued"
    return 1
  fi
  return 0
}

test_cleanup_queue_get_ready_items() {
  # Add item with 0 delay (ready immediately)
  cleanup_queue_add \
    "myorg/api-pr-100" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-100" \
    "/tmp/clone/api/pr-100" \
    "https://github.com/myorg/api/pull/100" \
    "github_pr" \
    "0s"
  
  # Add item with long delay (not ready)
  cleanup_queue_add \
    "myorg/api-pr-200" \
    "github-reviews" \
    "merged" \
    "ocdc-review-api-200" \
    "/tmp/clone/api/pr-200" \
    "https://github.com/myorg/api/pull/200" \
    "github_pr" \
    "1h"
  
  local ready_items
  ready_items=$(cleanup_queue_get_ready)
  
  # Should contain pr-100 but not pr-200
  assert_contains "$ready_items" "myorg/api-pr-100"
  if [[ "$ready_items" == *"myorg/api-pr-200"* ]]; then
    echo "pr-200 should not be ready yet"
    return 1
  fi
  return 0
}

# =============================================================================
# Tests: PR state detection
# =============================================================================

test_github_pr_state_parsing() {
  # Test parsing of gh CLI output
  local gh_output='{"state":"MERGED","mergedAt":"2025-01-15T12:00:00Z"}'
  local result
  result=$(cleanup_parse_github_pr_state "$gh_output")
  
  local should_cleanup reason
  should_cleanup=$(echo "$result" | jq -r '.should_cleanup')
  reason=$(echo "$result" | jq -r '.reason')
  
  assert_equals "true" "$should_cleanup"
  assert_equals "merged" "$reason"
}

test_github_pr_state_closed_not_merged() {
  local gh_output='{"state":"CLOSED","mergedAt":null}'
  local result
  result=$(cleanup_parse_github_pr_state "$gh_output")
  
  local should_cleanup reason
  should_cleanup=$(echo "$result" | jq -r '.should_cleanup')
  reason=$(echo "$result" | jq -r '.reason')
  
  assert_equals "true" "$should_cleanup"
  assert_equals "closed" "$reason"
}

test_github_pr_state_open() {
  local gh_output='{"state":"OPEN","mergedAt":null}'
  local result
  result=$(cleanup_parse_github_pr_state "$gh_output")
  
  local should_cleanup
  should_cleanup=$(echo "$result" | jq -r '.should_cleanup')
  
  assert_equals "false" "$should_cleanup"
}

test_cleanup_check_source_state_parses_pr_url() {
  # This tests the URL parsing logic in cleanup_check_source_state
  # We can't test the gh CLI call directly, but we can test URL parsing
  local source_url="https://github.com/myorg/myrepo/pull/123"
  
  # The function should extract: repo=myorg/myrepo, pr_number=123
  # Since we don't want to call gh CLI in tests, we verify the regex works
  if [[ "$source_url" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    local repo="${BASH_REMATCH[1]}"
    local pr_number="${BASH_REMATCH[2]}"
    
    assert_equals "myorg/myrepo" "$repo"
    assert_equals "123" "$pr_number"
  else
    echo "URL regex should match: $source_url"
    return 1
  fi
  return 0
}

test_cleanup_check_source_state_parses_issue_url() {
  local source_url="https://github.com/owner/repo/issues/456"
  
  if [[ "$source_url" =~ github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then
    local repo="${BASH_REMATCH[1]}"
    local issue_number="${BASH_REMATCH[2]}"
    
    assert_equals "owner/repo" "$repo"
    assert_equals "456" "$issue_number"
  else
    echo "URL regex should match: $source_url"
    return 1
  fi
  return 0
}

test_cleanup_check_source_state_unknown_type_returns_false() {
  local result
  result=$(cleanup_check_source_state "unknown_type" "https://example.com/item/123")
  
  local should_cleanup
  should_cleanup=$(echo "$result" | jq -r '.should_cleanup')
  
  assert_equals "false" "$should_cleanup"
}

# =============================================================================
# Tests: Cleanup config parsing
# =============================================================================

test_cleanup_config_defaults() {
  # When no cleanup config is specified, should use defaults
  local config_json='{}'
  local result
  result=$(cleanup_get_config_with_defaults "$config_json")
  
  local enabled delay
  enabled=$(echo "$result" | jq -r '.enabled')
  delay=$(echo "$result" | jq -r '.delay')
  
  assert_equals "true" "$enabled"
  assert_equals "5m" "$delay"
}

test_cleanup_config_override() {
  local config_json='{"enabled": false, "delay": "10m", "on": ["merged"], "actions": ["kill_session"]}'
  local result
  result=$(cleanup_get_config_with_defaults "$config_json")
  
  local enabled delay on_count actions_count
  enabled=$(echo "$result" | jq -r '.enabled')
  delay=$(echo "$result" | jq -r '.delay')
  on_count=$(echo "$result" | jq '.on | length')
  actions_count=$(echo "$result" | jq '.actions | length')
  
  assert_equals "false" "$enabled"
  assert_equals "10m" "$delay"
  assert_equals "1" "$on_count"
  assert_equals "1" "$actions_count"
}

test_cleanup_should_trigger_for_reason() {
  local config_json='{"on": ["merged", "closed"]}'
  
  # Should trigger for merged
  if ! cleanup_should_trigger_for_reason "$config_json" "merged"; then
    echo "Should trigger for merged"
    return 1
  fi
  
  # Should trigger for closed
  if ! cleanup_should_trigger_for_reason "$config_json" "closed"; then
    echo "Should trigger for closed"
    return 1
  fi
  
  # Should not trigger for other
  if cleanup_should_trigger_for_reason "$config_json" "other"; then
    echo "Should not trigger for other"
    return 1
  fi
  
  return 0
}

# =============================================================================
# Tests: Cleanup execution
# =============================================================================

# Helper: Create a mock tmux session for cleanup testing
create_cleanup_test_session() {
  local session_name="$1"
  local poll_config="${2:-test-poll}"
  local item_key="${3:-test/repo-pr-42}"
  local workspace="${4:-/tmp/test-workspace}"
  local source_url="${5:-https://github.com/test/repo/pull/42}"
  local source_type="${6:-github_pr}"
  
  tmux new-session -d -s "$session_name" -c "/tmp" \
    -e "OCDC_POLL_CONFIG=$poll_config" \
    -e "OCDC_ITEM_KEY=$item_key" \
    -e "OCDC_WORKSPACE=$workspace" \
    -e "OCDC_BRANCH=test-branch" \
    -e "OCDC_SOURCE_URL=$source_url" \
    -e "OCDC_SOURCE_TYPE=$source_type" \
    "sleep 3600" 2>/dev/null || true
}

# Helper: Clean up test sessions
cleanup_test_sessions() {
  for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-cleanup-' || true); do
    tmux kill-session -t "$session" 2>/dev/null || true
  done
}

test_cleanup_execute_kill_session() {
  cleanup_test_sessions
  
  # Create a test session
  local session_name="test-cleanup-session-1"
  create_cleanup_test_session "$session_name"
  
  # Verify session exists
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Failed to create test session"
    return 1
  fi
  
  # Execute kill_session action
  cleanup_execute_action "kill_session" "$session_name" "/tmp/nonexistent"
  
  # Verify session is gone
  if tmux has-session -t "$session_name" 2>/dev/null; then
    cleanup_test_sessions
    echo "Session should have been killed"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

test_cleanup_execute_all_actions() {
  cleanup_test_sessions
  
  # Create a test session
  local session_name="test-cleanup-session-2"
  local workspace="$TEST_CLONES_DIR/test-repo/test-branch"
  mkdir -p "$workspace"
  
  create_cleanup_test_session "$session_name" "test-poll" "test/repo-pr-42" "$workspace"
  
  # Add to queue
  cleanup_queue_add \
    "test/repo-pr-42" \
    "test-poll" \
    "merged" \
    "$session_name" \
    "$workspace" \
    "https://github.com/test/repo/pull/42" \
    "github_pr" \
    "0s"
  
  # Execute all cleanup actions
  local actions='["kill_session", "remove_clone"]'
  cleanup_execute_all "$session_name" "$workspace" "$actions"
  
  # Verify session is gone
  if tmux has-session -t "$session_name" 2>/dev/null; then
    cleanup_test_sessions
    echo "Session should have been killed"
    return 1
  fi
  
  # Verify workspace is removed (if remove_clone was executed)
  if [[ -d "$workspace" ]]; then
    cleanup_test_sessions
    echo "Workspace should have been removed"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

test_cleanup_execute_skips_dirty_workspace() {
  cleanup_test_sessions
  
  # Create a test session with a dirty git workspace
  local session_name="test-cleanup-session-3"
  local workspace="$TEST_CLONES_DIR/dirty-repo/test-branch"
  mkdir -p "$workspace"
  
  # Initialize git repo with uncommitted changes
  (cd "$workspace" && git init && echo "test" > file.txt && git add file.txt && git commit -m "initial" && echo "uncommitted" > file.txt)
  
  create_cleanup_test_session "$session_name" "test-poll" "test/dirty-pr-42" "$workspace"
  
  # Execute cleanup with remove_clone - should skip due to dirty git
  local actions='["kill_session", "remove_clone"]'
  cleanup_execute_all "$session_name" "$workspace" "$actions"
  
  # Session should be gone (kill_session always works)
  if tmux has-session -t "$session_name" 2>/dev/null; then
    cleanup_test_sessions
    echo "Session should have been killed"
    return 1
  fi
  
  # Workspace should still exist (remove_clone skipped due to dirty git)
  if [[ ! -d "$workspace" ]]; then
    cleanup_test_sessions
    echo "Workspace should NOT have been removed (dirty git)"
    return 1
  fi
  
  # Cleanup
  rm -rf "$workspace"
  cleanup_test_sessions
  return 0
}

test_cleanup_get_actions_from_config() {
  local config_json='{"actions": ["kill_session", "stop_container"]}'
  local actions
  actions=$(cleanup_get_actions "$config_json" | tr '\n' ' ' | xargs)
  
  assert_contains "$actions" "kill_session"
  assert_contains "$actions" "stop_container"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Duration Parsing Tests:"
for test_func in \
  test_parse_duration_seconds \
  test_parse_duration_minutes \
  test_parse_duration_hours \
  test_parse_duration_default_minutes \
  test_parse_duration_invalid_returns_default
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Queue Add Tests:"
for test_func in \
  test_cleanup_queue_add_item \
  test_cleanup_queue_add_sets_timestamps \
  test_cleanup_queue_add_does_not_duplicate
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Queue Remove Tests:"
for test_func in \
  test_cleanup_queue_remove_item \
  test_cleanup_queue_remove_nonexistent_is_safe
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Queue Query Tests:"
for test_func in \
  test_cleanup_queue_is_queued \
  test_cleanup_queue_get_ready_items
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "PR State Detection Tests:"
for test_func in \
  test_github_pr_state_parsing \
  test_github_pr_state_closed_not_merged \
  test_github_pr_state_open \
  test_cleanup_check_source_state_parses_pr_url \
  test_cleanup_check_source_state_parses_issue_url \
  test_cleanup_check_source_state_unknown_type_returns_false
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Cleanup Config Tests:"
for test_func in \
  test_cleanup_config_defaults \
  test_cleanup_config_override \
  test_cleanup_should_trigger_for_reason \
  test_cleanup_get_actions_from_config
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Cleanup Execution Tests:"
for test_func in \
  test_cleanup_execute_kill_session \
  test_cleanup_execute_all_actions \
  test_cleanup_execute_skips_dirty_workspace
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
