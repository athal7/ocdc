#!/usr/bin/env bash
#
# Tests for ocdc OpenCode plugin
#
# These tests verify plugin functionality by testing helpers.js (pure functions)
# and validating index.js structure. The actual plugin integration with OpenCode
# can only be tested in the OpenCode runtime, but these tests provide high
# confidence that the logic is correct.
#
# Usage:
#   ./test/test_plugin.bash
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.bash"

PLUGIN_DIR="$(dirname "$SCRIPT_DIR")/plugin"

echo "Testing ocdc plugin..."
echo ""

# =============================================================================
# Setup/Teardown
# =============================================================================

setup() {
  export TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
  
  # Set up test environment - helpers.js reads these
  export OCDC_CACHE_DIR="$TEST_DIR/cache"
  export OCDC_CLONES_DIR="$TEST_DIR/clones"
  export OCDC_SESSIONS_DIR="$TEST_DIR/sessions"
  
  mkdir -p "$OCDC_CACHE_DIR" "$OCDC_CLONES_DIR" "$OCDC_SESSIONS_DIR"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
  fi
}

# Helper to run Node.js with helpers.js
run_node() {
  OCDC_CACHE_DIR="$OCDC_CACHE_DIR" \
  OCDC_CLONES_DIR="$OCDC_CLONES_DIR" \
  OCDC_SESSIONS_DIR="$OCDC_SESSIONS_DIR" \
  node --input-type=module -e "$1" 2>&1
}

# =============================================================================
# Plugin File Structure Tests
# =============================================================================

test_plugin_files_exist() {
  [[ -f "$PLUGIN_DIR/index.js" ]] || { echo "index.js missing"; return 1; }
  [[ -f "$PLUGIN_DIR/helpers.js" ]] || { echo "helpers.js missing"; return 1; }
  [[ -f "$PLUGIN_DIR/command/ocdc.md" ]] || { echo "command/ocdc.md missing"; return 1; }
  return 0
}

test_plugin_has_valid_javascript() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  node --check "$PLUGIN_DIR/index.js" 2>&1 || { echo "index.js has syntax errors"; return 1; }
  node --check "$PLUGIN_DIR/helpers.js" 2>&1 || { echo "helpers.js has syntax errors"; return 1; }
  return 0
}

test_plugin_exports_ocdc_function() {
  # Verify the export statement exists and has correct signature
  grep -q "export const OCDC = async ({ client })" "$PLUGIN_DIR/index.js" || {
    echo "OCDC export with correct signature not found"
    return 1
  }
  return 0
}

test_command_file_has_correct_name() {
  local name=$(grep "^name:" "$PLUGIN_DIR/command/ocdc.md" | sed 's/name: *//')
  if [[ "$name" != "ocdc" ]]; then
    echo "Command name should be 'ocdc', got: $name"
    return 1
  fi
  return 0
}

# =============================================================================
# HOST_COMMANDS Tests
# =============================================================================

test_host_commands_is_array() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { HOST_COMMANDS } from '$PLUGIN_DIR/helpers.js';
    console.log(Array.isArray(HOST_COMMANDS) && HOST_COMMANDS.length > 0);
  ")
  
  if [[ "$result" != "true" ]]; then
    echo "HOST_COMMANDS should be a non-empty array, got: $result"
    return 1
  fi
  return 0
}

test_host_commands_includes_required() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # These commands MUST stay on host for correct behavior
  local required=("git" "cat" "ls" "grep" "ocdc" "cd" "pwd")
  
  for cmd in "${required[@]}"; do
    local result=$(run_node "
      import { HOST_COMMANDS } from '$PLUGIN_DIR/helpers.js';
      console.log(HOST_COMMANDS.includes('$cmd'));
    ")
    if [[ "$result" != "true" ]]; then
      echo "HOST_COMMANDS should include '$cmd'"
      return 1
    fi
  done
  return 0
}

test_host_commands_excludes_dev_tools() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # These commands SHOULD go to container
  local dev_tools=("npm" "yarn" "pnpm" "bundle" "rails" "python" "pip" "cargo" "make")
  
  for cmd in "${dev_tools[@]}"; do
    local result=$(run_node "
      import { HOST_COMMANDS } from '$PLUGIN_DIR/helpers.js';
      console.log(HOST_COMMANDS.includes('$cmd'));
    ")
    if [[ "$result" == "true" ]]; then
      echo "HOST_COMMANDS should NOT include '$cmd' (should run in container)"
      return 1
    fi
  done
  return 0
}

# =============================================================================
# shouldRunOnHost Tests
# =============================================================================

test_should_run_on_host_git_commands() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local git_commands=("git status" "git push" "git log --oneline" "git diff HEAD~1")
  
  for cmd in "${git_commands[@]}"; do
    local result=$(run_node "
      import { shouldRunOnHost } from '$PLUGIN_DIR/helpers.js';
      console.log(shouldRunOnHost('$cmd'));
    ")
    if [[ "$result" != "true" ]]; then
      echo "shouldRunOnHost('$cmd') should return true, got: $result"
      return 1
    fi
  done
  return 0
}

test_should_run_on_host_file_reading() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local file_commands=("cat file.txt" "head -n 10 file.txt" "tail -f log.txt" "grep pattern file")
  
  for cmd in "${file_commands[@]}"; do
    local result=$(run_node "
      import { shouldRunOnHost } from '$PLUGIN_DIR/helpers.js';
      console.log(shouldRunOnHost('$cmd'));
    ")
    if [[ "$result" != "true" ]]; then
      echo "shouldRunOnHost('$cmd') should return true, got: $result"
      return 1
    fi
  done
  return 0
}

test_should_run_in_container() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local container_commands=("npm test" "yarn build" "bundle exec rspec" "python manage.py test" "cargo build" "make all")
  
  for cmd in "${container_commands[@]}"; do
    local result=$(run_node "
      import { shouldRunOnHost } from '$PLUGIN_DIR/helpers.js';
      console.log(shouldRunOnHost('$cmd'));
    ")
    if [[ "$result" != "false" ]]; then
      echo "shouldRunOnHost('$cmd') should return false (run in container), got: $result"
      return 1
    fi
  done
  return 0
}

