import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const { fakeGatewayFinalText, startDynamicFakeGateway } = await import("./tmux-helpers");
const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const cli = resolve(import.meta.dir, "../../examples/jev-routing/src/cli.mjs");

const candidates = ["moonshotai/kimi-k3", "openai/gpt-5.6-luna", "openai/gpt-5.6-sol"];

function nativeFixture(completion: (body: string) => Response, classify: (body: any, index: number) => string | Response) {
  const root = mkdtempSync(join(tmpdir(), "fx-native-jev-"));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true }); mkdirSync(cwd);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ auto_upgrade: false, fast_mode: false }));
  const gateway = startDynamicFakeGateway(completion, { models: candidates.map(id => ({
    id, type: "language", tags: ["tool-use"], context_window: 1_050_000, max_tokens: 8192,
  })) });
  const evaluations: any[] = [];
  const evaluationHeaders: Headers[] = [];
  const evaluator = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    expect(request.headers.get("ai-model-id")).toBe("typesafe-ai/jev");
    const body = await request.json() as any;
    evaluations.push(body);
    evaluationHeaders.push(request.headers);
    const taskClass = classify(body, evaluations.length - 1);
    if (taskClass instanceof Response) return taskClass;
    const selected: Record<string, string> = { family: "code-generation", taskClass };
    return Response.json({ answers: Object.fromEntries(Object.entries(body.questions).map(([key, question]: [string, any]) => [
      key, { type: "choice", choice: selected[key], probabilities: Object.fromEntries(Object.keys(question.criteria).map(label => [label, Number(label === selected[key])])) },
    ])), usage: { inputTokens: 123, outputTokens: 4 } });
  }});
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-jev-native", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_FAST_MODE: "0", FX_MODEL: "jev/auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
    FX_E2E_JEV_URL: "http://127.0.0.1:" + evaluator.port + "/evaluate",
    FX_TRACE_LOG: join(root, "trace.log"), FX_TRACE_SCOPES: "quality,agent,subagent",
  };
  return { root, home, cwd, gateway, evaluations, evaluationHeaders, env,
    async ask(prompt: string, args: string[] = [], extra: Record<string, string> = {}) {
      const child = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-fast", ...args, "--", prompt], {
        cwd, env: { ...env, ...extra }, stdin: "ignore", stdout: "pipe", stderr: "pipe",
      });
      const timeout = setTimeout(() => child.kill("SIGKILL"), 35_000);
      try {
        const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
        // These are intentional CLI notices/progress, not diagnostics.
        const diagnostics = stderr.split("\n").filter(line => line &&
          !line.startsWith("Full access enabled:") && !line.startsWith("[notice] Jev selected ") &&
          !line.includes(" working · ") && !line.startsWith("Running ") && !line.startsWith("Executing "));
        if (code !== 0 || diagnostics.length) throw new Error("exit=" + code + "\n" + stdout + "\n" + stderr + "\nevidence=" + root);
        return JSON.parse(stdout);
      } finally { clearTimeout(timeout); }
    },
    close(passed: boolean) {
      gateway.stop(); evaluator.stop(true);
      if (passed) rmSync(root, { recursive: true, force: true });
      else console.error("Native Jev evidence: " + root);
    },
  };
}

test("native Jev routes follow-up prompts with history and preserves explicit choices", async () => {
  const f = nativeFixture(() => fakeGatewayFinalText("NATIVE_ROUTE_REPLY"), (_, i) => i === 0 ? "routine" : "demanding");
  let passed = false;
  try {
    const first = await f.ask("Implement the small formatting change.");
    const second = await f.ask("Now investigate its concurrency failure.", ["--resume-id", first.session_id]);
    const third = await f.ask("Do it.", ["--resume-id", first.session_id, "--model", candidates[0]]);
    expect(first.model).toBe(candidates[1]); expect(second.model).toBe(candidates[2]); expect(third.model).toBe(candidates[0]);
    expect(f.evaluations).toHaveLength(2);
    expect(f.evaluations[1].state).toContain("Implement the small formatting change.");
    expect(f.evaluations[1].state).toContain("Now investigate its concurrency failure.");
    expect(f.gateway.requests.map(r => r.headers.get("ai-language-model-id"))).toEqual([candidates[1], candidates[2], candidates[0]]);
    expect(f.gateway.requests[1].body).toContain("NATIVE_ROUTE_REPLY");
    passed = true;
  } finally { f.close(passed); }
}, 90_000);

