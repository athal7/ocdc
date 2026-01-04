#!/usr/bin/env bash
#
# Tests for poll error handling and retry logic
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing poll error handling..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create state directory
  export OCDC_POLL_STATE_DIR="$TEST_CACHE_DIR/poll"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  echo '{}' > "$OCDC_POLL_STATE_DIR/processed.json"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Error Type Constants Tests
# =============================================================================

test_error_types_defined() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # All error types should be defined
  [[ -n "$ERR_RATE_LIMITED" ]] || { echo "ERR_RATE_LIMITED not defined"; return 1; }
  [[ -n "$ERR_AUTH_FAILED" ]] || { echo "ERR_AUTH_FAILED not defined"; return 1; }
  [[ -n "$ERR_NETWORK_TIMEOUT" ]] || { echo "ERR_NETWORK_TIMEOUT not defined"; return 1; }
  [[ -n "$ERR_REPO_NOT_FOUND" ]] || { echo "ERR_REPO_NOT_FOUND not defined"; return 1; }
  [[ -n "$ERR_CLONE_FAILED" ]] || { echo "ERR_CLONE_FAILED not defined"; return 1; }
  [[ -n "$ERR_DEVCONTAINER_FAILED" ]] || { echo "ERR_DEVCONTAINER_FAILED not defined"; return 1; }
  return 0
}

test_error_types_unique() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # All error types should be unique strings
  local types=("$ERR_RATE_LIMITED" "$ERR_AUTH_FAILED" "$ERR_NETWORK_TIMEOUT" "$ERR_REPO_NOT_FOUND" "$ERR_CLONE_FAILED" "$ERR_DEVCONTAINER_FAILED")
  local unique_count
  unique_count=$(printf '%s\n' "${types[@]}" | sort -u | wc -l | tr -d ' ')
  
  if [[ "$unique_count" != "6" ]]; then
    echo "Error types are not unique (got $unique_count unique, expected 6)"
    return 1
  fi
  return 0
}

# =============================================================================
# Retry Policy Tests
# =============================================================================

test_error_is_retryable_rate_limited() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if ! poll_error_is_retryable "$ERR_RATE_LIMITED"; then
    echo "Rate limited errors should be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_auth_failed() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if poll_error_is_retryable "$ERR_AUTH_FAILED"; then
    echo "Auth failed errors should NOT be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_network_timeout() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if ! poll_error_is_retryable "$ERR_NETWORK_TIMEOUT"; then
    echo "Network timeout errors should be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_repo_not_found() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if poll_error_is_retryable "$ERR_REPO_NOT_FOUND"; then
    echo "Repo not found errors should NOT be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_clone_failed() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if ! poll_error_is_retryable "$ERR_CLONE_FAILED"; then
    echo "Clone failed errors should be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_devcontainer_failed() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  if ! poll_error_is_retryable "$ERR_DEVCONTAINER_FAILED"; then
    echo "Devcontainer failed errors should be retryable"
    return 1
  fi
  return 0
}

test_error_is_retryable_unknown() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # Unknown error types should NOT be retryable (fail safe)
  if poll_error_is_retryable "unknown_error_type"; then
    echo "Unknown errors should NOT be retryable"
    return 1
  fi
  return 0
}

test_max_attempts_unknown() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local max
  max=$(poll_error_max_attempts "unknown_error_type")
  # Unknown errors return 0 (no retries)
  assert_equals "0" "$max"
}

# =============================================================================
# Max Attempts Tests
# =============================================================================

test_max_attempts_rate_limited() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # Rate limited should retry indefinitely (next poll cycle)
  local max
  max=$(poll_error_max_attempts "$ERR_RATE_LIMITED")
  # 0 means unlimited/poll-cycle retry
  assert_equals "0" "$max"
}

test_max_attempts_clone_failed() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local max
  max=$(poll_error_max_attempts "$ERR_CLONE_FAILED")
  assert_equals "3" "$max"
}

test_max_attempts_devcontainer_failed() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local max
  max=$(poll_error_max_attempts "$ERR_DEVCONTAINER_FAILED")
  assert_equals "3" "$max"
}

# =============================================================================
# Backoff Calculation Tests
# =============================================================================

test_backoff_first_attempt() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # First attempt: base delay is 60 seconds (1 minute)
  local backoff
  backoff=$(poll_error_calculate_backoff 1)
  
  # Should be around 60 seconds +/- 20% jitter (48-72)
  if [[ $backoff -lt 48 ]] || [[ $backoff -gt 72 ]]; then
    echo "First attempt backoff should be 60 +/- 20% (got $backoff)"
    return 1
  fi
  return 0
}

