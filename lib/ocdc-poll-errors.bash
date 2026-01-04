#!/usr/bin/env bash
#
# ocdc-poll-errors.bash - Error handling and retry logic for poll system
#
# Provides error type constants, retry policy functions, backoff calculation,
# and error state management for the poll orchestrator.
#
# Usage:
#   source "$(dirname "$0")/ocdc-poll-errors.bash"
#   poll_error_mark_item "$key" "$config" "$ERR_CLONE_FAILED" "message"
#
# Error Categories:
#   ERR_RATE_LIMITED      - API rate limited, exponential backoff, retry next cycle
#   ERR_AUTH_FAILED       - API auth failed, skip source permanently
#   ERR_NETWORK_TIMEOUT   - Network timeout, skip this cycle, retry next
#   ERR_REPO_NOT_FOUND    - Repo not found, skip item permanently
#   ERR_CLONE_FAILED      - Clone failed, retry up to 3 attempts
#   ERR_DEVCONTAINER_FAILED - Devcontainer failed, retry up to 3 attempts

# Prevent multiple sourcing
[[ -n "${_OCDC_POLL_ERRORS_LOADED:-}" ]] && return 0
_OCDC_POLL_ERRORS_LOADED=1

# Source paths library if not already loaded
_POLL_ERRORS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${OCDC_POLL_STATE_DIR:-}" ]]; then
  source "${_POLL_ERRORS_DIR}/ocdc-paths.bash"
fi

# Source file locking for state file updates
source "${_POLL_ERRORS_DIR}/ocdc-file-lock.bash"

# =============================================================================
# Error Type Constants
# =============================================================================

# Error type strings (used in state file and for policies)
readonly ERR_RATE_LIMITED="rate_limited"
readonly ERR_AUTH_FAILED="auth_failed"
readonly ERR_NETWORK_TIMEOUT="network_timeout"
readonly ERR_REPO_NOT_FOUND="repo_not_found"
readonly ERR_CLONE_FAILED="clone_failed"
readonly ERR_DEVCONTAINER_FAILED="devcontainer_failed"

# =============================================================================
# Retry Policy Functions
# =============================================================================

# Check if an error type is retryable
# Returns 0 (true) if retryable, 1 (false) if not
# Usage: poll_error_is_retryable "$ERR_CLONE_FAILED"
poll_error_is_retryable() {
  local error_type="$1"
  
  case "$error_type" in
    "$ERR_RATE_LIMITED")      return 0 ;;  # Yes, retry next cycle
    "$ERR_AUTH_FAILED")       return 1 ;;  # No, permanent
    "$ERR_NETWORK_TIMEOUT")   return 0 ;;  # Yes, retry next cycle
    "$ERR_REPO_NOT_FOUND")    return 1 ;;  # No, permanent
    "$ERR_CLONE_FAILED")      return 0 ;;  # Yes, up to 3 attempts
    "$ERR_DEVCONTAINER_FAILED") return 0 ;;  # Yes, up to 3 attempts
    *)                        return 1 ;;  # Unknown errors are not retried
  esac
}

# Get maximum retry attempts for an error type
# Returns 0 for "retry indefinitely on next poll cycle"
# Usage: max=$(poll_error_max_attempts "$ERR_CLONE_FAILED")
poll_error_max_attempts() {
  local error_type="$1"
  
  case "$error_type" in
    "$ERR_RATE_LIMITED")      echo "0" ;;  # Unlimited (next cycle)
    "$ERR_AUTH_FAILED")       echo "0" ;;  # N/A (not retryable)
    "$ERR_NETWORK_TIMEOUT")   echo "0" ;;  # Unlimited (next cycle)
    "$ERR_REPO_NOT_FOUND")    echo "0" ;;  # N/A (not retryable)
    "$ERR_CLONE_FAILED")      echo "3" ;;  # 3 attempts
    "$ERR_DEVCONTAINER_FAILED") echo "3" ;;  # 3 attempts
    *)                        echo "0" ;;
  esac
}

