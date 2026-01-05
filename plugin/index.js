import { 
  mkdirSync, existsSync, readdirSync, unlinkSync, copyFileSync 
} from "fs"
import { join, dirname, basename } from "path"
import { fileURLToPath } from "url"
import { tool } from "@opencode-ai/plugin/tool"

import {
  loadSession,
  saveSession,
  deleteSession,
  resolveWorkspace,
  shouldRunOnHost,
  getSessionsDir,
  runWithTimeout,
  shellQuote,
} from "./helpers.js"

// Import from new core modules
import {
  up,
  exec,
  isContainerRunning,
  checkDevcontainerCli,
  getOverridePath,
  PATHS,
} from "./core/index.js"

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
    const destFile = join(commandDir, "devcontainer.md")
    
    // Always update command file to latest version
    mkdirSync(commandDir, { recursive: true })
    const sourceFile = join(__dirname, "command/devcontainer.md")
    if (existsSync(sourceFile)) {
      copyFileSync(sourceFile, destFile)
    }
    
    // Clean up old command file names
    const oldFiles = ["ocdc-use.md", "ocdc.md"]
    for (const oldName of oldFiles) {
      const oldFile = join(commandDir, oldName)
      if (existsSync(oldFile)) {
        unlinkSync(oldFile)
      }
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

/**
 * Build devcontainer exec command string for bash interception
 * 
 * @param {string} workspace - Workspace path (will be shell-quoted)
 * @param {string} command - Command to execute (passed verbatim to shell)
 * @returns {string} Shell command string
 */
function buildDevcontainerExecCommand(workspace, command) {
  const overridePath = getOverridePath(workspace)
  const hasOverride = existsSync(overridePath)
  
  let cmd = `devcontainer exec --workspace-folder ${shellQuote(workspace)}`
  if (hasOverride) {
    cmd += ` --override-config ${shellQuote(overridePath)}`
  }
  cmd += ` -- ${command}`
  
  return cmd
}

// ============ Plugin Export ============

export const devcontainers = async ({ client }) => {
  // Install command file if needed (don't block on slow API)
  runWithTimeout(() => installCommand(client), INIT_TIMEOUT_MS)
  
  // Cleanup stale sessions (don't block on slow API)
  runWithTimeout(() => cleanupStaleSessions(client), INIT_TIMEOUT_MS)
  
  return {
    tool: {
      // Execute command in devcontainer
      devcontainer_exec: tool({
        description: "Execute a command in the current devcontainer context. Use this when you need to run commands inside the container.",
        args: {
          command: tool.schema.string().describe("Command to execute"),
        },
        async execute(args, ctx) {
          const { sessionID } = ctx
          const { command } = args
          
          const session = loadSession(sessionID)
          if (!session?.workspace) {
            return "Error: No devcontainer context set for this session. Use `/devcontainer <branch>` first."
          }
          
          try {
            // Use the core exec function
            const result = await exec(session.workspace, command, { signal: ctx.abort })
            
            if (result.exitCode !== 0) {
              return `Command failed (exit ${result.exitCode}):\n${result.stderr || result.stdout}`
            }
            
            return result.stdout
          } catch (err) {
            if (err.name === 'AbortError') {
              return `Command cancelled.`
            }
            return `Command failed: ${err.message}`
          }
        }
      }),
      
      // Interactive command for manual devcontainer targeting
      devcontainer: tool({
        description: "Set active devcontainer for this session. Use 'off' to disable. Set create=true to create a new workspace if it doesn't exist.",
        args: {
          target: tool.schema.string().optional().describe(
            "Branch name (e.g., 'feature-x'), 'off' to disable, or empty for status"
          ),
          create: tool.schema.string().optional().describe(
            "Set to 'true' to create the workspace if it doesn't exist (requires confirmation)"
          ),
        },
        async execute(args, ctx) {
          const { sessionID, abort: signal } = ctx
          const { target, create } = args
          const shouldCreate = create === "true" || create === true
          
          // Verify devcontainer CLI is installed
          const hasCli = await checkDevcontainerCli()
          if (!hasCli) {
            return "devcontainer CLI not found.\n\nInstall with: `npm install -g @devcontainers/cli`"
          }
          
          // Status request (no target)
          if (!target || target.trim() === "") {
            const session = loadSession(sessionID)
            if (!session) {
              return "No devcontainer active for this session.\n\n" +
                     "Use `/devcontainer <branch>` to target a devcontainer."
            }
            const running = await isContainerRunning(session.workspace)
            return `Current devcontainer: ${session.repoName}/${session.branch}\n` +
                   `Workspace: ${session.workspace}\n` +
                   `Status: ${running ? "Running" : "Not running"}\n` +
                   `\nUse \`/devcontainer off\` to disable.`
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
          
          // Resolve workspace (check if clone already exists)
          const resolved = resolveWorkspace(target)
          
          if (!resolved) {
            // Workspace doesn't exist - try to create it using core up()
            try {
              const result = await up(target, {
                noOpen: true,
                cwd: process.cwd(),
                signal,
              })
              
              saveSession(sessionID, {
                branch: result.branch,
                workspace: result.workspace,
                repoName: result.repo,
              })
              
              return `Workspace created and session now targeting: ${result.repo}/${result.branch}\n` +
                     `Workspace: ${result.workspace}\n` +
                     `Port: ${result.port}\n\n` +
                     `All commands will run inside this container.\n` +
                     `Use \`/devcontainer off\` to disable, or prefix with \`HOST:\` to run on host.`
            } catch (err) {
              if (err.name === 'AbortError') {
                return `Workspace creation cancelled.`
              }
              // Auto-creation failed - ask for confirmation
              if (!shouldCreate) {
                return `No devcontainer clone found for '${target}' and automatic creation failed.\n\n` +
                       `Error: ${err.message}\n\n` +
                       `Would you like me to try creating it again? Call this tool again with create='true' to confirm.`
              }
              
              // User explicitly asked for creation and it still failed
              return `Failed to create workspace: ${err.message}`
            }
          }
          
          if (resolved.ambiguous) {
            const options = resolved.matches
              .map(m => `  - ${m.repoName}/${m.branch}`)
              .join("\n")
            return `Ambiguous branch '${target}' found in multiple repos:\n${options}\n\n` +
                   `Use \`/devcontainer <repo>/${target}\` to specify.`
          }
          
          const { workspace, repoName, branch } = resolved
          
          // Check if container is running
          const isRunning = await isContainerRunning(workspace)
          if (!isRunning) {
            // Container exists but not running - try to start it using core up()
            try {
              const result = await up(workspace, { noOpen: true, signal })
              
              saveSession(sessionID, { branch, workspace, repoName })
              
              return `Container started and session now targeting: ${repoName}/${branch}\n` +
                     `Workspace: ${workspace}\n` +
                     `Port: ${result.port}\n\n` +
                     `All commands will run inside this container.\n` +
                     `Use \`/devcontainer off\` to disable, or prefix with \`HOST:\` to run on host.`
            } catch (err) {
              if (err.name === 'AbortError') {
                return `Container start cancelled.`
              }
              // Auto-start failed - ask for confirmation
              if (!shouldCreate) {
                return `Devcontainer for '${branch}' exists but is not running and automatic start failed.\n\n` +
                       `Error: ${err.message}\n\n` +
                       `Workspace: ${workspace}\n\n` +
                       `Would you like me to try starting it again? Call this tool again with create='true' to confirm.`
              }
              
              // User explicitly asked for start and it still failed
              return `Failed to start container: ${err.message}`
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
                 `Use \`/devcontainer off\` to disable, or prefix with \`HOST:\` to run on host.`
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
      
      // Wrap with devcontainer exec (using safe command builder to prevent shell injection)
      output.args.command = buildDevcontainerExecCommand(session.workspace, cmd)
    }
  }
}

// Default export for OpenCode plugin discovery
export default devcontainers
