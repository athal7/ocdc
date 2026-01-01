#!/usr/bin/env bash
#
# Tests for poll configuration schema and validation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing poll configuration..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create polls directory
  export OCDC_POLLS_DIR="$TEST_CONFIG_DIR/polls"
  mkdir -p "$OCDC_POLLS_DIR"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Helper to create test config files
# =============================================================================

create_valid_github_config() {
  cat > "$OCDC_POLLS_DIR/github-reviews.yaml" << 'EOF'
id: github-reviews
source: github-search
enabled: true

config:
  query: "is:pr is:open review-requested:@me"

filters:
  repos:
    allow:
      - "myorg/*"
    deny:
      - "myorg/archived-*"
  labels:
    deny:
      - "wip"
      - "draft"

key_template: "{repo}-pr-{number}"
clone_name_template: "pr-{number}"
branch_template: "{head_ref}"

repo_source:
  strategy: auto

prompt:
  template: |
    You are working in a devcontainer at {workspace} on branch {branch}.
    
    Review PR #{number}: {title}
    URL: {source_url}
    
    Please review the changes and provide feedback.

session:
  name_template: "ocdc-{key}"
  agent: review

cleanup:
  on:
    - merged
    - closed
  delay: 5m
EOF
}

create_minimal_config() {
  cat > "$OCDC_POLLS_DIR/minimal.yaml" << 'EOF'
id: minimal
source: github-search
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

prompt:
  template: "Review PR #{number}"

session:
  name_template: "ocdc-{key}"
EOF
}

create_config_with_prompt_file() {
  mkdir -p "$OCDC_POLLS_DIR/prompts"
  cat > "$OCDC_POLLS_DIR/prompts/review.md" << 'EOF'
Review PR #{number}: {title}

Repository: {repo}
URL: {source_url}
EOF

  cat > "$OCDC_POLLS_DIR/with-prompt-file.yaml" << 'EOF'
id: with-prompt-file
source: github-search
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

prompt:
  file: prompts/review.md

session:
  name_template: "ocdc-{key}"
EOF
}

create_invalid_config_missing_id() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-id.yaml" << 'EOF'
source: github-search
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

prompt:
  template: "Review PR"

session:
  name_template: "ocdc-{key}"
EOF
}

create_invalid_config_missing_source() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-source.yaml" << 'EOF'
id: invalid-missing-source
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

prompt:
  template: "Review PR"

session:
  name_template: "ocdc-{key}"
EOF
}

create_invalid_config_missing_prompt() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-prompt.yaml" << 'EOF'
id: invalid-missing-prompt
source: github-search
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

session:
  name_template: "ocdc-{key}"
EOF
}

create_invalid_config_missing_session() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-session.yaml" << 'EOF'
id: invalid-missing-session
source: github-search
enabled: true

config:
  query: "is:pr is:open"

key_template: "{repo}-pr-{number}"
branch_template: "{head_ref}"

prompt:
  template: "Review PR"
EOF
}

create_linear_config() {
  cat > "$OCDC_POLLS_DIR/linear-assigned.yaml" << 'EOF'
id: linear-assigned
source: linear
enabled: false

config:
  filter:
    assignee: "@me"
    state:
      type:
        in:
          - started
          - unstarted

filters:
  labels:
    deny:
      - "blocked"
      - "needs-design"

key_template: "{team}-{identifier}"
clone_name_template: "linear-{identifier}"
branch_template: "{identifier}"

repo_source:
  strategy: map
  mapping:
    "team:ENG": "~/Projects/api"
    "team:WEB": "~/Projects/web"
  default: "~/Projects/main"

prompt:
  template: |
    Work on this Linear issue:

    **[{identifier}] {title}**
    {url}

    {description}

session:
  name_template: "ocdc-linear-{identifier}"
  agent: dev

cleanup:
  on:
    - completed
    - canceled
  delay: 5m
EOF
}

# =============================================================================
# Tests
# =============================================================================

test_poll_config_library_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-poll-config.bash" ]]; then
    echo "lib/ocdc-poll-config.bash does not exist"
    return 1
  fi
  return 0
}

test_poll_config_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-poll-config.bash" 2>&1; then
    echo "Failed to source ocdc-poll-config.bash"
    return 1
  fi
  return 0
}

test_validate_valid_github_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/github-reviews.yaml"; then
    echo "Valid config should pass validation"
    return 1
  fi
  return 0
}

test_validate_minimal_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_minimal_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/minimal.yaml"; then
    echo "Minimal valid config should pass validation"
    return 1
  fi
  return 0
}

test_validate_config_with_prompt_file() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_prompt_file
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/with-prompt-file.yaml"; then
    echo "Config with prompt file should pass validation"
    return 1
  fi
  return 0
}

