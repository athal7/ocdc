#!/usr/bin/env node
/**
 * ocdc-mcp-fetch.js - Fetch items from MCP servers
 *
 * Reads MCP config from ~/.config/opencode/opencode.json (or OCDC_MCP_CONFIG_PATH)
 * Connects to GitHub or Linear MCP servers
 * Calls appropriate tools and transforms responses
 *
 * Usage:
 *   node lib/ocdc-mcp-fetch.js <source_type> [fetch_options_json]
 *
 * Exit codes:
 *   0  - Success (JSON array on stdout)
 *   1  - Invalid arguments
 *   10 - MCP not configured for this source type
 *   11 - MCP connection failed
 *   12 - Tool not found on MCP server
 *   13 - Tool execution failed
 *   99 - Unexpected error
 */

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import fs from "fs";
import path from "path";
import os from "os";

// Exit codes
const EXIT_SUCCESS = 0;
const EXIT_INVALID_ARGS = 1;
const EXIT_MCP_NOT_CONFIGURED = 10;
const EXIT_CONNECTION_FAILED = 11;
const EXIT_TOOL_NOT_FOUND = 12;
const EXIT_TOOL_FAILED = 13;
const EXIT_UNEXPECTED = 99;

// Source type to MCP server mapping
const SOURCE_TO_MCP = {
  github_issue: "github",
  github_pr: "github",
  linear_issue: "linear",
};

// Tool mappings per source type
const TOOL_MAPPINGS = {
  github_issue: {
    tool: "search_issues",
    buildQuery: (opts) => {
      const parts = ["is:issue"];
      if (opts.assignee) parts.push(`assignee:${opts.assignee}`);
      if (opts.state) parts.push(`state:${opts.state}`);
      if (opts.repo) parts.push(`repo:${opts.repo}`);
      // Support repos array
      if (opts.repos?.length) {
        opts.repos.forEach((r) => parts.push(`repo:${r}`));
      }
      if (opts.org) parts.push(`org:${opts.org}`);
      if (opts.labels?.length)
        opts.labels.forEach((l) => parts.push(`label:${l}`));
      // Use 'q' parameter (used by @modelcontextprotocol/server-github)
      return { q: parts.join(" ") };
    },
    transform: (result) => {
      // Transform MCP response to expected schema
      const text = result.content?.[0]?.text;
      if (!text) return [];
      const items = parseJsonArray(text, "github_issue");
      return items.map((item) => ({
        number: item.number,
        title: item.title,
        body: item.body,
        html_url: item.html_url || item.url,
        repository: extractRepository(item),
        labels: item.labels || [],
        assignees: item.assignees || [],
      }));
    },
  },
  github_pr: {
    tool: "search_issues", // GitHub search_issues works for PRs with is:pr
    buildQuery: (opts) => {
      const parts = ["is:pr"];
      if (opts.author) parts.push(`author:${opts.author}`);
      if (opts.review_requested)
        parts.push(`review-requested:${opts.review_requested}`);
      if (opts.review_decision) {
        // GitHub uses lowercase with underscores: changes_requested, approved, none
        const decision = opts.review_decision.toLowerCase();
        parts.push(`review:${decision}`);
      }
      if (opts.state) parts.push(`state:${opts.state}`);
      if (opts.repo) parts.push(`repo:${opts.repo}`);
      // Support repos array
      if (opts.repos?.length) {
        opts.repos.forEach((r) => parts.push(`repo:${r}`));
      }
      if (opts.org) parts.push(`org:${opts.org}`);
      // Use 'q' parameter (used by @modelcontextprotocol/server-github)
      return { q: parts.join(" ") };
    },
    transform: (result) => {
      const text = result.content?.[0]?.text;
      if (!text) return [];
      const items = parseJsonArray(text, "github_pr");
      return items.map((item) => ({
        number: item.number,
        title: item.title,
        body: item.body,
        html_url: item.html_url || item.url,
        repository: extractRepository(item),
        labels: item.labels || [],
        // GitHub search API doesn't return head.ref, use fallback branch name
        headRefName: item.head?.ref || `pr-${item.number}`,
      }));
    },
  },
  linear_issue: {
    // Tool name discovered at runtime
    tool: null,
    toolCandidates: [
      "list_my_issues",
      "get_my_issues",
      "search_issues",
      "list_issues",
      "linear_search_issues",
      "linear_list_issues",
    ],
    buildQuery: (opts) => {
      // Build query based on common Linear MCP patterns
      const query = {};
      if (opts.assignee === "@me") {
        query.assignedToMe = true;
      }
      if (Array.isArray(opts.state)) {
        query.status = opts.state;
      }
      // Team filter - send both param names for MCP server compatibility
      // Different Linear MCP servers may expect 'team' or 'teamKey'
      if (opts.team) {
        query.teamKey = opts.team;
        query.team = opts.team;
      }
      return query;
    },
    transform: (result) => {
      const text = result.content?.[0]?.text;
      if (!text) return [];
      const items = parseJsonArray(text, "linear_issue");
      return items.map((item) => ({
        id: item.id,
        identifier: item.identifier,
        title: item.title,
        description: item.description,
        url: item.url,
        team: item.team,
        labels: item.labels || [],
        state: item.state,
      }));
    },
  },
};

