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
  test_path_id_produces_known_hash
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
