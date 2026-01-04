#!/usr/bin/env bash
#
# ocdc-repo-config.bash - Repository configuration management for self-iteration
#
# Manages per-repository configuration stored in ~/.config/ocdc/repos.yaml
# Each repo is keyed by its identifier (e.g., "owner/repo" for GitHub)
#
# Usage:
#   source "$(dirname "$0")/ocdc-repo-config.bash"
#   config=$(repo_config_get "athal7/ocdc")
#
# Required: ruby (for YAML parsing), jq (for JSON manipulation)

# Prevent multiple sourcing
[[ -n "${_OCDC_REPO_CONFIG_LOADED:-}" ]] && return 0
_OCDC_REPO_CONFIG_LOADED=1

# =============================================================================
# Module Loading
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source paths for directory constants
if [[ -z "${OCDC_CONFIG_DIR:-}" ]]; then
  if [[ -f "${SCRIPT_DIR}/ocdc-paths.bash" ]]; then
    source "${SCRIPT_DIR}/ocdc-paths.bash"
  fi
  OCDC_CONFIG_DIR="${OCDC_CONFIG_DIR:-$HOME/.config/ocdc}"
fi

# Source YAML utilities
source "${SCRIPT_DIR}/ocdc-yaml.bash"

# Default repos file path
OCDC_REPOS_FILE="${OCDC_REPOS_FILE:-${OCDC_CONFIG_DIR}/repos.yaml}"

# =============================================================================
# Default Configuration Values
# =============================================================================

# Get default repo configuration as JSON
_repo_config_defaults() {
  cat << 'EOF'
{
  "wip_limits": {
    "max_concurrent": 3
  },
  "readiness": {
    "labels": {
      "required": [],
      "any_of": [],
      "exclude": []
    },
    "priority": {
      "labels": [],
      "age_weight": 1
    },
    "dependencies": {
      "check_body_references": true,
      "check_github_dependencies": false,
      "blocking_labels": ["blocked"]
    }
  },
  "comments": {
    "on_start": false,
    "on_pr_created": false
  }
}
EOF
}

# =============================================================================
# Config Loading Functions
# =============================================================================

# Load the entire repos configuration file
# Returns: JSON object with all repos
# Usage: config=$(repo_config_load)
repo_config_load() {
  if [[ ! -f "$OCDC_REPOS_FILE" ]]; then
    echo '{"repos":{}}'
    return 0
  fi
  
  _yaml_to_json "$OCDC_REPOS_FILE"
}

# Get configuration for a specific repo
# Usage: config=$(repo_config_get "owner/repo")
# Returns: JSON object for the repo, or empty/null if not found
repo_config_get() {
  local repo_key="$1"
  
  if [[ ! -f "$OCDC_REPOS_FILE" ]]; then
    echo ""
    return 0
  fi
  
  local result
  result=$(_yaml_to_json "$OCDC_REPOS_FILE" | jq -c --arg key "$repo_key" '.repos[$key] // empty')
  
  if [[ -z "$result" ]] || [[ "$result" == "null" ]]; then
    echo ""
    return 0
  fi
  
  echo "$result"
}

# Get configuration for a specific repo with defaults applied
# Usage: config=$(repo_config_get_with_defaults "owner/repo")
# Returns: JSON object with defaults merged
repo_config_get_with_defaults() {
  local repo_key="$1"
  
  local defaults
  defaults=$(_repo_config_defaults)
  
  local config
  config=$(repo_config_get "$repo_key")
  
  if [[ -z "$config" ]]; then
    echo "$defaults"
    return 0
  fi
  
  # Deep merge using jq's recursive object merge
  # The * operator does shallow merge, so we use reduce for deep merge
  jq -n --argjson defaults "$defaults" --argjson config "$config" '
    def deep_merge:
      . as $merged |
      if type == "array" then
        if (.[0] | type) == "object" and (.[1] | type) == "object" then
          [.[0], .[1]] | add |
          with_entries(
            if (.value | type) == "object" then
              .value = ([($merged[0][.key] // {}), ($merged[1][.key] // {})] | deep_merge)
            elif ($merged[1][.key] // null) != null then
              .value = $merged[1][.key]
            else
              .
            end
          )
        else .[1] // .[0]
        end
      else .
      end;
    [$defaults, $config] | deep_merge
  '
}

# List all configured repos
# Usage: repos=$(repo_config_list)
# Returns: newline-separated list of repo keys
repo_config_list() {
  if [[ ! -f "$OCDC_REPOS_FILE" ]]; then
    return 0
  fi
  
  _yaml_to_json "$OCDC_REPOS_FILE" | jq -r '.repos | keys[]' 2>/dev/null
}

# =============================================================================
# Path Resolution Functions
# =============================================================================

# Expand ~ to $HOME in a path
_expand_path() {
  local path="$1"
  echo "${path/#\~/$HOME}"
}

# Find repo key by local filesystem path
# Usage: repo_key=$(repo_config_find_by_path "/path/to/repo")
# Returns: repo key or empty if not found
repo_config_find_by_path() {
  local search_path="$1"
  
  if [[ ! -f "$OCDC_REPOS_FILE" ]]; then
    echo ""
    return 0
  fi
  
  # Normalize search path
  local normalized_search
  normalized_search=$(cd "$search_path" 2>/dev/null && pwd -P) || normalized_search="$search_path"
  
  # Search through all repos
  local repos_json
  repos_json=$(_yaml_to_json "$OCDC_REPOS_FILE")
  
  local repo_key
  while IFS= read -r repo_key; do
    [[ -z "$repo_key" ]] && continue
    
    local repo_path
    repo_path=$(echo "$repos_json" | jq -r --arg key "$repo_key" '.repos[$key].repo_path // empty')
    [[ -z "$repo_path" ]] && continue
    
    # Expand and normalize repo path
    local expanded_path
    expanded_path=$(_expand_path "$repo_path")
    local normalized_repo_path
    normalized_repo_path=$(cd "$expanded_path" 2>/dev/null && pwd -P) || normalized_repo_path="$expanded_path"
    
    if [[ "$normalized_search" == "$normalized_repo_path" ]]; then
      echo "$repo_key"
      return 0
    fi
  done < <(echo "$repos_json" | jq -r '.repos | keys[]' 2>/dev/null)
  
  echo ""
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate the repos configuration file
# Usage: repo_config_validate
# Returns: 0 if valid, 1 if invalid
repo_config_validate() {
  local config_file="${1:-$OCDC_REPOS_FILE}"
  
  if [[ ! -f "$config_file" ]]; then
    # No config file is valid (empty config)
    return 0
  fi
  
  # Check YAML can be parsed
  if ! _yaml_to_json "$config_file" > /dev/null 2>&1; then
    echo "Error: Failed to parse YAML: $config_file" >&2
    return 1
  fi
  
  # Check structure
  local repos_json
  repos_json=$(_yaml_to_json "$config_file")
  
  # Must have 'repos' key
  if ! echo "$repos_json" | jq -e '.repos' >/dev/null 2>&1; then
    echo "Error: Missing 'repos' key in $config_file" >&2
    return 1
  fi
  
  # Each repo must have repo_path
  local missing_paths
  missing_paths=$(echo "$repos_json" | jq -r '
    .repos | to_entries[] | 
    select(.value.repo_path == null or .value.repo_path == "") |
    .key
  ' 2>/dev/null)
  
  if [[ -n "$missing_paths" ]]; then
    echo "Error: Repos missing repo_path: $missing_paths" >&2
    return 1
  fi
  
  return 0
}

# =============================================================================
# Exports
# =============================================================================

export OCDC_REPOS_FILE
