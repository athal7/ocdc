/**
 * Path constants and utilities for opencode-devcontainers
 * 
 * Provides consistent path resolution across the plugin, respecting
 * environment variable overrides for testing and custom installations.
 */

import { join, resolve } from 'path'
import { homedir } from 'os'
import { createHash } from 'crypto'
import { mkdir, writeFile, realpath, access, constants } from 'fs/promises'
import { existsSync } from 'fs'

/**
 * Get path value, preferring env var over default
 */
function getPath(envVar, defaultPath) {
  return process.env[envVar] || defaultPath
}

/**
 * Path constants - all paths are derived from config/cache base dirs
 * Use getters to support dynamic env var changes (for testing)
 */
export const PATHS = {
  get config() {
    return getPath('OCDC_CONFIG_DIR', join(homedir(), '.config/opencode/devcontainers'))
  },
  get cache() {
    return getPath('OCDC_CACHE_DIR', join(homedir(), '.cache/opencode-devcontainers'))
  },
  // Clones live alongside opencode desktop worktrees for discoverability
  get clones() {
    return getPath('OCDC_CLONES_DIR', join(homedir(), '.local/share/opencode/clone'))
  },
  get ports() {
    return join(this.cache, 'ports.json')
  },
  get overrides() {
    return join(this.cache, 'overrides')
  },
  get configFile() {
    return join(this.config, 'config.json')
  },
  get sessions() {
    return getPath('OCDC_SESSIONS_DIR', join(this.cache, 'opencode-sessions'))
  },
}

/**
 * Generate a deterministic ID for a workspace path
 * Uses MD5 hash for consistent identification across sessions
 * 
 * @param {string} path - Absolute path to workspace
 * @returns {string} 32-character hex string
 */
export function pathId(path) {
  return createHash('md5').update(path).digest('hex')
}

/**
 * Resolve a path to its real path (following symlinks)
 * Returns the original path if it doesn't exist or can't be resolved
 * 
 * @param {string} path - Path to resolve
 * @returns {Promise<string>} Resolved path
 */
export async function resolvePath(path) {
  try {
    return await realpath(path)
  } catch {
    // Path doesn't exist or can't be resolved, return original
    return path
  }
}

/**
 * Check if a path exists
 * 
 * @param {string} path - Path to check
 * @returns {Promise<boolean>}
 */
export async function exists(path) {
  try {
    await access(path, constants.F_OK)
    return true
  } catch {
    return false
  }
}

/**
 * Ensure all required directories exist
 * Creates:
 * - config dir
 * - cache dir  
 * - overrides dir
 * - sessions dir
 * - ports.json (empty object if not exists)
 * - config.json (default config if not exists)
 * 
 * @returns {Promise<void>}
 */
export async function ensureDirs() {
  const dirs = [
    PATHS.config,
    PATHS.cache,
    PATHS.overrides,
    PATHS.sessions,
  ]

  // Create directories
  await Promise.all(dirs.map(dir => mkdir(dir, { recursive: true })))

  // Create ports.json if it doesn't exist
  if (!existsSync(PATHS.ports)) {
    await writeFile(PATHS.ports, '{}')
  }

  // Create config.json if it doesn't exist
  if (!existsSync(PATHS.configFile)) {
    const defaultConfig = {
      portRangeStart: 13000,
      portRangeEnd: 13099,
    }
    await writeFile(PATHS.configFile, JSON.stringify(defaultConfig, null, 2))
  }
}

/**
 * Default export for convenient importing
 */
export default {
  PATHS,
  pathId,
  resolvePath,
  exists,
  ensureDirs,
}
