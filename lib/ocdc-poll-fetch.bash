#!/usr/bin/env bash
#
# ocdc-poll-fetch.bash - Fetch command building for poll sources
#
# Builds commands to fetch items from MCP servers (Linear, GitHub) using
# the ocdc-mcp-fetch.js bridge script.
#
# Usage:
#   source "$(dirname "$0")/ocdc-poll-fetch.bash"
#   cmd=$(poll_config_build_fetch_command "github_issue" '{"repo":"org/repo"}')

# Prevent multiple sourcing
[[ -n "${_OCDC_POLL_FETCH_LOADED:-}" ]] && return 0
_OCDC_POLL_FETCH_LOADED=1

# Source defaults if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ocdc-poll-defaults.bash"

# =============================================================================
# Shell Quoting
# =============================================================================

# Shell-quote a string for safe interpolation into a command
# Usage: _shell_quote "value with spaces"
_shell_quote() {
  printf '%q' "$1"
}

# =============================================================================
# Fetch Command Building
# =============================================================================

# Build fetch command from source type and fetch options
# Usage: poll_config_build_fetch_command "linear_issue" '{"assignee":"@me"}'
#
# Returns a command that calls the MCP fetch bridge script:
#   node <lib>/ocdc-mcp-fetch.js <source_type> '<merged_options_json>'
poll_config_build_fetch_command() {
  local source_type="$1"
  local fetch_options="${2:-}"
  
  # Merge with defaults (compact JSON output for command line)
  local defaults
  defaults=$(poll_config_get_default_fetch_options "$source_type")
  
  if [[ -n "$fetch_options" ]] && [[ "$fetch_options" != "null" ]]; then
    fetch_options=$(echo "$defaults" | jq -c --argjson opts "$fetch_options" '. * $opts')
  else
    fetch_options=$(echo "$defaults" | jq -c '.')
  fi
  
  # Validate source type
  case "$source_type" in
    linear_issue|github_issue|github_pr)
      # Valid source types
      ;;
    *)
      echo "echo '[]'"
      return 0
      ;;
  esac
  
  # Build command using MCP fetch bridge script
  local mcp_fetch_script="${SCRIPT_DIR}/ocdc-mcp-fetch.js"
  
  # Shell-quote the JSON options to prevent injection
  local quoted_opts
  quoted_opts=$(_shell_quote "$fetch_options")
  
  echo "node \"${mcp_fetch_script}\" \"${source_type}\" ${quoted_opts}"
}
