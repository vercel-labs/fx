/**
 * Model-backed A/B eval of the prompt cache across mid-session changes.
 *
 * Each scenario is one saved fx session in its own profile and repository:
 * turn 1 reads every file to build a real history, then one event happens
 * (a branch switch, a permission change, folder rules, a restart, a named
 * skill), then more turns, each through `fx ask --resume last`. A recording
 * proxy in front of AI Gateway keeps every request and the usage its stream
 * reports. Per run it reports:
 *
 * - prefix breaks: agent requests that do not repeat the previous one byte for
 *   byte before adding to it, so the provider cannot reuse its cache;
 * - new tokens (uncached input plus cache writes) and cache reads;
 * - whether the answers are right for the scenario.
 *
 * It compares two explicit fx binaries on the same models. Results vary
 * between runs, so compare several runs, not one. It makes billed calls and
 * is not a pull request check.
 */
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requireAbsoluteExecutableBinary } from "./agent-quality-ab";

export const DEFAULT_UPSTREAM = "https://ai-gateway.vercel.sh";

export interface RecordedRequest {
  seq: number;
  path: string;
  /** The parsed JSON body of a POST, or null. */
  body: unknown;
  usage: StreamUsage | null;
}

export interface StreamUsage {
  noCache: number;
  cacheRead: number;
  cacheWrite: number;
}

interface PromptMessage {
  role: string;
  content: unknown;
}

/** An agent request: one with tools and a prompt, not a title or reviewer request. */
export function agentPrompt(body: unknown): PromptMessage[] | null {
  if (!body || typeof body !== "object") return null;
  const { prompt, tools } = body as { prompt?: unknown; tools?: unknown };
  if (!Array.isArray(prompt) || !Array.isArray(tools) || tools.length === 0) return null;
  return prompt as PromptMessage[];
}

/**
 * Pairs of consecutive agent requests where the later one does not start
 * with every message of the earlier one, unchanged.
 */
export function prefixBreaks(prompts: PromptMessage[][]): Array<{ from: number; to: number; why: string }> {
  const breaks: Array<{ from: number; to: number; why: string }> = [];
  for (let i = 1; i < prompts.length; i++) {
    const prev = prompts[i - 1];
    const next = prompts[i];
    if (next.length < prev.length) {
      breaks.push({ from: i - 1, to: i, why: "shorter" });
      continue;
    }
    const at = prev.findIndex((message, index) => JSON.stringify(message) !== JSON.stringify(next[index]));
    if (at >= 0) breaks.push({ from: i - 1, to: i, why: `message ${at} (${prev[at].role}) differs` });
  }
  return breaks;
}

/** The usage the stream's `finish` part reports, or null. */
export function parseStreamUsage(stream: string): StreamUsage | null {
  let usage: StreamUsage | null = null;
  for (const line of stream.split("\n")) {
    if (!line.startsWith("data: ") || !line.includes('"finish"')) continue;
    try {
      const part = JSON.parse(line.slice(6));
      if (part.type !== "finish") continue;
      const input = part.usage?.inputTokens ?? {};
      const cacheRead = Number(input.cacheRead ?? 0);
      const cacheWrite = Number(input.cacheWrite ?? 0);
      const noCache = Number(input.noCache ?? Math.max(0, Number(input.total ?? 0) - cacheRead - cacheWrite));
      usage = { noCache, cacheRead, cacheWrite };
    } catch {}
  }
  return usage;
}

export interface RecordingProxy {
  url: string;
  requests: RecordedRequest[];
  stop(): void;
}

/** A reverse proxy on localhost that forwards to `upstream` and records. */
export function startRecordingProxy(upstream = DEFAULT_UPSTREAM): RecordingProxy {
  const requests: RecordedRequest[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const raw = req.method === "GET" || req.method === "HEAD" ? undefined : await req.text();
      const headers = new Headers(req.headers);
      for (const name of ["host", "content-length", "accept-encoding"]) headers.delete(name);
      const record: RecordedRequest = { seq: requests.length + 1, path: url.pathname, body: null, usage: null };
      if (raw) {
        try {
          record.body = JSON.parse(raw);
        } catch {}
      }
      requests.push(record);
      const response = await fetch(upstream + url.pathname + url.search, { method: req.method, headers, body: raw });
      const outHeaders = new Headers(response.headers);
      for (const name of ["content-encoding", "content-length"]) outHeaders.delete(name);
      if (!response.body) return new Response(null, { status: response.status, headers: outHeaders });
      const [toClient, toRecord] = response.body.tee();
      void new Response(toRecord).text().then((text) => {
        record.usage = parseStreamUsage(text);
      });
      return new Response(toClient, { status: response.status, headers: outHeaders });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, requests, stop: () => server.stop(true) };
}

