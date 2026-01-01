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

### Quick Start

```bash
# Copy example config
mkdir -p ~/.config/ocdc/polls
cp "$(brew --prefix ocdc)/share/ocdc/examples/github-issues.yaml" ~/.config/ocdc/polls/

# Edit with your repo and label
vim ~/.config/ocdc/polls/github-issues.yaml

# Start automatic polling (runs every 5 minutes)
brew services start ocdc

# View logs
tail -f "$(brew --prefix)/var/log/ocdc-poll.log"
```

### Configuration

Poll configs live in `~/.config/ocdc/polls/`. Each config defines:
- `fetch_command` - Shell command that outputs JSON array of items
- `item_mapping` - jq expressions to extract fields
- `repo_paths` - Map repo names to local paths
- `prompt` - Template for OpenCode session prompt

See the example configs in [`share/ocdc/examples/`](share/ocdc/examples/) for the full schema.

### Manual Polling

Run a single poll cycle without setting up the service:

```bash
ocdc poll --once
```

## License

MIT
