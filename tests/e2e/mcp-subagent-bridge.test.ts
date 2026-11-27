// What a subagent's `fx mcp call` may run. The fake model starts a subagent, which makes
// shell calls; each call's answer and the tools/call lines the small server saw are read.
// The view the subagent's profile gives it and the deny rules of the mode it runs in decide
// the call, and whether the tool's list was loaded when the command began does not.
// tests/tla/drivers/mcp_host/subagent-access.test.ts runs the same scripts against the model.
import { describe, expect, test } from "bun:test";
import { FX_BIN } from "../evals/eval-helpers";
import { LARGE_RESULT, LARGE_TOOL, LIST_CHANGE_RELEASE, NOT_SET_VARIABLE, OTHER_TOOL, SMALL_RESULT, SMALL_TOOL, runPaths, seen, shellStep, type PathsRun } from "./mcp-rules-paths";

/** What `fx mcp call` and `fx mcp call help` both say when fx has no MCP tool by that name for this agent. */
const noSuchTool = (tool: string) => `No MCP tool named ${tool} is available to this agent. Find tool names with fx mcp call search.`;

/** The words fx mcp call prints, with its exit code 5, when the agent may not call the tool. */
const refusal = (tool: string) => `fx mcp call: ${tool} did not run. ${noSuchTool(tool)}`;

const call = (run: PathsRun, tool: string) => seen(run, "bridge_call", tool).text;
const ok = (run: PathsRun) => expect([run.code, run.stderr.slice(-200)]).toEqual([0, run.stderr.slice(-200)]);

function expectRefused(text: string, tool: string) {
  expect(text).toContain("exit=5");
  expect(text).toContain(refusal(tool));
}

function expectRan(text: string, result: string) {
  expect(text).toContain("exit=0");
  expect(text).toContain(result);
}

const bridge = (...tools: string[]) => tools.map((tool) => `bridge_call:${tool}`);
const openSmall = `open_small:${SMALL_TOOL}`;
const mcp = (rest: string) => `"${FX_BIN}" mcp call ${rest}`;