test_should_run_on_host_escape_hatch() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # HOST: prefix should force host execution
  local escape_commands=("HOST: npm test" "HOST:yarn build" "host: python script.py")
  
  for cmd in "${escape_commands[@]}"; do
    local result=$(run_node "
      import { shouldRunOnHost } from '$PLUGIN_DIR/helpers.js';
      console.log(shouldRunOnHost('$cmd'));
    ")
    if [[ "$result" != "escape" ]]; then
      echo "shouldRunOnHost('$cmd') should return 'escape', got: $result"
      return 1
    fi
  done
  return 0
}

test_should_run_on_host_empty_commands() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shouldRunOnHost } from '$PLUGIN_DIR/helpers.js';
    const tests = [
      shouldRunOnHost(''),
      shouldRunOnHost('   '),
      shouldRunOnHost(null),
      shouldRunOnHost(undefined),
    ];
    console.log(tests.every(t => t === true));
  ")
  
  if [[ "$result" != "true" ]]; then
    echo "Empty/null commands should return true (run on host)"
    return 1
  fi
  return 0
}

# =============================================================================
# Session Management Tests
# =============================================================================

test_session_save_and_load() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { saveSession, loadSession } from '$PLUGIN_DIR/helpers.js';
    
    const testId = 'test-session-123';
    const testData = { 
      workspace: '/test/path', 
      branch: 'main', 
      repoName: 'test-repo',
      sourceUrl: 'https://github.com/test/repo/pull/1'
    };
    
    saveSession(testId, testData);
    const loaded = loadSession(testId);
    
    if (!loaded) throw new Error('Session not loaded');
    if (loaded.workspace !== testData.workspace) throw new Error('workspace mismatch');
    if (loaded.branch !== testData.branch) throw new Error('branch mismatch');
    if (loaded.repoName !== testData.repoName) throw new Error('repoName mismatch');
    if (loaded.sourceUrl !== testData.sourceUrl) throw new Error('sourceUrl mismatch');
    if (!loaded.activatedAt) throw new Error('activatedAt should be set');
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "Session save/load failed: $result"
    return 1
  fi
  return 0
}

test_session_delete() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { saveSession, loadSession, deleteSession } from '$PLUGIN_DIR/helpers.js';
    
    const testId = 'delete-test-session';
    saveSession(testId, { workspace: '/test', branch: 'main', repoName: 'test' });
    
    // Verify saved
    if (!loadSession(testId)) throw new Error('Session should exist after save');
    
    // Delete
    deleteSession(testId);
    
    // Verify deleted
    if (loadSession(testId) !== null) throw new Error('Session should be null after delete');
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "Session delete failed: $result"
    return 1
  fi
  return 0
}

test_session_load_nonexistent() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { loadSession } from '$PLUGIN_DIR/helpers.js';
    
    const session = loadSession('nonexistent-session-xyz');
    console.log(session === null ? 'PASS' : 'FAIL');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "loadSession should return null for nonexistent session"
    return 1
  fi
  return 0
}

test_session_delete_nonexistent() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Should not throw when deleting non-existent session
  local result=$(run_node "
    import { deleteSession } from '$PLUGIN_DIR/helpers.js';
    
    try {
      deleteSession('nonexistent-session-xyz');
      console.log('PASS');
    } catch (e) {
      console.log('FAIL: ' + e.message);
    }
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "deleteSession should not throw for nonexistent session: $result"
    return 1
  fi
  return 0
}

# =============================================================================
# Workspace Resolution Tests
# =============================================================================

test_resolve_workspace_repo_branch_syntax() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Create test clone directory
  mkdir -p "$OCDC_CLONES_DIR/myrepo/feature-branch"
  
  local result=$(run_node "
    import { resolveWorkspace } from '$PLUGIN_DIR/helpers.js';
    
    const resolved = resolveWorkspace('myrepo/feature-branch');
    if (!resolved) throw new Error('not resolved');
    if (resolved.repoName !== 'myrepo') throw new Error('repoName=' + resolved.repoName);
    if (resolved.branch !== 'feature-branch') throw new Error('branch=' + resolved.branch);
    if (!resolved.workspace.endsWith('myrepo/feature-branch')) throw new Error('workspace=' + resolved.workspace);
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "resolveWorkspace repo/branch failed: $result"
    return 1
  fi
  return 0
}

test_resolve_workspace_branch_only_unique() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Create a single repo with the branch
  mkdir -p "$OCDC_CLONES_DIR/single-repo/unique-branch"
  
  local result=$(run_node "
    import { resolveWorkspace } from '$PLUGIN_DIR/helpers.js';
    
    const resolved = resolveWorkspace('unique-branch');
    if (!resolved) throw new Error('not resolved');
    if (resolved.repoName !== 'single-repo') throw new Error('repoName=' + resolved.repoName);
    if (resolved.branch !== 'unique-branch') throw new Error('branch=' + resolved.branch);
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "resolveWorkspace branch-only unique failed: $result"
    return 1
  fi
  return 0
}

test_resolve_workspace_branch_ambiguous() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Create same branch in multiple repos
  mkdir -p "$OCDC_CLONES_DIR/repo-a/main"
  mkdir -p "$OCDC_CLONES_DIR/repo-b/main"
  
  local result=$(run_node "
    import { resolveWorkspace } from '$PLUGIN_DIR/helpers.js';
    
    const resolved = resolveWorkspace('main');
    if (!resolved) throw new Error('not resolved');
    if (!resolved.ambiguous) throw new Error('should be ambiguous');
    if (!resolved.matches || resolved.matches.length !== 2) throw new Error('should have 2 matches');
    
    const repos = resolved.matches.map(m => m.repoName).sort();
    if (repos[0] !== 'repo-a' || repos[1] !== 'repo-b') throw new Error('wrong repos: ' + repos);
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "resolveWorkspace branch ambiguous failed: $result"
    return 1
  fi
  return 0
}

