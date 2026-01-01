#!/usr/bin/env bash
#
# ocdc-poll-config.bash - Poll configuration schema and validation
#
# This library provides functions for loading, validating, and working
# with poll configuration files.
#
# Usage:
#   source "$(dirname "$0")/ocdc-poll-config.bash"
#   poll_config_validate "/path/to/config.yaml"
#
# Required: ruby (for YAML parsing), jq (for JSON manipulation)

# Source paths for OCDC_POLLS_DIR if available
if [[ -z "${OCDC_POLLS_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/ocdc-paths.bash" ]]; then
    source "${SCRIPT_DIR}/ocdc-paths.bash"
  fi
  OCDC_POLLS_DIR="${OCDC_POLLS_DIR:-${OCDC_CONFIG_DIR:-$HOME/.config/ocdc}/polls}"
fi

# =============================================================================
# YAML to JSON conversion
# =============================================================================

# Convert YAML file to JSON using Ruby's built-in YAML support
# Outputs directly to stdout - pipe to jq for processing
# Usage: _yaml_to_json "/path/to/file.yaml"
_yaml_to_json() {
  local yaml_file="$1"
  
  if [[ ! -f "$yaml_file" ]]; then
    echo "Error: File not found: $yaml_file" >&2
    return 1
  fi
  
  ruby -ryaml -rjson -e "puts JSON.generate(YAML.load_file('$yaml_file'))" 2>/dev/null
}

# Get a field from YAML file using jq path
# Pipes directly from ruby to jq to avoid bash variable issues with multiline strings
# Usage: _yaml_get "/path/to/file.yaml" ".field.subfield"
_yaml_get() {
  local yaml_file="$1"
  local jq_path="$2"
  
  if [[ ! -f "$yaml_file" ]]; then
    echo "Error: File not found: $yaml_file" >&2
    return 1
  fi
  
  # Pipe directly to avoid bash variable issues with multiline JSON strings
  ruby -ryaml -rjson -e "puts JSON.generate(YAML.load_file('$yaml_file'))" 2>/dev/null | \
    jq -r "$jq_path | if . == null then empty else . end" 2>/dev/null
}

