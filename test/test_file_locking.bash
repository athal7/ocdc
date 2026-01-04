#!/usr/bin/env bash
#
# Tests for file locking functions (mkdir-based, cross-platform)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing file locking..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  source "$LIB_DIR/ocdc-file-lock.bash"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Tests for lock_file
# =============================================================================

test_lock_file_creates_lock_directory() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/test.lock"
  
  lock_file "$lockfile"
  
  if [[ ! -d "$lockfile" ]]; then
    echo "lock_file should create lock directory"
    return 1
  fi
  
  # Cleanup
  unlock_file "$lockfile"
  return 0
}

test_lock_file_blocks_second_lock() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/test.lock"
  
  # Acquire first lock
  lock_file "$lockfile"
  
  # Try to acquire second lock in background with timeout
  local got_lock=false
  (
    # Use timeout with a very short duration
    timeout 0.3 bash -c "source '$LIB_DIR/ocdc-file-lock.bash' && lock_file '$lockfile'" 2>/dev/null && got_lock=true
  ) &
  local bg_pid=$!
  
  # Wait a bit and check
  sleep 0.5
  
  # The background process should have timed out (not acquired lock)
  if wait "$bg_pid" 2>/dev/null; then
    echo "Second lock attempt should have timed out"
    unlock_file "$lockfile"
    return 1
  fi
  
  # Cleanup
  unlock_file "$lockfile"
  return 0
}

test_lock_file_recovers_from_stale_file_lock() {
  # Regression test for stale file locks (not directories) left by legacy code
  # This was the root cause of poll blocking for days - a file at the lock path
  # would cause mkdir to fail, but -d test would also fail, resulting in infinite loop
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/stale-file.lock"
  
  # Create a stale lock FILE (not directory) - simulates legacy locking or corruption
  touch "$lockfile"
  
  # Set mtime to 120 seconds ago
  local old_time
  old_time=$(date -v-120S +%Y%m%d%H%M 2>/dev/null || date -d '120 seconds ago' +%Y%m%d%H%M 2>/dev/null)
  touch -t "$old_time" "$lockfile" 2>/dev/null || touch -d '120 seconds ago' "$lockfile" 2>/dev/null
  
  # Try to acquire the lock - should succeed by removing stale file
  local result_file="$TEST_DIR/lock_result"
  (
    source "$LIB_DIR/ocdc-file-lock.bash"
    lock_file "$lockfile" 1  # 1-second max_age for faster test
    echo "acquired" > "$result_file"
  ) &
  local bg_pid=$!
  
  # Wait up to 2 seconds for lock acquisition
  local waited=0
  while [[ $waited -lt 20 ]] && ! [[ -f "$result_file" ]]; do
    sleep 0.1
    ((waited++)) || true
  done
  
  # Kill background process if still running
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  
  if [[ ! -f "$result_file" ]] || [[ "$(cat "$result_file" 2>/dev/null)" != "acquired" ]]; then
    echo "lock_file should recover from stale FILE lock (not just directory)"
    rm -f "$lockfile" 2>/dev/null || true
    return 1
  fi
  
  # Cleanup
  rmdir "$lockfile" 2>/dev/null || rm -f "$lockfile" 2>/dev/null || true
  return 0
}

test_lock_file_recovers_from_stale_lock() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/stale.lock"
  
  # Create a stale lock directory manually
  mkdir -p "$lockfile"
  
  # Set mtime to 120 seconds ago (older than 60-second default max_age)
  # macOS uses -t with YYYYMMDDhhmm format, Linux uses -d
  local old_time
  old_time=$(date -v-120S +%Y%m%d%H%M 2>/dev/null || date -d '120 seconds ago' +%Y%m%d%H%M 2>/dev/null)
  touch -t "$old_time" "$lockfile" 2>/dev/null || touch -d '120 seconds ago' "$lockfile" 2>/dev/null
  
  # Try to acquire the lock - should succeed quickly because lock is stale
  # Use a short max_age (1 second) to speed up the test
  local result_file="$TEST_DIR/lock_result"
  (
    source "$LIB_DIR/ocdc-file-lock.bash"
    lock_file "$lockfile" 1  # 1-second max_age for faster test
    echo "acquired" > "$result_file"
  ) &
  local bg_pid=$!
  
  # Wait up to 2 seconds for lock acquisition
  local waited=0
  while [[ $waited -lt 20 ]] && ! [[ -f "$result_file" ]]; do
    sleep 0.1
    ((waited++)) || true
  done
  
  # Kill background process if still running
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  
  if [[ ! -f "$result_file" ]] || [[ "$(cat "$result_file" 2>/dev/null)" != "acquired" ]]; then
    echo "lock_file should recover from stale lock (older than max_age)"
    rmdir "$lockfile" 2>/dev/null || true
    return 1
  fi
  
  # Cleanup
  rmdir "$lockfile" 2>/dev/null || true
  return 0
}

