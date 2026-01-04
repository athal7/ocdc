import { 
  mkdirSync, existsSync, readdirSync, unlinkSync, copyFileSync 
} from "fs"
import { join, dirname } from "path"
import { execSync, execFile } from "child_process"
import { promisify } from "util"
import { fileURLToPath } from "url"
import { tool } from "@opencode-ai/plugin/tool"

import {
  loadSession,
  saveSession,
  deleteSession,
  resolveWorkspace,
  shouldRunOnHost,
  checkContainerRunning,
  getSessionsDir,
  getCacheDir,
  runWithTimeout,
  buildOcdcExecArgs,
  buildOcdcExecCommandString,
} from "./helpers.js"

// Promisified execFile for non-blocking async execution
const execFileAsync = promisify(execFile)

// Timeout for init operations (2 seconds)
const INIT_TIMEOUT_MS = 2000

const __dirname = dirname(fileURLToPath(import.meta.url))

// ============ Internal Functions ============

async function installCommand(client) {
  try {
    const paths = await client.path.get()
    const configDir = paths.data?.config
    if (!configDir) return
    
    const commandDir = join(configDir, "command")
    const destFile = join(commandDir, "ocdc.md")
    
    // Always update command file to latest version
    mkdirSync(commandDir, { recursive: true })
    const sourceFile = join(__dirname, "command/ocdc.md")
    if (existsSync(sourceFile)) {
      copyFileSync(sourceFile, destFile)
    }
    
    // Clean up old command file name
    const oldFile = join(commandDir, "ocdc-use.md")
    if (existsSync(oldFile)) {
      unlinkSync(oldFile)
    }
  } catch {}
}

async function cleanupStaleSessions(client) {
  const sessionsDir = getSessionsDir()
  if (!existsSync(sessionsDir)) return
  
  try {
    const response = await client.session.list()
    const sessions = response.data || []
    const activeIDs = new Set(sessions.map(s => s.id))
    
    for (const file of readdirSync(sessionsDir)) {
      if (!file.endsWith(".json")) continue
      const sessionID = file.replace(".json", "")
      if (!activeIDs.has(sessionID)) {
        unlinkSync(join(sessionsDir, file))
      }
    }
  } catch {}
}

// ============ Plugin Export ============

