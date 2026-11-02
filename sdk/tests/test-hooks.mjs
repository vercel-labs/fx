#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createFxAgent, createFxEngine, createMemoryPersistence, memory } from "../node.js";
import { createMcpAdapter } from "../mcp.js";
import { toolObservation } from "../tool-observation.js";
import { createFxEngine as createSharedEngine } from "../fx-sdk.js";

const backend = process.argv[2] ?? "native";
assert.ok(["native", "wasm"].includes(backend));
const base = {
  backend,
  nativeAddon: new URL("../../zig-out/lib/libfx.node", import.meta.url),
  ...(backend === "wasm"
    ? { wasm: await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) }
    : {}),
  apiKey: "hook-fixture-credential",
  model: "fixture/hooks",
  instructions: "hook fixture instructions",
  modelCatalog: [
    { id: "fixture/hooks", type: "language", tags: ["tool-use"], context_window: 200000 },
  ],
};
const finish = (reason = "stop") => ({
  type: "finish",
  finishReason: { unified: reason, raw: reason },
  usage: { inputTokens: { total: 7, cacheRead: 2 }, outputTokens: { total: 3 } },
});
const answer = (text = "answer") => [{ type: "text-delta", delta: text }, finish()];
const call = (id, key) => ({
  type: "tool-call",
  toolCallId: id,
  toolName: "lookup",
  input: { key },
});
const sse = (events) =>
  new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n",
    {
      headers: { "content-type": "text/event-stream" },
    },
  );
function gateway(replies) {
  const bodies = [];
  return {
    bodies,
    fetch: async (_url, init) => {
      if (init.method === "GET") return Response.json({ data: base.modelCatalog });
      bodies.push(JSON.parse(new TextDecoder().decode(init.body)));
      const reply = replies[bodies.length - 1];
      assert.ok(reply, `unexpected model request ${bodies.length}`);
      return typeof reply === "function"
        ? reply(init)
        : reply instanceof Response
          ? reply
          : sse(reply);
    },
  };
}
const eventsOf = (events, type) => events.filter((event) => event.type === type);
async function drain(turn) {
  const updates = [];
  for await (const event of turn) updates.push(event);
  return { updates, result: await turn.result };
}

