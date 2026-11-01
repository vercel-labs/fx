import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  SCENARIOS,
  agentPrompt,
  loadCacheAbConfigFromEnv,
  parseStreamUsage,
  prefixBreaks,
  runCacheAbComparison,
  staleShellReuses,
  startRecordingProxy,
  summarize,
  writeFixtureRepo,
  type ScenarioRun,
} from "./prompt-cache-ab";

const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });
const system = (text: string) => ({ role: "system", content: text });

describe("prompt cache A/B helpers", () => {
  test("a request that repeats the previous one before adding to it is no break", () => {
    const first = [system("rules"), user("one")];
    const second = [...first, { role: "assistant", content: [{ type: "text", text: "ok" }] }, user("two")];
    expect(prefixBreaks([first, second])).toEqual([]);
  });

  test("a changed earlier message or a shorter request is a break", () => {
    const first = [system("rules, branch main"), user("one")];
    const changed = [system("rules, branch feature"), user("one"), user("two")];
    expect(prefixBreaks([first, changed])).toEqual([{ from: 0, to: 1, why: "message 0 (system) differs" }]);
    expect(prefixBreaks([first, [first[0]]])).toEqual([{ from: 0, to: 1, why: "shorter" }]);
  });

  test("only requests with tools and a prompt are agent requests", () => {
    expect(agentPrompt({ prompt: [user("x")], tools: [{ name: "read_file" }] })).toHaveLength(1);
    expect(agentPrompt({ prompt: [user("title this")], tools: [] })).toBeNull();
    expect(agentPrompt({ prompt: "x", tools: [{}] })).toBeNull();
    expect(agentPrompt(null)).toBeNull();
  });

  test("usage comes from the stream's finish part", () => {
    const stream =
      'data: {"type":"stream-start"}\n\n' +
      'data: {"type":"text-delta","delta":"finish"}\n\n' +
      'data: {"type":"finish","usage":{"inputTokens":{"total":120,"noCache":20,"cacheRead":90,"cacheWrite":10}}}\n\n';
    expect(parseStreamUsage(stream)).toEqual({ noCache: 20, cacheRead: 90, cacheWrite: 10 });
    expect(parseStreamUsage('data: {"type":"finish","usage":{"inputTokens":{"total":50,"cacheRead":30}}}\n')).toEqual({
      noCache: 20,
      cacheRead: 30,
      cacheWrite: 0,
    });
    expect(parseStreamUsage("data: {\"type\":\"text-delta\"}\n")).toBeNull();
  });

  test("the stale shell check counts a later call that names an earlier handle", () => {
    const toolResult = {
      role: "tool",
      content: [{ type: "tool-result", output: { type: "text", value: '{"session_id":"shell-1","state":"running"}' } }],
    };
    const turn2 = [user("start sleep"), toolResult];
    const turn3First = [...turn2, user("still running?")];
    const call = (input: unknown) => ({ role: "assistant", content: [{ type: "tool-call", input }] });
    const run = (lastCall: unknown): ScenarioRun => ({
      scenario: "staleshell",
      side: "candidate",
      model: "fake/model",
      turns: [
        { prompt: "t1", exit: 0, output: "", requestsEnd: 1 },
        { prompt: "t2", exit: 0, output: "shell-1", requestsEnd: 2 },
        { prompt: "t3", exit: 0, output: "no", requestsEnd: 4 },
      ],
      requests: [
        { seq: 1, path: "/", body: { prompt: [user("read")], tools: [{}] }, usage: null },
        { seq: 2, path: "/", body: { prompt: turn2, tools: [{}] }, usage: null },
        { seq: 3, path: "/", body: { prompt: turn3First, tools: [{}] }, usage: null },
        { seq: 4, path: "/", body: { prompt: [...turn3First, call(lastCall), toolResult], tools: [{}] }, usage: null },
      ],
    });
    expect(staleShellReuses(run({ action: "interact", session_id: "shell-1" }))).toBe(1);
    expect(staleShellReuses(run({ action: "run", command: "pgrep sleep" }))).toBe(0);
  });

  test("a summary counts breaks, new tokens and cache reads of agent requests only", () => {
    const scenario = SCENARIOS.find((s) => s.name === "permnote")!;
    const first = [system("rules"), user("read")];
    const run: ScenarioRun = {
      scenario: "permnote",
      side: "baseline",
      model: "fake/model",
      turns: [
        { prompt: "t1", exit: 0, output: "", requestsEnd: 2 },
        { prompt: "t2", exit: 0, output: "auto", requestsEnd: 3 },
      ],
      requests: [
        { seq: 1, path: "/", body: { prompt: first, tools: [{}] }, usage: { noCache: 100, cacheRead: 0, cacheWrite: 50 } },
        { seq: 2, path: "/", body: { prompt: [user("title")], tools: [] }, usage: { noCache: 9, cacheRead: 0, cacheWrite: 0 } },
        { seq: 3, path: "/", body: { prompt: [system("changed"), user("read")], tools: [{}] }, usage: null },
      ],
    };
    expect(summarize(run, scenario)).toEqual({
      scenario: "permnote",
      side: "baseline",
      model: "fake/model",
      exitedCleanly: true,
      agentRequests: 2,
      prefixBreaks: 1,
      newTokens: 150,
      cacheRead: 0,
      usageMissing: 1,
      answersRight: true,
    });
  });

  test("the recording proxy forwards a request and keeps its body and usage", async () => {
    const upstream = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: () =>
        new Response('data: {"type":"finish","usage":{"inputTokens":{"noCache":3,"cacheRead":7,"cacheWrite":0}}}\n\n', {
          headers: { "content-type": "text/event-stream" },
        }),
    });
    const proxy = startRecordingProxy(`http://127.0.0.1:${upstream.port}`);
    try {
      const response = await fetch(`${proxy.url}/v4/ai/language-model`, { method: "POST", body: JSON.stringify({ prompt: [], tools: [] }) });
      expect(await response.text()).toContain('"finish"');
      await Bun.sleep(50);
      expect(proxy.requests).toHaveLength(1);
      expect(proxy.requests[0].path).toBe("/v4/ai/language-model");
      expect(proxy.requests[0].body).toEqual({ prompt: [], tools: [] });
      expect(proxy.requests[0].usage).toEqual({ noCache: 3, cacheRead: 7, cacheWrite: 0 });
    } finally {
      proxy.stop();
      upstream.stop(true);
    }
  });

  test("the fixture is a repository on master with every file committed", () => {
    const repo = mkdtempSync(join(tmpdir(), "fx-cache-ab-fixture-"));
    try {
      writeFixtureRepo(repo);
      const branch = Bun.spawnSync(["git", "-C", repo, "branch", "--show-current"]).stdout.toString().trim();
      expect(branch).toBe("master");
      expect(Bun.spawnSync(["git", "-C", repo, "status", "--porcelain"]).stdout.toString()).toBe("");
      expect(readFileSync(join(repo, "README.md"), "utf8")).toContain("shopkit");
    } finally {
      rmSync(repo, { recursive: true, force: true });
    }
  });

  test("the config names two absolute binaries, the models, and known scenarios", () => {
    expect(() => loadCacheAbConfigFromEnv({})).toThrow("FX_CACHE_AB_MODELS");
    expect(() => loadCacheAbConfigFromEnv({ FX_CACHE_AB_MODELS: "a/b", FX_CACHE_AB_BASELINE_BIN: "fx" })).toThrow("absolute");
    expect(() =>
      loadCacheAbConfigFromEnv({
        FX_CACHE_AB_MODELS: "a/b",
        FX_CACHE_AB_SCENARIOS: "nope",
        FX_CACHE_AB_BASELINE_BIN: process.execPath,
        FX_CACHE_AB_CANDIDATE_BIN: process.execPath,
      }),
    ).toThrow("unknown scenario");
  });
});

// Live: FX_CACHE_AB_BASELINE_BIN and FX_CACHE_AB_CANDIDATE_BIN name two fx
// builds, FX_CACHE_AB_MODELS a comma-separated list of models. Billed calls.
const live =
  !!process.env.FX_CACHE_AB_BASELINE_BIN && !!process.env.FX_CACHE_AB_CANDIDATE_BIN && !!process.env.FX_CACHE_AB_MODELS;

describe.skipIf(!live)("prompt cache A/B (live models)", () => {
  test(
    "both builds finish every scenario, and the candidate breaks the cache no more than the baseline",
    async () => {
      const summaries = await runCacheAbComparison(loadCacheAbConfigFromEnv());
      for (const summary of summaries) expect(summary.usageMissing).toBe(0);
      const sum = (side: string) => summaries.filter((s) => s.side === side).reduce((n, s) => n + s.prefixBreaks, 0);
      expect(summaries.filter((s) => s.side === "candidate").every((s) => s.exitedCleanly)).toBe(true);
      expect(sum("candidate")).toBeLessThanOrEqual(sum("baseline"));
    },
    { timeout: 24 * 60 * 60 * 1000 },
  );
});
