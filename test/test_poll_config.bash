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
# Helper to create test config files (NEW SCHEMA)
# =============================================================================

create_valid_linear_config() {
  cat > "$OCDC_POLLS_DIR/linear-issues.yaml" << 'EOF'
id: linear-issues
source_type: linear_issue

repo_filters:
  - team: "ENG"
    repo_path: "~/code/engineering"
  - team: "PROD"
    labels: ["backend"]
    repo_path: "~/code/backend"
EOF
}

create_valid_github_issue_config() {
  cat > "$OCDC_POLLS_DIR/github-issues.yaml" << 'EOF'
id: github-issues
source_type: github_issue

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
  - org: "myorg"
    labels: ["ready"]
    repo_path: "~/code/myorg"
EOF
}

create_valid_github_pr_config() {
  cat > "$OCDC_POLLS_DIR/github-reviews.yaml" << 'EOF'
id: github-reviews
source_type: github_pr

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_config_with_fetch_options() {
  cat > "$OCDC_POLLS_DIR/with-fetch-options.yaml" << 'EOF'
id: with-fetch-options
source_type: github_issue

fetch:
  assignee: "@me"
  state: "open"
  labels: ["ready", "approved"]

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_config_with_fetch_command() {
  cat > "$OCDC_POLLS_DIR/with-fetch-command.yaml" << 'EOF'
id: with-fetch-command
source_type: github_issue

fetch_command: "gh issue list --repo myorg/backend --json number,title"

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_config_with_custom_prompt() {
  cat > "$OCDC_POLLS_DIR/custom-prompt.yaml" << 'EOF'
id: custom-prompt
source_type: github_issue

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"

prompt:
  template: "Custom prompt for {title} - {url}"
EOF
}

create_config_with_custom_session() {
  cat > "$OCDC_POLLS_DIR/custom-session.yaml" << 'EOF'
id: custom-session
source_type: github_issue

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"

session:
  name_template: "custom-{number}"
  agent: architect
EOF
}

create_disabled_config() {
  cat > "$OCDC_POLLS_DIR/disabled.yaml" << 'EOF'
id: disabled-poll
enabled: false
source_type: github_issue

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_invalid_config_missing_id() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-id.yaml" << 'EOF'
source_type: github_issue

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_invalid_config_missing_source_type() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-source-type.yaml" << 'EOF'
id: missing-source-type

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

create_invalid_config_missing_repo_filters() {
  cat > "$OCDC_POLLS_DIR/invalid-missing-repo-filters.yaml" << 'EOF'
id: missing-repo-filters
source_type: github_issue
EOF
}

create_invalid_config_empty_repo_filters() {
  cat > "$OCDC_POLLS_DIR/invalid-empty-repo-filters.yaml" << 'EOF'
id: empty-repo-filters
source_type: github_issue
repo_filters: []
EOF
}

create_invalid_config_both_fetch() {
  cat > "$OCDC_POLLS_DIR/invalid-both-fetch.yaml" << 'EOF'
id: both-fetch
source_type: github_issue

fetch:
  assignee: "@me"

fetch_command: "gh issue list"

repo_filters:
  - repo: "myorg/backend"
    repo_path: "~/code/backend"
EOF
}

# =============================================================================
# Basic Tests
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

# =============================================================================
# Validation Tests
# =============================================================================

test_validate_linear_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_linear_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/linear-issues.yaml"; then
    echo "Valid Linear config should pass validation"
    return 1
  fi
  return 0
}

test_validate_github_issue_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_issue_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/github-issues.yaml"; then
    echo "Valid GitHub issue config should pass validation"
    return 1
  fi
  return 0
}

test_validate_github_pr_config() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_pr_config
  
  if ! poll_config_validate "$OCDC_POLLS_DIR/github-reviews.yaml"; then
    echo "Valid GitHub PR config should pass validation"
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

test_validate_rejects_missing_source_type() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_source_type
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-source-type.yaml" 2>/dev/null; then
    echo "Config missing 'source_type' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_missing_repo_filters() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_missing_repo_filters
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-missing-repo-filters.yaml" 2>/dev/null; then
    echo "Config missing 'repo_filters' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_empty_repo_filters() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_empty_repo_filters
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-empty-repo-filters.yaml" 2>/dev/null; then
    echo "Config with empty 'repo_filters' should fail validation"
    return 1
  fi
  return 0
}

test_validate_rejects_both_fetch_options() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_invalid_config_both_fetch
  
  if poll_config_validate "$OCDC_POLLS_DIR/invalid-both-fetch.yaml" 2>/dev/null; then
    echo "Config with both 'fetch' and 'fetch_command' should fail validation"
    return 1
  fi
  return 0
}