export const TURN1 =
  "Read every file in this repository except under .git, one read_file call per file. " +
  "Then reply with one short line per file saying what it does.";

export interface Scenario {
  name: string;
  /** Turns after turn 1, each run with `--resume last`. */
  turns: string[];
  /** Changes the repository or profile after turn 1. */
  afterTurn1?: (repo: string, home: string) => void;
  /** Runs before the turn at this index, outside fx. */
  beforeTurn?: Record<number, (repo: string) => void>;
  /** Turns at these indexes run without `--full-access`, in the profile's `auto` mode. */
  defaultAccess?: number[];
  /** Whether the answers are right. */
  check?: (run: ScenarioRun) => boolean;
}

export interface TurnResult {
  prompt: string;
  exit: number | null;
  output: string;
  /** Index into the run's requests after this turn. */
  requestsEnd: number;
}

export interface ScenarioRun {
  scenario: string;
  side: string;
  model: string;
  turns: TurnResult[];
  requests: RecordedRequest[];
}

function git(repo: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", "-C", repo, ...args], { stdout: "ignore", stderr: "pipe" });
  if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString()}`);
}

function endsWithWord(text: string, word: string): boolean {
  return new RegExp(`${word}\\W*$`).test(text.trim());
}

const PINEAPPLE_RULES = "# Sub rules\n\nEvery reply about a file in this folder must end with the word PINEAPPLE.\n";

/** Session ids of shells started before the last turn that the last turn uses again. */
export function staleShellReuses(run: ScenarioRun): number {
  const agent = run.requests.map((r) => agentPrompt(r.body));
  const lastStart = run.turns.at(-2)?.requestsEnd ?? 0;
  const ids = new Set<string>();
  for (const prompt of agent.slice(0, lastStart + 1)) {
    for (const message of prompt ?? []) {
      if (message.role !== "tool") continue;
      for (const match of JSON.stringify(message.content).matchAll(/session_id\\?"\s*:\s*\\?"(shell-[A-Za-z0-9_-]+)/g)) ids.add(match[1]);
    }
  }
  const lastTurn = agent.slice(lastStart).filter((p): p is PromptMessage[] => p !== null);
  const first = lastTurn[0];
  const last = lastTurn.at(-1);
  if (!first || !last) return 0;
  let reused = 0;
  for (const message of last.slice(first.length - 1)) {
    if (message.role !== "assistant" || !Array.isArray(message.content)) continue;
    for (const part of message.content as Array<{ type?: string; input?: unknown }>) {
      if (part.type !== "tool-call") continue;
      const input = JSON.stringify(part.input ?? "");
      if ([...ids].some((id) => input.includes(id))) reused++;
    }
  }
  return reused;
}

export const SCENARIOS: Scenario[] = [
  { name: "control", turns: ["Reply with the single word OK."] },
  {
    // The agent switches branches mid-turn; later turns ask which branch is
    // checked out, and before the last one it switches back outside fx. The
    // switch back names `master`, so it works even when a build never ran the
    // first turn's checkout.
    name: "branchnote",
    turns: [
      "Use the shell tool to run `git checkout -q -b feature-x`, then reply with only the word done.",
      "Without running any tools, which git branch is checked out right now? Reply with only the branch name.",
      "Without running any tools, which git branch is checked out right now? Reply with only the branch name.",
    ],
    beforeTurn: { 2: (repo) => git(repo, "checkout", "-q", "master") },
    check: (run) => {
      const texts = run.turns.slice(1).map((t) => t.output.toLowerCase());
      return texts.length >= 3 && texts[0].includes("done") && texts[1].includes("feature-x") && texts[2].includes("master");
    },
  },
  {
    name: "permnote",
    turns: ["Without running any tools, which fx permission mode applies right now? Reply with only the mode name."],
    defaultAccess: [0],
    check: (run) => (run.turns[1]?.output ?? "").toLowerCase().includes("auto"),
  },
  {
    // Folder rules with a visible effect, created after turn 1 so only later turns reach them.
    name: "scopedobey",
    turns: [
      "Read sub/notes.md with the read_file tool, then reply with its first line.",
      "Read sub/notes.md again with the read_file tool, then reply with its second line.",
    ],
    afterTurn1: (repo) => {
      mkdirSync(join(repo, "sub"));
      writeFileSync(join(repo, "sub", "AGENTS.md"), PINEAPPLE_RULES);
      writeFileSync(join(repo, "sub", "notes.md"), "Scoped note line one.\nLine two.\n");
    },
    check: (run) => run.turns.slice(1).length >= 2 && run.turns.slice(1).every((t) => endsWithWord(t.output, "PINEAPPLE")),
  },
  {
    // Turn 2 leaves a shell running; turn 3 is a new process, so that handle is stale.
    name: "staleshell",
    turns: [
      "Use the shell tool to run `sleep 300` with yield_time_ms 0, so it keeps running in the background. Then reply with only its session_id.",
      "Is the sleep command you started still running? Find out, then answer yes or no and say how you checked.",
    ],
    check: (run) => staleShellReuses(run) === 0,
  },
  {
    // A named skill with a visible effect; the next turn does not name it.
    name: "skillobey",
    turns: ["$pineapple-note Reply with one short sentence about this repository.", "Reply with one short sentence about the README."],
    check: (run) => endsWithWord(run.turns[1]?.output ?? "", "PINEAPPLE"),
  },
];

const FIXTURE_FILES: Record<string, string> = {
  "README.md": "# shopkit\n\nA tiny inventory toolkit.\n\n- `shopkit/pricing.py` computes order totals.\n- `shopkit/store.py` tracks stock.\n",
  "shopkit/__init__.py": '"""shopkit: a tiny inventory toolkit."""\n',
  "shopkit/pricing.py":
    "def calc_total(lines, discount_percent=0):\n    subtotal = sum(qty * price for qty, price in lines)\n    return round(subtotal * (100 - discount_percent) / 100, 2)\n",
  "shopkit/store.py":
    "class Store:\n    def __init__(self):\n        self.stock = {}\n\n    def add(self, sku, qty):\n        self.stock[sku] = self.stock.get(sku, 0) + qty\n",
  "shopkit/cli.py": "import sys\n\nfrom .pricing import calc_total\n\n\ndef main():\n    print(calc_total([(1, float(a)) for a in sys.argv[1:]]))\n",
  "tests/test_pricing.py":
    "from shopkit.pricing import calc_total\n\n\ndef test_discount():\n    assert calc_total([(2, 5.0)], 10) == 9.0\n",
  "docs/design.md": "# Design\n\nPricing and stock are separate modules with no shared state.\n",
  "data/import_1.csv": "sku,qty\napple,1\nbanana,2\n",
};

/** A fresh repository on branch master with one commit. */
export function writeFixtureRepo(repo: string): void {
  for (const [path, text] of Object.entries(FIXTURE_FILES)) {
    mkdirSync(join(repo, path, ".."), { recursive: true });
    writeFileSync(join(repo, path), text);
  }
  git(repo, "init", "-q", "-b", "master");
  git(repo, "-c", "user.email=eval@example.com", "-c", "user.name=eval", "add", "-A");
  git(repo, "-c", "user.email=eval@example.com", "-c", "user.name=eval", "commit", "-q", "-m", "fixture");
}

function writeProfile(home: string): void {
  mkdirSync(join(home, ".fx", "skills", "pineapple-note"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission_mode: "auto" }) + "\n", { mode: 0o600 });
  // Every scenario has the same profile from turn 1, so only the event differs.
  writeFileSync(
    join(home, ".fx", "skills", "pineapple-note", "SKILL.md"),
    "---\nname: pineapple-note\ndescription: Demo skill with a visible effect. Use when asked for a pineapple note.\n---\n\n" +
      "# Pineapple note\n\nWhen this skill is active, end every reply with the word PINEAPPLE.\n",
  );
}

function runAsk(
  binary: string,
  args: string[],
  opts: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number },
): Promise<{ code: number | null; stdout: string }> {
  return new Promise((resolve) => {
    const child = spawn(binary, args, { cwd: opts.cwd, env: opts.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.resume();
    const timer = setTimeout(() => child.kill("SIGKILL"), opts.timeoutMs);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout });
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

/** Runs one scenario with `binary` and `model` in a fresh profile and repository. */
export async function runScenario(
  scenario: Scenario,
  opts: { binary: string; side: string; model: string; timeoutMs: number; upstream?: string },
): Promise<ScenarioRun> {
  const root = mkdtempSync(join(tmpdir(), `fx-cache-ab-${scenario.name}-`));
  const home = join(root, "home");
  const repo = join(root, "repo");
  mkdirSync(repo, { recursive: true });
  writeProfile(home);
  writeFixtureRepo(repo);
  const proxy = startRecordingProxy(opts.upstream);
  const run: ScenarioRun = { scenario: scenario.name, side: opts.side, model: opts.model, turns: [], requests: proxy.requests };
  const env: Record<string, string | undefined> = {
    ...process.env,
    HOME: home,
    NO_COLOR: "1",
    FX_SOUND: "0",
    FX_MODEL: opts.model,
    FX_MAX_AGENT_STEPS: "40",
    FX_GATEWAY_CHAT_URL: `${proxy.url}/v4/ai/language-model`,
    FX_GATEWAY_BASE_URL: proxy.url,
  };
  const turn = async (prompt: string, resume: boolean, fullAccess: boolean) => {
    const args = ["ask", ...(fullAccess ? ["--full-access"] : []), "--json", ...(resume ? ["--resume", "last"] : []), "--", prompt];
    const result = await runAsk(opts.binary, args, { cwd: repo, env, timeoutMs: opts.timeoutMs });
    // Let the proxy finish reading the last stream.
    await Bun.sleep(500);
    run.turns.push({ prompt, exit: result.code, output: finalOutput(result.stdout), requestsEnd: proxy.requests.length });
  };
  try {
    await turn(TURN1, false, true);
    scenario.afterTurn1?.(repo, home);
    for (const [index, prompt] of scenario.turns.entries()) {
      scenario.beforeTurn?.[index]?.(repo);
      await turn(prompt, true, !(scenario.defaultAccess ?? []).includes(index));
    }
  } finally {
    proxy.stop();
    rmSync(root, { recursive: true, force: true });
  }
  return run;
}

export interface RunSummary {
  scenario: string;
  side: string;
  model: string;
  exitedCleanly: boolean;
  agentRequests: number;
  prefixBreaks: number;
  newTokens: number;
  cacheRead: number;
  usageMissing: number;
  answersRight: boolean | null;
}

export function summarize(run: ScenarioRun, scenario: Scenario): RunSummary {
  const agent = run.requests.filter((r) => agentPrompt(r.body) !== null);
  return {
    scenario: run.scenario,
    side: run.side,
    model: run.model,
    exitedCleanly: run.turns.every((t) => t.exit === 0),
    agentRequests: agent.length,
    prefixBreaks: prefixBreaks(agent.map((r) => agentPrompt(r.body)!)).length,
    newTokens: agent.reduce((sum, r) => sum + (r.usage ? r.usage.noCache + r.usage.cacheWrite : 0), 0),
    cacheRead: agent.reduce((sum, r) => sum + (r.usage?.cacheRead ?? 0), 0),
    usageMissing: agent.filter((r) => r.usage === null).length,
    answersRight: scenario.check ? scenario.check(run) : null,
  };
}

export interface CacheAbConfig {
  baselineBin: string;
  candidateBin: string;
  models: string[];
  scenarios: Scenario[];
  outputDir: string;
  timeoutMs: number;
}

export function loadCacheAbConfigFromEnv(env: NodeJS.ProcessEnv = process.env): CacheAbConfig {
  const models = (env.FX_CACHE_AB_MODELS ?? "").split(",").map((m) => m.trim()).filter(Boolean);
  if (models.length === 0) throw new Error("FX_CACHE_AB_MODELS must name at least one model");
  const wanted = (env.FX_CACHE_AB_SCENARIOS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const scenarios = wanted.length === 0 ? SCENARIOS : wanted.map((name) => {
    const scenario = SCENARIOS.find((s) => s.name === name);
    if (!scenario) throw new Error(`unknown scenario ${name}`);
    return scenario;
  });
  return {
    baselineBin: requireAbsoluteExecutableBinary(env.FX_CACHE_AB_BASELINE_BIN ?? "", "baseline"),
    candidateBin: requireAbsoluteExecutableBinary(env.FX_CACHE_AB_CANDIDATE_BIN ?? "", "candidate"),
    models,
    scenarios,
    outputDir: env.FX_CACHE_AB_OUTPUT_DIR ?? mkdtempSync(join(tmpdir(), `fx-cache-ab-${Date.now()}-`)),
    timeoutMs: Number(env.FX_CACHE_AB_TIMEOUT_MS ?? "1800000"),
  };
}

/** Runs every scenario on both binaries for each model; writes one JSON file per run and a summary. */
export async function runCacheAbComparison(config = loadCacheAbConfigFromEnv()): Promise<RunSummary[]> {
  mkdirSync(config.outputDir, { recursive: true });
  const summaries: RunSummary[] = [];
  for (const model of config.models) {
    for (const scenario of config.scenarios) {
      for (const [side, binary] of [["baseline", config.baselineBin], ["candidate", config.candidateBin]] as const) {
        const run = await runScenario(scenario, { binary, side, model, timeoutMs: config.timeoutMs });
        const summary = summarize(run, scenario);
        summaries.push(summary);
        const file = `${model.replaceAll("/", "_")}-${scenario.name}-${side}.json`;
        writeFileSync(join(config.outputDir, file), JSON.stringify({ summary, run }, null, 2));
        console.log(JSON.stringify(summary));
      }
    }
  }
  writeFileSync(join(config.outputDir, "summary.json"), JSON.stringify(summaries, null, 2));
  console.log(`artifacts: ${config.outputDir}`);
  return summaries;
}
