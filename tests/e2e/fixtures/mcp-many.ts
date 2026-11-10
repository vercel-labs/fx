// Many MCP servers from one process, for stress runs: each path
// /s/<index>/mcp is its own server with its own generated tools, over the
// 2025-06-18 Streamable HTTP protocol answered with plain JSON. One process
// keeps a run with 1000 servers about fx, not about starting 1000 programs.

import { writeFileSync } from "node:fs";

export const MANY_MCP_VERSION = "2025-06-18";

export type ManyMcpOptions = {
  servers: number;
  toolsPerServer: number;
  // The text every tools/call answers with.
  resultText?: string;
};

export type ManyMcpStats = {
  initialize: number;
  toolsList: number;
  toolsCall: Array<{ server: number; tool: string; arguments: unknown }>;
};

export function manyMcpServerName(index: number): string {
  return `s${String(index).padStart(4, "0")}`;
}

export function manyMcpToolName(index: number): string {
  return `tool_${String(index).padStart(2, "0")}`;
}

function toolList(server: number, count: number) {
  const tools = [];
  for (let tool = 0; tool < count; tool++) {
    tools.push({
      name: manyMcpToolName(tool),
      description: `Tool ${tool} of server ${server}: echoes its text with the server and tool number.`,
      inputSchema: {
        type: "object",
        properties: { text: { type: "string", description: "What to echo." } },
        required: ["text"],
      },
    });
  }
  return tools;
}

export function startManyMcpHttpServers(options: ManyMcpOptions) {
  const stats: ManyMcpStats = { initialize: 0, toolsList: 0, toolsCall: [] };
  const lists = new Map<number, ReturnType<typeof toolList>>();
  const resultText = options.resultText ?? "MANY_MCP_TOOL_RESULT";

  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const match = /^\/s\/(\d+)\/mcp$/.exec(url.pathname);
      const index = match ? Number(match[1]) : -1;
      if (index < 0 || index >= options.servers) return new Response("not found", { status: 404 });
      if (request.method === "DELETE") return new Response(null, { status: 204 });
      // No server-to-client stream: the protocol's way to decline it.
      if (request.method === "GET") return new Response(null, { status: 405 });
      if (request.method !== "POST") return new Response(null, { status: 405 });

      const message = await request.json() as { id?: unknown; method?: string; params?: any };
      switch (message.method) {
        case "server/discover":
          // Not a 2026-07-28 server: fx falls back to initialize.
          return new Response(null, { status: 404 });
        case "notifications/initialized":
        case "notifications/cancelled":
          return new Response(null, { status: 202 });
        case "initialize":
          stats.initialize += 1;
          return Response.json({
            jsonrpc: "2.0",
            id: message.id,
            result: {
              protocolVersion: MANY_MCP_VERSION,
              capabilities: { tools: {} },
              serverInfo: { name: manyMcpServerName(index), version: "1" },
              instructions: `Stress server ${index} with ${options.toolsPerServer} echo tools.`,
            },
          });
        case "tools/list": {
          stats.toolsList += 1;
          let tools = lists.get(index);
          if (!tools) {
            tools = toolList(index, options.toolsPerServer);
            lists.set(index, tools);
          }
          return Response.json({ jsonrpc: "2.0", id: message.id, result: { tools } });
        }
        case "tools/call":
          stats.toolsCall.push({ server: index, tool: String(message.params?.name), arguments: message.params?.arguments });
          return Response.json({
            jsonrpc: "2.0",
            id: message.id,
            result: { content: [{ type: "text", text: `${resultText} server=${index} tool=${message.params?.name}` }] },
          });
        default:
          return Response.json({ jsonrpc: "2.0", id: message.id ?? null, error: { code: -32601, message: "Method not found" } });
      }
    },
  });

  return {
    stats,
    url(index: number) {
      return `http://127.0.0.1:${server.port}/s/${index}/mcp`;
    },
    stop() {
      server.stop(true);
    },
  };
}

// Writes an mcp.json that lists every server of `fixture`.
export function writeManyMcpConfig(
  path: string,
  fixture: ReturnType<typeof startManyMcpHttpServers>,
  servers: number,
  timeouts: { startup_timeout_ms?: number; operation_timeout_ms?: number } = {},
) {
  const mcp: Record<string, unknown> = {};
  for (let index = 0; index < servers; index++) {
    mcp[manyMcpServerName(index)] = { type: "http", url: fixture.url(index), ...timeouts };
  }
  writeFileSync(path, JSON.stringify({ mcp }));
}
