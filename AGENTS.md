# Agent Instructions

## Pre-Commit: Documentation Check

Before committing changes, verify documentation is updated to reflect code changes:

1. **README.md** - Update if changes affect:
   - CLI commands or flags (`ocdc <command>`)
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

## Post-PR: Release and Upgrade Workflow

After a PR is merged to main, follow this workflow to upgrade the local installation:

### 1. Watch CI Run

Watch the CI workflow until it completes (creates release via semantic-release):

```bash
gh run watch -R athal7/ocdc
```

### 2. Verify Release Created

Confirm the new release was published:

```bash
gh release list -R athal7/ocdc -L 1
```

### 3. Wait for Homebrew Formula Update

The formula is auto-updated after release. Poll until available:

```bash
brew update
brew info athal7/tap/ocdc | head -3
```

Compare version with the release. If not updated yet, wait and retry.

### 4. Upgrade Installation

```bash
brew upgrade athal7/tap/ocdc
```

### 5. Verify Upgrade

```bash
ocdc version
```

### 6. Config Migration (if needed)

Config file locations:
- Main config: `~/.config/ocdc/config.json`
- Cache/state: `~/.cache/ocdc/`

If config format changed, check release notes for breaking changes:

```bash
gh release view -R athal7/ocdc
```
