// What each MCP path shows for a tool a deny rule names, by permission mode.
// One `fx ask` run per mode: a fake gateway scripts the model's calls (toolbox
// search, open of a small and of a large server, open and run of a tool, and
// a shell command's `fx mcp call` list, search, help and call), and each
// answer is read as shown or hidden. A subagent can run the same calls (its
// run saves the session, which subagents need).
// Shared by tests/e2e/mcp-stdio.test.ts and the TLA+ driver
// tests/tla/drivers/mcp_host/mcp-rules.test.ts.
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { contentText } from "./conditional-guidance-oracle";
import { startManyMcpHttpServers } from "./fixtures/mcp-many";
import { fakeGatewayFinalText, fakeGatewayToolCall, startDynamicFakeGateway } from "./tmux-helpers";

export type Mode = "full" | "auto" | "ask";
export type PathName =
  | "search" | "open_small" | "open_large" | "open_tool" | "run"
  | "bridge_list" | "bridge_search" | "bridge_help" | "bridge_call";

/** The small server's tool, the large server's tool, and a tool of the large server no rule names. */
export const SMALL_TOOL = "mcp_fixture_echo";
export const LARGE_TOOL = "mcp_big_tool_01";
export const OTHER_TOOL = "mcp_big_tool_02";
export const SMALL_RESULT = "MODERN_MCP_TOOL_RESULT";
export const LARGE_RESULT = "BIG_TOOL_RESULT";

export interface Observation { path: PathName; tool: string; shown: boolean; text: string }
export interface PathsRun {
  code: number; stdout: string; stderr: string;
  observations: Observation[];
  /** The text of each step's result, by step id, for the words a guard compares. */
  texts: Record<string, string>;
}
export interface PathsOptions {
  /** The fx binary under test. */
  bin: string;
  mode: Mode;
  /** Who makes the calls: the main agent, or a subagent it starts. */
  agent?: "main" | "child";
  /** The settings' `permission` object. */
  rules: Record<string, unknown>;
  /** A subagent's profile limits it to these servers. */
  childServers?: string[];
  /** A subagent's profile sets its own permission mode (the mode it runs in, else the host's). */
  childMode?: Mode;
  /** Skip the steps that need an approval (`ask` mode): only search and open. */
  readOnly?: boolean;
  /** The small server never starts (it exits at once). */
  down?: boolean;
  /** An extra scratch folder name. */
  label?: string;
}

interface Step { id: string; name: string; args: Record<string, unknown>; path: PathName; tool: string; shown: (text: string) => boolean }

const hidesTool = (tool: string) => (text: string) => text.includes(tool) && !text.includes("Nothing named") && !text.includes("No tool named") && !text.includes("No MCP tool named");

function steps(bin: string): Step[] {
  // Each stream goes to a file and is printed after the exit code, so the shell tool's merge of the two cannot interleave them.
  const sh = (command: string) => ({ action: "run", command: `${command} > out.txt 2> err.txt; echo "exit=$?"; cat out.txt; cat err.txt` });
  const mcp = (rest: string) => `"${bin}" mcp call ${rest}`;
  const out: Step[] = [];
  const add = (path: PathName, tool: string, name: string, args: Record<string, unknown>, shown: (text: string) => boolean) =>
    out.push({ id: `p_${path}_${tool}`, name, args, path, tool, shown });
  add("search", SMALL_TOOL, "toolbox", { search: "echo" }, (t) => t.includes(`"name":"${SMALL_TOOL}"`));
  add("search", LARGE_TOOL, "toolbox", { search: "tool_01" }, (t) => t.includes(`"name":"${LARGE_TOOL}"`));
  add("open_small", SMALL_TOOL, "toolbox", { open: "fixture" }, (t) => t.includes(`"name":"${SMALL_TOOL}"`));
  add("open_large", LARGE_TOOL, "toolbox", { open: "big" }, (t) => t.includes(LARGE_TOOL));
  add("open_large", OTHER_TOOL, "toolbox", { open: "big" }, (t) => t.includes(OTHER_TOOL));
  add("open_tool", SMALL_TOOL, "toolbox", { open: SMALL_TOOL }, hidesTool(SMALL_TOOL));
  add("open_tool", LARGE_TOOL, "toolbox", { open: LARGE_TOOL }, hidesTool(LARGE_TOOL));
  add("open_tool", OTHER_TOOL, "toolbox", { open: OTHER_TOOL }, hidesTool(OTHER_TOOL));
  add("run", SMALL_TOOL, "toolbox", { run: SMALL_TOOL, arguments: { text: "hello" } }, (t) => t.includes(SMALL_RESULT));
  add("run", LARGE_TOOL, "toolbox", { run: LARGE_TOOL, arguments: { text: "hello" } }, (t) => t.includes(LARGE_RESULT));
  add("run", OTHER_TOOL, "toolbox", { run: OTHER_TOOL, arguments: { text: "hello" } }, (t) => t.includes(LARGE_RESULT));
  add("bridge_list", SMALL_TOOL, "shell", sh(mcp("list fixture")), (t) => t.includes(SMALL_TOOL));
  add("bridge_list", LARGE_TOOL, "shell", sh(mcp("list big")), (t) => t.includes(LARGE_TOOL));
  add("bridge_search", SMALL_TOOL, "shell", sh(mcp("search echo")), (t) => t.includes(SMALL_TOOL));
  add("bridge_search", LARGE_TOOL, "shell", sh(mcp("search tool_01")), (t) => t.includes(LARGE_TOOL));
  add("bridge_help", SMALL_TOOL, "shell", sh(mcp(`help ${SMALL_TOOL}`)), (t) => !t.includes("No MCP tool named") && !t.includes("exit=1"));
  add("bridge_help", LARGE_TOOL, "shell", sh(mcp(`help ${LARGE_TOOL}`)), (t) => !t.includes("No MCP tool named") && !t.includes("exit=1"));
  add("bridge_call", SMALL_TOOL, "shell", sh(mcp(`${SMALL_TOOL} '{"text":"hello"}'`)), (t) => t.includes(SMALL_RESULT));
  add("bridge_call", LARGE_TOOL, "shell", sh(mcp(`${LARGE_TOOL} '{"text":"hello"}'`)), (t) => t.includes(LARGE_RESULT));
  add("bridge_call", OTHER_TOOL, "shell", sh(mcp(`${OTHER_TOOL} '{"text":"hello"}'`)), (t) => t.includes(LARGE_RESULT));
  return out;
}