test("native Jev keeps a dedicated evaluation key separate from inference", async () => {
  const f = nativeFixture(() => fakeGatewayFinalText("SPLIT_KEYS_REPLY"), () => "routine");
  let passed = false;
  try {
    const result = await f.ask("Implement a small helper.", [], {
      FX_JEV_GATEWAY_API_KEY: "synthetic-evaluation-only", FX_JEV_GATEWAY_TEAM: "personal-evaluation-team",
    });
    expect(result.model).toBe(candidates[1]);
    expect(f.evaluationHeaders.map(h => h.get("authorization"))).toEqual(["Bearer synthetic-evaluation-only"]);
    expect(f.evaluationHeaders[0].get("x-vercel-ai-gateway-team")).toBe("personal-evaluation-team");
    expect(f.gateway.requests.every(r => r.headers.get("authorization") === "Bearer synthetic-jev-native")).toBe(true);
    expect(f.gateway.requests.every(r => r.headers.get("x-vercel-ai-gateway-team") !== "personal-evaluation-team")).toBe(true);
    expect(readFileSync(f.env.FX_TRACE_LOG, "utf8")).not.toContain("synthetic-evaluation-only");
    const fallback = await f.ask("Implement another helper.", [], { FX_JEV_GATEWAY_API_KEY: "" });
    expect(fallback.model).toBe(candidates[0]);
    expect(f.evaluationHeaders).toHaveLength(1);
    passed = true;
  } finally { f.close(passed); }
}, 45_000);

test("native Jev evaluator failure retains an eligible fallback and records overhead", async () => {
  const f = nativeFixture(() => fakeGatewayFinalText("FALLBACK_REPLY"), () => new Response("private provider error", { status: 403 }));
  let passed = false;
  try {
    const result = await f.ask("Implement a helper.");
    expect(result.model).toBe(candidates[0]);
    expect(result.output).toBe("FALLBACK_REPLY");
    expect(f.evaluations).toHaveLength(1);
    const trace = readFileSync(f.env.FX_TRACE_LOG, "utf8");
    expect(trace).toContain('"reason":"evaluation_failed"');
    expect(trace).toContain('"billing_complete":false');
    expect(trace).not.toContain("private provider error");
    passed = true;
  } finally { f.close(passed); }
}, 45_000);

test("native Jev resumed uncertainty keeps the last selected eligible model", async () => {
  const f = nativeFixture(() => fakeGatewayFinalText("CONTINUITY_REPLY"), (_, i) => i === 0 ? "demanding" : new Response("unavailable", { status: 503 }));
  let passed = false;
  try {
    const first = await f.ask("Diagnose a difficult synchronization bug.");
    const next = await f.ask("Continue with that.", ["--resume-id", first.session_id]);
    expect(first.model).toBe(candidates[2]);
    expect(next.model).toBe(candidates[2]);
    expect(f.evaluations).toHaveLength(2);
    passed = true;
  } finally { f.close(passed); }
}, 45_000);

for (const parentAuto of [false, true]) test(`native Jev routes persistent child assignments independently (parentAuto=${parentAuto})`, async () => {
  const { fakeGatewayToolCall, fakeShellRun } = await import("./tmux-helpers");
  let parentCalls = 0;
  const childModels: string[] = [];
  const f = nativeFixture(body => {
    const isChild = !body.includes('"name":"subagent"');
    if (isChild) {
      childModels.push(f.gateway.requests.at(-1)!.headers.get("ai-language-model-id")!);
      if (body.includes('"toolCallId":"child-check"')) return fakeGatewayFinalText("CHILD_DONE");
      return fakeShellRun("child-check", "printf 'checked'");
    }
    parentCalls++;
    if (parentCalls === 1) return fakeGatewayToolCall("delegate-first", "subagent", { request: { action: "message", agent: "worker", message: "SMALL_CHILD: format a string." } });
    if (parentCalls === 2) return fakeGatewayToolCall("delegate-second", "subagent", { request: { action: "message", agent: "worker", message: "HARD_CHILD: investigate a deadlock." } });
    return fakeGatewayFinalText("PARENT_DONE");
  }, body => body.state.includes("ORIGIN: root") ? "general" : body.state.split("ORIGIN:")[0].includes("HARD_CHILD") ? "demanding" : "routine");
  let passed = false;
  try {
    const result = await f.ask("Delegate the two child assignments.", parentAuto ? [] : ["--model", candidates[0]], { FX_EXPERIMENT_JEV_SUBAGENT_ROUTING: "1", FX_JEV_GATEWAY_API_KEY: "synthetic-child-evaluation" });
    expect(result.output).toBe("PARENT_DONE");
    expect(f.evaluations).toHaveLength(parentAuto ? 3 : 2);
    const childEvaluations = f.evaluations.filter(e => e.state.includes("ORIGIN: subagent"));
    expect(childEvaluations).toHaveLength(2);
    expect(f.evaluationHeaders.every(h => h.get("authorization") === "Bearer synthetic-child-evaluation")).toBe(true);
    expect(f.gateway.requests.every(r => r.headers.get("authorization") === "Bearer synthetic-jev-native")).toBe(true);
    expect(childEvaluations[1].state).toContain("SMALL_CHILD");
    expect(childModels[0]).toBe(candidates[1]);
    expect(childModels[1]).toBe(candidates[1]);
    expect(childModels.at(-1)).toBe(candidates[2]);
    expect(f.gateway.requests.filter(r => r.body.includes('"name":"subagent"')).every(r => r.headers.get("ai-language-model-id") === candidates[0])).toBe(true);
    passed = true;
  } finally { f.close(passed); }
}, 90_000);