// Native semantic boundaries, not UI previews: exact model-to-tool IDs,
// parallel execution and failures, accepted results, and separate new turns.
{
  const events = [];
  const executed = [];
  const mock = gateway([
    [call("call-a", "alpha"), call("call-b", "beta"), finish("tool-calls")],
    answer(),
    answer("second"),
  ]);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    hooks: {
      captureContent: true,
      onEvent: (event) => {
        events.push(event);
      },
    },
    tools: [
      {
        name: "lookup",
        description: "Lookup fixture",
        inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
        async execute({ key }) {
          executed.push(key);
          if (key === "beta") throw new Error("lookup-fixture-error");
          return `value:${key}`;
        },
      },
    ],
  });
  try {
    assert.equal(
      (await drain(engine.prompt("use lookup", { turnId: "fixture-turn" }))).result.stopReason,
      "end_turn",
    );
    assert.deepEqual(executed.sort(), ["alpha", "beta"]);
    assert.equal(mock.bodies.length, 2);
    const start = eventsOf(events, "turn.start")[0];
    assert.equal(start.turnId, "fixture-turn");
    assert.equal(start.data.input, "use lookup");
    assert.equal(start.data.resumed, false);
    for (const event of events) {
      assert.equal(event.version, 1);
      assert.equal(event.sessionId, engine.sessionId);
      assert.equal(event.turnId, start.turnId);
      assert.equal(event.executionId, start.executionId);
      assert.ok(Number.isSafeInteger(event.timestamp) && event.timestamp > 0);
    }
    const modelStarts = eventsOf(events, "model.start");
    assert.deepEqual(
      modelStarts.map((event) => event.data.modelCallId),
      [1, 2],
    );
    assert.deepEqual(
      modelStarts.map((event) => event.stepIndex),
      [1, 2],
    );
    assert.equal(modelStarts[0].data.purpose, "agent");
    assert.ok(JSON.stringify(modelStarts[0].data.instructions).includes(base.instructions));
    const lookup = modelStarts[0].data.tools.find((tool) => tool.name === "lookup");
    assert.equal(JSON.parse(lookup.inputSchemaJson).properties.key.type, "string");
    const modelEnds = eventsOf(events, "model.end");
    assert.deepEqual(
      modelEnds[0].data.toolCalls.map((value) => value.callId),
      ["call-a", "call-b"],
    );
    assert.equal(modelEnds[1].data.output, "answer");
    assert.equal(modelEnds[1].data.usage.inputTokens, 7);
    for (const startEvent of modelStarts) {
      const admitted = events.find(
        (event) =>
          event.type === "model.admitted" && event.data.modelCallId === startEvent.data.modelCallId,
      );
      const end = modelEnds.find((event) => event.data.modelCallId === startEvent.data.modelCallId);
      assert.ok(events.indexOf(startEvent) < events.indexOf(admitted));
      assert.ok(events.indexOf(admitted) < events.indexOf(end));
    }
    const starts = eventsOf(events, "tool.start");
    assert.equal(starts.length, 2);
    const ends = eventsOf(events, "tool.end");
    const results = eventsOf(events, "tool.result");
    for (const event of starts) {
      const end = ends.find((value) => value.data.call.callId === event.data.call.callId);
      const result = results.find((value) => value.data.call.callId === event.data.call.callId);
      assert.ok(end && result);
      assert.ok(events.indexOf(event) < events.indexOf(end));
      assert.ok(events.indexOf(end) < events.indexOf(result));
      assert.deepEqual(JSON.parse(event.data.call.argumentsJson), {
        key: event.data.call.callId === "call-a" ? "alpha" : "beta",
      });
    }
    assert.equal(
      results.find((event) => event.data.call.callId === "call-b").data.status,
      "failure",
    );
    assert.equal(eventsOf(events, "turn.end")[0].data.outcome, "completed");
    assert.ok(!JSON.stringify(events).includes(base.apiKey));
    await drain(engine.prompt("next", { turnId: "next-turn" }));
    const turns = eventsOf(events, "turn.start");
    assert.equal(turns[1].turnId, "next-turn");
    assert.notEqual(turns[0].executionId, turns[1].executionId);
  } finally {
    await engine.close();
  }
}

// Metadata-only is the default. Rejected observer promises (including the
// error handler's), throws, mutation, and never-settling work cannot change fx.
{
  const seen = [];
  const errors = [];
  const mock = gateway([answer("private-output")]);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    hooks: {
      onEvent(event) {
        seen.push(structuredClone(event));
        event.data = { corrupted: true };
        if (seen.length === 1) throw new Error("observer-throw");
        if (seen.length === 2) return Promise.reject(new Error("observer-reject"));
        return new Promise(() => {});
      },
      onError(error) {
        errors.push(error.message);
        return Promise.reject(new Error("error-handler-reject"));
      },
    },
  });
  try {
    const { result } = await drain(engine.prompt("private-input"));
    assert.equal(result.stopReason, "end_turn");
    assert.equal(mock.bodies.length, 1);
    assert.deepEqual(errors.sort(), ["observer-reject", "observer-throw"]);
    assert.ok(!JSON.stringify(seen).includes("private-input"));
    assert.ok(!JSON.stringify(seen).includes("private-output"));
    assert.ok(seen.every((event) => !event.contentCaptured));
  } finally {
    await engine.close();
  }
}

// Content is bounded on a UTF-8 boundary without shortening the model's input.
{
  const events = [];
  const mock = gateway([answer()]);
  const input = "界".repeat(24000);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    hooks: {
      captureContent: true,
      onEvent: (event) => {
        events.push(event);
      },
    },
  });
  try {
    await drain(engine.prompt(input));
    const start = eventsOf(events, "turn.start")[0];
    assert.equal(new TextEncoder().encode(start.data.input).byteLength, 65535);
    assert.equal(start.contentTruncated, true);
    assert.ok(!start.data.input.includes("\ufffd"));
    assert.ok(JSON.stringify(mock.bodies).includes(input));
  } finally {
    await engine.close();
  }
}

