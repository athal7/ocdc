#!/usr/bin/env bash
#
# Tests for repository configuration (self-iteration)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "Testing repository configuration..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create repos config file location
  export OCDC_REPOS_FILE="$TEST_CONFIG_DIR/repos.yaml"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Helper to create test config files
# =============================================================================

create_basic_repos_config() {
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  athal7/ocdc:
    repo_path: ~/code/ocdc
  
  myorg/backend:
    repo_path: ~/code/backend
    wip_limits:
      max_concurrent: 2
EOF
}

create_repos_config_with_readiness() {
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  athal7/ocdc:
    repo_path: ~/code/ocdc
    issue_tracker:
      type: github
      repo: athal7/ocdc
    readiness:
      labels:
        exclude: ["blocked", "needs-design"]
      priority:
        labels:
          - label: critical
            weight: 100
          - label: high
            weight: 50
          - label: medium
            weight: 25
        age_weight: 1
      dependencies:
        check_body_references: true
        blocking_labels: ["blocked"]
    wip_limits:
      max_concurrent: 3
EOF
}

create_repos_config_with_defaults() {
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  minimal/repo:
    repo_path: ~/code/minimal
EOF
}

create_repos_config_multiple() {
  cat > "$OCDC_REPOS_FILE" << 'EOF'
repos:
  org/repo1:
    repo_path: ~/code/repo1
    wip_limits:
      max_concurrent: 1
  
  org/repo2:
    repo_path: ~/code/repo2
    wip_limits:
      max_concurrent: 2
  
  org/repo3:
    repo_path: ~/code/repo3
EOF
}

# =============================================================================
# Basic Tests
# =============================================================================

test_repo_config_library_exists() {
  if [[ ! -f "$LIB_DIR/ocdc-repo-config.bash" ]]; then
    echo "lib/ocdc-repo-config.bash does not exist"
    return 1
  fi
  return 0
}

test_repo_config_can_be_sourced() {
  if ! source "$LIB_DIR/ocdc-repo-config.bash" 2>&1; then
    echo "Failed to source ocdc-repo-config.bash"
    return 1
  fi
  return 0
}

# =============================================================================
# Config Loading Tests
# =============================================================================

test_load_repos_config() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local config
  config=$(repo_config_load)
  
  if [[ -z "$config" ]]; then
    echo "Should load repos config"
    return 1
  fi
  
  # Should be valid JSON
  if ! echo "$config" | jq -e '.' >/dev/null 2>&1; then
    echo "Should return valid JSON: $config"
    return 1
  fi
  return 0
}

test_get_repo_config() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local repo_path
  repo_path=$(echo "$config" | jq -r '.repo_path')
  
  assert_equals "~/code/ocdc" "$repo_path"
}

test_get_repo_config_with_wip_limits() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local config
  config=$(repo_config_get "myorg/backend")
  
  local max_concurrent
  max_concurrent=$(echo "$config" | jq -r '.wip_limits.max_concurrent')
  
  assert_equals "2" "$max_concurrent"
}

test_get_repo_config_not_found() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local config
  config=$(repo_config_get "nonexistent/repo")
  
  # Should return empty or null
  if [[ -n "$config" ]] && [[ "$config" != "null" ]]; then
    echo "Should return empty for nonexistent repo: $config"
    return 1
  fi
  return 0
}

test_list_repos() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_multiple
  
  local repos
  repos=$(repo_config_list)
  
  if [[ "$repos" != *"org/repo1"* ]]; then
    echo "Should list org/repo1"
    return 1
  fi
  if [[ "$repos" != *"org/repo2"* ]]; then
    echo "Should list org/repo2"
    return 1
  fi
  if [[ "$repos" != *"org/repo3"* ]]; then
    echo "Should list org/repo3"
    return 1
  fi
  return 0
}

# =============================================================================
# Default Value Tests
# =============================================================================

