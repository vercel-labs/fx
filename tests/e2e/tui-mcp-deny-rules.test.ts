// The terminal UI builds its tool context apart from fx ask, so the rule of
// full access (no MCP deny rule hides or blocks an MCP tool) is checked here
// too, with the mode changing in a running session and with a rule the
// person saved for the session. The wider matrix of paths and modes is in
// mcp-stdio.test.ts.
import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { contentText } from "./conditional-guidance-oracle";
import { SMALL_RESULT, SMALL_TOOL } from "./mcp-rules-paths";
import { fakeGatewayFinalText, fakeGatewayToolCall, startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const STEP = 20_000;

let tui: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let root: string | null = null;

afterEach(async () => {
  await tui?.kill();
  tui = null;
  gateway?.stop();
  gateway = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
});

function toolResultText(body: string, callId: string): string {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
  const part = prompt
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []) as Array<Record<string, unknown>>)
    .find((item) => item.type === "tool-result" && item.toolCallId === callId);
  if (!part) throw new Error(`missing the tool result for ${callId}`);
  return contentText(part.output);
}

type Responder = Parameters<typeof startFakeGateway>[0][number];

/** One turn of the scripted model: open the tool, run it, say `final`. What each answered is kept in `got`. */
function turn(n: number, final: string, got: Record<string, string>): Responder[] {
  return [
    fakeGatewayToolCall(`open_${n}`, "toolbox", { open: SMALL_TOOL }),
    (body: string) => {
      got[`open_${n}`] = toolResultText(body, `open_${n}`);
      return fakeGatewayToolCall(`run_${n}`, "toolbox", { run: SMALL_TOOL, arguments: { text: "hello" } });
    },
    (body: string) => {
      got[`run_${n}`] = toolResultText(body, `run_${n}`);
      return fakeGatewayFinalText(final);
    },
  ];
}

async function launch(mode: "full-access" | "auto", settings: Record<string, unknown>, responders: Responder[]): Promise<void> {
  root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-mcp-rules-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(settings));
  // The TUI can show forms, so it declares elicitation to every server.
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({ mcp: { fixture: { type: "local", command: [process.execPath, FIXTURE], enabled: true, environment: { FX_MCP_EXPECT_ELICITATION: "both" } } } }),
  );
  const active = startFakeGateway(responders, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  gateway = active;
  tui = await TmuxSession.create({
    isolated: true,
    cwd: workspace,
    width: 140,
    height: 40,
    stderrPath: join(root, "stderr.log"),
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-tui-mcp-rules-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: mode,
      FX_GATEWAY_BASE_URL: active.baseUrl,
      FX_GATEWAY_CHAT_URL: active.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: active.chatUrl,
      FX_MODEL: MODEL,
    },
  });
  await tui.waitForComposer(15_000);
}

const OPENED = `"name":"${SMALL_TOOL}"`;
const NOT_OPENED = `Nothing named ${SMALL_TOOL} is in the toolbox menu. Use toolbox search to find it.`;
const NOT_RUN = `No tool named ${SMALL_TOOL} is in the toolbox. Use toolbox search to find it.`;

for (const mode of ["full-access", "auto"] as const) {
  test.skipIf(!tmuxAvailable())(`in the TUI in ${mode}, a tool a deny rule names ${mode === "full-access" ? "opens and runs" : "stays hidden and refused"}`, async () => {
    const got: Record<string, string> = {};
    await launch(mode, { permission: { [SMALL_TOOL]: "deny" } }, turn(1, "RULE_DONE", got));
    await tui!.sendText("Open and run the fixture tool.");
    await tui!.waitForText("RULE_DONE", 45_000);
    if (mode === "full-access") {
      expect(got.open_1).toContain(OPENED);
      expect(got.run_1).toContain(SMALL_RESULT);
    } else {
      expect(got.open_1).toContain(NOT_OPENED);
      expect(got.run_1).toContain(NOT_RUN);
    }
  }, 120_000);
}

test.skipIf(!tmuxAvailable())("in the TUI a mode change takes effect at the next call: full access ignores the rule, auto applies it again, full access ignores it again", async () => {
  const got: Record<string, string> = {};
  await launch("full-access", { permission: { [SMALL_TOOL]: "deny" } }, [...turn(1, "TURN_ONE_DONE", got), ...turn(2, "TURN_TWO_DONE", got), ...turn(3, "TURN_THREE_DONE", got)]);
  await tui!.sendText("First turn, in full access.");
  await tui!.waitForText("TURN_ONE_DONE", 45_000);
  await tui!.waitForStableComposer(STEP);
  await tui!.sendText("/permissions auto");
  await tui!.waitForText("mode set to auto", STEP);
  await tui!.sendText("Second turn, in auto.");
  await tui!.waitForText("TURN_TWO_DONE", 45_000);
  await tui!.waitForStableComposer(STEP);
  await tui!.sendText("/permissions full-access");
  await tui!.waitForText("mode set to full access", STEP);
  await tui!.sendText("Third turn, in full access again.");
  await tui!.waitForText("TURN_THREE_DONE", 45_000);
  expect(got.open_1).toContain(OPENED);
  expect(got.run_1).toContain(SMALL_RESULT);
  expect(got.open_2).toContain(NOT_OPENED);
  expect(got.run_2).toContain(NOT_RUN);
  expect(got.open_3).toContain(OPENED);
  expect(got.run_3).toContain(SMALL_RESULT);
}, 240_000);

// A rule saved for the session cannot name an MCP tool: /permissions remember
// refuses it, so no saved rule reaches an MCP path, and full access runs the
// tool as it does without one.
test.skipIf(!tmuxAvailable())("in the TUI a deny rule cannot be saved for an MCP tool, and the tool still opens and runs in full access", async () => {
  const got: Record<string, string> = {};
  await launch("full-access", {}, [fakeGatewayFinalText("SESSION_SAVED"), ...turn(1, "SAVED_RULE_DONE", got)]);
  await tui!.sendText("Save this session first.");
  await tui!.waitForText("SESSION_SAVED", 45_000);
  await tui!.waitForStableComposer(STEP);
  await tui!.sendText(`/permissions remember deny ${SMALL_TOOL} ${JSON.stringify({ text: "hello" })}`);
  await tui!.waitForText("could not prepare that exact permission action without executing it", STEP);
  await tui!.waitForStableComposer(STEP);
  await tui!.sendText("Open and run the fixture tool.");
  await tui!.waitForText("SAVED_RULE_DONE", 45_000);
  expect(got.open_1).toContain(OPENED);
  expect(got.run_1).toContain(SMALL_RESULT);
}, 240_000);