// Instructions cannot starve the latest model-visible user input.
{
  const events = [];
  const engine = await createFxEngine({
    ...base,
    instructions: "x".repeat(60000),
    fetch: gateway([answer()]).fetch,
    hooks: {
      captureContent: true,
      onEvent: (event) => {
        events.push(event);
      },
    },
  });
  try {
    await drain(engine.prompt("needle"));
    assert.ok(eventsOf(events, "model.start")[0].data.messages.at(-1).content.includes("needle"));
  } finally {
    await engine.close();
  }
}

// A receipt follows accepted persistence, not a queued or rejected append.
// Yield/resume keeps the logical turn ID, but not its worker execution ID.
{
  const store = createMemoryPersistence();
  const events = [];
  const mock = gateway([
    [call("durable-call", "alpha"), finish("tool-calls")],
    answer("resumed"),
    answer("reran"),
  ]);
  let executions = 0;
  const options = {
    ...base,
    fetch: mock.fetch,
    sessionId: "hook-durable-session",
    persistence: store,
    hooks: {
      onEvent: (event) => {
        events.push(event);
      },
    },
    tools: [
      {
        name: "lookup",
        description: "Lookup",
        inputSchema: { type: "object" },
        execute: () => {
          executions += 1;
          return "durable-result";
        },
      },
    ],
  };
  let engine = await createFxEngine(options);
  try {
    assert.equal(
      (await drain(engine.prompt("lookup", { turnId: "durable-turn", yieldAt: Date.now() - 1 })))
        .result.stopReason,
      "yielded",
    );
    assert.equal(eventsOf(events, "turn.end")[0].data.outcome, "yielded");
    const first = eventsOf(events, "turn.start")[0];
    const receipt = eventsOf(events, "journal.commit").at(-1);
    assert.ok(receipt.data.cursor);
    assert.equal(receipt.turnId, null);
    await engine.close();
    engine = await createFxEngine(options);
    const restored = eventsOf(events, "journal.restore").at(-1);
    assert.equal(restored.data.resumable, true);
    assert.equal(restored.data.openTurnId, "durable-turn");
    assert.equal((await drain(engine.resume())).result.stopReason, "end_turn");
    const resumed = eventsOf(events, "turn.start").at(-1);
    assert.equal(resumed.data.resumed, true);
    assert.equal(resumed.turnId, first.turnId);
    assert.notEqual(resumed.executionId, first.executionId);
    for (const event of events.filter((event) => event.executionId === resumed.executionId))
      assert.equal(event.turnId, first.turnId, event.type);
    assert.equal(
      eventsOf(events, "turn.end").find((event) => event.executionId === resumed.executionId)
        .turnId,
      first.turnId,
    );
    assert.equal(executions, 1);
    assert.equal(eventsOf(events, "tool.start").length, 1);
    assert.equal(mock.bodies.length, 2);

    // A crash lost everything after the tool intent. Explicit permission to
    // rerun is new execution of the same logical call, before a new model step.
    const recorded = store.records.flatMap(
      (record) => JSON.parse(new TextDecoder().decode(record.data)).events,
    );
    const intent = recorded.findLastIndex((event) => event.type === "tool_intent");
    assert.ok(intent >= 0);
    const crashed = createMemoryPersistence();
    await crashed.append({
      expected: null,
      idempotencyKey: "fixture-crash",
      data: new TextEncoder().encode(
        JSON.stringify({ format: "libfx-journal-v1", events: recorded.slice(0, intent + 1) }),
      ),
    });
    await engine.close();
    engine = await createFxEngine({ ...options, persistence: crashed });
    assert.equal(
      (await drain(engine.resume({ onAmbiguous: () => "rerun" }))).result.stopReason,
      "end_turn",
    );
    const rerun = eventsOf(events, "tool.start").at(-1);
    const rerunTurn = eventsOf(events, "turn.start").at(-1);
    assert.equal(rerun.data.rerun, true);
    assert.equal(rerun.data.call.callId, "durable-call");
    assert.equal(rerun.turnId, first.turnId);
    assert.equal(rerun.executionId, rerunTurn.executionId);
    assert.ok(events.indexOf(rerunTurn) < events.indexOf(rerun));
    for (const event of events.filter((event) => event.executionId === rerunTurn.executionId))
      assert.equal(event.turnId, first.turnId, event.type);
    assert.equal(
      eventsOf(events, "turn.end").find((event) => event.executionId === rerunTurn.executionId)
        .turnId,
      first.turnId,
    );
    assert.equal(eventsOf(events, "turn.start").length, 3);
    assert.equal(eventsOf(events, "turn.end").length, 3);
    assert.equal(executions, 2);
  } finally {
    await engine.close();
  }
}