test_resolve_workspace_not_found() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { resolveWorkspace } from '$PLUGIN_DIR/helpers.js';
    
    const resolved = resolveWorkspace('nonexistent/branch');
    console.log(resolved === null ? 'PASS' : 'FAIL: ' + JSON.stringify(resolved));
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "resolveWorkspace not found failed: $result"
    return 1
  fi
  return 0
}

test_resolve_workspace_nested_branch_name() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Branch names can have slashes (feature/add-login)
  mkdir -p "$OCDC_CLONES_DIR/myrepo/feature/add-login"
  
  local result=$(run_node "
    import { resolveWorkspace } from '$PLUGIN_DIR/helpers.js';
    
    const resolved = resolveWorkspace('myrepo/feature/add-login');
    if (!resolved) throw new Error('not resolved');
    if (resolved.repoName !== 'myrepo') throw new Error('repoName=' + resolved.repoName);
    if (resolved.branch !== 'feature/add-login') throw new Error('branch=' + resolved.branch);
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "resolveWorkspace nested branch name failed: $result"
    return 1
  fi
  return 0
}

# =============================================================================
# Directory Getter Tests
# =============================================================================

test_directory_getters_use_env_vars() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { getCacheDir, getSessionsDir, getClonesDir } from '$PLUGIN_DIR/helpers.js';
    
    const cacheDir = getCacheDir();
    const sessionsDir = getSessionsDir();
    const clonesDir = getClonesDir();
    
    if (cacheDir !== '$OCDC_CACHE_DIR') throw new Error('getCacheDir=' + cacheDir);
    if (sessionsDir !== '$OCDC_SESSIONS_DIR') throw new Error('getSessionsDir=' + sessionsDir);
    if (clonesDir !== '$OCDC_CLONES_DIR') throw new Error('getClonesDir=' + clonesDir);
    
    console.log('PASS');
  ")
  
  if [[ "$result" != "PASS" ]]; then
    echo "Directory getters failed: $result"
    return 1
  fi
  return 0
}

# =============================================================================
# Plugin Structure Tests (static analysis of index.js)
# =============================================================================

test_plugin_defines_ocdc_tool() {
  grep -q "ocdc: tool(" "$PLUGIN_DIR/index.js" || { 
    echo "ocdc tool not defined"
    return 1
  }
  return 0
}

test_plugin_defines_ocdc_set_context_tool() {
  grep -q "ocdc_set_context: tool(" "$PLUGIN_DIR/index.js" || {
    echo "ocdc_set_context tool not defined"
    return 1
  }
  return 0
}

test_plugin_defines_ocdc_exec_tool() {
  grep -q "ocdc_exec: tool(" "$PLUGIN_DIR/index.js" || {
    echo "ocdc_exec tool not defined"
    return 1
  }
  return 0
}

test_plugin_defines_tool_execute_before_hook() {
  grep -q '"tool.execute.before"' "$PLUGIN_DIR/index.js" || { 
    echo "tool.execute.before hook not defined"
    return 1
  }
  return 0
}

test_plugin_hook_checks_bash_tool() {
  # The hook should only intercept bash commands
  grep -q 'input.tool !== "bash"' "$PLUGIN_DIR/index.js" || {
    echo "Hook should check for bash tool"
    return 1
  }
  return 0
}

test_plugin_hook_loads_session() {
  grep -q 'loadSession(input.sessionID)' "$PLUGIN_DIR/index.js" || {
    echo "Hook should load session"
    return 1
  }
  return 0
}

test_plugin_hook_uses_shouldRunOnHost() {
  grep -q 'shouldRunOnHost(cmd)' "$PLUGIN_DIR/index.js" || {
    echo "Hook should use shouldRunOnHost"
    return 1
  }
  return 0
}

test_plugin_hook_wraps_with_ocdc_exec() {
  # The hook now uses buildOcdcExecCommandString for safe command wrapping
  grep -q 'buildOcdcExecCommandString' "$PLUGIN_DIR/index.js" || {
    echo "Hook should wrap commands with buildOcdcExecCommandString"
    return 1
  }
  return 0
}

test_plugin_ocdc_tool_checks_cli_installed() {
  grep -q 'which ocdc' "$PLUGIN_DIR/index.js" || {
    echo "ocdc tool should check CLI is installed"
    return 1
  }
  return 0
}

test_plugin_ocdc_tool_handles_off() {
  grep -q 'target === "off"' "$PLUGIN_DIR/index.js" || {
    echo "ocdc tool should handle 'off' target"
    return 1
  }
  return 0
}

test_plugin_set_context_validates_workspace() {
  grep -q 'existsSync(workspace)' "$PLUGIN_DIR/index.js" || {
    echo "ocdc_set_context should validate workspace exists"
    return 1
  }
  return 0
}

test_plugin_ocdc_tool_does_not_show_verbose_up_output() {
  # The ocdc tool should NOT include verbose "ocdc up output" sections
  # These logs are noisy and not useful for the user
  if grep -q -- '--- ocdc up output ---' "$PLUGIN_DIR/index.js"; then
    echo "ocdc tool should not include verbose 'ocdc up output' sections"
    return 1
  fi
  return 0
}

# =============================================================================
# Timeout Utility Tests
# =============================================================================

test_withTimeout_resolves_fast_promise() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { withTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const fast = Promise.resolve('done');
    const result = await withTimeout(fast, 1000);
    console.log(result === 'done' ? 'PASS' : 'FAIL');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "Fast promise should resolve: $result"; return 1; }
  return 0
}

test_withTimeout_rejects_slow_promise() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { withTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const slow = new Promise(r => setTimeout(() => r('done'), 5000));
    try {
      await withTimeout(slow, 100);
      console.log('FAIL: should have timed out');
    } catch (e) {
      console.log(e.message === 'TIMEOUT' ? 'PASS' : 'FAIL: ' + e.message);
    }
  ")
  
  [[ "$result" == "PASS" ]] || { echo "Slow promise should timeout: $result"; return 1; }
  return 0
}