test("native Jev child switch preserves a child's explicit model override", async () => {
  const { fakeGatewayToolCall } = await import("./tmux-helpers");
  let parentCalls = 0;
  const f = nativeFixture(body => {
    if (!body.includes('"name":"subagent"')) return fakeGatewayFinalText("PINNED_CHILD_DONE");
    if (++parentCalls > 1) return fakeGatewayFinalText("PARENT_DONE");
    return fakeGatewayToolCall("explicit-child", "subagent", { request: { action: "run", task: "Do a simple edit.", model: candidates[2] } });
  }, () => { throw new Error("An explicit model must bypass Jev"); });
  let passed = false;
  try {
    await f.ask("Delegate one child.", ["--model", candidates[0]], { FX_EXPERIMENT_JEV_SUBAGENT_ROUTING: "1" });
    expect(f.evaluations).toHaveLength(0);
    expect(f.gateway.requests.map(r => r.headers.get("ai-language-model-id"))).toEqual([candidates[0], candidates[2], candidates[0]]);
    passed = true;
  } finally { f.close(passed); }
}, 45_000);

const { TmuxSession, tmuxAvailable } = await import("./tmux-helpers");
test.skipIf(!tmuxAvailable())("native Jev interactive prompts reroute without losing the conversation", async () => {
  let completions = 0;
  const f = nativeFixture(() => fakeGatewayFinalText("TTY_ROUTED_" + ++completions), (_, i) => i === 0 ? "routine" : "demanding");
  let tui: InstanceType<typeof TmuxSession> | undefined, passed = false;
  const stderrPath = join(f.root, "tty-stderr.txt");
  try {
    tui = await TmuxSession.create({ cmd: binary + " --no-fast", cwd: f.cwd, env: f.env, stderrPath, isolated: true });
    await tui.waitForComposer(20_000);
    await tui.sendText("Plan the change to the scheduler.");
    await tui.waitForText("TTY_ROUTED_1", 20_000);
    await tui.waitForComposer(20_000);
    await tui.sendText("Do it.");
    await tui.waitForText("TTY_ROUTED_2", 20_000);
    await tui.waitForComposer(20_000);
    expect(f.evaluations).toHaveLength(2);
    expect(f.evaluations[1].state).toContain("Do it.");
    expect(f.evaluations[1].state).toContain("Plan the change to the scheduler.");
    expect(f.gateway.requests.map(r => r.headers.get("ai-language-model-id"))).toEqual([candidates[1], candidates[2]]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    passed = true;
  } finally { await tui?.kill(); f.close(passed); }
}, 70_000);

test("native Jev ACP prompts share routing and respect a later model pin", async () => {
  const { spawn } = await import("node:child_process");
  const f = nativeFixture(() => fakeGatewayFinalText("ACP_ROUTED"), (_, i) => i === 0 ? "routine" : "demanding");
  const child = spawn(binary, ["acp", "--model", "jev/auto"], { cwd: f.cwd, env: f.env, stdio: ["pipe", "pipe", "pipe"] });
  let buffer = "", stderr = "", passed = false, id = 0;
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  child.stdout.on("data", chunk => {
    buffer += chunk.toString();
    const lines = buffer.split("\n"); buffer = lines.pop()!;
    for (const line of lines) if (line.trim()) {
      const message = JSON.parse(line);
      const waiter = pending.get(message.id);
      if (waiter) { pending.delete(message.id); message.error ? waiter.reject(new Error(JSON.stringify(message.error))) : waiter.resolve(message.result); }
    }
  });
  child.stderr.on("data", chunk => { stderr += chunk; });
  async function rpc(method: string, params: any) {
    const requestId = ++id;
    return await new Promise<any>((resolve, reject) => {
      const timeout = setTimeout(() => { pending.delete(requestId); reject(new Error("ACP timeout: " + method + "\n" + stderr)); }, 20_000);
      pending.set(requestId, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); } });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: requestId, method, params }) + "\n");
    });
  }
  try {
    await rpc("initialize", { protocolVersion: 1, clientCapabilities: {} });
    const session = await rpc("session/new", { cwd: f.cwd, mcpServers: [] });
    const sessionId = session.sessionId;
    for (const text of ["Plan a narrow edit.", "Do it."]) {
      await rpc("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
    }
    await rpc("session/set_config_option", { sessionId, configId: "model", value: candidates[0] });
    await rpc("session/prompt", { sessionId, prompt: [{ type: "text", text: "Explain the result." }] });
    expect(f.evaluations).toHaveLength(2);
    expect(f.evaluations[1].state).toContain("Plan a narrow edit.");
    expect(f.gateway.requests.map(r => r.headers.get("ai-language-model-id"))).toEqual([candidates[1], candidates[2], candidates[0]]);
    expect(stderr).toBe("");
    passed = true;
  } finally {
    child.kill("SIGTERM");
    await new Promise<void>(resolve => child.once("close", () => resolve()));
    f.close(passed);
  }
}, 70_000);

