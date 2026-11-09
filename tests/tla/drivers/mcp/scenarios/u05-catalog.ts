// U05 tool catalog, step 6: the catalog core (src/mcp/core/catalog.zig) and
// the tool store (src/mcp/protocol/tools.zig), driven by
// tests/tla/drivers/mcp/labs/stdio_lab.zig against the scripted fake server after real era
// detection. Every scenario checks the catalog, era, stdio, and request
// traces against their models, and the requests the server actually received.

import type { Rule } from "../fakes/stdio";
import { expectFinal, labScenario, type LabCase, type Seen } from "../lab";
import type { Scenario } from "../scenario";

const MODERN = "2026-07-28";
const LEGACY = "2025-11-25";
const LIST_CHANGED = { jsonrpc: "2.0", method: "notifications/tools/list_changed" };

const discover: Rule = { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: { listChanged: true } } } };
const initialize: Rule = { method: "initialize", result: { protocolVersion: LEGACY, capabilities: { tools: { listChanged: true } }, serverInfo: { name: "fake", version: "1" } } };
const tool = (name: string) => ({ name, inputSchema: { type: "object" } });
const page = (names: string[], extra: Record<string, unknown> = {}) => ({ tools: names.map(tool), ...extra });
const ping = (before: unknown[] = []): Rule => ({ method: "ping", before, result: {} });

// What the server received: each request's method, with the cursor of tools/list requests.
function received(log: { dir: string; line: string }[]): string[] {
  return log
    .filter((l) => l.dir === "in")
    .map((l) => JSON.parse(l.line) as { method?: string; params?: { cursor?: string } })
    .filter((m) => m.method !== undefined && m.method !== "notifications/initialized")
    .map((m) => (m.method === "tools/list" && m.params?.cursor !== undefined ? `tools/list ${JSON.stringify(m.params.cursor)}` : m.method!));
}

const toolLines = (lines: Seen[]) => lines.filter((l) => l.tools).map((l) => l.tools!);
const calls = (lines: Seen[]) => lines.filter((l) => l.call).map((l) => l.call!);
const events = (lines: Seen[]) => toolLines(lines).filter((t) => t.event !== "dropped").map((t) => (t.event === "fail" ? "fail" : `${t.event}${t.fresh ? "" : " (not cached)"} ${t.names?.join(",")}`));

function same(got: unknown, want: unknown, what: string): string | null {
  return JSON.stringify(got) === JSON.stringify(want) ? null : `${what} were ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`;
}

// Detection, then the catalog, on one preferred modern version.
function catalogScenario(c: Omit<LabCase, "unit" | "requestTrace" | "era" | "catalog"> & { maxPages?: number; modelPages?: number; catalogVerdict?: "ACCEPTED" | "REJECTED" }): Scenario {
  const maxPages = c.maxPages ?? 100;
  return labScenario({
    ...c,
    unit: "U05",
    requestTrace: true,
    era: { preferred: 1 },
    catalog: { maxPages: c.modelPages ?? maxPages, verdict: c.catalogVerdict },
    labFlags: ["--preferred", MODERN, "--probe-ms", "3000", "--max-pages", String(maxPages), ...(c.labFlags ?? [])],
  });
}

const START = ["start", "detect", "expect era-modern"];
const START_LEGACY = ["start", "detect", "expect era-legacy"];
const STOP = ["stop", "expect stopped 5000"];

