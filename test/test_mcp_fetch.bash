#!/usr/bin/env bash
#
# Tests for MCP fetch script (lib/ocdc-mcp-fetch.js)
#
# Tests the MCP bridge script that fetches items from MCP servers
# (GitHub, Linear) and transforms responses for the poll orchestrator.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
MCP_FETCH="$LIB_DIR/ocdc-mcp-fetch.js"

echo "Testing MCP fetch script..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create mock opencode config directory
  export OCDC_MCP_CONFIG_PATH="$TEST_CONFIG_DIR/opencode.json"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Helper Functions
# =============================================================================

create_mock_mcp_config() {
  cat > "$OCDC_MCP_CONFIG_PATH" << 'EOF'
{
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.githubcopilot.com/mcp/",
      "enabled": true
    },
    "linear": {
      "type": "remote",
      "url": "https://mcp.linear.app/sse",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer ${LINEAR_API_TOKEN}"
      }
    }
  }
}
EOF
}

create_disabled_github_config() {
  cat > "$OCDC_MCP_CONFIG_PATH" << 'EOF'
{
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.githubcopilot.com/mcp/",
      "enabled": false
    }
  }
}
EOF
}

create_empty_mcp_config() {
  cat > "$OCDC_MCP_CONFIG_PATH" << 'EOF'
{
  "mcp": {}
}
EOF
}

# =============================================================================
# Script Existence Tests
# =============================================================================

test_mcp_fetch_script_exists() {
  if [[ ! -f "$MCP_FETCH" ]]; then
    echo "lib/ocdc-mcp-fetch.js does not exist"
    return 1
  fi
  return 0
}

test_mcp_fetch_script_is_executable() {
  if [[ ! -x "$MCP_FETCH" ]]; then
    echo "lib/ocdc-mcp-fetch.js is not executable"
    return 1
  fi
  return 0
}

# =============================================================================
# Argument Validation Tests
# =============================================================================

test_mcp_fetch_no_args_fails() {
  local exit_code=0
  node "$MCP_FETCH" 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 1 ]]; then
    echo "Expected exit code 1 for missing arguments, got $exit_code"
    return 1
  fi
  return 0
}

test_mcp_fetch_invalid_source_type_fails() {
  create_mock_mcp_config
  
  local exit_code=0
  node "$MCP_FETCH" "invalid_type" '{}' 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 1 ]]; then
    echo "Expected exit code 1 for invalid source type, got $exit_code"
    return 1
  fi
  return 0
}

test_mcp_fetch_valid_source_types() {
  # Test that valid source types are recognized (even if MCP is not configured)
  # Script should fail at MCP config step, not source type validation
  create_empty_mcp_config
  
  for source_type in github_issue github_pr linear_issue; do
    local exit_code=0
    local output
    output=$(node "$MCP_FETCH" "$source_type" '{}' 2>&1) || exit_code=$?
    
    # Should fail with exit code 10 (MCP not configured), not 1 (invalid args)
    if [[ $exit_code -eq 1 ]]; then
      echo "Source type '$source_type' was rejected as invalid"
      return 1
    fi
  done
  return 0
}

# =============================================================================
# MCP Configuration Tests
# =============================================================================

test_mcp_fetch_missing_config_file() {
  # Remove config file
  rm -f "$OCDC_MCP_CONFIG_PATH"
  
  local exit_code=0
  node "$MCP_FETCH" "github_issue" '{}' 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 10 ]]; then
    echo "Expected exit code 10 for missing config file, got $exit_code"
    return 1
  fi
  return 0
}

test_mcp_fetch_mcp_not_configured() {
  create_empty_mcp_config
  
  local exit_code=0
  node "$MCP_FETCH" "github_issue" '{}' 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 10 ]]; then
    echo "Expected exit code 10 for MCP not configured, got $exit_code"
    return 1
  fi
  return 0
}

test_mcp_fetch_mcp_server_disabled() {
  create_disabled_github_config
  
  local exit_code=0
  node "$MCP_FETCH" "github_issue" '{}' 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 10 ]]; then
    echo "Expected exit code 10 for disabled MCP server, got $exit_code"
    return 1
  fi
  return 0
}

