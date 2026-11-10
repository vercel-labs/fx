/**
 * Model-backed A/B eval of the tools fx sends: whether a conversation's tools
 * stay the same, and what that does to the prompt cache.
 *
 * Each task is one conversation in its own profile and folder, with a skill,
 * the fixture MCP server, and two markdown files:
 *
 * - skill: read a skill and quote its first rule;
 * - mcp: run the fixture MCP server's echo tool and quote its result;
 * - file: find a markdown file by its content and quote a value from it;
 * - added: in the TUI, answer one prompt, then use an MCP server added to the
 *   profile while the session runs;
 * - many: run one tool of an MCP server with 100 tools.
 *
 * A recording proxy in front of AI Gateway keeps every request and the usage
 * its stream reports. The main agent's requests are the ones whose tools
 * include read_file, so auto mode's reviewer and title requests are left out.
 * Per conversation it reports how many different tool lists the requests
 * sent (1 means the tools never changed), the input of every request after
 * the first and how much of it was read from the cache, the request count,
 * the bytes of the first request's tools, and whether the answer is right.
 *
 * It compares two explicit fx binaries on the same models. Results vary
 * between runs. It makes billed calls and is not a pull request check.
 */
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { startManyMcpHttpServers } from "../e2e/fixtures/mcp-many";
import { TmuxSession } from "../e2e/tmux-helpers";
import { requireAbsoluteExecutableBinary } from "./agent-quality-ab";
import { DEFAULT_UPSTREAM, startRecordingProxy, type RecordedRequest } from "./prompt-cache-ab";

const MCP_FIXTURE = resolve(import.meta.dirname, "../e2e/fixtures/mcp-modern-stdio.mjs");

export const MARKERS = {
  skill: "LIVE_RULE_CITE_EVERY_LINE",
  mcp: "LIVE_MCP_ECHO_RESULT",
  file: "LIVE_LAUNCH_CODE_7731",
  many: "LIVE_MANY_RESULT",
} as const;

export type TaskName = "skill" | "mcp" | "file" | "added" | "many";

export interface Task {
  name: TaskName;
  /** One prompt for `fx ask`; the TUI task's two prompts, in order. */
  prompts: string[];
  /** Whether the answer is right. */
  check: (answer: string) => boolean;
}

export const TASKS: Task[] = [
  {
    name: "skill",
    prompts: ["Use the live-review skill and tell me its first rule, word for word."],
    check: (answer) => answer.includes(MARKERS.skill),
  },
  {
    name: "mcp",
    prompts: ["Use the fixture MCP server's echo tool to echo the text PINEAPPLE, and tell me exactly what it returned."],
    check: (answer) => answer.includes(MARKERS.mcp),
  },
  {
    name: "file",
    prompts: ["One markdown file under this folder states a launch code. Find it and tell me the code and the file's path."],
    check: (answer) => answer.includes(MARKERS.file),
  },
  {
    name: "added",
    prompts: [
      "What is three plus four? Reply with only the number, written as one word in capital letters.",
      "An MCP server was just added for you. Use its echo tool to echo the word MANGO, and tell me exactly what it returned.",
    ],
    check: (answer) => answer.includes("SEVEN") && answer.includes(MARKERS.mcp),
  },
  {
    name: "many",
    prompts: ["Use tool_42 of the s0000 MCP server to echo the text KIWI, and tell me exactly what it returned."],
    check: (answer) => answer.includes(MARKERS.many) && answer.includes("tool_42"),
  },
];

interface Body {
  tools?: Array<{ name?: string }>;
}

/** The main agent's requests: those whose tools include read_file. */
export function mainAgentRequests(requests: RecordedRequest[]): RecordedRequest[] {
  return requests.filter((r) => ((r.body as Body | null)?.tools ?? []).some((tool) => tool.name === "read_file"));
}

export interface ConversationSummary {
  task: TaskName;
  side: string;
  model: string;
  answerRight: boolean;
  exitedCleanly: boolean;
  requests: number;
  /** Different tool lists the main agent's requests sent; 1 means unchanged. */
  toolLists: number;
  /** Bytes of the first request's tools, as JSON. */
  toolBytes: number;
  /** Input of every request after the first, and the part read from the cache. */
  laterInput: number;
  laterCacheRead: number;
  usageMissing: number;
}

export function summarizeConversation(
  requests: RecordedRequest[],
  info: { task: TaskName; side: string; model: string; answer: string; exitedCleanly: boolean },
): ConversationSummary {
  const agent = mainAgentRequests(requests);
  const toolLists = agent.map((r) => JSON.stringify((r.body as Body).tools));
  const later = agent.slice(1);
  const task = TASKS.find((t) => t.name === info.task)!;
  return {
    task: info.task,
    side: info.side,
    model: info.model,
    answerRight: task.check(info.answer),
    exitedCleanly: info.exitedCleanly,
    requests: agent.length,
    toolLists: new Set(toolLists).size,
    toolBytes: toolLists[0]?.length ?? 0,
    laterInput: later.reduce((sum, r) => sum + (r.usage ? r.usage.noCache + r.usage.cacheRead + r.usage.cacheWrite : 0), 0),
    laterCacheRead: later.reduce((sum, r) => sum + (r.usage?.cacheRead ?? 0), 0),
    usageMissing: agent.filter((r) => r.usage === null).length,
  };
}