for (const wrapped of [false, true]) {
  const events = [];
  const engine = await createFxEngine({
    ...base,
    fetch: gateway([answer()]).fetch,
    persistence: {
      load: async () => ({}),
      append: async () => {
        const fenced = Object.assign(new Error("fenced"), { code: "FX_FENCED" });
        throw wrapped ? new Error("wrapped", { cause: fenced }) : fenced;
      },
    },
    hooks: {
      onEvent: (event) => {
        events.push(event);
      },
    },
  });
  try {
    await assert.rejects(drain(engine.prompt("never delivered")), /journal|append/i);
    assert.equal(eventsOf(events, "journal.commit").length, 0);
    assert.equal(eventsOf(events, "model.start").length, 0);
    assert.equal(eventsOf(events, "journal.error")[0].data.fenced, true);
  } finally {
    await engine.close().catch(() => {});
  }
}

// No receipt may precede the persistence owner's acknowledgement.
{
  const events = [];
  const store = createMemoryPersistence();
  const entered = Promise.withResolvers();
  const accepted = Promise.withResolvers();
  const mock = gateway([answer()]);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    persistence: {
      load: store.load,
      async append(record) {
        entered.resolve();
        await accepted.promise;
        return store.append(record);
      },
    },
    hooks: {
      onEvent: (event) => {
        events.push(event);
      },
    },
  });
  try {
    const running = drain(engine.prompt("wait for storage"));
    await entered.promise;
    assert.equal(eventsOf(events, "journal.commit").length, 0);
    assert.equal(mock.bodies.length, 0);
    accepted.resolve();
    await running;
    assert.ok(eventsOf(events, "journal.commit").length > 0);
  } finally {
    accepted.resolve();
    await engine.close();
  }
}

