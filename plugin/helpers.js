import { 
  readFileSync, writeFileSync, mkdirSync, existsSync, 
  readdirSync, unlinkSync, statSync 
} from "fs"
import { join, basename } from "path"
import { execSync } from "child_process"

// ============ Utility Functions ============

/**
 * Wraps a promise with a timeout. If the promise doesn't resolve within
 * the specified time, the timeout rejects with 'TIMEOUT'.
 */
export function withTimeout(promise, ms) {
  let timeoutId
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error('TIMEOUT')), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId))
}

/**
 * Runs an async function with a timeout, returning undefined on timeout or error.
 * Use this for fire-and-forget operations that shouldn't block.
 */
export async function runWithTimeout(fn, ms) {
  try {
    return await withTimeout(fn(), ms)
  } catch {
    return undefined
  }
}

// Directory getters - respect environment variables
export function getCacheDir() {
  return process.env.OCDC_CACHE_DIR || 
    join(process.env.HOME, ".cache/opencode-devcontainers")
}

export function getSessionsDir() {
  return process.env.OCDC_SESSIONS_DIR || 
    join(getCacheDir(), "opencode-sessions")
}

export function getClonesDir() {
  return process.env.OCDC_CLONES_DIR ||
    join(process.env.HOME, ".cache/devcontainer-clones")
}

// Commands that should always run on host, not in container
export const HOST_COMMANDS = [
  // File navigation
  'cd', 'ls', 'pwd', 'find', 'tree',
  // File reading (opencode uses these)
  'cat', 'head', 'tail', 'less', 'more', 'wc',
  // File editing/searching (opencode uses these)
  'sed', 'awk', 'grep', 'rg', 'ed',
  // Git (always on host - repo is mounted)
  'git',
  // Editors/IDEs
  'code', 'vim', 'nvim', 'nano', 'open', 'cursor',
  // System inspection
  'which', 'type', 'echo', 'env', 'printenv', 'whoami', 'hostname',
  // devcontainer command (prevent recursion)
  'devcontainer',
  // Package managers (global installs on host)
  'brew', 'apt', 'apt-get', 'yum', 'dnf',
]

// ============ Session Management ============

function getSessionFile(sessionID) {
  return join(getSessionsDir(), `${sessionID}.json`)
}

export function loadSession(sessionID) {
  const file = getSessionFile(sessionID)
  if (!existsSync(file)) return null
  try {
    return JSON.parse(readFileSync(file, "utf-8"))
  } catch {
    return null
  }
}

export function saveSession(sessionID, state) {
  const sessionsDir = getSessionsDir()
  mkdirSync(sessionsDir, { recursive: true })
  writeFileSync(getSessionFile(sessionID), JSON.stringify({
    ...state,
    activatedAt: new Date().toISOString()
  }, null, 2))
}

export function deleteSession(sessionID) {
  const file = getSessionFile(sessionID)
  if (existsSync(file)) {
    unlinkSync(file)
  }
}

// ============ Workspace Resolution ============

export function resolveWorkspace(branchArg) {
  const clonesDir = getClonesDir()
  let repoName = null
  let branch = branchArg
  
  // Handle repo/branch syntax
  if (branchArg.includes("/")) {
    const parts = branchArg.split("/")
    repoName = parts[0]
    branch = parts.slice(1).join("/")
  }
  
  // If repo specified, look directly
  if (repoName) {
    const clonePath = join(clonesDir, repoName, branch)
    if (existsSync(clonePath)) return { workspace: clonePath, repoName, branch }
    return null
  }
  
  // Try to infer repo from current directory
  try {
    const gitRoot = execSync("git rev-parse --show-toplevel", { 
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"]
    }).trim()
    repoName = basename(gitRoot)
    const clonePath = join(clonesDir, repoName, branch)
    if (existsSync(clonePath)) return { workspace: clonePath, repoName, branch }
  } catch {}
  
  // Search all repos for this branch
  if (existsSync(clonesDir)) {
    const matches = []
    for (const repo of readdirSync(clonesDir)) {
      const repoPath = join(clonesDir, repo)
      try {
        const stat = statSync(repoPath)
        if (!stat.isDirectory()) continue
      } catch { continue }
      
      const clonePath = join(repoPath, branch)
      if (existsSync(clonePath)) {
        matches.push({ workspace: clonePath, repoName: repo, branch })
      }
    }
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) {
      return { ambiguous: true, matches }
    }
  }
  
  return null
}

// ============ Command Classification ============

export function shouldRunOnHost(command) {
  if (!command || !command.trim()) return true
  
  const trimmed = command.trim()
  
  // Check for HOST: escape hatch (case-insensitive)
  if (trimmed.toUpperCase().startsWith("HOST:")) {
    return "escape"
  }
  
  const firstWord = trimmed.split(/\s+/)[0]
  return HOST_COMMANDS.includes(firstWord)
}

// ============ Secure Command Execution ============

/**
 * Shell-quotes a string for safe inclusion in a shell command.
 * Uses single quotes which prevent all shell interpretation except for
 * single quotes themselves, which are escaped using the '"'"' pattern.
 * 
 * Returns the original string if it contains only safe characters.
 */
export function shellQuote(str) {
  // Safe characters that don't need quoting
  if (/^[a-zA-Z0-9_\-./=:@]+$/.test(str)) {
    return str
  }
  // Escape single quotes: close quote, add double-quoted single quote, reopen quote
  // "it's" becomes 'it'"'"'s'
  return "'" + str.replace(/'/g, "'\"'\"'") + "'"
}