export const OCDC = async ({ client }) => {
  // Install command file if needed (don't block on slow API)
  runWithTimeout(() => installCommand(client), INIT_TIMEOUT_MS)
  
  // Cleanup stale sessions (don't block on slow API)
  runWithTimeout(() => cleanupStaleSessions(client), INIT_TIMEOUT_MS)
  
  return {
    tool: {
      // Execute command in devcontainer
      ocdc_exec: tool({
        description: "Execute a command in the current devcontainer context. Use this when you need to run commands inside the container.",
        args: {
          command: tool.schema.string().describe("Command to execute"),
        },
        async execute(args, ctx) {
          const { sessionID } = ctx
          const { command } = args
          
          const session = loadSession(sessionID)
          if (!session?.workspace) {
            return "Error: No devcontainer context set for this session. Use ocdc_set_context first."
          }
          
          try {
            // Use async execFile to avoid blocking the event loop
            const { stdout } = await execFileAsync(
              "ocdc",
              buildOcdcExecArgs(session.workspace, command),
              { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024, signal: ctx.abort }
            )
            return stdout
          } catch (err) {
            if (err.name === 'AbortError') {
              return `Command cancelled.`
            }
            return `Command failed: ${err.message}\n${err.stderr || ""}`
          }
        }
      }),
      
      // Interactive command for manual devcontainer targeting
      ocdc: tool({
        description: "Set active devcontainer for this session. Use 'off' to disable, or 'repo/branch' for specific repo. Set create=true to create a new workspace if it doesn't exist.",
        args: {
          target: tool.schema.string().optional().describe(
            "Branch name (e.g., 'feature-x'), repo/branch (e.g., 'myapp/feature-x'), 'off' to disable, or empty for status"
          ),
          create: tool.schema.string().optional().describe(
            "Set to 'true' to create the workspace if it doesn't exist (requires confirmation)"
          ),
        },
        async execute(args, ctx) {
          const { sessionID } = ctx
          const { target, create } = args
          const shouldCreate = create === "true" || create === true
          
          // Verify CLI is installed
          try {
            execSync("which ocdc", { encoding: "utf-8", stdio: "pipe" })
          } catch {
            return "ocdc CLI not found.\n\nInstall with: `brew install athal7/tap/ocdc`"
          }
          
          // Status request (no target)
          if (!target || target.trim() === "") {
            const session = loadSession(sessionID)
            if (!session) {
              return "No devcontainer active for this session.\n\n" +
                     "Use `/ocdc <branch>` to target a devcontainer."
            }
            const running = checkContainerRunning(session.workspace)
            return `Current devcontainer: ${session.repoName}/${session.branch}\n` +
                   `Workspace: ${session.workspace}\n` +
                   `Status: ${running ? "Running" : "Not running"}\n` +
                   `\nUse \`/ocdc off\` to disable.`
          }
          
          // Disable request
          if (target === "off") {
            const session = loadSession(sessionID)
            deleteSession(sessionID)
            if (session) {
              return `Devcontainer mode disabled. Commands will now run on the host.`
            }
            return "No devcontainer was active for this session."
          }
          
          // Resolve workspace
          const resolved = resolveWorkspace(target)
          
          if (!resolved) {
            // Workspace doesn't exist - try to create it automatically
            try {
              // Use async execFile to avoid blocking the event loop
              await execFileAsync('ocdc', ['up', target], {
                encoding: "utf-8",
                maxBuffer: 10 * 1024 * 1024,
                timeout: 300000, // 5 minutes for container setup
                signal: ctx.abort,
              })
              
              // Re-resolve after creation
              const newResolved = resolveWorkspace(target)
              if (newResolved && !newResolved.ambiguous) {
                saveSession(sessionID, {
                  branch: newResolved.branch,
                  workspace: newResolved.workspace,
                  repoName: newResolved.repoName,
                })
                return `Workspace created and session now targeting: ${newResolved.repoName}/${newResolved.branch}\n` +
                       `Workspace: ${newResolved.workspace}\n\n` +
                       `All commands will run inside this container.\n` +
                       `Use \`/ocdc off\` to disable, or prefix with \`HOST:\` to run on host.`
              }
              return `Workspace created but could not auto-target.`
            } catch (err) {
              if (err.name === 'AbortError') {
                return `Workspace creation cancelled.`
              }
              // Auto-creation failed - ask for confirmation
              if (!shouldCreate) {
                return `No devcontainer clone found for '${target}' and automatic creation failed.\n\n` +
                       `Error: ${err.message}\n\n` +
                       `Would you like me to try creating it again? Call this tool again with create='true' to confirm, ` +
                       `or run manually: \`ocdc up ${target}\``
              }
              
              // User explicitly asked for creation and it still failed
              return `Failed to create workspace: ${err.message}\n${err.stderr || ""}`
            }
          }
          
          if (resolved.ambiguous) {
            const options = resolved.matches
              .map(m => `  - ${m.repoName}/${m.branch}`)
              .join("\n")
            return `Ambiguous branch '${target}' found in multiple repos:\n${options}\n\n` +
                   `Use \`/ocdc <repo>/${target}\` to specify.`
          }
          
          const { workspace, repoName, branch } = resolved
          
          // Check if container is running
          const isRunning = checkContainerRunning(workspace)
          if (!isRunning) {
            // Container exists but not running - try to start it automatically
            try {
              // Use async execFile to avoid blocking the event loop
              await execFileAsync('ocdc', ['up', target], {
                encoding: "utf-8",
                maxBuffer: 10 * 1024 * 1024,
                timeout: 300000,
                signal: ctx.abort,
              })
              
              saveSession(sessionID, { branch, workspace, repoName })
              return `Container started and session now targeting: ${repoName}/${branch}\n` +
                     `Workspace: ${workspace}\n\n` +
                     `All commands will run inside this container.\n` +
                     `Use \`/ocdc off\` to disable, or prefix with \`HOST:\` to run on host.`
            } catch (err) {
              if (err.name === 'AbortError') {
                return `Container start cancelled.`
              }
              // Auto-start failed - ask for confirmation
              if (!shouldCreate) {
                return `Devcontainer for '${branch}' exists but is not running and automatic start failed.\n\n` +
                       `Error: ${err.message}\n\n` +
                       `Workspace: ${workspace}\n\n` +
                       `Would you like me to try starting it again? Call this tool again with create='true' to confirm, ` +
                       `or run manually: \`ocdc up ${branch}\``
              }
              
              // User explicitly asked for start and it still failed
              return `Failed to start container: ${err.message}\n${err.stderr || ""}`
            }
          }
          
          // Save session state
          saveSession(sessionID, {
            branch,
            workspace,
            repoName,
          })
          
          return `Session now targeting: ${repoName}/${branch}\n` +
                 `Workspace: ${workspace}\n\n` +
                 `All commands will run inside this container.\n` +
                 `Use \`/ocdc off\` to disable, or prefix with \`HOST:\` to run on host.`
        }
      }),
    },
    
    // Intercept bash commands to run in container
    "tool.execute.before": async (input, output) => {
      // Only intercept bash commands
      if (input.tool !== "bash") return
      
      const session = loadSession(input.sessionID)
      if (!session?.workspace) return
      
      let cmd = output.args?.command?.trim()
      if (!cmd) return
      
      const hostCheck = shouldRunOnHost(cmd)
      
      // Check for HOST: escape hatch
      if (hostCheck === "escape") {
        output.args.command = cmd.replace(/^HOST:\s*/i, "")
        return
      }
      
      // Check if command should run on host
      if (hostCheck) return
      
      // Wrap with ocdc exec (using safe command builder to prevent shell injection)
      output.args.command = buildOcdcExecCommandString(session.workspace, cmd)
    }
  }
}

// Default export for OpenCode plugin discovery
export default OCDC