test("Jev routing launcher selects a model and runs the built fx binary", async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-jev-routing-"));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true }); mkdirSync(cwd);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ auto_upgrade: false }));
  const selected = "openai/gpt-5.6-luna", bodies: string[] = [];
  const gateway = startDynamicFakeGateway(body => {
    bodies.push(body);
    return fakeGatewayFinalText("ROUTED_MODEL_REPLIED");
  }, { models: [{ id: selected, type: "language", tags: ["tool-use"], context_window: 1050000, max_tokens: 8192 }] });
  const trace = join(root, "decision.json"), evaluation = join(root, "evaluation.json");
  const preload = join(root, "evaluation-fixture.mjs");
  // The production client keeps its fixed URL. This process-local fixture
  // replaces fetch, so this deterministic test cannot call a real evaluator.
  writeFileSync(preload, `import { writeFileSync } from 'node:fs';
globalThis.fetch = async (url, options) => {
  if (url !== 'https://ai-gateway.vercel.sh/v4/ai/evaluation-model') throw new Error('Unexpected evaluation URL');
  const body = JSON.parse(options.body);
  writeFileSync(${JSON.stringify(evaluation)}, JSON.stringify(body));
  const choices = {family: 'code-generation', taskClass: 'routine'};
  return Response.json({answers: Object.fromEntries(Object.entries(body.questions).map(([key, question]) => [key, {
    type:'choice', choice:choices[key], probabilities:Object.fromEntries(Object.keys(question.criteria).map(label => [label, Number(label === choices[key])]))
  }])), usage:{inputTokens:100,outputTokens:1}});
};\n`);
  let passed = false;
  try {
    const prompt = "Create a small function that returns the sum of two integers.";
    const input = join(root, "prompt.txt"); writeFileSync(input, prompt);
    const child = Bun.spawn(["node", "--import", preload, cli, "run-fx", "--binary", binary, "--prompt-file", input, "--trace", trace], {
      cwd, env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
        AI_GATEWAY_API_KEY: "synthetic-jev-routing", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
        FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      }, stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timeout = setTimeout(() => child.kill("SIGKILL"), 30_000);
    try {
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(0); expect(stderr).toBe("");
      expect(JSON.parse(stdout).output).toBe("ROUTED_MODEL_REPLIED");
      const decision = JSON.parse(readFileSync(trace, "utf8"));
      expect(decision.model).toBe(selected);
      expect(decision.error).toBeNull();
      expect(decision.reason).toBe("family_code-generation_task_routine");
      expect(JSON.parse(readFileSync(evaluation, "utf8")).state).toBe(prompt);
      expect(bodies).toHaveLength(1);
      expect(JSON.parse(stdout).model).toBe(selected);
      expect(bodies[0]).toContain(prompt);
      passed = true;
    } finally { clearTimeout(timeout); }
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else console.error(`Jev routing evidence: ${root}`);
  }
}, 45_000);