export const scenarios: Scenario[] = [
  catalogScenario({
    name: "u05-pages-and-cache",
    description: "Two pages joined in order, an empty-string cursor followed, malformed tools and duplicates dropped, then served from the cache (CAT-01, CAT-04)",
    rules: [
      discover,
      { method: "tools/list", cursor: null, result: { tools: [tool("a"), { name: "bad" }], nextCursor: "", ttlMs: 60000 } },
      { method: "tools/list", cursor: "", result: { tools: [tool("b"), tool("a")], ttlMs: 30000 } },
    ],
    script: [...START, "tools", "expect catalog-fresh", "tools", ...STOP],
    check: (lines, final, log) =>
      same(events(lines), ["publish a,b", "serve a,b"], "catalog results") ??
      same(toolLines(lines).filter((t) => t.event === "dropped").map((t) => [t.invalid, t.duplicate]), [[1, 0], [0, 1]], "dropped counts") ??
      same(received(log), ["server/discover", "tools/list", 'tools/list ""'], "requests") ??
      expectFinal(final, { catalog: "fresh", tools: 2 }),
  }),
  catalogScenario({
    name: "u05-zero-ttl",
    description: "A modern list with ttlMs 0 is never served from the cache (CAT-04)",
    rules: [discover, { method: "tools/list", result: page(["a"], { ttlMs: 0 }) }],
    script: [...START, "tools", "expect catalog-idle", "tools", "expect catalog-idle", ...STOP],
    check: (lines, _, log) => same(events(lines), ["publish (not cached) a", "publish (not cached) a"], "catalog results") ?? same(received(log), ["server/discover", "tools/list", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-ttl-expires",
    description: "A cached modern list goes stale when its shortest page TTL runs out, and is listed again on the next need (CAT-04)",
    rules: [discover, { method: "tools/list", cursor: null, result: page(["a"], { nextCursor: "p2", ttlMs: 60000 }) }, { method: "tools/list", cursor: "p2", result: page(["b"], { ttlMs: 300 }) }],
    script: [...START, "tools", "expect catalog-fresh", "expect catalog-stale 3000", "tools", "expect catalog-fresh", ...STOP],
    check: (lines, _, log) => same(events(lines), ["publish a,b", "publish a,b"], "catalog results") ?? same(received(log).filter((m) => m.startsWith("tools/list")).length, 4, "tools/list requests"),
  }),
  catalogScenario({
    name: "u05-list-changed",
    description: "notifications/tools/list_changed makes a fresh list stale at once (CAT-05)",
    rules: [discover, { method: "tools/list", result: page(["a"], { ttlMs: 60000 }) }, ping([LIST_CHANGED])],
    script: [...START, "tools", "expect catalog-fresh", "request ping", "outcome 3 result", "expect catalog-stale", "tools", "expect catalog-fresh", ...STOP],
    check: (lines, _, log) => same(events(lines), ["publish a", "publish a"], "catalog results") ?? same(received(log), ["server/discover", "tools/list", "ping", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-changed-during-listing",
    description: "A list_changed that arrives while a listing runs keeps its answer out of the cache",
    rules: [discover, { method: "tools/list", times: 1, before: [LIST_CHANGED], result: page(["old"], { ttlMs: 60000 }) }, { method: "tools/list", result: page(["new"], { ttlMs: 60000 }) }],
    script: [...START, "tools", "expect catalog-idle", "tools", "expect catalog-fresh", "tools", ...STOP],
    check: (lines) => same(events(lines), ["publish (not cached) old", "publish new", "serve new"], "catalog results"),
  }),
  catalogScenario({
    name: "u05-legacy-cached",
    description: "A 2025 list has no TTL but stays fresh until list_changed",
    rules: [initialize, { method: "tools/list", result: page(["a"]) }, ping([LIST_CHANGED])],
    script: [...START_LEGACY, "tools", "expect catalog-fresh", "tools", "request ping", "outcome 4 result", "expect catalog-stale", "tools", "expect catalog-fresh", ...STOP],
    check: (lines, _, log) =>
      same(events(lines), ["publish a", "serve a", "publish a"], "catalog results") ?? same(received(log), ["server/discover", "initialize", "tools/list", "ping", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-endless-cursor",
    description: "A server that always sends the same cursor is stopped at the page limit",
    maxPages: 5,
    rules: [discover, { method: "tools/list", result: page(["t"], { nextCursor: "same", ttlMs: 60000 }) }],
    script: [...START, "tools", "expect catalog-idle", ...STOP],
    check: (lines, final, log) =>
      same(events(lines), ["publish t"], "catalog results") ?? same(received(log).filter((m) => m.startsWith("tools/list")).length, 5, "tools/list requests") ?? expectFinal(final, { tools: 1 }),
  }),
  catalogScenario({
    name: "u05-invalid-cursor-restart",
    description: "-32602 for a continuation page drops the pages so far and lists again from the beginning (CAT-02)",
    rules: [
      discover,
      { method: "tools/list", cursor: null, result: page(["a"], { nextCursor: "c1", ttlMs: 60000 }) },
      { method: "tools/list", cursor: "c1", times: 1, error: { code: -32602, message: "Invalid cursor" } },
      { method: "tools/list", cursor: "c1", result: page(["b"], { ttlMs: 60000 }) },
    ],
    script: [...START, "tools", "expect catalog-fresh", ...STOP],
    check: (lines, _, log) => same(events(lines), ["publish a,b"], "catalog results") ?? same(received(log), ["server/discover", "tools/list", 'tools/list "c1"', "tools/list", 'tools/list "c1"'], "requests"),
  }),
  catalogScenario({
    name: "u05-invalid-cursor-twice",
    description: "A cursor that is invalid again after the restart fails the listing",
    rules: [discover, { method: "tools/list", cursor: null, result: page(["a"], { nextCursor: "c1" }) }, { method: "tools/list", cursor: "c1", error: { code: -32602, message: "Invalid cursor" } }],
    script: [...START, "tools", "expect catalog-idle", ...STOP],
    check: (lines, final, log) =>
      same(events(lines), ["fail"], "catalog results") ??
      same(received(log), ["server/discover", "tools/list", 'tools/list "c1"', "tools/list", 'tools/list "c1"'], "requests") ??
      expectFinal(final, { catalog: "none", tools: 0 }),
  }),
  catalogScenario({
    name: "u05-page-error",
    description: "A page error fails the listing and caches nothing; the next need lists again",
    rules: [discover, { method: "tools/list", error: { code: -32603, message: "Internal error" } }],
    script: [...START, "tools", "expect catalog-idle", "tools", "expect catalog-idle", ...STOP],
    check: (lines, _, log) => same(events(lines), ["fail", "fail"], "catalog results") ?? same(received(log), ["server/discover", "tools/list", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-page-expires-during-listing",
    description: "A page whose TTL runs out before the listing ends leaves the list stale at once: each page is fresh for its own TTL from its own arrival",
    rules: [
      discover,
      { method: "tools/list", cursor: null, result: page(["a"], { nextCursor: "p2", ttlMs: 100 }) },
      { method: "tools/list", cursor: "p2", delayMs: 300, result: page(["b"], { ttlMs: 60000 }) },
    ],
    script: [...START, "tools", "expect catalog-stale 3000", "tools", "expect catalog-stale 3000", ...STOP],
    check: (lines, _, log) =>
      same(events(lines), ["publish (not cached) a,b", "publish (not cached) a,b"], "catalog results") ??
      same(received(log).filter((m) => m.startsWith("tools/list")).length, 4, "tools/list requests"),
  }),
  catalogScenario({
    name: "u05-failed-refresh-keeps-last",
    description: "A re-list that fails after list_changed hands the waiters the last list, still stale, and every next need lists again",
    rules: [
      discover,
      { method: "tools/list", times: 1, result: page(["a"], { ttlMs: 60000 }) },
      ping([LIST_CHANGED]),
      { method: "tools/list", error: { code: -32603, message: "Internal error" } },
    ],
    script: [...START, "tools", "expect catalog-fresh", "request ping", "outcome 3 result", "expect catalog-stale", "tools", "expect catalog-stale", "tools", "expect catalog-stale", ...STOP],
    check: (lines, _, log) =>
      same(events(lines), ["publish a", "serve_last (not cached) a", "serve_last (not cached) a"], "catalog results") ??
      same(received(log), ["server/discover", "tools/list", "ping", "tools/list", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-needs-join",
    description: "A need while a listing runs joins it instead of starting another",
    rules: [discover, { method: "tools/list", delayMs: 300, result: page(["a"], { ttlMs: 60000 }) }],
    script: [...START, "tools", "tools", "expect catalog-fresh", ...STOP],
    check: (lines, _, log) => same(events(lines), ["publish a"], "catalog results") ?? same(received(log), ["server/discover", "tools/list"], "requests"),
  }),
  catalogScenario({
    name: "u05-call-answers",
    description: "Tool call answers: an isError result and structured content go to the model, input_required and malformed results are recognized, and an unknown-tool error makes the list stale (CAT-08)",
    rules: [
      discover,
      { method: "tools/list", result: page(["echo"], { ttlMs: 60000 }) },
      { method: "tools/call", times: 1, result: { content: [{ type: "text", text: "bad date" }], structuredContent: [1, 2], isError: true } },
      { method: "tools/call", times: 1, result: { resultType: "input_required", inputRequests: {} } },
      { method: "tools/call", times: 1, result: { structuredContent: {} } },
      { method: "tools/call", times: 1, error: { code: -32602, message: "Unknown tool: nope" } },
    ],
    script: [
      ...START,
      "tools",
      "expect catalog-fresh",
      'call echo {"text":"hi"}',
      "outcome 3 result",
      "call echo",
      "outcome 4 result",
      "call echo",
      "outcome 5 result",
      "call nope",
      "outcome 6 peer_error",
      "expect catalog-stale",
      "tools",
      "expect catalog-fresh",
      ...STOP,
    ],
    check: (lines, _, log) => {
      const got = calls(lines).map((c) => [c.kind, c.is_error ?? null, c.structured ?? null, c.code ?? null]);
      const problem = same(got, [["result", true, "[1,2]", null], ["input_required", null, null, null], ["invalid", null, null, null], ["failure", null, null, -32602]], "call answers");
      return problem ?? same(received(log), ["server/discover", "tools/list", "tools/call", "tools/call", "tools/call", "tools/call", "tools/list"], "requests");
    },
  }),
  catalogScenario({
    name: "u05-new-process-relists",
    description: "A new server process makes the list stale, so it is listed again after detection",
    rules: [discover, { method: "tools/list", result: page(["a"], { ttlMs: 60000 }) }, { method: "tools/call", result: { content: [] }, then: "crash" }],
    labFlags: ["--backoff-ms", "20"],
    script: [...START, "tools", "expect catalog-fresh", "call a", "outcome 3 result", "expect idle", "start", "expect era-modern", "expect catalog-stale", "tools", "expect catalog-fresh", ...STOP],
    check: (lines, final, log) =>
      same(events(lines), ["publish a", "publish a"], "catalog results") ??
      same(received(log), ["server/discover", "tools/list", "tools/call", "server/discover", "tools/list"], "requests") ??
      expectFinal(final, { generation: 2, catalog: "fresh" }),
  }),
  catalogScenario({
    name: "u05-listing-lost",
    description: "A server that dies during a listing fails it; nothing is cached",
    rules: [discover, { method: "tools/list", noReply: true, then: "crash" }],
    labFlags: ["--backoff-ms", "20"],
    script: [...START, "tools", "expect catalog-idle", "stop", "expect stopped 5000"],
    check: (lines, final) => same(events(lines), ["fail"], "catalog results") ?? expectFinal(final, { catalog: "none" }),
  }),
  catalogScenario({
    name: "u05-planted-page-limit-mismatch",
    description: "Known-bad control: the lab stops at four pages but the model is told three, so the fourth page can't be matched",
    maxPages: 4,
    modelPages: 3,
    catalogVerdict: "REJECTED",
    rules: [discover, { method: "tools/list", result: page(["t"], { nextCursor: "same" }) }],
    script: [...START, "tools", "expect catalog-idle", ...STOP],
  }),
];