export interface SideTotals {
  side: string;
  conversations: number;
  answersRight: number;
  /** Conversations whose main agent sent more than one tool list. */
  toolsChanged: number;
  laterInput: number;
  laterCacheRead: number;
  /** The part of later input not read from the cache. */
  laterUncached: number;
  requests: number;
  manyRequests: number;
  /**
   * The fewest and most bytes of a first request's tools in the `fx ask`
   * tasks. They differ by model; the TUI sends more tools, so it is left out.
   */
  toolBytes: { min: number; max: number };
}

export function sideTotals(summaries: ConversationSummary[], side: string): SideTotals {
  const rows = summaries.filter((s) => s.side === side);
  const laterInput = rows.reduce((sum, s) => sum + s.laterInput, 0);
  const laterCacheRead = rows.reduce((sum, s) => sum + s.laterCacheRead, 0);
  const askBytes = rows.filter((s) => s.task !== "added").map((s) => s.toolBytes);
  return {
    side,
    conversations: rows.length,
    answersRight: rows.filter((s) => s.answerRight).length,
    toolsChanged: rows.filter((s) => s.toolLists > 1).length,
    laterInput,
    laterCacheRead,
    laterUncached: laterInput - laterCacheRead,
    requests: rows.reduce((sum, s) => sum + s.requests, 0),
    manyRequests: rows.filter((s) => s.task === "many").reduce((sum, s) => sum + s.requests, 0),
    toolBytes: { min: askBytes.length ? Math.min(...askBytes) : 0, max: askBytes.length ? Math.max(...askBytes) : 0 },
  };
}

/** The profile and folder every task starts from; the TUI task adds its server later. */
export function writeTaskFixture(root: string, opts: { mcp: boolean; manyUrl?: string }): { home: string; workspace: string } {
  const home = join(root, "home");
  const workspace = join(root, "ws");
  mkdirSync(join(home, ".fx", "skills", "live-review"), { recursive: true, mode: 0o700 });
  mkdirSync(join(workspace, "docs"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}\n", { mode: 0o600 });
  writeFileSync(
    join(home, ".fx", "skills", "live-review", "SKILL.md"),
    "---\nname: live-review\ndescription: Review a change and report each problem with a file:line cite.\n---\n\n# live-review\n\n" +
      `The first rule of this review is ${MARKERS.skill}: cite every problem as file:line.\n`,
  );
  writeFileSync(join(workspace, "docs", "release.md"), "Release notes\nNothing here.\n");
  writeFileSync(join(workspace, "docs", "plan.md"), `Launch plan\nThe launch code is ${MARKERS.file}.\n`);
  writeFileSync(join(workspace, "main.py"), 'print("hello")\n');
  if (opts.mcp) writeMcpConfig(home, { manyUrl: opts.manyUrl });
  return { home, workspace };
}

/**
 * The fixture MCP server, and the 100-tool one when `manyUrl` names it. The
 * TUI asks for form and URL elicitation and `fx ask` for none; the fixture
 * refuses a client that doesn't ask for what it expects.
 */
export function writeMcpConfig(home: string, opts: { manyUrl?: string; tui?: boolean } = {}): void {
  const servers: Record<string, unknown> = {
    fixture: {
      type: "local",
      command: [process.execPath, MCP_FIXTURE],
      enabled: true,
      environment: { FX_MCP_MODE: "normal", FX_MCP_RESULT_TEXT: MARKERS.mcp, FX_MCP_EXPECT_ELICITATION: opts.tui ? "both" : "none" },
    },
  };
  if (opts.manyUrl) servers.s0000 = { type: "http", url: opts.manyUrl };
  writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: servers }) + "\n", { mode: 0o600 });
}

