# Contributing to opencode-devcontainers

Thanks for your interest in contributing!

## Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/athal7/opencode-devcontainers.git
   cd opencode-devcontainers
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Install the devcontainer CLI (required for actual container operations):
   ```bash
   npm install -g @devcontainers/cli
   ```

4. Set up the plugin for local testing:
   ```bash
   # Link plugin to OpenCode plugins directory
   mkdir -p ~/.config/opencode/plugins
   ln -sf "$(pwd)/plugin" ~/.config/opencode/plugins/opencode-devcontainers
   
   # Add to opencode.json
   # "plugin": ["/path/to/opencode-devcontainers/plugin"]
   ```

## Running Tests

Run the full test suite:
```bash
npm test
```

Run tests in watch mode:
```bash
npm run test:watch
```

## Project Structure

```
opencode-devcontainers/
├── plugin/
│   ├── index.js           # Plugin entry point
│   ├── helpers.js          # Utility functions
│   ├── command/
│   │   └── devcontainer.md # Slash command definition
│   └── core/               # Core modules
│       ├── clones.js       # Clone management
│       ├── config.js       # Override config generation
│       ├── devcontainer.js # Devcontainer operations
│       ├── git.js          # Git operations
│       ├── paths.js        # Path constants
│       └── ports.js        # Port allocation
├── skill/
│   └── ocdc/
│       └── SKILL.md        # Agent skill documentation
└── test/
    └── unit/               # Unit tests
```

## Writing Tests

Tests use Node.js built-in test runner. Example:

```javascript
import { describe, test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert'

describe('myFeature', () => {
  beforeEach(() => {
    // Setup
  })

  afterEach(() => {
    // Cleanup
  })

  test('does something', () => {
    assert.strictEqual(actual, expected)
  })
})
```

## Code Style

- Use ES modules (`import`/`export`)
- Use async/await for async operations
- Handle errors explicitly
- Add JSDoc comments for public functions

## Submitting Changes

1. Create a feature branch: `git checkout -b my-feature`
2. Make your changes
3. Run tests: `npm test`
4. Commit with conventional commit message:
   - `feat:` for new features
   - `fix:` for bug fixes
   - `docs:` for documentation
   - `refactor:` for refactoring
   - `test:` for tests
   - `chore:` for maintenance
5. Push and open a pull request

## Releasing

Releases are automated via semantic-release:

1. Merge PR to main
2. CI analyzes commit messages and determines version bump
3. Publishes to npm automatically
4. Creates GitHub release

No manual version bumping needed - just use conventional commits!