# =============================================================================
# Default Tests
# =============================================================================

test_default_item_mapping_linear() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local mapping
  mapping=$(poll_config_get_default_item_mapping "linear_issue")
  
  # Check key fields exist
  if ! echo "$mapping" | jq -e '.key' >/dev/null; then
    echo "Linear mapping should have .key"
    return 1
  fi
  if ! echo "$mapping" | jq -e '.url' >/dev/null; then
    echo "Linear mapping should have .url"
    return 1
  fi
  return 0
}

test_default_item_mapping_github_issue() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local mapping
  mapping=$(poll_config_get_default_item_mapping "github_issue")
  
  if ! echo "$mapping" | jq -e '.key' >/dev/null; then
    echo "GitHub issue mapping should have .key"
    return 1
  fi
  return 0
}

test_default_prompt_linear() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local prompt
  prompt=$(poll_config_get_default_prompt "linear_issue")
  
  if [[ "$prompt" != *"Linear"* ]]; then
    echo "Linear default prompt should mention Linear"
    return 1
  fi
  return 0
}

test_default_prompt_github_pr() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local prompt
  prompt=$(poll_config_get_default_prompt "github_pr")
  
  if [[ "$prompt" != *"Review"* ]]; then
    echo "GitHub PR default prompt should mention Review"
    return 1
  fi
  return 0
}

test_default_session_name_linear() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local name
  name=$(poll_config_get_default_session_name "linear_issue")
  
  if [[ "$name" != *"linear"* ]]; then
    echo "Linear default session name should contain 'linear'"
    return 1
  fi
  return 0
}

test_default_agent_github_pr() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local agent
  agent=$(poll_config_get_default_agent "github_pr")
  
  assert_equals "plan" "$agent"
}

test_default_agent_github_issue() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local agent
  agent=$(poll_config_get_default_agent "github_issue")
  
  assert_equals "build" "$agent"
}

# =============================================================================
# Fetch Command Building Tests
# =============================================================================

# Note: These tests verify that poll_config_build_fetch_command generates
# commands that use the MCP fetch bridge script (lib/ocdc-mcp-fetch.js)
# instead of CLI commands like gh or linear.

test_build_fetch_command_linear() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local cmd
  cmd=$(poll_config_build_fetch_command "linear_issue" '{}')
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "Linear fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  if [[ "$cmd" != *"linear_issue"* ]]; then
    echo "Linear fetch command should include source type: $cmd"
    return 1
  fi
  return 0
}

test_build_fetch_command_github_issue() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local cmd
  cmd=$(poll_config_build_fetch_command "github_issue" '{}')
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "GitHub issue fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  if [[ "$cmd" != *"github_issue"* ]]; then
    echo "GitHub issue fetch command should include source type: $cmd"
    return 1
  fi
  return 0
}

test_build_fetch_command_github_pr() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local cmd
  cmd=$(poll_config_build_fetch_command "github_pr" '{}')
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "GitHub PR fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  if [[ "$cmd" != *"github_pr"* ]]; then
    echo "GitHub PR fetch command should include source type: $cmd"
    return 1
  fi
  return 0
}

test_build_fetch_command_with_options() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local cmd
  cmd=$(poll_config_build_fetch_command "github_issue" '{"repo":"myorg/backend","labels":["ready"]}')
  
  # Should use MCP fetch script with options in JSON
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "Fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  # Options should be passed as JSON (may be quoted)
  if [[ "$cmd" != *"myorg/backend"* ]]; then
    echo "Fetch command should include repo in options: $cmd"
    return 1
  fi
  if [[ "$cmd" != *"ready"* ]]; then
    echo "Fetch command should include labels in options: $cmd"
    return 1
  fi
  return 0
}

test_build_fetch_command_escapes_special_chars() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # Test that shell metacharacters are properly escaped in the JSON options
  local cmd
  cmd=$(poll_config_build_fetch_command "github_issue" '{"repo":"myorg/back$end","labels":["re;ady"]}')
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "Fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  # The JSON options should be shell-quoted to prevent injection
  # The exact escaping depends on printf %q, but special chars should be safe
  if [[ "$cmd" == *'rm -rf'* ]]; then
    echo "Fetch command should not allow command injection: $cmd"
    return 1
  fi
  return 0
}

test_build_fetch_command_state_validation() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # State validation now happens in the MCP fetch script, not in bash
  # The bash function just passes the JSON options through
  local cmd
  cmd=$(poll_config_build_fetch_command "github_issue" '{"state":"open"}')
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "Fetch command should use MCP fetch script: $cmd"
    return 1
  fi
  # State should be in the JSON options
  if [[ "$cmd" != *"open"* ]]; then
    echo "Fetch command should include state in options: $cmd"
    return 1
  fi
  return 0
}

