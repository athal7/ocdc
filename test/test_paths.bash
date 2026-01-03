#!/usr/bin/env bash
#
# Tests for ocdc path management and migration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing ocdc paths..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  # Create isolated test directory (don't use setup_test_env which sets OCDC_* vars)
  export TEST_DIR=$(mktemp -d)
  
  # Override HOME for testing
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
  
  # Clear OCDC_* vars so defaults are used (tests for defaults need this)
  unset OCDC_CONFIG_DIR OCDC_CACHE_DIR OCDC_DATA_DIR OCDC_CLONES_DIR
}

teardown() {
  if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
  fi
}

# =============================================================================
# Tests
# =============================================================================

test_paths_file_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-paths.bash" ]]; then
    echo "lib/ocdc-paths.bash does not exist"
    return 1
  fi
  return 0
}

test_paths_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-paths.bash" 2>&1; then
    echo "Failed to source ocdc-paths.bash"
    return 1
  fi
  return 0
}

test_paths_defines_config_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  if [[ -z "${OCDC_CONFIG_DIR:-}" ]]; then
    echo "OCDC_CONFIG_DIR not defined"
    return 1
  fi
  assert_contains "$OCDC_CONFIG_DIR" ".config/ocdc"
}

test_paths_defines_cache_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  if [[ -z "${OCDC_CACHE_DIR:-}" ]]; then
    echo "OCDC_CACHE_DIR not defined"
    return 1
  fi
  assert_contains "$OCDC_CACHE_DIR" ".cache/ocdc"
}

test_paths_defines_data_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  if [[ -z "${OCDC_DATA_DIR:-}" ]]; then
    echo "OCDC_DATA_DIR not defined"
    return 1
  fi
  assert_contains "$OCDC_DATA_DIR" ".local/share/ocdc"
}

test_paths_defines_clones_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  if [[ -z "${OCDC_CLONES_DIR:-}" ]]; then
    echo "OCDC_CLONES_DIR not defined"
    return 1
  fi
  assert_contains "$OCDC_CLONES_DIR" "devcontainer-clones"
}

test_paths_defines_polls_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  if [[ -z "${OCDC_POLLS_DIR:-}" ]]; then
    echo "OCDC_POLLS_DIR not defined"
    return 1
  fi
  assert_contains "$OCDC_POLLS_DIR" "polls"
}

test_paths_creates_directories() {
  source "$LIB_DIR/ocdc-paths.bash"
  ocdc_ensure_dirs
  
  if [[ ! -d "$OCDC_CONFIG_DIR" ]]; then
    echo "Config dir not created: $OCDC_CONFIG_DIR"
    return 1
  fi
  if [[ ! -d "$OCDC_CACHE_DIR" ]]; then
    echo "Cache dir not created: $OCDC_CACHE_DIR"
    return 1
  fi
  if [[ ! -d "$OCDC_DATA_DIR" ]]; then
    echo "Data dir not created: $OCDC_DATA_DIR"
    return 1
  fi
  if [[ ! -d "$OCDC_POLLS_DIR" ]]; then
    echo "Polls dir not created: $OCDC_POLLS_DIR"
    return 1
  fi
  return 0
}

test_migration_moves_old_config() {
  # Create old directory structure
  local old_config="$HOME/.config/devcontainer-multi"
  mkdir -p "$old_config"
  echo '{"portRangeStart": 14000}' > "$old_config/config.json"
  
  source "$LIB_DIR/ocdc-paths.bash"
  ocdc_migrate_paths
  
  # Check old dir is gone
  if [[ -d "$old_config" ]]; then
    echo "Old config dir should be removed after migration"
    return 1
  fi
  
  # Check new dir has the file
  if [[ ! -f "$OCDC_CONFIG_DIR/config.json" ]]; then
    echo "config.json not migrated to new location"
    return 1
  fi
  
  # Check content preserved
  local port=$(jq -r '.portRangeStart' "$OCDC_CONFIG_DIR/config.json")
  if [[ "$port" != "14000" ]]; then
    echo "Config content not preserved during migration"
    return 1
  fi
  
  return 0
}

