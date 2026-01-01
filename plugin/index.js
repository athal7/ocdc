import { 
  mkdirSync, existsSync, readdirSync, unlinkSync, copyFileSync 
} from "fs"
import { join, dirname } from "path"
import { execSync } from "child_process"
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
} from "./helpers.js"

const __dirname = dirname(fileURLToPath(import.meta.url))

// Re-export helpers
export { 
  loadSession, 
  saveSession, 
  deleteSession, 
  resolveWorkspace, 
  shouldRunOnHost 
} from "./helpers.js"
export { HOST_COMMANDS } from "./helpers.js"

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
  // Install command file if needed
  await installCommand(client)
  
  // Cleanup stale sessions
  await cleanupStaleSessions(client)
  
  return {
    tool: {
      // Set context for this session - used by poll orchestrator
      ocdc_set_context: tool({
        description: "Set the devcontainer/workspace context for this OpenCode session. Called by ocdc poll to configure sessions.",
        args: {
          workspace: tool.schema.string().describe("Absolute path to workspace/clone directory"),
          branch: tool.schema.string().describe("Git branch name"),
          source_url: tool.schema.string().optional().describe("PR or issue URL (GitHub/Linear)"),
          source_type: tool.schema.string().optional().describe("Source type: github_pr, github_issue, linear_issue"),
        },
        async execute(args, ctx) {
          const { sessionID } = ctx
          const { workspace, branch, source_url, source_type } = args
          
          if (!existsSync(workspace)) {
            return `Error: Workspace does not exist: ${workspace}`
          }
          
          // Extract repo name from workspace path
          const parts = workspace.split("/")
          const repoName = parts[parts.length - 2] || "unknown"
          
          saveSession(sessionID, {
            workspace,
            branch,
            repoName,
            sourceUrl: source_url,
            sourceType: source_type,
          })
          
          return `Context set:\n` +
                 `  Workspace: ${workspace}\n` +
                 `  Branch: ${branch}\n` +
                 `  Repo: ${repoName}\n` +
                 (source_url ? `  Source: ${source_url}\n` : "") +
                 `\nAll bash commands will now run inside this devcontainer.`
        }
      }),
      
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
            const result = execSync(`ocdc exec --workspace "${session.workspace}" -- ${command}`, {
              encoding: "utf-8",
              maxBuffer: 10 * 1024 * 1024,
            })
            return result
          } catch (err) {
            return `Command failed: ${err.message}\n${err.stderr || ""}`
          }
        }
      }),
      
      // Interactive command for manual devcontainer targeting
      ocdc: tool({
        description: "Set active devcontainer for this session. Use 'off' to disable, or 'repo/branch' for specific repo.",
        args: {
          target: tool.schema.string().optional().describe(
            "Branch name (e.g., 'feature-x'), repo/branch (e.g., 'myapp/feature-x'), 'off' to disable, or empty for status"
          ),
        },
        async execute(args, ctx) {
          const { sessionID } = ctx
          const { target } = args
          
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
                   (session.sourceUrl ? `Source: ${session.sourceUrl}\n` : "") +
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
            return `No devcontainer clone found for '${target}'.\n\n` +
                   `Create one with: \`ocdc up ${target}\``
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
            return `Devcontainer for '${branch}' exists but is not running.\n\n` +
                   `Workspace: ${workspace}\n\n` +
                   `Start it with: \`ocdc up ${branch}\``
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
      
      // Wrap with ocdc exec
      output.args.command = `ocdc exec --workspace "${session.workspace}" -- ${cmd}`
    }
  }
}
