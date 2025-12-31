# devcontainer-multi

Run multiple devcontainer instances simultaneously with auto-assigned ports and branch management.

## Why?

When working on multiple branches of the same project, you often need isolated development environments. Git worktrees don't work with devcontainers because the `.git` file in a worktree points to the main repo's `.git` directory, which doesn't exist inside the container.

This tool solves the problem by:
- Creating shallow clones for each branch (fully self-contained, works with devcontainers)
- Auto-assigning ports from a configurable range (13000-13099 by default)
- Generating ephemeral override configs (repo's devcontainer.json is never modified)
- Tracking active instances to avoid conflicts

## Installation

### Homebrew (recommended)

```bash
brew install athal7/tap/devcontainer-multi
```

### Quick install (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/athal7/devcontainer-multi/main/install.sh | bash
```

This installs to `~/.local/bin`. To install elsewhere:

```bash
curl -fsSL https://raw.githubusercontent.com/athal7/devcontainer-multi/main/install.sh | bash -s -- /usr/local/bin
```

### From source

```bash
git clone https://github.com/athal7/devcontainer-multi.git
cd devcontainer-multi
./install.sh
```

### Dependencies

- `jq` - JSON processor
- `devcontainer` CLI - `npm install -g @devcontainers/cli`
- `git`

## Usage

### Start a devcontainer

```bash
cd ~/Projects/myapp

# Start devcontainer for current directory
dcup                    # Starts on port 13000

# Start devcontainer for a specific branch (creates clone)
dcup feature-x          # Starts on port 13001
dcup bugfix-123         # Starts on port 13002
```

### Navigate to existing clones

```bash
# In VS Code terminal: opens new VS Code window
# In other terminals: prints cd command
dcgo feature-x

# Force VS Code
dcgo --vscode feature-x

# List available clones
dcgo
```

### Manage instances

```bash
# List all instances and orphaned clones
dclist

# Stop current instance
dcdown

# Stop all instances
dcdown --all

# Stop and remove clone
dcdown --remove-clone

# Remove stale port assignments
dcdown --prune
```

### Execute commands in container

```bash
dcexec bash
dcexec bin/rails console
dcexec npm test
```

### Interactive TUI

```bash
dctui
```

The TUI shows both tracked containers and orphaned clones. Navigation:

- `↑/↓` or `j/k`: Move selection
- `Enter`: Open/start selected instance
- `n`: New devcontainer (prompts for branch)
- `d`: Stop/delete selected (with option to remove clone)
- `D`: Stop all instances
- `r`: Refresh
- `q`: Quit

## Configuration

Create `~/.config/devcontainer-multi/config.json`:

```json
{
  "portRangeStart": 13000,
  "portRangeEnd": 13099
}
```

## How it works

1. **Clone-based isolation**: When you run `dcup feature-x`, it creates a shallow clone at `~/.cache/devcontainer-clones/myapp/feature-x/`. Clones use `--reference` and `--dissociate` to share git objects with your main repo, saving disk space while remaining fully independent. Gitignored files (secrets, `.env`, keys) under 100KB are automatically copied to the clone.

2. **Port override**: The tool generates an ephemeral override file that sets a unique port mapping:
   ```json
   {
     "name": "myapp (port 13001)",
     "runArgs": ["-p", "13001:3000"]
   }
   ```
   This is passed to `devcontainer up --override-config`, leaving your repo's devcontainer.json untouched.

3. **Port tracking**: Active port assignments are tracked in `~/.cache/devcontainer-multi/ports.json`.

## File locations

| Path | Purpose |
|------|---------|
| `~/.config/devcontainer-multi/config.json` | User configuration |
| `~/.cache/devcontainer-multi/ports.json` | Port assignments |
| `~/.cache/devcontainer-multi/overrides/` | Ephemeral override configs |
| `~/.cache/devcontainer-clones/` | Branch clones |

## License

MIT
