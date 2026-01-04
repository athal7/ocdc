/**
 * opencode-devcontainers core module
 * 
 * This is the public API for programmatic access to devcontainer management.
 * Used by:
 * - The OpenCode plugin (plugin/index.js)
 * - opencode-pilot for autonomous sessions
 * 
 * @example
 * import { up, exec, down, list } from 'opencode-devcontainers/plugin/core/index.js'
 * 
 * // Start a devcontainer
 * const { workspace, port } = await up('feature-branch', { cwd: '/path/to/repo' })
 * 
 * // Run a command
 * const { stdout } = await exec(workspace, 'npm test')
 * 
 * // Stop and release port
 * await down(workspace)
 */

// High-level devcontainer operations
export {
  up,
  exec,
  down,
  list,
  isContainerRunning,
  checkDevcontainerCli,
  buildUpArgs,
  buildExecArgs,
} from './devcontainer.js'

// Clone management
export {
  createClone,
  listClones,
  removeClone,
  getClonePath,
  copyGitignored,
} from './clones.js'

// Port management
export {
  allocatePort,
  releasePort,
  listPorts,
  readPorts,
  writePorts,
  isPortFree,
  withLock,
} from './ports.js'

// Configuration
export {
  generateOverrideConfig,
  readDevcontainerJson,
  detectInternalPort,
  getOverridePath,
  loadUserConfig,
} from './config.js'

// Git operations
export {
  isGitRepo,
  getRepoRoot,
  getCurrentBranch,
  getRemoteUrl,
  clone,
  checkout,
  fetch,
  listIgnoredFiles,
} from './git.js'

// Paths and utilities
export {
  PATHS,
  pathId,
  resolvePath,
  exists,
  ensureDirs,
} from './paths.js'
