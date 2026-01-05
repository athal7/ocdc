# opencode-devcontainers

OpenCode plugin for running multiple devcontainer instances with auto-assigned ports and branch-based isolation.

> **Version 0.x** - Pre-1.0 software. Minor versions may contain breaking changes.

## Why?

When working on multiple branches, you need isolated development environments. Git worktrees don't work with devcontainers because the `.git` file points outside the container.

**opencode-devcontainers** solves this by:
- Creating shallow clones for each branch (fully self-contained)
- Auto-assigning ports from a configurable range (13000-13099)
- Generating ephemeral override configs (your devcontainer.json stays clean)
- Tracking active instances to avoid conflicts

## Installation

Add to your `~/.config/opencode/opencode.json`:

```json
{
  "plugin": ["opencode-devcontainers"]
}
```

OpenCode automatically installs npm plugins on startup.

### Dependencies

- `devcontainer` CLI - Install with: `npm install -g @devcontainers/cli`

## Usage

In OpenCode, use the `/devcontainer` slash command:

```
/devcontainer feature-x    # Start/target a devcontainer for this branch
/devcontainer myapp/main   # Target specific repo/branch
/devcontainer              # Show current status
/devcontainer off          # Disable, run commands on host
```

When a devcontainer is targeted:
- Most commands run inside the container automatically
- Git operations and file reading run on host
- Prefix with `HOST:` to force host execution

## Configuration

`~/.config/ocdc/config.json`:
```json
{
  "portRangeStart": 13000,
  "portRangeEnd": 13099
}
```

## How It Works

1. **Clones**: Creates `~/.cache/devcontainer-clones/myapp/feature-x/` with a shallow clone. Gitignored secrets are auto-copied from main repo.
2. **Ports**: Generates ephemeral override config with unique port, passed via `--override-config`.
3. **Tracking**: Active instances tracked in `~/.cache/ocdc/ports.json`

## Integration with opencode-pilot

When using [opencode-pilot](https://github.com/athal7/opencode-pilot) for automated issue processing, configure your `repos.yaml` to include the `/devcontainer` command in the prompt template:

```yaml
repos:
  myorg/myrepo:
    session:
      prompt_template: |
        /devcontainer issue-{number}

        {title}

        {body}
```

This starts an isolated devcontainer for each issue automatically.

## Related

- [opencode-pilot](https://github.com/athal7/opencode-pilot) - Automation layer for OpenCode (notifications, mobile UI, polling)

## License

MIT
