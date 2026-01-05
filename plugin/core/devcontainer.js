/**
 * Devcontainer CLI wrapper for opencode-devcontainers
 * 
 * High-level orchestration of devcontainer operations:
 * - up: Start a devcontainer with port allocation
 * - exec: Run commands inside a container
 * - down: Stop a container and release port
 * - list: List running containers
 */

import { spawn } from 'child_process'
import { basename } from 'path'
import { PATHS, ensureDirs } from './paths.js'
import { allocatePort, releasePort, readPorts, getContainerPort, updatePortAllocation } from './ports.js'
import { generateOverrideConfig, getOverridePath } from './config.js'
import { createClone, getClonePath } from './clones.js'
import { getCurrentBranch, getRepoRoot } from './git.js'
import { existsSync } from 'fs'

/**
 * Run a command and return a promise with the result
 * 
 * @param {string} cmd - Command to run
 * @param {string[]} args - Arguments
 * @param {object} [options] - spawn options
 * @param {AbortSignal} [options.signal] - Abort signal for cancellation (Node.js 15.4+)
 * @returns {Promise<{stdout: string, stderr: string, exitCode: number, success: boolean}>}
 */
async function runCommand(cmd, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      ...options,
    })

    let stdout = ''
    let stderr = ''

    child.stdout.on('data', data => {
      stdout += data.toString()
    })

    child.stderr.on('data', data => {
      stderr += data.toString()
    })

    child.on('close', exitCode => {
      resolve({
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        exitCode,
        success: exitCode === 0,
      })
    })

    child.on('error', reject)
  })
}

/**
 * Check if the devcontainer CLI is installed
 * 
 * @returns {Promise<boolean>}
 */
export async function checkDevcontainerCli() {
  try {
    const result = await runCommand('which', ['devcontainer'])
    return result.success
  } catch {
    return false
  }
}

/**
 * Build arguments for devcontainer up command
 * 
 * @param {string} workspace - Workspace path
 * @param {string} overridePath - Override config path
 * @param {object} [options]
 * @param {boolean} [options.removeExisting] - Remove existing container
 * @returns {string[]}
 */
export function buildUpArgs(workspace, overridePath, options = {}) {
  const args = [
    'up',
    '--workspace-folder', workspace,
    '--override-config', overridePath,
  ]

  if (options.removeExisting) {
    args.push('--remove-existing-container')
  }

  return args
}

/**
 * Build arguments for devcontainer exec command
 * 
 * @param {string} workspace - Workspace path
 * @param {string} command - Command to execute
 * @param {object} [options]
 * @param {string} [options.overridePath] - Override config path
 * @returns {string[]}
 */
export function buildExecArgs(workspace, command, options = {}) {
  const args = [
    'exec',
    '--workspace-folder', workspace,
  ]

  if (options.overridePath) {
    args.push('--override-config', options.overridePath)
  }

  // Use sh -c to properly handle commands with arguments, pipes, and redirects
  args.push('--', 'sh', '-c', command)

  return args
}

/**
 * Start a devcontainer
 * 
 * Orchestrates:
 * 1. Create clone if branch specified
 * 2. Allocate port
 * 3. Generate override config
 * 4. Run devcontainer up
 * 
 * @param {string} workspaceOrBranch - Workspace path or branch name
 * @param {object} [options]
 * @param {boolean} [options.removeExisting] - Remove existing container
 * @param {boolean} [options.noOpen] - Don't open VS Code
 * @param {boolean} [options.dryRun] - Return command without executing
 * @param {string} [options.cwd] - Working directory (for branch resolution)
 * @param {AbortSignal} [options.signal] - Abort signal for cancellation
 * @returns {Promise<{workspace: string, port: number, repo: string, branch: string}>}
 */
