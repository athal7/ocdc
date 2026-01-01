#!/usr/bin/env bash
#
# Tests for ocdc naming consistency
#
# Verifies that legacy command names (dcup, dcdown, etc.) are not used
# in documentation or user-facing messages.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Testing ocdc naming consistency..."
echo ""

# =============================================================================
# Helper Functions
# =============================================================================

# Check if a file contains legacy command names in comments/strings
# (excluding legitimate variable/path references to devcontainer-multi for migration)
check_file_for_legacy_commands() {
  local file="$1"
  local errors=0
  
  # Check for dcup, dcdown, dclist, dcexec, dcgo, dctui, dcclean as standalone commands
  # These patterns match word boundaries to avoid false positives
  for cmd in dcup dcdown dclist dcexec dcgo dctui dcclean; do
    # Search for the command as a word (not part of another word)
    # Allow references in variable names like _LEGACY or path migration code
    if grep -nE "(^|[^_a-zA-Z0-9])${cmd}([^_a-zA-Z0-9]|$)" "$file" 2>/dev/null | \
       grep -vE '_LEGACY|migration|_migrate' > /dev/null; then
      echo "  Found legacy command '$cmd' in: $file"
      grep -nE "(^|[^_a-zA-Z0-9])${cmd}([^_a-zA-Z0-9]|$)" "$file" | \
        grep -vE '_LEGACY|migration|_migrate' | head -3 | sed 's/^/    /'
      errors=$((errors + 1))
    fi
  done
  
  return $errors
}

# =============================================================================
# Tests
# =============================================================================

test_ocdc_up_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-up"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_ocdc_down_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-down"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_ocdc_exec_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-exec"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_ocdc_list_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-list"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_ocdc_go_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-go"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_ocdc_tui_no_legacy_commands() {
  local file="$PROJECT_DIR/lib/ocdc-tui"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  check_file_for_legacy_commands "$file"
}

test_helper_no_legacy_project_name() {
  local file="$PROJECT_DIR/test/test_helper.bash"
  if [[ ! -f "$file" ]]; then
    echo "File not found: $file"
    return 1
  fi
  # Check for devcontainer-multi in comments (excluding path references for migration)
  if grep -nE 'devcontainer-multi' "$file" 2>/dev/null | \
     grep -vE '_LEGACY|migration|_migrate|\.config/|\.cache/' > /dev/null; then
    echo "  Found 'devcontainer-multi' in: $file"
    grep -nE 'devcontainer-multi' "$file" | \
      grep -vE '_LEGACY|migration|_migrate|\.config/|\.cache/' | head -3 | sed 's/^/    /'
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Naming Consistency Tests:"

for test_func in \
  test_ocdc_up_no_legacy_commands \
  test_ocdc_down_no_legacy_commands \
  test_ocdc_exec_no_legacy_commands \
  test_ocdc_list_no_legacy_commands \
  test_ocdc_go_no_legacy_commands \
  test_ocdc_tui_no_legacy_commands \
  test_helper_no_legacy_project_name
do
  run_test "${test_func#test_}" "$test_func"
done

print_summary
