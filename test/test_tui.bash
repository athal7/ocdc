#!/usr/bin/env bash
#
# Tests for ocdc-tui layout functions
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing ocdc-tui..."
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
# Tests for calculate_layout function
# =============================================================================

test_calculate_layout_exists() {
  # Source the TUI script to get the function
  # We need to extract just the function, not run main()
  if ! grep -q "calculate_layout()" "$LIB_DIR/ocdc-tui"; then
    echo "calculate_layout function should exist in ocdc-tui"
    return 1
  fi
  return 0
}

test_layout_widens_branch_on_wide_terminal() {
  # Source just the layout function
  source_layout_function
  
  # On a 120-column terminal, branch should be wider than 16
  calculate_layout 120
  
  if [[ $BRANCH_WIDTH -le 16 ]]; then
    echo "Branch width should be > 16 on 120-col terminal, got: $BRANCH_WIDTH"
    return 1
  fi
  return 0
}

test_layout_minimum_widths_on_narrow_terminal() {
  source_layout_function
  
  # On a narrow 60-column terminal, should use minimum widths
  calculate_layout 60
  
  if [[ $REPO_WIDTH -lt $MIN_REPO_WIDTH ]]; then
    echo "Repo width should be at least $MIN_REPO_WIDTH, got: $REPO_WIDTH"
    return 1
  fi
  if [[ $BRANCH_WIDTH -lt $MIN_BRANCH_WIDTH ]]; then
    echo "Branch width should be at least $MIN_BRANCH_WIDTH, got: $BRANCH_WIDTH"
    return 1
  fi
  return 0
}

test_layout_centers_on_wide_terminal() {
  source_layout_function
  
  # On a very wide terminal (200 cols), should have left padding for centering
  calculate_layout 200
  
  if [[ $LEFT_PADDING -le 0 ]]; then
    echo "Should have left padding for centering on wide terminal, got: $LEFT_PADDING"
    return 1
  fi
  return 0
}

test_layout_no_centering_on_narrow_terminal() {
  source_layout_function
  
  # On a terminal barely wider than content, centering is minimal
  # Content at minimum is ~44 chars, so 50 cols should have small padding
  calculate_layout 50
  
  # At 50 cols, content ~44, padding would be ~3 which is fine
  # Just verify it doesn't crash and has reasonable padding
  if [[ $LEFT_PADDING -lt 0 ]]; then
    echo "Left padding should not be negative, got: $LEFT_PADDING"
    return 1
  fi
  return 0
}

test_layout_respects_max_width() {
  source_layout_function
  
  # Even on a 300-col terminal, content width (excluding centering padding) should not exceed max
  calculate_layout 300
  
  # Content width = port + repo + branch + status + spacing (excluding centering padding)
  local content_width=$((PORT_WIDTH + 2 + REPO_WIDTH + 2 + BRANCH_WIDTH + 2 + STATUS_WIDTH))
  
  # Content should not exceed MAX_CONTENT_WIDTH
  if [[ $content_width -gt $MAX_CONTENT_WIDTH ]]; then
    echo "Content width should not exceed $MAX_CONTENT_WIDTH, got: $content_width"
    return 1
  fi
  return 0
}

test_layout_handles_very_narrow_terminal() {
  source_layout_function
  
  # On a very narrow terminal (30 cols), should use minimums and not crash
  calculate_layout 30
  
  if [[ $REPO_WIDTH -lt $MIN_REPO_WIDTH ]]; then
    echo "Repo width should be at least $MIN_REPO_WIDTH, got: $REPO_WIDTH"
    return 1
  fi
  if [[ $BRANCH_WIDTH -lt $MIN_BRANCH_WIDTH ]]; then
    echo "Branch width should be at least $MIN_BRANCH_WIDTH, got: $BRANCH_WIDTH"
    return 1
  fi
  if [[ $LEFT_PADDING -lt 0 ]]; then
    echo "Left padding should not be negative, got: $LEFT_PADDING"
    return 1
  fi
  return 0
}

test_layout_centers_at_max_content_width() {
  source_layout_function
  
  # At exactly MAX_CONTENT_WIDTH + some margin, should start centering
  calculate_layout 140
  
  # Content width at max is ~98 (6+36+50+6), terminal is 140
  # Should have meaningful left padding for centering
  if [[ $LEFT_PADDING -le 5 ]]; then
    echo "Should have centering padding at 140 cols, got LEFT_PADDING: $LEFT_PADDING"
    return 1
  fi
  return 0
}

test_vertical_padding_on_tall_terminal() {
  source_layout_function
  
  # With 5 instances and a 50-row terminal, should have top padding
  calculate_layout 120 50 5
  
  if [[ $TOP_PADDING -le 0 ]]; then
    echo "Should have top padding on tall terminal, got: $TOP_PADDING"
    return 1
  fi
  return 0
}

test_no_vertical_padding_on_short_terminal() {
  source_layout_function
  
  # With 5 instances and only 15 rows, should not add top padding
  calculate_layout 120 15 5
  
  if [[ $TOP_PADDING -gt 0 ]]; then
    echo "Should not have top padding on short terminal, got: $TOP_PADDING"
    return 1
  fi
  return 0
}

# Helper to source just the layout function and constants from ocdc-tui
source_layout_function() {
  # Define constants (must match ocdc-tui)
  MIN_REPO_WIDTH=12
  MIN_BRANCH_WIDTH=12
  MAX_CONTENT_WIDTH=130
  PORT_WIDTH=6
  STATUS_WIDTH=8
  GIT_WIDTH=10
  REPO_WIDTH=$MIN_REPO_WIDTH
  BRANCH_WIDTH=$MIN_BRANCH_WIDTH
  LEFT_PADDING=2
  TOP_PADDING=0
  
  # Extract and eval the calculate_layout function
  eval "$(sed -n '/^calculate_layout()/,/^}$/p' "$LIB_DIR/ocdc-tui")"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "TUI Layout Tests:"

for test_func in \
  test_calculate_layout_exists \
  test_layout_widens_branch_on_wide_terminal \
  test_layout_minimum_widths_on_narrow_terminal \
  test_layout_centers_on_wide_terminal \
  test_layout_no_centering_on_narrow_terminal \
  test_layout_respects_max_width \
  test_layout_handles_very_narrow_terminal \
  test_layout_centers_at_max_content_width \
  test_vertical_padding_on_tall_terminal \
  test_no_vertical_padding_on_short_terminal
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
