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

# Legacy paths (for migration)
_LEGACY_CONFIG_DIR="${HOME}/.config/devcontainer-multi"
_LEGACY_CACHE_DIR="${HOME}/.cache/devcontainer-multi"

# Ensure all required directories exist
ocdc_ensure_dirs() {
  mkdir -p "$OCDC_CONFIG_DIR"
  mkdir -p "$OCDC_CACHE_DIR"
  mkdir -p "$OCDC_OVERRIDES_DIR"
  mkdir -p "$OCDC_DATA_DIR"
  mkdir -p "$OCDC_CLONES_DIR"
  mkdir -p "$OCDC_POLLS_DIR"
  mkdir -p "$OCDC_POLL_STATE_DIR"
  
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
