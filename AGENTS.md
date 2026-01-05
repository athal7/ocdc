# Agent Instructions

## Pre-Commit: Documentation Check

Before committing changes, verify documentation is updated to reflect code changes:

1. **README.md** - Update if changes affect:
   - Plugin usage (`/devcontainer` command)
   - Configuration options (`~/.config/ocdc/config.json`)
   - Installation steps or dependencies
   - Usage examples

2. **CONTRIBUTING.md** - Update if changes affect:
   - Development setup or workflow
   - Test commands or patterns
   - Release process

3. **skill/ocdc/SKILL.md** - Update if changes affect:
   - Workflow or best practices
   - New commands or features
   - OpenCode integration

4. **plugin/command/devcontainer.md** - Update if changes affect:
   - Command arguments or behavior
   - Examples

## Post-PR: Release and Upgrade Workflow

After a PR is merged to main, semantic-release automatically:
1. Creates a new version based on commit messages
2. Publishes to npm
3. Creates a GitHub release

### Verify Release

```bash
gh release list -R athal7/opencode-devcontainers -L 1
npm view opencode-devcontainers version
```

### Upgrade

OpenCode automatically updates npm plugins on startup. Just restart OpenCode.

To force a specific version:
```json
{
  "plugin": ["opencode-devcontainers@5.0.0"]
}
```

### Config Migration (if needed)

Config file locations:
- Main config: `~/.config/ocdc/config.json`
- Cache/state: `~/.cache/ocdc/`

If config format changed, check release notes:

```bash
gh release view -R athal7/opencode-devcontainers
```