# =============================================================================
# Backoff Calculation
# =============================================================================

# Calculate backoff delay in seconds with exponential growth and jitter
# Formula: base * 2^(attempt-1) with 20% jitter, capped at 1 hour
# Usage: delay=$(poll_error_calculate_backoff 2)
poll_error_calculate_backoff() {
  local attempt="$1"
  local base_delay=60  # 1 minute base
  local max_delay=3600  # 1 hour max
  
  # Calculate exponential delay: base * 2^(attempt-1)
  local exponent=$((attempt - 1))
  local delay=$((base_delay * (1 << exponent)))
  
  # Cap at max delay
  if [[ $delay -gt $max_delay ]]; then
    delay=$max_delay
  fi
  
  # Add 20% jitter (random between -20% and +20%)
  # Use $RANDOM which gives 0-32767
  local jitter_percent=$(( (RANDOM % 41) - 20 ))  # -20 to +20
  local jitter=$(( delay * jitter_percent / 100 ))
  delay=$((delay + jitter))
  
  # Ensure delay is positive
  if [[ $delay -lt 1 ]]; then
    delay=1
  fi
  
  echo "$delay"
}

# =============================================================================
# Error State Management
# =============================================================================

# Internal: Get state file path
_poll_error_state_file() {
  echo "${OCDC_POLL_STATE_DIR}/processed.json"
}

# Internal: Ensure state file exists
_poll_error_ensure_state_file() {
  local state_file
  state_file=$(_poll_error_state_file)
  mkdir -p "$(dirname "$state_file")"
  [[ -f "$state_file" ]] || echo '{}' > "$state_file"
}

