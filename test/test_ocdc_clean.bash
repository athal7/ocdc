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
  local output=$("$BIN_DIR/ocdc" clean 2>&1)
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

print_summary
