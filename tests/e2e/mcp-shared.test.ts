import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import { fakeGatewayFinalText, fakeGatewayToolCall, startFakeGateway } from "./tmux-helpers";

// Sessions share a stdio MCP server through one owner process: one copy per
// launch config, one owner per profile, and a project server per repo.

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const OWNER_MARK = "--fx-internal-mcp-owner";
const CALL_TIMEOUT_MS = 75_000;

type Gateway = ReturnType<typeof startFakeGateway>;
type Root = {
  root: string;
  home: string;
  workspace: string;
  /** The profile folder the owner's socket lives under. */
  fxHome: string;
  profile: string;
  wire: string;
  pid: string;
};

type WireEntry = { pid: number; message: { method?: string; params?: { _meta?: Record<string, unknown> } } };

let cleanupRoot: string | null = null;
let gateways: Gateway[] = [];
let cleanupPids = new Set<number>();

afterEach(async () => {
  for (const pid of cleanupPids) if (isRunning(pid)) process.kill(pid, "SIGKILL");
  cleanupPids = new Set();
  for (const gateway of gateways) gateway.stop();
  gateways = [];
  if (cleanupRoot) rmSync(cleanupRoot, { recursive: true, force: true });
  cleanupRoot = null;
});

/**
 * A root with its own profile. The folder sits under `/tmp` so the owner's
 * socket path stays inside a Unix address's limit on macOS too.
 */
function createRoot(
  label: string,
  options: { shared?: boolean; callDelayMs?: number; mode?: string; profileServer?: boolean } = {},
): Root {
  const root = mkdtempSync(join("/tmp", `fxs-${label}-`));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const fxHome = join(home, ".fx");
  const profile = join(fxHome, "mcp.json");
  const wire = join(root, "mcp-wire.jsonl");
  const pid = join(root, "mcp.pid");
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), "{}");
  if (options.profileServer !== false) {
    writeFileSync(
      profile,
      JSON.stringify({
        mcp: {
          fixture: {
            command: process.execPath,
            args: [FIXTURE],
            enabled: true,
            // Only an opt-out is written; true is the default.
            ...(options.shared === false ? { shared: false } : {}),
            environment: {
              FX_MCP_WIRE_LOG: wire,
              FX_MCP_PID_PATH: pid,
              FX_MCP_CALL_DELAY_MS: String(options.callDelayMs ?? 0),
              FX_MCP_MODE: options.mode ?? "normal",
            },
          },
        },
      }),
    );
  }
  return { root, home, workspace, fxHome, profile, wire, pid };
}

function gatewayFor(finalText: string): Gateway {
  const gateway = startFakeGateway([
    fakeGatewayToolCall("select_mcp", "toolbox", { open: TOOL_NAME }),
    fakeGatewayToolCall("call_mcp", "toolbox", { run: TOOL_NAME, arguments: { text: "shared" } }),
    fakeGatewayFinalText(finalText),
  ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  gateways.push(gateway);
  return gateway;
}

function envFor(root: Root, gateway: Gateway) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-mcp-shared-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "auto",
    FX_DISABLE_KEYCHAIN: "1",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
  };
}

function ask(root: Root, gateway: Gateway, prompt: string, cwd = root.workspace, timeoutMs = CALL_TIMEOUT_MS) {
  return runFx(["ask", "--json", "--auto", "--no-save", prompt], {
    cwd,
    env: envFor(root, gateway),
    timeoutMs,
  });
}

function readWire(path: string): WireEntry[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as WireEntry);
}

function serverPids(path: string): number[] {
  // Every message a server logs names its process, so a list or a call shows
  // which server ran it.
  return [...new Set(readWire(path).map((entry) => entry.pid))];
}

function toolCalls(path: string): WireEntry[] {
  return readWire(path).filter((entry) => entry.message.method === "tools/call");
}

/** The text fx sent the model as one tool call's result. */
function toolResultText(body: string, callId: string): string {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
  const part = prompt
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []) as Array<Record<string, unknown>>)
    .find((item) => item.type === "tool-result" && item.toolCallId === callId);
  if (!part) throw new Error(`missing the tool result for ${callId}`);
  return contentText(part.output);
}

function isRunning(pid: number): boolean {
  // A killed process stays visible until its parent reaps it, so a running
  // one must also have a state. `ps` names both.
  const out = Bun.spawnSync(["ps", "-o", "stat=", "-p", String(pid)]).stdout.toString().trim();
  return out.length > 0 && !out.startsWith("Z");
}

