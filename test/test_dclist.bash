#!/usr/bin/env bash
#
# Integration tests for dclist command
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing dclist..."
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

test_dclist_shows_help() {
  local output=$("$BIN_DIR/dclist" --help 2>&1)
  assert_contains "$output" "dclist"
}

test_dclist_shows_empty_message() {
  echo '{}' > "$TEST_CACHE_DIR/ports.json"
  local output=$("$BIN_DIR/dclist" 2>&1)
  assert_contains "$output" "No devcontainer instances"
}

test_dclist_shows_registered_instance() {
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
  
  local output=$("$BIN_DIR/dclist" 2>&1)
  assert_contains "$output" "13000"
  assert_contains "$output" "my-repo"
  assert_contains "$output" "main"
}

test_dclist_shows_multiple_instances() {
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
  
  local output=$("$BIN_DIR/dclist" 2>&1)
  assert_contains "$output" "13000"
  assert_contains "$output" "13001"
  assert_contains "$output" "repo1"
  assert_contains "$output" "repo2"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Command Usage Tests:"

for test_func in \
  test_dclist_shows_help \
  test_dclist_shows_empty_message \
  test_dclist_shows_registered_instance \
  test_dclist_shows_multiple_instances
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
