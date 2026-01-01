#!/usr/bin/env bash
#
# Integration tests for ocdc-up command
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

echo "Testing ocdc-up..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  setup_test_env
  
  # Create a fake git repo with devcontainer.json
  export TEST_REPO="$TEST_DIR/test-repo"
  mkdir -p "$TEST_REPO/.devcontainer"
  
  cat > "$TEST_REPO/.devcontainer/devcontainer.json" << 'EOF'
{
  "name": "Test Container",
  "image": "node:18",
  "forwardPorts": [3000]
}
EOF
  
  # Initialize git repo
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" add -A
  git -C "$TEST_REPO" commit -q -m "Initial commit"
  
  # Override config paths for testing
  export CONFIG_DIR="$TEST_CONFIG_DIR"
  export CACHE_DIR="$TEST_CACHE_DIR"
  export CLONES_DIR="$TEST_CLONES_DIR"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# Tests
# =============================================================================

test_ocdc_up_shows_help() {
  local output=$("$BIN_DIR/ocdc" up --help 2>&1)
  assert_contains "$output" "Usage:"
  assert_contains "$output" "ocdc-up"
}

test_ocdc_up_fails_outside_git_repo() {
  cd "$TEST_DIR"
  local output
  if output=$("$BIN_DIR/ocdc" up 2>&1); then
    echo "Should have failed outside git repo"
    return 1
  fi
  assert_contains "$output" "Not in a git repository"
}

test_ocdc_up_fails_without_devcontainer_json() {
  # Create repo without devcontainer.json
  local bare_repo="$TEST_DIR/bare-repo"
  mkdir -p "$bare_repo"
  git -C "$bare_repo" init -q
  
  cd "$bare_repo"
  local output
  if output=$("$BIN_DIR/ocdc" up 2>&1); then
    echo "Should have failed without devcontainer.json"
    return 1
  fi
  assert_contains "$output" "No devcontainer.json found"
}

test_ocdc_up_detects_workspace() {
  cd "$TEST_REPO"
  # Use --no-open and capture output (will fail at devcontainer up, but that's ok)
  local output=$("$BIN_DIR/ocdc" up --no-open 2>&1 || true)
  assert_contains "$output" "Workspace:"
  assert_contains "$output" "$TEST_REPO"
}

test_ocdc_up_assigns_port() {
  cd "$TEST_REPO"
  local output=$("$BIN_DIR/ocdc" up --no-open 2>&1 || true)
  assert_contains "$output" "Port mapping:"
  assert_contains "$output" "localhost:13"  # Port in 13000 range
}

test_ocdc_up_creates_clone_for_branch() {
  cd "$TEST_REPO"
  
  # Create a branch first
  git checkout -q -b test-branch
  git checkout -q main 2>/dev/null || git checkout -q master
  
  local output=$("$BIN_DIR/ocdc" up test-branch --no-open 2>&1 || true)
  assert_contains "$output" "clone"
}

test_ocdc_up_no_open_flag_works() {
  cd "$TEST_REPO"
  local output=$("$BIN_DIR/ocdc" up --no-open 2>&1 || true)
  # Should not contain "Opening" message
  if [[ "$output" == *"Opening in VS Code"* ]]; then
    echo "Should not attempt to open VS Code with --no-open"
    return 1
  fi
  return 0
}