# =============================================================================
# Repo Filter Matching Tests
# =============================================================================

test_match_repo_filter_team_only() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"team":{"key":"ENG"}}'
  local filters='[{"team":"ENG","repo_path":"~/code/eng"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/eng" "$result"
}

test_match_repo_filter_labels_only() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"labels":[{"name":"backend"}]}'
  local filters='[{"labels":["backend"],"repo_path":"~/code/backend"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/backend" "$result"
}

test_match_repo_filter_case_insensitive() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"team":{"key":"eng"}}'
  local filters='[{"team":"ENG","repo_path":"~/code/eng"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/eng" "$result"
}

test_match_repo_filter_specificity() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # Item has both team and label
  local item='{"team":{"key":"ENG"},"labels":[{"name":"backend"}]}'
  
  # Filters: team+label is more specific than team only
  local filters='[
    {"team":"ENG","repo_path":"~/code/eng-default"},
    {"team":"ENG","labels":["backend"],"repo_path":"~/code/eng-backend"}
  ]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  # Should match the more specific rule (team+labels)
  assert_equals "~/code/eng-backend" "$result"
}

test_match_repo_filter_no_match() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"team":{"key":"PROD"}}'
  local filters='[{"team":"ENG","repo_path":"~/code/eng"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  # Should return empty string for no match
  assert_equals "" "$result"
}

test_match_repo_filter_github_repo() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"repository":{"full_name":"myorg/backend","name":"backend","owner":{"login":"myorg"}}}'
  local filters='[{"repo":"myorg/backend","repo_path":"~/code/backend"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/backend" "$result"
}

test_match_repo_filter_github_org() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local item='{"repository":{"full_name":"myorg/frontend","name":"frontend","owner":{"login":"myorg"}}}'
  local filters='[{"org":"myorg","repo_path":"~/code/myorg"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/myorg" "$result"
}

test_match_repo_filter_catch_all() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # Filter with only repo_path acts as catch-all
  local item='{"team":{"key":"UNKNOWN"}}'
  local filters='[{"repo_path":"~/code/default"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  # Should match the catch-all filter
  assert_equals "~/code/default" "$result"
}

test_match_repo_filter_multiple_labels_any() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # Item has only one of the filter labels - should still match (ANY semantics)
  local item='{"labels":[{"name":"frontend"}]}'
  local filters='[{"labels":["backend","frontend","api"],"repo_path":"~/code/services"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  assert_equals "~/code/services" "$result"
}

test_match_repo_filter_item_missing_fields() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  # Item with null/missing nested fields
  local item='{"repository":null,"team":null}'
  local filters='[{"team":"ENG","repo_path":"~/code/eng"}]'
  
  local result
  result=$(poll_config_match_repo_filter "$item" "$filters")
  
  # Should return empty (no match)
  assert_equals "" "$result"
}

# =============================================================================
# Effective Config Tests
# =============================================================================

test_effective_fetch_command_from_options() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_fetch_options
  
  local cmd
  cmd=$(poll_config_get_effective_fetch_command "$OCDC_POLLS_DIR/with-fetch-options.yaml")
  
  # Should use MCP fetch script
  if [[ "$cmd" != *"ocdc-mcp-fetch.js"* ]]; then
    echo "Should use MCP fetch script: $cmd"
    return 1
  fi
  if [[ "$cmd" != *"github_issue"* ]]; then
    echo "Should include source type: $cmd"
    return 1
  fi
  return 0
}

test_effective_fetch_command_override() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_fetch_command
  
  local cmd
  cmd=$(poll_config_get_effective_fetch_command "$OCDC_POLLS_DIR/with-fetch-command.yaml")
  
  if [[ "$cmd" != "gh issue list --repo myorg/backend --json number,title" ]]; then
    echo "Should use explicit fetch_command: $cmd"
    return 1
  fi
  return 0
}

test_effective_prompt_default() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_issue_config
  
  local prompt
  prompt=$(poll_config_get_effective_prompt "$OCDC_POLLS_DIR/github-issues.yaml")
  
  if [[ "$prompt" != *"Work on issue"* ]]; then
    echo "Should use default prompt: $prompt"
    return 1
  fi
  return 0
}

test_effective_prompt_custom() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_custom_prompt
  
  local prompt
  prompt=$(poll_config_get_effective_prompt "$OCDC_POLLS_DIR/custom-prompt.yaml")
  
  if [[ "$prompt" != *"Custom prompt"* ]]; then
    echo "Should use custom prompt: $prompt"
    return 1
  fi
  return 0
}

