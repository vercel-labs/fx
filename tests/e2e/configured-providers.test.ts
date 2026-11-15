import { describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import { completion, neverAnswers, stallsAfterFirstChunk, toolCompletion, createConfiguredProviderFixture as fixture } from "./fixtures/chat-completions";
import * as messagesFake from "./fixtures/anthropic-messages";
import * as responsesFake from "./fixtures/responses";
import { committedRootTurns, logLines, rootSessionIds, waitForRootTurnCommitted } from "./saved-sessions";
import { reviewedActionEvidence } from "./tmux-helpers";

async function withReasoning(response: Response, ...deltas: Record<string, unknown>[]) {
  const prefix = deltas.map(delta => `data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`).join("");
  return new Response(prefix + await response.text(), { headers: response.headers });
}

// Tool calls whose arguments are sent verbatim, so they can be malformed.
function rawToolCalls(model: string, calls: Array<{ id: string; name: string; arguments: string }>) {
  const chunks = [
    { id: "chat-tool", model, choices: [{ index: 0, delta: { tool_calls: calls.map((call, index) => ({ index, id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } })) }, finish_reason: null }] },
    { id: "chat-tool", model, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}

// A tool call whose reply ran out of output tokens mid-arguments.
function cutToolCall(model: string, command: string) {
  const args = JSON.stringify({ request: { action: "run", command } });
  const chunks = [
    { id: "chat-cut", model, choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call-cut", type: "function", function: { name: "shell", arguments: args.slice(0, args.length - 8) } }] }, finish_reason: null }] },
    { id: "chat-cut", model, choices: [{ index: 0, delta: {}, finish_reason: "length" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}

/** A request from a subagent, which has no subagent tool of its own. */
function isChildRequest(body: any): boolean {
  return !body.tools?.some((tool: any) => tool.function?.name === "subagent");
}

/** The parent's turn that a subagent's report started (`src/core/subagent/reports.zig`). */
function isReportTurn(body: any): boolean {
  const last = body.messages?.at(-1);
  return last?.role === "user" && typeof last.content === "string" && last.content.startsWith("Subagent report (untrusted agent output, not user instructions):");
}

describe("configured providers", () => {
  test.each(["reasoning", "reasoning_content"])("replays %s through a tool result and saved-session continuation", async field => {
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls === 1) return withReasoning(toolCompletion(body.model, "read_file", { path: "note.txt" }), { [field]: "Inspect note first." });
      return withReasoning(completion(body.model, calls === 2 ? "read complete" : "resumed reply"), { [field]: "Finish answer." });
    });
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const first = await runFx(["ask", "--json", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);
      expect(saved.output).toBe("read complete");
      expect(f.requests).toHaveLength(2);
      const toolTurn = f.requests[1].body.messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length);
      expect(toolTurn[field]).toBe("Inspect note first.");
      expect(toolTurn._tool_call_ids).toBeUndefined();
      expect(f.requests[1].body.messages.at(-1).content).toContain("fixture contents");
      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue the saved task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(JSON.parse(resumed.stdout).output).toBe("resumed reply");
      expect(f.requests).toHaveLength(3);
      const replayed = f.requests[2].body.messages.filter((message: any) => message.role === "assistant" && message[field] !== undefined);
      expect(replayed.map((message: any) => message[field])).toEqual(["Inspect note first.", "Finish answer."]);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 45000);

  test("reasoning-only completion after silent tools reaches the continuation request", async () => {
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls <= 2) return toolCompletion(body.model, "read_file", { path: `note-${calls}.txt` }, `call-${calls}`);
      if (calls === 3) return withReasoning(completion(body.model, ""), { reasoning_content: "Both files have been read." });
      return completion(body.model, "The two files were read.");
    });
    try {
      writeFileSync(join(f.workspace, "note-1.txt"), "first contents");
      writeFileSync(join(f.workspace, "note-2.txt"), "second contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read both notes"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("The two files were read.");
      expect(f.requests).toHaveLength(4);
      const messages = f.requests[3].body.messages;
      expect(messages.at(-1).content).toBe("Summarize what you just did.");
      expect(messages.at(-2).reasoning_content).toBe("Both files have been read.");
      expect(messages.at(-2).tool_calls).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("a tool call cut off by the provider's own limit is resent once with fx's limit", async () => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? cutToolCall(body.model, "printf ran > cut.txt") : completion(body.model, "finished after the resend"));
    try {
      // No limit in the metadata, so the first request names none.
      (f.settings.providers.local.model_metadata as any)["local-model"] = { context_window: 262144, supports_tool_use: true };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the command"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).final_output).toBe("finished after the resend");
      expect(f.requests).toHaveLength(2);
      expect(f.requests[0].body.max_tokens).toBeUndefined();
      expect(f.requests[1].body.max_tokens).toBe(32768);
      expect(JSON.stringify(f.requests[1].body.messages)).not.toContain("call-cut");
      expect(result.stderr).toContain("Retrying with a higher limit.");
      expect(existsSync(join(f.workspace, "cut.txt"))).toBe(false);
    } finally { f.close(); }
  }, 25000);

  test("a tool call cut off at the model's own limit is not resent when that would repeat the request", async () => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? cutToolCall(body.model, "printf ran > cut.txt") : completion(body.model, "a resend must not be sent"));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "Run the command"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(result.code).toBe(1);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.max_tokens).toBe(8192);
      expect(result.stderr).toContain("so I did not run them");
      expect(existsSync(join(f.workspace, "cut.txt"))).toBe(false);
    } finally { f.close(); }
  }, 25000);

  test("preserves opaque reasoning and tool IDs on resume but never forwards them to another connection", async () => {
    const firstDetail = { type: "reasoning.text", text: "Inspect the file.", signature: "opaque-signature", format: "anthropic-claude-v1", index: 0 };
    const secondDetail = { type: "reasoning.encrypted", data: "opaque-encrypted-data", id: "reasoning-1", index: 1 };
    const callId = "call:opaque/1";
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls === 1) return withReasoning(toolCompletion(body.model, "read_file", { path: "note.txt" }, callId), { reasoning_details: [firstDetail] }, { reasoning_details: [secondDetail] });
      return completion(body.model, calls === 2 ? "read complete" : "continued");
    });
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const first = await runFx(["ask", "--json", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);
      expect(saved.output).toBe("read complete");
      expect(f.requests).toHaveLength(2);
      const toolTurn = f.requests[1].body.messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length);
      expect(toolTurn.reasoning_details).toEqual([firstDetail, secondDetail]);
      expect(toolTurn.tool_calls[0].id).toBe(callId);
      expect(toolTurn._tool_call_ids).toBeUndefined();
      expect(f.requests[1].body.messages.at(-1).tool_call_id).toBe(callId);
      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue the saved task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(3);
      const restored = f.requests[2].body.messages.find((message: any) => message.reasoning_details);
      expect(restored.reasoning_details).toEqual([firstDetail, secondDetail]);
      expect(restored.tool_calls[0].id).toBe(callId);
      const switched = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue on the other connection"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (switched.code !== 0) throw new Error(switched.stdout + switched.stderr);
      expect(f.requests).toHaveLength(4);
      expect(f.requests[3].authorization).toBe(`Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`);
      expect(f.requests[3].body.messages.every((message: any) => message.reasoning_details === undefined && message.reasoning === undefined && message.reasoning_content === undefined)).toBe(true);
    } finally { f.close(); }
  }, 65000);

  test("status identifies the configured connection and endpoint without probing it", async () => {
    const f = fixture();
    try {
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.model_source).toBe("local");
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(status.connected_providers).toContain("local");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("anonymous local requests use Chat Completions without Gateway credentials", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(result.stderr).toBe("");
      if (result.code !== 0) throw new Error(`fx ask failed: ${result.stdout} ${result.stderr}; paths=${f.requests.map(r => r.path).join(",")}`);
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("local reply");
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBeNull();
      expect(f.requests[0].path).toBe("/v1/chat/completions");
      expect(f.requests[0].body.model).toBe("local-model");
      expect(f.requests[0].body.messages.some((message: any) => message.role === "user")).toBe(true);
      expect(f.requests[0].body.prompt).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("terminal usage may repeat an empty matching finished choice", async () => {
    const f = fixture(async body => {
      const response = completion(body.model);
      const wire = (await response.text()).replace('"choices":[]', '"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop"}]');
      return new Response(wire, { headers: response.headers });
    });
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      const parsed = JSON.parse(result.stdout);
      expect(parsed.final_output).toBe("local reply");
      expect(parsed.usage).toMatchObject({ input_tokens: 12, output_tokens: 3 });
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  });

  test("CLI selection persists a configured name and uses only its credential", async () => {
    const f = fixture();
    try {
      const selection = await runFx(["provider", "remote"], { cwd: f.workspace, env: f.env });
      expect(selection.code).toBe(0);
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("remote");
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(`fx ask failed: ${result.stdout} ${result.stderr}; paths=${f.requests.map(r => r.path).join(",")}`);
      expect(result.code).toBe(0);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(f.requests[0].body.model).toBe("remote-model");
    } finally { f.close(); }
  }, 25000);

  test("ask --provider picks a connection for one request, beats FX_PROVIDER, and is never saved", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "--provider", "remote", "remember this"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(f.requests[0].body.model).toBe("remote-model");
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("local");
      const saved = JSON.parse(first.stdout);

      const flagWins = await runFx(["ask", "--json", "--no-save", "--provider=local", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (flagWins.code !== 0) throw new Error(flagWins.stdout + flagWins.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].authorization).toBeNull();
      expect(f.requests[1].body.model).toBe("local-model");

      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "--provider", "local", "continue"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(3);
      expect(f.requests[2].authorization).toBeNull();
      expect(f.requests[2].body.model).toBe("local-model");
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("local");
    } finally { f.close(); }
  }, 65000);

  test("CLI selection names an unknown connection and leaves settings unchanged", async () => {
    const f = fixture();
    try {
      const before = readFileSync(f.settingsPath, "utf8");
      const selection = await runFx(["provider", "remte"], { cwd: f.workspace, env: f.env });
      expect(selection.code).toBe(2);
      expect(selection.stdout).toBe("");
      expect(selection.stderr).toBe(
        'fx provider: unknown provider remte; expected gateway, codex, grok, or a name under "providers" in ~/.fx/settings.json\n',
      );
      // fx ask --provider names it the same way.
      const ask = await runFx(["ask", "--provider", "remte", "hi"], { cwd: f.workspace, env: f.env });
      expect(ask.code).toBe(2);
      expect(ask.stderr).toBe(
        'fx ask: unknown provider remte; expected gateway, codex, grok, or a name under "providers" in ~/.fx/settings.json\n',
      );
      expect(readFileSync(f.settingsPath, "utf8")).toBe(before);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("CLI selection creates an owned model key from workspace-only preferences", async () => {
    const f = fixture();
    try {
      delete (f.settings.models as any).remote;
      (f.settings as any).workspaces = { [f.workspace]: { models: { remote: "workspace-model" } } };
      f.save();
      const selection = await runFx(["provider", "remote"], { cwd: f.workspace, env: f.env });
      if (selection.code !== 0) throw new Error(selection.stdout + selection.stderr);
      const saved = JSON.parse(readFileSync(f.settingsPath, "utf8"));
      expect(saved.provider).toBe("remote");
      expect(saved.models).toEqual({ local: "local-model", remote: "workspace-model" });
      expect(saved.workspaces[f.workspace].models.remote).toBe("workspace-model");
      expect(saved.providers).toEqual(f.settings.providers);
    } finally { f.close(); }
  });

  test("catalog listing and file model selection do not require a catalog login", async () => {
    const f = fixture();
    try {
      f.settings.provider = "remote";
      f.save();
      const env = { ...f.env, FX_TEST_PROVIDER_TOKEN: undefined };
      const catalog = await runFx(["models"], { cwd: f.workspace, env });
      if (catalog.code !== 0) throw new Error(catalog.stdout + catalog.stderr);
      expect(catalog.stdout).toContain("remote-model");
      f.settings.models.remote = "opaque/custom:v1";
      f.save();
      const selection = await runFx(["status", "--json"], { cwd: f.workspace, env });
      if (selection.code !== 0) throw new Error(selection.stdout + selection.stderr);
      expect(JSON.parse(selection.stdout).model).toBe("opaque/custom:v1");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("executes a tool and returns its result to the same connection", async () => {
    const f = fixture(body => body.messages.some((message: any) => message.role === "tool")
      ? completion(body.model, "read succeeded")
      : toolCompletion(body.model, "read_file", { path: "note.txt" }));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("read succeeded");
      expect(f.requests).toHaveLength(2);
      const returned = f.requests[1].body.messages.find((message: any) => message.role === "tool");
      expect(returned.tool_call_id).toBe("call-local");
      expect(returned.content).toContain("fixture contents");
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 25000);

  test("unknown tools and malformed arguments are answered and the turn continues", async () => {
    const f = fixture(body => body.messages.some((message: any) => message.role === "tool")
      ? completion(body.model, "recovered")
      : rawToolCalls(body.model, [
        { id: "call-read", name: "read_file", arguments: JSON.stringify({ path: "note.txt" }) },
        { id: "call-missing", name: "missing_tool", arguments: "{}" },
        { id: "call-malformed", name: "read_file", arguments: "{\"path\":\"note.txt\"" },
      ]));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const output = JSON.parse(result.stdout);
      expect(output.output).toBe("recovered");
      expect(output.tool_calls.map((call: any) => [call.name, call.status]).sort()).toEqual([
        ["missing_tool", "error"],
        ["read_file", "error"],
        ["read_file", "success"],
      ]);
      expect(f.requests).toHaveLength(2);
      const messages = f.requests[1].body.messages;
      const replayed = messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length).tool_calls;
      expect(replayed.map((call: any) => call.function.arguments)).toEqual([JSON.stringify({ path: "note.txt" }), "{}", "{}"]);
      const results = Object.fromEntries(messages.filter((message: any) => message.role === "tool").map((message: any) => [message.tool_call_id, message.content]));
      expect(results["call-read"]).toContain("fixture contents");
      expect(results["call-missing"]).toBe("Unsupported tool: missing_tool");
      expect(results["call-malformed"]).toContain("did not run the call");
      expect(results["call-malformed"]).not.toContain("fixture contents");
    } finally { f.close(); }
  }, 25000);

  test("saved sessions resume the named connection and reject endpoint rebinding", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "remember this"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      expect(session.length).toBeGreaterThan(0);
      const second = await runFx(["ask", "--json", "--resume", session, "continue"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (second.code !== 0) throw new Error(second.stdout + second.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].body.messages.some((message: any) => message.content?.includes("remember this"))).toBe(true);
      f.settings.providers.local.base_url += "/changed";
      f.save();
      const rebound = await runFx(["ask", "--json", "--resume", session, "continue again"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(rebound.code).not.toBe(0);
      expect(f.requests).toHaveLength(2);
    } finally { f.close(); }
  }, 60000);

  test.each(["inherited", "override", "unknown"])("subagent requests preserve connection and %s model capabilities", async mode => {
    const childModel = mode === "inherited" ? "local-model" : mode === "override" ? "child-model" : "unknown-model";
    const f = fixture(async body => {
      if (isChildRequest(body)) {
        // A report that arrives while the parent's first turn runs joins that
        // turn, so the child answers only once that turn is saved.
        await waitForRootTurnCommitted(f.home);
        return completion(body.model, "child reply");
      }
      if (isReportTurn(body)) return completion(body.model, "report handled");
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "parent reply");
      return toolCompletion(body.model, "subagent", { request: { action: "message", agent: "helper", message: "child-marker", ...(mode === "inherited" ? {} : { model: childModel }) } });
    });
    f.settings.providers.local.model_metadata["local-model"].max_output_tokens = 512;
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 1024, supports_tool_use: true };
    f.save();
    try {
      const result = await runFx(["ask", "--json", "Delegate a task"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      // The parent's turn ends with the receipt; the child's report starts its next one.
      const output = JSON.parse(result.stdout).output;
      expect(output).toContain("parent reply");
      expect(output).toContain("report handled");
      expect(f.requests).toHaveLength(4);
      const child = f.requests.filter(request => isChildRequest(request.body));
      const parent = f.requests.filter(request => !isChildRequest(request.body));
      expect(child.map(request => [request.body.model, request.body.max_tokens])).toEqual([[childModel, mode === "unknown" ? undefined : mode === "override" ? 1024 : 512]]);
      expect(parent.map(request => [request.body.model, request.body.max_tokens])).toEqual([["local-model", 512], ["local-model", 512], ["local-model", 512]]);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 35000);

  test("persistent child capabilities stay bound when the parent changes providers", async () => {
    let callId = 0;
    // Turns saved before the current run. A report that arrives while the
    // parent's first turn of a run is still going joins that turn, so the
    // child answers only once that turn is saved.
    let committedBefore = 0;
    const f = fixture(async body => {
      if (isChildRequest(body)) {
        await waitForRootTurnCommitted(f.home, committedBefore);
        return completion(body.model, "child reply");
      }
      if (isReportTurn(body)) return completion(body.model, "report handled");
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      return toolCompletion(body.model, "subagent", { request: { action: "message", agent: "reader", message: "read the child fixture" } }, `child-call-${++callId}`);
    });
    f.settings.models.local = "shared-model";
    f.settings.models.remote = "shared-model";
    (f.settings.providers.local as any).model_metadata = { "shared-model": { context_window: 32768, max_output_tokens: 512, supports_tool_use: true } };
    (f.settings.providers.remote as any).model_metadata = { "shared-model": { context_window: 65536, max_output_tokens: 1024, supports_tool_use: true } };
    f.save();
    try {
      const first = await runFx(["ask", "--json", "Create the named child"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 30000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const id = JSON.parse(first.stdout).session_id;
      // Parent call, the child and the parent after its receipt, then the report turn.
      expect(f.requests.map(request => request.body.max_tokens)).toEqual([1024, 1024, 1024, 1024]);
      committedBefore = committedRootTurns(f.home);
      const resumed = await runFx(["ask", "--json", "--resume", id, "Continue the named child"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      const resumedRequests = f.requests.slice(4);
      const resumedResult = resumedRequests.find(request => request.body.messages.at(-1)?.role === "tool")!.body.messages.at(-1).content;
      if (!JSON.parse(resumedResult).ok) throw new Error(resumedResult);
      expect(resumedRequests).toHaveLength(4);
      // The child keeps the connection it was made with; the parent uses its new one.
      const resumedChild = resumedRequests.filter(request => isChildRequest(request.body));
      const resumedParent = resumedRequests.filter(request => !isChildRequest(request.body));
      expect(resumedChild.map(request => [request.body.max_tokens, request.authorization])).toEqual([[1024, `Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`]]);
      expect(resumedParent.map(request => [request.body.max_tokens, request.authorization])).toEqual([[512, null], [512, null], [512, null]]);
      f.settings.providers.remote.base_url += "/changed";
      f.save();
      const rebound = await runFx(["ask", "--json", "--resume", id, "Continue the named child again"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (rebound.code !== 0) throw new Error(rebound.stdout + rebound.stderr);
      // The child cannot reach its rebound endpoint, so it never asks, and its
      // failure reaches the parent as a report.
      const reboundRequests = f.requests.slice(8);
      expect(reboundRequests.every(request => !isChildRequest(request.body) && request.authorization === null && request.path === "/v1/chat/completions")).toBe(true);
      const report = reboundRequests.find(request => isReportTurn(request.body));
      expect(report).toBeDefined();
      expect(report!.body.messages.at(-1).content).toContain("failed");
    } finally { f.close(); }
  }, 100000);

  test("configured child compaction uses the model capability lookup", async () => {
    let parentTurns = 0;
    const f = fixture(body => {
      if (body.model === "child-model") {
        // Context pressure comes from the child's own replies. Compaction keeps
        // them word for word, shortening the longest, so it needs no model call.
        return completion(body.model, "child reply " + "detail ".repeat(2000), Math.ceil(JSON.stringify(body).length / 4));
      }
      if (isReportTurn(body)) return completion(body.model, "report handled");
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      parentTurns++;
      return toolCompletion(body.model, "subagent", { request: { action: "message", agent: "reader", message: `child context ${parentTurns}`, ...(parentTurns === 1 ? { model: "child-model" } : {}) } }, `context-call-${parentTurns}`);
    });
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 512, supports_tool_use: true };
    f.save();
    let id: string | undefined;
    try {
      for (let turn = 0; turn < 12; turn++) {
        const result = await runFx(["ask", "--json", ...(id ? ["--resume", id] : []), "Continue the child context"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
        if (result.code !== 0) throw new Error(result.stdout + result.stderr);
        id = JSON.parse(result.stdout).session_id;
        const returned = f.requests.filter(request => request.body.model === "local-model" && request.body.messages.at(-1)?.role === "tool").at(-1)!.body.messages.at(-1).content;
        if (!JSON.parse(returned).ok) throw new Error(returned);
        expect(JSON.parse(returned).ok).toBe(true);
      }
      const childRequests = f.requests.filter(request => request.body.model === "child-model");
      // Only the child model's own small context window makes the child compact.
      expect(childRequests.some(request => JSON.stringify(request.body.messages).includes("<compacted_conversation>"))).toBe(true);
      expect(childRequests.every(request => request.body.max_tokens > 0 && request.body.max_tokens <= 512)).toBe(true);
      expect(f.requests.every(request => request.path === "/v1/chat/completions" && request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 90000);

  test("automatic permission review uses the custom connection", async () => {
    const f = fixture(body => {
      if (body.tools?.some((tool: any) => tool.function?.name === "permission_decision")) return toolCompletion(body.model, "permission_decision", { decision: "clear", rationale: "fixture review" });
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "edit finished");
      return toolCompletion(body.model, "shell", { request: { action: "run", command: "python3 -c 'print(42)'" } });
    });
    try {
      f.settings.permission_mode = "auto";
      (f.settings.providers.local as any).reviewer_model = "review-model";
      (f.settings.providers.local.model_metadata as any)["review-model"] = { context_window: 262144, max_output_tokens: 512 };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the Python snippet"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const review = f.requests.find(request => request.body.tools?.some((tool: any) => tool.function?.name === "permission_decision"));
      expect(review?.body.model).toBe("review-model");
      expect(review?.body.max_tokens).toBe(512);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 35000);

  test.each(["clear", "caution", "missing", "malformed", "refused", "truncated", "incomplete"])("custom review response recovery preserves %s outcome", async outcome => {
    let marker = "";
    let reviews = 0;
    const f = fixture(body => {
      if (body.tools?.some((tool: any) => tool.function?.name === "permission_decision")) {
        reviews++;
        if (reviews === 1 || (outcome === "missing" && reviews === 2)) {
          if (outcome === "malformed") return rawToolCalls(body.model, [{ id: "review-1", name: "permission_decision", arguments: "{\"decision\":\"clear\"" }]);
          if (outcome === "refused" || outcome === "truncated" || outcome === "incomplete") {
            const chunks = [
              { id: "review", model: body.model, choices: [{ index: 0, delta: outcome === "refused" ? { refusal: "Cannot review this." } : { content: "Incomplete review." }, finish_reason: null }] },
              { id: "review", model: body.model, choices: [{ index: 0, delta: {}, finish_reason: outcome === "truncated" ? "length" : "stop" }] },
            ];
            return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + (outcome === "incomplete" ? "" : "data: [DONE]\n\n"), { headers: { "content-type": "text/event-stream" } });
          }
          return completion(body.model, "The action looks safe.");
        }
        return toolCompletion(body.model, "permission_decision", outcome === "caution"
          ? { decision: "caution", category: "system_harm", evidence: reviewedActionEvidence(JSON.stringify(body)) }
          : { decision: "clear" });
      }
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "review finished");
      return toolCompletion(body.model, "shell", { request: { action: "run", command: `python3 -c 'from pathlib import Path; p=Path(${JSON.stringify(marker)}); p.write_text(p.read_text()+"one\\n")'` } });
    });
    try {
      marker = join(f.workspace, "review-effects.txt");
      writeFileSync(marker, "");
      f.settings.permission_mode = "auto";
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the local fixture once."], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(readFileSync(marker, "utf8")).toBe(["clear", "malformed"].includes(outcome) ? "one\n" : "");
      // A held caution adds one confirming review of the same request.
      expect(reviews).toBe(outcome === "caution" ? 3 : ["clear", "missing", "malformed"].includes(outcome) ? 2 : 1);
      const requests = f.requests.filter(request => request.body.tools?.some((tool: any) => tool.function?.name === "permission_decision"));
      for (const request of requests.slice(1)) expect(request.body).toEqual(requests[0].body);
      expect(f.requests.every(request => request.path === "/v1/chat/completions")).toBe(true);
    } finally { f.close(); }
  }, 20000);

  test.each(["caution", "invalid"])("%s custom permission reviews never authorize execution", async decision => {
    let marker = "";
    const f = fixture(body => {
      if (body.tools?.some((tool: any) => tool.function?.name === "permission_decision")) return toolCompletion(body.model, "permission_decision", {
        decision,
        rationale: "fixture review",
        ...(decision === "caution" ? { category: "system_harm", evidence: reviewedActionEvidence(JSON.stringify(body)) } : {}),
      });
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "action held");
      return toolCompletion(body.model, "shell", { request: { action: "run", command: `python3 -c 'open("${marker}", "w").write("bad")'` } });
    });
    try {
      marker = join(f.workspace, "review-must-not-run.txt");
      f.settings.permission_mode = "auto";
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the Python snippet"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests.some(request => request.body.tools?.some((tool: any) => tool.function?.name === "permission_decision"))).toBe(true);
      expect(existsSync(marker)).toBe(false);
      expect(f.requests.every(request => request.path === "/v1/chat/completions")).toBe(true);
    } finally { f.close(); }
  }, 20000);

  test("resume uses its own key when a different bearer connection is the default", async () => {
    const f = fixture();
    try {
      (f.settings.providers.local as any).auth = { type: "bearer", env: "FX_TEST_LOCAL_TOKEN" };
      f.save();
      const env = { ...f.env, FX_TEST_LOCAL_TOKEN: "local-only-token" };
      const first = await runFx(["ask", "--json", "remember remote"], { cwd: f.workspace, env: { ...env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const id = JSON.parse(first.stdout).session_id;
      const resumed = await runFx(["ask", "--json", "--resume", id, "continue"], { cwd: f.workspace, env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].body.model).toBe("remote-model");
      expect(f.requests[1].authorization).toBe("Bearer own-provider-token");
    } finally { f.close(); }
  }, 45000);

  test("malformed workspace provider overrides fail before any network request", async () => {
    const f = fixture();
    try {
      f.settings.provider = "gateway";
      (f.settings as any).workspaces = { [f.workspace]: { provider: "local", permission_mode: "invalid" } };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "local-only prompt"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test("truncated tool streams cannot execute a partially delivered call", async () => {
    const f = fixture(body => new Response(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "partial", type: "function", function: { name: "write_file", arguments: JSON.stringify({ path: "must-not-exist.txt", content: "unsafe" }) } }] }, finish_reason: "tool_calls" }] })}\n\n`, { headers: { "content-type": "text/event-stream" } }));
    try {
      f.settings.permission_mode = "full-access";
      (f.settings as any).yolo_acknowledged = true;
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Write must-not-exist.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(result.code).not.toBe(0);
      expect(existsSync(join(f.workspace, "must-not-exist.txt"))).toBe(false);
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 15000);

  test.each(["headers", "stream"])("cancellation stops stalled custom %s without replaying the POST", async phase => {
    const f = fixture(() => phase === "headers" ? new Promise<Response>(() => {}) : new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}\n\n')); } }), { headers: { "content-type": "text/event-stream" } }));
    const env: Record<string, string | undefined> = { ...process.env };
    for (const [key, value] of Object.entries(f.env)) {
      if (value === undefined) delete env[key]; else env[key] = value;
    }
    const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const output = Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    let forced = false;
    const timer = setTimeout(() => { forced = true; child.kill("SIGKILL"); }, 8000);
    try {
      const until = Date.now() + 5000;
      while (f.requests.length === 0 && child.exitCode === null && Date.now() < until) await Bun.sleep(10);
      expect(f.requests).toHaveLength(1);
      child.kill("SIGINT");
      expect(await child.exited).toBe(130);
      await output;
      expect(forced).toBe(false);
      expect(f.requests).toHaveLength(1);
    } finally {
      clearTimeout(timer);
      if (child.exitCode === null) child.kill("SIGKILL");
      await child.exited;
      await output;
      f.close();
    }
  }, 12000);

  test("a connection without a saved model runs from --model or FX_MODEL and rejects a blank FX_MODEL", async () => {
    const f = fixture();
    try {
      delete (f.settings.models as Record<string, string>).local;
      f.save();
      const chatModels = () => f.requests.filter(request => request.path === "/v1/chat/completions").map(request => request.body.model);

      const flag = await runFx(["ask", "--json", "--no-save", "--model", "flag-model", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      if (flag.code !== 0) throw new Error(flag.stdout + flag.stderr);
      const env = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "  env-model  " }, timeoutMs: 10000 });
      if (env.code !== 0) throw new Error(env.stdout + env.stderr);
      expect(chatModels()).toEqual(["flag-model", "env-model"]);

      const status = await runFx(["status", "--json"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "env-model" } });
      expect(status.code).toBe(0);
      expect(JSON.parse(status.stdout)).toMatchObject({ model: "env-model", model_origin: "FX_MODEL", model_source: "local" });

      const blank = await runFx(["status"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "   " } });
      expect(blank.code).toBe(1);
      expect(blank.stderr).toBe("fx: no model is selected for this connection; save one under \"models\" in ~/.fx/settings.json, or set a model for this run with --model or FX_MODEL\n");
      expect(chatModels()).toHaveLength(2);
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).models.local).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("redirects cannot forward credentials to another connection", async () => {
    const target = fixture();
    const f = fixture(() => new Response("redirect", { status: 307, headers: { location: `${target.settings.providers.local.base_url}/chat/completions` } }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" } });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(1);
      expect(target.requests).toHaveLength(0);
    } finally { f.close(); target.close(); }
  });

  test("provider error diagnostics redact the selected key", async () => {
    const f = fixture(() => Response.json({ error: { message: "rejected own-provider-token" } }, { status: 401, headers: { "retry-after": "3" } }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(() => JSON.parse(result.stdout)).not.toThrow();
      expect(result.stderr).not.toContain("panic");
      expect(result.stdout + result.stderr).not.toContain("own-provider-token");
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 15000);

  test.each(["slashes", "unicode", "plain", "duplicate"])("provider errors redact opaque credentials encoded as %s", async encoding => {
    const token = "alpha/beta/gamma";
    const encoded = encoding === "slashes" ? token.replaceAll("/", "\\/") : [...token].map(char => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
    const body = encoding === "plain" ? `rejected ${token}` : encoding === "duplicate" ? `{"error":{"message":"rejected ${encoded}"},"${token}":0,"${encoded}":1}` : `{"error":{"message":"rejected ${encoded}","code":"${encoded}"}}`;
    const f = fixture(() => new Response(body, { status: 400 }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: token } });
      expect(result.code).toBe(1);
      expect(() => JSON.parse(result.stdout)).not.toThrow();
      expect(result.stdout + result.stderr).not.toContain(token);
      expect(result.stdout + result.stderr).toContain(encoding === "duplicate" ? "could not be decoded" : "rejected");
    } finally { f.close(); }
  });

  test("corrupt profile JSON cannot silently choose Gateway", async () => {
    const f = fixture();
    try {
      writeFileSync(f.settingsPath, '{"provider":"local",');
      const result = await runFx(["ask", "--json", "--no-save", "local-only prompt"], { cwd: f.workspace, env: f.env, timeoutMs: 8000 });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 12000);

  test("invalid bearer header bytes are rejected before sending", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: "bad\nheader" } });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("process overrides select a connection and opaque model without rewriting settings", async () => {
    const f = fixture();
    try {
      const before = readFileSync(f.settingsPath, "utf8");
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_MODEL: "unlisted-model" } });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.model).toBe("unlisted-model");
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(readFileSync(f.settingsPath, "utf8")).toBe(before);
    } finally { f.close(); }
  });

  test("project files cannot replace profile connections", async () => {
    const f = fixture();
    try {
      writeFileSync(join(f.workspace, ".fx.json"), JSON.stringify({ provider: "remote", providers: { local: "invalid" } }));
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: f.env });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.model).toBe("local-model");
      expect(f.requests[0].authorization).toBeNull();
    } finally { f.close(); }
  });

  test("saved history remains readable after its connection is removed", async () => {
    const f = fixture();
    try {
      const saved = await runFx(["ask", "--json", "remember this"], { cwd: f.workspace, env: f.env });
      if (saved.code !== 0) throw new Error(saved.stdout + saved.stderr);
      const id = JSON.parse(saved.stdout).session_id;
      delete (f.settings.providers as any).local;
      f.save();
      const history = await runFx(["session", id, "--json"], { cwd: f.workspace, env: f.env });
      if (history.code !== 0) throw new Error(history.stdout + history.stderr);
      expect(history.stdout).toContain("remember this");
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 25000);

  test("ignored workspace provider definitions stay inert when a sibling workspace field is malformed", async () => {
    const f = fixture();
    try {
      (f.settings as any).workspaces = {
        [f.workspace]: {
          providers: { shadow: { protocol: "openai-chat-completions", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } },
          effort: 42,
        },
      };
      f.save();
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.model_source).toBe("local");
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(status.connected_providers).toContain("local");
      expect(status.connected_providers).not.toContain("shadow");
      expect(result.stderr).toContain("malformed_settings");
    } finally { f.close(); }
  });

  test("ignored workspace provider definitions with broken protocols stay inert during recovery", async () => {
    const f = fixture();
    try {
      (f.settings as any).workspaces = {
        [f.workspace]: {
          providers: { shadow: { protocol: "bogus", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } },
          effort: 42,
        },
      };
      f.save();
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(result.stderr).toContain("malformed_settings");
    } finally { f.close(); }
  });

  test("unknown connections and missing keys fail without a Gateway fallback", async () => {
    const f = fixture();
    try {
      const unknown = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "missing" } });
      expect(unknown.code).not.toBe(0);
      const missingKey = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: undefined } });
      expect(missingKey.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 25000);
});

/// The model metadata of a fixture connection, to add fields to.
function metadata(f: ReturnType<typeof fixture>, connection: "local" | "remote" = "local"): Record<string, any> {
  const models = f.settings.providers[connection].model_metadata as Record<string, any>;
  return models[`${connection}-model`];
}

/// The settings of a fixture connection, to add fields to.
function connection(f: ReturnType<typeof fixture>, name: "local" | "remote" = "local"): Record<string, any> {
  return f.settings.providers[name];
}

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}

describe("custom connection options", () => {
  test("effort: a declared level sends its fields, over the model's own, and no level sends none", async () => {
    const f = fixture();
    try {
      Object.assign(metadata(f), {
        request: { temperature: 0.2, top_p: 0.9 },
        reasoning_efforts: { low: { reasoning_effort: "low" }, high: { reasoning_effort: "high", temperature: 0.7 } },
      });
      f.save();
      const high = await runFx(["ask", "--json", "--no-save", "--effort", "high", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (high.code !== 0) throw new Error(high.stdout + high.stderr);
      expect(high.stderr).toBe("");
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.reasoning_effort).toBe("high");
      expect(f.requests[0].body.temperature).toBe(0.7);
      expect(f.requests[0].body.top_p).toBe(0.9);
      expect(f.requests[0].body.model).toBe("local-model");

      const none = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (none.code !== 0) throw new Error(none.stdout + none.stderr);
      expect(none.stderr).toBe("");
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].body.reasoning_effort).toBeUndefined();
      expect(f.requests[1].body.temperature).toBe(0.2);
      expect(f.requests[1].body.top_p).toBe(0.9);
    } finally { f.close(); }
  }, 45000);

  test("effort: a configured level the model does not declare is not sent, and one line says so", async () => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? toolCompletion(body.model, "read_file", { path: "note.txt" }) : completion(body.model, "read complete"));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      (f.settings as any).effort = "high";
      f.save();
      const undeclared = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (undeclared.code !== 0) throw new Error(undeclared.stdout + undeclared.stderr);
      // Two requests in one session, one notice.
      expect(f.requests).toHaveLength(2);
      expect(f.requests.every(request => request.body.reasoning_effort === undefined)).toBe(true);
      expect(occurrences(undeclared.stderr, "high is not available for local-model")).toBe(1);

      metadata(f).reasoning_efforts = { low: { reasoning_effort: "low" } };
      f.save();
      calls = 1;
      const other = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (other.code !== 0) throw new Error(other.stdout + other.stderr);
      expect(f.requests[2].body.reasoning_effort).toBeUndefined();
      expect(occurrences(other.stderr, "high is not available for local-model")).toBe(1);

      (f.settings as any).effort = "low";
      f.save();
      const declared = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (declared.code !== 0) throw new Error(declared.stdout + declared.stderr);
      expect(f.requests[3].body.reasoning_effort).toBe("low");
      expect(declared.stderr).toBe("");
    } finally { f.close(); }
  }, 60000);

  test("request: the output limit travels in the field the model names, and extra headers come from the environment", async () => {
    const f = fixture();
    try {
      metadata(f, "remote").output_limit_field = "max_completion_tokens";
      connection(f, "remote").headers = { "X-Org": { env: "FX_TEST_PROVIDER_ORG" } };
      f.save();
      const env = { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_ORG: "org-fixture-123" };
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.max_completion_tokens).toBe(8192);
      expect(f.requests[0].body.max_tokens).toBeUndefined();
      expect(f.requests[0].headers["x-org"]).toBe("org-fixture-123");
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");

      // A header whose variable is unset fails before anything is sent.
      const unset = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: { ...env, FX_TEST_PROVIDER_ORG: undefined }, timeoutMs: 20000 });
      expect(unset.code).not.toBe(0);
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 45000);

  test("request: a header value the server quotes back is masked like the key", async () => {
    // A 400, because fx shows a server's own words for it; a 401 gets fx's fixed text.
    const f = fixture(() => Response.json({ error: { message: "rejected org-fixture-123 for own-provider-token" } }, { status: 400 }));
    try {
      connection(f, "remote").headers = { "X-Org": { env: "FX_TEST_PROVIDER_ORG" } };
      f.save();
      const env = { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_ORG: "org-fixture-123" };
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(f.requests).toHaveLength(1);
      expect(result.stdout + result.stderr).toContain("rejected");
      expect(result.stdout + result.stderr).not.toContain("org-fixture-123");
      expect(result.stdout + result.stderr).not.toContain("own-provider-token");
    } finally { f.close(); }
  }, 15000);

  test.each([
    ["a model's request fields", (f: ReturnType<typeof fixture>) => { metadata(f).request = { messages: [] }; }, "ReservedRequestField"],
    ["an effort level's fields", (f: ReturnType<typeof fixture>) => { metadata(f).reasoning_efforts = { high: { model: "other" } }; }, "ReservedRequestField"],
    ["the output limit, through a model's request fields", (f: ReturnType<typeof fixture>) => { metadata(f).request = { max_tokens: 1 }; }, "ReservedRequestField"],
    ["the Authorization header", (f: ReturnType<typeof fixture>) => { connection(f).headers = { authorization: { env: "FX_TEST_PROVIDER_ORG" } }; }, "ReservedHeader"],
  ])("request: settings that would replace %s are refused before any request", async (_what, change, code) => {
    const f = fixture();
    try {
      change(f);
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_TEST_PROVIDER_ORG: "org-fixture-123" }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(JSON.parse(result.stdout).error).toBe(code);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test("models: a connection that asks for it lists the server's models beside its own, with its defaults", async () => {
    const served = { object: "list", data: [{ id: "served-a", object: "model" }, { id: "local-model", object: "model" }, { id: "served-b", object: "model" }] };
    const f = fixture(undefined, { "/v1/models": () => Response.json(served) });
    try {
      Object.assign(connection(f), { fetch_models: true, model_defaults: { context_window: 65536, max_output_tokens: 777, supports_tool_use: true } });
      f.save();
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      const ids: string[] = JSON.parse(listed.stdout).ids;
      expect([...ids].sort()).toEqual(["local-model", "served-a", "served-b"]);
      expect(listed.stderr).toBe("");
      expect(f.requests.map(request => `${request.method} ${request.path}`)).toEqual(["GET /v1/models"]);
      expect(f.requests[0].authorization).toBeNull();

      // A model only the server lists takes the connection's defaults; one the
      // settings declare keeps its own.
      const defaulted = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "served-a" }, timeoutMs: 20000 });
      if (defaulted.code !== 0) throw new Error(defaulted.stdout + defaulted.stderr);
      const chat = f.requests.filter(request => request.path === "/v1/chat/completions");
      expect(chat).toHaveLength(1);
      expect(chat[0].body.model).toBe("served-a");
      expect(chat[0].body.max_tokens).toBe(777);
      const declared = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (declared.code !== 0) throw new Error(declared.stdout + declared.stderr);
      expect(f.requests.filter(request => request.path === "/v1/chat/completions")[1].body.max_tokens).toBe(8192);
    } finally { f.close(); }
  }, 60000);

  test("models: the model list request carries the connection's own key and headers", async () => {
    const f = fixture(undefined, { "/v1/models": () => Response.json({ object: "list", data: [{ id: "served-a" }] }) });
    try {
      Object.assign(connection(f, "remote"), { fetch_models: true, headers: { "X-Org": { env: "FX_TEST_PROVIDER_ORG" } } });
      f.save();
      const env = { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_ORG: "org-fixture-123" };
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env, timeoutMs: 15000 });
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      expect([...JSON.parse(listed.stdout).ids].sort()).toEqual(["remote-model", "served-a"]);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(f.requests[0].headers["x-org"]).toBe("org-fixture-123");
    } finally { f.close(); }
  }, 20000);

  test.each([
    ["answers 401", () => Response.json({ error: { message: "no" } }, { status: 401 })],
    ["answers 500", () => new Response("down", { status: 500 })],
    ["sends something that is not a model list", () => new Response("{\"object\":\"list\",\"data\":", { headers: { "content-type": "application/json" } })],
    ["lists nothing usable", () => Response.json({ object: "list", data: [{ id: "" }, { name: "no id" }, 7] })],
    ["never answers", () => neverAnswers()],
  ])("models: a server that %s leaves the models in settings, with one line", async (_what, reply) => {
    const f = fixture(undefined, { "/v1/models": reply });
    try {
      Object.assign(connection(f), { fetch_models: true, timeouts: { first_response_ms: 300 } });
      f.save();
      const started = performance.now();
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      expect(performance.now() - started).toBeLessThan(8000);
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      expect(JSON.parse(listed.stdout).ids).toEqual(["local-model"]);
      expect(occurrences(listed.stderr, "showing the models in settings")).toBe(_what === "lists nothing usable" ? 0 : 1);
      expect(f.requests.filter(request => request.path === "/v1/models")).toHaveLength(1);
    } finally { f.close(); }
  }, 20000);

  test.each([
    ["first_response_ms", (model: string) => neverAnswers()],
    ["stall_ms", (model: string) => stallsAfterFirstChunk(model)],
  ])("timeouts: %s ends an attempt at the connection's bound, and fx sends again", async (key, silent) => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? silent(body.model) : completion(body.model, "answered the second attempt"));
    try {
      connection(f).timeouts = { [key]: 300 };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (result.code !== 0) throw new Error(`fx did not finish: ${result.stdout} ${result.stderr}`);
      expect(JSON.parse(result.stdout).final_output).toBe("answered the second attempt");
      expect(f.requests).toHaveLength(2);
      // The bound, then request recovery's first wait of about a second. The
      // built-in bounds are 120 s and 600 s.
      const gap = f.requests[1].at - f.requests[0].at;
      expect(gap).toBeGreaterThanOrEqual(300);
      expect(gap).toBeLessThan(6000);
    } finally { f.close(); }
  }, 25000);

  test("title: a connection's title model names a saved session, with no key", async () => {
    const f = fixture(body => body.model === "title-model" ? completion(body.model, "Renderer Loop Refactor") : completion(body.model));
    try {
      connection(f).title_model = "title-model";
      f.save();
      const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const titleCalls = f.requests.filter(request => request.body.model === "title-model");
      expect(titleCalls).toHaveLength(1);
      expect(titleCalls[0].path).toBe("/v1/chat/completions");
      expect(titleCalls[0].authorization).toBeNull();
      expect(JSON.stringify(titleCalls[0].body.messages)).toContain("refactor the renderer loop");
      const titles = rootSessionIds(f.home).map(id => (logLines(f.home, id) as any[]).filter(line => line.kind === "set" && line.key === "title").at(-1)?.value);
      expect(titles).toEqual(["Renderer Loop Refactor"]);
    } finally { f.close(); }
  }, 40000);

  test("vision: the connection's vision model reads an image for a model that cannot, and without one fx offers no fallback", async () => {
    const visionResult = JSON.stringify({ images: [{ image_id: 1, status: "ok", summary: "a square logo", visible_text: ["FX LOGO"], details: ["square layout"] }] });
    let turns = 0;
    const f = fixture(body => {
      if (body.model === "vision-model") return completion(body.model, visionResult);
      return ++turns === 1 ? toolCompletion(body.model, "vision", { image_ids: [1], focus: "describe the image" }, "call-vision") : completion(body.model, "it is a logo");
    });
    try {
      const image = join(f.workspace, "logo.png");
      copyFileSync(join(REPO_ROOT, "tests/e2e/fixtures/placeholder-logo.png"), image);
      connection(f).vision_model = "vision-model";
      // A model that says it cannot see images, so fx must use the fallback.
      metadata(f).supports_vision = false;
      f.save();
      // Vision asks before it sends an image anywhere; auto mode allows it.
      const result = await runFx(["ask", "--json", "--no-save", "--image", image, "Describe the attached image."], { cwd: f.workspace, env: { ...f.env, FX_PERMISSION_MODE: "auto" }, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).final_output).toBe("it is a logo");
      const vision = f.requests.filter(request => request.body?.model === "vision-model");
      expect(vision).toHaveLength(1);
      expect(vision[0].body.response_format.type).toBe("json_schema");
      expect(vision[0].body.response_format.json_schema.schema.type).toBe("object");
      const parts = vision[0].body.messages.at(-1).content;
      expect(parts.some((part: any) => part.type === "image_url" && part.image_url.url.startsWith("data:image/png;base64,"))).toBe(true);
      const turn = f.requests.filter(request => request.body?.model === "local-model");
      expect(turn).toHaveLength(2);
      expect(turn[0].body.tools.some((tool: any) => tool.function.name === "vision")).toBe(true);
      expect(JSON.stringify(turn[0].body)).not.toContain("image_url");
      expect(JSON.stringify(turn[1].body)).toContain("FX LOGO");

      // Without a vision model the connection has no image fallback.
      delete connection(f).vision_model;
      f.save();
      turns = 1;
      const before = f.requests.length;
      const plain = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (plain.code !== 0) throw new Error(plain.stdout + plain.stderr);
      const offered = f.requests.slice(before).map(request => request.body.tools?.map((tool: any) => tool.function.name) ?? []);
      expect(offered).toHaveLength(1);
      expect(offered[0]).not.toContain("vision");
    } finally { f.close(); }
  }, 45000);

  test("usage: the cached token count a server reports reaches the JSON result", async () => {
    const f = fixture(body => completion(body.model, "local reply", 12, 9));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).usage).toEqual({ input_tokens: 12, output_tokens: 3, cache_read_tokens: 9 });
    } finally { f.close(); }
  });
});

// The same options on the two other protocols a connection can speak, each
// against a fake built from a real server's replies
// (`fixtures/custom-endpoint-captures/`).
const OTHER_PROTOCOLS = [
  { protocol: "openai-responses", fake: responsesFake, owned: "input", limitField: "max_output_tokens", effort: { reasoning: { effort: "high" } }, effortKey: "reasoning" },
  { protocol: "anthropic-messages", fake: messagesFake, owned: "system", limitField: "max_tokens", effort: { thinking: { type: "enabled", budget_tokens: 2048 } }, effortKey: "thinking" },
] as const;

describe.each(OTHER_PROTOCOLS)("custom connection on $protocol", ({ protocol, fake, owned, limitField, effort, effortKey }) => {
  function protocolFixture(respond?: (body: any) => Response | Promise<Response>, routes: Record<string, (body: any) => Response | Promise<Response>> = {}) {
    const f = fixture(undefined, { [fake.path]: body => respond ? respond(body) : fake.completion(body.model), ...routes });
    for (const name of ["local", "remote"] as const) connection(f, name).protocol = protocol;
    f.save();
    return f;
  }
  const sent = (f: ReturnType<typeof fixture>) => f.requests.filter(request => request.path === fake.path);

  test("a tool call and its result go to the connection, and the reply's usage reaches the JSON result", async () => {
    let calls = 0;
    const f = protocolFixture(body => ++calls === 1 ? fake.toolCompletion(body.model, "read_file", { path: "note.txt" }) : fake.completion(body.model, "read complete", { input: 12, output: 3, cached: 9 }));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const json = JSON.parse(result.stdout);
      expect(json.final_output).toBe("read complete");
      // Both requests of the turn: 12 + 12 in, 3 + 3 out, and the second's cached 9.
      expect(json.usage).toEqual({ input_tokens: 24, output_tokens: 6, cache_read_tokens: 9 });
      expect(f.requests.map(request => request.path)).toEqual([fake.path, fake.path]);
      expect(fake.requestView(f.requests[0].body).toolNames).toContain("read_file");
      expect(fake.requestView(f.requests[0].body).limit).toBe(8192);
      expect(JSON.stringify(f.requests[1].body)).toContain("fixture contents");
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 45000);

  test("effort: a declared level sends its fields over the model's own, and one the model does not declare is left out with one line", async () => {
    const f = protocolFixture();
    try {
      Object.assign(metadata(f), { request: { temperature: 0.2 }, reasoning_efforts: { high: { ...effort, temperature: 0.7 } } });
      f.save();
      const high = await runFx(["ask", "--json", "--no-save", "--effort", "high", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (high.code !== 0) throw new Error(high.stdout + high.stderr);
      expect(high.stderr).toBe("");
      expect(sent(f)[0].body[effortKey]).toEqual((effort as any)[effortKey]);
      expect(sent(f)[0].body.temperature).toBe(0.7);

      const none = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (none.code !== 0) throw new Error(none.stdout + none.stderr);
      expect(sent(f)[1].body[effortKey]).toBeUndefined();
      expect(sent(f)[1].body.temperature).toBe(0.2);

      (f.settings as any).effort = "low";
      f.save();
      const undeclared = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (undeclared.code !== 0) throw new Error(undeclared.stdout + undeclared.stderr);
      expect(sent(f)[2].body[effortKey]).toBeUndefined();
      expect(occurrences(undeclared.stderr, "low is not available for local-model")).toBe(1);
    } finally { f.close(); }
  }, 60000);

  test("request: the model's fields, the output limit and a header from the environment reach the server, and a field fx owns is refused", async () => {
    const f = protocolFixture();
    try {
      metadata(f, "remote").request = { top_p: 0.9 };
      connection(f, "remote").headers = { "X-Org": { env: "FX_TEST_PROVIDER_ORG" } };
      f.save();
      const env = { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_ORG: "org-fixture-123" };
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const request = sent(f)[0];
      expect(request.body.top_p).toBe(0.9);
      expect(request.body[limitField]).toBe(8192);
      expect(request.headers["x-org"]).toBe("org-fixture-123");
      expect(request.authorization).toBe("Bearer own-provider-token");
      if (protocol === "anthropic-messages") expect(request.headers["anthropic-version"]).toBe("2023-06-01");

      metadata(f).request = { [owned]: "replaced" };
      f.save();
      const refused = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(refused.code).toBe(1);
      expect(JSON.parse(refused.stdout).error).toBe("ReservedRequestField");
      expect(sent(f)).toHaveLength(1);
    } finally { f.close(); }
  }, 45000);

  test("timeouts: first_response_ms ends an attempt at the connection's bound, and fx sends again", async () => {
    let calls = 0;
    const f = protocolFixture(body => ++calls === 1 ? neverAnswers() : fake.completion(body.model, "answered the second attempt"));
    try {
      connection(f).timeouts = { first_response_ms: 300 };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (result.code !== 0) throw new Error(`fx did not finish: ${result.stdout} ${result.stderr}`);
      expect(JSON.parse(result.stdout).final_output).toBe("answered the second attempt");
      expect(sent(f)).toHaveLength(2);
      const gap = sent(f)[1].at - sent(f)[0].at;
      expect(gap).toBeGreaterThanOrEqual(300);
      expect(gap).toBeLessThan(6000);
    } finally { f.close(); }
  }, 25000);

  test("title and models: the title model names a saved session, and the server's model list joins the declared models", async () => {
    const f = protocolFixture(
      body => body.model === "title-model" ? fake.completion(body.model, "Renderer Loop Refactor") : fake.completion(body.model),
      { "/v1/models": () => Response.json({ object: "list", data: [{ id: "served-a" }, { id: "local-model" }] }) },
    );
    try {
      Object.assign(connection(f), { title_model: "title-model", fetch_models: true, model_defaults: { max_output_tokens: 777 } });
      f.save();
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      expect([...JSON.parse(listed.stdout).ids].sort()).toEqual(["local-model", "served-a"]);

      const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(sent(f).filter(request => request.body.model === "title-model")).toHaveLength(1);
      const titles = rootSessionIds(f.home).map(id => (logLines(f.home, id) as any[]).filter(line => line.kind === "set" && line.key === "title").at(-1)?.value);
      expect(titles).toEqual(["Renderer Loop Refactor"]);
    } finally { f.close(); }
  }, 45000);
});

// The bytes a real server sent, unedited (`fixtures/custom-endpoint-captures/`):
// a tool call, then text, for each protocol.
describe("replay: fx reads the replies a real local server sent", () => {
  const capture = (name: string) => new Response(readFileSync(join(REPO_ROOT, "tests/e2e/fixtures/custom-endpoint-captures", name)), { headers: { "content-type": "text/event-stream" } });
  test.each([
    ["openai-chat-completions", "/v1/chat/completions", "chat", "ok", "call_wbzs0x5v"],
    ["openai-responses", "/v1/responses", "responses", "ok", "call_jwjijtgk"],
    ["anthropic-messages", "/v1/messages", "messages", "Ok.", "call_xtq9b61r"],
  ])("%s", async (protocol, path, prefix, text, callId) => {
    let calls = 0;
    const f = fixture(undefined, { [path]: () => capture(++calls === 1 ? `${prefix}-tool-call.sse` : `${prefix}-text.sse`) });
    try {
      connection(f).protocol = protocol;
      f.save();
      // The recorded call reads a path outside the workspace, which fails;
      // full access lets it run without a prompt.
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: { ...f.env, FX_PERMISSION_MODE: "full-access" }, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const json = JSON.parse(result.stdout);
      expect(json.final_output).toBe(text);
      expect(json.tool_calls.map((call: any) => call.name)).toEqual(["read_file"]);
      const sent = f.requests.filter(request => request.path === path);
      expect(sent).toHaveLength(2);
      expect(JSON.stringify(sent[1].body)).toContain(callId);
    } finally { f.close(); }
  }, 30000);
});

describe("custom connection limits", () => {
  test("stress: 256 declared models, 16 levels for each through model_defaults, and a server list of 10,000 models", async () => {
    // Settings files stop at 64 KiB, so a connection with many models
    // declares them briefly and gives their shared fields in model_defaults.
    const levels = Object.fromEntries(Array.from({ length: 16 }, (_, index) => [`level${index}`, { reasoning_effort: `l${index}` }]));
    const declared = Object.fromEntries(Array.from({ length: 256 }, (_, index) => [`model-${index}`, { context_window: 131072 }]));
    const served = { object: "list", data: Array.from({ length: 10_000 }, (_, index) => ({ id: `model-${index}`, object: "model" })) };
    const f = fixture(undefined, { "/v1/models": () => Response.json(served) });
    try {
      Object.assign(connection(f), { fetch_models: true, model_metadata: declared, model_defaults: { max_output_tokens: 4096, supports_tool_use: true, reasoning_efforts: levels } });
      (f.settings.models as any).local = "model-255";
      f.save();
      expect(readFileSync(f.settingsPath).length).toBeLessThan(64 * 1024);
      const started = performance.now();
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      const listSeconds = (performance.now() - started) / 1000;
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      const ids: string[] = JSON.parse(listed.stdout).ids;
      expect(ids).toHaveLength(10_000);
      expect(new Set(ids).size).toBe(10_000);
      expect(listSeconds).toBeLessThan(10);

      // A model only the server lists gets every level from the defaults.
      const ask = await runFx(["ask", "--json", "--no-save", "--effort", "level15", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "model-9999" }, timeoutMs: 30000 });
      if (ask.code !== 0) throw new Error(ask.stdout + ask.stderr);
      const chat = f.requests.filter(request => request.path === "/v1/chat/completions");
      expect(chat).toHaveLength(1);
      expect(chat[0].body.model).toBe("model-9999");
      expect(chat[0].body.reasoning_effort).toBe("l15");
      expect(chat[0].body.max_tokens).toBe(4096);
    } finally { f.close(); }
  }, 60000);

  test("one past the limits is refused before any request: 257 models, or 17 levels", async () => {
    const f = fixture();
    try {
      connection(f).model_metadata = Object.fromEntries(Array.from({ length: 257 }, (_, index) => [`model-${index}`, {}]));
      f.save();
      const models = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "model-1" }, timeoutMs: 10000 });
      expect(models.code).toBe(1);
      expect(JSON.parse(models.stdout).error).toBe("LimitExceeded");
      connection(f).model_metadata = { "local-model": { reasoning_efforts: Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`l${index}`, {}])) } };
      f.save();
      const levels = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(levels.code).toBe(1);
      expect(JSON.parse(levels.stdout).error).toBe("LimitExceeded");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 30000);

  test("crash: a session killed mid-reply resumes on its own connection, with the effort level the settings give", async () => {
    let calls = 0;
    const f = fixture(body => {
      calls += 1;
      if (calls === 2) return stallsAfterFirstChunk(body.model);
      return completion(body.model, calls === 1 ? "first reply" : "resumed reply");
    });
    try {
      metadata(f).reasoning_efforts = { high: { reasoning_effort: "high" } };
      (f.settings as any).effort = "high";
      f.save();
      const first = await runFx(["ask", "--json", "start the long task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      const env = Object.fromEntries(Object.entries({ ...process.env, ...f.env }).filter(([, value]) => value !== undefined)) as Record<string, string>;
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--resume", session, "second step"], { cwd: f.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      const deadline = Date.now() + 15_000;
      while (f.requests.length < 2 && Date.now() < deadline) await Bun.sleep(20);
      expect(f.requests).toHaveLength(2);
      // Killed while the reply streams: no chance to save anything on the way out.
      child.kill(9);
      await child.exited;
      expect(child.signalCode).toBe("SIGKILL");
      const resumed = await runFx(["ask", "--json", "--resume", session, "continue the task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(JSON.parse(resumed.stdout).final_output).toBe("resumed reply");
      expect(f.requests).toHaveLength(3);
      for (const request of f.requests) {
        expect(request.path).toBe("/v1/chat/completions");
        expect(request.authorization).toBeNull();
        expect(request.body.reasoning_effort).toBe("high");
      }
      expect(JSON.stringify(f.requests[2].body.messages)).toContain("start the long task");
      expect(JSON.stringify(f.requests[2].body.messages)).toContain("first reply");
    } finally { f.close(); }
  }, 45000);
});

// OpenAI's Responses API answers 400 when a request asks for encrypted
// reasoning from a model that does not reason, and `include` is a field fx
// owns, so settings cannot take it out.
describe("custom connection on openai-responses: encrypted reasoning", () => {
  const high = { high: { reasoning: { effort: "high" } } };
  test.each([
    { name: "a model without effort levels", levels: undefined, defaults: undefined, include: false },
    { name: "a model whose effort levels are an empty list", levels: {}, defaults: undefined, include: false },
    { name: "a model with effort levels", levels: high, defaults: undefined, include: true },
    { name: "a model that takes its effort levels from model_defaults", levels: undefined, defaults: { reasoning_efforts: high }, include: true },
  ])("a Responses request asks for encrypted reasoning only when the model declares effort levels: $name", async ({ levels, defaults, include }) => {
    const f = fixture(undefined, {
      [responsesFake.path]: body => body.include !== undefined && !include
        ? new Response(JSON.stringify({ error: { message: "Encrypted content is not supported with this model.", type: "invalid_request_error", param: "include", code: null } }), { status: 400, headers: { "content-type": "application/json" } })
        : responsesFake.completion(body.model),
    });
    try {
      connection(f).protocol = "openai-responses";
      if (levels !== undefined) metadata(f).reasoning_efforts = levels;
      if (defaults !== undefined) connection(f).model_defaults = defaults;
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const sent = f.requests.filter(request => request.path === responsesFake.path);
      expect(sent.length).toBe(1);
      expect(sent[0].body.include).toEqual(include ? ["reasoning.encrypted_content"] : undefined);
    } finally { f.close(); }
  }, 25000);
});

describe("automatic permission review on a custom connection", () => {
  test.each([
    { name: "a review model the settings do not declare", declared: undefined, defaults: { max_output_tokens: 300 }, limit: 300 },
    { name: "a declared review model without its own limit", declared: { context_window: 262144 }, defaults: { max_output_tokens: 300 }, limit: 300 },
    { name: "a default above the review's own cap", declared: undefined, defaults: { max_output_tokens: 4096 }, limit: 2048 },
  ])("the review takes its output limit from the model defaults: $name", async ({ declared, defaults, limit }) => {
    const f = fixture(body => {
      if (body.tools?.some((tool: any) => tool.function?.name === "permission_decision")) return toolCompletion(body.model, "permission_decision", { decision: "clear", rationale: "fixture review" });
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "done");
      return toolCompletion(body.model, "shell", { request: { action: "run", command: "python3 -c 'print(42)'" } });
    });
    try {
      f.settings.permission_mode = "auto";
      connection(f).reviewer_model = "review-model";
      connection(f).model_defaults = defaults;
      if (declared !== undefined) (connection(f).model_metadata as any)["review-model"] = declared;
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the Python snippet"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const review = f.requests.find(request => request.body?.tools?.some((tool: any) => tool.function?.name === "permission_decision"));
      expect(review?.body.model).toBe("review-model");
      expect(review?.body.max_tokens).toBe(limit);
    } finally { f.close(); }
  }, 35000);
});

// What a person reads when a custom connection's settings are wrong: the file,
// the setting's path, and what to do, on every surface that reports it.
describe("custom connection errors name the setting", () => {
  const settingsFile = "~/.fx/settings.json";
  const owned = "fx writes this field itself; remove it";
  test.each([
    ["a model's request field fx writes", (f: ReturnType<typeof fixture>) => { metadata(f).request = { messages: [] }; },
      "providers.local.model_metadata.local-model.request.messages", owned],
    ["an effort level's field fx writes", (f: ReturnType<typeof fixture>) => { metadata(f).reasoning_efforts = { high: { model: "other" } }; },
      "providers.local.model_metadata.local-model.reasoning_efforts.high.model", owned],
    ["a header fx sets", (f: ReturnType<typeof fixture>) => { connection(f).headers = { authorization: { env: "FX_TEST_PROVIDER_ORG" } }; },
      "providers.local.headers.authorization", "fx sets this header itself; remove it"],
    ["a header given its value", (f: ReturnType<typeof fixture>) => { connection(f).headers = { "X-Org": "acme" }; },
      "providers.local.headers.X-Org", "a header's value is {\"env\": \"VARIABLE\"}, the environment variable that holds it"],
    ["an effort level fx can't name", (f: ReturnType<typeof fixture>) => { metadata(f).reasoning_efforts = { "High Effort!": {} }; },
      "providers.local.model_metadata.local-model.reasoning_efforts.\"High Effort!\"", "an effort level's name uses letters, digits, -, _, and ., and is not auto, adaptive, or default"],
    ["a timeout of 0", (f: ReturnType<typeof fixture>) => { connection(f).timeouts = { stall_ms: 0 }; },
      "providers.local.timeouts.stall_ms", "a timeout is a whole number of milliseconds from 1 to 86400000"],
    ["a field fx does not know", (f: ReturnType<typeof fixture>) => { metadata(f).bogus = 1; },
      "providers.local.model_metadata.local-model.bogus", "fx doesn't know this field; check its spelling or remove it"],
    ["a protocol fx does not speak", (f: ReturnType<typeof fixture>) => { connection(f).protocol = "openai"; },
      "providers.local.protocol", "the protocol is openai-chat-completions, openai-responses, or anthropic-messages"],
    ["a model id with a dot", (f: ReturnType<typeof fixture>) => { connection(f).model_metadata["gpt-4.1"] = { request: { model: "x" } }; },
      "providers.local.model_metadata.\"gpt-4.1\".request.model", owned],
  ])("settings: fx refuses %s with the setting's path and what to do", async (_what, change, path, fix) => {
    const f = fixture();
    try {
      change(f);
      f.save();
      const result = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_TEST_PROVIDER_ORG: "org-fixture-123" }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe(`fx: ${settingsFile}: ${path}: ${fix}\n`);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test("settings: a key thousands of bytes long is cut in the path, so the message stays one line", async () => {
    const f = fixture();
    try {
      metadata(f).request = { ["k".repeat(5000)]: 1 };
      f.save();
      const result = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(result.stderr.startsWith(`fx: ${settingsFile}: providers.local.model_metadata.local-model.request.kkkk`)).toBe(true);
      expect(result.stderr.split("\n")).toHaveLength(2);
      expect(result.stderr.length).toBeLessThan(400);
    } finally { f.close(); }
  }, 15000);

  test("settings: fx provider names the same setting", async () => {
    const f = fixture();
    try {
      const models = f.settings.providers.local.model_metadata as Record<string, any>;
      models["local-model"].request = { messages: [] };
      f.save();
      const result = await runFx(["provider", "local"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe("fx provider: ~/.fx/settings.json: providers.local.model_metadata.local-model.request.messages: fx writes this field itself; remove it\n");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 30000);

  test("settings: fx doctor names the same setting", async () => {
    const f = fixture();
    try {
      metadata(f).request = { messages: [] };
      f.save();
      const doctor = await runFx(["doctor"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(doctor.stdout).toContain(`  \u2717 config     failed to load config: ${settingsFile}: providers.local.model_metadata.local-model.request.messages: ${owned}`);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test.each([
    ["not set", undefined, "which is not set; set it, or remove the header from ~/.fx/settings.json"],
    ["empty", "", "which is empty; set it, or remove the header from ~/.fx/settings.json"],
    ["holding a control character", "acme\u0001", "whose value has a character a header can't carry; fix the variable"],
  ])("headers: a header variable %s is named with its header and connection, before any request", async (_what, value, rest) => {
    const f = fixture();
    try {
      connection(f).headers = { "X-Org": { env: "FX_PROBE_ORG" } };
      f.save();
      const result = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROBE_ORG: value }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe(`fx: the header X-Org of connection local reads FX_PROBE_ORG, ${rest}\n`);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test("headers: when headers on more than one connection can't be sent, each is named with its connection", async () => {
    const f = fixture();
    try {
      connection(f).headers = { "X-Org": { env: "FX_PROBE_ORG" } };
      (f.settings.providers as Record<string, any>).remote.headers = { "X-Team": { env: "FX_PROBE_TEAM" } };
      f.save();
      const result = await runFx(["ask", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROBE_ORG: undefined, FX_PROBE_TEAM: "" }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe("fx: 2 headers can't be sent: X-Org of connection local reads FX_PROBE_ORG, which is not set; X-Team of connection remote reads FX_PROBE_TEAM, which is empty. Set or fix each variable, or remove its header from ~/.fx/settings.json\n");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  const changed = "fx ask: This session's custom connection changed in ~/.fx/settings.json after the session was saved: its protocol, base_url, or auth. Change it back, or start a new session.\n";
  test.each([
    ["its protocol", (f: ReturnType<typeof fixture>) => { connection(f).protocol = "anthropic-messages"; }],
    ["its base_url", (f: ReturnType<typeof fixture>) => { connection(f).base_url = connection(f).base_url.replace("127.0.0.1", "localhost"); }],
    ["its auth", (f: ReturnType<typeof fixture>) => { connection(f).auth = { type: "bearer", env: "FX_TEST_PROVIDER_TOKEN" }; }],
  ])("resume: a session whose connection changed %s says so and sends nothing", async (_what, change) => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "first turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      change(f);
      f.save();
      const resumed = await runFx(["ask", "--resume", session, "second turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      expect(resumed.code).toBe(1);
      expect(resumed.stderr).toBe(changed);
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 30000);

  test("resume: a session whose connection was removed says so and sends nothing", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "first turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      delete (f.settings.providers as Record<string, unknown>).local;
      (f.settings as Record<string, unknown>).provider = "remote";
      f.save();
      const resumed = await runFx(["ask", "--resume", session, "second turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      expect(resumed.code).toBe(1);
      expect(resumed.stderr).toBe("fx ask: This session's custom connection is no longer in ~/.fx/settings.json. Add it back, or start a new session.\n");
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 30000);

  test("resume: a change outside the connection's binding still resumes", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "first turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      connection(f).timeouts = { stall_ms: 60000 };
      metadata(f).reasoning_efforts = { high: { reasoning_effort: "high" } };
      connection(f).headers = { "X-Org": { env: "FX_TEST_PROVIDER_ORG" } };
      f.save();
      const resumed = await runFx(["ask", "--json", "--resume", session, "second turn"], { cwd: f.workspace, env: { ...f.env, FX_TEST_PROVIDER_ORG: "org-fixture-123" }, timeoutMs: 15000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].headers["x-org"]).toBe("org-fixture-123");
    } finally { f.close(); }
  }, 30000);
});
