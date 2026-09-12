import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { completion, toolCompletion, createConfiguredProviderFixture as fixture } from "./fixtures/chat-completions";

describe("configured providers", () => {
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
    const f = fixture(body => {
      if (body.messages.some((message: any) => message.role === "user" && message.content?.includes("child-marker"))) return completion(body.model, "child reply");
      if (body.messages.some((message: any) => message.role === "tool")) return completion(body.model, "parent reply");
      return toolCompletion(body.model, "subagent", { request: { action: "run", task: "child-marker", ...(mode === "inherited" ? {} : { model: childModel }) } });
    });
    f.settings.providers.local.model_metadata["local-model"].max_output_tokens = 512;
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 1024, supports_tool_use: true };
    f.save();
    try {
      const result = await runFx(["ask", "--json", "Delegate a task"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("parent reply");
      expect(f.requests).toHaveLength(3);
      expect(f.requests.map(request => request.body.model)).toEqual(["local-model", childModel, "local-model"]);
      expect(f.requests.map(request => request.body.max_tokens)).toEqual([512, mode === "unknown" ? undefined : mode === "override" ? 1024 : 512, 512]);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 35000);

  test("persistent child capabilities stay bound when the parent changes providers", async () => {
    let callId = 0;
    const f = fixture(body => {
      if (!body.tools?.some((tool: any) => tool.function?.name === "subagent")) return completion(body.model, "child reply");
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
      expect(f.requests.map(request => request.body.max_tokens)).toEqual([1024, 1024, 1024]);
      const resumed = await runFx(["ask", "--json", "--resume", id, "Continue the named child"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      const resumedResult = f.requests.at(-1)!.body.messages.at(-1).content;
      if (!JSON.parse(resumedResult).ok) throw new Error(resumedResult);
      expect(f.requests.map(request => request.body.max_tokens)).toEqual([1024, 1024, 1024, 512, 1024, 512]);
      expect(f.requests[3].authorization).toBeNull();
      expect(f.requests[4].authorization).toBe(`Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`);
      expect(f.requests[5].authorization).toBeNull();
      f.settings.providers.remote.base_url += "/changed";
      f.save();
      const rebound = await runFx(["ask", "--json", "--resume", id, "Continue the named child again"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (rebound.code !== 0) throw new Error(rebound.stdout + rebound.stderr);
      expect(f.requests).toHaveLength(8);
      expect(f.requests.slice(6).every(request => request.authorization === null && request.path === "/v1/chat/completions")).toBe(true);
      expect(f.requests[7].body.messages.at(-1).content).toContain("child_failed");
    } finally { f.close(); }
  }, 100000);

  test("configured child compaction uses the model capability lookup", async () => {
    let parentTurns = 0;
    let summaries = 0;
    const f = fixture(body => {
      if (body.model === "child-model") {
        if (!body.tools?.length) {
          summaries++;
          return completion(body.model, "The child is retaining repeated context details and should continue acknowledging them.");
        }
        return completion(body.model, "child reply", Math.ceil(JSON.stringify(body).length / 4));
      }
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      parentTurns++;
      return toolCompletion(body.model, "subagent", { request: { action: "message", agent: "reader", message: `child context ${parentTurns} ` + "detail ".repeat(2000), ...(parentTurns === 1 ? { model: "child-model" } : {}) } }, `context-call-${parentTurns}`);
    });
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 512, supports_tool_use: true };
    f.save();
    let id: string | undefined;
    try {
      for (let turn = 0; turn < 12; turn++) {
        const result = await runFx(["ask", "--json", ...(id ? ["--resume", id] : []), "Continue the child context"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
        if (result.code !== 0) throw new Error(result.stdout + result.stderr);
        id = JSON.parse(result.stdout).session_id;
        const returned = f.requests.filter(request => request.body.model === "local-model").at(-1)!.body.messages.at(-1).content;
        if (!JSON.parse(returned).ok) throw new Error(returned);
        expect(JSON.parse(returned).ok).toBe(true);
      }
      expect(summaries).toBeGreaterThan(0);
      const childRequests = f.requests.filter(request => request.body.model === "child-model");
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

  test.each(["caution", "invalid"])("%s custom permission reviews never authorize execution", async decision => {
    let marker = "";
    const f = fixture(body => {
      if (body.tools?.some((tool: any) => tool.function?.name === "permission_decision")) return toolCompletion(body.model, "permission_decision", { decision, rationale: "fixture review" });
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