// Streaming cancellation produces one terminal model observation, no retry.
// A handoff is marked separately so the host needn't fail the logical turn.
for (const reason of [undefined, "handoff"]) {
  const events = [];
  let turn;
  const mock = gateway([
    (init) =>
      new Response(
        new ReadableStream({
          start(controller) {
            init.signal.addEventListener(
              "abort",
              () => controller.error(new DOMException("Aborted", "AbortError")),
              { once: true },
            );
            controller.enqueue(
              new TextEncoder().encode('data: {"type":"text-delta","delta":"partial"}\n\n'),
            );
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      ),
  ]);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    ...(reason === "handoff" ? { persistence: createMemoryPersistence() } : {}),
    hooks: {
      onEvent(event) {
        events.push(event);
        if (event.type === "model.output_start") turn.cancel(reason ? { reason } : {});
      },
    },
  });
  try {
    turn = engine.prompt("cancel the stream");
    await drain(turn);
    assert.equal(mock.bodies.length, 1);
    assert.equal(eventsOf(events, "model.start").length, 1);
    assert.equal(eventsOf(events, "model.end").length, 1);
    assert.equal(eventsOf(events, "model.end")[0].data.cancelled, true, JSON.stringify(events));
    assert.ok(["cancelled", "interrupted"].includes(eventsOf(events, "turn.end")[0].data.outcome));
    assert.equal(eventsOf(events, "turn.end")[0].data.handoff === true, reason === "handoff");
  } finally {
    await engine.close();
  }
}

// Hook transport and content capture are absent unless explicitly requested.
{
  const diagnostics = [];
  const engine = await createFxEngine({
    ...base,
    fetch: gateway([answer()]).fetch,
    onEvent: (event) => {
      diagnostics.push(event);
    },
  });
  try {
    await drain(engine.prompt("hooks disabled"));
    const created = diagnostics.find(
      (event) => event.type === "acp.send" && event.message?.method === "libfx/new",
    );
    assert.equal(created.message.params.hooks, undefined);
    assert.ok(!diagnostics.some((event) => event.message?.method === "libfx/hook"));
  } finally {
    await engine.close();
  }
}

// Durable agents forward the same observer into the engine that runs the turn.
{
  const events = [];
  const hooks = new (class {
    #events = events;
    onEvent(event) {
      this.#events.push(event);
    }
  })();
  const agent = createFxAgent({
    ...base,
    durability: memory(),
    fetch: gateway([answer("durable agent")]).fetch,
    hooks,
  });
  try {
    const session = agent.session("hook-factory-session");
    const turn = session.prompt("observe the durable engine");
    await drain(turn);
    assert.equal(eventsOf(events, "turn.start").length, 1);
    assert.equal(eventsOf(events, "turn.end").length, 1);
    assert.equal(eventsOf(events, "turn.start")[0].sessionId, session.id);
    assert.ok(eventsOf(events, "journal.commit").length > 0);
  } finally {
    await agent.close();
  }
}

// Input waits are real host effects; observer failures cannot change decisions,
// answers, or thrown errors. Child engines carry their caller's tool identity.
{
  const events = [];
  const mock = gateway([
    [call("parent-call", "inputs"), finish("tool-calls")],
    answer("parent finished"),
  ]);
  let effects = 0;
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    hooks: {
      captureContent: true,
      onEvent: (event) => {
        events.push(event);
      },
    },
    tools: [
      {
        name: "lookup",
        description: "Inputs and child",
        inputSchema: { type: "object" },
        async execute(_input, context) {
          assert.ok(context.observation);
          const accepted = { outcome: "accepted", answers: ["approve"], value: 42 };
          assert.equal(
            await context.observation.wait({ kind: "approval", prompt: "Allow this?" }, () => {
              effects++;
              return accepted;
            }),
            accepted,
          );
          const denied = { outcome: "denied", answers: ["no"] };
          assert.equal(
            await context.observation.wait(
              {
                kind: "question",
                questions: [{ question: "Continue?", options: [{ label: "no" }] }],
              },
              () => {
                effects++;
                return denied;
              },
            ),
            denied,
          );
          const failure = new Error("input-fixture-failure");
          await assert.rejects(
            context.observation.wait({ kind: "question", prompt: "Fail" }, () => {
              effects++;
              throw failure;
            }),
            (error) => error === failure,
          );
          const child = await createFxEngine({
            ...base,
            hooks: context.observation.childHooks(),
            fetch: gateway([answer("child finished")]).fetch,
          });
          try {
            await drain(child.prompt("child input", { turnId: "child-turn" }));
          } finally {
            await child.close();
          }
          return "inputs handled";
        },
      },
    ],
  });
  try {
    await drain(engine.prompt("run", { turnId: "parent-turn" }));
    assert.equal(effects, 3);
    const starts = eventsOf(events, "wait.start");
    const ends = eventsOf(events, "wait.end");
    assert.deepEqual(
      starts.map((event) => event.data.kind),
      ["approval", "question", "question"],
    );
    assert.deepEqual(
      ends.map((event) => event.data.outcome),
      ["accepted", "denied", "failed"],
    );
    assert.equal(new Set(starts.map((event) => event.data.requestId)).size, 3);
    for (const event of starts) assert.equal(event.data.callId, "parent-call");
    const child = eventsOf(events, "turn.start").find((event) => event.turnId === "child-turn");
    assert.ok(child);
    assert.notEqual(child.sessionId, engine.sessionId);
    assert.equal(child.rootSessionId, engine.sessionId);
    assert.equal(child.parentSessionId, engine.sessionId);
    assert.equal(child.parentTurnId, "parent-turn");
    assert.equal(child.parentCallId, "parent-call");
  } finally {
    await engine.close();
  }
}

