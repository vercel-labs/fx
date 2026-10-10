import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

// `fx mcp` on MCP-v2. Sign-in is covered in mcp-auth.test.ts.

const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");

let cleanup: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;

afterEach(async () => {
  if (tui) await tui.kill();
  tui = null;
  gateway?.stop();
  gateway = null;
  if (cleanup) rmSync(cleanup, { recursive: true, force: true });
  cleanup = null;
});

function isRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function createRoot(profile?: unknown, project?: unknown) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mcp-verbs-")));
  cleanup = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  if (profile !== undefined) writeFileSync(join(home, ".fx", "mcp.json"), typeof profile === "string" ? profile : JSON.stringify(profile));
  if (project !== undefined) writeFileSync(join(workspace, ".mcp.json"), JSON.stringify(project));
  return {
    home,
    workspace,
    profilePath: join(home, ".fx", "mcp.json"),
    projectPath: join(workspace, ".mcp.json"),
    env: {
      HOME: home,
      FX_MCP_ENGINE: "v2",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      AI_GATEWAY_API_KEY: "fake-mcp-verbs-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_MCP_PROTOCOL_VERSION: undefined,
    },
  };
}

type Root = ReturnType<typeof createRoot>;

function mcp(root: Root, ...args: string[]) {
  return runFx(["mcp", ...args], { cwd: root.workspace, env: root.env, timeoutMs: 20_000 });
}

const fixtureServer = (extra: Record<string, unknown> = {}) => ({
  command: process.execPath,
  args: [MODERN_FIXTURE],
  env: { FX_MCP_SPEC_CLIENT: "1" },
  ...extra,
});

