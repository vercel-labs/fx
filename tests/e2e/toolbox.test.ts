import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import { fakeGatewayFinalText, fakeGatewayToolCall, startDynamicFakeGateway, startFakeGateway } from "./tmux-helpers";
import { manyMcpServerName, startManyMcpHttpServers } from "./fixtures/mcp-many";

// The toolbox: fx sends its built-in tools as they are, plus one `toolbox`
// tool, and lists skills, MCP servers, and custom tools in a short menu
// instead of sending all of them. The model opens an entry, or runs a tool,
// through `toolbox`; what it opens arrives at the end of the conversation, so
// no request ever changes what an earlier request sent.

const MODEL = "openai/gpt-5";
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const MCP_TOOL = "mcp_fixture_echo";
const MCP_RESULT = "TOOLBOX_MCP_TOOL_RESULT";
const SKILL_BODY = "TOOLBOX_SKILL_BODY: review each changed file and cite file:line.";

// The built-in tools `fx ask --no-save` sends, in order, with toolbox in the
// place of the tools it replaces. `subagent` needs a saved session.
const NO_SAVE_TOOLS = [
  "read_file",
  "glob_files",
  "grep_files",
  "edit_file",
  "write_file",
  "shell",
  "toolbox",
  "ask_user_question",
  "web_fetch",
  "exa_search",
  "read_tool_result",
  // The gateway adds fx's vision tool for models without native image input.
  "vision",
];
const REPLACED_TOOLS = ["capability_search", "mcp_select_tool", "skill", "install_skill"];

type Root = { root: string; home: string; workspace: string; wireLogPath: string };

let cleanup: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;

afterEach(() => {
  gateway?.stop();
  gateway = null;
  if (cleanup) cleanupIsolatedTestHome(cleanup);
  cleanup = null;
});

function createRoot(): Root {
  const root = realpathSync(createIsolatedTestHome());
  cleanup = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const wireLogPath = join(root, "mcp-wire.jsonl");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, MODERN_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_WIRE_LOG: wireLogPath,
            FX_MCP_PID_PATH: join(root, "mcp.pid"),
            FX_MCP_MODE: "normal",
            FX_MCP_RESULT_TEXT: MCP_RESULT,
          },
        },
      },
    }),
  );
  writeSkill(home, "demo-review", "Review one pull request and report problems with file:line cites.", SKILL_BODY);
  writeSkill(home, "demo-release", "Cut a release from the changelog to the public download.", "Release steps.");
  return { root, home, workspace, wireLogPath };
}

function writeSkill(home: string, name: string, description: string, skillBody: string) {
  const dir = join(home, ".fx", "skills", name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), `---\nname: ${name}\ndescription: ${description}\n---\n\n# ${name}\n\n${skillBody}\n`);
}

function env(root: Root, active: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-toolbox-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: active.baseUrl,
    FX_GATEWAY_CHAT_URL: active.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: active.chatUrl,
    FX_MODEL: MODEL,
  };
}

function start(steps: unknown[]) {
  gateway = startFakeGateway(steps as never, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  return gateway;
}

type Body = { prompt: Array<Record<string, unknown>>; tools?: Array<Record<string, unknown>> };

function body(raw: string): Body {
  return JSON.parse(raw) as Body;
}

function toolNames(request: Body): string[] {
  return (request.tools ?? []).map((tool) => String(tool.name ?? tool.id));
}

// The tool name a request gives the result of call `id`. Providers match it
// against the name of the call it answers, which for a run is toolbox.
function toolResultName(request: Body, id: string): string | undefined {
  for (const message of request.prompt) {
    if (message.role !== "tool" || !Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && part.toolCallId === id) return String(part.toolName);
    }
  }
  return undefined;
}

function systemTexts(request: Body): string[] {
  return request.prompt.filter((message) => message.role === "system").map((message) => contentText(message.content));
}

// Model requests carry tools; fx's side requests, such as the session title,
// carry none.
function modelRequests(active: ReturnType<typeof startFakeGateway>): string[] {
  return active.requests.map((request) => request.body).filter((raw) => (body(raw).tools ?? []).length > 0);
}

