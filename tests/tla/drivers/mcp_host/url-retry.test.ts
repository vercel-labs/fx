// UrlRetry: a real `fx ask` in a terminal (tmux; fx ask asks MCP questions
// only with a terminal) whose fake-gateway model calls a 2025-11-25 stdio
// server, tests/e2e/fixtures/mcp-legacy-stdio.mjs, that answers the first
// tools/call with -32042. The harness opens the URLs, then releases the
// server's completions or chooses Cancel, and records what it saw. The
// fixture's wire log counts the calls. Checked against UrlRetry.tla.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers, worktree } from "../lib/context";
import { fixture, fxEnv, save, waitFor, writeProfile } from "./driver";
import { checkTrace, type TraceRecord, type Value } from "./trace";

const SERVER = join(worktree, "tests", "e2e", "fixtures", "mcp-legacy-stdio.mjs");
const TOOL = "mcp_fixture_echo";
const MODEL = "openai/gpt-5";
const DONE = "URL_RETRY_TURN_DONE";

async function start(name: string, mode: string, url: string) {
  const f = fixture(artifacts, name);
  const wire = join(f.base, "wire.jsonl");
  const release = join(f.control, "release");
  writeProfile(f, {
    fixture: {
      command: process.execPath,
      args: [SERVER],
      env: {
        FX_MCP_WIRE_LOG: wire,
        FX_MCP_MODE: mode,
        FX_MCP_LEGACY_VERSION: "2025-11-25",
        FX_MCP_ELICITATION_URL: url,
        FX_MCP_INVALIDATION_RELEASE_PATH: release,
        FX_MCP_PID_PATH: join(f.base, "mcp.pid"),
      },
    },
  });
  // fx opens a URL with `open` or `xdg-open`: these log it, so no browser starts.
  const bin = join(f.base, "bin");
  mkdirSync(bin);
  for (const opener of ["open", "xdg-open"]) {
    writeFileSync(join(bin, opener), `#!/bin/sh\nprintf '%s\\n' "$1" >> ${shellQuote(join(f.base, "open.log"))}\n`, { mode: 0o755 });
  }
  const { TmuxSession, startFakeGateway, fakeGatewayToolCall, fakeGatewayFinalText } = await targetHelpers();
  const gateway = startFakeGateway([
    fakeGatewayToolCall("select", "mcp_select_tool", { name: TOOL }),
    fakeGatewayToolCall("call", TOOL, { text: "hello" }),
    fakeGatewayFinalText(DONE),
  ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const env = fxEnv(f, {
    PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "full-access",
  });
  const tui = await TmuxSession.create({
    cmd: `${shellQuote(binary)} ask --no-save ${shellQuote("Call the fixture's echo tool.")}`,
    // No stderrPath: fx ask asks MCP questions only when stdin and stderr are a terminal.
    cwd: f.workspace, env, isolated: true, width: 160, height: 40, remainOnExit: true,
  });
  const calls = () => existsSync(wire)
    ? readFileSync(wire, "utf8").split("\n").filter(Boolean)
      .filter((line) => (JSON.parse(line) as { message?: { method?: string } }).message?.method === "tools/call").length
    : 0;
  const records: TraceRecord[] = [];
  const push = (event: string, data?: { [k: string]: Value }) => records.push({ event, data, at: Date.now() });
  const panes: { at: number; label: string; pane: string }[] = [];
  const snap = async (label: string) => { panes.push({ at: Date.now(), label, pane: await tui.capturePane() }); };
  const stop = async () => {
    save(join(f.base, "panes.json"), panes);
    await tui.kill();
    gateway.stop();
  };
  return { f, release, tui, calls, records, push, snap, stop };
}

test("Two URLs: fx calls again only once the server completes both, ignoring the rest (trace ACCEPTED)", async () => {
  const url = "https://example.test/url-retry";
  const run = await start("url-retry-two", "url_required_multiple", url);
  const { tui, calls, push, snap } = run;
  let afterFirst = -1;
  try {
    await waitFor("the first tools/call", () => calls() >= 1, 30_000);
    push("call", { n: 1 });
    await tui.waitForText(`Complete URL: ${url}`, 20_000);
    push("required");
    push("consent_shown");
    await snap("first URL");
    await tui.sendText("1");
    await tui.waitForText(`Complete URL: ${url}#second`, 20_000);
    await tui.sendText("1");
    await tui.waitForText("I completed it / Retry", 20_000);
    push("accept");
    push("waiting_shown");
    await snap("waiting");
    // An unknown id, URL 1, and URL 1 again.
    writeFileSync(run.release, "one");
    await Bun.sleep(400);
    afterFirst = calls();
    push("complete", { url: 1 });
    push("ignored");
    push("call", { n: afterFirst });
    writeFileSync(run.release, "two");
    await waitFor("the second tools/call", () => calls() >= 2, 20_000);
    push("complete", { url: 2 });
    push("call", { n: 2 });
    await tui.waitForText(DONE, 20_000);
    push("result");
    push("end", { how: "result" });
    await snap("end");
  } finally {
    await run.stop();
  }
  const verdict = await checkTrace({ module: "UrlRetry", records: run.records, dir: join(run.f.base, "trace"), constants: { ObsUrls: 2, ObsSlots: 4, ObsMaxCalls: 2, ObsGuard: true } });
  save(join(run.f.base, "verdict.json"), verdict);
  expect(afterFirst).toBe(1);
  expect(calls()).toBe(2);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 180_000);

test("One URL, then Cancel: the call ends with the server's error and is not sent again (trace ACCEPTED)", async () => {
  const url = "https://example.test/url-cancel";
  const run = await start("url-retry-cancel", "url_required_error", url);
  const { tui, calls, push, snap } = run;
  try {
    await waitFor("the first tools/call", () => calls() >= 1, 30_000);
    push("call", { n: 1 });
    await tui.waitForText(`Complete URL: ${url}`, 20_000);
    push("required");
    push("consent_shown");
    await tui.sendText("1");
    await tui.waitForText("I completed it / Retry", 20_000);
    push("accept");
    push("waiting_shown");
    await snap("waiting");
    await tui.sendText("2");
    push("cancel");
    await tui.waitForText(DONE, 20_000);
    await Bun.sleep(300);
    push("call", { n: calls() });
    push("end", { how: "cancelled" });
    await snap("end");
  } finally {
    await run.stop();
  }
  const verdict = await checkTrace({ module: "UrlRetry", records: run.records, dir: join(run.f.base, "trace"), constants: { ObsUrls: 1, ObsSlots: 4, ObsMaxCalls: 2, ObsGuard: true } });
  save(join(run.f.base, "verdict.json"), verdict);
  expect(calls()).toBe(1);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 180_000);