describe("fx mcp on MCP-v2", () => {
  test("add writes each file and keeps every key it doesn't know", async () => {
    // Raw text, so the number's spelling reaches fx as written.
    const root = createRoot('{"theme":"dark","mcp":{"old":{"command":"true","environment":{"A":"1"},"startup_timeout_ms":1.50}}}');
    writeFileSync(root.projectPath, '{"mcpServers":{},"note":"shared"}');
    chmodSync(root.projectPath, 0o640);

    const http = await mcp(root, "add", "web", "https://mcp.example/mcp", "--header", "X-Key=${KEY}");
    expect(http.stderr).toBe("");
    expect(http.code).toBe(0);
    expect(http.stdout).toBe("Added web to ~/.fx/mcp.json.\n");
    const stdio = await mcp(root, "add", "--project", "--env", "TOKEN=x", "local", "--", "node", "server.js", "-h");
    expect(stdio.code).toBe(0);
    expect(stdio.stdout).toBe("Added local to .mcp.json.\n");

    const profileText = readFileSync(root.profilePath, "utf8");
    expect(profileText).toContain('"startup_timeout_ms": 1.50');
    expect(JSON.parse(profileText)).toEqual({
      theme: "dark",
      mcp: {
        old: { command: "true", environment: { A: "1" }, startup_timeout_ms: 1.5 },
        web: { type: "http", url: "https://mcp.example/mcp", headers: { "X-Key": "${KEY}" } },
      },
    });
    expect(JSON.parse(readFileSync(root.projectPath, "utf8"))).toEqual({
      mcpServers: { local: { command: "node", args: ["server.js", "-h"], env: { TOKEN: "x" } } },
      note: "shared",
    });
    expect(statSync(root.profilePath).mode & 0o777).toBe(0o600);
    expect(statSync(root.projectPath).mode & 0o777).toBe(0o640);
  });

  test("add refuses a name that's there, a file it can't read, and a bad name", async () => {
    const root = createRoot({ mcpServers: { web: { type: "http", url: "https://a/mcp" } } });
    const before = readFileSync(root.profilePath, "utf8");
    const taken = await mcp(root, "add", "web", "https://b/mcp");
    expect(taken.code).toBe(1);
    expect(taken.stderr).toBe("Couldn't add web to ~/.fx/mcp.json: that name is already in the file; remove it first.\n");
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);

    writeFileSync(root.profilePath, '{"mcpServers":{},"mcpServers":{}}');
    const broken = await mcp(root, "add", "other", "https://b/mcp");
    expect(broken.code).toBe(1);
    expect(broken.stderr).toContain("isn't valid JSON, or repeats a key");
    expect(readFileSync(root.profilePath, "utf8")).toBe('{"mcpServers":{},"mcpServers":{}}');

    const bad = await mcp(root, "add", "bad name", "https://b/mcp");
    expect(bad.code).toBe(2);
    expect(bad.stderr).toStartWith("'bad name' can't be a server name: use letters, digits, '-' and '_'.\nusage: fx mcp add ");
    const notUrl = await mcp(root, "add", "web2", "mcp.example");
    expect(notUrl.code).toBe(2);
    expect(notUrl.stderr).toStartWith("'mcp.example' isn't a URL. A stdio server's command goes after --.\n");
  });

  test("list shows each server's file, transport, and status without connecting", async () => {
    const root = createRoot(
      {
        mcpServers: {
          ctx: { type: "http", url: "https://mcp.example/mcp" },
          off: { command: "never-run", enabled: false },
          sse: { type: "sse", url: "https://old.example/sse" },
          keyed: { type: "http", url: "https://k.example/mcp", bearer_token_env: "MISSING_TOKEN" },
        },
      },
      { mcpServers: { docs: { command: "never-run" } } },
    );
    const text = await mcp(root, "list");
    expect(text.stderr).toBe("");
    expect(text.code).toBe(0);
    expect(text.stdout).toBe(
      [
        "NAME   SOURCE          TRANSPORT  STATUS",
        "ctx    ~/.fx/mcp.json  http       not started",
        "off    ~/.fx/mcp.json  stdio      disabled",
        "sse    ~/.fx/mcp.json  sse        not supported",
        "keyed  ~/.fx/mcp.json  http       needs $MISSING_TOKEN",
        "docs   .mcp.json       stdio      waiting for approval",
        "",
      ].join("\n"),
    );
    const json = await mcp(root, "list", "--json");
    expect(json.code).toBe(0);
    const servers = JSON.parse(json.stdout).servers;
    expect(servers.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["ctx", "not_started"],
      ["off", "disabled"],
      ["sse", "not_supported"],
      ["keyed", "missing_env"],
      ["docs", "waiting_for_approval"],
    ]);
    expect(servers[4]).toMatchObject({ source: "project", file: root.projectPath, transport: "stdio", tools: null, error: null });

    // A server whose ${VAR} isn't set is skipped, and list says why.
    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { docs: { command: "x", args: ["${FX_VERBS_UNSET}"] } } }));
    await mcp(root, "approve", "docs");
    const noted = await mcp(root, "list");
    expect(noted.code).toBe(0);
    expect(noted.stderr).toBe("note: .mcp.json server 'docs' field argument requires environment variable 'FX_VERBS_UNSET'; set it or use ${FX_VERBS_UNSET:-default}.\n");
    expect(noted.stdout).not.toContain("docs");

    // fx won't send a token written into an Authorization header.
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { bad: { type: "http", url: "https://b/mcp", headers: { Authorization: "Bearer x" } } } }));
    const refused = await mcp(root, "list");
    expect(refused.code).toBe(1);
    expect(refused.stderr).toBe("fx mcp: a server in ~/.fx/mcp.json has headers fx won't send; put a token in bearer_token_env, or sign in with login\n");

    const empty = await mcp(createRoot(), "list");
    expect(empty.code).toBe(0);
    expect(empty.stdout).toBe("No MCP servers configured. Add one with: fx mcp add NAME URL\n");
  });

  test("show connects to a server and lists its tools; a broken one exits 1", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer(), broken: { command: "fx-mcp-verbs-missing-binary" } } });
    const text = await mcp(root, "show", "fixture");
    expect(text.stderr).toBe("");
    expect(text.code).toBe(0);
    expect(text.stdout).toMatch(/^fixture\n  status     ready, \d+ tools?\n  version    2026-07-28\n  transport  stdio\n  command    /);
    expect(text.stdout).toMatch(/\n    echo +Echo text through the modern MCP fixture\n/);

    const json = await mcp(root, "show", "fixture", "--json");
    expect(json.code).toBe(0);
    const shown = JSON.parse(json.stdout);
    expect(shown).toMatchObject({ name: "fixture", status: "ready", version: "2026-07-28", url: null });
    expect(shown.tools).toContainEqual({ name: "echo", description: "Echo text through the modern MCP fixture" });

    const broken = await mcp(root, "show", "broken");
    expect(broken.code).toBe(1);
    expect(broken.stdout).toMatch(/status     (failed|retrying)\n/);
    expect(broken.stdout).toMatch(/\n  error      .+\n/);

    const unknown = await mcp(root, "show", "nope");
    expect(unknown.code).toBe(1);
    expect(unknown.stderr).toBe("No MCP server named nope. fx mcp list shows them.\n");
  });

  test("${VAR} works in the profile too", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ args: ["${FX_VERBS_FIXTURE}"] }) } });
    root.env = { ...root.env, FX_VERBS_FIXTURE: MODERN_FIXTURE } as typeof root.env;
    const shown = await mcp(root, "show", "fixture");
    expect(shown.stderr).toBe("");
    expect(shown.code).toBe(0);
    expect(shown.stdout).toContain("status     ready");
  });

  test("remove finds the server's file, and asks when both files have it", async () => {
    const root = createRoot(
      { mcpServers: { twin: { command: "a" }, solo: { command: "b" } }, other: 1 },
      { mcpServers: { twin: { command: "c" } } },
    );
    const both = await mcp(root, "remove", "twin");
    expect(both.code).toBe(2);
    expect(both.stderr).toBe("twin is in both ~/.fx/mcp.json and .mcp.json. Add --profile or --project.\n");

    const project = await mcp(root, "remove", "--project", "twin");
    expect(project.code).toBe(0);
    expect(project.stdout).toBe("Removed twin from .mcp.json.\n");
    expect(JSON.parse(readFileSync(root.projectPath, "utf8"))).toEqual({ mcpServers: {} });

    const solo = await mcp(root, "remove", "solo");
    expect(solo.code).toBe(0);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8"))).toEqual({ mcpServers: { twin: { command: "a" } }, other: 1 });

    const gone = await mcp(root, "remove", "solo");
    expect(gone.code).toBe(1);
    expect(gone.stderr).toBe("No MCP server named solo in ~/.fx/mcp.json or .mcp.json.\n");
  });

  test("approve and reject say exactly what they trust", async () => {
    const root = createRoot(
      { mcpServers: { mine: { command: "x" } } },
      { mcpServers: { docs: { command: "node", args: ["docs server.js"] }, web: { type: "http", url: "https://w.example/mcp" } } },
    );
    const approved = await mcp(root, "approve", "docs");
    expect(approved.stderr).toBe("");
    expect(approved.code).toBe(0);
    expect(approved.stdout).toBe("Approved docs, which runs: node 'docs server.js'\n");

    const rejected = await mcp(root, "reject", "web");
    expect(rejected.code).toBe(0);
    expect(rejected.stdout).toBe("Rejected web. fx won't start it in this project.\n");

    const all = await mcp(root, "approve", "--all");
    expect(all.code).toBe(0);
    expect(all.stdout).toBe("Approved docs, which runs: node 'docs server.js'\n");

    const list = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(list.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["mine", "not_started"],
      ["docs", "not_started"],
      ["web", "rejected"],
    ]);

    const profileServer = await mcp(root, "approve", "mine");
    expect(profileServer.code).toBe(1);
    expect(profileServer.stderr).toBe("No project server named mine in .mcp.json.\n");
  });

  test("help, usage mistakes, and old verbs", async () => {
    const root = createRoot();
    const overview = await mcp(root);
    expect(overview.code).toBe(0);
    expect(overview.stdout).toStartWith("usage: fx mcp COMMAND\n\n  list [--json]               configured servers; never connects\n");
    const verbHelp = await mcp(root, "remove", "-h");
    expect(verbHelp.code).toBe(0);
    expect(verbHelp.stdout).toBe("usage: fx mcp remove [--project | --profile] NAME\n");

    const unknownVerb = await mcp(root, "nope");
    expect(unknownVerb.code).toBe(2);
    expect(unknownVerb.stderr).toStartWith("'nope' isn't a fx mcp command.\nusage: fx mcp COMMAND\n");
    const badFlag = await mcp(root, "logout", "--json", "x");
    expect(badFlag.code).toBe(2);
    expect(badFlag.stderr).toBe("fx mcp logout has no --json flag.\nusage: fx mcp logout NAME\n");

    for (const [args, message] of [
      [["auth", "x"], "fx mcp auth is now fx mcp login NAME.\n"],
      [["trust", "approve", "x"], "fx mcp trust is now fx mcp approve NAME and fx mcp reject NAME.\n"],
      [["path"], "fx mcp path is gone: fx mcp list shows each server's file.\n"],
      [["list", "--connect"], "fx mcp list --connect is now fx mcp show NAME.\n"],
    ] as const) {
      const old = await mcp(root, ...args);
      expect(old.code).toBe(2);
      expect(old.stderr).toBe(message);
      expect(old.stdout).toBe("");
    }
    expect(existsSync(root.profilePath)).toBe(false);
  });
});

