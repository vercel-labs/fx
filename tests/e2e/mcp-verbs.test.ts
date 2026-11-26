import { afterEach, describe, expect, test } from "bun:test";
import { processAlive as isRunning } from "./process-alive";
import { chmodSync, existsSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { startModernMcpHttpFixture } from "./fixtures/mcp-modern-http";
import { logLines, onlySessionId } from "./saved-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall, heldFakeGatewayFinalText, startDynamicFakeGateway, startFakeGateway, TmuxSession, tmuxAvailable, turnSettled } from "./tmux-helpers";

// `fx mcp`. Sign-in is covered in mcp-auth.test.ts.

const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");

let cleanup: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | ReturnType<typeof startDynamicFakeGateway> | null = null;
let tui: TmuxSession | null = null;

afterEach(async () => {
  if (tui) await tui.kill();
  tui = null;
  gateway?.stop();
  gateway = null;
  if (cleanup) rmSync(cleanup, { recursive: true, force: true });
  cleanup = null;
});

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
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      AI_GATEWAY_API_KEY: "fake-mcp-verbs-key",
      VERCEL_OIDC_TOKEN: undefined,
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
  ...extra,
});

describe("fx mcp", () => {
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

  // Fx never edits a linked file. Replacing a link forks the file it
  // points to, and following one could write outside the project.
  test("add and remove refuse a linked config file and name what it points to", async () => {
    const root = createRoot();
    const shared = join(root.workspace, "shared");
    mkdirSync(shared);
    const target = join(shared, "mcp.json");
    const text = JSON.stringify({ mcpServers: { one: { command: "true" } } });
    writeFileSync(target, text);
    symlinkSync(target, root.projectPath);
    const why = `it's a link to ${target}, and fx edits only a plain file; edit ${target} by hand.\n`;
    const added = await mcp(root, "add", "--project", "two", "--", "true");
    expect(added.code).toBe(1);
    expect(added.stderr).toBe(`Couldn't add two to .mcp.json: ${why}`);
    const removed = await mcp(root, "remove", "--project", "one");
    expect(removed.code).toBe(1);
    expect(removed.stderr).toBe(`Couldn't remove one from .mcp.json: ${why}`);
    expect(lstatSync(root.projectPath).isSymbolicLink()).toBe(true);
    expect(readFileSync(target, "utf8")).toBe(text);

    // A hard link would fork the same way.
    rmSync(root.projectPath);
    linkSync(target, root.projectPath);
    const hard = await mcp(root, "add", "--project", "two", "--", "true");
    expect(hard.code).toBe(1);
    expect(hard.stderr).toBe("Couldn't add two to .mcp.json: it has another hard link, and fx edits only a plain file; edit it by hand.\n");
    expect(readFileSync(target, "utf8")).toBe(text);

    // The profile's own replace refuses a link too, and says so the same way.
    const profileTarget = join(shared, "profile.json");
    writeFileSync(profileTarget, "{}");
    symlinkSync(profileTarget, root.profilePath);
    const profile = await mcp(root, "add", "three", "--", "true");
    expect(profile.code).toBe(1);
    expect(profile.stderr).toBe(`Couldn't add three to ~/.fx/mcp.json: it's a link to ${profileTarget}, and fx edits only a plain file; edit ${profileTarget} by hand.\n`);
    expect(lstatSync(root.profilePath).isSymbolicLink()).toBe(true);
    expect(readFileSync(profileTarget, "utf8")).toBe("{}");
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

    // fx won't send a token written into an Authorization header: that
    // server is skipped, and the note says where the token goes.
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { bad: { type: "http", url: "https://b/mcp", headers: { Authorization: "Bearer x" } } } }));
    const refused = await mcp(root, "list");
    expect(refused.code).toBe(0);
    expect(refused.stderr).toContain(
      "note: ~/.fx/mcp.json server 'bad' was skipped: fx won't send its Authorization header; put the token in \"bearer_token_env\", or sign in with login.\n",
    );
    expect(refused.stdout).not.toContain("bad");

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

  // What fx refuses in a server's answer to tools/list, and the words it gives for each. The reply is raw text after the
  // request id, so a repeated key reaches fx as written.
  const refusedLists: [string, string, string][] = [
    ["`tools` is no list", '"result":{"resultType":"complete","tools":7}', '"tools" is not a list'],
    ["`tools` is written twice", '"result":{"resultType":"complete","tools":[],"tools":[]}', "a field is written twice"],
    ["`tools` is written twice, once with an escape", '"result":{"resultType":"complete","tools":[],"t\\u006fols":[]}', "a field is written twice"],
    ["the server answers with an error", '"error":{"code":-32603,"message":"Internal error"}', "the server answered the list with an error"],
    ["the answer is no finished list", '"result":{"resultType":"input_required","inputRequests":{}}', "the server's answer was not a finished list"],
    // The reply is matched to the list by its id, which comes first, and then fx cannot read the rest. It says so, not that the server
    // answered with an error, and it does not wait 30 seconds for the list.
    ["the reply goes wrong after its id: not JSON", '"result":{"resultType":"complete","tools":[]},"extra":nope', "the answer is not a readable tool list"],
    [
      "the reply goes wrong after its id: nested past the engine's limit",
      `"result":{"resultType":"complete","tools":[]},"extra":${"[".repeat(3000)}${"]".repeat(3000)}`,
      "the answer is not a readable tool list",
    ],
    ["the reply goes wrong after its id: `result` is written twice", '"result":{"resultType":"complete","tools":[]},"result":{"resultType":"complete","tools":[]}', "a field is written twice"],
  ];

  for (const [what, reply, why] of refusedLists) {
    test(`show says when fx refused the tool list, as the server's answer: ${what}`, async () => {
      const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_LIST_REPLY: reply } }) } });
      const text = await mcp(root, "show", "fixture");
      expect(text.stderr).toBe("");
      // The server works, so the exit stays 0.
      expect(text.code).toBe(0);
      expect(text.stdout).toStartWith(`fixture\n  status     ready, tool list refused\n  tool list  refused: ${why}\n  version    2026-07-28\n  transport  stdio\n`);
      expect(text.stdout).not.toContain("0 tools");

      const json = await mcp(root, "show", "fixture", "--json");
      expect(json.code).toBe(0);
      const shown = JSON.parse(json.stdout);
      // `error` is what says a server is down, and this one is not; `status` and `tools` keep their meaning.
      expect(shown).toMatchObject({ name: "fixture", status: "ready", error: null, tools_error: why, tools: [] });
    }, 30_000);
  }

  // The reply's id comes after what fx cannot read, so the line names no request. Nothing tells which list it answers: the
  // list waits out the 30-second grace, as every request in flight does, and then fx says it could not read the list.
  const unnamedLists: [string, string, "text" | "json"][] = [
    ["not JSON before the id", '{"jsonrpc":"2.0","result":{"resultType":"complete","tools":[]},"extra":nope,"id":{id}}', "text"],
    ["nested past the engine's limit before the id", `{"jsonrpc":"2.0","result":{"resultType":"complete","tools":[]},"extra":${"[".repeat(3000)}${"]".repeat(3000)},"id":{id}}`, "json"],
  ];
  const UNREADABLE = "the answer is not a readable tool list";

  for (const [what, line, form] of unnamedLists) {
    test(`show says the list was unreadable when no id could be read, after the grace: ${what}`, async () => {
      const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_LIST_LINE: line } }) } });
      const started = Date.now();
      const shown = await runFx(["mcp", "show", "fixture", ...(form === "json" ? ["--json"] : [])], { cwd: root.workspace, env: root.env, timeoutMs: 60_000 });
      const seconds = (Date.now() - started) / 1000;
      expect(shown.stderr).toBe("");
      expect(shown.code).toBe(0);
      if (form === "json") {
        expect(JSON.parse(shown.stdout)).toMatchObject({ name: "fixture", status: "ready", error: null, tools_error: UNREADABLE, tools: [] });
      } else {
        expect(shown.stdout).toStartWith(`fixture\n  status     ready, tool list refused\n  tool list  refused: ${UNREADABLE}\n`);
        expect(shown.stdout).not.toContain("0 tools");
      }
      // The wait is the grace: not at once, as a line with an id would, and far short of the 5 minutes an operation waits.
      expect({ late: seconds > 28, early: seconds < 55 }).toEqual({ late: true, early: true });
    }, 90_000);
  }

  test("show gives no refusal for a tool list it accepted, or for a tool it could not read", async () => {
    const good = createRoot({ mcpServers: { fixture: fixtureServer() } });
    const text = await mcp(good, "show", "fixture");
    expect(text.stdout).toMatch(/^fixture\n  status     ready, 1 tool\n  version/);
    expect(text.stdout).not.toContain("tool list");
    expect(JSON.parse((await mcp(good, "show", "fixture", "--json")).stdout)).toMatchObject({ status: "ready", error: null, tools_error: null });

    // A tool whose `name` is written twice is dropped and the list is still the server's answer: nothing is refused.
    const dropped = createRoot({
      mcpServers: {
        fixture: fixtureServer({ env: { FX_MCP_LIST_REPLY: '"result":{"resultType":"complete","tools":[{"name":"a","name":"b","inputSchema":{"type":"object"}}]}' } }),
      },
    });
    const shown = JSON.parse((await mcp(dropped, "show", "fixture", "--json")).stdout);
    expect(shown).toMatchObject({ status: "ready", tools_error: null, tools: [] });
  }, 30_000);

  // What fx leaves out of a list is told beside the status, not only traced: how many, and the one reason they share.
  test("show says how many tools fx left out of a list and why, in text and in --json", async () => {
    let deepSchema: unknown = { type: "string" };
    for (let level = 0; level < 70; level += 1) deepSchema = { type: "object", properties: { a: deepSchema } };
    const good = '{"name":"good","inputSchema":{"type":"object"}}';
    const twice = '{"name":"twice","name":"again","inputSchema":{"type":"object"}}';
    const sameName = '{"name":"good","description":"the second","inputSchema":{"type":"object"}}';
    const tooDeep = JSON.stringify({ name: "deep", inputSchema: deepSchema });
    // `odd` has a `description` that is no text: the engine keeps it, and the host's reading refuses it. The others the engine
    // skips itself.
    const odd = '{"name":"odd","description":7,"inputSchema":{"type":"object"}}';
    const cases: { tools: string[]; listed: number; text: string | null; json: { count: number; reason: string } | null }[] = [
      { tools: [good], listed: 1, text: null, json: null },
      { tools: [good, twice], listed: 1, text: "1 tool: a field is written twice", json: { count: 1, reason: "a field is written twice" } },
      { tools: [good, sameName], listed: 1, text: "1 tool: a name is used by two tools", json: { count: 1, reason: "a name is used by two tools" } },
      { tools: [good, tooDeep], listed: 1, text: "1 tool: a limit on size or nesting is passed", json: { count: 1, reason: "a limit on size or nesting is passed" } },
      { tools: [good, odd], listed: 2, text: "1 tool: a definition can't be used", json: { count: 1, reason: "a definition can't be used" } },
      { tools: [good, twice, sameName, tooDeep, odd], listed: 2, text: "4 tools: more than one reason", json: { count: 4, reason: "more than one reason" } },
    ];
    for (const one of cases) {
      const reply = `"result":{"resultType":"complete","tools":[${one.tools.join(",")}]}`;
      const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_LIST_REPLY: reply } }) } });
      const text = await mcp(root, "show", "fixture");
      expect(text.stderr).toBe("");
      expect(text.code).toBe(0);
      expect(text.stdout).toContain(`  status     ready, ${one.listed} tool${one.listed === 1 ? "" : "s"}\n`);
      if (one.text === null) expect(text.stdout).not.toContain("left out");
      else expect(text.stdout).toContain(`  left out   ${one.text}\n`);
      const shown = JSON.parse((await mcp(root, "show", "fixture", "--json")).stdout);
      expect(shown).toMatchObject({ status: "ready", tools_error: null, tools_left_out: one.json });
      expect(JSON.parse((await mcp(root, "list", "--json")).stdout).servers[0]).toHaveProperty("tools_left_out");
    }
  }, 120_000);

  test("show says when fx refused the tool list of an HTTP server too", async () => {
    const upstream = startModernMcpHttpFixture("list_refused");
    try {
      const root = createRoot({ mcpServers: { web: { type: "http", url: upstream.url } } });
      const text = await mcp(root, "show", "web");
      expect(text.stderr).toBe("");
      expect(text.code).toBe(0);
      expect(text.stdout).toStartWith("web\n  status     ready, tool list refused\n  tool list  refused: a field is written twice\n");
      const shown = JSON.parse((await mcp(root, "show", "web", "--json")).stdout);
      expect(shown).toMatchObject({ status: "ready", error: null, tools_error: "a field is written twice", tools: [] });
    } finally {
      upstream.stop();
    }
  }, 30_000);

  // An HTTP server that answers `tools/list` with a status: 403 is refused, 429 and 503 are temporary and say so. The
  // refusal's words are the same in `show`, its JSON, the `/mcp` screen and what the model is told. `list` never connects, so
  // it has no list to say.
  const listStatuses = [
    { mode: "list_http_403", state: "tool list refused", detail: "refused", words: "the server answered the list with HTTP 403" },
    { mode: "list_http_429", state: "tool list unavailable (HTTP 429)", detail: "unavailable", words: "the server answered the list with HTTP 429, which is temporary" },
    { mode: "list_http_503", state: "tool list unavailable (HTTP 503)", detail: "unavailable", words: "the server answered the list with HTTP 503, which is temporary" },
  ] as const;
  for (const one of listStatuses) {
    test(`says the same reason for a tool list answered with ${one.mode.replace("list_http_", "HTTP ")} in show, its JSON and what the model is told`, async () => {
      const upstream = startModernMcpHttpFixture(one.mode);
      try {
        const root = createRoot({ mcpServers: { web: { type: "http", url: upstream.url } } });
        const text = await mcp(root, "show", "web");
        expect(text.stderr).toBe("");
        expect(text.code).toBe(0);
        expect(text.stdout).toStartWith(`web\n  status     ready, ${one.state}\n  tool list  ${one.detail}: ${one.words}\n`);
        const shown = JSON.parse((await mcp(root, "show", "web", "--json")).stdout);
        expect(shown).toMatchObject({ status: "ready", error: null, tools_error: one.words, tools: [] });

        // The model is told the same words, not that the server is unavailable.
        const activeGateway = startFakeGateway([
          fakeGatewayToolCall("search_web", "toolbox", { search: "web tools", server: "web" }),
          fakeGatewayToolCall("search_any", "toolbox", { search: "weather forecast" }),
          fakeGatewayToolCall("list_web", "shell", { action: "run", command: `"${FX_BIN}" mcp call list web` }),
          fakeGatewayFinalText("LIST_REASON_TOLD"),
        ], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
        gateway = activeGateway;
        const asked = await runFx(["ask", "--json", "--full-access", "--no-save", "Find the web tools."], {
          cwd: root.workspace,
          env: { ...root.env, FX_GATEWAY_BASE_URL: activeGateway.baseUrl, FX_GATEWAY_CHAT_URL: activeGateway.chatUrl, FX_MODEL: "openai/gpt-5" },
          timeoutMs: 60_000,
        });
        expect(asked.code).toBe(0);
        // A search of the server, a search of every server and `fx mcp call list` each tell it the refusal's words.
        const told = activeGateway.requests[3]?.body ?? "";
        expect(told.split(`MCP server 'web' is unavailable: ${one.words}`).length - 1).toBeGreaterThanOrEqual(3);
        expect(told).not.toContain("is unavailable: the server is unavailable");
      } finally {
        upstream.stop();
      }
    }, 90_000);

    test.skipIf(!tmuxAvailable())(`the /mcp screen of a server whose tool list is answered with ${one.mode.replace("list_http_", "HTTP ")} says the same reason in both of its lines`, async () => {
      const upstream = startModernMcpHttpFixture(one.mode);
      try {
        const root = createRoot({ mcpServers: { web: { type: "http", url: upstream.url } } });
        gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          width: 120,
          height: 30,
          env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
        });
        await tui.waitForComposer(15_000);
        await tui.sendText("/mcp");
        await tui.waitForText("MCP servers  1", 10_000);
        await tui.sendKeys("Enter");
        const pane = await tui.waitForText(`Its tools couldn't load: ${one.words}`, 20_000);
        expect(pane).toContain(`ready, ${one.state}`);
        expect(pane).not.toContain("Its tools couldn't load: the server is unavailable");
      } finally {
        upstream.stop();
      }
    }, 90_000);
  }

  // The `/mcp` list gives each row the words of its status that fit: under 33 columns the whole words of a refused list
  // do not, so a row says its kind in fewer, and a cut never takes the word that says it.
  test.skipIf(!tmuxAvailable())("the /mcp list says a refused and an unavailable tool list in rows that fit at 30, 33, 60 and 200 columns", async () => {
    const refused = startModernMcpHttpFixture("list_http_403");
    const waiting = startModernMcpHttpFixture("list_http_503");
    try {
      const root = createRoot({ mcpServers: { no403: { type: "http", url: refused.url }, wait503: { type: "http", url: waiting.url } } });
      gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
      const grid = [
        { width: 30, refused: "list refused", waiting: "unavailable" },
        { width: 33, refused: "tool list refused", waiting: "unavailable (503)" },
        { width: 60, refused: "ready, tool list refused", waiting: "ready, tool list unavailable (HTTP 503)" },
        { width: 200, refused: "ready, tool list refused", waiting: "ready, tool list unavailable (HTTP 503)" },
      ];
      for (const one of grid) {
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          width: one.width,
          height: 20,
          env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
        });
        await tui.waitForComposer(15_000);
        await tui.sendText("/mcp");
        const rowOf = (pane: string, name: string) => pane.split("\n").find((line) => line.replace(/^[› ]+/, "").startsWith(name)) ?? "";
        const pane = await tui.waitForPane((text) => rowOf(text, "no403").includes(one.refused) && rowOf(text, "wait503").includes(one.waiting), 20_000);
        for (const line of pane.split("\n")) {
          expect({ width: one.width, line, wide: [...line].length > one.width }).toMatchObject({ wide: false });
        }
        expect(pane).not.toContain("…");
        await tui.kill();
        tui = null;
      }
    } finally {
      refused.stop();
      waiting.stop();
    }
  }, 180_000);

  // The server answered `tools/list`, but not with a JSON-RPC message: a status that no other flow reads, or a page
  // that is no JSON. That is an answer fx refuses, not a server that gave none.
  const httpAnswers = [
    ["list_http_500", "the server answered the list with HTTP 500"],
    ["list_html_200", "the list is not valid JSON"],
  ] as const;
  for (const [mode, why] of httpAnswers) {
    test(`show says when an HTTP server answered the tool list with ${mode.replace("list_", "").replaceAll("_", " ")}`, async () => {
      const upstream = startModernMcpHttpFixture(mode);
      try {
        const root = createRoot({ mcpServers: { web: { type: "http", url: upstream.url } } });
        const text = await mcp(root, "show", "web");
        expect(text.stderr).toBe("");
        expect(text.code).toBe(0);
        expect(text.stdout).toStartWith(`web\n  status     ready, tool list refused\n  tool list  refused: ${why}\n`);
        const shown = JSON.parse((await mcp(root, "show", "web", "--json")).stdout);
        expect(shown).toMatchObject({ status: "ready", error: null, tools_error: why, tools: [] });
      } finally {
        upstream.stop();
      }
    }, 30_000);
  }

  test("list --json carries tools_error, null for a server fx has not asked for its tools", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_LIST_REPLY: refusedLists[0][1] } }), off: { command: "never-run", enabled: false } } });
    const listed = await mcp(root, "list", "--json");
    expect(listed.code).toBe(0);
    for (const server of JSON.parse(listed.stdout).servers) expect(server).toHaveProperty("tools_error", null);
  });

  test("a variable a header can't carry holds its server back instead of aborting fx", async () => {
    // Nothing listens on port 1, and nothing should be sent there.
    const root = createRoot({
      mcp: {
        token: { type: "http", url: "http://127.0.0.1:1/mcp", bearer_token_env: "FX_VERBS_TOKEN" },
        team: { type: "http", url: "http://127.0.0.1:1/mcp", header_env: { "X-Team": "FX_VERBS_TEAM" } },
      },
    });
    root.env = { ...root.env, FX_VERBS_TOKEN: "a\r\nb", FX_VERBS_TEAM: "x\nInjected: yes" } as typeof root.env;
    const shown = await mcp(root, "show", "token");
    expect(shown.stderr).toBe("");
    expect(shown.code).toBe(1);
    expect(shown.stdout).toContain("  status     can't use $FX_VERBS_TOKEN\n");
    const json = await mcp(root, "list", "--json");
    expect(json.code).toBe(0);
    expect(JSON.parse(json.stdout).servers.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["token", "invalid_env"],
      ["team", "invalid_env"],
    ]);
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
    expect(both.stderr).toBe("twin is in both ~/.fx/mcp.json and .mcp.json. Add --global or --project.\n");

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

    // `--global` names ~/.fx/mcp.json.
    const global = await mcp(root, "remove", "--global", "twin");
    expect(global.code).toBe(0);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8"))).toEqual({ mcpServers: {}, other: 1 });
    const profile = await mcp(root, "remove", "--profile", "twin");
    expect(profile.code).toBe(2);
    expect(profile.stdout).toBe("");
    expect(profile.stderr).toBe("fx mcp remove: --profile was removed; use --global\nusage: fx mcp remove [--global | --project] NAME\n");
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
    // `--all` approves the servers it shows, not a server added later.
    const settings = JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8"));
    expect(settings.workspaces[root.workspace]).toEqual({ enabledMcpjsonServers: ["docs"], disabledMcpjsonServers: ["web"] });

    const list = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(list.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["mine", "not_started"],
      ["docs", "not_started"],
      ["web", "rejected"],
    ]);

    const profileServer = await mcp(root, "approve", "mine");
    expect(profileServer.code).toBe(1);
    expect(profileServer.stderr).toBe("No project server named mine in .mcp.json.\n");
    const project = JSON.parse(readFileSync(root.projectPath, "utf8"));
    project.mcpServers.later = { command: "node", args: ["later.js"] };
    writeFileSync(root.projectPath, JSON.stringify(project));
    const after = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(after.find((s: { name: string }) => s.name === "later")?.status).toBe("waiting_for_approval");
  });

  test("approve --all approves each server it shows, and one added later still waits", async () => {
    const root = createRoot(undefined, { mcpServers: { a: { command: "node", args: ["a.js"] }, b: { type: "http", url: "https://b.example/mcp" } } });
    const all = await mcp(root, "approve", "--all");
    expect(all.code).toBe(0);
    expect(all.stdout).toBe("Approved a, which runs: node a.js\nApproved b, which connects to: https://b.example/mcp\n");
    const settings = JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8"));
    expect(settings.workspaces[root.workspace]).toEqual({ enabledMcpjsonServers: ["a", "b"] });
    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { a: { command: "node", args: ["a.js"] }, b: { type: "http", url: "https://b.example/mcp" }, c: { command: "node", args: ["c.js"] } } }));
    const list = JSON.parse((await mcp(root, "list", "--json")).stdout).servers;
    expect(list.map((s: { name: string; status: string }) => [s.name, s.status])).toEqual([
      ["a", "not_started"],
      ["b", "not_started"],
      ["c", "waiting_for_approval"],
    ]);
  });

  test("help, usage mistakes, and old verbs", async () => {
    const root = createRoot();
    const overview = await mcp(root);
    expect(overview.code).toBe(0);
    expect(overview.stdout).toStartWith("usage: fx mcp COMMAND\n\n  list [--json]               configured servers; never connects\n");
    const verbHelp = await mcp(root, "remove", "-h");
    expect(verbHelp.code).toBe(0);
    expect(verbHelp.stdout).toBe("usage: fx mcp remove [--global | --project] NAME\n");

    const unknownVerb = await mcp(root, "nope");
    expect(unknownVerb.code).toBe(2);
    expect(unknownVerb.stderr).toStartWith("'nope' isn't an fx mcp command.\nusage: fx mcp COMMAND\n");
    const badFlag = await mcp(root, "logout", "--json", "x");
    expect(badFlag.code).toBe(2);
    expect(badFlag.stderr).toBe("fx mcp logout: unknown flag --json\nusage: fx mcp logout NAME\n");

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

  test("fx mcp commands keep a trace when FX_TRACE_LOG asks for one", async () => {
    const root = createRoot({ mcp: { noisy: { command: "sh", args: ["-c", "echo trace-me >&2; exit 3"], startup_timeout_ms: 2_000 } } });
    const trace = join(root.home, "trace.log");
    const show = await runFx(["mcp", "show", "noisy"], { cwd: root.workspace, env: { ...root.env, FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "mcp" }, timeoutMs: 20_000 });
    expect(show.signal).toBeNull();
    expect(existsSync(trace)).toBe(true);
    expect(readFileSync(trace, "utf8")).toContain("line=trace-me");
  }, 30_000);
});

