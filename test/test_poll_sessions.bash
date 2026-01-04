#!/usr/bin/env bash
#
# Tests for poll session management commands
#
# Tests for:
#   ocdc poll sessions - List active poll sessions
#   ocdc poll attach   - Attach to a session
#   ocdc poll logs     - View poll logs
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing poll session management..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create polls directory and state directory
  export OCDC_POLLS_DIR="$TEST_CONFIG_DIR/polls"
  export OCDC_POLL_STATE_DIR="$TEST_DATA_DIR/poll-state"
  export OCDC_POLL_LOG_DIR="$TEST_DATA_DIR/logs"
  export OCDC_POLL_LOG_FILE="$OCDC_POLL_LOG_DIR/poll.log"
  mkdir -p "$OCDC_POLLS_DIR" "$OCDC_POLL_STATE_DIR" "$OCDC_POLL_LOG_DIR"
  
  # Source the poll script functions
  source "$LIB_DIR/ocdc-paths.bash"
  source "$LIB_DIR/ocdc-poll-config.bash"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Helper Functions for Tests
# =============================================================================

# Create a mock tmux session with OCDC environment variables
create_mock_session() {
  local session_name="$1"
  local poll_config="${2:-test-poll}"
  local item_key="${3:-test/repo-issue-42}"
  local workspace="${4:-/tmp/test-workspace}"
  
  # Create a simple tmux session
  tmux new-session -d -s "$session_name" -c "/tmp" \
    -e "OCDC_POLL_CONFIG=$poll_config" \
    -e "OCDC_ITEM_KEY=$item_key" \
    -e "OCDC_WORKSPACE=$workspace" \
    -e "OCDC_BRANCH=test-branch" \
    "sleep 3600" 2>/dev/null || true
}

# Clean up test tmux sessions
cleanup_mock_sessions() {
  for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-ocdc-' || true); do
    tmux kill-session -t "$session" 2>/dev/null || true
  done
}

# =============================================================================
# Tests: format_age function
# =============================================================================

test_format_age_seconds() {
  source "$LIB_DIR/ocdc-poll"
  
  local result
  result=$(format_age 45)
  assert_equals "45s" "$result"
}

test_format_age_minutes() {
  source "$LIB_DIR/ocdc-poll"
  
  local result
  result=$(format_age 300)
  assert_equals "5m" "$result"
}

test_format_age_hours() {
  source "$LIB_DIR/ocdc-poll"
  
  local result
  result=$(format_age 7200)
  assert_equals "2h" "$result"
}

test_format_age_days() {
  source "$LIB_DIR/ocdc-poll"
  
  local result
  result=$(format_age 172800)
  assert_equals "2d" "$result"
}

# =============================================================================
# Tests: ocdc poll sessions
# =============================================================================

test_poll_sessions_help() {
  local output
  output=$("$BIN_DIR/ocdc" poll sessions --help 2>&1)
  assert_contains "$output" "Usage:"
  assert_contains "$output" "sessions"
}

test_poll_sessions_header_always_shown() {
  # The header row should always be shown (even if sessions exist)
  # This test is more reliable than checking for "No active poll sessions"
  # since real sessions may exist on the system
  cleanup_mock_sessions
  
  local output
  output=$("$BIN_DIR/ocdc" poll sessions 2>&1)
  # Should always show the header row
  assert_contains "$output" "SESSION"
  assert_contains "$output" "POLL"
  assert_contains "$output" "ITEM"
  assert_contains "$output" "AGE"
}

test_poll_sessions_lists_session() {
  cleanup_mock_sessions
  create_mock_session "test-ocdc-issue-42" "github-issues" "myorg/repo-issue-42"
  
  local output
  output=$("$BIN_DIR/ocdc" poll sessions 2>&1)
  
  # Should contain session name
  assert_contains "$output" "test-ocdc-issue-42"
  # Should contain poll config
  assert_contains "$output" "github-issues"
  # Should contain item key
  assert_contains "$output" "myorg/repo-issue-42"
  
  cleanup_mock_sessions
}

test_poll_sessions_ignores_non_poll_sessions() {
  cleanup_mock_sessions
  
  # Create a regular tmux session (no OCDC_POLL_CONFIG)
  tmux new-session -d -s "test-ocdc-regular" "sleep 3600" 2>/dev/null || true
  
  local output
  output=$("$BIN_DIR/ocdc" poll sessions 2>&1)
  
  # Should not list the regular session (it has no OCDC_POLL_CONFIG)
  if [[ "$output" == *"test-ocdc-regular"* ]]; then
    tmux kill-session -t "test-ocdc-regular" 2>/dev/null || true
    echo "Should not list sessions without OCDC_POLL_CONFIG"
    return 1
  fi
  
  tmux kill-session -t "test-ocdc-regular" 2>/dev/null || true
  return 0
}