describe("/mcp in the shell on MCP-v2", () => {
  test.skipIf(!tmuxAvailable())("/mcp runs the same verbs and prints the same text", async () => {
    // The shell can ask questions, so it says so to servers.
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_SPEC_CLIENT: "1", FX_MCP_EXPECT_ELICITATION: "both" } }) } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);

    await tui.sendText("/mcp list");
    await tui.waitForText("fixture  ~/.fx/mcp.json  stdio      not started", 10_000);
    await tui.sendText("/mcp show fixture");
    await tui.waitForText("Echo text through the modern MCP fixture", 15_000);
    await tui.waitForText("version    2026-07-28", 5_000);

    // Completion: the verbs, then the servers each verb takes.
    await tui.sendLiteral("/mcp ");
    await tui.waitForText("connect to a server and list its tools", 10_000);
    await tui.sendLiteral("show ");
    await tui.waitForText("show fixture", 10_000);
    await tui.sendKeys("C-u");
    await tui.sendLiteral("/mcp login ");
    await Bun.sleep(600);
    expect(await tui.capturePane()).not.toContain("login fixture");
    await tui.sendKeys("C-u");

    await tui.sendText("/mcp add web https://w.example/mcp");
    await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
    await tui.sendText("/mcp list");
    await tui.waitForText("web      ~/.fx/mcp.json  http       not started", 10_000);
    await tui.waitForText("ready, ", 5_000);

    await tui.sendText("/mcp nope");
    await tui.waitForText("'nope' isn't a /mcp command.", 10_000);
    await tui.sendText("/mcp list --json");
    await tui.waitForText("/mcp list has no --json flag.", 10_000);
    await tui.sendText("/mcp auth web");
    await tui.waitForText("/mcp auth is now /mcp login NAME.", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toEqual({ type: "http", url: "https://w.example/mcp" });
  }, 90_000);

  test.skipIf(!tmuxAvailable())("startup names waiting project servers and config problems once", async () => {
    const root = createRoot(
      { mcpServers: { docs: { command: "node", args: ["s.js", "${DOCS_TOKEN}"] } } },
      { mcpServers: { broken: { command: "nope" }, proj: { command: "node", args: ["p.js"] } } },
    );
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 140,
      height: 36,
      env: { ...root.env, DOCS_TOKEN: undefined, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    // A notice, not a prompt: the composer is free.
    await tui.waitForComposer(15_000);
    const waiting = "This project has 2 MCP servers waiting for approval: broken, proj. Use /mcp approve NAME.";
    const note = "server 'docs' field argument requires environment variable 'DOCS_TOKEN'";
    await tui.waitForText(waiting, 10_000);
    await tui.waitForText(note, 5_000);

    // A reload says nothing about what didn't change.
    await tui.sendText("/mcp add web https://w.example/mcp");
    await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
    await tui.sendText("/mcp approve proj");
    await tui.waitForText("Approved proj, which runs: node p.js", 10_000);
    await Bun.sleep(800);
    const scrollback = await tui.captureFullScrollback();
    expect(scrollback.split(waiting).length - 1).toBe(1);
    expect(scrollback.split(note).length - 1).toBe(1);
    expect(scrollback).not.toContain("waiting for approval: broken.");
  }, 60_000);

  test.skipIf(!tmuxAvailable())("quitting waits for no server: each gets SIGTERM", async () => {
    // Only SIGTERM ends it: it never reads stdin, and never answers.
    const root = createRoot({
      mcpServers: { slow: { command: "/bin/sh", args: ["-c", "echo $$ > slow.pid; trap 'exit 0' TERM; while :; do sleep 0.05; done"] } },
    });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 140,
      height: 36,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("/mcp show slow");
    const pidPath = join(root.workspace, "slow.pid");
    for (let i = 0; i < 200 && !existsSync(pidPath); i++) await Bun.sleep(25);
    const pid = Number(readFileSync(pidPath, "utf8").trim());
    try {
      expect(isRunning(pid)).toBe(true);
      await tui.sendKeys("C-c");
      await Bun.sleep(300);
      const start = Date.now();
      await tui.sendKeys("C-c");
      while (tui.isAlive() && Date.now() - start < 5_000) await Bun.sleep(20);
      // A graceful stop would wait 1.5 s on the closed stdin before SIGTERM.
      expect(Date.now() - start).toBeLessThan(1_000);
      for (let i = 0; i < 50 && isRunning(pid); i++) await Bun.sleep(20);
      expect(isRunning(pid)).toBe(false);
    } finally {
      if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 60_000);

  test.skipIf(!tmuxAvailable())("/mcp alone opens the menu, whose choices run the verbs", async () => {
    const root = createRoot(
      { mcpServers: { fixture: fixtureServer({ env: { FX_MCP_SPEC_CLIENT: "1", FX_MCP_EXPECT_ELICITATION: "both" } }), web: { type: "http", url: "https://w.example/mcp" } } },
      { mcpServers: { proj: { command: "node", args: ["proj.js", "--port", "4100"] } } },
    );
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 100,
      height: 36,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);

    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.waitForText(/proj +waiting for approval +project/, 5_000);
    await tui.waitForText("↑↓ navigate     enter open     esc close", 5_000);

    // Typing filters; Enter connects the server and lists its tools.
    await tui.sendLiteral("fix");
    await tui.waitForText("MCP servers  1 of 3", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Echo text through the modern MCP fixture", 15_000);
    await tui.waitForText("› Remove        /mcp remove fixture", 5_000);
    // ↓ goes on into the tools, where Enter has nothing to run.
    await tui.sendKeys("Down");
    await tui.waitForText("↑↓ navigate     esc back", 5_000);
    // Esc goes back, then closes and clears the filter.
    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  1 of 3", 5_000);
    await tui.sendKeys("Escape");
    await tui.waitForPane((pane) => !pane.includes("MCP servers") && !pane.includes("fix"), 5_000);

    // A choice that changes something asks first; anything but Enter is no.
    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.sendKeys("Down Down Enter");
    await tui.waitForText("› Approve       /mcp approve proj", 5_000);
    await tui.waitForText("Its tools show here once you approve it.", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Approve proj for this project? It runs:", 5_000);
    await tui.waitForText("node proj.js --port 4100", 5_000);
    await tui.waitForText("enter confirm     esc cancel", 5_000);
    await tui.sendLiteral("n");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 5_000);
    expect(await tui.capturePane()).not.toContain("Approved proj");

    // Confirmed, it runs `/mcp approve proj`, which prints in the conversation.
    await tui.sendKeys("Enter");
    await tui.waitForText("enter confirm     esc cancel", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Approved proj, which runs: node proj.js --port 4100", 10_000);
    // The reload follows, and the screen with it.
    await tui.waitForText("› Reject        /mcp reject proj", 10_000);

    // Remove asks which file it edits; Esc keeps the server, Enter removes it.
    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  3", 5_000);
    await tui.sendKeys("Up Enter");
    await tui.waitForText("› Remove        /mcp remove web", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);
    await tui.sendKeys("Escape");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 5_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeDefined();
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("Removed web from ~/.fx/mcp.json.", 10_000);
    // Its screen goes with it, back to the list.
    await tui.waitForText("MCP servers  2", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeUndefined();
  }, 90_000);
});
