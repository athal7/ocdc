---
name: ocdc-use
description: Target a devcontainer for this session
---

# /ocdc-use

Target a devcontainer clone for command execution in this OpenCode session.

## Usage

```
/ocdc-use [target]
```

## Arguments

- `target` - One of:
  - Empty: Show current status
  - `<branch>`: Target branch in current repo's clones
  - `<repo>/<branch>`: Target specific repo/branch
  - `off`: Disable devcontainer targeting

## Examples

```
/ocdc-use              # Show current devcontainer status
/ocdc-use feature-x    # Target feature-x branch clone
/ocdc-use myapp/main   # Target main branch of myapp
/ocdc-use off          # Disable, run commands on host
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
