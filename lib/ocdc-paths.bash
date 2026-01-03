#!/usr/bin/env bash
#
# ocdc-paths.bash - Path constants and migration for ocdc
#
# Source this file in all ocdc scripts to get consistent paths.
#
# Usage:
#   source "$(dirname "$0")/../lib/ocdc-paths.bash"
#   ocdc_ensure_dirs
#
# Environment variables can override any path:
#   OCDC_CONFIG_DIR, OCDC_CACHE_DIR, OCDC_DATA_DIR, OCDC_CLONES_DIR

# Path constants (respect environment overrides)
OCDC_CONFIG_DIR="${OCDC_CONFIG_DIR:-${HOME}/.config/ocdc}"
OCDC_CACHE_DIR="${OCDC_CACHE_DIR:-${HOME}/.cache/ocdc}"
OCDC_DATA_DIR="${OCDC_DATA_DIR:-${HOME}/.local/share/ocdc}"
OCDC_CLONES_DIR="${OCDC_CLONES_DIR:-${HOME}/.cache/devcontainer-clones}"

# Derived paths
OCDC_PORTS_FILE="${OCDC_CACHE_DIR}/ports.json"
OCDC_OVERRIDES_DIR="${OCDC_CACHE_DIR}/overrides"
OCDC_CONFIG_FILE="${OCDC_CONFIG_DIR}/config.json"
OCDC_POLL_STATE_DIR="${OCDC_DATA_DIR}/poll-state"
OCDC_POLLS_DIR="${OCDC_POLLS_DIR:-${OCDC_CONFIG_DIR}/polls}"
OCDC_POLL_LOG_DIR="${OCDC_POLL_LOG_DIR:-${OCDC_DATA_DIR}/logs}"
OCDC_POLL_LOG_FILE="${OCDC_POLL_LOG_FILE:-${OCDC_POLL_LOG_DIR}/poll.log}"

# Legacy paths (for migration)
_LEGACY_CONFIG_DIR="${HOME}/.config/devcontainer-multi"
_LEGACY_CACHE_DIR="${HOME}/.cache/devcontainer-multi"

# Generate a stable ID from a path using MD5 hash
# Used for workspace identifiers, not security (short, deterministic IDs)
# Works on both macOS (md5) and Linux (md5sum)
ocdc_path_id() {
  local path="$1"
  echo "$path" | md5 -q 2>/dev/null || echo "$path" | md5sum | cut -d' ' -f1
}

# Resolve a path to its canonical absolute form, resolving symlinks
# Returns the original input if the path doesn't exist
# Note: Only works for directories, not files
# Usage: resolved=$(ocdc_resolve_path "/some/path")
ocdc_resolve_path() {
  local path="$1"
  (cd "$path" 2>/dev/null && pwd -P) || echo "$path"
}

# Get the version of ocdc from git tags or package.json
# Returns "dev" if not in a release context
ocdc_version() {
  if [[ -n "${OCDC_VERSION:-}" ]]; then
    echo "$OCDC_VERSION"
  else
    echo "dev"
  fi
}

# Ensure all required directories exist
ocdc_ensure_dirs() {
  mkdir -p "$OCDC_CONFIG_DIR"
  mkdir -p "$OCDC_CACHE_DIR"
  mkdir -p "$OCDC_OVERRIDES_DIR"
  mkdir -p "$OCDC_DATA_DIR"
  mkdir -p "$OCDC_CLONES_DIR"
  mkdir -p "$OCDC_POLLS_DIR"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  mkdir -p "$OCDC_POLL_LOG_DIR"
  
  # Initialize empty files if they don't exist
  [[ -f "$OCDC_PORTS_FILE" ]] || echo '{}' > "$OCDC_PORTS_FILE"
  [[ -f "$OCDC_CONFIG_FILE" ]] || echo '{}' > "$OCDC_CONFIG_FILE"
}