/**
 * Extract repository info from GitHub API response
 * Handles multiple formats: repository object, repository_url string, html_url
 */
function extractRepository(item) {
  // If repository object has full_name, use it
  if (item.repository?.full_name) {
    return {
      full_name: item.repository.full_name,
      name: item.repository.name,
    };
  }
  
  // Try to build from repository object parts
  if (item.repository?.owner && item.repository?.name) {
    const owner = item.repository.owner?.login || item.repository.owner;
    return {
      full_name: `${owner}/${item.repository.name}`,
      name: item.repository.name,
    };
  }
  
  // Extract from repository_url (e.g., "https://api.github.com/repos/owner/repo")
  if (item.repository_url) {
    const match = item.repository_url.match(/repos\/([^/]+\/[^/]+)$/);
    if (match) {
      const full_name = match[1];
      const name = full_name.split('/')[1];
      return { full_name, name };
    }
  }
  
  // Extract from html_url (e.g., "https://github.com/owner/repo/...")
  if (item.html_url || item.url) {
    const url = item.html_url || item.url;
    const match = url.match(/github\.com\/([^/]+\/[^/]+)/);
    if (match) {
      const full_name = match[1];
      const name = full_name.split('/')[1];
      return { full_name, name };
    }
  }
  
  // Fallback to empty
  return { full_name: "", name: "" };
}

/**
 * Parse JSON text as an array with error handling
 * Returns empty array if parsing fails or result is not an array
 * Handles GitHub search API responses that wrap items in { items: [...] }
 */
function parseJsonArray(text, sourceType) {
  try {
    const parsed = JSON.parse(text);
    // Handle GitHub search API response format: { total_count, items: [...] }
    if (parsed && Array.isArray(parsed.items)) {
      return parsed.items;
    }
    if (Array.isArray(parsed)) {
      return parsed;
    }
    console.error(
      `Warning: MCP response for ${sourceType} is not an array, returning empty`
    );
    return [];
  } catch (err) {
    console.error(
      `Warning: Failed to parse MCP response for ${sourceType}: ${err.message}`
    );
    return [];
  }
}

/**
 * Expand environment variables in a string
 * Supports ${VAR} syntax (not $VAR)
 */
function expandEnvVars(str) {
  return str.replace(/\$\{(\w+)\}/g, (_, name) => process.env[name] || "");
}

/**
 * Create appropriate transport based on MCP config
 */
async function createTransport(mcpConfig) {
  // Expand environment variables in headers
  const headers = {};
  if (mcpConfig.headers) {
    for (const [key, value] of Object.entries(mcpConfig.headers)) {
      headers[key] = expandEnvVars(value);
    }
  }

  if (mcpConfig.type === "remote") {
    const url = new URL(mcpConfig.url);

    // Use SSE for Linear (legacy), Streamable HTTP for others
    if (mcpConfig.url.includes("linear.app/sse")) {
      return new SSEClientTransport(url, {
        requestInit: { headers },
      });
    } else {
      return new StreamableHTTPClientTransport(url, {
        requestInit: { headers },
      });
    }
  } else if (mcpConfig.type === "local") {
    const command = mcpConfig.command;
    if (!command || command.length === 0) {
      throw new Error("Local MCP config missing command");
    }

    // Handle shell commands (sh -c "...")
    const [cmd, ...args] = command;
    return new StdioClientTransport({
      command: cmd,
      args,
      env: { ...process.env },
    });
  }

  throw new Error(`Unknown MCP type: ${mcpConfig.type}`);
}

/**
 * Get MCP config file path
 */
function getConfigPath() {
  // Allow override via environment variable (for testing)
  if (process.env.OCDC_MCP_CONFIG_PATH) {
    return process.env.OCDC_MCP_CONFIG_PATH;
  }
  return path.join(os.homedir(), ".config/opencode/opencode.json");
}

