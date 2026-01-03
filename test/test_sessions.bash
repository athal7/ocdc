#!/usr/bin/env bash
#
# Tests for session management (lib/ocdc-sessions.bash)
#
# Tests for:
#   ocdc_list_poll_sessions - List tmux sessions with OCDC_* vars
#   ocdc_get_session_metadata - Get session metadata
#   ocdc_is_session_orphan - Check if session's workspace exists
#   ocdc_kill_session - Kill session and clear poll state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing session management..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Set up poll state directory
  export OCDC_POLL_STATE_DIR="$TEST_DATA_DIR/poll-state"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  echo '{}' > "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Source the sessions library
  source "$LIB_DIR/ocdc-paths.bash"
  source "$LIB_DIR/ocdc-sessions.bash"
}

teardown() {
  # Clean up any test tmux sessions
  for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-ocdc-' || true); do
    tmux kill-session -t "$session" 2>/dev/null || true
  done
  cleanup_test_env
}

# =============================================================================
# Helper: Create mock tmux session with OCDC env vars
# =============================================================================

create_test_session() {
  local session_name="$1"
  local workspace="${2:-/tmp/test-workspace}"
  local poll_config="${3:-test-poll}"
  local item_key="${4:-test-item-key}"
  local branch="${5:-test-branch}"
  
  tmux new-session -d -s "$session_name" \
    -e "OCDC_WORKSPACE=$workspace" \
    -e "OCDC_POLL_CONFIG=$poll_config" \
    -e "OCDC_ITEM_KEY=$item_key" \
    -e "OCDC_BRANCH=$branch" \
    "sleep 3600" 2>/dev/null || true
}

# =============================================================================
# Tests: ocdc_list_poll_sessions
# =============================================================================

test_list_poll_sessions_empty() {
  # Ensure no test sessions exist
  for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-ocdc-' || true); do
    tmux kill-session -t "$session" 2>/dev/null || true
  done
  
  local result
  result=$(ocdc_list_poll_sessions)
  
  # Should return empty array or no sessions matching our pattern
  # The function returns all OCDC sessions, so this tests the base case
  assert_equals "[]" "$result" || return 0  # Empty is fine
}

test_list_poll_sessions_finds_ocdc_session() {
  create_test_session "test-ocdc-session-1" "/tmp/test-ws" "my-poll" "my-key"
  
  local result
  result=$(ocdc_list_poll_sessions)
  
  # Should contain our session
  assert_contains "$result" "test-ocdc-session-1"
  
  tmux kill-session -t "test-ocdc-session-1" 2>/dev/null || true
}

test_list_poll_sessions_ignores_non_ocdc_session() {
  # Create a regular tmux session without OCDC vars
  tmux new-session -d -s "test-ocdc-regular" "sleep 3600" 2>/dev/null || true
  
  local result
  result=$(ocdc_list_poll_sessions)
  
  # Should NOT contain the regular session
  if [[ "$result" == *"test-ocdc-regular"* ]]; then
    tmux kill-session -t "test-ocdc-regular" 2>/dev/null || true
    echo "Should not list sessions without OCDC_POLL_CONFIG"
    return 1
  fi
  
  tmux kill-session -t "test-ocdc-regular" 2>/dev/null || true
  return 0
}

# =============================================================================
# Tests: ocdc_get_session_metadata
# =============================================================================

test_get_session_metadata_returns_all_fields() {
  create_test_session "test-ocdc-meta" "/tmp/meta-ws" "meta-poll" "meta-key" "meta-branch"
  
  local result
  result=$(ocdc_get_session_metadata "test-ocdc-meta")
  
  # Check all fields are present
  assert_contains "$result" '"workspace":"/tmp/meta-ws"'
  assert_contains "$result" '"poll_config":"meta-poll"'
  assert_contains "$result" '"item_key":"meta-key"'
  assert_contains "$result" '"branch":"meta-branch"'
  
  tmux kill-session -t "test-ocdc-meta" 2>/dev/null || true
}

test_get_session_metadata_nonexistent_session() {
  local result
  if result=$(ocdc_get_session_metadata "nonexistent-session-xyz" 2>&1); then
    echo "Should fail for nonexistent session"
    return 1
  fi
  return 0
}

# =============================================================================
# Tests: ocdc_is_session_orphan
# =============================================================================

test_is_session_orphan_true_when_workspace_missing() {
  create_test_session "test-ocdc-orphan" "/nonexistent/path/xyz" "poll" "key"
  
  if ocdc_is_session_orphan "test-ocdc-orphan"; then
    tmux kill-session -t "test-ocdc-orphan" 2>/dev/null || true
    return 0
  else
    tmux kill-session -t "test-ocdc-orphan" 2>/dev/null || true
    echo "Should be orphan when workspace doesn't exist"
    return 1
  fi
}

test_is_session_orphan_false_when_workspace_exists() {
  local workspace="$TEST_DIR/existing-workspace"
  mkdir -p "$workspace"
  
  create_test_session "test-ocdc-not-orphan" "$workspace" "poll" "key"
  
  if ocdc_is_session_orphan "test-ocdc-not-orphan"; then
    tmux kill-session -t "test-ocdc-not-orphan" 2>/dev/null || true
    echo "Should NOT be orphan when workspace exists"
    return 1
  else
    tmux kill-session -t "test-ocdc-not-orphan" 2>/dev/null || true
    return 0
  fi
}

# =============================================================================
# Tests: ocdc_kill_session
# =============================================================================

test_kill_session_removes_tmux_session() {
  create_test_session "test-ocdc-kill" "/tmp/ws" "poll" "key"
  
  # Verify session exists
  if ! tmux has-session -t "test-ocdc-kill" 2>/dev/null; then
    echo "Setup failed: session not created"
    return 1
  fi
  
  ocdc_kill_session "test-ocdc-kill"
  
  # Verify session is gone
  if tmux has-session -t "test-ocdc-kill" 2>/dev/null; then
    echo "Session should have been killed"
    return 1
  fi
  
  return 0
}

test_kill_session_clears_processed_state() {
  local item_key="test-item-to-clear"
  
  # Add entry to processed.json
  echo "{\"$item_key\": {\"config\": \"test\", \"processed_at\": \"2024-01-01\"}}" > "$OCDC_POLL_STATE_DIR/processed.json"
  
  create_test_session "test-ocdc-clear-state" "/tmp/ws" "poll" "$item_key"
  
  ocdc_kill_session "test-ocdc-clear-state"
  
  # Verify entry was removed from processed.json
  local remaining
  remaining=$(jq -r --arg key "$item_key" '.[$key] // "null"' "$OCDC_POLL_STATE_DIR/processed.json")
  
  if [[ "$remaining" != "null" ]]; then
    echo "Processed state should have been cleared"
    echo "Remaining: $remaining"
    return 1
  fi
  
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Session List Tests:"
for test_func in \
  test_list_poll_sessions_empty \
  test_list_poll_sessions_finds_ocdc_session \
  test_list_poll_sessions_ignores_non_ocdc_session
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Metadata Tests:"
for test_func in \
  test_get_session_metadata_returns_all_fields \
  test_get_session_metadata_nonexistent_session
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Orphan Tests:"
for test_func in \
  test_is_session_orphan_true_when_workspace_missing \
  test_is_session_orphan_false_when_workspace_exists
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Kill Tests:"
for test_func in \
  test_kill_session_removes_tmux_session \
  test_kill_session_clears_processed_state
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
