// Tests for the scripted fake stdio server.
//
//   bun test ./tests/tla/drivers/mcp/fakes/stdio.test.ts

import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Rule } from "./stdio";

const SERVER = join(import.meta.dir, "stdio.ts");
let dirs: string[] = [];

afterEach(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
  dirs = [];
});

async function exchange(rules: Rule[], lines: string[], flags: string[] = []) {
  const dir = mkdtempSync(join(tmpdir(), "mcpv2-fake-stdio-"));
  dirs.push(dir);
  const script = join(dir, "rules.json");
  const log = join(dir, "log.jsonl");
  writeFileSync(script, JSON.stringify(rules));
  const proc = Bun.spawn([process.execPath, SERVER, "--script", script, "--log", log, ...flags], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  for (const line of lines) proc.stdin.write(line + "\n");
  proc.stdin.end();
  const exit = await proc.exited;
  const parse = (l: string) => {
    try {
      return JSON.parse(l);
    } catch {
      return l; // deliberately malformed output from a `raw` rule
    }
  };
  const out = (await new Response(proc.stdout).text()).split("\n").filter(Boolean).map(parse);
  const logged = readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return { exit, out, logged };
}

const request = (id: number, method: string) => JSON.stringify({ jsonrpc: "2.0", id, method, params: {} });

test("answers a matching request with the scripted result and copies the id", async () => {
  const { exit, out } = await exchange([{ method: "server/discover", result: { supportedVersions: ["2026-07-28"] } }], [request(7, "server/discover")]);
  expect(exit).toBe(0);
  expect(out).toEqual([{ jsonrpc: "2.0", id: 7, result: { supportedVersions: ["2026-07-28"] } }]);
});

test("answers an unmatched request with -32601 and ignores notifications", async () => {
  const { out } = await exchange([], [request(1, "tools/list"), JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })]);
  expect(out).toEqual([{ jsonrpc: "2.0", id: 1, error: { code: -32601, message: "Method not found" } }]);
});

test("rules with a use limit fall through to the next matching rule", async () => {
  const rules: Rule[] = [
    { method: "tools/list", times: 1, error: { code: -32022, message: "Unsupported protocol version", data: { supported: ["2025-11-25"] } } },
    { method: "tools/list", result: { tools: [] } },
  ];
  const { out } = await exchange(rules, [request(1, "tools/list"), request(2, "tools/list")]);
  expect(out[0].error.code).toBe(-32022);
  expect(out[1]).toEqual({ jsonrpc: "2.0", id: 2, result: { tools: [] } });
});

test("can send notifications before the reply, raw malformed lines, and crash", async () => {
  const rules: Rule[] = [
    { method: "tools/call", times: 1, before: [{ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 1, progress: 1 } }], result: { content: [] } },
    { method: "tools/call", raw: "{not json", then: "crash" },
  ];
  const proc = await exchange(rules, [request(1, "tools/call"), request(2, "tools/call"), request(3, "tools/call")]);
  expect(proc.exit).toBe(1);
  expect(proc.out[proc.out.length - 1]).toBe("{not json");
  const lines = proc.logged.filter((l) => l.dir === "out").map((l) => l.line);
  expect(lines).toEqual([
    JSON.stringify({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 1, progress: 1 } }),
    JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content: [] } }),
    "{not json",
  ]);
  expect(proc.logged.filter((l) => l.dir === "in").length).toBeGreaterThanOrEqual(2);
});

test("rules can match the request's 2026 protocol version, or its absence", async () => {
  const rules: Rule[] = [
    { method: "tools/list", version: "2026-07-28", result: { era: "modern" } },
    { method: "tools/list", version: null, result: { era: "legacy" } },
  ];
  const modern = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } });
  const other = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2027-01-01" } } });
  const { out } = await exchange(rules, [modern, request(3, "tools/list"), other]);
  expect(out.map((m: { id: number; result?: { era: string }; error?: { code: number } }) => [m.id, m.result?.era ?? m.error?.code])).toEqual([
    [1, "modern"],
    [3, "legacy"],
    [2, -32601],
  ]);
});

test("--start-delay holds input until the delay passes", async () => {
  const started = Date.now();
  const { out } = await exchange([{ method: "ping", result: {} }], [request(1, "ping")], ["--start-delay", "300"]);
  expect(out).toEqual([{ jsonrpc: "2.0", id: 1, result: {} }]);
  expect(Date.now() - started).toBeGreaterThanOrEqual(300);
});

test("rules can match the request's cursor, or its absence", async () => {
  const rules: Rule[] = [
    { method: "tools/list", cursor: null, result: { page: 1 } },
    { method: "tools/list", cursor: "", result: { page: 2 } },
  ];
  const list = (id: number, cursor?: string) => JSON.stringify({ jsonrpc: "2.0", id, method: "tools/list", params: cursor === undefined ? {} : { cursor } });
  const { out } = await exchange(rules, [list(1), list(2, ""), list(3, "x")]);
  expect(out.map((m: { id: number; result?: { page: number }; error?: { code: number } }) => [m.id, m.result?.page ?? m.error?.code])).toEqual([
    [1, 1],
    [2, 2],
    [3, -32601],
  ]);
});