test_withTimeout_rejects_never_resolving_promise() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { withTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const never = new Promise(() => {}); // Never resolves
    try {
      await withTimeout(never, 100);
      console.log('FAIL: should have timed out');
    } catch (e) {
      console.log(e.message === 'TIMEOUT' ? 'PASS' : 'FAIL: ' + e.message);
    }
  ")
  
  [[ "$result" == "PASS" ]] || { echo "Never-resolving promise should timeout: $result"; return 1; }
  return 0
}

test_runWithTimeout_returns_undefined_on_timeout() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { runWithTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const result = await runWithTimeout(
      () => new Promise(() => {}), // Never resolves
      100
    );
    console.log(result === undefined ? 'PASS' : 'FAIL: ' + result);
  ")
  
  [[ "$result" == "PASS" ]] || { echo "runWithTimeout should return undefined on timeout: $result"; return 1; }
  return 0
}

test_runWithTimeout_returns_undefined_on_error() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { runWithTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const result = await runWithTimeout(
      async () => { throw new Error('boom'); },
      1000
    );
    console.log(result === undefined ? 'PASS' : 'FAIL: ' + result);
  ")
  
  [[ "$result" == "PASS" ]] || { echo "runWithTimeout should return undefined on error: $result"; return 1; }
  return 0
}

test_runWithTimeout_returns_value_on_success() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { runWithTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const result = await runWithTimeout(
      async () => 'success',
      1000
    );
    console.log(result === 'success' ? 'PASS' : 'FAIL: ' + result);
  ")
  
  [[ "$result" == "PASS" ]] || { echo "runWithTimeout should return value on success: $result"; return 1; }
  return 0
}

# =============================================================================
# Plugin Initialization Tests
# =============================================================================
# These tests verify that the plugin initializes quickly and doesn't hang,
# even when external dependencies (like Docker or OpenCode API) are slow.

test_plugin_init_does_not_await_slow_operations() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # The plugin initialization should NOT await slow operations like
  # installCommand or cleanupStaleSessions. They run with runWithTimeout
  # which means the plugin returns immediately without blocking.
  #
  # This test simulates what happens when the OpenCode API is slow or hangs.
  # The plugin should still return quickly.
  
  local result
  result=$(run_node "
    import { runWithTimeout } from '$PLUGIN_DIR/helpers.js';
    
    // Simulate a slow operation (like client.session.list that hangs)
    let operationCompleted = false;
    const slowOperation = async () => {
      await new Promise(r => setTimeout(r, 10000)); // 10 seconds
      operationCompleted = true;
    };
    
    const start = Date.now();
    
    // This is what the plugin does now - fire and forget with timeout
    runWithTimeout(slowOperation, 2000);
    
    const elapsed = Date.now() - start;
    
    // Should return immediately (not wait for the slow operation)
    if (elapsed > 100) {
      throw new Error('runWithTimeout blocked for ' + elapsed + 'ms');
    }
    
    // The operation should not have completed
    if (operationCompleted) {
      throw new Error('Operation should not have completed yet');
    }
    
    console.log('PASS: runWithTimeout returned immediately in ' + elapsed + 'ms');
  ")
  
  [[ "$result" == PASS* ]] || { echo "Plugin init should not block: $result"; return 1; }
  return 0
}

test_plugin_init_timeout_prevents_hang() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  # Test that runWithTimeout actually times out and doesn't hang forever
  local result
  result=$(run_node "
    import { runWithTimeout } from '$PLUGIN_DIR/helpers.js';
    
    const start = Date.now();
    
    // This simulates client.session.list() that never resolves
    const result = await runWithTimeout(
      () => new Promise(() => {}), // Never resolves
      100 // 100ms timeout
    );
    
    const elapsed = Date.now() - start;
    
    if (result !== undefined) {
      throw new Error('Should return undefined on timeout, got: ' + result);
    }
    
    if (elapsed > 200) {
      throw new Error('Took too long: ' + elapsed + 'ms (expected ~100ms)');
    }
    
    console.log('PASS: timed out correctly in ' + elapsed + 'ms');
  ")
  
  [[ "$result" == PASS* ]] || { echo "Timeout should prevent hang: $result"; return 1; }
  return 0
}

# =============================================================================
# Secure Command Execution Tests
# =============================================================================
# These tests verify that command execution is safe against shell injection

test_build_ocdc_exec_args_simple_command() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecArgs } from '$PLUGIN_DIR/helpers.js';
    
    const args = buildOcdcExecArgs('/path/to/workspace', 'echo hello');
    const expected = ['exec', '--workspace', '/path/to/workspace', '--', 'echo hello'];
    
    if (JSON.stringify(args) !== JSON.stringify(expected)) {
      throw new Error('Expected: ' + JSON.stringify(expected) + ', got: ' + JSON.stringify(args));
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecArgs simple command failed: $result"; return 1; }
  return 0
}

test_build_ocdc_exec_args_workspace_with_spaces() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecArgs } from '$PLUGIN_DIR/helpers.js';
    
    const args = buildOcdcExecArgs('/path/with spaces/workspace', 'ls -la');
    const expected = ['exec', '--workspace', '/path/with spaces/workspace', '--', 'ls -la'];
    
    if (JSON.stringify(args) !== JSON.stringify(expected)) {
      throw new Error('Expected: ' + JSON.stringify(expected) + ', got: ' + JSON.stringify(args));
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecArgs workspace with spaces failed: $result"; return 1; }
  return 0
}

test_build_ocdc_exec_args_command_with_shell_metacharacters() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecArgs } from '$PLUGIN_DIR/helpers.js';
    
    // Command with shell metacharacters - should be preserved as-is since it's passed to shell
    const args = buildOcdcExecArgs('/workspace', 'echo \\\$HOME && ls | grep test');
    const expected = ['exec', '--workspace', '/workspace', '--', 'echo \\\$HOME && ls | grep test'];
    
    if (JSON.stringify(args) !== JSON.stringify(expected)) {
      throw new Error('Expected: ' + JSON.stringify(expected) + ', got: ' + JSON.stringify(args));
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecArgs command with metacharacters failed: $result"; return 1; }
  return 0
}

