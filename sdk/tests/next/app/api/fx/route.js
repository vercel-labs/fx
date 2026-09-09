import { randomUUID } from "node:crypto";
import { appendFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  if (!["host", "mcp", "error", "known-error", "cancel", "resume", "startup"].includes(scenario)) {
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
  const journalDirectory = mkdtempSync(join(tmpdir(), "libfx-next-journal-"));
  const journalPath = join(journalDirectory, "entries.jsonl");
  const journal = [];
  const requestId = randomUUID();
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
        if (scenario === "known-error") return { isError: true, content: "fixture tool failure" };
        if (scenario === "cancel") {
          signal.addEventListener("abort", () => { toolAborted = true; }, { once: true });
          controller.abort();
          return new Promise((resolve) => setTimeout(() => resolve(expectedValue), 20));
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
      journal: [],
      onEntry(entry) {
        const previous = journal.at(-1);
        if (entry.seq === previous?.seq && entry.hash === previous.hash) return;
        if (entry.seq !== (previous?.seq ?? 0) + 1) throw new Error("JournalConflict");
        appendFileSync(journalPath, JSON.stringify({ ...entry, bytes: Buffer.from(entry.bytes).toString("base64") }) + "\n", { flush: true });
        journal.push({ ...entry, bytes: Uint8Array.from(entry.bytes) });
      },
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
        const expected = scenario === "known-error" ? "fixture tool failure" : observedValue;
        if (!expected || !JSON.stringify(body).includes(expected)) throw new Error("Tool result missing from next request");
        return stream([
          { type: "text-delta", delta: scenario === "known-error" ? "tool failed" : expected },
          { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } },
        ]);
      } } : {}),
    };
    agent = await createFxAgent(options);
    if (scenario === "startup") {
      return Response.json({ ok: true, probe, checkpointBytes: (await agent.checkpoint()).bytes.length });
    }
    const turn = agent.prompt("Look up key alpha and repeat its value.", { requestId, signal: controller.signal });
    let text = "";
    const drain = (async () => {
      for await (const event of turn) {
        events.push(event.type);
        if (event.type === "text_delta") text += event.delta;
      }
    })();
    const [settled, drained] = await Promise.allSettled([turn.result, drain]);
    let result;
    if (toolCalls !== 1) throw new Error(`Expected one tool callback, received ${toolCalls}`);
    if (!events.includes("tool_start")) throw new Error("Missing tool_start event");
    if (scenario === "cancel" || scenario === "error") {
      if (settled.status !== "rejected" || settled.reason.code !== "RecoveryRequired") throw new Error("Unknown tool outcome was not preserved");
      if (scenario === "cancel" && !toolAborted) throw new Error("Tool cancellation was not delivered");
      const pending = await agent.status();
      if (pending.idle || pending.pendingTurn.awaiting.tool?.name !== "lookup") throw new Error("Missing uncertain tool identity");
      await agent.abandon();
      result = JSON.parse(new TextDecoder().decode(journal.at(-1).bytes)).result;
      if (result.reason !== "interrupted" || result.pendingTool?.name !== "lookup") throw new Error("Abandonment lost uncertain tool evidence");
      await agent.close();
      agent = await createFxAgent({ ...options, journal });
    } else {
      if (settled.status === "rejected") throw settled.reason;
      if (drained.status === "rejected") throw drained.reason;
      result = settled.value;
      if (!result.ok || result.stopReason !== "stop" || !events.includes("tool_end")) throw new Error("Tool turn did not complete");
      if (scenario !== "known-error" && !text.includes(observedValue)) throw new Error("Model did not use the tool result");
    }
    const checkpoint = await agent.checkpoint();
    await agent.close();
    agent = null;
    if (scenario === "resume") {
      agent = await createFxAgent({ ...options, journal: [checkpoint] });
      const resumed = agent.prompt("Repeat the value you looked up without calling another tool.", { requestId: randomUUID(), signal: controller.signal });
      let resumedText = "";
      for await (const event of resumed) if (event.type === "text_delta") resumedText += event.delta;
      if ((await resumed.result).stopReason !== "stop" || !resumedText.includes(observedValue)) throw new Error("Checkpoint restore lost tool history");
      await agent.close();
      agent = null;
    }
    await adapter?.close();
    adapter = null;
    return Response.json({ ok: true, scenario, probe, toolCalls, modelRequests, events, result, checkpointBytes: checkpoint.bytes.length,
      closedMcp, node: process.version, arch: process.arch, glibc: process.report.getReport().header.glibcVersionRuntime ?? null });
  } catch (error) {
    return Response.json({ ok: false, code: error.code, message: error.message }, { status: 500 });
  } finally {
    clearTimeout(timeout);
    await agent?.close();
    await adapter?.close();
    rmSync(journalDirectory, { recursive: true, force: true });
  }
}