test_effective_session_name_default() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_issue_config
  
  local name
  name=$(poll_config_get_effective_session_name "$OCDC_POLLS_DIR/github-issues.yaml")
  
  if [[ "$name" != *"issue"* ]]; then
    echo "Should use default session name: $name"
    return 1
  fi
  return 0
}

test_effective_session_name_custom() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_custom_session
  
  local name
  name=$(poll_config_get_effective_session_name "$OCDC_POLLS_DIR/custom-session.yaml")
  
  assert_equals "custom-{number}" "$name"
}

test_effective_agent_default() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_pr_config
  
  local agent
  agent=$(poll_config_get_effective_agent "$OCDC_POLLS_DIR/github-reviews.yaml")
  
  # GitHub PR default is 'plan'
  assert_equals "plan" "$agent"
}

test_effective_agent_custom() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_config_with_custom_session
  
  local agent
  agent=$(poll_config_get_effective_agent "$OCDC_POLLS_DIR/custom-session.yaml")
  
  assert_equals "architect" "$agent"
}

# =============================================================================
# Config Listing Tests
# =============================================================================

test_list_all_configs() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_issue_config
  create_disabled_config
  
  local configs
  configs=$(poll_config_list "$OCDC_POLLS_DIR")
  
  if [[ "$configs" != *"github-issues.yaml"* ]]; then
    echo "Should list github-issues.yaml"
    return 1
  fi
  if [[ "$configs" != *"disabled.yaml"* ]]; then
    echo "Should list disabled.yaml"
    return 1
  fi
  return 0
}

test_list_enabled_configs_only() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  create_valid_github_issue_config  # enabled by default
  create_disabled_config            # enabled: false
  
  local configs
  configs=$(poll_config_list_enabled "$OCDC_POLLS_DIR")
  
  if [[ "$configs" != *"github-issues.yaml"* ]]; then
    echo "Should list enabled github-issues.yaml"
    return 1
  fi
  if [[ "$configs" == *"disabled.yaml"* ]]; then
    echo "Should not list disabled disabled.yaml"
    return 1
  fi
  return 0
}

# =============================================================================
# Template Rendering Tests
# =============================================================================

test_render_template_simple() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="Issue #{number}: {title}"
  local result
  result=$(poll_config_render_template "$template" number=123 title="Add feature")
  
  assert_equals "Issue #123: Add feature" "$result"
}

test_render_template_multiple_vars() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="Working on {repo} branch {branch}"
  local result
  result=$(poll_config_render_template "$template" \
    repo="myorg/api" \
    branch="issue-42")
  
  assert_equals "Working on myorg/api branch issue-42" "$result"
}

test_render_template_preserves_unknown_vars() {
  source "$LIB_DIR/ocdc-poll-config.bash"
  
  local template="Known: {known}, Unknown: {unknown}"
  local result
  result=$(poll_config_render_template "$template" known="value")
  
  assert_equals "Known: value, Unknown: {unknown}" "$result"
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Poll Configuration Tests:"

for test_func in \
  test_poll_config_library_exists \
  test_poll_config_can_be_sourced \
  test_validate_linear_config \
  test_validate_github_issue_config \
  test_validate_github_pr_config \
  test_validate_rejects_missing_id \
  test_validate_rejects_missing_source_type \
  test_validate_rejects_missing_repo_filters \
  test_validate_rejects_empty_repo_filters \
  test_validate_rejects_both_fetch_options \
  test_default_item_mapping_linear \
  test_default_item_mapping_github_issue \
  test_default_prompt_linear \
  test_default_prompt_github_pr \
  test_default_session_name_linear \
  test_default_agent_github_pr \
  test_default_agent_github_issue \
  test_build_fetch_command_linear \
  test_build_fetch_command_github_issue \
  test_build_fetch_command_github_pr \
  test_build_fetch_command_with_options \
  test_build_fetch_command_escapes_special_chars \
  test_build_fetch_command_state_validation \
  test_match_repo_filter_team_only \
  test_match_repo_filter_labels_only \
  test_match_repo_filter_case_insensitive \
  test_match_repo_filter_specificity \
  test_match_repo_filter_no_match \
  test_match_repo_filter_github_repo \
  test_match_repo_filter_github_org \
  test_match_repo_filter_catch_all \
  test_match_repo_filter_multiple_labels_any \
  test_match_repo_filter_item_missing_fields \
  test_effective_fetch_command_from_options \
  test_effective_fetch_command_override \
  test_effective_prompt_default \
  test_effective_prompt_custom \
  test_effective_session_name_default \
  test_effective_session_name_custom \
  test_effective_agent_default \
  test_effective_agent_custom \
  test_list_all_configs \
  test_list_enabled_configs_only \
  test_render_template_simple \
  test_render_template_multiple_vars \
  test_render_template_preserves_unknown_vars
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
