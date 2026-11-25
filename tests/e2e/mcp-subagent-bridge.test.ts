// What a subagent's `fx mcp call` may run. The fake model starts a subagent, which makes
// shell calls; each call's answer and the tools/call lines the small server saw are read.
// The view the subagent's profile gives it and the deny rules of the mode it runs in decide
// the call, and whether the tool's list was loaded when the command began does not.
// tests/tla/drivers/mcp_host/subagent-access.test.ts runs the same scripts against the model.
import { describe, expect, test } from "bun:test";
import { FX_BIN } from "../evals/eval-helpers";
import { LARGE_RESULT, LARGE_TOOL, LIST_CHANGE_RELEASE, OTHER_TOOL, SMALL_RESULT, SMALL_TOOL, runPaths, seen, shellStep, type PathsRun } from "./mcp-rules-paths";

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