// Cache markers sit on the newest message on purpose and move as the
// conversation grows; everything else must stay byte-for-byte the same.
function withoutCacheMarkers(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutCacheMarkers);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) {
      if (key === "providerOptions") continue;
      out[key] = withoutCacheMarkers(item);
    }
    return out;
  }
  return value;
}

// Every request starts with exactly what the request before it sent: the same
// tools, and its messages as a prefix of the next request's.
function expectEveryRequestExtendsThePrevious(raws: string[]) {
  for (let i = 1; i < raws.length; i++) {
    const before = body(raws[i - 1]!);
    const after = body(raws[i]!);
    expect(JSON.stringify(after.tools)).toBe(JSON.stringify(before.tools));
    const earlier = before.prompt.map((message) => JSON.stringify(withoutCacheMarkers(message)));
    const later = after.prompt.slice(0, earlier.length).map((message) => JSON.stringify(withoutCacheMarkers(message)));
    expect(later).toEqual(earlier);
  }
}

function toolResultText(request: Body, callId: string): string {
  for (const message of request.prompt) {
    if (message.role !== "tool" || !Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.toolCallId === callId) return JSON.stringify(part.output ?? part.result ?? part);
    }
  }
  return "";
}

// The text a tool result carries, as the model reads it.
function resultValue(request: Body, callId: string): string {
  const raw = toolResultText(request, callId);
  if (!raw) return "";
  const wrapped = JSON.parse(raw) as { value?: unknown };
  return typeof wrapped.value === "string" ? wrapped.value : JSON.stringify(wrapped.value ?? "");
}

type SearchRow = { name: string; arguments?: { properties?: Record<string, unknown>; required?: string[] }; open_for_arguments?: boolean };

function wireCalls(path: string): Array<Record<string, any>> {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.message?.method === "tools/call");
}

