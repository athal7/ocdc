```
      ⚡
  ___  ___ ___  ___ 
 / _ \/ __/ _ \/ __|
| (_) | (_| (_) | (__ 
 \___/ \___\___/ \___|
      ⚡
   OpenCode DevContainers
```

Run multiple devcontainer instances simultaneously with auto-assigned ports and branch management.

## Why?

When working on multiple branches, you need isolated development environments. Git worktrees don't work with devcontainers because the `.git` file points outside the container.

**ocdc** solves this by:
- Creating shallow clones for each branch (fully self-contained)
- Auto-assigning ports from a configurable range (13000-13099)
- Generating ephemeral override configs (your devcontainer.json stays clean)
- Tracking active instances to avoid conflicts

## Installation

### Homebrew (Recommended)

```bash
brew install athal7/tap/ocdc

# Enable automatic polling (optional)
brew services start ocdc
```

### Manual Installation

```bash
curl -fsSL https://raw.githubusercontent.com/athal7/ocdc/main/install.sh | bash
```

### Dependencies

- `jq` - JSON processor (auto-installed with Homebrew)
- `tmux` - Terminal multiplexer (auto-installed with Homebrew)
- `devcontainer` CLI - Install with: `npm install -g @devcontainers/cli`
- `opencode` - Required for polling features: `npm install -g @opencode/cli`

## Usage

```bash
ocdc up                 # Start devcontainer (port 13000)
ocdc up feature-x       # Start for branch (port 13001)
ocdc                    # Interactive TUI
ocdc list               # List instances
ocdc exec bash          # Execute in container
ocdc go feature-x       # Navigate to clone
ocdc down               # Stop current
ocdc down --all         # Stop all
ocdc clean              # Remove orphaned clones
```

## Configuration

`~/.config/ocdc/config.json`:
```json
{
  "portRangeStart": 13000,
  "portRangeEnd": 13099
}
```

## How it works

1. **Clones**: `ocdc up feature-x` creates `~/.cache/devcontainer-clones/myapp/feature-x/`. Gitignored secrets are auto-copied.
2. **Ports**: Ephemeral override with unique port, passed via `--override-config`.
3. **Tracking**: `~/.cache/ocdc/ports.json`

## Automatic Polling (Optional)

ocdc can automatically poll external sources (GitHub PRs, Linear issues) and create devcontainer sessions with OpenCode to work on them.

### Prerequisites

Polling uses MCP (Model Context Protocol) servers configured in your OpenCode config. Add the appropriate MCP servers to `~/.config/opencode/opencode.json`:

**For GitHub issues/PRs:**
```json
{
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.githubcopilot.com/mcp/",
      "enabled": true
    }
  }
}
```

**For Linear issues:**
```json
{
  "mcp": {
    "linear": {
      "type": "remote",
      "url": "https://mcp.linear.app/sse",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer ${LINEAR_API_TOKEN}"
      }
    }
  }
}
```

### Quick Start

```bash
# Copy example config
mkdir -p ~/.config/ocdc/polls
cp "$(brew --prefix)/share/ocdc/examples/github-issues.yaml" ~/.config/ocdc/polls/

# Edit with your repo mappings
vim ~/.config/ocdc/polls/github-issues.yaml

# Start automatic polling (runs every 5 minutes)
brew services start ocdc

# View logs
tail -f "$(brew --prefix)/var/log/ocdc-poll.log"
```

**Note**: The OpenCode plugin is automatically installed to `~/.config/opencode/plugins/ocdc/` during Homebrew installation.

### Configuration

Poll configs live in `~/.config/ocdc/polls/`. Each config defines:
- `source_type` - One of: `github_issue`, `github_pr`, `linear_issue`
- `repo_filters` - Rules for mapping items to local repositories
- `fetch` - Optional fetch options (see below)
- `prompt.template` - Template for OpenCode session prompt (optional)
- `session.name_template` - Template for tmux session name (optional)
- `cleanup` - Optional cleanup configuration for merged/closed items

**Fetch options by source type:**