# test_poll_sessions_shows_header is combined with test_poll_sessions_header_always_shown

# =============================================================================
# Tests: ocdc poll attach
# =============================================================================

test_poll_attach_help() {
  local output
  output=$("$BIN_DIR/ocdc" poll attach --help 2>&1)
  assert_contains "$output" "Usage:"
  assert_contains "$output" "attach"
  assert_contains "$output" "pattern"
}

test_poll_attach_no_args_shows_error() {
  local output
  if output=$("$BIN_DIR/ocdc" poll attach 2>&1); then
    echo "Should fail without arguments"
    return 1
  fi
  assert_contains "$output" "Usage:"
}

test_poll_attach_no_match_shows_error() {
  cleanup_mock_sessions
  
  local output
  if output=$("$BIN_DIR/ocdc" poll attach "nonexistent-pattern" 2>&1); then
    echo "Should fail when no sessions match"
    return 1
  fi
  assert_contains "$output" "No sessions matching"
}

test_poll_attach_multiple_matches_non_interactive() {
  cleanup_mock_sessions
  create_mock_session "test-ocdc-api-1" "github-issues" "myorg/api-issue-1"
  create_mock_session "test-ocdc-api-2" "github-issues" "myorg/api-issue-2"
  
  # Pipe empty input to simulate non-interactive mode
  local output
  if output=$(echo "" | "$BIN_DIR/ocdc" poll attach "api" 2>&1); then
    cleanup_mock_sessions
    echo "Should fail in non-interactive mode with multiple matches"
    return 1
  fi
  
  cleanup_mock_sessions
  assert_contains "$output" "Multiple matches"
}

# =============================================================================
# Tests: ocdc poll logs
# =============================================================================

test_poll_logs_help() {
  local output
  output=$("$BIN_DIR/ocdc" poll logs --help 2>&1)
  assert_contains "$output" "Usage:"
  assert_contains "$output" "logs"
  assert_contains "$output" "--follow"
  assert_contains "$output" "--poll"
}

test_poll_logs_no_file_shows_warning() {
  # Ensure log file doesn't exist
  rm -f "$OCDC_POLL_LOG_FILE"
  
  local output
  output=$("$BIN_DIR/ocdc" poll logs 2>&1)
  assert_contains "$output" "No log file"
}

test_poll_logs_shows_recent_logs() {
  # Create test log file
  mkdir -p "$OCDC_POLL_LOG_DIR"
  cat > "$OCDC_POLL_LOG_FILE" << 'EOF'
2024-01-15T10:00:00Z [github-issues] Processing poll: github-issues
2024-01-15T10:00:01Z [github-issues] Found 2 items
2024-01-15T10:00:02Z [github-reviews] Processing poll: github-reviews
EOF
  
  local output
  output=$("$BIN_DIR/ocdc" poll logs 2>&1)
  
  assert_contains "$output" "github-issues"
  assert_contains "$output" "Found 2 items"
}

test_poll_logs_filter_by_poll() {
  # Create test log file with mixed poll entries
  mkdir -p "$OCDC_POLL_LOG_DIR"
  cat > "$OCDC_POLL_LOG_FILE" << 'EOF'
2024-01-15T10:00:00Z [github-issues] Processing poll: github-issues
2024-01-15T10:00:01Z [github-reviews] Processing poll: github-reviews
2024-01-15T10:00:02Z [github-issues] New item found
EOF
  
  local output
  output=$("$BIN_DIR/ocdc" poll logs --poll github-issues 2>&1)
  
  # Should contain github-issues entries
  assert_contains "$output" "github-issues"
  # Should NOT contain github-reviews entries
  if [[ "$output" == *"github-reviews"* ]]; then
    echo "Should filter out other polls"
    return 1
  fi
  return 0
}

# =============================================================================
# Tests: --max-concurrent option
# =============================================================================

test_poll_help_shows_max_concurrent() {
  local output
  output=$("$BIN_DIR/ocdc" poll --help 2>&1)
  assert_contains "$output" "--max-concurrent"
}

test_poll_max_concurrent_accepts_value() {
  # Should not error with valid --max-concurrent value
  local output
  output=$("$BIN_DIR/ocdc" poll --dry-run --max-concurrent 3 2>&1)
  # Should complete without "Unknown option" error
  if [[ "$output" == *"Unknown option"* ]]; then
    echo "Should accept --max-concurrent option"
    return 1
  fi
  return 0
}

test_poll_max_concurrent_rejects_invalid() {
  # Should error with non-numeric value
  local output
  if output=$("$BIN_DIR/ocdc" poll --dry-run --max-concurrent invalid 2>&1); then
    echo "Should reject non-numeric --max-concurrent"
    return 1
  fi
  assert_contains "$output" "must be a positive integer"
}