export async function up(workspaceOrBranch, options = {}) {
  await ensureDirs()

  let workspace = workspaceOrBranch
  let repoName
  let branch

  // Check if it's a branch name (not an absolute path)
  if (!workspaceOrBranch.startsWith('/')) {
    // It's a branch name - create a clone
    const cwd = options.cwd || process.cwd()
    const repoRoot = await getRepoRoot(cwd)
    
    if (!repoRoot) {
      throw new Error('Not in a git repository. Run from a repo directory or specify a workspace path.')
    }

    const cloneResult = await createClone({
      repoRoot,
      branch: workspaceOrBranch,
    })

    workspace = cloneResult.workspace
    repoName = cloneResult.repoName
    branch = cloneResult.branch
  } else {
    // It's a workspace path
    repoName = basename(workspace)
    branch = await getCurrentBranch(workspace) || 'unknown'
  }

  // Check for devcontainer.json
  const devcontainerPath = existsSync(`${workspace}/.devcontainer/devcontainer.json`)
    ? `${workspace}/.devcontainer/devcontainer.json`
    : existsSync(`${workspace}/.devcontainer.json`)
      ? `${workspace}/.devcontainer.json`
      : null

  if (!devcontainerPath) {
    throw new Error(`No devcontainer.json found in ${workspace}`)
  }

  // Allocate port
  const portAllocation = await allocatePort(workspace, repoName, branch)
  const port = portAllocation.port

  // Generate override config
  const overridePath = await generateOverrideConfig(workspace, port)

  // Build command args
  const args = buildUpArgs(workspace, overridePath, {
    removeExisting: options.removeExisting,
  })

  if (options.dryRun) {
    return {
      workspace,
      port,
      repo: repoName,
      branch,
      dryRun: true,
      command: `devcontainer ${args.join(' ')}`,
    }
  }

  // Run devcontainer up
  let result
  try {
    result = await runCommand('devcontainer', args, {
      signal: options.signal,
    })
  } catch (err) {
    // Clean up port allocation on abort or error
    await releasePort(workspace)
    throw err
  }

  if (!result.success) {
    // Clean up port allocation on failure
    await releasePort(workspace)
    throw new Error(`devcontainer up failed: ${result.stderr}`)
  }

  // Verify actual port after container starts
  // The container may have started on a different port if there was a race condition
  // or if an existing container was reused. Retry a few times as container may still
  // be registering with Docker immediately after devcontainer up returns.
  let actualPort = port
  let containerPort = null
  for (let i = 0; i < 3 && containerPort === null; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, 500))
    containerPort = await getContainerPort(workspace)
  }
  if (containerPort !== null && containerPort !== port) {
    // Container started on a different port - update our tracking
    await updatePortAllocation(workspace, containerPort)
    actualPort = containerPort
  }

  return {
    workspace,
    port: actualPort,
    repo: repoName,
    branch,
    stdout: result.stdout,
  }
}

/**
 * Execute a command in a devcontainer
 * 
 * @param {string} workspace - Workspace path
 * @param {string} command - Command to execute
 * @param {object} [options]
 * @param {AbortSignal} [options.signal] - Abort signal
 * @returns {Promise<{stdout: string, stderr: string, exitCode: number}>}
 */
export async function exec(workspace, command, options = {}) {
  const overridePath = getOverridePath(workspace)
  const hasOverride = existsSync(overridePath)

  const args = buildExecArgs(workspace, command, {
    overridePath: hasOverride ? overridePath : undefined,
  })

  const result = await runCommand('devcontainer', args, {
    signal: options.signal,
  })

  return {
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
  }
}

/**
 * Stop a devcontainer and release its port
 * 
 * @param {string} workspace - Workspace path
 * @returns {Promise<void>}
 */
export async function down(workspace) {
  // Release port allocation
  await releasePort(workspace)

  // Note: We don't actually stop the container here because:
  // 1. devcontainer CLI doesn't have a "down" command
  // 2. VS Code manages the container lifecycle
  // The port release is the main action - the container will be
  // stopped when VS Code closes or the user runs docker stop.
}

/**
 * List all port allocations with live container status
 * 
 * Returns port allocations with additional status information:
 * - status: 'up' if container is running on the recorded port, 'down' if not running,
 *           'mismatch' if container is running but on a different port
 * - actualPort: the actual port the container is running on (if running)
 * 
 * @param {object} [options]
 * @param {boolean} [options.sync] - If true, auto-sync ports.json when mismatch detected (default: false)
 * @returns {Promise<Array<{workspace: string, port: number, repo: string, branch: string, started: string, status: string, actualPort?: number}>>}
 */
export async function list(options = {}) {
  const ports = await readPorts()
  
  const results = await Promise.all(
    Object.entries(ports).map(async ([workspace, data]) => {
      const actualPort = await getContainerPort(workspace)
      let status = 'down'
      
      if (actualPort !== null) {
        if (actualPort === data.port) {
          status = 'up'
        } else {
          status = 'mismatch'
          // Auto-sync if requested
          if (options.sync) {
            await updatePortAllocation(workspace, actualPort)
          }
        }
      }
      
      return {
        workspace,
        port: options.sync && actualPort !== null ? actualPort : data.port,
        repo: data.repo,
        branch: data.branch,
        started: data.started,
        status,
        ...(actualPort !== null && actualPort !== data.port ? { actualPort } : {}),
      }
    })
  )
  
  return results
}

/**
 * Check if a container is running for a workspace
 * 
 * This is a heuristic check - we look for a docker container
 * with a label matching the workspace.
 * 
 * @param {string} workspace - Workspace path
 * @returns {Promise<boolean>}
 */
export async function isContainerRunning(workspace) {
  try {
    // Look for container with devcontainer.local_folder label
    const result = await runCommand('docker', [
      'ps',
      '--filter', `label=devcontainer.local_folder=${workspace}`,
      '--format', '{{.ID}}',
    ])
    
    return result.success && result.stdout.length > 0
  } catch {
    return false
  }
}

// Export runCommand for testing
export { runCommand }

export default {
  checkDevcontainerCli,
  buildUpArgs,
  buildExecArgs,
  up,
  exec,
  down,
  list,
  isContainerRunning,
  runCommand,
}