test_ocdc_up_override_sets_correct_workspace_folder() {
  # Regression test: when using a branch clone, the override config must set
  # workspaceFolder to match the actual clone directory name, not the original
  # repo's hardcoded workspaceFolder value
  
  # Create a devcontainer.json with explicit workspaceFolder (like real projects have)
  cat > "$TEST_REPO/.devcontainer/devcontainer.json" << 'EOF'
{
  "name": "Test Container",
  "image": "node:18",
  "workspaceFolder": "/workspaces/test-repo",
  "forwardPorts": [3000]
}
EOF
  git -C "$TEST_REPO" add -A
  git -C "$TEST_REPO" commit -q -m "Add workspaceFolder"
  
  cd "$TEST_REPO"
  
  # Create a branch
  git checkout -q -b feature-xyz
  git checkout -q main 2>/dev/null || git checkout -q master
  
  # Run ocdc-up for the branch (will fail at devcontainer up, but creates override)
  "$BIN_DIR/ocdc" up feature-xyz --no-open 2>&1 || true
  
  # Find the override file and verify workspaceFolder is correct
  local override_file=$(ls "$TEST_CACHE_DIR/overrides"/*.json 2>/dev/null | head -1)
  if [[ -z "$override_file" ]]; then
    echo "Override file not created"
    return 1
  fi
  
  local workspace_folder=$(jq -r '.workspaceFolder' "$override_file")
  if [[ "$workspace_folder" != "/workspaces/feature-xyz" ]]; then
    echo "Expected workspaceFolder '/workspaces/feature-xyz', got '$workspace_folder'"
    return 1
  fi
  return 0
}

test_ocdc_up_copies_gitignored_files_to_clone() {
  # When creating a clone for a branch, files that exist locally but are
  # gitignored should be copied so the app can run (secrets, local config, etc.)
  # Directories with many files (>100) are skipped as they're likely dependencies.
  
  cd "$TEST_REPO"
  
  # Add gitignore patterns
  cat > .gitignore << 'EOF'
config/master.key
config/credentials/*.key
.env*
!.env.example
secrets/
node_modules/
vendor/
storage/
package-lock.json
yarn.lock
Gemfile.lock
EOF
  git add .gitignore
  git commit -q -m "Add gitignore"
  
  # Create files that match gitignore patterns (these won't be in the clone)
  mkdir -p config/credentials secrets
  echo "master-key-content" > config/master.key
  echo "dev-key-content" > config/credentials/development.key
  echo "prod-key-content" > config/credentials/production.key
  echo "ENV_VAR=secret" > .env
  echo "LOCAL_VAR=local" > .env.local
  echo "top-secret" > secrets/api_key.txt
  
  # Create dependency directories with many files (should NOT be copied)
  mkdir -p node_modules vendor/bundle storage/uploads
  for i in $(seq 1 15); do
    echo "file$i" > "node_modules/file$i.js"
    echo "file$i" > "vendor/bundle/file$i.rb"
    echo "file$i" > "storage/uploads/file$i.txt"
  done
  
  # Create lock files that should NOT be copied (generated, cause conflicts)
  echo "lock-content" > package-lock.json
  echo "lock-content" > yarn.lock
  echo "lock-content" > Gemfile.lock
  
  # Create a file that matches an exclusion pattern (should NOT be copied)
  echo "example" > .env.example
  git add .env.example
  git commit -q -m "Add env example"
  
  # Create a tracked file (should NOT be copied since it's in git)
  echo "tracked" > config/database.yml
  git add config/database.yml
  git commit -q -m "Add database config"
  
  # Create a branch
  git checkout -q -b feature-secrets
  git checkout -q main 2>/dev/null || git checkout -q master
  
  # Run ocdc-up for the branch
  local output=$("$BIN_DIR/ocdc" up feature-secrets --no-open 2>&1 || true)
  
  # Verify gitignored files were copied
  local clone_dir="$TEST_CLONES_DIR/test-repo/feature-secrets"
  
  if [[ ! -f "$clone_dir/config/master.key" ]]; then
    echo "config/master.key was not copied to clone"
    return 1
  fi
  
  if [[ ! -f "$clone_dir/config/credentials/development.key" ]]; then
    echo "config/credentials/development.key was not copied to clone"
    return 1
  fi
  
  if [[ ! -f "$clone_dir/config/credentials/production.key" ]]; then
    echo "config/credentials/production.key was not copied to clone"
    return 1
  fi
  
  if [[ ! -f "$clone_dir/.env" ]]; then
    echo ".env was not copied to clone"
    return 1
  fi
  
  if [[ ! -f "$clone_dir/.env.local" ]]; then
    echo ".env.local was not copied to clone"
    return 1
  fi
  
  if [[ ! -f "$clone_dir/secrets/api_key.txt" ]]; then
    echo "secrets/api_key.txt was not copied to clone"
    return 1
  fi
  
  # Verify files from high-file-count directories were NOT copied
  if [[ -f "$clone_dir/node_modules/file1.js" ]]; then
    echo "node_modules files should not be copied (too many files)"
    return 1
  fi
  
  if [[ -f "$clone_dir/vendor/bundle/file1.rb" ]]; then
    echo "vendor files should not be copied (too many files)"
    return 1
  fi
  
  if [[ -f "$clone_dir/storage/uploads/file1.txt" ]]; then
    echo "storage files should not be copied (too many files)"
    return 1
  fi
  
  # Verify lock files were NOT copied (generated files, cause conflicts)
  if [[ -f "$clone_dir/package-lock.json" ]]; then
    echo "package-lock.json should not be copied"
    return 1
  fi
  
  if [[ -f "$clone_dir/yarn.lock" ]]; then
    echo "yarn.lock should not be copied"
    return 1
  fi
  
  if [[ -f "$clone_dir/Gemfile.lock" ]]; then
    echo "Gemfile.lock should not be copied"
    return 1
  fi
  
  # Verify content is correct
  if [[ "$(cat "$clone_dir/config/master.key")" != "master-key-content" ]]; then
    echo "master.key content mismatch"
    return 1
  fi
  
  assert_contains "$output" "Copied"
  return 0
}

test_ocdc_up_skips_path_traversal_attempts() {
  # Defense in depth: paths containing ".." should be skipped to prevent
  # writing files outside the clone directory. While git ls-files shouldn't
  # return such paths, this protects against edge cases.
  #
  # Note: We can't create actual "../" paths on the filesystem, so we test
  # files with ".." in the filename as a proxy. The real protection is against
  # malformed git ls-files output that might contain traversal sequences.
  
  cd "$TEST_REPO"
  
  # Add gitignore pattern
  cat > .gitignore << 'EOF'
secrets/
EOF
  git add .gitignore
  git commit -q -m "Add gitignore"
  
  # Create a legitimate gitignored file
  mkdir -p secrets
  echo "safe-secret" > secrets/safe.txt
  
  # Create a file with ".." in its name (valid but suspicious)
  # This acts as a proxy for testing path traversal protection
  mkdir -p "secrets/sub"
  echo "suspicious" > "secrets/sub/..test"
  
  # Create a branch
  git checkout -q -b feature-traversal
  git checkout -q main 2>/dev/null || git checkout -q master
  
  # Run ocdc-up for the branch
  local output=$("$BIN_DIR/ocdc" up feature-traversal --no-open 2>&1 || true)
  
  local clone_dir="$TEST_CLONES_DIR/test-repo/feature-traversal"
  
  # The safe file should be copied
  if [[ ! -f "$clone_dir/secrets/safe.txt" ]]; then
    echo "secrets/safe.txt was not copied to clone"
    return 1
  fi
  
  # Files with ".." in the path should NOT be copied (defense in depth)
  if [[ -f "$clone_dir/secrets/sub/..test" ]]; then
    echo "File with '..' in path should not be copied (path traversal protection)"
    return 1
  fi
  
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Command Usage Tests:"

# Run each test with setup/teardown
for test_func in \
  test_ocdc_up_shows_help \
  test_ocdc_up_fails_outside_git_repo \
  test_ocdc_up_fails_without_devcontainer_json \
  test_ocdc_up_detects_workspace \
  test_ocdc_up_assigns_port \
  test_ocdc_up_creates_clone_for_branch \
  test_ocdc_up_no_open_flag_works \
  test_ocdc_up_override_sets_correct_workspace_folder \
  test_ocdc_up_copies_gitignored_files_to_clone \
  test_ocdc_up_skips_path_traversal_attempts
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

print_summary
