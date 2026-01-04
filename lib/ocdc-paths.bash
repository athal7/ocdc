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

# Get the version of ocdc from package.json
# Returns "unknown" if package.json not found
# Environment variable OCDC_VERSION takes precedence (for testing/override)
ocdc_version() {
  if [[ -n "${OCDC_VERSION:-}" ]]; then
    echo "$OCDC_VERSION"
    return
  fi
  
  # Find package.json relative to this script's location
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local version_file="${script_dir}/../package.json"
  
  if [[ -f "$version_file" ]]; then
    jq -r '.version' "$version_file"
  else
    echo "unknown"
  fi
}

# Ensure all required directories exist
ocdc_ensure_dirs() {
  mkdir -p "$OCDC_CONFIG_DIR"
  mkdir -p "$OCDC_CACHE_DIR"
  mkdir -p "$OCDC_OVERRIDES_DIR"
  mkdir -p "$OCDC_DATA_DIR"
  mkdir -p "$OCDC_CLONES_DIR"
  
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

# Check if a port is actively listening
# Usage: ocdc_is_port_active 13000
# Returns: 0 if active, 1 if not
ocdc_is_port_active() {
  local port="$1"
  lsof -i ":$port" >/dev/null 2>&1
}

# Resolve a branch identifier to a workspace path
# Usage: ocdc_resolve_identifier <branch> [repo]
# Outputs: workspace path to stdout
# Outputs: warning to stderr if ambiguous
# Returns: 0 on success, 1 on failure (with error message to stderr)
#
# Resolution order when multiple matches:
# 1. Prefer workspaces with active containers (port responding)
# 2. Fall back to most recently started
# 3. Warn user about ambiguity
ocdc_resolve_identifier() {
  local branch="$1"
  local repo="${2:-}"
  
  [[ -f "$OCDC_PORTS_FILE" ]] || { echo "No workspaces tracked" >&2; return 1; }
  
  local candidates
  if [[ -n "$repo" ]]; then
    # Exact repo + branch match
    candidates=$(jq -r --arg r "$repo" --arg b "$branch" \
      'to_entries[] | select(.value.repo == $r and .value.branch == $b) | .key' \
      "$OCDC_PORTS_FILE" 2>/dev/null)
  else
    # Branch-only match
    candidates=$(jq -r --arg b "$branch" \
      'to_entries[] | select(.value.branch == $b) | .key' \
      "$OCDC_PORTS_FILE" 2>/dev/null)
  fi
  
  # Count matches
  local count=0
  local candidate_array=()
  while IFS= read -r ws; do
    [[ -n "$ws" ]] || continue
    candidate_array+=("$ws")
    count=$((count + 1))
  done <<< "$candidates"
  
  if [[ $count -eq 0 ]]; then
    if [[ -n "$repo" ]]; then
      echo "No workspace found for: $repo/$branch" >&2
    else
      echo "No workspace found for: $branch" >&2
    fi
    return 1
  fi
  
  if [[ $count -eq 1 ]]; then
    echo "${candidate_array[0]}"
    return 0
  fi
  
  # Multiple matches - need to resolve ambiguity
  # First, try to find an active one
  local active_ws=""
  local active_repo=""
  for ws in "${candidate_array[@]}"; do
    local port
    port=$(jq -r --arg ws "$ws" '.[$ws].port' "$OCDC_PORTS_FILE")
    if ocdc_is_port_active "$port"; then
      active_ws="$ws"
      active_repo=$(jq -r --arg ws "$ws" '.[$ws].repo' "$OCDC_PORTS_FILE")
      break
    fi
  done
  
  if [[ -n "$active_ws" ]]; then
    echo "[ocdc] Multiple workspaces match '$branch', using $active_repo/$branch (active)" >&2
    echo "$active_ws"
    return 0
  fi
  
  # No active containers - pick most recently started
  local best_ws=""
  local best_repo=""
  best_ws=$(jq -r --arg b "$branch" \
    '[to_entries[] | select(.value.branch == $b)] | sort_by(.value.started) | reverse | .[0].key' \
    "$OCDC_PORTS_FILE" 2>/dev/null)
  best_repo=$(jq -r --arg ws "$best_ws" '.[$ws].repo' "$OCDC_PORTS_FILE")
  
  echo "[ocdc] Multiple workspaces match '$branch', using $best_repo/$branch (most recent)" >&2
  echo "$best_ws"
  return 0
}

# Export all paths
export OCDC_CONFIG_DIR
export OCDC_CACHE_DIR
export OCDC_DATA_DIR
export OCDC_CLONES_DIR
export OCDC_PORTS_FILE
export OCDC_OVERRIDES_DIR
export OCDC_CONFIG_FILE