# =============================================================================
# Tests for unlock_file
# =============================================================================

test_unlock_file_removes_lock_directory() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/test.lock"
  
  lock_file "$lockfile"
  unlock_file "$lockfile"
  
  if [[ -d "$lockfile" ]]; then
    echo "unlock_file should remove lock directory"
    return 1
  fi
  return 0
}

test_unlock_file_succeeds_when_not_locked() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  local lockfile="$TEST_DIR/nonexistent.lock"
  
  # Should not fail even if lock doesn't exist
  if ! unlock_file "$lockfile"; then
    echo "unlock_file should succeed even when lock doesn't exist"
    return 1
  fi
  return 0
}

# =============================================================================
# Tests for mark_processed with new locking
# =============================================================================

# Define mark_processed for testing (same as in ocdc-poll but using file-lock)
_test_mark_processed() {
  local key="$1"
  local config_id="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  lock_file "${STATE_FILE}.lock"
  # Ensure lock is released even if jq/mv fails
  trap 'unlock_file "${STATE_FILE}.lock"' EXIT
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" --arg config "$config_id" --arg ts "$timestamp" \
    '.[$key] = {config: $config, processed_at: $ts}' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  
  trap - EXIT
  unlock_file "${STATE_FILE}.lock"
}

test_mark_processed_creates_state_entry() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  # Setup state file
  export STATE_FILE="$TEST_DIR/processed.json"
  echo '{}' > "$STATE_FILE"
  
  _test_mark_processed "test-key-1" "test-config"
  
  local result
  result=$(jq -r '.["test-key-1"].config' "$STATE_FILE")
  assert_equals "test-config" "$result"
}

test_mark_processed_does_not_use_flock() {
  # Verify that locking works without flock command
  # This is the core of issue #33
  
  # Create a PATH that doesn't include flock
  local temp_path="$TEST_DIR/bin"
  mkdir -p "$temp_path"
  # Create wrapper scripts for required commands only
  for cmd in jq mktemp mv date mkdir rmdir sleep; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null || echo "")
    if [[ -n "$cmd_path" ]]; then
      ln -sf "$cmd_path" "$temp_path/$cmd"
    fi
  done
  
  # Use only our temp path - flock won't be available
  local OLD_PATH="$PATH"
  export PATH="$temp_path"
  
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  export STATE_FILE="$TEST_DIR/processed.json"
  echo '{}' > "$STATE_FILE"
  
  # This should work without flock
  if ! _test_mark_processed "test-key-2" "test-config" 2>&1; then
    export PATH="$OLD_PATH"
    echo "mark_processed should work without flock command"
    return 1
  fi
  
  export PATH="$OLD_PATH"
  return 0
}

test_mark_processed_no_lock_file_left_behind() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  export STATE_FILE="$TEST_DIR/processed.json"
  echo '{}' > "$STATE_FILE"
  
  _test_mark_processed "test-key-3" "test-config"
  
  # Lock directory should be cleaned up
  if [[ -d "${STATE_FILE}.lock" ]]; then
    echo "Lock directory should be removed after mark_processed completes"
    return 1
  fi
  return 0
}

test_mark_processed_releases_lock_on_error() {
  source "$LIB_DIR/ocdc-file-lock.bash"
  
  export STATE_FILE="$TEST_DIR/processed.json"
  # Create invalid JSON to make jq fail
  echo 'not valid json' > "$STATE_FILE"
  
  # Run in subshell so error doesn't abort test
  (
    set +e  # Disable errexit in subshell
    _test_mark_processed "test-key-4" "test-config" 2>/dev/null
  )
  
  # Lock directory should be cleaned up even after failure
  if [[ -d "${STATE_FILE}.lock" ]]; then
    echo "Lock directory should be removed even when jq fails"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "File Locking Tests:"

for test_func in \
  test_lock_file_creates_lock_directory \
  test_lock_file_blocks_second_lock \
  test_lock_file_recovers_from_stale_file_lock \
  test_lock_file_recovers_from_stale_lock \
  test_unlock_file_removes_lock_directory \
  test_unlock_file_succeeds_when_not_locked \
  test_mark_processed_creates_state_entry \
  test_mark_processed_does_not_use_flock \
  test_mark_processed_no_lock_file_left_behind \
  test_mark_processed_releases_lock_on_error
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