test_validate_linear_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_linear_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/linear-assigned.yaml"; then
    echo "Valid Linear config should pass validation"
    return 1
  fi
  return 0
}

test_validate_rejects_missing_id() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_id
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-id.yaml" 2>/dev/null; then
    echo "Config missing 'id' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_missing_source() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_source
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-source.yaml" 2>/dev/null; then
    echo "Config missing 'source' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_missing_prompt() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_prompt
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-prompt.yaml" 2>/dev/null; then
    echo "Config missing 'prompt' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_missing_session() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_session
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-session.yaml" 2>/dev/null; then
    echo "Config missing 'session' should fail validation"
    return 1
  fi
  return 0
}

test_get_config_field() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config
  
  local id
  id=$(poll_config_get "$OCDC_POLLS_DIR/github-reviews.yaml" ".id")
  assert_equals "github-reviews" "$id"
}

test_get_config_nested_field() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config
  
  local query
  query=$(poll_config_get "$OCDC_POLLS_DIR/github-reviews.yaml" ".config.query")
  assert_equals "is:pr is:open review-requested:@me" "$query"
}

test_get_config_enabled_defaults_to_true() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_minimal_config
  
  local enabled
  enabled=$(poll_config_get_with_default "$OCDC_POLLS_DIR/minimal.yaml" ".enabled" "true")
  assert_equals "true" "$enabled"
}

test_list_all_configs() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config
  create_linear_config
  
  local configs
  configs=$(poll_config_list "$OCDC_POLLS_DIR")
  
  # Should find both configs
  if [[ "$configs" != *"github-reviews.yaml"* ]]; then
    echo "Should list github-reviews.yaml"
    return 1
  fi
  if [[ "$configs" != *"linear-assigned.yaml"* ]]; then
    echo "Should list linear-assigned.yaml"
    return 1
  fi
  return 0
}

test_list_enabled_configs_only() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config  # enabled: true
  create_linear_config         # enabled: false
  
  local configs
  configs=$(poll_config_list_enabled "$OCDC_POLLS_DIR")
  
  # Should only find enabled config
  if [[ "$configs" != *"github-reviews.yaml"* ]]; then
    echo "Should list enabled github-reviews.yaml"
    return 1
  fi
  if [[ "$configs" == *"linear-assigned.yaml"* ]]; then
    echo "Should not list disabled linear-assigned.yaml"
    return 1
  fi
  return 0
}

test_render_template_simple() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="PR #{number}: {title}"
  local result
  result=$(poll_config_render_template "$template" number=123 title="Add feature")
  
  assert_equals "PR #123: Add feature" "$result"
}

test_render_template_multiple_vars() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="Working on {repo} branch {branch} at {workspace}"
  local result
  result=$(poll_config_render_template "$template" \
    repo="myorg/api" \
    branch="feature-x" \
    workspace="/path/to/clone")
  
  assert_equals "Working on myorg/api branch feature-x at /path/to/clone" "$result"
}

test_render_template_preserves_unknown_vars() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="Known: {known}, Unknown: {unknown}"
  local result
  result=$(poll_config_render_template "$template" known="value")
  
  assert_equals "Known: value, Unknown: {unknown}" "$result"
}

test_load_prompt_from_template() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_config
  
  local prompt
  prompt=$(poll_config_get_prompt "$OCDC_POLLS_DIR/github-reviews.yaml")
  
  if [[ "$prompt" != *"working in a devcontainer"* ]]; then
    echo "Should load prompt template"
    return 1
  fi
  return 0
}

test_load_prompt_from_file() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_prompt_file
  
  local prompt
  prompt=$(poll_config_get_prompt "$OCDC_POLLS_DIR/with-prompt-file.yaml")
  
  if [[ "$prompt" != *"Review PR #{number}"* ]]; then
    echo "Should load prompt from file"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Poll Configuration Tests:"

for test_func in \
  test_poll_config_library_exists \
  test_poll_config_can_be_sourced \
  test_validate_valid_github_config \
  test_validate_minimal_config \
  test_validate_config_with_prompt_file \
  test_validate_linear_config \
  test_validate_rejects_missing_id \
  test_validate_rejects_missing_source \
  test_validate_rejects_missing_prompt \
  test_validate_rejects_missing_session \
  test_get_config_field \
  test_get_config_nested_field \
  test_get_config_enabled_defaults_to_true \
  test_list_all_configs \
  test_list_enabled_configs_only \
  test_render_template_simple \
  test_render_template_multiple_vars \
  test_render_template_preserves_unknown_vars \
  test_load_prompt_from_template \
  test_load_prompt_from_file
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