describe("a subagent's fx mcp call", () => {
  for (const loaded of [false, true]) {
    const when = loaded ? "its list was loaded before the subagent started" : "its list was never loaded";

    test(`is refused, exit 5, for a server outside its profile: ${when}`, async () => {
      const run = await runPaths({
        bin: FX_BIN, mode: "full", agent: "child", rules: {}, childServers: ["big"],
        only: bridge(SMALL_TOOL, LARGE_TOOL), parentFirst: loaded ? [openSmall] : [],
        label: `outside-profile-${loaded}`,
      });
      ok(run);
      if (loaded) expect(run.texts[`parent:p_${openSmall.replace(":", "_")}`]).toContain(`"name":"${SMALL_TOOL}"`);
      expectRefused(call(run, SMALL_TOOL), SMALL_TOOL);
      expectRan(call(run, LARGE_TOOL), LARGE_RESULT);
      expect(run.fixtureCalls).toEqual([]);
    }, 240_000);

    test(`is refused for every server when its profile lists none: ${when}`, async () => {
      const run = await runPaths({
        bin: FX_BIN, mode: "full", agent: "child", rules: {}, childServers: [],
        only: bridge(SMALL_TOOL, LARGE_TOOL), parentFirst: loaded ? [openSmall] : [],
        label: `no-servers-${loaded}`,
      });
      ok(run);
      expectRefused(call(run, SMALL_TOOL), SMALL_TOOL);
      expectRefused(call(run, LARGE_TOOL), LARGE_TOOL);
      expect(run.fixtureCalls).toEqual([]);
    }, 240_000);
  }

  test("meets a deny rule that applies only in its own mode: the parent's call runs, the child's is refused", async () => {
    const run = await runPaths({
      bin: FX_BIN, mode: "full", childMode: "auto", agent: "child", rules: { [SMALL_TOOL]: "deny" },
      only: bridge(SMALL_TOOL, OTHER_TOOL), parentFirst: bridge(SMALL_TOOL),
      label: "deny-in-child-mode",
    });
    ok(run);
    expectRan(run.texts[`parent:p_bridge_call_${SMALL_TOOL}`]!, SMALL_RESULT);
    expectRefused(call(run, SMALL_TOOL), SMALL_TOOL);
    expectRan(call(run, OTHER_TOOL), LARGE_RESULT);
    expect(run.fixtureCalls).toEqual(["echo"]);
  }, 240_000);

  test("says the same words in fx mcp call and fx mcp call help for a tool outside its view or denied in its mode", async () => {
    const run = await runPaths({
      bin: FX_BIN, mode: "full", childMode: "auto", agent: "child", rules: { [SMALL_TOOL]: "deny" },
      only: [`bridge_call:${SMALL_TOOL}`, `bridge_help:${SMALL_TOOL}`], label: "same-words-denied",
    });
    ok(run);
    expectRefused(call(run, SMALL_TOOL), SMALL_TOOL);
    const help = seen(run, "bridge_help", SMALL_TOOL).text;
    expect(help).toContain("exit=1");
    expect(help).toContain(`fx mcp call: ${noSuchTool(SMALL_TOOL)}`);
    expect(run.fixtureCalls).toEqual([]);
  }, 240_000);

  test("tells fx mcp call and help why a tool can't be used, in the words toolbox open uses for it", async () => {
    // The small server exits at once, so its tool exists but its server is unavailable.
    const run = await runPaths({
      bin: FX_BIN, mode: "full", agent: "child", rules: {}, down: true,
      only: [`open_tool:${SMALL_TOOL}`, `bridge_call:${SMALL_TOOL}`, `bridge_help:${SMALL_TOOL}`], label: "server-down",
    });
    ok(run);
    const opened = seen(run, "open_tool", SMALL_TOOL).text;
    const reason = /MCP server 'fixture' is unavailable: [^"\\\n]*/.exec(opened)?.[0];
    expect(reason, `toolbox open said: ${opened}`).toStartWith("MCP server 'fixture' is unavailable: its process exited");
    const called = call(run, SMALL_TOOL);
    expect(called).toContain("exit=5");
    expect(called).toContain(`fx mcp call: ${SMALL_TOOL} did not run. ${reason}`);
    expect(called).not.toContain("No MCP tool named");
    const help = seen(run, "bridge_help", SMALL_TOOL).text;
    expect(help).toContain("exit=1");
    expect(help).toContain(`fx mcp call: ${reason}`);
    expect(help).not.toContain("No MCP tool named");
    expect(run.fixtureCalls).toEqual([]);
  }, 240_000);

  test("runs the subagent's first call, with no open or search before it", async () => {
    const run = await runPaths({ bin: FX_BIN, mode: "full", agent: "child", rules: {}, only: bridge(SMALL_TOOL), label: "first-call" });
    ok(run);
    expectRan(call(run, SMALL_TOOL), SMALL_RESULT);
    expect(run.fixtureCalls).toEqual(["echo"]);
  }, 240_000);

  // A subagent's view is limited. A tool the rules hide, or one on a server outside its profile, is not there for it,
  // so what that tool's server is doing (held, down, or waiting for a login) is none of its business: the same words
  // as a tool that does not exist. The main agent's view is not limited, and it hears why, as `toolbox open` always has.
  type Extra = Array<"keyed" | "locked">;
  const SERVERS = [
    { state: "down", server: "fixture", tool: SMALL_TOOL, extra: [] as Extra, down: true, why: "MCP server 'fixture' is unavailable: its process exited" },
    { state: "held", server: "keyed", tool: "mcp_keyed_list", extra: ["keyed"] as Extra, down: false, why: `MCP server 'keyed' needs ${NOT_SET_VARIABLE} set before fx starts.` },
    { state: "login", server: "locked", tool: "mcp_locked_list", extra: ["locked"] as Extra, down: false, why: "MCP server 'locked' needs a login. Ask the user to run fx mcp login locked in a terminal, then try again." },
  ];
  const commands = (tool: string) => [
    shellStep("call", mcp(`${tool} '{}'`)),
    shellStep("help", mcp(`help ${tool}`)),
    { id: "open", name: "toolbox", args: { open: tool } },
    { id: "open_unknown", name: "toolbox", args: { open: "mcp_nothing_here" } },
  ];
  for (const { state, server, tool, extra, down } of SERVERS) {
    for (const hidden of ["denied by a rule", "outside the profile"] as const) {
      test(`says nothing of a ${state} server's state to a subagent for a tool ${hidden}`, async () => {
        const denied = hidden === "denied by a rule";
        const view = ["fixture", "big", ...extra].filter((name) => denied || name !== server);
        const run = await runPaths({
          bin: FX_BIN, mode: "full", childMode: "auto", agent: "child", only: [], label: `hidden-${state}-${denied ? "rule" : "view"}`,
          rules: denied ? { [tool]: "deny" } : {}, childServers: view, extraServers: extra, down, extra: commands(tool),
        });
        ok(run);
        expectRefused(run.texts.call!, tool);
        expect(run.texts.help).toContain("exit=1");
        expect(run.texts.help).toContain(`fx mcp call: ${noSuchTool(tool)}`);
        // `toolbox open` says what it says of a tool that does not exist at all.
        expect(run.texts.open!.replaceAll(tool, "TOOL")).toBe(run.texts.open_unknown!.replaceAll("mcp_nothing_here", "TOOL"));
        for (const text of [run.texts.call!, run.texts.help!, run.texts.open!]) {
          for (const word of ["needs a login", "is unavailable", `needs ${NOT_SET_VARIABLE}`, "set before fx starts"]) expect(text).not.toContain(word);
        }
        expect(run.fixtureCalls).toEqual([]);
      }, 240_000);
    }
  }

  // Two servers whose names share a prefix: `linear`, which never loads, and `linear_dev`, which does. A tool name that
  // `linear_dev`'s list lacks could be a tool of either by its spelling, and no list or alias binds it, so neither is blamed.
  test("blames no server for a name that two servers' names could own, and the one that could only be one's", async () => {
    const ghost = "mcp_linear_dev_ghost";
    const run = await runPaths({
      bin: FX_BIN, mode: "full", agent: "main", only: [], label: "prefix-twins", rules: {}, extraServers: ["linear", "linear_dev"],
      extra: [
        shellStep("call", mcp(`${ghost} '{}'`)),
        shellStep("help", mcp(`help ${ghost}`)),
        { id: "open", name: "toolbox", args: { open: ghost } },
        { id: "open_unknown", name: "toolbox", args: { open: "mcp_nothing_here" } },
        // `linear_dev`'s own tool runs, and a name only `linear` could own still hears why `linear` is held.
        shellStep("twin_call", mcp("mcp_linear_dev_echo '{\"text\":\"hi\"}'")),
        shellStep("linear_call", mcp("mcp_linear_list '{}'")),
        { id: "linear_open", name: "toolbox", args: { open: "mcp_linear_list" } },
      ],
    });
    ok(run);
    expectRefused(run.texts.call!, ghost);
    expect(run.texts.help).toContain("exit=1");
    expect(run.texts.help).toContain(`fx mcp call: ${noSuchTool(ghost)}`);
    expect(run.texts.open!.replaceAll(ghost, "TOOL")).toBe(run.texts.open_unknown!.replaceAll("mcp_nothing_here", "TOOL"));
    for (const text of [run.texts.call!, run.texts.help!, run.texts.open!]) expect(text).not.toContain(NOT_SET_VARIABLE);
    expectRan(run.texts.twin_call!, SMALL_RESULT);
    const why = `MCP server 'linear' needs ${NOT_SET_VARIABLE} set before fx starts.`;
    expect(run.texts.linear_call).toContain("exit=5");
    expect(run.texts.linear_call).toContain(`fx mcp call: mcp_linear_list did not run. ${why}`);
    expect(run.texts.linear_open).toContain(why);
  }, 240_000);

  for (const { state, tool, extra, down, why } of SERVERS) {
    test(`tells the main agent why a ${state} server's tool can't be used, though a rule hides the tool, as toolbox open always has`, async () => {
      const run = await runPaths({
        bin: FX_BIN, mode: "auto", agent: "main", only: [], label: `hidden-${state}-main`,
        rules: { [tool]: "deny" }, extraServers: extra, down, extra: commands(tool),
      });
      ok(run);
      expect(run.texts.call).toContain("exit=5");
      expect(run.texts.call).toContain(`fx mcp call: ${tool} did not run. ${why}`);
      expect(run.texts.help).toContain("exit=1");
      expect(run.texts.help).toContain(`fx mcp call: ${why}`);
      expect(run.texts.open).toContain(why);
      expect(run.fixtureCalls).toEqual([]);
    }, 240_000);
  }

  test("runs a search and then a call in one shell command", async () => {
    const command = `{ ${mcp("search echo")} > search.txt 2>&1; ${mcp(`${SMALL_TOOL} '{"text":"hello"}'`)}; }`;
    const run = await runPaths({ bin: FX_BIN, mode: "full", agent: "child", rules: {}, only: [], extra: [shellStep("search_then_call", command)], label: "search-then-call" });
    ok(run);
    expectRan(run.texts.search_then_call!, SMALL_RESULT);
    expect(run.fixtureCalls).toEqual(["echo"]);
  }, 240_000);

  test("runs a tool that list_changed added to a server in its view, once fx has read the change", async () => {
    const added = "mcp_fixture_added";
    const POLLS = 100;
    const listsTheTool = [
      `n=0; until ${mcp("search added")} 2>&1 | grep -q ${added}; do`,
      `n=$((n+1)); if [ $n -ge ${POLLS} ]; then echo "fx never listed ${added} after the server changed its list: ${POLLS} searches"; break; fi;`,
      `sleep 0.1; done; [ $n -lt ${POLLS} ]`,
    ].join(" ");
    const run = await runPaths({
      bin: FX_BIN, mode: "full", agent: "child", rules: {}, only: [], listChange: { to: "added" },
      extra: [
        shellStep("search_first", mcp("search echo")),
        shellStep("call_before", mcp(`${added} '{"text":"hello"}'`)),
        // The server's file says it sent list_changed, not that fx read it. fx has read it when a search lists the tool,
        // so the step polls the search, for at most POLLS tries, and only then does the call run.
        shellStep("change_list", `{ touch ${LIST_CHANGE_RELEASE}; ${listsTheTool}; }`),
        shellStep("call_after", mcp(`${added} '{"text":"hello"}'`)),
      ],
      label: "list-changed",
    });
    ok(run);
    expect(run.texts.search_first).toContain(SMALL_TOOL);
    expectRefused(run.texts.call_before!, added);
    expect(run.texts.change_list, "fx should list the added tool before the call runs").toContain("exit=0");
    expectRan(run.texts.call_after!, SMALL_RESULT);
    expect(run.fixtureCalls).toEqual(["added"]);
  }, 240_000);
});