/**
 * Main function
 */
async function main() {
  const args = process.argv.slice(2);
  
  // Check for --dry-run flag
  const dryRunIndex = args.indexOf('--dry-run');
  const dryRun = dryRunIndex !== -1;
  if (dryRun) {
    args.splice(dryRunIndex, 1);
  }

  if (args.length < 1) {
    console.error(
      "Usage: ocdc-mcp-fetch.js <source_type> [fetch_options_json] [--dry-run]"
    );
    console.error("Source types: github_issue, github_pr, linear_issue");
    console.error("Options:");
    console.error("  --dry-run  Print the query that would be sent without connecting");
    process.exit(EXIT_INVALID_ARGS);
  }

  const sourceType = args[0];
  let fetchOptions = {};

  // Parse fetch options if provided
  if (args[1]) {
    try {
      fetchOptions = JSON.parse(args[1]);
    } catch (err) {
      console.error(`Invalid JSON in fetch options: ${err.message}`);
      process.exit(EXIT_INVALID_ARGS);
    }
  }

  // Validate source type
  const mcpServerName = SOURCE_TO_MCP[sourceType];
  if (!mcpServerName) {
    console.error(`Unknown source type: ${sourceType}`);
    console.error(
      `Valid source types: ${Object.keys(SOURCE_TO_MCP).join(", ")}`
    );
    process.exit(EXIT_INVALID_ARGS);
  }

  // Read MCP config
  const configPath = getConfigPath();
  if (!fs.existsSync(configPath)) {
    console.error(`MCP config not found: ${configPath}`);
    process.exit(EXIT_MCP_NOT_CONFIGURED);
  }

  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
  } catch (err) {
    console.error(`Failed to parse MCP config: ${err.message}`);
    process.exit(EXIT_MCP_NOT_CONFIGURED);
  }

  const mcpConfig = config.mcp?.[mcpServerName];

  if (!mcpConfig) {
    console.error(`MCP server '${mcpServerName}' not configured in ${configPath}`);
    process.exit(EXIT_MCP_NOT_CONFIGURED);
  }

  if (mcpConfig.enabled === false) {
    console.error(`MCP server '${mcpServerName}' is disabled`);
    process.exit(EXIT_MCP_NOT_CONFIGURED);
  }

  // Get tool mapping and build query
  const mapping = TOOL_MAPPINGS[sourceType];
  const params = mapping.buildQuery(fetchOptions);

  // Dry-run mode: print the query and exit
  if (dryRun) {
    console.log(`Source type: ${sourceType}`);
    console.log(`MCP server: ${mcpServerName}`);
    console.log(`Tool: ${mapping.tool || mapping.toolCandidates?.join(' | ')}`);
    console.log(`Query: ${JSON.stringify(params, null, 2)}`);
    process.exit(EXIT_SUCCESS);
  }

  // Create client and connect
  const client = new Client({ name: "ocdc-poll", version: "1.0.0" });
  let transport;

  try {
    transport = await createTransport(mcpConfig);
    await client.connect(transport);
  } catch (err) {
    // Clean up transport if it was created but connection failed
    if (transport) {
      try {
        await transport.close?.();
      } catch {
        // Ignore cleanup errors
      }
    }
    console.error(`Failed to connect to MCP server '${mcpServerName}': ${err.message}`);
    process.exit(EXIT_CONNECTION_FAILED);
  }

  try {
    // mapping and params already built above (before dry-run check)
    let toolName = mapping.tool;

    // For sources without a fixed tool name, discover it
    if (!toolName && mapping.toolCandidates) {
      const tools = await client.listTools();
      const availableNames = tools.tools.map((t) => t.name);
      toolName = mapping.toolCandidates.find((c) => availableNames.includes(c));

      if (!toolName) {
        console.error(
          `No matching tool found for ${sourceType}. Available tools: ${availableNames.join(", ")}`
        );
        process.exit(EXIT_TOOL_NOT_FOUND);
      }
    }

    // Call the tool
    const result = await client.callTool({ name: toolName, arguments: params });

    // Transform and output
    const items = mapping.transform(result);
    console.log(JSON.stringify(items));

    process.exit(EXIT_SUCCESS);
  } catch (err) {
    console.error(`Tool execution failed: ${err.message}`);
    process.exit(EXIT_TOOL_FAILED);
  } finally {
    try {
      await client.close();
    } catch {
      // Ignore close errors
    }
  }
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(EXIT_UNEXPECTED);
});