# Get a field from YAML with a default value
# Usage: _yaml_get_default "/path/to/file.yaml" ".field" "default"
_yaml_get_default() {
  local yaml_file="$1"
  local jq_path="$2"
  local default="$3"
  
  local value
  value=$(_yaml_get "$yaml_file" "$jq_path")
  
  if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# =============================================================================
# Schema Validation
# =============================================================================

# Required fields for a valid poll configuration
_POLL_REQUIRED_FIELDS=(
  "id"
  "source"
  "key_template"
  "branch_template"
  "prompt"
  "session"
)

# Validate a poll configuration file
# Returns 0 if valid, 1 if invalid
# Usage: poll_config_validate "/path/to/config.yaml"
poll_config_validate() {
  local config_file="$1"
  local errors=()
  
  # Check file exists
  if [[ ! -f "$config_file" ]]; then
    echo "Error: Config file not found: $config_file" >&2
    return 1
  fi
  
  # Check YAML can be parsed
  if ! _yaml_to_json "$config_file" > /dev/null 2>&1; then
    echo "Error: Failed to parse YAML: $config_file" >&2
    return 1
  fi
  
  # Check required fields using direct piping
  for field in "${_POLL_REQUIRED_FIELDS[@]}"; do
    local value
    value=$(_yaml_get "$config_file" ".$field")
    if [[ -z "$value" ]]; then
      errors+=("Missing required field: $field")
    fi
  done
  
  # Validate prompt has either template or file
  local prompt_template prompt_file
  prompt_template=$(_yaml_get "$config_file" ".prompt.template")
  prompt_file=$(_yaml_get "$config_file" ".prompt.file")
  
  if [[ -z "$prompt_template" ]] && [[ -z "$prompt_file" ]]; then
    errors+=("prompt must have either 'template' or 'file'")
  fi
  
  # If prompt.file is specified, check it exists (relative to config dir)
  if [[ -n "$prompt_file" ]]; then
    local config_dir
    config_dir=$(dirname "$config_file")
    local full_prompt_path="$config_dir/$prompt_file"
    if [[ ! -f "$full_prompt_path" ]]; then
      errors+=("Prompt file not found: $prompt_file (looked in $full_prompt_path)")
    fi
  fi
  
  # Validate session has name_template
  local session_name
  session_name=$(_yaml_get "$config_file" ".session.name_template")
  if [[ -z "$session_name" ]]; then
    errors+=("session must have 'name_template'")
  fi
  
  # Validate source is a known type
  local source
  source=$(_yaml_get "$config_file" ".source")
  case "$source" in
    github-search|linear)
      # Valid sources
      ;;
    *)
      if [[ -n "$source" ]]; then
        errors+=("Unknown source type: $source (expected: github-search, linear)")
      fi
      ;;
  esac
  
  # Report errors
  if [[ ${#errors[@]} -gt 0 ]]; then
    echo "Validation errors in $config_file:" >&2
    for error in "${errors[@]}"; do
      echo "  - $error" >&2
    done
    return 1
  fi
  
  return 0
}

# =============================================================================
# Config Access Functions
# =============================================================================

# Get a field from a poll config file
# Usage: poll_config_get "/path/to/config.yaml" ".field.path"
poll_config_get() {
  local config_file="$1"
  local jq_path="$2"
  
  _yaml_get "$config_file" "$jq_path"
}

# Get a field from a poll config with a default value
# Usage: poll_config_get_with_default "/path/to/config.yaml" ".field" "default"
poll_config_get_with_default() {
  local config_file="$1"
  local jq_path="$2"
  local default="$3"
  
  _yaml_get_default "$config_file" "$jq_path" "$default"
}

# Get the prompt content from a config (handles both template and file)
# Usage: poll_config_get_prompt "/path/to/config.yaml"
poll_config_get_prompt() {
  local config_file="$1"
  
  # Check for inline template first
  local template
  template=$(_yaml_get "$config_file" ".prompt.template")
  
  if [[ -n "$template" ]]; then
    echo "$template"
    return 0
  fi
  
  # Check for file reference
  local prompt_file
  prompt_file=$(_yaml_get "$config_file" ".prompt.file")
  
  if [[ -n "$prompt_file" ]]; then
    local config_dir
    config_dir=$(dirname "$config_file")
    local full_path="$config_dir/$prompt_file"
    
    if [[ -f "$full_path" ]]; then
      cat "$full_path"
      return 0
    else
      echo "Error: Prompt file not found: $full_path" >&2
      return 1
    fi
  fi
  
  echo "Error: No prompt template or file specified" >&2
  return 1
}

# =============================================================================
# Config Listing Functions
# =============================================================================

# List all config files in a directory
# Usage: poll_config_list "/path/to/polls/dir"
poll_config_list() {
  local polls_dir="${1:-$OCDC_POLLS_DIR}"
  
  if [[ ! -d "$polls_dir" ]]; then
    return 0
  fi
  
  find "$polls_dir" -maxdepth 1 -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
    while read -r file; do
      basename "$file"
    done
}

# List only enabled config files
# Usage: poll_config_list_enabled "/path/to/polls/dir"
poll_config_list_enabled() {
  local polls_dir="${1:-$OCDC_POLLS_DIR}"
  
  if [[ ! -d "$polls_dir" ]]; then
    return 0
  fi
  
  for file in "$polls_dir"/*.yaml "$polls_dir"/*.yml; do
    [[ -f "$file" ]] || continue
    local enabled
    enabled=$(_yaml_get_default "$file" ".enabled" "true")
    # Handle both string "true" and boolean true from YAML
    if [[ "$enabled" == "true" ]]; then
      basename "$file"
    fi
  done
}

# =============================================================================
# Template Rendering
# =============================================================================

# Render a template string with variable substitutions
# Usage: poll_config_render_template "template {var}" var=value var2=value2
poll_config_render_template() {
  local template="$1"
  shift
  
  local result="$template"
  
  # Process each var=value argument
  for arg in "$@"; do
    local var="${arg%%=*}"
    local value="${arg#*=}"
    
    # Replace {var} with value
    result="${result//\{$var\}/$value}"
  done
  
  echo "$result"
}

# =============================================================================
# Exports
# =============================================================================

export OCDC_POLLS_DIR
