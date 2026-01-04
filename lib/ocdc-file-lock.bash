#!/usr/bin/env bash
#
# ocdc-file-lock.bash - Cross-platform file locking using mkdir
#
# This uses mkdir for atomic lock acquisition, which works on both macOS and Linux.
# flock is not available on macOS by default.
#
# Usage:
#   source "$(dirname "$0")/../lib/ocdc-file-lock.bash"
#   lock_file "/path/to/lockfile"
#   # ... critical section ...
#   unlock_file "/path/to/lockfile"

# Acquire a lock (blocking with polling)
# Usage: lock_file <lockfile> [max_age_seconds]
# max_age_seconds: Remove stale locks older than this (default: 60)
lock_file() {
  local lockfile="$1"
  local max_age="${2:-60}"
  
  while true; do
    # Try to create lock directory atomically
    if mkdir "$lockfile" 2>/dev/null; then
      return 0
    fi
    
    # Lock exists - check if it's stale
    if [[ -e "$lockfile" ]]; then
      local now lock_mtime age
      now=$(date +%s)
      
      # Get mtime - handle both files and directories
      # macOS: stat -f%m, Linux: stat -c%Y
      lock_mtime=$(stat -f%m "$lockfile" 2>/dev/null || stat -c%Y "$lockfile" 2>/dev/null || echo 0)
      age=$((now - lock_mtime))
      
      if [[ $age -gt $max_age ]]; then
        # Stale lock - remove it (handles both files and directories)
        rm -rf "$lockfile" 2>/dev/null || true
        continue
      fi
    fi
    
    # Wait and retry
    sleep 0.1
  done
}

# Release a lock
# Usage: unlock_file <lockfile>
unlock_file() {
  local lockfile="$1"
  rmdir "$lockfile" 2>/dev/null || rm -f "$lockfile" 2>/dev/null || true
}
