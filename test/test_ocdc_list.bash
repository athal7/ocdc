#!/usr/bin/env bash
#
# Integration tests for ocdc-list command
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing ocdc-list..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Tests
# =============================================================================

test_ocdc_list_shows_help() {
  local output=$("$BIN_DIR/ocdc" list --help 2>&1)
  assert_contains "$output" "ocdc-list"
}

test_ocdc_list_shows_empty_message() {
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  # Use --active to avoid picking up real sessions from the system
  local output=$("$BIN_DIR/ocdc" list --active 2>&1)
  assert_contains "$output" "No devcontainer instances"
}

test_ocdc_list_shows_registered_instance() {
  cat > "$TEST_CACHE_DIR/ports.json" << 'EOF'
{
  "/path/to/repo": {
    "port": 13000,
    "repo": "my-repo",
    "branch": "main",
    "started": "2024-01-01T00:00:00Z"
  }
}
EOF
  
  local output=$("$BIN_DIR/ocdc" list 2>&1)
  assert_contains "$output" "13000"
  assert_contains "$output" "my-repo"
  assert_contains "$output" "main"
}

test_ocdc_list_shows_multiple_instances() {
  cat > "$TEST_CACHE_DIR/ports.json" << 'EOF'
{
  "/path/to/repo1": {
    "port": 13000,
    "repo": "repo1",
    "branch": "main",
    "started": "2024-01-01T00:00:00Z"
  },
  "/path/to/repo2": {
    "port": 13001,
    "repo": "repo2",
    "branch": "feature",
    "started": "2024-01-01T00:00:00Z"
  }
}
EOF
  
  local output=$("$BIN_DIR/ocdc" list 2>&1)
  assert_contains "$output" "13000"
  assert_contains "$output" "13001"
  assert_contains "$output" "repo1"
  assert_contains "$output" "repo2"
}

# =============================================================================
# Session Tests
# =============================================================================

# Helper to create mock tmux session
create_test_session() {
  local session_name="$1"
  local workspace="${2:-/tmp/test-workspace}"
  local poll_config="${3:-test-poll}"
  local item_key="${4:-test-item-key}"
  
  tmux new-session -d -s "$session_name" \
    -e "OCDC_WORKSPACE=$workspace" \
    -e "OCDC_POLL_CONFIG=$poll_config" \
    -e "OCDC_ITEM_KEY=$item_key" \
    -e "OCDC_BRANCH=test-branch" \
    "sleep 3600" 2>/dev/null || true
}

cleanup_test_sessions() {
  for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-ocdc-' || true); do
    tmux kill-session -t "$session" 2>/dev/null || true
  done
}

test_ocdc_list_shows_sessions() {
  cleanup_test_sessions
  
  # Create a workspace for the session
  local workspace="$TEST_CLONES_DIR/my-repo/session-branch"
  mkdir -p "$workspace"
  
  # Create a session
  create_test_session "test-ocdc-list-sess" "$workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  local output=$("$BIN_DIR/ocdc" list 2>&1)
  
  # Should show SESSION status
  assert_contains "$output" "SESSION"
  assert_contains "$output" "test-ocdc-list-sess"
  
  cleanup_test_sessions
}

test_ocdc_list_shows_orphaned_session() {
  cleanup_test_sessions
  
  # Create a session with non-existent workspace
  create_test_session "test-ocdc-orphan-list" "/nonexistent/workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  local output=$("$BIN_DIR/ocdc" list 2>&1)
  
  # Should show as orphan session
  assert_contains "$output" "test-ocdc-orphan-list"
  
  cleanup_test_sessions
}

test_ocdc_list_json_includes_sessions() {
  cleanup_test_sessions
  
  # Create a workspace for the session
  local workspace="$TEST_CLONES_DIR/my-repo/json-branch"
  mkdir -p "$workspace"
  
  create_test_session "test-ocdc-json-sess" "$workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  local output=$("$BIN_DIR/ocdc" list --json 2>&1)
  
  # Should be valid JSON with session
  if ! echo "$output" | jq -e '.[] | select(.type == "session")' >/dev/null 2>&1; then
    cleanup_test_sessions
    echo "JSON output should include session type"
    echo "Got: $output"
    return 1
  fi
  
  cleanup_test_sessions
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Command Usage Tests:"

for test_func in \
  test_ocdc_list_shows_help \
  test_ocdc_list_shows_empty_message \
  test_ocdc_list_shows_registered_instance \
  test_ocdc_list_shows_multiple_instances
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Tests:"

for test_func in \
  test_ocdc_list_shows_sessions \
  test_ocdc_list_shows_orphaned_session \
  test_ocdc_list_json_includes_sessions
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
