import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { RecordedRequest } from "./prompt-cache-ab";
import {
  MARKERS,
  TASKS,
  loadToolboxAbConfigFromEnv,
  mainAgentRequests,
  runToolboxAbComparison,
  sideTotals,
  summarizeConversation,
  writeTaskFixture,
  type ConversationSummary,
} from "./toolbox-ab";

const tools = (...names: string[]) => names.map((name) => ({ name, description: `${name} tool` }));
let seq = 0;
const request = (toolNames: string[], usage: RecordedRequest["usage"]): RecordedRequest => ({
  seq: ++seq,
  path: "/v4/ai/language-model",
  body: { prompt: [{ role: "user", content: "x" }], tools: tools(...toolNames) },
  usage,
});
const usage = (noCache: number, cacheRead: number, cacheWrite = 0) => ({ noCache, cacheRead, cacheWrite });

describe("toolbox A/B helpers", () => {
  test("only requests whose tools include read_file are the main agent's", () => {
    const main = request(["read_file", "toolbox"], usage(10, 0));
    const reviewer = request(["decide"], usage(5, 0));
    const title = { seq: ++seq, path: "/v4/ai/language-model", body: { prompt: [], tools: [] }, usage: null };
    expect(mainAgentRequests([main, reviewer, title])).toEqual([main]);
  });

  test("a conversation counts its tool lists and the later requests' cached input", () => {
    const requests = [
      request(["read_file", "mcp_select_tool"], usage(1000, 0, 500)),
      request(["read_file", "mcp_select_tool", "mcp_fixture_echo"], usage(300, 1200)),
      request(["read_file", "mcp_select_tool", "mcp_fixture_echo"], usage(100, 1500, 50)),
    ];
    const summary = summarizeConversation(requests, { task: "mcp", side: "baseline", model: "m", answer: `It returned ${MARKERS.mcp}.`, exitedCleanly: true });
    expect(summary.requests).toBe(3);
    expect(summary.toolLists).toBe(2);
    expect(summary.toolBytes).toBe(JSON.stringify(tools("read_file", "mcp_select_tool")).length);
    expect(summary.laterInput).toBe(300 + 1200 + 100 + 1500 + 50);
    expect(summary.laterCacheRead).toBe(2700);
    expect(summary.answerRight).toBe(true);
    expect(summary.usageMissing).toBe(0);
  });

  test("each task is right only with its marker", () => {
    const check = (name: string, answer: string) => TASKS.find((t) => t.name === name)!.check(answer);
    expect(check("skill", MARKERS.skill)).toBe(true);
    expect(check("file", "docs/plan.md")).toBe(false);
    expect(check("many", MARKERS.many)).toBe(false);
    expect(check("many", `tool_42 returned ${MARKERS.many}`)).toBe(true);
    expect(check("added", `SEVEN ... ${MARKERS.mcp}`)).toBe(true);
    expect(check("added", "SEVEN")).toBe(false);
  });

  test("a side's totals add its conversations and give the fx ask tasks' tool bytes", () => {
    const row = (task: ConversationSummary["task"], side: string, toolLists: number, toolBytes: number, requests: number): ConversationSummary => ({
      task, side, model: "m", answerRight: true, exitedCleanly: true, requests, toolLists, toolBytes, laterInput: 100, laterCacheRead: 60, usageMissing: 0,
    });
    const summaries = [
      row("skill", "candidate", 1, 700, 2),
      row("many", "candidate", 1, 650, 4),
      row("added", "candidate", 1, 990, 3),
      row("mcp", "baseline", 2, 900, 3),
    ];
    expect(sideTotals(summaries, "candidate")).toEqual({
      side: "candidate",
      conversations: 3,
      answersRight: 3,
      toolsChanged: 0,
      laterInput: 300,
      laterCacheRead: 180,
      laterUncached: 120,
      requests: 9,
      manyRequests: 4,
      toolBytes: { min: 650, max: 700 },
    });
    expect(sideTotals(summaries, "baseline").toolsChanged).toBe(1);
  });

  test("the fixture has the skill, both markdown files, and the MCP servers it asks for", () => {
    const root = mkdtempSync(join(tmpdir(), "fx-toolbox-ab-test-"));
    try {
      const { home, workspace } = writeTaskFixture(root, { mcp: true, manyUrl: "http://127.0.0.1:1/s/0/mcp" });
      expect(readFileSync(join(home, ".fx", "skills", "live-review", "SKILL.md"), "utf8")).toContain(MARKERS.skill);
      expect(readFileSync(join(workspace, "docs", "plan.md"), "utf8")).toContain(MARKERS.file);
      const servers = JSON.parse(readFileSync(join(home, ".fx", "mcp.json"), "utf8")).mcp;
      expect(Object.keys(servers)).toEqual(["fixture", "s0000"]);
      expect(servers.fixture.environment.FX_MCP_RESULT_TEXT).toBe(MARKERS.mcp);
      const bare = writeTaskFixture(join(root, "bare"), { mcp: false });
      expect(existsSync(join(bare.home, ".fx", "mcp.json"))).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("the config names two absolute binaries, the models, and known tasks", () => {
    expect(() => loadToolboxAbConfigFromEnv({})).toThrow("FX_TOOLBOX_AB_MODELS");
    expect(() => loadToolboxAbConfigFromEnv({ FX_TOOLBOX_AB_MODELS: "a/b", FX_TOOLBOX_AB_BASELINE_BIN: "fx" })).toThrow("absolute");
    expect(() =>
      loadToolboxAbConfigFromEnv({
        FX_TOOLBOX_AB_MODELS: "a/b",
        FX_TOOLBOX_AB_TASKS: "nope",
        FX_TOOLBOX_AB_BASELINE_BIN: process.execPath,
        FX_TOOLBOX_AB_CANDIDATE_BIN: process.execPath,
      }),
    ).toThrow("unknown task nope");
    const config = loadToolboxAbConfigFromEnv({
      FX_TOOLBOX_AB_MODELS: "a/b, c/d",
      FX_TOOLBOX_AB_TASKS: "skill,many",
      FX_TOOLBOX_AB_BASELINE_BIN: process.execPath,
      FX_TOOLBOX_AB_CANDIDATE_BIN: process.execPath,
      FX_TOOLBOX_AB_OUTPUT_DIR: "/tmp/out",
    });
    expect(config.models).toEqual(["a/b", "c/d"]);
    expect(config.tasks.map((t) => t.name)).toEqual(["skill", "many"]);
    expect(config.timeoutMs).toBe(400000);
  });
});

// Live: FX_TOOLBOX_AB_BASELINE_BIN and FX_TOOLBOX_AB_CANDIDATE_BIN name two fx
// builds, FX_TOOLBOX_AB_MODELS a comma-separated list of models. The added
// task needs tmux. Billed calls.
const live =
  !!process.env.FX_TOOLBOX_AB_BASELINE_BIN && !!process.env.FX_TOOLBOX_AB_CANDIDATE_BIN && !!process.env.FX_TOOLBOX_AB_MODELS;

describe.skipIf(!live)("toolbox A/B (live models)", () => {
  test(
    "the candidate's conversations never change their tools",
    async () => {
      const { totals } = await runToolboxAbComparison();
      const candidate = totals.find((t) => t.side === "candidate")!;
      expect(candidate.toolsChanged).toBe(0);
    },
    24 * 60 * 60 * 1000,
  );
});