| Option | github_issue | github_pr | linear_issue |
|--------|--------------|-----------|--------------|
| `assignee` | `@me` | - | `@me` |
| `author` | - | filter by PR author | - |
| `review_requested` | - | `@me` | - |
| `review_decision` | - | CHANGES_REQUESTED, APPROVED, REVIEW_REQUIRED | - |
| `state` | open/closed | open/closed | array of states |
| `labels` | array | - | - |
| `exclude_labels` | - | - | array |
| `repo` | owner/repo | owner/repo | - |
| `repos` | array of repos | array of repos | - |
| `org` | organization | organization | - |
| `team` | - | - | team key |

**Available template variables**: `{key}`, `{repo}`, `{repo_short}`, `{number}`, `{title}`, `{body}`, `{url}`, `{branch}`

Example configs are installed to `$(brew --prefix)/share/ocdc/examples/` and documented in the [examples directory](share/ocdc/examples/).

### Automatic Cleanup

When PRs are merged or closed, ocdc automatically detects this and cleans up resources after a configurable grace period:

```yaml
cleanup:
  on: [merged, closed]  # Terminal states that trigger cleanup
  delay: 5m             # Grace period before cleanup (default: 5 minutes)
  actions:              # Actions to perform (in order)
    - kill_session      # Kill the tmux session
    - stop_container    # Stop the devcontainer
    - remove_clone      # Remove the clone directory (only if git is clean)
```

**Safety**: The `remove_clone` action will skip directories with uncommitted or unpushed changes.

### Manual Polling

Run a single poll cycle without setting up the service:

```bash
ocdc poll --once
```

Use `--skip-cleanup` to disable cleanup detection (for debugging):

```bash
ocdc poll --once --skip-cleanup
```

### Self-Iteration (Automatic Issue Readiness)

Self-iteration automatically evaluates issues and marks them as ready for work based on priority, dependencies, and WIP limits. Supports both GitHub and Linear via MCP.

**Enable in `~/.config/ocdc/config.json`:**

```json
{
  "self_iteration": {
    "enabled": true,
    "ready_label": "ocdc:ready"
  },
  "wip_limits": {
    "global_max": 5
  }
}
```

**Configure repositories in `~/.config/ocdc/repos.yaml`:**

```yaml
repos:
  # GitHub example
  myorg/backend:
    repo_path: ~/code/backend
    issue_tracker:
      source_type: github_issue
      fetch_options:
        repo: myorg/backend
      ready_action:
        type: add_label
        label: "ocdc:ready"
    readiness:
      labels:
        exclude: ["blocked", "needs-design"]
      priority:
        labels:
          - label: critical
            weight: 100
          - label: high
            weight: 50
    wip_limits:
      max_concurrent: 2
  
  # Linear example (no label action needed - uses workflow states)
  myorg/linear-project:
    repo_path: ~/code/linear-project
    issue_tracker:
      source_type: linear_issue
      fetch_options:
        team: "ENG"
        assignee: "@me"
      ready_action:
        type: none
```

**How it works:**

1. On each poll cycle, ocdc fetches issues via MCP (GitHub or Linear)
2. Issues are scored by priority with age as a tiebreaker (FIFO)
3. Blocked issues are excluded (labels, body references, unchecked task lists)
4. Top candidates have their `ready_action` executed (up to WIP limits)
5. The regular poll cycle then picks up ready issues

**Priority scoring:**

- **Explicit labels**: Configure weights for labels like `critical`, `high`, `medium`
- **Inferred signals** (when no priority label):
  - Milestone: +20 points
  - Reactions: +5 per thumbs-up (capped at 30)
  - Comments: +2 per comment (capped at 20)
  - Assignee: +15 if assigned
- **Age bonus**: +1 point per day since creation

**Dependency detection:**

- Body patterns: "blocked by #X", "depends on #X", "requires #X", "after #X"
- Task lists: Issues with multiple unchecked checkboxes are considered tracking issues
- Blocking labels: Configurable labels like `blocked`, `waiting-on-external`

**Run evaluation only (no session creation):**

```bash
ocdc poll --evaluate-only
```

See `share/ocdc/examples/repos.yaml` for full configuration options.

## License

MIT
