#!/usr/bin/env bash
#
# Integration tests for ocdc-clean command
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing ocdc-clean..."
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

test_ocdc_clean_shows_help() {
  local output=$("$BIN_DIR/ocdc" clean --help 2>&1)
  assert_contains "$output" "Usage:"
  assert_contains "$output" "ocdc-clean"
}

test_ocdc_clean_handles_no_orphans() {
  # Empty clones dir, should report nothing to clean
  # Use --clones to avoid picking up real sessions from the system
  local output=$("$BIN_DIR/ocdc" clean --clones 2>&1)
  assert_contains "$output" "No orphaned clones"
}

test_ocdc_clean_removes_orphaned_clone() {
  # Create a clone directory that's not tracked
  mkdir -p "$TEST_CLONES_DIR/my-repo/feature-branch"
  echo "test file" > "$TEST_CLONES_DIR/my-repo/feature-branch/README.md"
  
  # Ensure no tracked containers (empty ports.json)
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean with --force to skip confirmation
  local output=$("$BIN_DIR/ocdc" clean --force 2>&1)
  assert_contains "$output" "Removed"
  
  # Verify clone was removed
  [[ ! -d "$TEST_CLONES_DIR/my-repo/feature-branch" ]] || {
    echo "Clone directory should have been removed"
    return 1
  }
}

test_ocdc_clean_preserves_tracked_clone() {
  # Create a clone directory
  mkdir -p "$TEST_CLONES_DIR/my-repo/tracked-branch"
  echo "test file" > "$TEST_CLONES_DIR/my-repo/tracked-branch/README.md"
  
  # Resolve the real path (macOS /var -> /private/var)
  local real_path=$(cd "$TEST_CLONES_DIR/my-repo/tracked-branch" && pwd -P)
  
  # Track it in ports.json
  cat > "$TEST_CACHE_DIR/ports.json" << EOF
{
  "$real_path": {
    "port": 13000,
    "repo": "my-repo",
    "branch": "tracked-branch"
  }
}
EOF
  
  # Run clean
  local output=$("$BIN_DIR/ocdc" clean --force 2>&1)
  
  # Verify tracked clone was preserved
  [[ -d "$TEST_CLONES_DIR/my-repo/tracked-branch" ]] || {
    echo "Tracked clone should have been preserved"
    return 1
  }
}

test_ocdc_clean_cleans_empty_parent_dirs() {
  # Create an orphaned clone
  mkdir -p "$TEST_CLONES_DIR/my-repo/only-branch"
  echo "test file" > "$TEST_CLONES_DIR/my-repo/only-branch/README.md"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean
  "$BIN_DIR/ocdc" clean --force 2>&1
  
  # Verify parent directory was also removed (it's now empty)
  [[ ! -d "$TEST_CLONES_DIR/my-repo" ]] || {
    echo "Empty parent directory should have been removed"
    return 1
  }
}

test_ocdc_clean_dry_run_shows_but_preserves() {
  # Create an orphaned clone
  mkdir -p "$TEST_CLONES_DIR/my-repo/feature-branch"
  echo "test file" > "$TEST_CLONES_DIR/my-repo/feature-branch/README.md"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean with --dry-run
  local output=$("$BIN_DIR/ocdc" clean --dry-run 2>&1)
  assert_contains "$output" "Would remove"
  assert_contains "$output" "feature-branch"
  
  # Verify clone was NOT removed
  [[ -d "$TEST_CLONES_DIR/my-repo/feature-branch" ]] || {
    echo "Clone directory should have been preserved in dry-run mode"
    return 1
  }
}

test_ocdc_clean_multiple_orphans() {
  # Create multiple orphaned clones
  mkdir -p "$TEST_CLONES_DIR/repo-a/branch-1"
  mkdir -p "$TEST_CLONES_DIR/repo-a/branch-2"
  mkdir -p "$TEST_CLONES_DIR/repo-b/main"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean
  local output=$("$BIN_DIR/ocdc" clean --force 2>&1)
  
  # All should be removed
  [[ ! -d "$TEST_CLONES_DIR/repo-a/branch-1" ]] || return 1
  [[ ! -d "$TEST_CLONES_DIR/repo-a/branch-2" ]] || return 1
  [[ ! -d "$TEST_CLONES_DIR/repo-b/main" ]] || return 1
}

# =============================================================================
# Git Safety Tests
# =============================================================================

# Helper to create a test git repo
create_test_git_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  cd "$repo_dir"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test User"
  echo "initial" > file.txt
  git add file.txt
  git commit --quiet -m "Initial commit"
}

test_ocdc_clean_skips_dirty_workspace() {
  # Create an orphaned clone with uncommitted changes
  local clone="$TEST_CLONES_DIR/my-repo/dirty-branch"
  create_test_git_repo "$clone"
  echo "uncommitted" >> "$clone/file.txt"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean (should skip dirty workspace)
  local output=$("$BIN_DIR/ocdc" clean 2>&1)
  assert_contains "$output" "Skipped"
  assert_contains "$output" "uncommitted"
  
  # Verify clone was NOT removed
  [[ -d "$clone" ]] || {
    echo "Dirty clone should have been preserved"
    return 1
  }
}

