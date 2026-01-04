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
```

### Manual Installation

```bash
curl -fsSL https://raw.githubusercontent.com/athal7/ocdc/main/install.sh | bash
```

### Dependencies

- `jq` - JSON processor (auto-installed with Homebrew)
- `devcontainer` CLI - Install with: `npm install -g @devcontainers/cli`

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

## OpenCode Plugin

ocdc includes an OpenCode plugin for targeting devcontainers from within OpenCode sessions:

```bash
# Install the plugin
ocdc plugin install
```

Then in OpenCode:
```
/ocdc feature-x    # Target a devcontainer for this session
/ocdc              # Show current status
/ocdc off          # Disable, run commands on host
```

When a devcontainer is targeted:
- Most commands run inside the container via `ocdc exec`
- Git, file reading, and editors run on host
- Prefix with `HOST:` to force host execution

## License

MIT
