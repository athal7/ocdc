---
name: devcontainer
description: Target a devcontainer for this session
---

# /devcontainer

Target a devcontainer clone for command execution in this OpenCode session.

## Usage

```
/devcontainer [target]
```

## Arguments

- `target` - One of:
  - Empty: Show current status
  - `<branch>`: Target branch in current repo's clones
  - `<repo>/<branch>`: Target specific repo/branch
  - `off`: Disable devcontainer targeting

## Examples

```
/devcontainer              # Show current devcontainer status
/devcontainer feature-x    # Target feature-x branch clone
/devcontainer myapp/main   # Target main branch of myapp
/devcontainer off          # Disable, run commands on host
```

## Behavior

When a devcontainer is targeted:
- Most commands run inside the container via `ocdc exec`
- Git, file reading, and editors run on host
- Prefix with `HOST:` to force host execution

## Related

- `ocdc up <branch>` - Create and start a devcontainer clone
- `ocdc list` - List all devcontainer instances
- `ocdc down` - Stop a devcontainer