test_poll_max_concurrent_rejects_zero() {
  # Should error with zero value
  local output
  if output=$("$BIN_DIR/ocdc" poll --dry-run --max-concurrent 0 2>&1); then
    echo "Should reject --max-concurrent 0"
    return 1
  fi
  assert_contains "$output" "must be a positive integer"
}

# =============================================================================
# Tests: Log rotation
# =============================================================================

test_log_rotation_keeps_recent_lines() {
  source "$LIB_DIR/ocdc-poll"
  
  mkdir -p "$OCDC_POLL_LOG_DIR"
  
  # Create a log file with more than max_lines
  # Using a smaller number for testing
  local test_log="$OCDC_POLL_LOG_DIR/test-rotation.log"
  for i in $(seq 1 150); do
    echo "Line $i" >> "$test_log"
  done
  
  # Verify we have 150 lines
  local before_count
  before_count=$(wc -l < "$test_log")
  if [[ $before_count -ne 150 ]]; then
    echo "Expected 150 lines, got $before_count"
    return 1
  fi
  
  # Call rotation with small limits for testing
  rotate_log_if_needed "$test_log" 100 50
  
  # Should now have 50 lines
  local after_count
  after_count=$(wc -l < "$test_log")
  if [[ $after_count -ne 50 ]]; then
    echo "Expected 50 lines after rotation, got $after_count"
    return 1
  fi
  
  # Should keep the most recent lines (last line should be "Line 150")
  local last_line
  last_line=$(tail -1 "$test_log")
  assert_equals "Line 150" "$last_line"
}

test_log_rotation_no_action_under_limit() {
  source "$LIB_DIR/ocdc-poll"
  
  mkdir -p "$OCDC_POLL_LOG_DIR"
  
  local test_log="$OCDC_POLL_LOG_DIR/test-no-rotation.log"
  for i in $(seq 1 50); do
    echo "Line $i" >> "$test_log"
  done
  
  rotate_log_if_needed "$test_log" 100 50
  
  # Should still have 50 lines (no rotation needed)
  local count
  count=$(wc -l < "$test_log" | tr -d ' ')
  assert_equals "50" "$count"
}

# =============================================================================
# Tests: Subcommand routing
# =============================================================================

test_poll_subcommand_sessions_routes() {
  local output
  output=$("$BIN_DIR/ocdc" poll sessions --help 2>&1)
  # Should route to sessions subcommand, not show main poll help
  if [[ "$output" == *"--daemon"* ]]; then
    echo "Should route to sessions, not main poll"
    return 1
  fi
  assert_contains "$output" "sessions"
}

test_poll_subcommand_attach_routes() {
  local output
  output=$("$BIN_DIR/ocdc" poll attach --help 2>&1)
  if [[ "$output" == *"--daemon"* ]]; then
    echo "Should route to attach, not main poll"
    return 1
  fi
  assert_contains "$output" "attach"
}

test_poll_subcommand_logs_routes() {
  local output
  output=$("$BIN_DIR/ocdc" poll logs --help 2>&1)
  if [[ "$output" == *"--daemon"* ]]; then
    echo "Should route to logs, not main poll"
    return 1
  fi
  assert_contains "$output" "logs"
}

test_poll_existing_commands_still_work() {
  local output
  output=$("$BIN_DIR/ocdc" poll --help 2>&1)
  # Main poll help should still work
  assert_contains "$output" "--daemon"
  assert_contains "$output" "--dry-run"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Poll Session Management Tests:"

# Run format_age tests first (unit tests)
for test_func in \
  test_format_age_seconds \
  test_format_age_minutes \
  test_format_age_hours \
  test_format_age_days
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Subcommand Routing Tests:"

for test_func in \
  test_poll_subcommand_sessions_routes \
  test_poll_subcommand_attach_routes \
  test_poll_subcommand_logs_routes \
  test_poll_existing_commands_still_work
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Poll Sessions Command Tests:"

for test_func in \
  test_poll_sessions_help \
  test_poll_sessions_header_always_shown \
  test_poll_sessions_lists_session \
  test_poll_sessions_ignores_non_poll_sessions
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Poll Attach Command Tests:"

for test_func in \
  test_poll_attach_help \
  test_poll_attach_no_args_shows_error \
  test_poll_attach_no_match_shows_error \
  test_poll_attach_multiple_matches_non_interactive
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Poll Logs Command Tests:"

for test_func in \
  test_poll_logs_help \
  test_poll_logs_no_file_shows_warning \
  test_poll_logs_shows_recent_logs \
  test_poll_logs_filter_by_poll
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Max Concurrent Option Tests:"

for test_func in \
  test_poll_help_shows_max_concurrent \
  test_poll_max_concurrent_accepts_value \
  test_poll_max_concurrent_rejects_invalid \
  test_poll_max_concurrent_rejects_zero
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Log Rotation Tests:"

for test_func in \
  test_log_rotation_keeps_recent_lines \
  test_log_rotation_no_action_under_limit
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