function resultOf(body: string, id: string): string | null {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
  const part = prompt
    .flatMap((m) => (Array.isArray(m.content) ? m.content : []) as Array<Record<string, unknown>>)
    .find((p) => p.type === "tool-result" && p.toolCallId === id);
  return part ? contentText(part.output) : null;
}

const MODEL = "openai/gpt-5";

export async function runPaths(options: PathsOptions): Promise<PathsRun> {
  const agent = options.agent ?? "main";
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-mcp-rules-${options.label ?? options.mode}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx", "agents", "limited"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const many = startManyMcpHttpServers({ servers: 1, toolsPerServer: 12, resultText: LARGE_RESULT });
  const fixture = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: options.rules }));
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({ mcp: {
      fixture: { type: "local", command: options.down ? [process.execPath, "-e", "process.exit(0)"] : [process.execPath, fixture], enabled: true },
      big: { type: "http", url: many.url(0) },
    } }),
  );
  writeFileSync(
    join(home, ".fx", "agents", "limited", "profile.json"),
    JSON.stringify({
      description: "Uses the servers it is limited to",
      mcp_servers: options.childServers ?? ["fixture", "big"],
      ...(options.childMode ? { permission_mode: options.childMode === "full" ? "full-access" : options.childMode } : {}),
    }),
  );
  const all = steps(options.bin).filter((s) => !options.readOnly || s.name === "toolbox" && !("run" in s.args));
  const texts: Record<string, string> = {};
  // The parent's turn waits until the subagent's last step, so fx ask stays alive for it.
  let releaseParent: (response: Response) => void = () => {};
  const parentHold = new Promise<Response>((resolve) => { releaseParent = resolve; });
  const gateway = startDynamicFakeGateway(
    async (body) => {
      if (body.includes("Subagent report (untrusted agent output")) return fakeGatewayFinalText("PARENT_DONE");
      const parent = agent === "child" && (!body.includes("CHILD_TASK") || body.includes('"toolCallId":"start_child"'));
      if (parent) {
        if (body.includes('"toolCallId":"start_child"')) return parentHold;
        return fakeGatewayToolCall("start_child", "subagent", {
          request: { action: "message", agent: "worker", ...(options.childServers || options.childMode ? { profile: "limited" } : {}), message: "CHILD_TASK" },
        });
      }
      for (const step of all) {
        const r = resultOf(body, step.id);
        if (r !== null) texts[step.id] = r;
      }
      for (const step of all) if (resultOf(body, step.id) === null) return fakeGatewayToolCall(step.id, step.name, step.args);
      if (agent === "child") releaseParent(fakeGatewayFinalText("PARENT_SENT"));
      return fakeGatewayFinalText(agent === "child" ? "CHILD_DONE" : "MAIN_DONE");
    },
    { classifierDecision: "clear", models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  try {
    const flag = options.mode === "full" ? ["--full-access"] : options.mode === "auto" ? ["--auto"] : [];
    const proc = Bun.spawn([options.bin, "ask", "--json", ...flag, ...(agent === "child" ? [] : ["--no-save"]), agent === "child" ? "Start the worker." : "Go."], {
      cwd: workspace,
      stdout: "pipe",
      stderr: "pipe",
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        HOME: home,
        TMPDIR: process.env.TMPDIR ?? "/tmp",
        AI_GATEWAY_API_KEY: "fake-mcp-rules-key",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_E2E_DISABLE_DOTENV: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: MODEL,
        ...(options.mode === "ask" ? { FX_PERMISSION_MODE: "ask" } : {}),
      },
    });
    const timer = setTimeout(() => proc.kill(), 150_000);
    const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    clearTimeout(timer);
    const observations = all
      .filter((s) => texts[s.id] !== undefined)
      .map((s) => ({ path: s.path, tool: s.tool, shown: s.shown(texts[s.id]!), text: texts[s.id]! }));
    return { code, stdout, stderr, observations, texts };
  } finally {
    gateway.stop();
    many.stop();
  }
}

/** The observation of one path and tool; throws when the run did not reach it. */
export function seen(run: PathsRun, path: PathName, tool: string): Observation {
  const found = run.observations.find((o) => o.path === path && o.tool === tool);
  if (!found) throw new Error(`the run never reached ${path} for ${tool}; exit ${run.code}: ${run.stderr.slice(-300)}`);
  return found;
}