test_backoff_second_attempt() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # Second attempt: 2^1 * 60 = 120 seconds
  local backoff
  backoff=$(poll_error_calculate_backoff 2)
  
  # Should be around 120 seconds +/- 20% jitter (96-144)
  if [[ $backoff -lt 96 ]] || [[ $backoff -gt 144 ]]; then
    echo "Second attempt backoff should be 120 +/- 20% (got $backoff)"
    return 1
  fi
  return 0
}

test_backoff_third_attempt() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # Third attempt: 2^2 * 60 = 240 seconds
  local backoff
  backoff=$(poll_error_calculate_backoff 3)
  
  # Should be around 240 seconds +/- 20% jitter (192-288)
  if [[ $backoff -lt 192 ]] || [[ $backoff -gt 288 ]]; then
    echo "Third attempt backoff should be 240 +/- 20% (got $backoff)"
    return 1
  fi
  return 0
}

test_backoff_capped_at_one_hour() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  # Very high attempt number should be capped at 1 hour (3600)
  local backoff
  backoff=$(poll_error_calculate_backoff 100)
  
  # Should be at most 3600 + 20% = 4320
  if [[ $backoff -gt 4320 ]]; then
    echo "Backoff should be capped at ~1 hour (got $backoff)"
    return 1
  fi
  # Should be at least 3600 - 20% = 2880
  if [[ $backoff -lt 2880 ]]; then
    echo "Backoff for high attempt should be near max (got $backoff)"
    return 1
  fi
  return 0
}

# =============================================================================
# Error State Management Tests
# =============================================================================

test_mark_item_error() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="test-repo-issue-42"
  local config_id="test-config"
  
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed"
  
  # Check state file
  local state
  state=$(jq -r --arg key "$key" '.[$key].state' "$OCDC_POLL_STATE_DIR/processed.json")
  
  assert_equals "error" "$state"
}

test_mark_item_error_tracks_attempts() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="test-repo-issue-43"
  local config_id="test-config"
  
  # First error
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed"
  
  local attempts
  attempts=$(jq -r --arg key "$key" '.[$key].error.attempts' "$OCDC_POLL_STATE_DIR/processed.json")
  
  assert_equals "1" "$attempts"
  
  # Second error
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed again"
  
  attempts=$(jq -r --arg key "$key" '.[$key].error.attempts' "$OCDC_POLL_STATE_DIR/processed.json")
  
  assert_equals "2" "$attempts"
}

test_mark_item_error_sets_next_retry() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="test-repo-issue-44"
  local config_id="test-config"
  
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed"
  
  local next_retry
  next_retry=$(jq -r --arg key "$key" '.[$key].error.next_retry' "$OCDC_POLL_STATE_DIR/processed.json")
  
  if [[ "$next_retry" == "null" ]] || [[ -z "$next_retry" ]]; then
    echo "next_retry should be set"
    return 1
  fi
  return 0
}

test_mark_item_error_type() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="test-repo-issue-45"
  local config_id="test-config"
  
  poll_error_mark_item "$key" "$config_id" "$ERR_DEVCONTAINER_FAILED" "npm install failed"
  
  local error_type
  error_type=$(jq -r --arg key "$key" '.[$key].error.type' "$OCDC_POLL_STATE_DIR/processed.json")
  
  assert_equals "$ERR_DEVCONTAINER_FAILED" "$error_type"
}

test_mark_item_error_message() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="test-repo-issue-46"
  local config_id="test-config"
  
  poll_error_mark_item "$key" "$config_id" "$ERR_DEVCONTAINER_FAILED" "npm install failed"
  
  local message
  message=$(jq -r --arg key "$key" '.[$key].error.message' "$OCDC_POLL_STATE_DIR/processed.json")
  
  assert_equals "npm install failed" "$message"
}

# =============================================================================
# Should Retry Tests
# =============================================================================

test_should_retry_not_errored() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="never-seen"
  
  # Item not in state - should process (not retry, since never seen)
  if poll_error_should_retry "$key"; then
    echo "Never-seen item should not be a 'retry'"
    return 1
  fi
  return 0
}

test_should_retry_successful() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="successful-item"
  
  # Mark as successfully processed
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" \
    '.[$key] = {state: "processed", config: "test", processed_at: "2025-01-01T00:00:00Z"}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should NOT retry successful items
  if poll_error_should_retry "$key"; then
    echo "Successfully processed item should not be retried"
    return 1
  fi
  return 0
}

test_should_retry_max_exceeded() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="max-exceeded-item"
  
  # Mark with max attempts exceeded
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg type "$ERR_CLONE_FAILED" \
    '.[$key] = {state: "error", config: "test", error: {type: $type, attempts: 3, max_attempts: 3, next_retry: "2025-01-01T00:00:00Z"}}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should NOT retry when max attempts reached
  if poll_error_should_retry "$key"; then
    echo "Item at max attempts should not be retried"
    return 1
  fi
  return 0
}

