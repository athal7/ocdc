#!/usr/bin/env bash
#
# ocdc-file-lock.bash - Cross-platform file locking using mkdir
#
# Uses mkdir-based locking which is atomic and portable across
# macOS and Linux (flock is not available on macOS by default).
#

# Acquire a lock using mkdir (atomic operation)
# Spins until lock is acquired, with stale lock detection
# Args:
#   $1 - lock directory path
#   $2 - max age in seconds before lock is considered stale (default: 60)
lock_file() {
  local lockdir="$1"
  local max_age="${2:-60}"
  
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Check if something exists at lock path (could be file or directory)
    if [[ -e "$lockdir" ]]; then
      local lock_mtime now lock_age
      # Cross-platform mtime: Linux uses -c %Y, macOS uses -f %m
      lock_mtime=$(stat -c %Y "$lockdir" 2>/dev/null) || lock_mtime=$(stat -f %m "$lockdir" 2>/dev/null) || lock_mtime=0
      now=$(date +%s)
      lock_age=$((now - lock_mtime))
      
      if [[ $lock_age -gt $max_age ]]; then
        # Lock is stale - remove it (handles both files and directories)
        if [[ -d "$lockdir" ]]; then
          rmdir "$lockdir" 2>/dev/null || true
        else
          rm -f "$lockdir" 2>/dev/null || true
        fi
        continue
      fi
    fi
    sleep 0.1
  done
}

# Release a lock by removing the directory
# Succeeds even if lock doesn't exist
unlock_file() {
  local lockdir="$1"
  rmdir "$lockdir" 2>/dev/null || true
}
