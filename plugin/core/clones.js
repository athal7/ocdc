/**
 * Clone management for opencode-devcontainers
 * 
 * Creates isolated git clones for branch-based devcontainer development.
 * Worktrees don't work with devcontainers (the .git file path breaks inside
 * the container), so we use full clones with --reference for efficiency.
 */

import { join, basename, dirname } from 'path'
import { mkdir, rm, readdir, stat, copyFile, readFile, writeFile } from 'fs/promises'
import { existsSync } from 'fs'
import { PATHS, exists } from './paths.js'
import { clone, checkout, getRemoteUrl, getCurrentBranch, listIgnoredFiles } from './git.js'

// Lock files to skip (generated, cause merge conflicts)
const SKIP_FILES = new Set([
  'package-lock.json',
  'yarn.lock',
  'pnpm-lock.yaml',
  'Gemfile.lock',
  'Cargo.lock',
  'poetry.lock',
  'composer.lock',
])

// Max file size to copy (100KB) - secrets/config are small
const MAX_FILE_SIZE = 102400

// Max gitignored files per top-level directory - secrets have few, dependencies have many
const MAX_FILES_PER_DIR = 10

/**
 * Get the path where a clone would be created
 * 
 * @param {string} repo - Repository name
 * @param {string} branch - Branch name
 * @returns {string} Absolute path to clone directory
 */
export function getClonePath(repo, branch) {
  return join(PATHS.clones, repo, branch)
}

/**
 * Copy gitignored files from source repo to clone
 * 
 * These files (secrets, local config, etc.) are needed for the app to run but
 * aren't in git. Skips directories with many gitignored files (dependencies)
 * and large files.
 * 
 * @param {string} source - Source repository path
 * @param {string} dest - Destination clone path
 * @returns {Promise<number>} Number of files copied
 */
export async function copyGitignored(source, dest) {
  const ignoredFiles = await listIgnoredFiles(source)
  if (ignoredFiles.length === 0) return 0

  // Count files per top-level directory
  const dirFileCounts = new Map()
  for (const file of ignoredFiles) {
    const topDir = file.split('/')[0]
    const key = file.includes('/') ? topDir : '.'
    dirFileCounts.set(key, (dirFileCounts.get(key) || 0) + 1)
  }

  let copied = 0

  for (const relPath of ignoredFiles) {
    // Skip paths with parent directory references (defense in depth)
    if (relPath.includes('..')) continue

    // Skip lock files
    const filename = basename(relPath)
    if (SKIP_FILES.has(filename)) continue

    // Skip if directory has too many gitignored files (likely dependencies)
    const topDir = relPath.includes('/') ? relPath.split('/')[0] : '.'
    if (dirFileCounts.get(topDir) > MAX_FILES_PER_DIR) continue

    const srcPath = join(source, relPath)
    const destPath = join(dest, relPath)

    // Only copy files, not directories
    try {
      const srcStat = await stat(srcPath)
      if (!srcStat.isFile()) continue

      // Skip large files
      if (srcStat.size > MAX_FILE_SIZE) continue

      // Skip if already exists
      if (existsSync(destPath)) continue

      // Create parent directory and copy
      await mkdir(dirname(destPath), { recursive: true })
      await copyFile(srcPath, destPath)
      copied++
    } catch {
      // Skip files we can't read
    }
  }

  return copied
}

/**
 * Create a clone for a branch
 * 
 * @param {object} options
 * @param {string} options.repoRoot - Path to source repository
 * @param {string} options.branch - Branch name to create/checkout
 * @param {boolean} [options.force] - Force recreate if exists
 * @returns {Promise<{workspace: string, created: boolean, repoName: string, branch: string}>}
 */
export async function createClone(options) {
  const { repoRoot, branch, force = false } = options
  const repoName = basename(repoRoot)
  const workspace = getClonePath(repoName, branch)

  // Check if clone already exists
  if (await exists(workspace)) {
    if (!force) {
      return { workspace, created: false, repoName, branch }
    }
    // Force recreate - remove existing
    await rm(workspace, { recursive: true, force: true })
  }

  // Create clone directory
  await mkdir(dirname(workspace), { recursive: true })

  // Get remote URL if available
  const remoteUrl = await getRemoteUrl(repoRoot)

  if (remoteUrl) {
    // Clone from remote with reference for efficiency
    try {
      await clone({
        url: remoteUrl,
        dest: workspace,
        reference: repoRoot,
        branch,
      })
    } catch (e) {
      // Branch might not exist on remote - clone without branch, then create it
      if (e.message.includes('not found') || e.message.includes('did not match')) {
        await clone({
          url: remoteUrl,
          dest: workspace,
          reference: repoRoot,
        })
        await checkout(workspace, branch, { createBranch: true })
      } else {
        throw e
      }
    }
  } else {
    // Local clone
    await clone({
      url: repoRoot,
      dest: workspace,
    })
    // Check out branch (create if doesn't exist)
    const currentBranch = await getCurrentBranch(workspace)
    if (currentBranch !== branch) {
      await checkout(workspace, branch, { createBranch: true })
    }
  }

  // Copy gitignored files (secrets, local config)
  await copyGitignored(repoRoot, workspace)

  return { workspace, created: true, repoName, branch }
}

/**
 * List all clones
 * 
 * @param {object} [options]
 * @param {string} [options.repo] - Filter by repository name
 * @returns {Promise<Array<{workspace: string, repo: string, branch: string}>>}
 */
export async function listClones(options = {}) {
  const { repo: filterRepo } = options
  const clones = []

  if (!existsSync(PATHS.clones)) {
    return clones
  }

  const repos = await readdir(PATHS.clones)

  for (const repo of repos) {
    if (filterRepo && repo !== filterRepo) continue

    const repoPath = join(PATHS.clones, repo)
    const repoStat = await stat(repoPath).catch(() => null)
    if (!repoStat?.isDirectory()) continue

    const branches = await readdir(repoPath)

    for (const branch of branches) {
      const workspace = join(repoPath, branch)
      const gitDir = join(workspace, '.git')

      // Only include if it's a git repo
      if (existsSync(gitDir)) {
        clones.push({ workspace, repo, branch })
      }
    }
  }

  return clones
}

/**
 * Remove a clone
 * 
 * @param {string} repo - Repository name
 * @param {string} branch - Branch name
 * @returns {Promise<boolean>} True if removed, false if didn't exist
 */
export async function removeClone(repo, branch) {
  const workspace = getClonePath(repo, branch)

  if (!existsSync(workspace)) {
    return false
  }

  await rm(workspace, { recursive: true, force: true })
  return true
}

export default {
  getClonePath,
  copyGitignored,
  createClone,
  listClones,
  removeClone,
}