async function waitFor(label: string, predicate: () => boolean, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    // Polls the state the predicate reads, bounded by the deadline.
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${label}`);
}

/** Every owner process for `fxHome`, by its arguments. */
function ownerPids(fxHome: string): number[] {
  const listed = Bun.spawnSync(["ps", "-eo", "pid,stat,args"]).stdout.toString();
  const found: number[] = [];
  for (const line of listed.split("\n")) {
    if (!line.includes(OWNER_MARK) || !line.includes(fxHome)) continue;
    const [pidText, stat] = line.trim().split(/\s+/);
    const pid = Number(pidText);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    if (stat.startsWith("Z")) continue;
    found.push(pid);
  }
  return found;
}

/** Collects every owner seen while `poll` runs, so an owner that exits counts too. */
function watchOwners(fxHome: string) {
  const seen = new Set<number>();
  const poll = setInterval(() => {
    for (const pid of ownerPids(fxHome)) seen.add(pid);
  }, 50);
  return {
    stop: () => {
      clearInterval(poll);
      for (const pid of ownerPids(fxHome)) seen.add(pid);
      return [...seen];
    },
  };
}

function parentOf(pid: number): number {
  const out = Bun.spawnSync(["ps", "-o", "ppid=", "-p", String(pid)]).stdout.toString().trim();
  return Number(out);
}

async function expectExited(pids: Iterable<number>, timeoutMs = 5_000) {
  const unique = [...new Set(pids)].filter((pid) => pid > 0);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (unique.every((pid) => !isRunning(pid))) return;
    // Polls each process's exit, bounded by the deadline.
    await Bun.sleep(25);
  }
  throw new Error(`processes did not exit: ${unique.filter(isRunning).join(", ")}`);
}

describe("shared MCP servers", () => {
  test("two fx processes share one stdio server", async () => {
    // A slow call keeps the first session's server busy while the second
    // joins, so both calls run on it at once.
    const root = createRoot("pair", { callDelayMs: 2_000 });
    const owners = watchOwners(root.fxHome);
    const first = ask(root, gatewayFor("PAIR_FIRST_DONE"), "Call the shared MCP tool.");
    const second = ask(root, gatewayFor("PAIR_SECOND_DONE"), "Call the shared MCP tool too.");
    // One server is up for both sessions, run by one owner.
    await waitFor("the server", () => serverPids(root.wire).length >= 1);
    const [serverPid] = serverPids(root.wire);
    cleanupPids.add(serverPid!);
    const runningOwners = ownerPids(root.fxHome);
    expect(runningOwners).toHaveLength(1);
    expect(parentOf(serverPid!)).toBe(runningOwners[0]!);

    const [one, two] = await Promise.all([first, second]);
    const seenOwners = owners.stop();
    expect(one.code, one.stderr || one.stdout).toBe(0);
    expect(two.code, two.stderr || two.stdout).toBe(0);
    expect(JSON.parse(one.stdout).output).toContain("PAIR_FIRST_DONE");
    expect(JSON.parse(two.stdout).output).toContain("PAIR_SECOND_DONE");
    const calls = toolCalls(root.wire);
    expect(calls).toHaveLength(2);
    // Both sessions' calls ran on the one server.
    expect(new Set(calls.map((call) => call.pid)).size).toBe(1);
    // One owner ran both sessions, from start to end.
    expect(seenOwners).toHaveLength(1);
    // The server runs under the owner, and hears the same client a session's
    // own copy sends: fx, with the version this binary prints. The 2026 first
    // request carries it in its metadata; `initialize` is the legacy fallback.
    const version = (await runFx(["--version"])).stdout.trim();
    const discover = readWire(root.wire).find((entry) => entry.message.method === "server/discover");
    expect(discover?.message.params?._meta?.["io.modelcontextprotocol/clientInfo"]).toEqual({ name: "fx", version });

    // Both sessions are gone: the server stops and the owner exits.
    await expectExited([serverPid!, ...seenOwners]);
  }, 120_000);

  test("a project server in two repos starts one copy per repo", async () => {
    const root = createRoot("repos", { profileServer: false });
    const repos = ["alpha", "beta"].map((name) => {
      const repo = join(root.root, name);
      mkdirSync(repo, { recursive: true });
      writeFileSync(
        join(repo, ".mcp.json"),
        JSON.stringify({
          mcpServers: {
            fixture: {
              command: process.execPath,
              args: [FIXTURE],
              env: {
                FX_MCP_WIRE_LOG: root.wire,
                FX_MCP_PID_PATH: root.pid,
                // Slow enough that both copies are still running while their
                // parents and start directories are read.
                FX_MCP_CALL_DELAY_MS: "3000",
              },
            },
          },
        }),
      );
      return repo;
    });
    const alphaGateway = gatewayFor("REPOS_ALPHA_DONE");
    const betaGateway = gatewayFor("REPOS_BETA_DONE");
    for (const repo of repos) {
      const approved = await runFx(["mcp", "approve", "fixture"], {
        cwd: repo,
        env: envFor(root, alphaGateway),
      });
      expect(approved.code, approved.stderr).toBe(0);
    }

    const owners = watchOwners(root.fxHome);
    const resultsPromise = Promise.all([
      ask(root, alphaGateway, "Call the project MCP tool.", repos[0]),
      ask(root, betaGateway, "Call the project MCP tool.", repos[1]),
    ]);
    // Each repo runs its own copy, both under the one owner.
    await waitFor("both servers", () => serverPids(root.wire).length >= 2);
    const pids = serverPids(root.wire);
    const runningOwners = ownerPids(root.fxHome);
    expect(runningOwners).toHaveLength(1);
    for (const pid of pids) expect(parentOf(pid)).toBe(runningOwners[0]!);
    if (process.platform === "linux") {
      const cwds = pids.map((pid) => readlinkSync(`/proc/${pid}/cwd`));
      expect(cwds.sort()).toEqual(repos.map((repo) => realpathSync(repo)).sort());
    }
    const results = await resultsPromise;
    const seenOwners = owners.stop();
    for (const pid of pids) cleanupPids.add(pid);
    for (const result of results) expect(result.code, result.stderr || result.stdout).toBe(0);
    expect(JSON.parse(results[0]!.stdout).output).toContain("REPOS_ALPHA_DONE");
    expect(JSON.parse(results[1]!.stdout).output).toContain("REPOS_BETA_DONE");
    // The same launch config in two repos has two start directories, so two
    // keys and two servers, both in the one owner.
    expect(seenOwners).toHaveLength(1);

    await expectExited([...pids, ...seenOwners]);
  }, 120_000);

  test("shared false keeps one server per fx process", async () => {
    const root = createRoot("private", { shared: false, callDelayMs: 2_000 });
    const owners = watchOwners(root.fxHome);
    const first = ask(root, gatewayFor("PRIVATE_FIRST_DONE"), "Call the private MCP tool.");
    const second = ask(root, gatewayFor("PRIVATE_SECOND_DONE"), "Call the private MCP tool too.");
    await waitFor("both servers", () => serverPids(root.wire).length >= 2);
    const pids = serverPids(root.wire);
    for (const pid of pids) cleanupPids.add(pid);
    const [one, two] = await Promise.all([first, second]);
    const seenOwners = owners.stop();

    expect(one.code, one.stderr || one.stdout).toBe(0);
    expect(two.code, two.stderr || two.stdout).toBe(0);
    const calls = toolCalls(root.wire);
    expect(calls).toHaveLength(2);
    expect(new Set(calls.map((call) => call.pid)).size).toBe(2);
    // Nothing opted in, so no owner was started at all.
    expect(seenOwners).toEqual([]);
    await expectExited(pids);
  }, 120_000);

  test("an owner killed during a call leaves that call lost and the next call working", async () => {
    // The call never answers, so it is in flight when the owner dies.
    const root = createRoot("kill", { mode: "stall_operation" });
    const firstGateway = gatewayFor("KILLED_CALL_DONE");
    const first = ask(root, firstGateway, "Call the shared MCP tool.");
    // The fixture lists its tools, then the call arrives and stalls.
    await waitFor("the stuck call", () => toolCalls(root.wire).length >= 1);
    const [serverPid] = serverPids(root.wire);
    cleanupPids.add(serverPid!);
    await waitFor("the owner", () => ownerPids(root.fxHome).length > 0);
    const [owner] = ownerPids(root.fxHome);
    cleanupPids.add(owner!);
    process.kill(owner!, "SIGKILL");
    await waitFor("the owner to die", () => ownerPids(root.fxHome).length === 0);

    const lost = await first;
    expect(lost.code, lost.stderr || lost.stdout).toBe(0);
    const body = firstGateway.requests.at(-1)?.body ?? "";
    expect(toolResultText(body, "call_mcp")).toContain(
      "MCP server 'fixture' ended the call: the server went away. The tool may have run.",
    );

    // The next call starts a new owner and a new server.
    const profile = JSON.parse(readFileSync(root.profile, "utf8"));
    profile.mcp.fixture.environment.FX_MCP_MODE = "normal";
    writeFileSync(root.profile, JSON.stringify(profile));
    const second = await ask(root, gatewayFor("NEXT_CALL_DONE"), "Call the shared MCP tool again.");
    expect(second.code, second.stderr || second.stdout).toBe(0);
    expect(JSON.parse(second.stdout).output).toContain("NEXT_CALL_DONE");
    const calls = toolCalls(root.wire);
    expect(calls).toHaveLength(2);
    const secondPid = calls[1]!.pid;
    cleanupPids.add(secondPid);
    expect(secondPid).not.toBe(calls[0]!.pid);

    await expectExited([serverPid!, secondPid, ...ownerPids(root.fxHome)]);
  }, 120_000);
});
