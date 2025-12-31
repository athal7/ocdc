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

```bash
# Clone the repo
git clone https://github.com/athal7/devcontainer-multi.git
cd devcontainer-multi

# Run the install script
./install.sh

# Or manually copy scripts to your PATH
cp bin/* ~/.local/bin/
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
# List all instances
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

Navigation:
- `j/k` or arrows: Move up/down
- `Enter`: Open selected instance
- `s`: Start devcontainer for current directory
- `b`: Start devcontainer for a branch
- `x`: Stop selected instance
- `X`: Stop all instances
- `p`: Prune stale entries
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

1. **Clone-based isolation**: When you run `dcup feature-x`, it creates a shallow clone at `~/.cache/devcontainer-clones/myapp/feature-x/`. Clones use `--reference` and `--dissociate` to share git objects with your main repo, saving disk space while remaining fully independent.

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