# Mark an item with an error state
# Increments attempt counter if already in error state
# Usage: poll_error_mark_item "$key" "$config_id" "$ERR_CLONE_FAILED" "message"
poll_error_mark_item() {
  local key="$1"
  local config_id="$2"
  local error_type="$3"
  local message="$4"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Get current attempts (0 if not exists or not in error state)
  local current_attempts
  current_attempts=$(jq -r --arg key "$key" '
    .[$key] |
    if .state == "error" then (.error.attempts // 0) else 0 end
  ' "$state_file" 2>/dev/null || echo "0")
  
  local new_attempts=$((current_attempts + 1))
  local max_attempts
  max_attempts=$(poll_error_max_attempts "$error_type")
  
  # Calculate next retry time
  local backoff_seconds
  backoff_seconds=$(poll_error_calculate_backoff "$new_attempts")
  local next_retry
  # macOS date uses -v, Linux uses -d
  if date -v+1S >/dev/null 2>&1; then
    next_retry=$(date -u -v+"${backoff_seconds}S" +"%Y-%m-%dT%H:%M:%SZ")
  else
    next_retry=$(date -u -d "+${backoff_seconds} seconds" +"%Y-%m-%dT%H:%M:%SZ")
  fi
  
  # Update state file with locking
  local lock_file="${state_file}.lock"
  lock_file "$lock_file"
  trap 'unlock_file "$lock_file"' EXIT
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" \
     --arg config "$config_id" \
     --arg type "$error_type" \
     --arg msg "$message" \
     --arg ts "$timestamp" \
     --argjson attempts "$new_attempts" \
     --argjson max "$max_attempts" \
     --arg next "$next_retry" \
     '.[$key] = {
       state: "error",
       config: $config,
       error: {
         type: $type,
         message: $msg,
         occurred_at: $ts,
         attempts: $attempts,
         max_attempts: $max,
         next_retry: $next
       }
     }' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
  
  trap - EXIT
  unlock_file "$lock_file"
}

# Check if an item should be retried now
# Returns 0 (true) if should retry, 1 (false) if not
# Usage: if poll_error_should_retry "$key"; then ...
poll_error_should_retry() {
  local key="$1"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  # Check if key exists and is in error state
  local item_state
  item_state=$(jq -r --arg key "$key" '.[$key].state // "unknown"' "$state_file" 2>/dev/null)
  
  # Not in error state = not a retry (might be new or already processed)
  if [[ "$item_state" != "error" ]]; then
    return 1
  fi
  
  # Get error info
  local error_json
  error_json=$(jq -c --arg key "$key" '.[$key].error // {}' "$state_file" 2>/dev/null)
  
  local error_type attempts max_attempts next_retry
  error_type=$(echo "$error_json" | jq -r '.type // ""')
  attempts=$(echo "$error_json" | jq -r '.attempts // 0')
  max_attempts=$(echo "$error_json" | jq -r '.max_attempts // 0')
  next_retry=$(echo "$error_json" | jq -r '.next_retry // ""')
  
  # Check if error type is retryable
  if ! poll_error_is_retryable "$error_type"; then
    return 1
  fi
  
  # Check if max attempts reached (max_attempts=0 means unlimited)
  if [[ "$max_attempts" != "0" ]] && [[ "$attempts" -ge "$max_attempts" ]]; then
    return 1
  fi
  
  # Check if retry time has passed
  if [[ -n "$next_retry" ]]; then
    local now_ts next_ts
    now_ts=$(date +%s)
    # Parse ISO timestamp (stored as UTC with Z suffix)
    # macOS: use -u for UTC and strip the Z suffix
    # Linux: date -d handles ISO format directly
    local next_retry_no_z="${next_retry%Z}"
    if date -j -u -f "%Y-%m-%dT%H:%M:%S" "$next_retry_no_z" +%s >/dev/null 2>&1; then
      next_ts=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$next_retry_no_z" +%s)
    else
      next_ts=$(date -d "$next_retry" +%s 2>/dev/null || echo "0")
    fi
    
    if [[ "$now_ts" -lt "$next_ts" ]]; then
      return 1  # Too early to retry
    fi
  fi
  
  # All checks passed - should retry
  return 0
}

# Check if an item should be permanently skipped
# Returns 0 (true) if should skip, 1 (false) if not
# Usage: if poll_error_should_skip "$key"; then continue; fi
poll_error_should_skip() {
  local key="$1"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  # Check if key exists and is in error state
  local item_state
  item_state=$(jq -r --arg key "$key" '.[$key].state // "unknown"' "$state_file" 2>/dev/null)
  
  if [[ "$item_state" != "error" ]]; then
    return 1  # Not in error state, don't skip
  fi
  
  # Get error type
  local error_type
  error_type=$(jq -r --arg key "$key" '.[$key].error.type // ""' "$state_file" 2>/dev/null)
  
  # Non-retryable errors should be skipped permanently
  if ! poll_error_is_retryable "$error_type"; then
    return 0
  fi
  
  return 1
}

# Clear error state for an item (remove from state file)
# Usage: poll_error_clear_item "$key"
poll_error_clear_item() {
  local key="$1"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  # Update state file with locking
  local lock_file="${state_file}.lock"
  lock_file "$lock_file"
  trap 'unlock_file "$lock_file"' EXIT
  
  local tmp
  tmp=$(mktemp)
  jq --arg key "$key" 'del(.[$key])' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
  
  trap - EXIT
  unlock_file "$lock_file"
}

# Get error info for an item as JSON
# Returns empty object if not in error state
# Usage: info=$(poll_error_get_info "$key")
poll_error_get_info() {
  local key="$1"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  jq -c --arg key "$key" '.[$key].error // {}' "$state_file" 2>/dev/null || echo "{}"
}

# Check if an item is in error state
# Returns 0 (true) if in error state, 1 (false) otherwise
# Usage: if poll_error_is_errored "$key"; then ...
poll_error_is_errored() {
  local key="$1"
  
  _poll_error_ensure_state_file
  local state_file
  state_file=$(_poll_error_state_file)
  
  local item_state
  item_state=$(jq -r --arg key "$key" '.[$key].state // "unknown"' "$state_file" 2>/dev/null)
  
  [[ "$item_state" == "error" ]]
}
