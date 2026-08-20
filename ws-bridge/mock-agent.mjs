#!/usr/bin/env node
// Minimal mock ACP agent for bridge testing.
// Implements: initialize, session/new, session/load, session/prompt
import { createInterface } from "node:readline";
const agentName = process.env.MOCK_AGENT_NAME || "mock";
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try { msg = JSON.parse(trimmed); } catch { return; }
  const id = msg.id;
  const method = msg.method;
  // handle batch
  if (Array.isArray(msg)) {
    // not implemented - respond error
    return;
  }
  if (method === "initialize") {
    const resp = {
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: 1,
        agentCapabilities: {
          loadSession: true,
          promptCapabilities: { image: false, audio: false, embeddedContext: true },
          mcpCapabilities: { http: true, sse: true },
          sessionCapabilities: { list: {}, resume: {}, close: {} },
        },
        agentInfo: { name: agentName, title: agentName, version: "0.0.0mock" },
        authMethods: [],
      },
    };
    console.log(JSON.stringify(resp));
  } else if (method === "session/new") {
    const cwd = msg.params?.cwd || "/tmp";
    const sessionId = `${Date.now()}-${Math.random().toString(16).slice(2)}-${agentName}`;
    // send response
    console.log(JSON.stringify({ jsonrpc: "2.0", id, result: { sessionId, modes: { currentModeId: "default" }, configOptions: [], cwd } }));
    // send available_commands_update async
    setTimeout(() => {
      console.log(JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: { sessionUpdate: "available_commands_update", availableCommands: [] } } }));
    }, 10);
  } else if (method === "session/load" || method === "session/resume") {
    const cwd = msg.params?.cwd || "/tmp";
    const sid = msg.params?.sessionId || "unknown";
    // echo check? In mock we don't enforce cwd mismatch - just succeed
    // But if test wants cwd validation failure, we could implement check based on cwd
    // For now always succeed
    if (method === "session/load") {
      // send a fake update then response
      setTimeout(() => {
        console.log(JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "mock history" } } } }));
        console.log(JSON.stringify({ jsonrpc: "2.0", id, result: null }));
      }, 10);
    } else {
      console.log(JSON.stringify({ jsonrpc: "2.0", id, result: {} }));
    }
  } else if (method === "session/prompt") {
    const sid = msg.params?.sessionId || "sess";
    const promptText = JSON.stringify(msg.params?.prompt || "");
    // send chunks
    setTimeout(() => {
      console.log(JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `mock:${agentName}:` + promptText.slice(0,50) } } } }));
    }, 20);
    setTimeout(() => {
      console.log(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
    }, 40);
  } else if (method === "session/list") {
    console.log(JSON.stringify({ jsonrpc: "2.0", id, result: { sessions: [] } }));
  } else if (method === "session/close") {
    console.log(JSON.stringify({ jsonrpc: "2.0", id, result: {} }));
  } else {
    console.log(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } }));
  }
});
// keep alive
process.stdin.resume();