describe("/mcp in the shell", () => {
  test.skipIf(!tmuxAvailable())("/mcp list and /mcp show say when fx refused a server's tool list", async () => {
    // The shell can ask questions, so it says so to servers, and the fixture expects that.
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both", FX_MCP_LIST_REPLY: '"result":{"resultType":"complete","tools":7}' } }) } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    // Servers start on their own once the first frame is up; ask until the status says what happened to the list.
    const listed = "fixture  ~/.fx/mcp.json  stdio      ready, tool list refused";
    for (let i = 0; i < 20 && !(await tui.capturePane()).includes(listed); i++) {
      await tui.sendText("/mcp list");
      await tui.waitForText(listed, 500).catch(() => {});
    }
    await tui.waitForText(listed, 1_000);
    await tui.sendText("/mcp show fixture");
    await tui.waitForText('tool list  refused: "tools" is not a list', 15_000);
  }, 60_000);

  test.skipIf(!tmuxAvailable())("/mcp runs the same verbs and prints the same text", async () => {
    // The shell can ask questions, so it says so to servers.
    const root = createRoot({ mcpServers: { fixture: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both" } }) } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);

    // Servers start on their own once the first frame is up. `/mcp list`
    // says what each is doing now, so ask until it's ready. Nothing is wrong,
    // so the status line says nothing about MCP.
    const listed = "fixture  ~/.fx/mcp.json  stdio      ready, 1 tool";
    for (let i = 0; i < 20 && !(await tui.capturePane()).includes(listed); i++) {
      await tui.sendText("/mcp list");
      await tui.waitForText(listed, 500).catch(() => {});
    }
    await tui.waitForText(listed, 1_000);
    expect(await tui.capturePane()).not.toMatch(/mcp \d+\/\d+/);
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
    // Added, it starts too; this address never answers.
    await tui.waitForText(/web +~\/\.fx\/mcp\.json +http +(connecting|retrying|failed)/, 10_000);
    await tui.waitForText("ready, ", 5_000);

    await tui.sendText("/mcp nope");
    await tui.waitForText("'nope' isn't a /mcp command.", 10_000);
    await tui.sendText("/mcp list --json");
    await tui.waitForText("/mcp list: unknown flag --json", 10_000);
    await tui.sendText("/mcp auth web");
    await tui.waitForText("/mcp auth is now /mcp login NAME.", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toEqual({ type: "http", url: "https://w.example/mcp" });
  }, 90_000);

  test.skipIf(!tmuxAvailable())("/mcp add joins a backslash-newline in its arguments the way the shell does", async () => {
    // Every shell reads `"a\<newline>b"` as `ab`, so that is the argument
    // the saved server gets.
    const root = createRoot();
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.pasteText('/mcp add probe -- /bin/echo "a\\\nb"');
    await tui.sendKeys("Enter");
    await tui.waitForText("Added probe to ~/.fx/mcp.json.", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.probe).toEqual({ command: "/bin/echo", args: ["ab"] });
  }, 60_000);

  test.skipIf(!tmuxAvailable())("a config change restarts only the server it changed, never freezes the shell, and a server runs one copy at a time", async () => {
    // `s` keeps running after its input closes and ignores SIGTERM, so fx
    // takes about 3 s to stop it: 1.5 s for it to exit, 1.5 s after SIGTERM.
    const root = createRoot();
    const pidPath = join(root.home, "s.pid");
    const eofPath = join(root.home, "s.eof");
    const projPid = join(root.home, "proj.pid");
    const env = { FX_MCP_EXPECT_ELICITATION: "both", FX_MCP_IGNORE_EOF: "1", FX_MCP_IGNORE_TERM: "1", FX_MCP_PID_PATH: pidPath, FX_MCP_EOF_PATH: eofPath };
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { s: fixtureServer({ env }) } }));
    writeFileSync(root.projectPath, JSON.stringify({ mcpServers: { proj: fixtureServer({ env: { FX_MCP_PID_PATH: projPid } }) } }));
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    // `s` outlives fx's SIGTERM at quit, so every copy is killed here.
    const pids = new Set<number>();
    const killServers = () => {
      for (const path of [pidPath, projPid]) if (existsSync(path)) pids.add(Number(readFileSync(path, "utf8")));
      for (const pid of pids) if (isRunning(pid)) process.kill(pid, "SIGKILL");
    };
    const pidIn = (path: string) => (existsSync(path) ? Number(readFileSync(path, "utf8").trim() || "0") : 0);
    try {
      await tui.waitForComposer(15_000);
      // `s` starts on its own once the first frame is up and writes its pid.
      const upBy = Date.now() + 10_000;
      while (pidIn(pidPath) === 0 && Date.now() < upBy) await Bun.sleep(5);
      const oldPid = pidIn(pidPath);
      pids.add(oldPid);

      // Adding a server, approving one, and removing one leave `s` as it was.
      await tui.sendText("/mcp add web https://w.example/mcp");
      await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
      await tui.sendText("/mcp approve proj");
      await tui.waitForText("Approved proj", 10_000);
      const projBy = Date.now() + 10_000;
      while (pidIn(projPid) === 0 && Date.now() < projBy) await Bun.sleep(5);
      expect(pidIn(projPid)).not.toBe(0);
      await tui.sendText("/mcp remove web");
      await tui.waitForText("Removed web from ~/.fx/mcp.json.", 10_000);
      expect(pidIn(pidPath)).toBe(oldPid);
      expect(existsSync(eofPath)).toBe(false);
      expect(isRunning(oldPid)).toBe(true);

      // Removed, `s` stops; added back at once, the new copy waits for it.
      await tui.sendText("/mcp remove s");
      await tui.waitForText("Removed s from ~/.fx/mcp.json.", 10_000);
      const eofBy = Date.now() + 10_000;
      // The fixture creates the file, then writes its pid.
      while (!(existsSync(eofPath) && readFileSync(eofPath, "utf8").trim() !== "") && Date.now() < eofBy) await Bun.sleep(5);
      expect(readFileSync(eofPath, "utf8").trim()).toBe(String(oldPid));
      const flags = Object.entries(env).map(([k, v]) => `--env ${k}=${v}`).join(" ");
      await tui.sendText(`/mcp add ${flags} s -- ${process.execPath} ${MODERN_FIXTURE}`);
      await tui.waitForText("Added s to ~/.fx/mcp.json.", 10_000);
      // The old copy is still stopping. Typing still shows at once.
      const typedAt = Date.now();
      await tui.sendLiteral("zq");
      await tui.waitForText("zq", 5_000);
      expect(Date.now() - typedAt).toBeLessThan(1_000);
      expect(isRunning(oldPid)).toBe(true);

      // The new copy starts only once the old one is gone.
      const startBy = Date.now() + 15_000;
      while (pidIn(pidPath) === oldPid && Date.now() < startBy) await Bun.sleep(5);
      expect(pidIn(pidPath)).not.toBe(oldPid);
      expect(isRunning(oldPid)).toBe(false);
      await tui.sendKeys("C-u");
      await tui.sendText("/mcp list");
      await tui.waitForText(/s +~\/\.fx\/mcp\.json +stdio +ready, 1 tool/, 15_000);
    } finally {
      // fx first, so no new copy starts after this.
      await tui?.kill();
      tui = null;
      killServers();
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a config change while a server is in use leaves it running, and the call finishes on the same process", async () => {
    // `s` takes 3 s to start, so `/mcp show s` is waiting on it while the config changes.
    const root = createRoot();
    const pidPath = join(root.home, "s.pid");
    writeFileSync(root.profilePath, JSON.stringify({ mcpServers: { s: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both", FX_MCP_DISCOVER_DELAY_MS: "3000", FX_MCP_PID_PATH: pidPath } }) } }));
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    const pids = new Set<number>();
    try {
      await tui.waitForComposer(15_000);
      const startBy = Date.now() + 10_000;
      while (!existsSync(pidPath) && Date.now() < startBy) await Bun.sleep(5);
      const oldPid = Number(readFileSync(pidPath, "utf8"));
      pids.add(oldPid);

      await tui.sendText("/mcp show s");
      await Bun.sleep(300);
      await tui.sendText("/mcp add web https://w.example/mcp");
      await tui.waitForText("Added web to ~/.fx/mcp.json.", 10_000);
      expect(await tui.capturePane()).not.toContain("Echo text through the modern MCP fixture");

      // The show answers from the copy it was waiting on, which keeps running.
      await tui.waitForText("Echo text through the modern MCP fixture", 10_000);
      pids.add(Number(readFileSync(pidPath, "utf8")));
      expect([...pids]).toEqual([oldPid]);
      expect(isRunning(oldPid)).toBe(true);
    } finally {
      await tui?.kill();
      tui = null;
      for (const pid of pids) if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a server added or removed by fx mcp outside the session reaches the next prompt and /mcp", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer() } });
    gateway = startFakeGateway([fakeGatewayFinalText("first done"), fakeGatewayFinalText("second done")], {
      models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }],
    });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    // Every string in a request, decoded, so the menu and notes read as the model reads them.
    const strings = (value: unknown): string[] =>
      typeof value === "string" ? [value]
        : Array.isArray(value) ? value.flatMap(strings)
        : value !== null && typeof value === "object" ? Object.values(value).flatMap(strings)
        : [];
    const text = (body: string) => strings(JSON.parse(body)).join("\n");
    const menu = (body: string) => {
      const all = text(body);
      return all.slice(all.indexOf("<toolbox>"), all.indexOf("</toolbox>"));
    };
    // The toolbox's change note, as its MCP servers line.
    const notedServers = (body: string) => /The toolbox now holds[\s\S]*?MCP servers: (.*)\n/.exec(text(body))?.[1] ?? "";

    // Another fx process writes the profile, as an agent's shell tool would.
    expect((await mcp(root, "add", "outside", "--", process.execPath, MODERN_FIXTURE)).code).toBe(0);
    // The next prompt loads it first, so its own request tells the model.
    await tui.sendText("first prompt");
    await tui.waitForPane((pane) => pane.includes("first done") && turnSettled(pane), 15_000);
    expect(gateway.requests).toHaveLength(1);
    const firstMenu = menu(gateway.requests[0]!.body);
    expect(firstMenu).toContain("- fixture");
    expect(firstMenu).toContain("- outside");
    // The session runs it, so `/mcp list` reports it.
    await tui.sendText("/mcp list");
    await tui.waitForText(/outside +~\/\.fx\/mcp\.json +stdio/, 10_000);

    // Removed the same way, it's gone by the next prompt. The menu stays as
    // first sent, so nothing earlier requests sent changes, and a note names
    // the servers toolbox holds now.
    expect((await mcp(root, "remove", "outside")).code).toBe(0);
    await tui.sendText("second prompt");
    await tui.waitForText("second done", 15_000);
    expect(gateway.requests).toHaveLength(2);
    expect(menu(gateway.requests[1]!.body)).toBe(firstMenu);
    expect(notedServers(gateway.requests[1]!.body)).toBe("fixture");
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a change noted in a turn that compaction folds away is noted again, and the menu stays as first sent", async () => {
    const root = createRoot({ mcpServers: { fixture: fixtureServer(), outside: fixtureServer() } });
    let answered = 0;
    const dynamic = startDynamicFakeGateway((raw: string) => {
      const request = JSON.parse(raw);
      if (request.tools?.length === 0 && request.toolChoice?.type === "none") return fakeGatewayFinalText("Turn 1\nIn between: none");
      answered += 1;
      return fakeGatewayFinalText(`done ${answered}`);
    }, { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    gateway = dynamic;
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: dynamic.baseUrl, FX_GATEWAY_CHAT_URL: dynamic.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const strings = (value: unknown): string[] =>
      typeof value === "string" ? [value]
        : Array.isArray(value) ? value.flatMap(strings)
        : value !== null && typeof value === "object" ? Object.values(value).flatMap(strings)
        : [];
    const text = (body: string) => strings(JSON.parse(body)).join("\n");
    const menu = (body: string) => {
      const all = text(body);
      return all.slice(all.indexOf("<toolbox>"), all.indexOf("</toolbox>"));
    };
    const notedServers = (body: string) => [...text(body).matchAll(/The toolbox now holds[\s\S]*?MCP servers: (.*)\n/g)].map((match) => match[1]);
    const agentBodies = () => dynamic.requests.map((request) => request.body)
      .filter((body) => { const request = JSON.parse(body); return !(request.tools?.length === 0 && request.toolChoice?.type === "none"); });
    // Each turn ends with its status line; the next prompt waits for it, so
    // no keystroke lands while the turn is still finishing.
    const prompt = async (words: string) => {
      const turn = answered + 1;
      await tui!.sendText(words);
      const ended = new RegExp(`done ${turn}\\n\\s*\\d+s \\(↑`);
      await tui!.waitForPane((pane) => ended.test(pane), 15_000);
      await tui!.waitForComposer(15_000);
    };
    const compactions = () => logLines(root.home, onlySessionId(root.home)).filter((line) => line.kind === "compacted").length;

    await prompt("first prompt");
    const firstMenu = menu(agentBodies()[0]!);
    expect(firstMenu).toContain("- fixture");
    expect(firstMenu).toContain("- outside");
    // The note telling the model that outside is gone goes in this turn.
    expect((await mcp(root, "remove", "outside")).code).toBe(0);
    await prompt("NOTED_TURN_PROMPT");
    expect(notedServers(agentBodies()[1]!)).toEqual(["fixture"]);
    // Four more turns, so the noted turn is older than the turns compaction keeps.
    for (const n of [3, 4, 5, 6]) await prompt(`prompt ${n}`);

    await tui.sendText("/compact");
    for (let i = 0; i < 600 && compactions() === 0; i++) await Bun.sleep(25);
    expect(compactions()).toBe(1);
    await tui.waitForComposer(15_000);
    await prompt("after compaction");
    const after = agentBodies().at(-1)!;
    // The noted turn was folded into the summary, and its note with it; the
    // newer turns follow as sent.
    const users = JSON.parse(after).prompt.filter((message: any) => message.role === "user")
      .map((message: any) => typeof message.content === "string" ? message.content : message.content.map((part: any) => part.text ?? "").join(""));
    expect(users[0]).toStartWith("<compacted_conversation>");
    expect(users[0]).toContain("NOTED_TURN_PROMPT");
    expect(users.slice(1, -1)).toEqual(["prompt 3", "prompt 4", "prompt 5", "prompt 6"]);
    // The note rides the new prompt, after everything earlier requests sent.
    expect(users.at(-1)).toStartWith("after compaction\n");
    // The conversation keeps its menu, so fx tells the model again what the
    // toolbox holds now.
    expect(menu(after)).toBe(firstMenu);
    expect(notedServers(after)).toEqual(["fixture"]);
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a prompt sent while a turn runs keeps the current servers, and the next prompt after the turn loads the change", async () => {
    // Only SIGTERM ends it: it never reads stdin, and never answers.
    const root = createRoot({
      mcpServers: { slow: { command: "/bin/sh", args: ["-c", "echo $$ > slow.pid; trap 'exit 0' TERM; while :; do sleep 0.05; done"] } },
    });
    const held = heldFakeGatewayFinalText();
    gateway = startFakeGateway([held.response, fakeGatewayFinalText("second done"), fakeGatewayFinalText("third done")], {
      models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }],
    });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const pidPath = join(root.home, "slow.pid");
    for (let i = 0; i < 200 && !existsSync(pidPath); i++) await Bun.sleep(25);
    const pid = Number(readFileSync(pidPath, "utf8").trim());
    try {
      expect(isRunning(pid)).toBe(true);
      await tui.sendText("first prompt");
      for (let i = 0; i < 600 && gateway.requests.length === 0; i++) await Bun.sleep(25);
      expect(gateway.requests).toHaveLength(1);
      // While the turn runs, another fx removes the server and a prompt is sent.
      expect((await mcp(root, "remove", "slow")).code).toBe(0);
      await tui.sendText("second prompt");
      await tui.waitForText("second prompt", 10_000);
      // A removed server stops within about 1.5 s; this one keeps running.
      for (let i = 0; i < 50; i++) {
        expect(isRunning(pid)).toBe(true);
        await Bun.sleep(50);
      }
      held.release("first done");
      await tui.waitForPane((pane) => pane.includes("second done") && turnSettled(pane), 15_000);
      // The next prompt, sent with no turn running, loads the change.
      await tui.sendText("third prompt");
      await tui.waitForText("third done", 15_000);
      for (let i = 0; i < 200 && isRunning(pid); i++) await Bun.sleep(25);
      expect(isRunning(pid)).toBe(false);
    } finally {
      held.dispose();
      if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 90_000);

  test.skipIf(!tmuxAvailable())("a project .mcp.json that is a FIFO or a link to /dev/tty can't stop the shell starting or checking the config", async () => {
    for (const kind of ["fifo", "tty"] as const) {
      const root = createRoot();
      if (kind === "fifo") expect(Bun.spawnSync(["mkfifo", root.projectPath]).exitCode).toBe(0);
      else symlinkSync("/dev/tty", root.projectPath);
      gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 120,
        height: 30,
        env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      });
      await tui.waitForComposer(15_000);
      // `/mcp list` checks the config files again before it answers.
      await tui.sendText("/mcp list");
      await tui.waitForText("No MCP servers configured", 10_000);
      expect(await tui.captureFullScrollback()).toContain(".mcp.json server 'unknown' was skipped: fx can't read it.");
      await tui.kill();
      tui = null;
      gateway.stop();
      gateway = null;
      rmSync(cleanup!, { recursive: true, force: true });
      cleanup = null;
    }
  }, 60_000);

  test.skipIf(!tmuxAvailable())("the status line, not the transcript, names waiting project servers and config problems", async () => {
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
    // Not a prompt: the composer is free, and the status line says what's waiting.
    await tui.waitForComposer(15_000);
    await tui.waitForText("2 MCP need attention · /mcp", 10_000);
    // One left, it's named; it stays until it's handled.
    await tui.sendText("/mcp reject broken");
    await tui.waitForText("proj is waiting for approval · /mcp", 10_000);
    await tui.sendText("/mcp reject proj");
    // Then the config problem, which /mcp list shows.
    await tui.waitForText("MCP config has 1 problem · /mcp list", 10_000);
    await tui.sendText("/mcp list");
    await tui.waitForText("server 'docs' field argument requires environment variable 'DOCS_TOKEN'", 10_000);
    // None of it was printed above the composer on its own.
    const scrollback = await tui.captureFullScrollback();
    expect(scrollback).not.toContain("waiting for approval: broken");
    expect(scrollback).not.toContain("Use /mcp approve");
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
    const pidPath = join(root.home, "slow.pid");
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
      // The owner stops the server, which ignores its closed stdin, with
      // SIGTERM within its grace; the session itself does not wait for it.
      // Polls that process's exit, bounded at 5 s.
      for (let i = 0; i < 250 && isRunning(pid); i++) await Bun.sleep(20);
      expect(isRunning(pid)).toBe(false);
    } finally {
      if (isRunning(pid)) process.kill(pid, "SIGKILL");
    }
  }, 60_000);

  test.skipIf(!tmuxAvailable())("/mcp alone opens the menu, whose choices run the verbs", async () => {
    const root = createRoot(
      { mcpServers: { fixture: fixtureServer({ env: { FX_MCP_EXPECT_ELICITATION: "both" } }), web: { type: "http", url: "https://w.example/mcp" } } },
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
    // Typing filters its tools, by name or description; the list's filter waits.
    await tui.sendLiteral("zz");
    await tui.waitForText("No tools match.", 5_000);
    await tui.sendKeys("BSpace BSpace");
    await tui.sendLiteral("THROUGH");
    await tui.waitForText("Tools 1 of 1", 5_000);
    await tui.waitForText("Echo text through the modern MCP fixture", 5_000);
    // ↓ goes on into the tools, where Enter has nothing to run.
    await tui.sendKeys("Down");
    await tui.waitForText("↑↓ navigate     esc back", 5_000);
    // Esc goes back, then closes and clears the filter.
    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  1 of 3", 5_000);
    await tui.sendKeys("Escape");
    await tui.waitForPane((pane) => !pane.includes("MCP servers") && !pane.includes("fix"), 5_000);

    // Ctrl+C closes the menu from a server's screen, without arming the exit.
    await tui.sendText("/mcp");
    await tui.waitForText("MCP servers  3", 10_000);
    await tui.sendKeys("Enter");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 10_000);
    // ← goes back to the list like Esc, and → opens the server like Enter.
    await tui.sendKeys("Left");
    await tui.waitForText("↑↓ navigate     enter open     esc close", 5_000);
    await tui.sendKeys("Right");
    await tui.waitForText("↑↓ navigate     enter run     esc back", 10_000);
    await tui.sendKeys("C-c");
    await tui.waitForPane((pane) => !pane.includes("MCP servers") && !pane.includes("esc back"), 5_000);
    expect(await tui.capturePane()).not.toContain("press ctrl+c again to exit");

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

    // Confirmed, it runs `/mcp approve proj`. The menu shows the result, so
    // the conversation doesn't repeat it.
    await tui.sendKeys("Enter");
    await tui.waitForText("enter confirm     esc cancel", 5_000);
    await tui.sendKeys("Enter");
    // The reload follows, and the screen with it.
    await tui.waitForText("› Reject        /mcp reject proj", 10_000);
    expect(await tui.captureFullScrollback()).not.toContain("Approved proj");

    // Remove asks which file it edits; Esc keeps the server, Enter removes it.
    await tui.sendKeys("Escape");
    await tui.waitForText("MCP servers  3", 5_000);
    // Approved, proj works and sorts between fixture and web.
    await tui.sendKeys("Down Enter");
    await tui.waitForText("› Remove        /mcp remove web", 5_000);
    await tui.sendKeys("Enter");
    // It asks on Remove's own row, with its answers; the hint line stays.
    await tui.waitForText("› Remove web from ~/.fx/mcp.json?   yes  no", 5_000);
    expect(await tui.capturePane()).toContain("↑↓ navigate     enter run     esc back");
    // → chooses no, and Enter on no keeps the server.
    await tui.sendKeys("Right Enter");
    await tui.waitForText("› Remove        /mcp remove web", 5_000);
    await tui.waitForText("↑↓ navigate     enter run     esc back", 5_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeDefined();
    await tui.sendKeys("Enter");
    await tui.waitForText("Remove web from ~/.fx/mcp.json?", 5_000);
    await tui.sendKeys("Enter");
    // Its screen goes with it, back to the list, which no longer shows it.
    await tui.waitForText("MCP servers  2", 10_000);
    expect(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers.web).toBeUndefined();
    expect(await tui.captureFullScrollback()).not.toContain("Removed web");
  }, 90_000);

  test.skipIf(!tmuxAvailable())("/mcp names HOME and writes nothing when HOME is not absolute", async () => {
    // fx treats a relative HOME as unset, and the shell's /mcp must not build
    // `.fx/mcp.json` against the workspace instead.
    const root = createRoot();
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 40,
      env: { ...root.env, HOME: "relative/home", FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("/mcp add web https://w.example/mcp");
    await tui.waitForText("/mcp: HOME is not set to an absolute path", 10_000);
    expect(existsSync(join(root.workspace, ".fx"))).toBe(false);
    expect(existsSync(join(root.workspace, "relative"))).toBe(false);
  }, 60_000);
});

describe("fx ask", () => {
  test("fx ask names unapproved project servers and the command that approves them", async () => {
    const root = createRoot(undefined, { mcpServers: { proj: fixtureServer() } });
    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const result = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(result.stderr).toContain("fx ask: skipped unapproved project MCP servers: proj. Approve with fx mcp approve <name> before retrying.");
    expect(result.stderr).not.toContain("trust");
  }, 60_000);

  test("a project server whose name holds an escape sequence is skipped with an escaped note, never printed raw", async () => {
    // An OSC sequence that would retitle the terminal if printed as is.
    const evil = "evil\u001b]0;pwned\u0007";
    const root = createRoot(undefined, { mcpServers: { proj: fixtureServer(), [evil]: fixtureServer() } });
    const note = "note: .mcp.json server 'evil\\x1b]0;pwned\\x07' was skipped: its name has a character fx won't print.";

    const list = await runFx(["mcp", "list"], { cwd: root.workspace, env: root.env, timeoutMs: 30_000 });
    expect(list.code).toBe(0);
    expect(list.stderr).toContain(note);
    expect(list.stdout).toContain("proj");
    expect(list.stdout).not.toContain("evil");
    expect(list.stdout + list.stderr).not.toContain("\u001b");

    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const ask = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(ask.stderr).toContain(note);
    expect(ask.stderr).toContain("fx ask: skipped unapproved project MCP servers: proj. Approve");
    expect(ask.stdout + ask.stderr).not.toContain("\u001b");
  }, 60_000);

  test("a profile with both mcp and mcpServers names each server it leaves out", async () => {
    const root = createRoot({ mcp: { alpha: fixtureServer() }, mcpServers: { beta: fixtureServer() } });
    const note = "note: ~/.fx/mcp.json server 'beta' was skipped: the file has both \"mcp\" and \"mcpServers\", and fx reads only \"mcp\"; merge them into one.";

    const list = await runFx(["mcp", "list"], { cwd: root.workspace, env: root.env, timeoutMs: 30_000 });
    expect(list.code).toBe(0);
    expect(list.stdout).toContain("alpha");
    expect(list.stdout).not.toContain("beta");
    expect(list.stderr).toContain(note);

    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const ask = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 30_000,
    });
    expect(ask.code).toBe(0);
    expect(ask.stderr).toContain(note);
  }, 60_000);
});

// `fx mcp add` and `remove` never save an entry that fx's own reader skips, and
// never rewrite a profile whose servers key looks misspelled. The reader owns
// the rules (src/core/mcp/project_config.zig); these tests check what the
// person sees and that a refused command leaves the file byte for byte as it was.
// A test named "guard: ..." holds on the code before the change.
describe("fx mcp add and remove refuse what fx would skip", () => {
  const PLAIN_HTTP = "fx uses plain http only for localhost, 127.0.0.1 and [::1]; use https";
  const NEEDS_PORT = "a plain http address needs a port, such as http://localhost:8080/mcp";
  const AUTHORIZATION = 'fx won\'t send its Authorization header; put the token in "bearer_token_env", or sign in with login';
  const fixFor = (key: string, real: string) =>
    `the key "${key}" looks like a misspelling of "${real}", so fx doesn't read it. Move its servers into "${real}", then delete "${key}", and run the command again`;

  // createRoot keeps one folder to clean; a test with several roots would leak the earlier ones.
  const earlier: string[] = [];
  const fresh = (profile?: unknown, project?: unknown) => {
    if (cleanup) earlier.push(cleanup);
    cleanup = null;
    return createRoot(profile, project);
  };
  afterEach(() => {
    for (const dir of earlier.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  const bytesOf = (path: string): string | null => (existsSync(path) ? readFileSync(path, "utf8") : null);
  const loaded = async (root: Root) => {
    const list = await mcp(root, "list", "--json");
    expect(list.code).toBe(0);
    return (JSON.parse(list.stdout).servers as { name: string }[]).map((s) => s.name);
  };

  /** A profile of `filler` unrelated top-level keys, then `tail` (the keys that follow them). */
  const bigProfile = (filler: number, tail: Record<string, unknown>) => {
    const object: Record<string, unknown> = {};
    for (let i = 0; i < filler; i++) object[`note${i}`] = i;
    return JSON.stringify({ ...object, ...tail });
  };

  async function refused(root: Root, args: string[], why: string, file = "~/.fx/mcp.json", verb = "add", name = "web", path = root.profilePath) {
    const before = bytesOf(path);
    const ran = await mcp(root, verb, ...args);
    expect(ran.stderr).toBe(`Couldn't ${verb} ${name} ${verb === "add" ? "to" : "from"} ${file}: ${why}.\n`);
    expect(ran.stdout).toBe("");
    expect(ran.code).toBe(1);
    expect(bytesOf(path)).toBe(before);
  }

  test("add refuses plain http to a host that isn't localhost, 127.0.0.1 or [::1], says why, and leaves the file as it was", async () => {
    const none = fresh();
    await refused(none, ["--no-login", "web", "http://example.com/mcp"], PLAIN_HTTP);
    expect(existsSync(none.profilePath)).toBe(false);

    const root = fresh({ theme: "dark", mcpServers: { old: { command: "true" } } });
    await refused(root, ["--no-login", "web", "http://example.com:8080/mcp"], PLAIN_HTTP);
    await refused(root, ["--no-login", "web", "http://localhost.:8080/mcp"], PLAIN_HTTP);
    await refused(root, ["--no-login", "web", "http://127.0.0.2:8080/mcp"], PLAIN_HTTP);
    expect(await loaded(root)).toEqual(["old"]);
  }, 120_000);

  test("add refuses plain http to localhost without a port, and says a port is needed", async () => {
    const root = fresh({ mcpServers: { old: { command: "true" } } });
    await refused(root, ["--no-login", "web", "http://localhost/mcp"], NEEDS_PORT);
    await refused(root, ["--no-login", "web", "http://127.0.0.1/mcp"], NEEDS_PORT);
    await refused(root, ["--no-login", "web", "http://[::1]/mcp"], NEEDS_PORT);
  }, 120_000);

  test("add refuses an address with a user name or password, a #fragment, or no host, each for its own reason", async () => {
    const root = fresh({ mcpServers: { old: { command: "true" } } });
    await refused(root, ["--no-login", "web", "https://user:secret@x.example/mcp"], 'its "url" has a user name or password in it; remove it');
    await refused(root, ["--no-login", "web", "https://x.example/mcp#part"], 'its "url" has a #fragment; remove it');
    await refused(root, ["--no-login", "web", "https:///mcp"], 'its "url" has no host name');
    // The same entries in .mcp.json get the same reasons.
    const project = fresh(undefined, { mcpServers: { old: { command: "true" } } });
    await refused(project, ["--no-login", "--project", "web", "http://example.com/mcp"], PLAIN_HTTP, ".mcp.json", "add", "web", project.projectPath);
  }, 120_000);

  test("add refuses an Authorization header for the profile, in any spelling, with the reader's words", async () => {
    const root = fresh({ mcpServers: { old: { command: "true" } } });
    for (const header of ["Authorization=Bearer abc", "authorization=Bearer abc", "AUTHORIZATION=Bearer abc"]) {
      await refused(root, ["--no-login", "authd", "https://x.example/mcp", "--header", header], AUTHORIZATION, "~/.fx/mcp.json", "add", "authd");
    }
  }, 120_000);

  test("add refuses headers and variables the reader would skip: reserved, duplicate, badly named, or a malformed ${", async () => {
    const root = fresh({ mcpServers: { old: { command: "true" } } });
    const url = "https://x.example/mcp";
    await refused(root, ["--no-login", "web", url, "--header", "Host=a"], 'its "headers" isn\'t valid');
    await refused(root, ["--no-login", "web", url, "--header", "X-A=1", "--header", "x-a=2"], 'its "headers" isn\'t valid');
    await refused(root, ["--no-login", "web", url, "--header", "Bad Header=1"], 'its "headers" isn\'t valid');
    await refused(root, ["--no-login", "web", url, "--header", "X-K=${"], "a ${...} in it isn't valid");
    await refused(root, ["--no-login", "web", url, "--header", "X-K=${1X}"], "a ${...} in it isn't valid");
    await refused(root, ["--env", "K=${", "web", "--", "node", "server.js"], "a ${...} in it isn't valid");
  }, 120_000);

  test("guard: add takes an Authorization header for --project, as .mcp.json allows it", async () => {
    const root = fresh(undefined, { mcpServers: {} });
    const added = await mcp(root, "add", "--no-login", "--project", "authd", "https://x.example/mcp", "--header", "Authorization=Bearer abc");
    expect(added.stderr).toBe("");
    expect(added.code).toBe(0);
    expect(added.stdout).toBe("Added authd to .mcp.json.\n");
    expect(JSON.parse(readFileSync(root.projectPath, "utf8")).mcpServers.authd.headers).toEqual({ Authorization: "Bearer abc" });
  }, 120_000);

  test("guard: add still takes everything the reader loads", async () => {
    const root = fresh();
    const adds: string[][] = [
      ["--no-login", "https", "https://x.example/mcp"],
      ["--no-login", "local1", "http://localhost:8080/mcp"],
      ["--no-login", "local2", "http://127.0.0.1:8080/mcp"],
      ["--no-login", "local3", "http://[::1]:8080/mcp"],
      ["--no-login", "header", "https://x.example/mcp", "--header", "X-Foo=1"],
      ["--no-login", "empty", "https://x.example/mcp", "--header", "X-Foo="],
      ["--no-login", "slack"],
      ["stdio", "--", "node", "server.js"],
    ];
    for (const args of adds) {
      const added = await mcp(root, "add", ...args);
      expect(added.stderr).toBe("");
      expect(added.code).toBe(0);
      expect(added.stdout).toStartWith(`Added ${args.find((a) => !a.startsWith("-"))} to ~/.fx/mcp.json.`);
    }
    expect(await loaded(root)).toEqual(["https", "local1", "local2", "local3", "header", "empty", "slack", "stdio"]);

    // A variable that isn't set holds the server back, and list says which; add still saves it.
    const unset = await mcp(root, "add", "--no-login", "later", "https://x.example/mcp", "--header", "X-K=${FX_VERBS_NOT_SET}");
    expect(unset.code).toBe(0);
    expect(unset.stdout).toBe("Added later to ~/.fx/mcp.json.\n");
    const noted = await mcp(root, "list");
    expect(noted.stderr).toBe("note: ~/.fx/mcp.json server 'later' field http_header requires environment variable 'FX_VERBS_NOT_SET'; set it or use ${FX_VERBS_NOT_SET:-default}.\n");
  }, 120_000);

  test("guard: the duplicate name, both keys, an old bad entry, and the case-sensitive prefix keep today's behavior", async () => {
    const both = fresh({ mcp: { a: { command: "x" } }, mcpServers: { b: { command: "y" } } });
    await refused(both, ["--no-login", "web", "https://x.example/mcp"], 'the file has both "mcp" and "mcpServers"; merge them into one');

    const taken = fresh({ mcpServers: { web: { command: "x" } } });
    await refused(taken, ["--no-login", "web", "https://x.example/mcp"], "that name is already in the file; remove it first");

    // An entry already in the file that the reader skips doesn't stop a good one.
    const old = fresh({ mcpServers: { broken: { type: "http", url: "http://example.com/mcp" } } });
    const added = await mcp(old, "add", "--no-login", "web", "https://x.example/mcp");
    expect(added.code).toBe(0);
    expect(await loaded(old)).toEqual(["web"]);

    // add's own prefix check is case-sensitive: a usage mistake, exit 2, before anything is read.
    const upper = await mcp(fresh(), "add", "--no-login", "web", "HTTPS://x.example/mcp");
    expect(upper.code).toBe(2);
    expect(upper.stderr).toStartWith("'HTTPS://x.example/mcp' isn't a URL. A stdio server's command goes after --.\n");
  }, 120_000);

  test("add refuses a profile whose servers key looks misspelled, names the key, and gives the fix", async () => {
    const cases: { text: string; key: string; real: string }[] = [
      { text: '{"mcp_servers":{"a":{"command":"x"}}}', key: "mcp_servers", real: "mcpServers" },
      { text: '{"theme":"dark","servers":{"a":{"command":"x"}},"mcpServers":{"b":{"command":"y"}}}', key: "servers", real: "mcpServers" },
      { text: '{"MCP-Servers":{"a":{"command":"x"}},"mcp":{"b":{"command":"y"}}}', key: "MCP-Servers", real: "mcp" },
    ];
    for (const c of cases) {
      const root = fresh(c.text);
      await refused(root, ["--no-login", "web", "https://x.example/mcp"], fixFor(c.key, c.real));
      await refused(root, ["web", "--", "node", "server.js"], fixFor(c.key, c.real));
    }
  }, 120_000);

  test("guard: a misspelled key in the profile doesn't stop add --project, and a key that holds no servers isn't a misspelling", async () => {
    const root = fresh({ mcp_servers: { a: { command: "x" } } }, { mcpServers: {} });
    const project = await mcp(root, "add", "--no-login", "--project", "web", "https://x.example/mcp");
    expect(project.code).toBe(0);
    expect(project.stdout).toBe("Added web to .mcp.json.\n");

    const notes = fresh({ servers: { note: 1 }, mcpServers: {} });
    const added = await mcp(notes, "add", "--no-login", "web", "https://x.example/mcp");
    expect(added.stderr).toBe("");
    expect(added.code).toBe(0);
  }, 120_000);

  test("remove refuses to rewrite a profile whose servers key looks misspelled, names the key, and gives the fix", async () => {
    const root = fresh({ mcpServers: { a: { command: "x" } }, servers: { b: { command: "y" } } });
    await refused(root, ["a"], fixFor("servers", "mcpServers"), "~/.fx/mcp.json", "remove", "a");
    const withMcp = fresh({ mcp: { a: { command: "x" } }, mcp_servers: { b: { command: "y" } } });
    await refused(withMcp, ["a"], fixFor("mcp_servers", "mcp"), "~/.fx/mcp.json", "remove", "a");
  }, 120_000);

  // The line after "No MCP server named ...": the profile does list the name, under a key that fx doesn't read.
  const listedUnder = (name: string, why: string) => `${name} is in ~/.fx/mcp.json, but ${why}.\n`;

  test("remove of a name that only the misspelled key holds says so, names the key and the fix, and leaves the file as it was", async () => {
    const root = fresh({ mcpServers: { a: { command: "x" } }, servers: { b: { command: "y" } } }, { mcpServers: { p: { command: "z" } } });
    const before = readFileSync(root.profilePath, "utf8");
    const fix = fixFor("servers", "mcpServers");
    const missing = await mcp(root, "remove", "b");
    expect(missing.code).toBe(1);
    expect(missing.stdout).toBe("");
    expect(missing.stderr).toBe(`No MCP server named b in ~/.fx/mcp.json or .mcp.json.\n${listedUnder("b", fix)}`);
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
    // --global looks only in the profile, and says so as before; --project looks only in .mcp.json, which has no misspelled-key check.
    const global = await mcp(root, "remove", "--global", "b");
    expect(global.code).toBe(1);
    expect(global.stderr).toBe(`No MCP server named b in ~/.fx/mcp.json.\n${listedUnder("b", fix)}`);
    const project = await mcp(root, "remove", "--project", "b");
    expect(project.code).toBe(1);
    expect(project.stderr).toBe("No MCP server named b in .mcp.json.\n");
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
    // The real key is "mcp" when the profile has it.
    const withMcp = fresh({ mcp: { a: { command: "x" } }, mcp_servers: { b: { command: "y" } } });
    const withMcpBefore = readFileSync(withMcp.profilePath, "utf8");
    const named = await mcp(withMcp, "remove", "b");
    expect(named.code).toBe(1);
    expect(named.stderr).toBe(`No MCP server named b in ~/.fx/mcp.json or .mcp.json.\n${listedUnder("b", fixFor("mcp_servers", "mcp"))}`);
    expect(readFileSync(withMcp.profilePath, "utf8")).toBe(withMcpBefore);
    // Once the servers are moved and the key is gone, the name is where fx reads it, and the same command removes it.
    writeFileSync(withMcp.profilePath, JSON.stringify({ mcp: { a: { command: "x" }, b: { command: "y" } } }));
    const fixed = await mcp(withMcp, "remove", "b");
    expect(fixed.code).toBe(0);
    expect(fixed.stdout).toBe("Removed b from ~/.fx/mcp.json.\n");
  }, 120_000);

  test("guard: remove of a project server leaves the profile as it was, and a name in neither file gets no hint", async () => {
    const root = fresh({ mcpServers: { a: { command: "x" } }, servers: { b: { command: "y" } } }, { mcpServers: { p: { command: "z" } } });
    const before = readFileSync(root.profilePath, "utf8");
    const project = await mcp(root, "remove", "p");
    expect(project.code).toBe(0);
    expect(project.stdout).toBe("Removed p from .mcp.json.\n");
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
    const none = await mcp(root, "remove", "nope");
    expect(none.code).toBe(1);
    expect(none.stderr).toBe("No MCP server named nope in ~/.fx/mcp.json or .mcp.json.\n");
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
  }, 120_000);

  test("the hint finds the name as the reader does: under a key or name written with an escape, under a key too long to show whole, and only when the name is a server there", async () => {
    // "mcp\u005fservers" is the key mcp_servers, and "b\u0062" the name bb, as JSON reads them.
    const escaped = fresh('{"mcpServers":{"a":{"command":"x"}},"mcp\\u005fservers":{"b\\u0062":{"command":"y"}}}');
    const escapedBefore = bytesOf(escaped.profilePath);
    const found = await mcp(escaped, "remove", "bb");
    expect(found.code).toBe(1);
    expect(found.stderr).toBe(`No MCP server named bb in ~/.fx/mcp.json or .mcp.json.\n${listedUnder("bb", fixFor("mcp_servers", "mcpServers"))}`);
    expect(bytesOf(escaped.profilePath)).toBe(escapedBefore);

    // 11 + 140 bytes: a cut at 128 bytes lands inside a character, so the key is named by how it starts.
    const wide = "mcp_servers" + "\u00e9".repeat(70);
    const long = fresh({ mcpServers: { a: { command: "x" } }, [wide]: { b: { command: "y" } } });
    const longBefore = bytesOf(long.profilePath);
    const cut = await mcp(long, "remove", "b");
    expect(cut.code).toBe(1);
    expect(cut.stdout).toBe("");
    const lines = cut.stderr.split("\n");
    expect(lines[0]).toBe("No MCP server named b in ~/.fx/mcp.json or .mcp.json.");
    expect(cut.stderr).not.toContain("\ufffd");
    expect(cut.stderr).not.toContain("\\xc3");
    expect(lines[1]).toContain('b is in ~/.fx/mcp.json, but the key that starts with "mcp_servers\u00e9');
    expect(lines[1]).not.toContain('the key "mcp_servers');
    expect(lines[1]).toContain(`" looks like a misspelling of "mcpServers", so fx doesn't read it. Move its servers into "mcpServers", then delete that key, and run the command again.`);
    const quoted = lines[1].slice(lines[1].indexOf('starts with "') + 'starts with "'.length, lines[1].indexOf('" looks like'));
    expect(wide.startsWith(quoted)).toBe(true);
    expect(bytesOf(long.profilePath)).toBe(longBefore);

    // No hint where the name is not a server of a misspelled key: not in it, in a key that is not a misspelling,
    // or in it as something that is not a server. The first line is the one it always was.
    const plain = "No MCP server named b in ~/.fx/mcp.json or .mcp.json.\n";
    for (const profile of [
      { mcpServers: { a: { command: "x" } }, servers: { c: { command: "y" } } },
      { mcpServers: { a: { command: "x" } }, notes: { b: { command: "y" } } },
      { mcpServers: { a: { command: "x" } }, servers: { b: 1, c: { command: "y" } } },
      { mcpServers: { a: { command: "x" } }, servers: { b: 1 } },
    ]) {
      const root = fresh(profile);
      const before = bytesOf(root.profilePath);
      const ran = await mcp(root, "remove", "b");
      expect(ran.code).toBe(1);
      expect(ran.stderr).toBe(plain);
      expect(bytesOf(root.profilePath)).toBe(before);
    }
  }, 120_000);

  test("the edit check reads every key: a misspelled key after 64 others, or after 64 entries that aren't servers, is found", async () => {
    const last = fresh(bigProfile(64, { mcpServers: { a: { command: "x" } }, mcp_servers: { b: { command: "y" } } }));
    await refused(last, ["--no-login", "web", "https://x.example/mcp"], fixFor("mcp_servers", "mcpServers"));
    await refused(last, ["a"], fixFor("mcp_servers", "mcpServers"), "~/.fx/mcp.json", "remove", "a");

    const wide: Record<string, unknown> = {};
    for (let i = 0; i < 64; i++) wide[`n${i}`] = i;
    wide.real = { command: "y" };
    const deep = fresh({ mcpServers: { a: { command: "x" } }, servers: wide });
    await refused(deep, ["--no-login", "web", "https://x.example/mcp"], fixFor("servers", "mcpServers"));

    // 64 entries that aren't servers come first, so a scan that stops at 64 entries misses the 70 servers after them.
    const many: Record<string, unknown> = {};
    for (let i = 0; i < 64; i++) many[`n${i}`] = i;
    for (let i = 0; i < 70; i++) many[`s${i}`] = { command: "y" };
    const crowd = fresh({ mcpServers: { a: { command: "x" } }, mcp_servers: many });
    await refused(crowd, ["--no-login", "web", "https://x.example/mcp"], fixFor("mcp_servers", "mcpServers"));
  }, 120_000);

  test("a misspelled key too long to show whole is named by how it starts, cut at a character, and the file is left as it was", async () => {
    // 11 + 140 bytes: a cut at 128 bytes lands inside a character.
    const wide = "mcp_servers" + "\u00e9".repeat(70);
    const root = fresh({ mcpServers: { a: { command: "x" } }, [wide]: { b: { command: "y" } } });
    const before = bytesOf(root.profilePath);
    const ran = await mcp(root, "add", "--no-login", "web", "https://x.example/mcp");
    expect(ran.code).toBe(1);
    expect(ran.stdout).toBe("");
    // The words are valid UTF-8 with no cut character, and name no key that the file lacks.
    const words = ran.stderr;
    expect(words).not.toContain("\ufffd");
    expect(words).not.toContain("\\xc3");
    expect(words).toContain(`Couldn't add web to ~/.fx/mcp.json: the key that starts with "mcp_servers\u00e9`);
    expect(words).not.toContain('the key "mcp_servers');
    expect(words).toContain(`" looks like a misspelling of "mcpServers", so fx doesn't read it. Move its servers into "mcpServers", then delete that key, and run the command again.\n`);
    const quoted = words.slice(words.indexOf('starts with "') + 'starts with "'.length, words.indexOf('" looks like'));
    expect(wide.startsWith(quoted)).toBe(true);
    expect(bytesOf(root.profilePath)).toBe(before);
  }, 120_000);

  test("a misspelled key whose terminal-safe text is cut is named by how it starts, in the skip note and in the refusal", async () => {
    // 111 bytes, so the load scan reads it, but each control character shows as four, and the words show only the start.
    const key = "mcp_servers" + "\u0001".repeat(100);
    const root = fresh({ mcpServers: { a: { command: "x" } }, [key]: { b: { command: "y" } } });
    const list = await mcp(root, "list");
    const start = String.raw`the key that starts with "mcp_servers(\\x01)+\.\.\."`;
    const tail = String.raw` looks like a misspelling of "mcpServers", so fx doesn't read it\. Move its servers into "mcpServers", then delete that key`;
    expect(list.stderr).toMatch(new RegExp(String.raw`^note: ~/\.fx/mcp\.json: ${start}${tail}\.\n$`));
    const before = bytesOf(root.profilePath);
    const ran = await mcp(root, "add", "--no-login", "web", "https://x.example/mcp");
    expect(ran.code).toBe(1);
    expect(ran.stderr).toMatch(new RegExp(String.raw`^Couldn't add web to ~/\.fx/mcp\.json: ${start}${tail}, and run the command again\.\n$`));
    expect(bytesOf(root.profilePath)).toBe(before);
  }, 120_000);

  test("guard: a profile with 65 or more top-level keys and no misspelled key still takes add and remove", async () => {
    const root = fresh(bigProfile(70, { mcpServers: { a: { command: "x" } } }));
    const added = await mcp(root, "add", "--no-login", "web", "https://x.example/mcp");
    expect(added.stderr).toBe("");
    expect(added.code).toBe(0);
    const removed = await mcp(root, "remove", "a");
    expect(removed.code).toBe(0);
    expect(removed.stdout).toBe("Removed a from ~/.fx/mcp.json.\n");
    expect(await loaded(root)).toEqual(["web"]);
  }, 120_000);

  test("the skip note for an address fx won't use says why, in the words add refuses with", async () => {
    const entry = (url: string) => ({ type: "http", url });
    const cases: [string, string][] = [
      ["http://example.com/mcp", PLAIN_HTTP],
      ["http://localhost.:8080/mcp", PLAIN_HTTP],
      ["http://localhost/mcp", NEEDS_PORT],
      ["https://user:secret@x.example/mcp", 'its "url" has a user name or password in it; remove it'],
      ["https://x.example/mcp#part", 'its "url" has a #fragment; remove it'],
      ["https:///mcp", 'its "url" has no host name'],
      ["ftp://x.example/mcp", 'its "url" must start with https:// (or http:// for localhost)'],
    ];
    for (const [url, why] of cases) {
      const root = fresh({ mcpServers: { web: entry(url), ok: entry("https://x.example/mcp") } });
      const list = await mcp(root, "list");
      expect(list.stderr).toBe(`note: ~/.fx/mcp.json server 'web' was skipped: ${why}.\n`);
      expect(list.stdout).toContain("ok");
      expect(list.stdout).not.toContain("web");
    }
    // The notes for the other fields keep their words.
    const headers = fresh({ mcpServers: { web: { type: "http", url: "https://x.example/mcp", headers: { Host: "a" } } } });
    expect((await mcp(headers, "list")).stderr).toBe('note: ~/.fx/mcp.json server \'web\' was skipped: its "headers" isn\'t valid.\n');
  }, 120_000);

  test("list says at load that a misspelled servers key is not read, and gives the same fix", async () => {
    const root = fresh({ mcpServers: { a: { command: "x" } }, mcp_servers: { b: { command: "y" } } });
    const list = await mcp(root, "list");
    expect(list.code).toBe(0);
    expect(list.stdout).toContain("a ");
    expect(list.stderr).toBe(
      'note: ~/.fx/mcp.json: the key "mcp_servers" looks like a misspelling of "mcpServers", so fx doesn\'t read it. Move its servers into "mcpServers", then delete "mcp_servers".\n',
    );
  }, 120_000);

  test("fx ask says at load that a misspelled servers key is not read, and gives the fix", async () => {
    const root = fresh({ mcpServers: { a: fixtureServer() }, servers: { b: fixtureServer() } });
    const note =
      'note: ~/.fx/mcp.json: the key "servers" looks like a misspelling of "mcpServers", so fx doesn\'t read it. Move its servers into "mcpServers", then delete "servers".';
    gateway = startFakeGateway([fakeGatewayFinalText("done")], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    const ask = await runFx(["ask", "--no-save", "hello"], {
      cwd: root.workspace,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
      timeoutMs: 60_000,
    });
    expect(ask.code).toBe(0);
    expect(ask.stderr).toContain(note);
  }, 120_000);

  test.skipIf(!tmuxAvailable())("the shell's status line counts a misspelled servers key as a config problem, and /mcp list gives the fix", async () => {
    const root = fresh({ mcpServers: { a: { command: "true" } }, mcp_servers: { b: { command: "true" } } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 200,
      height: 36,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    await tui.waitForText("MCP config has 1 problem · /mcp list", 10_000);
    await tui.sendText("/mcp list");
    await tui.waitForText('the key "mcp_servers" looks like a misspelling of "mcpServers", so fx doesn\'t read it.', 10_000);
    await tui.waitForText('Move its servers into "mcpServers", then delete "mcp_servers".', 10_000);
  }, 120_000);

  test.skipIf(!tmuxAvailable())("/mcp add and /mcp remove print the same refusals and the shell keeps running", async () => {
    const root = fresh({ mcpServers: { a: { command: "true" } }, servers: { b: { command: "true" } } });
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 220,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const before = readFileSync(root.profilePath, "utf8");
    await tui.sendText("/mcp add web https://x.example/mcp");
    await tui.waitForText(`Couldn't add web to ~/.fx/mcp.json: ${fixFor("servers", "mcpServers")}.`, 10_000);
    await tui.sendText("/mcp remove a");
    await tui.waitForText(`Couldn't remove a from ~/.fx/mcp.json: ${fixFor("servers", "mcpServers")}.`, 10_000);
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
    // The shell still answers.
    await tui.sendText("/mcp list");
    await tui.waitForText("~/.fx/mcp.json", 10_000);
    await tui.sendText("/mcp add --no-login --project web https://x.example/mcp");
    await tui.waitForText("Added web to .mcp.json.", 10_000);
  }, 90_000);

  // A file nested past the limit (src/core/shared/json_depth.zig) is not rewritten: the writer aborts the whole
  // process from 257 levels. The reader still loads such a file.
  const nested = (levels: number, server = "old") => `{"mcpServers":{"${server}":{"command":"true"}},"notes":${"[".repeat(levels)}${"]".repeat(levels)}}`;
  const TOO_DEEP = "the file is nested more than 64 levels deep; flatten it by hand first";

  test("add and remove refuse a file nested past the limit, however deep, and leave it as it was", async () => {
    for (const levels of [64, 256, 300, 400_000]) {
      const root = fresh(nested(levels));
      writeFileSync(root.projectPath, nested(levels, "proj"));
      for (const [flag, file, path, server] of [["--global", "~/.fx/mcp.json", root.profilePath, "old"], ["--project", ".mcp.json", root.projectPath, "proj"]] as const) {
        await refused(root, ["--no-login", flag, "web", "https://mcp.example/mcp"], TOO_DEEP, file, "add", "web", path);
        await refused(root, [flag, server], TOO_DEEP, file, "remove", server, path);
      }
      expect((await loaded(root)).sort()).toEqual(["old", "proj"]);
    }
  }, 120_000);

  test("guard: a file at the limit is edited, and a deep file beside the one being edited does not stop it", async () => {
    const root = fresh(nested(63));
    const added = await mcp(root, "add", "--no-login", "web", "https://mcp.example/mcp");
    expect(added.stderr).toBe("");
    expect(added.stdout).toBe("Added web to ~/.fx/mcp.json.\n");
    expect(Object.keys(JSON.parse(readFileSync(root.profilePath, "utf8")).mcpServers)).toEqual(["old", "web"]);
    const removed = await mcp(root, "remove", "--global", "old");
    expect(removed.stdout).toBe("Removed old from ~/.fx/mcp.json.\n");

    writeFileSync(root.profilePath, nested(400_000));
    const profile = bytesOf(root.profilePath);
    const project = await mcp(root, "add", "--no-login", "--project", "web", "https://mcp.example/mcp");
    expect(project.stderr).toBe("");
    expect(project.code).toBe(0);
    expect(project.stdout).toStartWith("Added web to .mcp.json.\n");
    expect(bytesOf(root.profilePath)).toBe(profile);
  }, 60_000);

  test.skipIf(!tmuxAvailable())("/mcp add and /mcp remove refuse a file nested past the limit and the shell keeps running", async () => {
    const root = fresh(nested(300));
    gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 220,
      height: 40,
      env: { ...root.env, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: "openai/gpt-5" },
    });
    await tui.waitForComposer(15_000);
    const before = readFileSync(root.profilePath, "utf8");
    await tui.sendText("/mcp add web https://x.example/mcp");
    await tui.waitForText(`Couldn't add web to ~/.fx/mcp.json: ${TOO_DEEP}.`, 10_000);
    await tui.sendText("/mcp remove old");
    await tui.waitForText(`Couldn't remove old from ~/.fx/mcp.json: ${TOO_DEEP}.`, 10_000);
    expect(readFileSync(root.profilePath, "utf8")).toBe(before);
    await tui.sendText("/mcp add --no-login --project web https://x.example/mcp");
    await tui.waitForText("Added web to .mcp.json.", 10_000);
  }, 90_000);
});