test_migration_moves_old_cache() {
  # Create old directory structure
  local old_cache="$HOME/.cache/devcontainer-multi"
  mkdir -p "$old_cache/overrides"
  echo '{}' > "$old_cache/ports.json"
  echo '{}' > "$old_cache/overrides/test.json"
  
  source "$LIB_DIR/ocdc-paths.bash"
  ocdc_migrate_paths
  
  # Check old dir is gone
  if [[ -d "$old_cache" ]]; then
    echo "Old cache dir should be removed after migration"
    return 1
  fi
  
  # Check new dir has the files
  if [[ ! -f "$OCDC_CACHE_DIR/ports.json" ]]; then
    echo "ports.json not migrated to new location"
    return 1
  fi
  if [[ ! -f "$OCDC_CACHE_DIR/overrides/test.json" ]]; then
    echo "overrides not migrated to new location"
    return 1
  fi
  
  return 0
}

test_migration_is_idempotent() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Run migration twice (should not fail)
  ocdc_migrate_paths
  ocdc_migrate_paths
  
  # Dirs should exist
  if [[ ! -d "$OCDC_CONFIG_DIR" ]]; then
    echo "Config dir should exist after migration"
    return 1
  fi
  
  return 0
}

test_migration_preserves_existing_new_dirs() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create new dir with content FIRST
  mkdir -p "$OCDC_CONFIG_DIR"
  echo '{"existing": true}' > "$OCDC_CONFIG_DIR/config.json"
  
  # Create old dir with different content
  local old_config="$HOME/.config/devcontainer-multi"
  mkdir -p "$old_config"
  echo '{"old": true}' > "$old_config/config.json"
  
  ocdc_migrate_paths
  
  # New content should be preserved (not overwritten by old)
  local existing=$(jq -r '.existing // false' "$OCDC_CONFIG_DIR/config.json")
  if [[ "$existing" != "true" ]]; then
    echo "Existing new config should not be overwritten"
    return 1
  fi
  
  return 0
}

test_env_override_respected() {
  # Set custom paths via environment
  export OCDC_CONFIG_DIR="$TEST_DIR/custom-config"
  export OCDC_CACHE_DIR="$TEST_DIR/custom-cache"
  
  source "$LIB_DIR/ocdc-paths.bash"
  
  assert_equals "$TEST_DIR/custom-config" "$OCDC_CONFIG_DIR"
  assert_equals "$TEST_DIR/custom-cache" "$OCDC_CACHE_DIR"
  
  unset OCDC_CONFIG_DIR OCDC_CACHE_DIR
}

test_path_id_returns_consistent_hash() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local path="/some/test/path"
  local hash1=$(ocdc_path_id "$path")
  local hash2=$(ocdc_path_id "$path")
  
  # Should return same hash for same input
  assert_equals "$hash1" "$hash2"
}

test_path_id_returns_32_char_hex() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local hash=$(ocdc_path_id "/test/path")
  
  # MD5 produces 32 hex characters
  if [[ ${#hash} -ne 32 ]]; then
    echo "Expected 32 characters, got ${#hash}: $hash"
    return 1
  fi
  
  # Should only contain hex characters
  if [[ ! "$hash" =~ ^[a-f0-9]+$ ]]; then
    echo "Hash should only contain hex chars: $hash"
    return 1
  fi
  
  return 0
}

test_path_id_different_paths_different_hashes() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local hash1=$(ocdc_path_id "/path/one")
  local hash2=$(ocdc_path_id "/path/two")
  
  if [[ "$hash1" == "$hash2" ]]; then
    echo "Different paths should produce different hashes"
    return 1
  fi
  
  return 0
}

test_path_id_produces_known_hash() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Verify known hash to catch implementation changes
  # MD5 of "/test" (with trailing newline from echo) is aa4100bf...
  local hash=$(ocdc_path_id "/test")
  local expected="aa4100bfddcf9c62750b376c5ebd2b0e"
  
  assert_equals "$expected" "$hash"
}

test_resolve_path_exists() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Function should be defined after sourcing
  if ! type -t ocdc_resolve_path >/dev/null 2>&1; then
    echo "ocdc_resolve_path function not defined"
    return 1
  fi
  return 0
}