// MCP metadata is taken from the adapter's registered server and original tool,
// never guessed from its sanitized model name. Remote correlation is opt-in.
for (const propagateCorrelation of [false, true]) {
  const events = [];
  const remote = [];
  const adapter = await createMcpAdapter(
    {
      listTools: async () => ({
        tools: [{ name: "remote.echo", description: "Echo", inputSchema: { type: "object" } }],
      }),
      async callTool(params) {
        remote.push(params);
        return { content: [{ type: "text", text: "mcp result" }] };
      },
    },
    { prefix: "fixture_", serverName: "fixture-server", propagateCorrelation },
  );
  const modelTool = adapter.tools[0].name;
  const mock = gateway([
    [
      { type: "tool-call", toolCallId: "mcp-call", toolName: modelTool, input: {} },
      finish("tool-calls"),
    ],
    answer(),
  ]);
  const engine = await createFxEngine({
    ...base,
    fetch: mock.fetch,
    tools: adapter.tools,
    hooks: {
      onEvent: (event) => {
        events.push(event);
      },
    },
  });
  try {
    await drain(engine.prompt("call MCP"));
    const started = eventsOf(events, "mcp.start")[0];
    assert.equal(started.data.server, "fixture-server");
    assert.equal(started.data.tool, "remote.echo");
    assert.equal(started.data.callId, "mcp-call");
    const request = eventsOf(events, "mcp.request")[0];
    if (propagateCorrelation) {
      const token = remote[0]._meta["libfx/correlationId"];
      assert.match(token, /^[0-9a-f-]{36}$/);
      assert.ok(!token.includes(started.executionId));
      assert.ok(!token.includes("mcp-call"));
      assert.equal(remote[0]._meta.progressToken, undefined);
      assert.equal(request.data.requestIdKind, "correlation");
      assert.equal(request.data.requestId, token);
    } else {
      assert.equal(remote[0]._meta, undefined);
      assert.equal(request, undefined);
    }
    assert.equal(eventsOf(events, "mcp.end")[0].data.operationId, started.data.operationId);
    assert.equal(eventsOf(events, "mcp.end")[0].data.status, "success");
    assert.equal(remote.length, 1);
  } finally {
    await engine.close();
    await adapter.close();
  }
}