function runAsk(
  binary: string,
  args: string[],
  opts: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number },
): Promise<{ code: number | null; stdout: string }> {
  return new Promise((done) => {
    const child = spawn(binary, args, { cwd: opts.cwd, env: opts.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.resume();
    const timer = setTimeout(() => child.kill("SIGKILL"), opts.timeoutMs);
    child.on("close", (code) => {
      clearTimeout(timer);
      done({ code, stdout });
    });
  });
}

function finalOutput(stdout: string): string {
  const start = stdout.indexOf("{");
  if (start < 0) return "";
  try {
    const doc = JSON.parse(stdout.slice(start));
    return String(doc.final_output || doc.output || "").trim();
  } catch {
    return "";
  }
}

/** Runs one task with `binary` and `model` in a fresh profile and folder. */
export async function runTask(
  task: Task,
  opts: { binary: string; side: string; model: string; timeoutMs: number; manyUrl: string; upstream?: string },
): Promise<{ summary: ConversationSummary; requests: RecordedRequest[]; answer: string }> {
  const root = mkdtempSync(join(tmpdir(), `fx-toolbox-ab-${task.name}-`));
  const { home, workspace } = writeTaskFixture(root, { mcp: task.name !== "added", manyUrl: task.name === "many" ? opts.manyUrl : undefined });
  const proxy = startRecordingProxy(opts.upstream ?? DEFAULT_UPSTREAM);
  const env: Record<string, string | undefined> = {
    ...process.env,
    HOME: home,
    NO_COLOR: "1",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_MODEL: opts.model,
    FX_GATEWAY_BASE_URL: proxy.url,
    FX_GATEWAY_CHAT_URL: `${proxy.url}/v4/ai/language-model`,
  };
  let answer = "";
  let exitedCleanly = true;
  try {
    if (task.name === "added") {
      const session = await TmuxSession.create({ cmd: opts.binary, cwd: workspace, env: { ...env, FX_PERMISSION_MODE: "auto" }, width: 150, height: 50, isolated: true });
      try {
        await session.waitForComposer(60_000);
        await session.sendText(task.prompts[0]);
        await session.waitForText("SEVEN", opts.timeoutMs).catch(() => (exitedCleanly = false));
        await Bun.sleep(4000);
        writeMcpConfig(home, { tui: true });
        await Bun.sleep(3000);
        await session.sendText(task.prompts[1]);
        await session.waitForText(MARKERS.mcp, opts.timeoutMs).catch(() => (exitedCleanly = false));
        await Bun.sleep(5000);
        answer = await session.captureFullScrollback();
      } finally {
        await session.kill();
      }
    } else {
      const result = await runAsk(opts.binary, ["ask", "--json", "--auto", "--no-save", "--", task.prompts[0]], { cwd: workspace, env, timeoutMs: opts.timeoutMs });
      exitedCleanly = result.code === 0;
      answer = finalOutput(result.stdout);
    }
    // Let the proxy finish reading the last stream.
    await Bun.sleep(2000);
  } finally {
    proxy.stop();
    rmSync(root, { recursive: true, force: true });
  }
  const requests = proxy.requests;
  return { summary: summarizeConversation(requests, { task: task.name, side: opts.side, model: opts.model, answer, exitedCleanly }), requests, answer };
}

export interface ToolboxAbConfig {
  baselineBin: string;
  candidateBin: string;
  models: string[];
  tasks: Task[];
  outputDir: string;
  timeoutMs: number;
}

export function loadToolboxAbConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ToolboxAbConfig {
  const models = (env.FX_TOOLBOX_AB_MODELS ?? "").split(",").map((m) => m.trim()).filter(Boolean);
  if (models.length === 0) throw new Error("FX_TOOLBOX_AB_MODELS must name at least one model");
  const wanted = (env.FX_TOOLBOX_AB_TASKS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const tasks = wanted.length === 0 ? TASKS : wanted.map((name) => {
    const task = TASKS.find((t) => t.name === name);
    if (!task) throw new Error(`unknown task ${name}`);
    return task;
  });
  return {
    baselineBin: requireAbsoluteExecutableBinary(env.FX_TOOLBOX_AB_BASELINE_BIN ?? "", "baseline"),
    candidateBin: requireAbsoluteExecutableBinary(env.FX_TOOLBOX_AB_CANDIDATE_BIN ?? "", "candidate"),
    models,
    tasks,
    outputDir: env.FX_TOOLBOX_AB_OUTPUT_DIR ?? mkdtempSync(join(tmpdir(), `fx-toolbox-ab-${Date.now()}-`)),
    timeoutMs: Number(env.FX_TOOLBOX_AB_TIMEOUT_MS ?? "400000"),
  };
}

/**
 * Runs every task on both binaries for each model, one model's tasks at a
 * time in parallel; writes one JSON file per conversation and a summary with
 * each side's totals.
 */
export async function runToolboxAbComparison(config = loadToolboxAbConfigFromEnv()): Promise<{ summaries: ConversationSummary[]; totals: SideTotals[] }> {
  mkdirSync(config.outputDir, { recursive: true });
  const many = startManyMcpHttpServers({ servers: 1, toolsPerServer: 100, resultText: MARKERS.many });
  const summaries: ConversationSummary[] = [];
  try {
    for (const model of config.models) {
      for (const [side, binary] of [["baseline", config.baselineBin], ["candidate", config.candidateBin]] as const) {
        const runs = await Promise.all(
          config.tasks.map((task) => runTask(task, { binary, side, model, timeoutMs: config.timeoutMs, manyUrl: many.url(0) })),
        );
        for (const run of runs) {
          summaries.push(run.summary);
          const file = `${model.replaceAll("/", "_")}-${run.summary.task}-${side}.json`;
          writeFileSync(join(config.outputDir, file), JSON.stringify(run, null, 2));
          console.log(JSON.stringify(run.summary));
        }
      }
    }
  } finally {
    many.stop();
  }
  const totals = [sideTotals(summaries, "baseline"), sideTotals(summaries, "candidate")];
  writeFileSync(join(config.outputDir, "summary.json"), JSON.stringify({ summaries, totals }, null, 2));
  for (const total of totals) console.log(JSON.stringify(total));
  console.log(`artifacts: ${config.outputDir}`);
  return { summaries, totals };
}