# Migrate from legacy paths to new paths
# This is idempotent - safe to run multiple times
ocdc_migrate_paths() {
  local migrated=false
  
  # Migrate config directory
  if [[ -d "$_LEGACY_CONFIG_DIR" ]] && [[ ! -d "$OCDC_CONFIG_DIR" ]]; then
    mv "$_LEGACY_CONFIG_DIR" "$OCDC_CONFIG_DIR"
    migrated=true
  elif [[ -d "$_LEGACY_CONFIG_DIR" ]] && [[ -d "$OCDC_CONFIG_DIR" ]]; then
    # Both exist - merge (copy files that don't exist in new location)
    for file in "$_LEGACY_CONFIG_DIR"/*; do
      [[ -e "$file" ]] || continue
      local basename=$(basename "$file")
      if [[ ! -e "$OCDC_CONFIG_DIR/$basename" ]]; then
        cp -r "$file" "$OCDC_CONFIG_DIR/"
      fi
    done
    rm -rf "$_LEGACY_CONFIG_DIR"
    migrated=true
  fi
  
  # Migrate cache directory
  if [[ -d "$_LEGACY_CACHE_DIR" ]] && [[ ! -d "$OCDC_CACHE_DIR" ]]; then
    mv "$_LEGACY_CACHE_DIR" "$OCDC_CACHE_DIR"
    migrated=true
  elif [[ -d "$_LEGACY_CACHE_DIR" ]] && [[ -d "$OCDC_CACHE_DIR" ]]; then
    # Both exist - merge (copy files that don't exist in new location)
    for file in "$_LEGACY_CACHE_DIR"/*; do
      [[ -e "$file" ]] || continue
      local basename=$(basename "$file")
      if [[ ! -e "$OCDC_CACHE_DIR/$basename" ]]; then
        cp -r "$file" "$OCDC_CACHE_DIR/"
      fi
    done
    rm -rf "$_LEGACY_CACHE_DIR"
    migrated=true
  fi
  
  # Ensure directories exist after migration
  ocdc_ensure_dirs
  
  if [[ "$migrated" == "true" ]]; then
    echo "[ocdc] Migrated configuration from devcontainer-multi to ocdc" >&2
  fi
}

# Backward compatibility: export old variable names
# Scripts can gradually migrate to new names
export_legacy_vars() {
  export DCMULTI_CONFIG_DIR="$OCDC_CONFIG_DIR"
  export DCMULTI_CACHE_DIR="$OCDC_CACHE_DIR"
  export DCMULTI_CLONES_DIR="$OCDC_CLONES_DIR"
}

# Get git status for a workspace directory
# Returns JSON: {"clean": bool, "pushed": bool, "ahead": int}
# For non-git directories or errors, returns safe defaults
ocdc_get_git_status() {
  local workspace="$1"
  
  # Non-existent directory - no git state
  if [[ ! -d "$workspace" ]]; then
    echo '{"clean": true, "pushed": true, "ahead": 0, "is_git": false}'
    return 0
  fi
  
  # Not a git repo
  if ! git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
    echo '{"clean": true, "pushed": true, "ahead": 0, "is_git": false}'
    return 0
  fi
  
  local clean=true
  local pushed=true
  local ahead=0
  
  # Check for uncommitted changes (staged or unstaged)
  if ! git -C "$workspace" diff --quiet 2>/dev/null; then
    clean=false
  fi
  if ! git -C "$workspace" diff --cached --quiet 2>/dev/null; then
    clean=false
  fi
  
  # Check for unpushed commits (only if we have an upstream)
  local upstream
  upstream=$(git -C "$workspace" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  
  if [[ -n "$upstream" ]]; then
    ahead=$(git -C "$workspace" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "0")
    if [[ "$ahead" -gt 0 ]]; then
      pushed=false
    fi
  fi
  
  jq -n \
    --argjson clean "$clean" \
    --argjson pushed "$pushed" \
    --argjson ahead "$ahead" \
    '{clean: $clean, pushed: $pushed, ahead: $ahead, is_git: true}'
}

# Check if a workspace is safe to remove (no uncommitted or unpushed changes)
# Returns 0 (true) if safe, 1 (false) if not safe
ocdc_is_safe_to_remove() {
  local workspace="$1"
  
  # Non-existent directory is safe
  [[ ! -d "$workspace" ]] && return 0
  
  # Non-git directory is safe
  if ! git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  
  # Check for uncommitted changes
  if ! git -C "$workspace" diff --quiet 2>/dev/null; then
    return 1  # Has uncommitted changes
  fi
  if ! git -C "$workspace" diff --cached --quiet 2>/dev/null; then
    return 1  # Has staged changes
  fi
  
  # Check for unpushed commits (only if we have an upstream)
  local upstream
  upstream=$(git -C "$workspace" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  
  if [[ -n "$upstream" ]]; then
    local ahead
    ahead=$(git -C "$workspace" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "0")
    if [[ "$ahead" -gt 0 ]]; then
      return 1  # Has unpushed commits
    fi
  fi
  
  return 0  # Safe to remove
}

# Export all paths
export OCDC_CONFIG_DIR
export OCDC_CACHE_DIR
export OCDC_DATA_DIR
export OCDC_CLONES_DIR
export OCDC_PORTS_FILE
export OCDC_OVERRIDES_DIR
export OCDC_CONFIG_FILE
export OCDC_POLL_STATE_DIR
export OCDC_POLLS_DIR
export OCDC_POLL_LOG_DIR
export OCDC_POLL_LOG_FILE