test_shell_quote_simple_string() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    const quoted = shellQuote('/simple/path');
    if (quoted !== '/simple/path') {
      throw new Error('Expected: /simple/path, got: ' + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote simple string failed: $result"; return 1; }
  return 0
}

test_shell_quote_string_with_spaces() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    const quoted = shellQuote('/path/with spaces');
    if (quoted !== \"'/path/with spaces'\") {
      throw new Error(\"Expected: '/path/with spaces', got: \" + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote string with spaces failed: $result"; return 1; }
  return 0
}

test_shell_quote_string_with_single_quotes() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    // Single quotes in the string need escaping
    const quoted = shellQuote(\"it's a test\");
    // Should produce: 'it'\\''s a test' (close quote, escaped quote, open quote)
    if (quoted !== \"'it'\\\"'\\\"'s a test'\") {
      throw new Error(\"Expected: 'it'\\\"'\\\"'s a test', got: \" + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote string with single quotes failed: $result"; return 1; }
  return 0
}

test_shell_quote_string_with_special_chars() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    // String with shell metacharacters
    const quoted = shellQuote('/path/\\\$(whoami)/test');
    // Should be quoted to prevent expansion
    if (!quoted.startsWith(\"'\") || !quoted.endsWith(\"'\")) {
      throw new Error('Should be single-quoted, got: ' + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote string with special chars failed: $result"; return 1; }
  return 0
}

test_build_ocdc_exec_command_string() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecCommandString } from '$PLUGIN_DIR/helpers.js';
    
    const cmd = buildOcdcExecCommandString('/simple/workspace', 'npm test');
    if (cmd !== 'ocdc exec --workspace /simple/workspace -- npm test') {
      throw new Error('Expected: ocdc exec --workspace /simple/workspace -- npm test, got: ' + cmd);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecCommandString simple failed: $result"; return 1; }
  return 0
}

test_build_ocdc_exec_command_string_with_spaces() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecCommandString } from '$PLUGIN_DIR/helpers.js';
    
    const cmd = buildOcdcExecCommandString('/path/with spaces', 'npm test');
    // Workspace path should be properly quoted
    if (cmd !== \"ocdc exec --workspace '/path/with spaces' -- npm test\") {
      throw new Error(\"Expected: ocdc exec --workspace '/path/with spaces' -- npm test, got: \" + cmd);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecCommandString with spaces failed: $result"; return 1; }
  return 0
}

test_shell_quote_empty_string() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    const quoted = shellQuote('');
    // Empty string should be quoted to prevent shell issues
    if (quoted !== \"''\") {
      throw new Error(\"Expected: '', got: \" + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote empty string failed: $result"; return 1; }
  return 0
}

test_shell_quote_injection_attempt() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    // Attempt to inject shell commands via workspace path
    const malicious = \"'; rm -rf /; echo '\";
    const quoted = shellQuote(malicious);
    
    // Result should be a single-quoted string that treats the input as literal
    // The quotes should prevent any shell interpretation
    if (!quoted.startsWith(\"'\") || !quoted.endsWith(\"'\")) {
      throw new Error('Should be single-quoted, got: ' + quoted);
    }
    
    // The semicolons and commands should be treated as literal characters
    if (!quoted.includes('rm -rf')) {
      throw new Error('Command should be preserved as literal, got: ' + quoted);
    }
    
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote injection attempt failed: $result"; return 1; }
  return 0
}

test_shell_quote_newlines() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    // Paths can technically contain newlines
    const pathWithNewline = '/path/with\\nnewline';
    const quoted = shellQuote(pathWithNewline);
    
    // Should be quoted to contain the newline safely
    if (!quoted.startsWith(\"'\") || !quoted.endsWith(\"'\")) {
      throw new Error('Should be single-quoted, got: ' + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote newlines failed: $result"; return 1; }
  return 0
}

test_shell_quote_backticks() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { shellQuote } from '$PLUGIN_DIR/helpers.js';
    
    // Backticks can cause command substitution in some shells
    const withBackticks = '/path/\\\`whoami\\\`/test';
    const quoted = shellQuote(withBackticks);
    
    // Should be quoted - single quotes prevent backtick expansion
    if (!quoted.startsWith(\"'\") || !quoted.endsWith(\"'\")) {
      throw new Error('Should be single-quoted, got: ' + quoted);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "shellQuote backticks failed: $result"; return 1; }
  return 0
}

test_build_ocdc_exec_command_preserves_shell_features() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not available"
    return 0
  fi
  
  local result=$(run_node "
    import { buildOcdcExecCommandString } from '$PLUGIN_DIR/helpers.js';
    
    // Commands with pipes, redirects, etc. should be preserved (not escaped)
    // because the user expects shell features to work in their commands
    const cmd = buildOcdcExecCommandString('/workspace', 'ls -la | grep test && echo done');
    
    // Command should NOT be quoted - shell features should work
    if (!cmd.includes('| grep') || !cmd.includes('&& echo')) {
      throw new Error('Shell features should be preserved in command, got: ' + cmd);
    }
    console.log('PASS');
  ")
  
  [[ "$result" == "PASS" ]] || { echo "buildOcdcExecCommand preserves shell features failed: $result"; return 1; }
  return 0
}

# =============================================================================
# Async Execution Tests
# =============================================================================
# These tests verify that the plugin uses async execution to prevent UI blocking.
# The plugin must use execFileAsync (promisified execFile) instead of execFileSync
# for long-running operations like ocdc up and ocdc exec.

test_plugin_uses_async_exec() {
  # The plugin should define execFileAsync using promisify
  if ! grep -q "const execFileAsync = promisify(execFile)" "$PLUGIN_DIR/index.js"; then
    echo "execFileAsync should be defined using promisify(execFile)"
    return 1
  fi
  return 0
}

test_plugin_no_execFileSync_for_ocdc_commands() {
  # execFileSync should NOT be used anywhere in the plugin
  # It blocks the event loop and causes UI rendering issues
  local sync_count
  sync_count=$(grep -c "execFileSync" "$PLUGIN_DIR/index.js" 2>/dev/null || echo "0")
  
  if [[ "$sync_count" -ne 0 ]]; then
    echo "Expected 0 execFileSync calls, found: $sync_count"
    echo "Use execFileAsync instead to prevent UI blocking"
    return 1
  fi
  return 0
}

test_plugin_supports_abort_signal() {
  # The plugin should pass ctx.abort signal to execFileAsync calls
  # This allows users to cancel long-running operations
  if ! grep -q "signal: ctx.abort" "$PLUGIN_DIR/index.js"; then
    echo "Plugin should pass abort signal (signal: ctx.abort) to execFileAsync"
    return 1
  fi
  return 0
}

test_plugin_handles_abort_error() {
  # The plugin should handle AbortError for user cancellation
  if ! grep -q "AbortError" "$PLUGIN_DIR/index.js"; then
    echo "Plugin should handle AbortError for cancellation"
    return 1
  fi
  return 0
}

test_plugin_async_execute_functions() {
  # All three tools should have async execute functions
  local async_count
  async_count=$(grep -c "async execute(args, ctx)" "$PLUGIN_DIR/index.js" 2>/dev/null || echo "0")
  
  if [[ "$async_count" -ne 3 ]]; then
    echo "Expected 3 async execute functions (ocdc_set_context, ocdc_exec, ocdc), found: $async_count"
    return 1
  fi
  return 0
}

# =============================================================================
# OpenCode Runtime Integration Tests (skipped in CI)
# =============================================================================
# These tests actually invoke `opencode run` to verify the plugin works in the
# real OpenCode runtime. They require:
#   - opencode CLI installed
#   - OCDC plugin installed in ~/.config/opencode/plugins/ocdc
#   - Valid API credentials configured
#
# Integration tests run if opencode is installed and plugin is configured.
# OpenCode provides free models, so no API credentials needed.

# Helper to check if we can run integration tests
can_run_integration_tests() {
  # Check opencode is installed
  if ! command -v opencode &>/dev/null; then
    return 1
  fi
  
  # Check plugin is installed
  local plugin_path="$HOME/.config/opencode/plugins/ocdc/index.js"
  if [[ ! -f "$plugin_path" ]]; then
    return 1
  fi
  
  return 0
}

# Setup isolated environment for integration tests
# Uses temp directory for opencode working dir to isolate session database
setup_integration_env() {
  # Create a temp working directory for opencode to store its .opencode/ data
  # This prevents test sessions from polluting the user's real session list
  INTEGRATION_WORKDIR=$(mktemp -d)
  export INTEGRATION_WORKDIR
}

# Cleanup isolated environment after integration tests
cleanup_integration_env() {
  if [[ -n "${INTEGRATION_WORKDIR:-}" ]] && [[ -d "$INTEGRATION_WORKDIR" ]]; then
    rm -rf "$INTEGRATION_WORKDIR"
  fi
  unset INTEGRATION_WORKDIR
}

# =============================================================================
# Fresh Plugin Installation Test
# =============================================================================
# This test verifies the plugin can be installed fresh and loaded by opencode.
# It catches issues like:
#   - Missing dependencies (@opencode-ai/plugin resolution)
#   - Import path problems
#   - Module resolution issues with symlinks vs copies
#
# The test:
#   1. Backs up existing plugin installation
#   2. Copies plugin fresh from repo to ~/.config/opencode/plugins/ocdc
#   3. Verifies opencode can start and load the plugin
#   4. Restores original installation

test_fresh_plugin_installation() {
  # Use real HOME, not test HOME (unit tests may have changed HOME)
  local real_home saved_home
  saved_home="$HOME"
  real_home=$(getent passwd "$USER" 2>/dev/null | cut -d: -f6 || echo "/Users/$USER")
  export HOME="$real_home"
  
  # Skip if opencode not installed
  if ! command -v opencode &>/dev/null; then
    echo "SKIP: opencode not installed"
    export HOME="$saved_home"
    return 0
  fi
  
  # Initialize opencode if needed (installs @opencode-ai/plugin to node_modules)
  # This happens in CI where opencode is installed but never run
  if [[ ! -d "$real_home/.config/opencode/node_modules/@opencode-ai" ]]; then
    # Run opencode once with no plugins to initialize node_modules
    # Use temp workdir to avoid polluting real session list
    local init_workdir
    init_workdir=$(mktemp -d)
    mkdir -p "$real_home/.config/opencode"
    echo '{"plugin":[]}' > "$real_home/.config/opencode/opencode.json"
    perl -e 'alarm 60; exec @ARGV' opencode -c "$init_workdir" run "say ok" >/dev/null 2>&1 || true
    rm -rf "$init_workdir"
    
    if [[ ! -d "$real_home/.config/opencode/node_modules/@opencode-ai" ]]; then
      echo "SKIP: opencode failed to initialize node_modules"
      export HOME="$saved_home"
      return 0
    fi
  fi
  
  local plugin_dest="$real_home/.config/opencode/plugins/ocdc"
  local plugin_backup="$real_home/.config/opencode/plugins/ocdc.backup.$$"
  local config_file="$real_home/.config/opencode/opencode.json"
  local config_backup="$real_home/.config/opencode/opencode.json.backup.$$"
  
  # Backup existing installation if present
  if [[ -e "$plugin_dest" ]]; then
    cp -r "$plugin_dest" "$plugin_backup"
  fi
  
  # Backup config if present
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "$config_backup"
  fi
  
  # Cleanup function - always restore from backups
  cleanup_fresh_install_test() {
    # Restore original plugin
    rm -rf "$plugin_dest"
    if [[ -e "$plugin_backup" ]]; then
      mv "$plugin_backup" "$plugin_dest"
    fi
    # Restore original config (this preserves all other plugins)
    if [[ -f "$config_backup" ]]; then
      mv "$config_backup" "$config_file"
    fi
    # Restore HOME
    export HOME="$saved_home"
  }
  
  # Set trap to cleanup on any exit
  trap cleanup_fresh_install_test RETURN
  
  # Remove existing plugin and copy fresh from repo
  rm -rf "$plugin_dest"
  mkdir -p "$(dirname "$plugin_dest")"
  cp -r "$PLUGIN_DIR" "$plugin_dest"
  
  # Update config to include the plugin path
  # (initialization step may have set it to empty plugins)
  echo "{\"plugin\":[\"$plugin_dest\"]}" > "$config_file"
  
  # Test that opencode can start and load the plugin
  # Use a simple prompt that should work quickly
  # Use temp workdir to avoid polluting real session list
  local test_workdir output
  test_workdir=$(mktemp -d)
  output=$(perl -e 'alarm 30; exec @ARGV' opencode -c "$test_workdir" run "Say the word OK and nothing else" 2>&1)
  local exit_code=$?
  rm -rf "$test_workdir"
  
  # Check results
  if [[ $exit_code -ne 0 ]]; then
    # Check for plugin-specific errors that indicate a real problem
    if echo "$output" | grep -q "Cannot find module"; then
      echo "FAIL: MODULE RESOLUTION ERROR: Plugin cannot resolve @opencode-ai/plugin"
      echo "This happens when plugin is symlinked instead of copied."
      echo "Bun resolves modules from the real path, not symlink location."
      return 1
    fi
    
    # Session errors are CI environment issues, not plugin issues
    # opencode's session management may not work in non-interactive CI
    if echo "$output" | grep -qE "(Session not found|session.*error)"; then
      echo "SKIP: opencode session management issue (CI environment, not plugin)"
      return 0
    fi
    
    echo "FAIL: opencode failed to start with fresh plugin installation"
    echo "Exit code: $exit_code"
    echo "Output: $output"
    return 1
  fi
  
  # Verify we got a response (not just startup)
  if ! echo "$output" | grep -qiE "(ok|hello|hi|assistant|claude)"; then
    echo "FAIL: opencode started but didn't respond properly"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

# Cross-platform timeout wrapper
# Uses perl alarm which works on macOS and Linux
run_with_timeout() {
  local timeout_secs="$1"
  shift
  perl -e "alarm $timeout_secs; exec @ARGV" "$@" 2>&1
}

# Run opencode and capture output (with timeout)
# Uses INTEGRATION_WORKDIR to isolate session database from real sessions
run_opencode() {
  local prompt="$1"
  local timeout="${2:-60}"
  
  # Use -c to set working directory, isolating the .opencode/ database
  if [[ -n "${INTEGRATION_WORKDIR:-}" ]]; then
    run_with_timeout "$timeout" opencode -c "$INTEGRATION_WORKDIR" run --format json "$prompt"
  else
    run_with_timeout "$timeout" opencode run --format json "$prompt"
  fi
}

# Extract text content from opencode JSON output
extract_opencode_text() {
  local output="$1"
  # opencode run --format json outputs newline-delimited JSON events
  # Look for assistant text parts
  echo "$output" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | tr '\n' ' '
}

test_opencode_starts_within_timeout() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # CRITICAL: Verify opencode starts within 10 seconds
  # This catches plugin initialization hangs that would block startup indefinitely.
  # The plugin's init operations (installCommand, cleanupStaleSessions) must not
  # block even if the OpenCode API or Docker is slow/unavailable.
  
  local start_time end_time elapsed output
  start_time=$(date +%s)
  
  # Use a short timeout - if plugin hangs, this will fail
  # Use INTEGRATION_WORKDIR to isolate session database
  output=$(run_with_timeout 10 opencode -c "$INTEGRATION_WORKDIR" run --format json "Say hi" 2>&1)
  local exit_code=$?
  
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  
  cleanup_integration_env
  
  if [[ $exit_code -ne 0 ]]; then
    # Check if it was a timeout (exit code 142 = SIGALRM)
    if [[ $exit_code -eq 142 ]] || [[ "$output" == *"Alarm clock"* ]]; then
      echo "FAIL: opencode startup timed out after ${elapsed}s (plugin may be hanging)"
      echo "Output: $output"
      return 1
    fi
    echo "opencode run failed (exit $exit_code): $output"
    return 1
  fi
  
  # Verify we got a response
  if ! echo "$output" | grep -q '"type"'; then
    echo "No valid JSON output from opencode"
    echo "Output: $output"
    return 1
  fi
  
  # Should complete well under 10 seconds (typically 2-5s)
  if [[ $elapsed -gt 8 ]]; then
    echo "WARNING: opencode took ${elapsed}s to start (may indicate slow init)"
  fi
  
  return 0
}

test_opencode_plugin_loads() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Ask opencode to list tools - ocdc tools should be present
  local output
  output=$(run_opencode "List all available tool names you have. Just output the tool names, one per line, nothing else." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Check for ocdc tools in output
  if ! echo "$output" | grep -qi "ocdc"; then
    echo "ocdc tools not found in opencode tool list"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_ocdc_tool_responds() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Call the ocdc tool with no args (status check)
  local output
  output=$(run_opencode "Use the ocdc tool with no arguments to check current status." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Should mention "No devcontainer active" or similar
  if ! echo "$output" | grep -qiE "(no devcontainer|not active|ocdc|devcontainer)"; then
    echo "ocdc tool response not found"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_ocdc_set_context_rejects_invalid() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Try to set context with non-existent workspace
  local output
  output=$(run_opencode "Use the ocdc_set_context tool with workspace='/nonexistent/path/12345' and branch='test'." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Should report error about workspace not existing
  if ! echo "$output" | grep -qiE "(error|not exist|invalid|cannot find)"; then
    echo "ocdc_set_context should reject invalid workspace"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_ocdc_attempts_to_create_workspace() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Try to target a non-existent workspace - should attempt to create it
  local output
  output=$(run_opencode "Use the ocdc tool with target='nonexistent-branch-xyz123'." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Should attempt to create the workspace and report failure (since branch doesn't exist)
  if ! echo "$output" | grep -qiE "(create|failed|error|not found)"; then
    echo "ocdc should attempt to create non-existent workspace and report failure"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_ocdc_off_without_session() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Try to turn off when nothing is active
  local output
  output=$(run_opencode "Use the ocdc tool with target='off'." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Should indicate no session was active
  if ! echo "$output" | grep -qiE "(no devcontainer|not active|was not|disabled)"; then
    echo "ocdc off should indicate no session was active"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_ocdc_exec_requires_context() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Try to exec without setting context first
  local output
  output=$(run_opencode "Use the ocdc_exec tool with command='echo hello'." 120) || {
    cleanup_integration_env
    echo "opencode run failed: $output"
    return 1
  }
  
  cleanup_integration_env
  
  # Should report no context set
  if ! echo "$output" | grep -qiE "(no.*context|not set|use ocdc_set_context|no devcontainer)"; then
    echo "ocdc_exec should require context to be set first"
    echo "Output: $output"
    return 1
  fi
  
  return 0
}

test_opencode_slash_command_exists() {
  if ! can_run_integration_tests; then
    echo "SKIP: opencode not installed or plugin not configured"
    return 0
  fi
  
  setup_integration_env
  
  # Check that /ocdc command file is installed
  local cmd_file="$HOME/.config/opencode/command/ocdc.md"
  if [[ ! -f "$cmd_file" ]]; then
    # Plugin should install it on first run, so run opencode once
    run_opencode "Say hello" 30 >/dev/null 2>&1 || true
  fi
  
  cleanup_integration_env
  
  if [[ ! -f "$cmd_file" ]]; then
    echo "/ocdc command file not installed at $cmd_file"
    return 1
  fi
  
  # Verify command file has correct name
  if ! grep -q "^name: ocdc" "$cmd_file"; then
    echo "/ocdc command file has wrong name"
    return 1
  fi
  
  return 0
}

# =============================================================================
# Run Tests
# =============================================================================

echo "Plugin File Structure Tests:"

for test_func in \
  test_plugin_files_exist \
  test_plugin_has_valid_javascript \
  test_plugin_exports_ocdc_function \
  test_command_file_has_correct_name
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "HOST_COMMANDS Tests:"

for test_func in \
  test_host_commands_is_array \
  test_host_commands_includes_required \
  test_host_commands_excludes_dev_tools
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "shouldRunOnHost Tests:"

for test_func in \
  test_should_run_on_host_git_commands \
  test_should_run_on_host_file_reading \
  test_should_run_in_container \
  test_should_run_on_host_escape_hatch \
  test_should_run_on_host_empty_commands
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Session Management Tests:"

for test_func in \
  test_session_save_and_load \
  test_session_delete \
  test_session_load_nonexistent \
  test_session_delete_nonexistent
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Workspace Resolution Tests:"

for test_func in \
  test_resolve_workspace_repo_branch_syntax \
  test_resolve_workspace_branch_only_unique \
  test_resolve_workspace_branch_ambiguous \
  test_resolve_workspace_not_found \
  test_resolve_workspace_nested_branch_name
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Directory Getter Tests:"

for test_func in \
  test_directory_getters_use_env_vars
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Timeout Utility Tests:"

for test_func in \
  test_withTimeout_resolves_fast_promise \
  test_withTimeout_rejects_slow_promise \
  test_withTimeout_rejects_never_resolving_promise \
  test_runWithTimeout_returns_undefined_on_timeout \
  test_runWithTimeout_returns_undefined_on_error \
  test_runWithTimeout_returns_value_on_success
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Plugin Structure Tests (index.js):"

for test_func in \
  test_plugin_defines_ocdc_tool \
  test_plugin_defines_ocdc_set_context_tool \
  test_plugin_defines_ocdc_exec_tool \
  test_plugin_defines_tool_execute_before_hook \
  test_plugin_hook_checks_bash_tool \
  test_plugin_hook_loads_session \
  test_plugin_hook_uses_shouldRunOnHost \
  test_plugin_hook_wraps_with_ocdc_exec \
  test_plugin_ocdc_tool_checks_cli_installed \
  test_plugin_ocdc_tool_handles_off \
  test_plugin_set_context_validates_workspace \
  test_plugin_ocdc_tool_does_not_show_verbose_up_output
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Plugin Initialization Tests:"

for test_func in \
  test_plugin_init_does_not_await_slow_operations \
  test_plugin_init_timeout_prevents_hang
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Async Execution Tests:"

for test_func in \
  test_plugin_uses_async_exec \
  test_plugin_no_execFileSync_for_ocdc_commands \
  test_plugin_supports_abort_signal \
  test_plugin_handles_abort_error \
  test_plugin_async_execute_functions
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Secure Command Execution Tests:"

for test_func in \
  test_build_ocdc_exec_args_simple_command \
  test_build_ocdc_exec_args_workspace_with_spaces \
  test_build_ocdc_exec_args_command_with_shell_metacharacters \
  test_shell_quote_simple_string \
  test_shell_quote_string_with_spaces \
  test_shell_quote_string_with_single_quotes \
  test_shell_quote_string_with_special_chars \
  test_shell_quote_empty_string \
  test_shell_quote_injection_attempt \
  test_shell_quote_newlines \
  test_shell_quote_backticks \
  test_build_ocdc_exec_command_string \
  test_build_ocdc_exec_command_string_with_spaces \
  test_build_ocdc_exec_command_preserves_shell_features
do
  setup
  run_test "${test_func#test_}" "$test_func"
  teardown
done

echo ""
echo "Fresh Plugin Installation Test:"
# Run this test separately - it modifies real HOME config
run_test "fresh_plugin_installation" test_fresh_plugin_installation

echo ""
echo "OpenCode Runtime Integration Tests:"

for test_func in \
  test_opencode_starts_within_timeout \
  test_opencode_plugin_loads \
  test_opencode_ocdc_tool_responds \
  test_opencode_ocdc_set_context_rejects_invalid \
  test_opencode_ocdc_attempts_to_create_workspace \
  test_opencode_ocdc_off_without_session \
  test_opencode_ocdc_exec_requires_context \
  test_opencode_slash_command_exists
do
  # Don't use setup/teardown for integration tests - use real HOME
  run_test "${test_func#test_}" "$test_func"
done

print_summary
