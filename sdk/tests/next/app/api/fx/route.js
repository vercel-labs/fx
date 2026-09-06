import { randomUUID } from "node:crypto";
import { createFxAgent, getBackendInfo } from "libfx";
import { createMcpAdapter } from "libfx/mcp";

export const runtime = "nodejs";

function stream(events) {
  const data = [...events, "[DONE]"].map((event) => `data: ${typeof event === "string" ? event : JSON.stringify(event)}\n\n`).join("");
  return new Response(data, { headers: { "content-type": "text/event-stream" } });
}

export async function GET(request) {
  const token = process.env.LIBFX_SMOKE_TOKEN;
  const live = process.env.LIBFX_LIVE === "1";
  if ((token && request.headers.get("authorization") !== `Bearer ${token}`) || (live && !token)) {
    return new Response(null, { status: 401 });
  }
  const url = new URL(request.url);
  const backend = url.searchParams.get("backend") ?? "auto";
  const scenario = url.searchParams.get("scenario") ?? "host";
  if (!["host", "mcp", "error", "cancel", "resume"].includes(scenario)) {
    return Response.json({ error: "Unknown scenario" }, { status: 400 });
  }
  let agent;
  let adapter;
  let closedMcp = false;
  let toolCalls = 0;
  let modelRequests = 0;
  let observedValue;
  let toolAborted = false;
  const events = [];
  const expectedValue = `verified:${randomUUID()}`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const probe = await getBackendInfo({ backend });
    if (probe.backend === "unavailable") return Response.json({ probe }, { status: 503 });
    let tools = [{
      name: "lookup",
      description: "Get the verification value. Call once with key alpha, then repeat the returned value.",
      inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
      async execute(input, { signal }) {
        toolCalls++;
        if (input.key !== "alpha") throw new Error("Unexpected lookup key");
        if (scenario === "error") throw new Error("fixture tool failure");
        if (scenario === "cancel") {
          signal.addEventListener("abort", () => { toolAborted = true; }, { once: true });
          controller.abort();
          return new Promise(() => {});
        }
        observedValue = expectedValue;
        return expectedValue;
      },
    }];
    if (scenario === "mcp") {
      let id = 0;
      const rpc = async (method, params, signal) => {
        const response = await fetch(new URL("/api/mcp", request.url), {
          method: "POST", signal,
          headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
          body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
        });
        if (!response.ok) throw new Error(`MCP HTTP ${response.status}`);
        const message = await response.json();
        if (message.error) throw new Error(message.error.message);
        return message.result;
      };
      adapter = await createMcpAdapter({
        listTools: (params) => rpc("tools/list", params, controller.signal),
        async callTool(params, _schema, options) {
          toolCalls++;
          const result = await rpc("tools/call", params, options.signal);
          observedValue = result.content[0].text;
          return result;
        },
        async close() { closedMcp = true; },
      });
      tools = adapter.tools;
    }
    const options = {
      backend,
      apiKey: live ? process.env.AI_GATEWAY_API_KEY : "fixture-unused-key",
      model: live ? process.env.LIBFX_TEST_MODEL : "fixture/model",
      tools,
      instructions: "Call lookup exactly once with key alpha, then repeat its returned value. If it fails, say tool failed.",
      ...(!live ? { fetch: async (_url, init) => {
        if (init?.method === "GET") return Response.json({ data: [{ id: "fixture/model", type: "language", tags: ["tool-use"] }] });
        modelRequests++;
        const body = JSON.parse(init.body);
        if (modelRequests === 1) {
          if (!body.tools.some((tool) => tool.name === "lookup")) throw new Error("Tool schema missing from request");
          return stream([
            { type: "tool-call", toolCallId: "lookup-1", toolName: "lookup", input: { key: "alpha" } },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
          ]);
        }
        const expected = scenario === "error" ? "fixture tool failure" : observedValue;
        if (!expected || !JSON.stringify(body).includes(expected)) throw new Error("Tool result missing from next request");
        return stream([
          { type: "text-delta", delta: scenario === "error" ? "tool failed" : expected },
          { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } },
        ]);
      } } : {}),
    };
    agent = await createFxAgent(options);
    const turn = agent.prompt("Look up key alpha and repeat its value.", { signal: controller.signal });
    let text = "";
    for await (const event of turn) {
      events.push(event.type);
      if (event.type === "text_delta") text += event.delta;
    }
    const result = await turn.result;
    if (toolCalls !== 1) throw new Error(`Expected one tool callback, received ${toolCalls}`);
    if (!events.includes("tool_start")) throw new Error("Missing tool_start event");
    if (scenario === "cancel") {
      if (result.stopReason !== "cancelled" || !toolAborted) throw new Error("Tool cancellation did not settle");
    } else {
      if (result.stopReason !== "end_turn" || !events.includes("tool_end")) throw new Error("Tool turn did not complete");
      if (scenario !== "error" && !text.includes(observedValue)) throw new Error("Model did not use the tool result");
    }
    const checkpoint = await agent.checkpoint();
    await agent.close();
    agent = null;
    if (scenario === "resume") {
      agent = await createFxAgent({ ...options, checkpoint });
      const resumed = agent.prompt("Repeat the value you looked up without calling another tool.", { signal: controller.signal });
      let resumedText = "";
      for await (const event of resumed) if (event.type === "text_delta") resumedText += event.delta;
      if ((await resumed.result).stopReason !== "end_turn" || !resumedText.includes(observedValue)) throw new Error("Checkpoint restore lost tool history");
      await agent.close();
      agent = null;
    }
    await adapter?.close();
    adapter = null;
    return Response.json({ ok: true, scenario, probe, toolCalls, modelRequests, events, result, checkpointBytes: checkpoint.length,
      closedMcp, node: process.version, arch: process.arch, glibc: process.report.getReport().header.glibcVersionRuntime ?? null });
  } catch (error) {
    return Response.json({ ok: false, code: error.code, message: error.message }, { status: 500 });
  } finally {
    clearTimeout(timeout);
    await agent?.close();
    await adapter?.close();
  }
}
