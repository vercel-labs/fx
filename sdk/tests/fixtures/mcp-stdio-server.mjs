#!/usr/bin/env node
import { createInterface } from "node:readline";

const respond = (id, result) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
const dispatch = ({ id, method, params }) => {
  if (method === "initialize") return respond(id, { protocolVersion: "2025-06-18", capabilities: { tools: {}, resources: {}, prompts: {} }, serverInfo: { name: "libfx-fixture", version: "1" } });
  if (method === "tools/list") return respond(id, { tools: [{ name: "echo", description: "Echo a value", inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } }] });
  if (method === "tools/call") return respond(id, { content: [{ type: "text", text: `mcp:${params.arguments.value}` }] });
  if (method === "resources/read") return respond(id, { contents: [{ uri: params.uri, text: "resource context" }] });
  if (method === "prompts/get") return respond(id, { messages: [{ role: "user", content: [{ type: "text", text: "prompt context" }] }] });
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } })}\n`);
};

createInterface({ input: process.stdin }).on("line", (line) => {
  try { dispatch(JSON.parse(line)); } catch {}
});
