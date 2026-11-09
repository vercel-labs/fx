import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  applyVariant,
  armKey,
  bodyOnlyVariant,
  callFailure,
  extractToolCalls,
  isRemoteCommand,
  numberIn,
  parseStreamUsage,
  rescoreResults,
  reusableRun,
  rootRequest,
  startProxy,
  summarize,
  transformStream,
  type RecordedRequest,
  type RunResult,
  type Task,
} from "./tool-schema-ab";

const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });

describe("tool schema A/B helpers", () => {
  test("a failed call is a rejection unless a shell command ran and exited nonzero", () => {
    const call = (name: string, error: boolean, resultText: string) =>
      ({ id: "c", name, input: {}, inputRaw: "{}", providerExecuted: false, resultType: error ? "error-json" : "json", resultText, error });
    expect(callFailure(call("shell", true, '{"state":"completed","exit_code":1}'))).toBe("exited");
    expect(callFailure(call("shell", true, '{"error":{"code":"invalid_shell_request","executed":false}}'))).toBe("rejected");
    expect(callFailure(call("subagent", true, '{"ok":false,"result":"message needs agent and message."}'))).toBe("rejected");
    expect(callFailure(call("shell", false, '{"state":"completed","exit_code":0}'))).toBe(null);
    // A command that started counts as run even when it timed out or lost its process.
    expect(callFailure(call("shell", true, '{"state":"stopped","timed_out":true,"duration_ms":120000}'))).toBe("exited");
    expect(callFailure(call("shell", true, '{"state":"lost","duration_ms":5}'))).toBe("exited");
    expect(callFailure(call("shell", true, "shell run cwd is invalid: FileNotFound"))).toBe("rejected");
  });

  test("a transform that throws fails the stream and reports why", async () => {
    const errors: string[] = [];
    const source = new Response('data: {"type":"text-delta"}\ndata: [DONE]\n').body!;
    const rewritten = source.pipeThrough(
      transformStream({ event: () => { throw new Error("bad part"); } }, "m", (message) => errors.push(message)),
    );
    await expect(new Response(rewritten).text()).rejects.toThrow("bad part");
    expect(errors).toEqual(["event() threw: Error: bad part"]);

    const passthrough = new Response("data: [DONE]\n").body!.pipeThrough(transformStream({ event: (part) => part }, "m"));
    expect(await new Response(passthrough).text()).toBe("data: [DONE]\n");
  });

  test("a stream split inside a line and inside a character is rewritten whole", async () => {
    const bytes = new TextEncoder().encode('data: {"delta":"café"}\ndata: {"delta":"ok"}\n');
    const cut = [9, bytes.indexOf(0xc3) + 1, bytes.length - 3];
    const source = new ReadableStream<Uint8Array>({
      start(controller) {
        let from = 0;
        for (const to of [...cut, bytes.length]) {
          controller.enqueue(bytes.slice(from, to));
          from = to;
        }
        controller.close();
      },
    });
    const upper = { event: (part: Record<string, unknown>) => ({ delta: String(part.delta).toUpperCase() }) };
    expect(await new Response(source.pipeThrough(transformStream(upper, "m"))).text()).toBe('data: {"delta":"CAFÉ"}\ndata: {"delta":"OK"}\n');
  });

  test("a variant replaces only the named function tools and text in system messages", () => {
    const body: Record<string, unknown> = {
      tools: [
        { type: "function", name: "read_file", description: "old", inputSchema: { type: "object" } },
        { type: "function", name: "shell", description: "keep" },
        { type: "provider", name: "read_file", id: "gateway.search" },
      ],
      prompt: [
        { role: "system", content: "guidance" },
        { role: "system", content: "rules, then guidance, then guidance" },
        { role: "system", content: "other rules" },
        user("guidance"),
      ],
    };
    applyVariant(body, {
      tools: { read_file: { description: "new" } },
      system: [{ from: "guidance", to: "short" }],
    });
    expect(body.tools).toEqual([
      { type: "function", name: "read_file", description: "new", inputSchema: { type: "object" } },
      { type: "function", name: "shell", description: "keep" },
      { type: "provider", name: "read_file", id: "gateway.search" },
    ]);
    expect(body.prompt).toEqual([
      { role: "system", content: "short" },
      { role: "system", content: "rules, then short, then guidance" },
      { role: "system", content: "other rules" },
      user("guidance"),
    ]);
  });

  test("stream usage comes from the last finish part in either token shape", () => {
    const stream = [
      'data: {"type":"text-delta","delta":"finish"}',
      'data: {"type":"finish","usage":{"inputTokens":10,"outputTokens":2}}',
      'data: {"type":"finish","usage":{"inputTokens":{"total":50,"cacheRead":40,"cacheWrite":5},"outputTokens":{"total":7}}}',
      "data: [DONE]",
    ].join("\n");
    expect(parseStreamUsage(stream)).toEqual({ input: 50, cacheRead: 40, cacheWrite: 5, output: 7 });
    expect(parseStreamUsage('data: {"type":"text-delta"}')).toBeNull();
  });

  test("tool calls pair with their results and error outputs count as errors", () => {
    const calls = extractToolCalls([
      user("go"),
      {
        role: "assistant",
        content: [
          { type: "tool-call", toolCallId: "a", toolName: "shell", input: '{"action":"run","command":"ls"}' },
          { type: "tool-call", toolCallId: "b", toolName: "read_file", input: "{not json" },
        ],
      },
      {
        role: "tool",
        content: [
          { type: "tool-result", toolCallId: "a", output: { type: "text", value: "README.md" } },
          { type: "tool-result", toolCallId: "b", output: { type: "error-text", value: "bad input" } },
          { type: "tool-result", toolCallId: "unknown", output: { type: "text", value: "ignored" } },
        ],
      },
    ]);
    expect(calls.map((c) => [c.name, c.input, c.resultText, c.error])).toEqual([
      ["shell", { action: "run", command: "ls" }, "README.md", false],
      ["read_file", null, "bad input", true],
    ]);
  });

  test("the root request is the last agent request whose user turn is the task", () => {
    const request = (seq: number, agent: boolean, text: string): RecordedRequest => ({
      seq,
      agent,
      toolsHash: null,
      toolsBytes: 0,
      toolProps: {},
      prompt: [user(text)],
      usage: null,
      providerSearch: false,
      status: 200,
    });
    const requests = [request(1, true, "the task"), request(2, true, "a subagent task"), request(3, true, "the task"), request(4, false, "the task")];
    expect(rootRequest(requests, "the task")?.seq).toBe(3);
    expect(rootRequest(requests, "missing")).toBeNull();
  });

  test("a summary counts passes, errors, and missed target tools per group", () => {
    const run = (arm: string, pass: boolean, targetCalls: number, inputTokens: number) =>
      ({ arm, pass, targetCalls, targetErrors: 0, allErrors: pass ? 0 : 1, offSchemaFields: [], inputTokens, cacheReadTokens: inputTokens / 2, cacheWriteTokens: inputTokens / 4, outputTokens: 0, agentRequests: 2, toolsBytes: 100 }) as unknown as RunResult;
    const rows = summarize([run("A", true, 1, 100), run("A", false, 0, 300), run("B", true, 2, 50)], (r) => r.arm);
    expect(rows.A).toMatchObject({ runs: 2, pass: 1, allErrors: 1, missedTarget: 1, meanInputTokens: 200, meanCacheReadTokens: 100, meanCacheWriteTokens: 50, meanRequests: 2 });
    expect(rows.B).toMatchObject({ runs: 1, pass: 1, missedTarget: 0, meanInputTokens: 50 });
  });

  test("a number matches only as a whole number", () => {
    expect(numberIn("The answer is 42.", 42)).toBe(true);
    expect(numberIn("42", 42)).toBe(true);
    expect(numberIn("142 lines", 42)).toBe(false);
    expect(numberIn("42.5", 42)).toBe(false);
    expect(numberIn("1.42", 42)).toBe(false);
  });

  test("only commands that reach the network count as remote", () => {
    for (const command of ["gh pr list -R vercel/next.js", "curl -s https://api.github.com", "git fetch origin", "ls -la && git ls-remote origin", "cd x; wget https://example.com"]) {
      expect(isRemoteCommand(command)).toBe(true);
    }
    for (const command of ["ls -la && git log --oneline -5", "pwd; git status --short", "git log origin/main", "find . -name '*.md'", "grep -rn curl src"]) {
      expect(isRemoteCommand(command)).toBe(false);
    }
  });

  test("rescore keeps a run whose transform failed marked failed", () => {
    const task = { id: "t", tool: "read_file", check: () => ({ pass: true, reason: "ok" }) } as unknown as Task;
    const run = (transformErrors: string[]) =>
      ({ task: "t", pass: false, reason: "before", output: "", calls: [], stderrTail: "", transformErrors }) as unknown as RunResult;
    const results = [run(["request() failed: Error: boom"]), run([])];
    expect(rescoreResults(results, new Set(["t"]), [task])).toBe(1);
    expect(results[0]).toMatchObject({ pass: false, reason: "before" });
    expect(results[1]).toMatchObject({ pass: true, reason: "ok" });
  });

  test("the proxy answers 501 to a failed request transform and to every request after it", async () => {
    const proxy = startProxy({}, "key", { request: () => { throw new Error("boom"); } });
    const agentBody = JSON.stringify({ tools: [{ type: "function", name: "read_file", inputSchema: {} }], prompt: [] });
    const send = (body?: string) =>
      fetch(`${proxy.url}/v1/ai/language-model`, { method: body ? "POST" : "GET", headers: { authorization: "Bearer key" }, body });
    const first = await send(agentBody);
    expect(first.status).toBe(501);
    expect(await first.text()).toContain("request() failed: Error: boom");
    const later = await send();
    expect(later.status).toBe(501);
    expect(proxy.transformErrors).toEqual(["request() failed: Error: boom"]);
    await proxy.stop();
  });

  test("an arm key changes when the binary, the variant, or its transform changes", () => {
    const dir = mkdtempSync(join(tmpdir(), "fx-arm-key-"));
    try {
      const bin = join(dir, "fx");
      writeFileSync(bin, "build one");
      writeFileSync(join(dir, "t.ts"), "export function request() {}\n");
      const arm = { bin, variant: {}, variantPath: "none" };
      const plain = armKey(arm);
      expect(armKey(arm)).toBe(plain);
      const withTransform = { bin, variant: { transform: "./t.ts" }, variantPath: join(dir, "v.json") };
      const transformed = armKey(withTransform);
      expect(transformed).not.toBe(plain);
      writeFileSync(join(dir, "t.ts"), "export function request() { return; }\n");
      expect(armKey(withTransform)).not.toBe(transformed);
      writeFileSync(bin, "build two");
      expect(armKey(arm)).not.toBe(plain);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("resume reuses only a run with the same arm key and names each run it drops", () => {
    const lines: string[] = [];
    const log = (line: string) => lines.push(line);
    const stored = (key?: string) => ({ task: "t", armKey: key }) as unknown as RunResult;
    const same = stored("abc");
    expect(reusableRun(same, "abc", "a.json", log)).toBe(same);
    expect(reusableRun(stored("old"), "abc", "b.json", log)).toBeNull();
    expect(reusableRun(stored(), "abc", "c.json", log)).toBeNull();
    expect(lines).toEqual([
      "resume: rerunning b.json; it ran with arm key old, not abc",
      "resume: rerunning c.json; it ran with arm key none, not abc",
    ]);
  });

  test("tokens and probe refuse a variant that names a transform", () => {
    const dir = mkdtempSync(join(tmpdir(), "fx-body-variant-"));
    try {
      const path = join(dir, "v.json");
      writeFileSync(path, JSON.stringify({ transform: "./t.ts" }));
      expect(() => bodyOnlyVariant(path, "probe")).toThrow("probe runs no transform");
      expect(bodyOnlyVariant("none", "tokens")).toEqual({});
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