describe("toolbox", () => {
  test("the first request sends the built-in tools, toolbox, and a short menu instead of the skill list and MCP block", async () => {
    const root = createRoot();
    const active = start([fakeGatewayFinalText("TOOLBOX_MENU_DONE")]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Say hi."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const first = body(modelRequests(active)[0]!);

    expect(toolNames(first)).toEqual(NO_SAVE_TOOLS);
    for (const replaced of REPLACED_TOOLS) expect(toolNames(first)).not.toContain(replaced);

    // The toolbox tool itself names nothing from this profile, so its
    // definition is the same in every workspace.
    const toolbox = (first.tools ?? []).find((tool) => tool.name === "toolbox")!;
    expect(JSON.stringify(toolbox)).not.toContain("demo-review");
    expect(JSON.stringify(toolbox)).not.toContain("fixture");

    const system = systemTexts(first).join("\n");
    expect(system).not.toContain("<available_skills>");
    expect(system).not.toContain("Configured MCP servers visible to this model turn");
    const menu = systemTexts(first).find((text) => text.includes("demo-review"));
    expect(menu).toBeDefined();
    expect(menu).toContain("demo-review: Review one pull request and report problems with file:line cites.");
    expect(menu).toContain("demo-release: Cut a release from the changelog to the public download.");
    expect(menu).toContain("fixture");
    expect(menu).toContain("install_skill");
  }, 40_000);

  test("toolbox opens an MCP server and runs its tool without changing anything earlier requests sent", async () => {
    const root = createRoot();
    const active = start([
      fakeGatewayToolCall("open_fixture", "toolbox", { open: "fixture" }),
      fakeGatewayToolCall("run_echo", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
      fakeGatewayFinalText("TOOLBOX_RUN_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Use the fixture echo tool."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("TOOLBOX_RUN_DONE");

    const raws = modelRequests(active);
    expect(raws.length).toBe(3);
    expect(toolResultText(body(raws[1]!), "open_fixture")).toContain(MCP_TOOL);
    expect(toolResultText(body(raws[2]!), "run_echo")).toContain(MCP_RESULT);
    expect(toolResultName(body(raws[2]!), "run_echo")).toBe("toolbox");

    const calls = wireCalls(root.wireLogPath);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.message.params.name).toBe("echo");
    expect(calls[0]!.message.params.arguments).toEqual({ text: "hello" });

    // fx ask reports the tool that actually ran.
    const json = JSON.parse(result.stdout);
    expect((json.tool_calls as Array<{ name: string }>).map((call) => call.name)).toContain(MCP_TOOL);

    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("toolbox opens a skill and returns its instructions", async () => {
    const root = createRoot();
    const active = start([
      fakeGatewayToolCall("open_skill", "toolbox", { open: "demo-review" }),
      fakeGatewayFinalText("TOOLBOX_SKILL_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Review this change."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(2);
    expect(toolResultText(body(raws[1]!), "open_skill")).toContain("TOOLBOX_SKILL_BODY");
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("toolbox opens a built-in tool behind it and returns its definition", async () => {
    const root = createRoot();
    const active = start([
      fakeGatewayToolCall("open_builtin", "toolbox", { open: "install_skill" }),
      fakeGatewayFinalText("TOOLBOX_BUILTIN_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Install a skill."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(2);
    const opened = toolResultText(body(raws[1]!), "open_builtin");
    // The result arrives JSON-encoded, so match words rather than quoting.
    expect(opened).toContain("install_skill");
    expect(opened).toContain("inputSchema");
    expect(opened).toContain("source");
    expect(opened).toContain("Run it with toolbox run");
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("control characters in a toolbox target reach fx ask's progress rows as visible text", async () => {
    const root = createRoot();
    // A window title, a bell, and a clear screen, as a model could send.
    const active = start([
      fakeGatewayToolCall("open_escape", "toolbox", { open: "probe\u001b]0;owned\u0007\u001b[2J" }),
      fakeGatewayFinalText("TOOLBOX_ESCAPE_DONE"),
    ]);
    const result = await runFx(["ask", "--auto", "--no-save", "Open it."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stderr).toContain("probe");
    expect(result.stderr).not.toContain("\u001b");
    expect(result.stderr).not.toContain("\u0007");
  }, 40_000);

  test("a deny rule on the real tool stops toolbox run before the tool runs", async () => {
    const root = createRoot();
    writeFileSync(
      join(root.home, ".fx", "settings.json"),
      JSON.stringify({ permission: { install_skill: "deny", [MCP_TOOL]: "deny" } }),
    );
    const source = join(root.root, "source", "denied-skill");
    mkdirSync(source, { recursive: true });
    writeFileSync(join(source, "SKILL.md"), "---\nname: denied-skill\ndescription: never installed\n---\n\nBody.\n");
    const active = start([
      fakeGatewayToolCall("run_builtin", "toolbox", { run: "install_skill", arguments: { source: join(root.root, "source") } }),
      fakeGatewayToolCall("run_mcp", "toolbox", { run: MCP_TOOL, arguments: { text: "hello" } }),
      fakeGatewayFinalText("TOOLBOX_DENIED_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Install the skill and echo hello."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(3);
    const builtin = toolResultText(body(raws[1]!), "run_builtin");
    const mcp = toolResultText(body(raws[2]!), "run_mcp");
    expect(builtin).not.toContain("Installed");
    expect(mcp).not.toContain(MCP_RESULT);
    expect(existsSync(join(root.home, ".fx", "skills", "denied-skill"))).toBe(false);
    expect(existsSync(root.wireLogPath) ? wireCalls(root.wireLogPath) : []).toEqual([]);
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("rules for skill and capability_search decide toolbox open and search", async () => {
    const root = createRoot();
    writeFileSync(
      join(root.home, ".fx", "settings.json"),
      JSON.stringify({ permission: { skill: { "demo-review": "deny" }, capability_search: "deny" } }),
    );
    const active = start([
      fakeGatewayToolCall("open_denied", "toolbox", { open: "demo-review" }),
      fakeGatewayToolCall("search_denied", "toolbox", { search: "review" }),
      fakeGatewayFinalText("TOOLBOX_RULES_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Review this change."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(3);
    expect(toolResultText(body(raws[1]!), "open_denied")).not.toContain("TOOLBOX_SKILL_BODY");
    expect(toolResultText(body(raws[2]!), "search_denied")).not.toContain("Review one pull request");
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("a direct call of an MCP tool fx didn't send points at toolbox run and leaves the tools unchanged", async () => {
    const root = createRoot();
    const active = start([
      fakeGatewayToolCall("direct_mcp", MCP_TOOL, { text: "hello" }),
      fakeGatewayFinalText("TOOLBOX_DIRECT_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Echo hello."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(2);
    const output = toolResultText(body(raws[1]!), "direct_mcp");
    expect(output).toContain("toolbox");
    expect(output).not.toContain(MCP_RESULT);
    expect(existsSync(root.wireLogPath) ? wireCalls(root.wireLogPath) : []).toEqual([]);
    expect(toolNames(body(raws[1]!))).toEqual(toolNames(body(raws[0]!)));
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("tool placement moves a built-in tool behind toolbox or out of it for the run", async () => {
    const root = createRoot();
    // The profile sends install_skill directly; the flag puts glob_files
    // behind toolbox for this run.
    writeFileSync(join(root.home, ".fx", "settings.json"), JSON.stringify({ tool_placement: { install_skill: "direct" } }));
    writeFileSync(join(root.workspace, "PLACEMENT_NOTES.md"), "notes\n");
    const active = start([
      fakeGatewayToolCall("find_glob", "toolbox", { search: "list files" }),
      fakeGatewayToolCall("run_glob", "toolbox", { run: "glob_files", arguments: { pattern: "*.md" } }),
      fakeGatewayFinalText("TOOL_PLACEMENT_DONE"),
    ]);
    const result = await runFx(["--tool-placement", "glob_files=toolbox", "ask", "--json", "--auto", "--no-save", "List the markdown files."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("TOOL_PLACEMENT_DONE");

    const raws = modelRequests(active);
    expect(raws.length).toBe(3);
    const first = body(raws[0]!);
    expect(toolNames(first)).not.toContain("glob_files");
    expect(toolNames(first)).toContain("install_skill");
    const menu = systemTexts(first).find((text) => text.includes("<toolbox>")) ?? "";
    expect(menu).toContain("Tools\n- glob_files:");
    expect(menu).not.toContain("install_skill");

    // A search finds the built-in tools behind toolbox too, and doesn't say
    // it found nothing.
    const wrapped = JSON.parse(toolResultText(body(raws[1]!), "find_glob")) as { value?: string };
    const found = JSON.parse(wrapped.value ?? "{}") as { tools?: Array<{ name: string }>; counts?: { tools?: number }; state?: string };
    expect((found.tools ?? []).map((tool) => tool.name)).toContain("glob_files");
    expect(found.counts?.tools).toBe(found.tools?.length);
    expect(found.state).not.toBe("no_match");

    // The run is the agent's own glob_files call, answered under toolbox.
    expect(toolResultText(body(raws[2]!), "run_glob")).toContain("PLACEMENT_NOTES.md");
    expect(toolResultName(body(raws[2]!), "run_glob")).toBe("toolbox");
    expect(toolNames(body(raws[2]!))).toEqual(toolNames(first));
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("a subagent's profile limits what it runs and opens through toolbox", async () => {
    const root = createRoot();
    // The profile lists mcp_select_tool, one of the tools toolbox replaced,
    // so the child gets toolbox, but not shell and not skill.
    const profileDir = join(root.home, ".fx", "agents", "limited");
    mkdirSync(profileDir, { recursive: true });
    writeFileSync(join(profileDir, "profile.json"), JSON.stringify({
      description: "Reads files and uses the fixture",
      tools: ["read_file", "mcp_select_tool"],
      mcp_servers: ["fixture"],
    }));
    const childTask = "TOOLBOX_CHILD_TASK";
    const marker = join(root.root, "shell-ran");
    const childBodies: string[] = [];
    const latestUser = (body: string) =>
      JSON.stringify((JSON.parse(body) as Body).prompt.filter((message) => message.role === "user").at(-1) ?? "");
    gateway = startDynamicFakeGateway((body) => {
      if (latestUser(body).includes("Subagent report")) return fakeGatewayFinalText("TOOLBOX_PARENT_DONE");
      // A model request of the child's: fx's side requests carry no tools.
      if (body.includes(childTask) && !body.includes('"toolCallId":"parent_start"') && toolNames(JSON.parse(body) as Body).length > 0) {
        childBodies.push(body);
        if (!body.includes('"toolCallId":"child_run_shell"')) {
          return fakeGatewayToolCall("child_run_shell", "toolbox", {
            run: "shell",
            arguments: { action: "run", command: `touch '${marker}'` },
          });
        }
        if (!body.includes('"toolCallId":"child_open_skill"')) {
          return fakeGatewayToolCall("child_open_skill", "toolbox", { open: "demo-review" });
        }
        return fakeGatewayFinalText("TOOLBOX_CHILD_DONE");
      }
      if (body.includes('"toolCallId":"parent_start"')) return fakeGatewayFinalText("TOOLBOX_PARENT_SENT");
      return fakeGatewayToolCall("parent_start", "subagent", {
        request: { action: "message", agent: "limited-child", profile: "limited", message: childTask },
      });
    }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    // Subagents need a saved session, so this run saves into the test home.
    const result = await runFx(["ask", "--json", "--auto", "Start the limited child."], {
      cwd: root.workspace,
      env: env(root, gateway),
      timeoutMs: 40_000,
    });
    expect(result.code).toBe(0);
    expect(childBodies.length).toBeGreaterThanOrEqual(3);
    const childTools = toolNames(body(childBodies[0]!));
    expect(childTools).toContain("toolbox");
    expect(childTools).not.toContain("shell");
    // The profile refuses it as it refuses a direct call: the call isn't
    // executed. Without that, auto mode's reviewer would see the command and
    // answer with a hold instead.
    const refused = JSON.parse(toolResultText(body(childBodies[1]!), "child_run_shell")) as { value?: string };
    expect(refused.value).toBe("Not executed");
    expect(existsSync(marker)).toBe(false);
    // Opening a skill is decided as skill, which the profile doesn't list.
    const opened = toolResultText(body(childBodies[2]!), "child_open_skill");
    expect((JSON.parse(opened) as { value?: string }).value).toBe("Not executed");
    expect(opened).not.toContain("TOOLBOX_SKILL_BODY");
  }, 60_000);

  test("toolbox search gives each tool it finds with its arguments, so one search and one run use an MCP tool", async () => {
    const root = createRoot();
    const active = start([
      fakeGatewayToolCall("find_echo", "toolbox", { search: "echo text", server: "fixture" }),
      fakeGatewayToolCall("run_echo", "toolbox", { run: MCP_TOOL, arguments: { text: "hi" } }),
      fakeGatewayFinalText("TOOLBOX_SEARCH_RUN_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Echo hi with the fixture."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("TOOLBOX_SEARCH_RUN_DONE");
    // Search, run, answer: no open in between.
    const raws = modelRequests(active);
    expect(raws.length).toBe(3);
    const found = JSON.parse(resultValue(body(raws[1]!), "find_echo")) as { mcp_tools?: SearchRow[] };
    const echo = (found.mcp_tools ?? []).find((tool) => tool.name === MCP_TOOL);
    expect(echo?.arguments?.properties).toHaveProperty("text");
    expect(echo?.arguments?.required).toEqual(["text"]);
    expect(resultValue(body(raws[2]!), "run_echo")).toContain(MCP_RESULT);
    expect(wireCalls(root.wireLogPath)).toHaveLength(1);
    // The schemas came back as a result: the tools fx sends never changed.
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("a small MCP server opens with its tools' arguments, and a big one opens with its list and pages through search", async () => {
    const root = createRoot();
    const many = startManyMcpHttpServers({ servers: 1, toolsPerServer: 30 });
    try {
      const big = manyMcpServerName(0);
      const config = JSON.parse(readFileSync(join(root.home, ".fx", "mcp.json"), "utf8")) as { mcp: Record<string, unknown> };
      config.mcp[big] = { type: "http", url: many.url(0) };
      writeFileSync(join(root.home, ".fx", "mcp.json"), JSON.stringify(config));
      const pageOf = (raw: string, id: string) =>
        JSON.parse(resultValue(body(raw), id) || "{}") as { mcp_tools?: SearchRow[]; next_cursor?: string };
      gateway = startDynamicFakeGateway((raw) => {
        if (!raw.includes('"toolCallId":"open_small"')) return fakeGatewayToolCall("open_small", "toolbox", { open: "fixture" });
        if (!raw.includes('"toolCallId":"open_big"')) return fakeGatewayToolCall("open_big", "toolbox", { open: big });
        if (!raw.includes('"toolCallId":"page_one"')) return fakeGatewayToolCall("page_one", "toolbox", { search: "echoes text", server: big, limit: 20 });
        if (!raw.includes('"toolCallId":"page_two"')) {
          const cursor = pageOf(raw, "page_one").next_cursor ?? "missing";
          return fakeGatewayToolCall("page_two", "toolbox", { search: "echoes text", server: big, limit: 20, cursor });
        }
        // Nothing to look for: the server's tools, a page at a time.
        if (!raw.includes('"toolCallId":"list_big"')) return fakeGatewayToolCall("list_big", "toolbox", { search: "", server: big, limit: 3 });
        return fakeGatewayFinalText("TOOLBOX_PAGES_DONE");
      }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Look through the MCP servers."], {
        cwd: root.workspace,
        env: env(root, gateway),
        timeoutMs: 40_000,
      });
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("TOOLBOX_PAGES_DONE");
      const raws = modelRequests(gateway);
      const last = raws.at(-1)!;

      // One tool: it opens whole, with its arguments, ready to run.
      const small = resultValue(body(last), "open_small");
      expect(small).toContain("Tools of MCP server fixture, each with its arguments");
      const smallPage = JSON.parse(small.slice(small.indexOf("{"), small.lastIndexOf("}") + 1)) as { tools: SearchRow[] };
      expect(smallPage.tools.map((tool) => tool.name)).toEqual([MCP_TOOL]);
      expect(smallPage.tools[0]!.arguments?.required).toEqual(["text"]);

      // Thirty tools: their list, and the way to the ones needed.
      const opened = resultValue(body(last), "open_big");
      expect(opened).toContain(`Tools of MCP server ${big}, one per line`);
      expect(opened).toContain(`server "${big}"`);
      expect(opened).not.toContain("inputSchema");

      // A search gives twenty at most, each with its arguments, then the rest.
      const one = pageOf(last, "page_one");
      const two = pageOf(last, "page_two");
      expect(one.mcp_tools).toHaveLength(20);
      expect(typeof one.next_cursor).toBe("string");
      expect(two.mcp_tools).toHaveLength(10);
      expect(two.next_cursor).toBeUndefined();
      const names = [...one.mcp_tools!, ...two.mcp_tools!].map((tool) => tool.name);
      expect(new Set(names).size).toBe(30);
      for (const tool of [...one.mcp_tools!, ...two.mcp_tools!]) {
        expect(tool.arguments?.required ?? (tool.open_for_arguments ? ["open"] : [])).not.toEqual([]);
      }
      expect(one.mcp_tools![0]!.arguments?.required).toEqual(["text"]);
      const listed = pageOf(last, "list_big");
      expect(listed.mcp_tools?.map((tool) => tool.arguments?.required)).toEqual([["text"], ["text"], ["text"]]);
      expect(typeof listed.next_cursor).toBe("string");
      expect(many.stats.toolsCall).toEqual([]);
      expectEveryRequestExtendsThePrevious(raws);
    } finally {
      many.stop();
    }
  }, 60_000);

  test("a skill named like a tool or server is opened and decided as the skill, and kind picks the other", async () => {
    const root = createRoot();
    // A skill's name can be a built-in's or a server's. The skill's rules
    // decide an open of that name, since open reads the skill.
    writeSkill(root.home, "read_file", "A skill that shares a built-in's name.", "TOOLBOX_NAMED_LIKE_A_TOOL");
    writeSkill(root.home, "fixture", "A skill that shares the MCP server's name.", "TOOLBOX_NAMED_LIKE_A_SERVER");
    writeFileSync(join(root.home, ".fx", "settings.json"), JSON.stringify({ permission: { skill: { read_file: "deny" } } }));
    const active = start([
      fakeGatewayToolCall("open_denied", "toolbox", { open: "read_file" }),
      fakeGatewayToolCall("open_both", "toolbox", { open: "fixture" }),
      fakeGatewayToolCall("open_server", "toolbox", { open: "fixture", kind: "mcp_server" }),
      fakeGatewayToolCall("open_skill", "toolbox", { open: "fixture", kind: "skill" }),
      fakeGatewayFinalText("TOOLBOX_KIND_DONE"),
    ]);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Open the fixture."], {
      cwd: root.workspace,
      env: env(root, active),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    const raws = modelRequests(active);
    expect(raws.length).toBe(5);
    const last = body(raws.at(-1)!);
    expect(resultValue(last, "open_denied")).not.toContain("TOOLBOX_NAMED_LIKE_A_TOOL");
    const both = resultValue(last, "open_both");
    expect(both).toContain("as a skill and as an MCP server");
    expect(both).not.toContain("TOOLBOX_NAMED_LIKE_A_SERVER");
    expect(resultValue(last, "open_server")).toContain(MCP_TOOL);
    expect(resultValue(last, "open_skill")).toContain("TOOLBOX_NAMED_LIKE_A_SERVER");
    expectEveryRequestExtendsThePrevious(raws);
  }, 40_000);

  test("a subagent whose profile lists a tool placed behind toolbox keeps toolbox and runs it there", async () => {
    const root = createRoot();
    const profileDir = join(root.home, ".fx", "agents", "finder");
    mkdirSync(profileDir, { recursive: true });
    writeFileSync(join(profileDir, "profile.json"), JSON.stringify({ description: "Finds files", tools: ["glob_files"] }));
    writeFileSync(join(root.workspace, "FINDER_NOTES.md"), "notes\n");
    const childTask = "TOOLBOX_FINDER_TASK";
    const childBodies: string[] = [];
    const latestUser = (raw: string) =>
      JSON.stringify((JSON.parse(raw) as Body).prompt.filter((message) => message.role === "user").at(-1) ?? "");
    gateway = startDynamicFakeGateway((raw) => {
      if (latestUser(raw).includes("Subagent report")) return fakeGatewayFinalText("TOOLBOX_FINDER_PARENT_DONE");
      // A model request of the child's: fx's side requests carry no tools.
      if (raw.includes(childTask) && !raw.includes('"toolCallId":"parent_start"') && toolNames(JSON.parse(raw) as Body).length > 0) {
        childBodies.push(raw);
        if (!raw.includes('"toolCallId":"child_glob"')) {
          return fakeGatewayToolCall("child_glob", "toolbox", { run: "glob_files", arguments: { pattern: "*.md" } });
        }
        return fakeGatewayFinalText("TOOLBOX_FINDER_CHILD_DONE");
      }
      if (raw.includes('"toolCallId":"parent_start"')) return fakeGatewayFinalText("TOOLBOX_FINDER_SENT");
      return fakeGatewayToolCall("parent_start", "subagent", {
        request: { action: "message", agent: "finder-child", profile: "finder", message: childTask },
      });
    }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    const result = await runFx(["--tool-placement", "glob_files=toolbox", "ask", "--json", "--auto", "Start the finder."], {
      cwd: root.workspace,
      env: env(root, gateway),
      timeoutMs: 40_000,
    });
    expect(result.code).toBe(0);
    expect(childBodies.length).toBeGreaterThanOrEqual(2);
    // glob_files sits behind toolbox for this run, so toolbox is the child's
    // way to the one tool its profile lists.
    const childTools = toolNames(body(childBodies[0]!));
    expect(childTools).toContain("toolbox");
    expect(childTools).not.toContain("glob_files");
    expect(resultValue(body(childBodies[1]!), "child_glob")).toContain("FINDER_NOTES.md");
  }, 60_000);
});
