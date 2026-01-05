---
description: Target a devcontainer - /devcontainer <branch> or off
---

# /devcontainer

Route commands to a devcontainer for isolated development.

## Usage

```
/devcontainer <branch>        # Target branch (creates clone if needed)
/devcontainer <repo>/<branch> # Target specific repo's branch
/devcontainer off             # Stop routing, run on host
/devcontainer                 # Show current status
```

## Examples

```
/devcontainer feature-auth    # Work on feature-auth branch
/devcontainer api/main        # Work on api repo's main branch  
/devcontainer off             # Back to host execution
```

## What Happens

When you run `/devcontainer feature-x`:
1. Creates a shallow clone at `~/.cache/opencode-devcontainers/<repo>/feature-x` (if needed)
2. Starts the devcontainer with auto-assigned port
3. Routes subsequent bash commands to the container

Commands that stay on host (automatic):
- `git`, `gh`, `code`, `cursor` - version control and editors
- File reads via OpenCode tools - already on host filesystem
- Prefix any command with `HOST:` to force host execution
