import { describe, expect, test } from "bun:test";
import {
  applyVariant,
  extractToolCalls,
  isRemoteCommand,
  numberIn,
  parseStreamUsage,
  rootRequest,
  summarize,
  type RecordedRequest,
  type RunResult,
} from "./tool-schema-ab";

const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });

describe("tool schema A/B helpers", () => {
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
      ({ arm, pass, targetCalls, targetErrors: 0, allErrors: pass ? 0 : 1, offSchemaFields: [], inputTokens, outputTokens: 0, agentRequests: 2, toolsBytes: 100 }) as unknown as RunResult;
    const rows = summarize([run("A", true, 1, 100), run("A", false, 0, 300), run("B", true, 2, 50)], (r) => r.arm);
    expect(rows.A).toMatchObject({ runs: 2, pass: 1, allErrors: 1, missedTarget: 1, meanInputTokens: 200, meanRequests: 2 });
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
});