test_should_retry_before_time() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="too-soon-item"
  
  # Mark with next_retry in the future
  local future_time
  future_time=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ")
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg type "$ERR_CLONE_FAILED" --arg next "$future_time" \
    '.[$key] = {state: "error", config: "test", error: {type: $type, attempts: 1, max_attempts: 3, next_retry: $next}}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should NOT retry before next_retry time
  if poll_error_should_retry "$key"; then
    echo "Item should not retry before next_retry time"
    return 1
  fi
  return 0
}

test_should_retry_after_time() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="ready-to-retry-item"
  
  # Mark with next_retry in the past
  local past_time
  past_time=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-1 hour" +"%Y-%m-%dT%H:%M:%SZ")
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg type "$ERR_CLONE_FAILED" --arg next "$past_time" \
    '.[$key] = {state: "error", config: "test", error: {type: $type, attempts: 1, max_attempts: 3, next_retry: $next}}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should retry after next_retry time
  if ! poll_error_should_retry "$key"; then
    echo "Item should retry after next_retry time"
    return 1
  fi
  return 0
}

# =============================================================================
# Should Skip Tests
# =============================================================================

test_should_skip_not_retryable_error() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="auth-failed-item"
  
  # Mark with non-retryable error
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg type "$ERR_AUTH_FAILED" \
    '.[$key] = {state: "error", config: "test", error: {type: $type, attempts: 1, message: "Bad credentials"}}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should skip permanently non-retryable errors
  if ! poll_error_should_skip "$key"; then
    echo "Non-retryable error item should be skipped"
    return 1
  fi
  return 0
}

test_should_skip_repo_not_found() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="missing-repo-item"
  
  # Mark with repo not found error
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg type "$ERR_REPO_NOT_FOUND" \
    '.[$key] = {state: "error", config: "test", error: {type: $type, attempts: 1, message: "Repository not found"}}' \
    "$OCDC_POLL_STATE_DIR/processed.json" > "$tmp"
  mv "$tmp" "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Should skip permanently
  if ! poll_error_should_skip "$key"; then
    echo "Repo not found item should be skipped"
    return 1
  fi
  return 0
}

# =============================================================================
# Clear Error State Tests
# =============================================================================

test_clear_error_state() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="clearing-error-item"
  local config_id="test-config"
  
  # First set an error
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed"
  
  local state
  state=$(jq -r --arg key "$key" '.[$key].state' "$OCDC_POLL_STATE_DIR/processed.json")
  assert_equals "error" "$state"
  
  # Clear it
  poll_error_clear_item "$key"
  
  # Should no longer exist in state
  local exists
  exists=$(jq -e --arg key "$key" 'has($key)' "$OCDC_POLL_STATE_DIR/processed.json")
  
  if [[ "$exists" == "true" ]]; then
    echo "Item should be removed from state after clearing"
    return 1
  fi
  return 0
}

# =============================================================================
# Get Error Info Tests
# =============================================================================

test_get_error_info() {
  source "$LIB_DIR/ocdc-poll-errors.bash"
  
  local key="error-info-item"
  local config_id="test-config"
  
  poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "git clone failed"
  
  local info
  info=$(poll_error_get_info "$key")
  
  local type attempts message
  type=$(echo "$info" | jq -r '.type')
  attempts=$(echo "$info" | jq -r '.attempts')
  message=$(echo "$info" | jq -r '.message')
  
  assert_equals "$ERR_CLONE_FAILED" "$type"
  assert_equals "1" "$attempts"
  assert_equals "git clone failed" "$message"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Poll Error Handling Tests:"

for test_func in \
  test_error_types_defined \
  test_error_types_unique \
  test_error_is_retryable_rate_limited \
  test_error_is_retryable_auth_failed \
  test_error_is_retryable_network_timeout \
  test_error_is_retryable_repo_not_found \
  test_error_is_retryable_clone_failed \
  test_error_is_retryable_devcontainer_failed \
  test_error_is_retryable_unknown \
  test_max_attempts_rate_limited \
  test_max_attempts_clone_failed \
  test_max_attempts_devcontainer_failed \
  test_max_attempts_unknown \
  test_backoff_first_attempt \
  test_backoff_second_attempt \
  test_backoff_third_attempt \
  test_backoff_capped_at_one_hour \
  test_mark_item_error \
  test_mark_item_error_tracks_attempts \
  test_mark_item_error_sets_next_retry \
  test_mark_item_error_type \
  test_mark_item_error_message \
  test_should_retry_not_errored \
  test_should_retry_successful \
  test_should_retry_max_exceeded \
  test_should_retry_before_time \
  test_should_retry_after_time \
  test_should_skip_not_retryable_error \
  test_should_skip_repo_not_found \
  test_clear_error_state \
  test_get_error_info
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
