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

### Parallel Processing

By default, items are processed sequentially. Use `--max-concurrent` to process multiple items in parallel, significantly speeding up session creation when you have many pending items:

```bash
# Process up to 3 items simultaneously
ocdc poll --max-concurrent 3

# Preview what would be processed
ocdc poll --dry-run --max-concurrent 3
```

**Note**: Each devcontainer creation runs `docker build` which can be resource-intensive. Start with 2-3 concurrent jobs and increase if your system handles it well.

### Error Handling

The poll system handles errors gracefully with automatic retries:

| Error Type | Behavior | Retries |
|------------|----------|---------|
| Rate limited | Exponential backoff | Yes, next cycle |
| Auth failed | Skip source | No (permanent) |
| Network timeout | Skip this cycle | Yes, next cycle |
| Repo not found | Skip item | No (permanent) |
| Clone failed | Mark error | Yes, up to 3 attempts |
| Devcontainer failed | Mark error | Yes, up to 3 attempts |

**Backoff strategy**: 1m → 2m → 4m → 8m... (max 1 hour) with 20% jitter

Error state is tracked in `~/.cache/ocdc/poll/errors.json`. Items that fail 3 times will not be retried until manually cleared.

Use `--skip-cleanup` to disable cleanup detection (for debugging):

```bash
ocdc poll --once --skip-cleanup
```

## License

MIT
