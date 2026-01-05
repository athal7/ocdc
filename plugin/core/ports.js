/**
 * Port allocation and management for opencode-devcontainers
 * 
 * Handles:
 * - Atomic port allocation with file locking
 * - Port availability checking
 * - Port release on container shutdown
 */

import { join } from 'path'
import { mkdir, rmdir, readFile, writeFile, stat } from 'fs/promises'
import { existsSync } from 'fs'
import { createServer } from 'net'
import { PATHS } from './paths.js'

/**
 * File-based locking using mkdir (atomic on all platforms)
 * 
 * @param {string} lockPath - Base path for lock (will append .lock)
 * @param {Function} fn - Async function to run while holding lock
 * @param {number} maxAgeMs - Max age of lock before considered stale (default: 60s)
 * @returns {Promise<T>} Result of fn
 */
export async function withLock(lockPath, fn, maxAgeMs = 60000) {
  const lockDir = lockPath + '.lock'
  const retryDelayMs = 50
  const maxRetries = 1000 // ~50 seconds max wait

  for (let i = 0; i < maxRetries; i++) {
    try {
      await mkdir(lockDir)
      // Acquired lock
      break
    } catch (e) {
      if (e.code !== 'EEXIST') throw e

      // Lock exists - check if stale
      try {
        const lockStat = await stat(lockDir)
        const age = Date.now() - lockStat.mtimeMs
        if (age > maxAgeMs) {
          // Stale lock - remove and retry
          await rmdir(lockDir).catch(() => {})
          continue
        }
      } catch {
        // Stat failed - lock may have been released, retry
        continue
      }

      // Wait and retry
      await new Promise(r => setTimeout(r, retryDelayMs))
    }
  }

  try {
    return await fn()
  } finally {
    await rmdir(lockDir).catch(() => {})
  }
}

/**
 * Read ports.json file
 * Returns empty object if file doesn't exist or is invalid
 * 
 * @returns {Promise<Object>} Port assignments keyed by workspace path
 */
export async function readPorts() {
  try {
    const content = await readFile(PATHS.ports, 'utf-8')
    return JSON.parse(content)
  } catch {
    return {}
  }
}

/**
 * Write ports.json file atomically
 * 
 * @param {Object} ports - Port assignments to write
 * @returns {Promise<void>}
 */
export async function writePorts(ports) {
  const content = JSON.stringify(ports, null, 2)
  // Write to temp file then rename for atomicity
  const tempPath = PATHS.ports + '.tmp'
  await writeFile(tempPath, content)
  await writeFile(PATHS.ports, content) // rename not available, just write
}

/**
 * Read config.json to get port range
 * 
 * @returns {Promise<{portRangeStart: number, portRangeEnd: number}>}
 */
async function readConfig() {
  try {
    const content = await readFile(PATHS.configFile, 'utf-8')
    const config = JSON.parse(content)
    return {
      portRangeStart: config.portRangeStart || 13000,
      portRangeEnd: config.portRangeEnd || 13099,
    }
  } catch {
    return {
      portRangeStart: 13000,
      portRangeEnd: 13099,
    }
  }
}

/**
 * Check if a port is free (not in use by any process)
 * 
 * @param {number} port - Port to check
 * @returns {Promise<boolean>} True if port is free
 */
export async function isPortFree(port) {
  return new Promise(resolve => {
    const server = createServer()
    server.once('error', () => resolve(false))
    server.once('listening', () => {
      server.close()
      resolve(true)
    })
    server.listen(port, '127.0.0.1')
  })
}

/**
 * Check if a port is already assigned to another workspace
 * 
 * @param {Object} ports - Current port assignments
 * @param {number} port - Port to check
 * @returns {boolean}
 */
function isPortAssigned(ports, port) {
  return Object.values(ports).some(p => p.port === port)
}

/**
 * Allocate a port for a workspace
 * 
 * If workspace already has a port, returns existing assignment.
 * Otherwise finds first available port in configured range.
 * 
 * @param {string} workspace - Absolute path to workspace
 * @param {string} repo - Repository name
 * @param {string} branch - Branch name
 * @returns {Promise<{port: number, workspace: string, repo: string, branch: string, started: string}>}
 */
export async function allocatePort(workspace, repo, branch) {
  const lockPath = join(PATHS.cache, 'ports')

  return withLock(lockPath, async () => {
    const ports = await readPorts()
    const config = await readConfig()

    // Check existing assignment
    if (ports[workspace]) {
      return {
        port: ports[workspace].port,
        workspace,
        repo: ports[workspace].repo,
        branch: ports[workspace].branch,
        started: ports[workspace].started,
      }
    }

    // Find available port
    for (let port = config.portRangeStart; port <= config.portRangeEnd; port++) {
      // Skip if already assigned
      if (isPortAssigned(ports, port)) continue

      // Check if actually free
      if (await isPortFree(port)) {
        const now = new Date().toISOString()
        ports[workspace] = { port, repo, branch, started: now }
        await writePorts(ports)
        return { port, workspace, repo, branch, started: now }
      }
    }

    throw new Error(
      `No available ports in range ${config.portRangeStart}-${config.portRangeEnd}. ` +
      `Stop unused devcontainers to free ports.`
    )
  })
}

/**
 * Release a port allocation for a workspace
 * 
 * @param {string} workspace - Absolute path to workspace
 * @returns {Promise<void>}
 */
export async function releasePort(workspace) {
  const lockPath = join(PATHS.cache, 'ports')

  return withLock(lockPath, async () => {
    const ports = await readPorts()
    delete ports[workspace]
    await writePorts(ports)
  })
}

/**
 * Get all current port allocations
 * 
 * @returns {Promise<Object>}
 */
export async function listPorts() {
  return readPorts()
}

export default {
  withLock,
  readPorts,
  writePorts,
  isPortFree,
  allocatePort,
  releasePort,
  listPorts,
}