# =============================================================================
# JSON Options Parsing Tests
# =============================================================================

test_mcp_fetch_parses_json_options() {
  create_mock_mcp_config
  
  # With valid config, script will try to connect (and fail in test env)
  # But it should parse the JSON options without error
  local exit_code=0
  local output
  output=$(node "$MCP_FETCH" "github_issue" '{"assignee":"@me","state":"open"}' 2>&1) || exit_code=$?
  
  # Should fail at connection step (11), not JSON parsing (1)
  if [[ $exit_code -eq 1 ]]; then
    if [[ "$output" == *"JSON"* ]] || [[ "$output" == *"parse"* ]]; then
      echo "JSON parsing failed: $output"
      return 1
    fi
  fi
  return 0
}

test_mcp_fetch_handles_invalid_json() {
  create_mock_mcp_config
  
  local exit_code=0
  node "$MCP_FETCH" "github_issue" 'not valid json' 2>/dev/null || exit_code=$?
  
  if [[ $exit_code -ne 1 ]]; then
    echo "Expected exit code 1 for invalid JSON, got $exit_code"
    return 1
  fi
  return 0
}

test_mcp_fetch_handles_empty_options() {
  create_mock_mcp_config
  
  # Empty options should be valid (use defaults)
  local exit_code=0
  node "$MCP_FETCH" "github_issue" 2>&1 || exit_code=$?
  
  # Should not fail at argument parsing (1)
  if [[ $exit_code -eq 1 ]]; then
    echo "Empty options should be valid"
    return 1
  fi
  return 0
}

# =============================================================================
# Source Type to MCP Server Mapping Tests
# =============================================================================

test_mcp_fetch_github_issue_uses_github_server() {
  # Create config with only Linear (no GitHub)
  cat > "$OCDC_MCP_CONFIG_PATH" << 'EOF'
{
  "mcp": {
    "linear": {
      "type": "remote",
      "url": "https://mcp.linear.app/sse",
      "enabled": true
    }
  }
}
EOF
  
  local exit_code=0
  local output
  output=$(node "$MCP_FETCH" "github_issue" '{}' 2>&1) || exit_code=$?
  
  # Should fail because GitHub MCP is not configured
  if [[ $exit_code -ne 10 ]]; then
    echo "Expected exit code 10 (MCP not configured), got $exit_code"
    return 1
  fi
  if [[ "$output" != *"github"* ]]; then
    echo "Error message should mention github server"
    return 1
  fi
  return 0
}

test_mcp_fetch_linear_issue_uses_linear_server() {
  # Create config with only GitHub (no Linear)
  cat > "$OCDC_MCP_CONFIG_PATH" << 'EOF'
{
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.githubcopilot.com/mcp/",
      "enabled": true
    }
  }
}
EOF
  
  local exit_code=0
  local output
  output=$(node "$MCP_FETCH" "linear_issue" '{}' 2>&1) || exit_code=$?
  
  # Should fail because Linear MCP is not configured
  if [[ $exit_code -ne 10 ]]; then
    echo "Expected exit code 10 (MCP not configured), got $exit_code"
    return 1
  fi
  if [[ "$output" != *"linear"* ]]; then
    echo "Error message should mention linear server"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "MCP Fetch Script Tests:"

for test_func in \
  test_mcp_fetch_script_exists \
  test_mcp_fetch_script_is_executable \
  test_mcp_fetch_no_args_fails \
  test_mcp_fetch_invalid_source_type_fails \
  test_mcp_fetch_valid_source_types \
  test_mcp_fetch_missing_config_file \
  test_mcp_fetch_mcp_not_configured \
  test_mcp_fetch_mcp_server_disabled \
  test_mcp_fetch_parses_json_options \
  test_mcp_fetch_handles_invalid_json \
  test_mcp_fetch_handles_empty_options \
  test_mcp_fetch_github_issue_uses_github_server \
  test_mcp_fetch_linear_issue_uses_linear_server
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