test_ocdc_clean_skips_unpushed_workspace() {
  # Create a "remote" repo
  local remote="$TEST_DIR/remote-repo"
  mkdir -p "$remote"
  git init --bare --quiet "$remote"
  
  # Create an orphaned clone with unpushed commits
  local clone="$TEST_CLONES_DIR/my-repo/unpushed-branch"
  create_test_git_repo "$clone"
  git -C "$clone" remote add origin "$remote"
  git -C "$clone" push --quiet -u origin main 2>/dev/null || git -C "$clone" push --quiet -u origin master 2>/dev/null
  
  # Make a new unpushed commit
  echo "new" >> "$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" commit --quiet -m "Unpushed"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean (should skip unpushed workspace)
  local output=$("$BIN_DIR/ocdc" clean 2>&1)
  assert_contains "$output" "Skipped"
  assert_contains "$output" "unpushed"
  
  # Verify clone was NOT removed
  [[ -d "$clone" ]] || {
    echo "Unpushed clone should have been preserved"
    return 1
  }
}

test_ocdc_clean_force_removes_dirty() {
  # Create an orphaned clone with uncommitted changes
  local clone="$TEST_CLONES_DIR/my-repo/dirty-force"
  create_test_git_repo "$clone"
  echo "uncommitted" >> "$clone/file.txt"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean with --force (should remove despite being dirty)
  local output=$("$BIN_DIR/ocdc" clean --force 2>&1)
  
  # Verify clone WAS removed
  [[ ! -d "$clone" ]] || {
    echo "Dirty clone should have been removed with --force"
    return 1
  }
}

# =============================================================================
# Session Cleanup Tests
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

test_ocdc_clean_kills_orphaned_session() {
  # Create an orphaned session (workspace doesn't exist)
  create_test_session "test-ocdc-orphan-sess" "/nonexistent/workspace" "test-poll" "test-key"
  
  # Verify session exists
  if ! tmux has-session -t "test-ocdc-orphan-sess" 2>/dev/null; then
    echo "Setup failed: session not created"
    return 1
  fi
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Set up poll state dir
  export OCDC_POLL_STATE_DIR="$TEST_DATA_DIR/poll-state"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  echo '{"test-key": {"config": "test", "processed_at": "2024-01-01"}}' > "$OCDC_POLL_STATE_DIR/processed.json"
  
  # Run clean
  local output=$("$BIN_DIR/ocdc" clean 2>&1)
  assert_contains "$output" "Killed session"
  
  # Verify session was killed
  if tmux has-session -t "test-ocdc-orphan-sess" 2>/dev/null; then
    cleanup_test_sessions
    echo "Orphaned session should have been killed"
    return 1
  fi
  
  # Verify processed state was cleared
  local remaining
  remaining=$(jq -r '.["test-key"] // "null"' "$OCDC_POLL_STATE_DIR/processed.json")
  if [[ "$remaining" != "null" ]]; then
    echo "Processed state should have been cleared"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

test_ocdc_clean_preserves_session_with_workspace() {
  # Create a session with existing workspace
  local workspace="$TEST_CLONES_DIR/my-repo/session-branch"
  mkdir -p "$workspace"
  
  create_test_session "test-ocdc-valid-sess" "$workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean
  "$BIN_DIR/ocdc" clean 2>&1
  
  # Verify session still exists (workspace exists, so not orphaned)
  if ! tmux has-session -t "test-ocdc-valid-sess" 2>/dev/null; then
    echo "Session with valid workspace should be preserved"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

test_ocdc_clean_sessions_flag_only_sessions() {
  # Create an orphaned clone
  mkdir -p "$TEST_CLONES_DIR/my-repo/orphan-branch"
  
  # Create an orphaned session
  create_test_session "test-ocdc-sess-only" "/nonexistent/workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean --sessions (should only clean sessions, not clones)
  local output=$("$BIN_DIR/ocdc" clean --sessions 2>&1)
  
  # Session should be killed
  if tmux has-session -t "test-ocdc-sess-only" 2>/dev/null; then
    cleanup_test_sessions
    echo "Session should have been killed"
    return 1
  fi
  
  # Clone should be preserved
  if [[ ! -d "$TEST_CLONES_DIR/my-repo/orphan-branch" ]]; then
    cleanup_test_sessions
    echo "Clone should have been preserved with --sessions flag"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

test_ocdc_clean_clones_flag_only_clones() {
  # Create an orphaned clone
  mkdir -p "$TEST_CLONES_DIR/my-repo/clone-only"
  
  # Create an orphaned session
  create_test_session "test-ocdc-clone-flag" "/nonexistent/workspace" "test-poll" "test-key"
  
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  
  # Run clean --clones (should only clean clones, not sessions)
  local output=$("$BIN_DIR/ocdc" clean --clones 2>&1)
  
  # Clone should be removed
  if [[ -d "$TEST_CLONES_DIR/my-repo/clone-only" ]]; then
    cleanup_test_sessions
    echo "Clone should have been removed"
    return 1
  fi
  
  # Session should be preserved
  if ! tmux has-session -t "test-ocdc-clone-flag" 2>/dev/null; then
    cleanup_test_sessions
    echo "Session should have been preserved with --clones flag"
    return 1
  fi
  
  cleanup_test_sessions
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Clean Command Tests:"

for test_func in \
  test_ocdc_clean_shows_help \
  test_ocdc_clean_handles_no_orphans \
  test_ocdc_clean_removes_orphaned_clone \
  test_ocdc_clean_preserves_tracked_clone \
  test_ocdc_clean_cleans_empty_parent_dirs \
  test_ocdc_clean_dry_run_shows_but_preserves \
  test_ocdc_clean_multiple_orphans
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Git Safety Tests:"

for test_func in \
  test_ocdc_clean_skips_dirty_workspace \
  test_ocdc_clean_skips_unpushed_workspace \
  test_ocdc_clean_force_removes_dirty
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Cleanup Tests:"

for test_func in \
  test_ocdc_clean_kills_orphaned_session \
  test_ocdc_clean_preserves_session_with_workspace \
  test_ocdc_clean_sessions_flag_only_sessions \
  test_ocdc_clean_clones_flag_only_clones
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