test_get_repo_config_with_defaults() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_defaults
  
  local config
  config=$(repo_config_get_with_defaults "minimal/repo")
  
  # Should have default wip_limits
  local max_concurrent
  max_concurrent=$(echo "$config" | jq -r '.wip_limits.max_concurrent')
  
  # Default should be 3
  assert_equals "3" "$max_concurrent"
}

test_get_repo_config_defaults_not_override() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local config
  config=$(repo_config_get_with_defaults "myorg/backend")
  
  # Should preserve explicit value, not override with default
  local max_concurrent
  max_concurrent=$(echo "$config" | jq -r '.wip_limits.max_concurrent')
  
  assert_equals "2" "$max_concurrent"
}

test_get_repo_config_readiness_defaults() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_defaults
  
  local config
  config=$(repo_config_get_with_defaults "minimal/repo")
  
  # Should have default readiness settings
  local check_body_refs
  check_body_refs=$(echo "$config" | jq -r '.readiness.dependencies.check_body_references')
  
  assert_equals "true" "$check_body_refs"
}

# =============================================================================
# Readiness Configuration Tests
# =============================================================================

test_get_repo_readiness_labels() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_readiness
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local exclude_labels
  exclude_labels=$(echo "$config" | jq -r '.readiness.labels.exclude | join(",")')
  
  assert_equals "blocked,needs-design" "$exclude_labels"
}

test_get_repo_priority_labels() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_readiness
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local critical_weight
  critical_weight=$(echo "$config" | jq -r '.readiness.priority.labels[] | select(.label == "critical") | .weight')
  
  assert_equals "100" "$critical_weight"
}

test_get_repo_dependency_config() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_readiness
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local check_refs
  check_refs=$(echo "$config" | jq -r '.readiness.dependencies.check_body_references')
  
  assert_equals "true" "$check_refs"
}

# =============================================================================
# Issue Tracker Configuration Tests
# =============================================================================

test_get_repo_issue_tracker() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_readiness
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local tracker_type
  tracker_type=$(echo "$config" | jq -r '.issue_tracker.type')
  
  assert_equals "github" "$tracker_type"
}

test_get_repo_issue_tracker_repo() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_repos_config_with_readiness
  
  local config
  config=$(repo_config_get "athal7/ocdc")
  
  local tracker_repo
  tracker_repo=$(echo "$config" | jq -r '.issue_tracker.repo')
  
  assert_equals "athal7/ocdc" "$tracker_repo"
}

# =============================================================================
# Path Resolution Tests
# =============================================================================

test_find_repo_by_path() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  # Expand ~ for comparison
  local expanded_path="${HOME}/code/ocdc"
  
  local repo_key
  repo_key=$(repo_config_find_by_path "$expanded_path")
  
  assert_equals "athal7/ocdc" "$repo_key"
}

test_find_repo_by_path_not_found() {
  source "$LIB_DIR/ocdc-repo-config.bash"
  create_basic_repos_config
  
  local repo_key
  repo_key=$(repo_config_find_by_path "/nonexistent/path")
  
  if [[ -n "$repo_key" ]]; then
    echo "Should return empty for nonexistent path: $repo_key"
    return 1
  fi
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Repository Configuration Tests:"

for test_func in \
  test_repo_config_library_exists \
  test_repo_config_can_be_sourced \
  test_load_repos_config \
  test_get_repo_config \
  test_get_repo_config_with_wip_limits \
  test_get_repo_config_not_found \
  test_list_repos \
  test_get_repo_config_with_defaults \
  test_get_repo_config_defaults_not_override \
  test_get_repo_config_readiness_defaults \
  test_get_repo_readiness_labels \
  test_get_repo_priority_labels \
  test_get_repo_dependency_config \
  test_get_repo_issue_tracker \
  test_get_repo_issue_tracker_repo \
  test_find_repo_by_path \
  test_find_repo_by_path_not_found
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
