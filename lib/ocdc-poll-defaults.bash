#!/usr/bin/env bash
#
# ocdc-poll-defaults.bash - Default values for poll source types
#
# Provides default item mappings, prompts, session names, agents,
# and fetch options for each source type (linear_issue, github_issue, github_pr).
#
# Usage:
#   source "$(dirname "$0")/ocdc-poll-defaults.bash"
#   mapping=$(poll_config_get_default_item_mapping "github_issue")

# Prevent multiple sourcing
[[ -n "${_OCDC_POLL_DEFAULTS_LOADED:-}" ]] && return 0
_OCDC_POLL_DEFAULTS_LOADED=1

# =============================================================================
# Item Mapping Defaults
# =============================================================================

# Get default item mapping for a source type as JSON
# Usage: poll_config_get_default_item_mapping "linear_issue"
poll_config_get_default_item_mapping() {
  local source_type="$1"
  
  case "$source_type" in
    linear_issue)
      cat << 'EOF'
{
  "key": ".identifier",
  "repo": ".team.key",
  "repo_short": ".team.key",
  "number": ".identifier",
  "title": ".title",
  "body": ".description // \"\"",
  "url": ".url",
  "branch": ".identifier"
}
EOF
      ;;
    github_issue)
      cat << 'EOF'
{
  "key": "\"\\(.repository.full_name)-issue-\\(.number)\"",
  "repo": ".repository.full_name",
  "repo_short": ".repository.name",
  "number": ".number",
  "title": ".title",
  "body": ".body // \"\"",
  "url": ".html_url",
  "branch": "\"issue-\\(.number)\""
}
EOF
      ;;
    github_pr)
      cat << 'EOF'
{
  "key": "\"\\(.repository.full_name)-pr-\\(.number)\"",
  "repo": ".repository.full_name",
  "repo_short": ".repository.name",
  "number": ".number",
  "title": ".title",
  "body": ".body // \"\"",
  "url": ".html_url",
  "branch": ".headRefName // \"pr-\\(.number)\""
}
EOF
      ;;
    *)
      echo "{}" 
      ;;
  esac
}

# =============================================================================
# Prompt Defaults
# =============================================================================

# Get default prompt template for a source type
# Usage: poll_config_get_default_prompt "linear_issue"
poll_config_get_default_prompt() {
  local source_type="$1"
  
  case "$source_type" in
    linear_issue)
      cat << 'EOF'
Work on Linear issue {number}: {title}
{url}

{body}
EOF
      ;;
    github_issue)
      cat << 'EOF'
Work on issue #{number}: {title}
{url}

{body}
EOF
      ;;
    github_pr)
      cat << 'EOF'
Review PR #{number}: {title}
{url}

{body}
EOF
      ;;
    *)
      echo "Work on {number}: {title}"
      ;;
  esac
}

# =============================================================================
# Session Defaults
# =============================================================================

# Get default session name template for a source type
# Usage: poll_config_get_default_session_name "linear_issue"
poll_config_get_default_session_name() {
  local source_type="$1"
  
  case "$source_type" in
    linear_issue)
      echo "ocdc-linear-{number}"
      ;;
    github_issue)
      echo "ocdc-{repo_short}-issue-{number}"
      ;;
    github_pr)
      echo "ocdc-{repo_short}-review-{number}"
      ;;
    *)
      echo "ocdc-{number}"
      ;;
  esac
}

# Get default agent for a source type
# Usage: poll_config_get_default_agent "github_pr"
poll_config_get_default_agent() {
  local source_type="$1"
  
  case "$source_type" in
    github_pr)
      echo "plan"  # Read-only for reviews
      ;;
    *)
      echo "build"  # Can write code for issues
      ;;
  esac
}

# =============================================================================
# Fetch Option Defaults
# =============================================================================

# Get default fetch options for a source type as JSON
# Usage: poll_config_get_default_fetch_options "linear_issue"
poll_config_get_default_fetch_options() {
  local source_type="$1"
  
  case "$source_type" in
    linear_issue)
      cat << 'EOF'
{
  "assignee": null,
  "state": ["started", "unstarted"],
  "exclude_labels": [],
  "team": null
}
EOF
      ;;
    github_issue)
      cat << 'EOF'
{
  "assignee": null,
  "state": "open",
  "labels": [],
  "repo": null,
  "repos": null,
  "org": null
}
EOF
      ;;
    github_pr)
      cat << 'EOF'
{
  "review_requested": "@me",
  "author": null,
  "review_decision": null,
  "state": "open",
  "repo": null,
  "repos": null,
  "org": null
}
EOF
      ;;
    *)
      echo "{}"
      ;;
  esac
}