// A host-created child adds its outer parent only to its own root session.
// Descendant events already carry their native parent relationship.
{
  const events = [];
  const contexts = [];
  const promptStarted = Promise.withResolvers();
  let handler, exit, executeHostTool, promptMessage;
  const runtime = {
    exited: new Promise((resolve) => {
      exit = resolve;
    }),
    setLineHandler(value) {
      handler = value;
    },
    write(data) {
      const message = JSON.parse(data);
      if (message.method === "session/prompt") {
        promptMessage = message;
        promptStarted.resolve();
        return;
      }
      if (message.id !== undefined)
        queueMicrotask(() =>
          handler({
            id: message.id,
            result:
              message.method === "libfx/new"
                ? { sessionId: "child-root", _meta: { fx: { hooksVersion: 1 } } }
                : {},
          }),
        );
    },
    abortHostEffects() {},
    closeStdin() {
      exit(0);
    },
  };
  const outer = toolObservation(
    {
      sessionId: "outer",
      rootSessionId: "outer-root",
      turnId: "outer-turn",
      executionId: "outer-execution",
      stepIndex: 1,
    },
    "outer-call",
    {
      onEvent: (event) => {
        events.push(event);
      },
    },
    () => {},
    new AbortController().signal,
  );
  const engine = await createSharedEngine({
    apiKey: "fixture-key",
    runtimeFactory: (options) => {
      executeHostTool = options.hostToolExecutor;
      return runtime;
    },
    hooks: outer.childHooks(),
    tools: [
      {
        name: "lookup",
        description: "Lookup",
        inputSchema: { type: "object" },
        execute(_input, context) {
          contexts.push(context);
          return "ok";
        },
      },
    ],
  });
  try {
    const frame = {
      version: 1,
      type: "turn.start",
      sessionId: "child-root",
      rootSessionId: "child-root",
      parentSessionId: null,
      turnId: "child-turn",
      executionId: "child-execution",
      data: { resumed: false },
    };
    handler({ method: "libfx/hook", params: frame });
    handler({
      method: "libfx/hook",
      params: {
        ...frame,
        sessionId: "native-grandchild",
        parentSessionId: "native-child-parent",
        parentTurnId: "native-parent-turn",
        parentCallId: "native-parent-call",
      },
    });
    assert.equal(events[0].parentSessionId, "outer");
    assert.equal(events[0].parentCallId, "outer-call");
    assert.equal(events[1].rootSessionId, "outer-root");
    assert.equal(events[1].parentSessionId, "native-child-parent");
    assert.equal(events[1].parentTurnId, "native-parent-turn");
    assert.equal(events[1].parentCallId, "native-parent-call");
    const turn = engine.prompt("scope collision fixture");
    await promptStarted.promise;
    const emit = (overrides) =>
      handler({ method: "libfx/hook", params: { ...frame, ...overrides } });
    const call = { callId: "same", name: "lookup", provenance: "fx_local" };
    emit({ type: "tool.start", executionId: "root-scope", data: { call, rerun: false } });
    emit({
      type: "tool.start",
      sessionId: "native-grandchild",
      parentSessionId: "native-child-parent",
      executionId: "grandchild-scope",
      data: { call, rerun: false },
    });
    assert.equal(
      (await executeHostTool("lookup", {}, "native-grandchild", "same")).cancelled,
      true,
    );
    assert.equal(contexts.length, 0, "native descendant metadata cannot authorize a host tool");
    emit({
      type: "turn.end",
      sessionId: "native-grandchild",
      parentSessionId: "native-child-parent",
      executionId: "grandchild-scope",
      data: { outcome: "completed", error: null },
    });
    await executeHostTool("lookup", {}, "child-root", "same");
    assert.ok(contexts[0].observation, "ending a descendant must retain another execution's scope");
    assert.equal(contexts[0].sessionId, "child-root");
    assert.equal(contexts[0].observation.childHooks().parent.sessionId, "child-root");
    emit({
      type: "turn.end",
      executionId: "root-scope",
      data: { outcome: "completed", error: null },
    });
    await executeHostTool("lookup", {}, "child-root", "same");
    assert.equal(
      contexts[1].observation,
      undefined,
      "turn.end must remove scopes without tool.end",
    );
    emit({ type: "tool.start", executionId: "fenced-scope", data: { call, rerun: false } });
    emit({ type: "journal.error", data: { error: "Error", fenced: true } });
    await executeHostTool("lookup", {}, "child-root", "same");
    assert.equal(contexts[2].observation, undefined, "a fence must discard abandoned scopes");
    handler({ id: promptMessage.id, result: { stopReason: "end_turn", usage: {} } });
    await drain(turn);
  } finally {
    await engine.close();
  }
}

// Cancellation is an observation, not a replacement for the host's response.
// A late answer cannot emit a second terminal event or change the returned value.
{
  const events = [];
  const controller = new AbortController();
  const answer = Promise.withResolvers();
  const scope = {
    version: 1,
    sessionId: "fixture",
    rootSessionId: "fixture",
    parentSessionId: null,
    sourceSessionId: null,
    workId: null,
    turnId: "turn",
    executionId: "execution",
    stepIndex: 1,
  };
  const observer = toolObservation(
    scope,
    "call",
    { captureContent: true },
    (event) => events.push(event),
    controller.signal,
  );
  let calls = 0;
  const pending = observer.wait({ kind: "approval", prompt: "Approve?" }, () => {
    calls++;
    return answer.promise;
  });
  controller.abort();
  assert.equal(eventsOf(events, "wait.end")[0].data.outcome, "cancelled");
  const accepted = { outcome: "accepted", answers: ["late answer"] };
  answer.resolve(accepted);
  assert.equal(await pending, accepted);
  assert.equal(calls, 1);
  assert.equal(eventsOf(events, "wait.end").length, 1);
}

for (const hooks of [
  null,
  {},
  { onEvent: true },
  { onEvent() {}, captureContent: "yes" },
  { onEvent() {}, onError: true },
]) {
  await assert.rejects(createFxEngine({ ...base, hooks }), /hooks/);
}
console.log(
  `${backend} semantic hooks passed: model/tool boundaries, content, observer isolation, durable resume, and fencing`,
);
