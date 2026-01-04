---
name: ocdc
description: Concurrent branch development with devcontainers using clone-based isolation
---

# ocdc - OpenCode DevContainers

When working on projects with devcontainers, use `ocdc` for concurrent branch development instead of git worktrees.

## Why Not Git Worktrees?

Git worktrees don't work inside devcontainers because:
- The `.git` file in a worktree references a path outside the mounted directory
- Devcontainers mount a single directory, breaking the worktree link

## ocdc Clone Workflow

### Start Working on a New Branch

```bash
# From your main project directory
cd ~/Projects/myapp

# Create clone and start devcontainer for the branch
ocdc up feature-x
```

This:
1. Creates a clone at `~/.cache/devcontainer-clones/myapp/feature-x/`
2. Uses `git clone --reference --dissociate` to save disk space
3. Checks out the branch (creates it if needed)
4. Assigns a unique port (13000-13099)
5. Starts the devcontainer with an override config

### Managing Multiple Branches

```bash
# See all running instances
ocdc list

# Switch to working on a different branch
ocdc go feature-x       # In VS Code terminal: opens in new window
                        # Elsewhere: prints cd command to copy

# Execute commands in any container
ocdc exec --workspace ~/.cache/devcontainer-clones/myapp/feature-x npm test
```

### OpenCode Integration

When using OpenCode with ocdc:

```bash
# Target a specific devcontainer for this session
/ocdc feature-x

# Commands now run in that container automatically
# Git commands still run on host (repo is mounted)
```

### Stopping and Cleanup

```bash
# Stop current container
ocdc down

# Stop all containers
ocdc down --all

# Stop and remove the clone directory
ocdc down --remove-clone

# Clean up stale entries (containers that were stopped externally)
ocdc down --prune
```

### Clone Directory Structure

```
~/.cache/devcontainer-clones/
  myapp/
    main/           # Clone for main branch
    feature-x/      # Clone for feature-x branch
    feature-y/      # Clone for feature-y branch
  other-repo/
    main/
```

### Port Assignments

Ports are tracked in `~/.cache/ocdc/ports.json`:

```json
{
  "/Users/me/.cache/devcontainer-clones/myapp/main": {
    "port": 13000,
    "repo": "myapp",
    "branch": "main"
  },
  "/Users/me/.cache/devcontainer-clones/myapp/feature-x": {
    "port": 13001,
    "repo": "myapp",
    "branch": "feature-x"
  }
}
```

### Best Practices

1. **One branch per clone**: Each branch gets its own isolated environment
2. **Clean up after merge**: Run `ocdc down --remove-clone` when done with a branch
3. **Use `ocdc list`**: Check what's running before starting new instances
4. **Port range**: Default 13000-13099 supports up to 100 concurrent instances