test_resolve_path_returns_absolute_path() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  mkdir -p "$TEST_DIR/mydir"
  local result=$(ocdc_resolve_path "$TEST_DIR/mydir")
  
  # Result should start with /
  if [[ "$result" != /* ]]; then
    echo "Expected absolute path, got: $result"
    return 1
  fi
  return 0
}

test_resolve_path_resolves_symlinks() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create a real directory and a symlink to it
  mkdir -p "$TEST_DIR/real-dir"
  ln -s "$TEST_DIR/real-dir" "$TEST_DIR/symlink-dir"
  
  local real_path=$(ocdc_resolve_path "$TEST_DIR/real-dir")
  local symlink_path=$(ocdc_resolve_path "$TEST_DIR/symlink-dir")
  
  # Both should resolve to the same physical path
  if [[ "$real_path" != "$symlink_path" ]]; then
    echo "Symlink not resolved: real=$real_path symlink=$symlink_path"
    return 1
  fi
  return 0
}

test_resolve_path_returns_input_for_nonexistent() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local nonexistent="/nonexistent/path/that/does/not/exist"
  local result=$(ocdc_resolve_path "$nonexistent")
  
  # Should return the original input if the path doesn't exist
  assert_equals "$nonexistent" "$result"
}

test_resolve_path_handles_relative_paths() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  mkdir -p "$TEST_DIR/subdir"
  cd "$TEST_DIR/subdir"
  
  local result=$(ocdc_resolve_path ".")
  
  # Should return an absolute path
  if [[ "$result" != /* ]]; then
    echo "Expected absolute path for '.', got: $result"
    return 1
  fi
  
  # Should contain the subdir name
  if [[ "$result" != *"subdir"* ]]; then
    echo "Expected path to contain 'subdir', got: $result"
    return 1
  fi
  return 0
}

test_resolve_path_resolves_nested_symlinks() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create a real directory and nested symlinks
  mkdir -p "$TEST_DIR/real-dir"
  ln -s "$TEST_DIR/real-dir" "$TEST_DIR/link1"
  ln -s "$TEST_DIR/link1" "$TEST_DIR/link2"
  
  local real_path=$(ocdc_resolve_path "$TEST_DIR/real-dir")
  local link2_path=$(ocdc_resolve_path "$TEST_DIR/link2")
  
  # Nested symlinks should resolve to the same physical path
  if [[ "$real_path" != "$link2_path" ]]; then
    echo "Nested symlinks not resolved: real=$real_path link2=$link2_path"
    return 1
  fi
  return 0
}

test_resolve_path_does_not_change_cwd() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  mkdir -p "$TEST_DIR/original-dir"
  mkdir -p "$TEST_DIR/other-dir"
  
  cd "$TEST_DIR/original-dir"
  local original_cwd=$(pwd)
  
  # Call resolve_path on a different directory
  ocdc_resolve_path "$TEST_DIR/other-dir" >/dev/null
  
  local after_cwd=$(pwd)
  
  # Current directory should not have changed
  if [[ "$original_cwd" != "$after_cwd" ]]; then
    echo "Function changed cwd: before=$original_cwd after=$after_cwd"
    return 1
  fi
  return 0
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

test_is_safe_to_remove_clean_repo() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local repo="$TEST_DIR/clean-repo"
  create_test_git_repo "$repo"
  
  # Clean repo with no remote - should be safe (can't push anywhere)
  if ! ocdc_is_safe_to_remove "$repo"; then
    echo "Clean repo without remote should be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_dirty_repo() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local repo="$TEST_DIR/dirty-repo"
  create_test_git_repo "$repo"
  
  # Make uncommitted changes
  echo "modified" >> "$repo/file.txt"
  
  if ocdc_is_safe_to_remove "$repo"; then
    echo "Repo with uncommitted changes should NOT be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_staged_changes() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local repo="$TEST_DIR/staged-repo"
  create_test_git_repo "$repo"
  
  # Make staged changes
  echo "new" > "$repo/newfile.txt"
  git -C "$repo" add newfile.txt
  
  if ocdc_is_safe_to_remove "$repo"; then
    echo "Repo with staged changes should NOT be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_unpushed_commits() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create a "remote" repo
  local remote="$TEST_DIR/remote-repo"
  mkdir -p "$remote"
  git init --bare --quiet "$remote"
  
  # Create local repo that tracks the remote
  local repo="$TEST_DIR/local-repo"
  create_test_git_repo "$repo"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main 2>/dev/null || git -C "$repo" push --quiet -u origin master 2>/dev/null
  
  # Make a new commit that isn't pushed
  echo "new commit" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit --quiet -m "Unpushed commit"
  
  if ocdc_is_safe_to_remove "$repo"; then
    echo "Repo with unpushed commits should NOT be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_pushed_commits() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create a "remote" repo
  local remote="$TEST_DIR/remote-repo2"
  mkdir -p "$remote"
  git init --bare --quiet "$remote"
  
  # Create local repo that tracks the remote
  local repo="$TEST_DIR/local-repo2"
  create_test_git_repo "$repo"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main 2>/dev/null || git -C "$repo" push --quiet -u origin master 2>/dev/null
  
  # Everything is pushed - should be safe
  if ! ocdc_is_safe_to_remove "$repo"; then
    echo "Repo with all commits pushed should be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_nonexistent_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Non-existent directory should be safe (nothing to lose)
  if ! ocdc_is_safe_to_remove "/nonexistent/path/xyz"; then
    echo "Non-existent directory should be safe to remove"
    return 1
  fi
  return 0
}

test_is_safe_to_remove_non_git_dir() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local dir="$TEST_DIR/not-a-repo"
  mkdir -p "$dir"
  echo "some file" > "$dir/file.txt"
  
  # Non-git directory should be safe (no git state to preserve)
  if ! ocdc_is_safe_to_remove "$dir"; then
    echo "Non-git directory should be safe to remove"
    return 1
  fi
  return 0
}

test_get_git_status_returns_json() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local repo="$TEST_DIR/status-repo"
  create_test_git_repo "$repo"
  
  local status
  status=$(ocdc_get_git_status "$repo")
  
  # Should be valid JSON
  if ! echo "$status" | jq -e '.' >/dev/null 2>&1; then
    echo "Should return valid JSON"
    echo "Got: $status"
    return 1
  fi
  
  # Should have expected fields
  assert_contains "$status" '"clean"'
  assert_contains "$status" '"pushed"'
}

test_get_git_status_dirty() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  local repo="$TEST_DIR/status-dirty"
  create_test_git_repo "$repo"
  echo "dirty" >> "$repo/file.txt"
  
  local status
  status=$(ocdc_get_git_status "$repo")
  
  local clean
  clean=$(echo "$status" | jq -r '.clean')
  
  if [[ "$clean" != "false" ]]; then
    echo "Dirty repo should have clean=false"
    echo "Got: $status"
    return 1
  fi
  return 0
}

test_get_git_status_unpushed() {
  source "$LIB_DIR/ocdc-paths.bash"
  
  # Create a "remote" repo
  local remote="$TEST_DIR/remote-status"
  mkdir -p "$remote"
  git init --bare --quiet "$remote"
  
  # Create local repo that tracks the remote
  local repo="$TEST_DIR/local-status"
  create_test_git_repo "$repo"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main 2>/dev/null || git -C "$repo" push --quiet -u origin master 2>/dev/null
  
  # Make a new commit that isn't pushed
  echo "new" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit --quiet -m "Unpushed"
  
  local status
  status=$(ocdc_get_git_status "$repo")
  
  local pushed ahead
  pushed=$(echo "$status" | jq -r '.pushed')
  ahead=$(echo "$status" | jq -r '.ahead')
  
  if [[ "$pushed" != "false" ]]; then
    echo "Repo with unpushed commits should have pushed=false"
    echo "Got: $status"
    return 1
  fi
  
  if [[ "$ahead" != "1" ]]; then
    echo "Should be 1 commit ahead"
    echo "Got: $status"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Path Management Tests:"

for test_func in \
  test_paths_file_exists \
  test_paths_can_be_sourced \
  test_paths_defines_config_dir \
  test_paths_defines_cache_dir \
  test_paths_defines_data_dir \
  test_paths_defines_clones_dir \
  test_paths_defines_polls_dir \
  test_paths_creates_directories \
  test_migration_moves_old_config \
  test_migration_moves_old_cache \
  test_migration_is_idempotent \
  test_migration_preserves_existing_new_dirs \
  test_env_override_respected \
  test_path_id_returns_consistent_hash \
  test_path_id_returns_32_char_hex \
  test_path_id_different_paths_different_hashes \
  test_path_id_produces_known_hash \
  test_resolve_path_exists \
  test_resolve_path_returns_absolute_path \
  test_resolve_path_resolves_symlinks \
  test_resolve_path_returns_input_for_nonexistent \
  test_resolve_path_handles_relative_paths \
  test_resolve_path_resolves_nested_symlinks \
  test_resolve_path_does_not_change_cwd
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Git Safety Tests:"

for test_func in \
  test_is_safe_to_remove_clean_repo \
  test_is_safe_to_remove_dirty_repo \
  test_is_safe_to_remove_staged_changes \
  test_is_safe_to_remove_unpushed_commits \
  test_is_safe_to_remove_pushed_commits \
  test_is_safe_to_remove_nonexistent_dir \
  test_is_safe_to_remove_non_git_dir \
  test_get_git_status_returns_json \
  test_get_git_status_dirty \
  test_get_git_status_unpushed
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
