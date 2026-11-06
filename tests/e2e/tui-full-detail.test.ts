import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { onlySessionId } from "./saved-sessions";
import { createConfiguredProviderFixture } from "./fixtures/chat-completions";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewaySse, startFakeGateway, tmuxAvailable } = await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const TIMEOUT = 30_000;
// The hint row Ctrl+O shows at the bottom; it also says Ctrl+O is open.
const HINT = "esc close · pgup/pgdn scroll";
// Ctrl+O names a model without its provider: openai/gpt-5 reads gpt-5.
const MODEL = FAKE_GATEWAY_MODEL.slice(FAKE_GATEWAY_MODEL.lastIndexOf("/") + 1);

type Session = Awaited<ReturnType<typeof TmuxSession.create>>;

/// A gen ID in the AI Gateway's form: gen_ and 26 Crockford base-32 characters.
function genId(n: number): string {
  return `gen_01JC7P5XQ2M8VZ${String(n).padStart(12, "0")}`;
}

function finish(reason: "stop" | "tool-calls", input: number, output: number, gen: string) {
  return {
    type: "finish",
    finishReason: { unified: reason, raw: reason },
    usage: { inputTokens: { total: input }, outputTokens: { total: output } },
    providerMetadata: { gateway: { generationId: gen } },
  };
}

function textReply(text: string, input: number, output: number, gen: string): Response {
  return fakeGatewaySse([{ type: "text-delta", id: "answer_1", delta: text }, finish("stop", input, output, gen)]);
}

function shellStep(text: string, id: string, command: string, input: number, output: number, gen: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    { type: "tool-call", toolCallId: id, toolName: "shell", input: { request: { action: "run", command, yield_time_ms: 30_000 } } },
    finish("tool-calls", input, output, gen),
  ]);
}

/// A step that only calls a tool: no text before the call.
function toolOnlyStep(id: string, command: string, gen: string): Response {
  return fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: "shell", input: { request: { action: "run", command } } },
    finish("tool-calls", 50, 6, gen),
  ]);
}

/// A reply whose provider sends no gen ID.
function anonymousReply(text: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 7 }, outputTokens: { total: 2 } } },
  ]);
}

/// A reply that streams `text` and then stays open until the client goes.
function stalledReply(text: string): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n`));
        timer = setInterval(() => controller.enqueue(encoder.encode(": hold\n\n")), 50);
      },
      cancel() {
        clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function serverError(): Response {
  return new Response(JSON.stringify({ error: { message: "upstream broke" } }), {
    status: 500,
    headers: { "content-type": "application/json" },
  });
}

function rateLimited(): Response {
  return new Response(JSON.stringify({ error: { message: "slow down" } }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": "1" },
  });
}

function setup(responses: (Response | ((body: string) => Response | Promise<Response>))[]) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-detail-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  const gateway = startFakeGateway(responses);
  const env: Record<string, string | undefined> = {
    HOME: home,
    TERM: "xterm-256color",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-full-detail-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
  };
  const cleanup = () => {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  };
  return { home, workspace, gateway, env, cleanup };
}

async function start(cmd: string, workspace: string, env: Record<string, string | undefined>, width = 120, height = 70): Promise<Session> {
  const session = await TmuxSession.create({ cmd, cwd: workspace, env, width, height, isolated: true });
  await session.waitForComposer(TIMEOUT);
  return session;
}

async function ask(session: Session, prompt: string, answer: string) {
  await session.sendText(prompt);
  await session.waitForText(answer, TIMEOUT);
  await session.waitForComposer(TIMEOUT);
}

/// Opens Ctrl+O and returns its rows; the hint is the last one.
async function fullDetail(session: Session): Promise<string[]> {
  await session.sendHexBytes(["0f"]);
  await session.waitForText("esc close", TIMEOUT);
  const pane = await session.capturePane();
  return pane.split("\n").map((row) => row.trimEnd());
}

/// The index of the first row at or after `from` that contains every part.
function rowOf(rows: string[], from: number, ...parts: string[]): number {
  for (let index = from; index < rows.length; index += 1) {
    if (parts.every((part) => rows[index].includes(part))) return index;
  }
  return -1;
}

/// Each part must be on a row below the one before it.
function expectInOrder(rows: string[], steps: string[][]) {
  let at = -1;
  for (const parts of steps) {
    const next = rowOf(rows, at + 1, ...parts);
    if (next < 0) throw new Error(`no row with ${JSON.stringify(parts)} after row ${at}:\n${rows.join("\n")}`);
    at = next;
  }
}

/// No block headers, rails, tree marks or group lines anywhere. A mark opens
/// only a tool's own line, at the left edge.
function expectNoClutter(rows: string[]) {
  const text = rows.join("\n");
  for (const row of rows) {
    expect(row).not.toMatch(/· (Prompt|Response|Tool|Usage|Notice|Task|Issue)$/);
    expect(row.trimStart()).not.toMatch(/^[│├└]/);
    expect(row).not.toMatch(/^\s*● \d+ tool calls?\b/);
    if (row.trimStart().startsWith("●")) expect(row).toMatch(/^● \S/);
  }
  expect(text).toContain(HINT);
  expect(text).not.toContain("full detail · ctrl+o close");
}

/// The seconds of the day a `[Mon D ]HH:MM:SS` time row shows.
function secondsOf(row: string): number {
  const match = row.match(/(\d{2}):(\d{2}):(\d{2})\s*$/);
  if (!match) throw new Error(`no time in ${JSON.stringify(row)}`);
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

/// The time row under each prompt, in order.
function promptTimes(rows: string[]): string[] {
  return rows.flatMap((row, index) => (row.startsWith("┃ ") && index + 1 < rows.length ? [rows[index + 1]!] : []));
}

/// Two prompts, the first with a tool step: everything for each in order.
function expectTwoTurns(rows: string[]) {
  expectNoClutter(rows);
  const first = rowOf(rows, 0, "┃ List the folder");
  expect(first).toBeGreaterThanOrEqual(0);
  // The time the prompt was sent, on the row under it.
  expect(rows[first + 1]).toMatch(/^\s+([A-Z][a-z]{2} \d{1,2} )?\d{2}:\d{2}:\d{2}$/);
  expectInOrder(rows, [
    ["┃ List the folder"],
    ["Checking the folder."],
    [MODEL, "in 120", "out 18", genId(1)],
    ["Ran", "printf 'alpha\\nbeta\\n'"],
    ["alpha"],
    ["beta"],
    ["Done: two lines."],
    [MODEL, "in 210", "out 9", genId(2)],
    ["Turn ·"],
    ["┃ And once more?"],
    ["Second answer."],
    [MODEL, "in 260", "out 5", genId(3)],
    ["Turn ·"],
  ]);
  // No gen ID shows anywhere else, such as pinned at the top.
  for (const n of [1, 2, 3]) expect(rows.filter((row) => row.includes(genId(n)))).toHaveLength(1);
}

describe("Ctrl+O full detail", () => {
  test.skipIf(!tmuxAvailable())("each prompt shows its own tools, responses, tokens, times and gen IDs in order, live and after a resume", async () => {
    const env = setup([
      shellStep("Checking the folder.", "run_1", "printf 'alpha\\nbeta\\n'", 120, 18, genId(1)),
      textReply("Done: two lines.", 210, 9, genId(2)),
      textReply("Second answer.", 260, 5, genId(3)),
    ]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await ask(session, "List the folder", "Done: two lines.");
      await ask(session, "And once more?", "Second answer.");
      const live = await fullDetail(session);
      expectTwoTurns(live);

      // The same details, in the same places, after quitting and resuming,
      // and each prompt keeps the time it was sent.
      await session.kill();
      session = await start(`${binary} --resume ${onlySessionId(env.home)}`, env.workspace, env.env);
      const resumed = await fullDetail(session);
      expectTwoTurns(resumed);
      const [liveTimes, resumedTimes] = [promptTimes(live), promptTimes(resumed)];
      expect(resumedTimes).toHaveLength(liveTimes.length);
      for (const [index, row] of resumedTimes.entries()) {
        expect(Math.abs(secondsOf(row) - secondsOf(liveTimes[index]!))).toBeLessThanOrEqual(2);
      }
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a turn fx was stopped in keeps its prompt's time and its calls after a resume", async () => {
    let opened = false;
    const env = setup([
      shellStep("Checking the folder.", "run_1", "printf 'alpha\\nbeta\\n'", 120, 18, genId(4)),
      () => {
        opened = true;
        return new Promise<Response>(() => {});
      },
    ]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await session.sendText("Stop me midway");
      await session.waitForPane(() => opened, TIMEOUT);
      const live = await fullDetail(session);
      await session.kill();
      // The resume comes well after the prompt, so its time can't pass for it.
      await Bun.sleep(3_000);
      session = await start(`${binary} --resume ${onlySessionId(env.home)}`, env.workspace, env.env);
      const resumed = await fullDetail(session);
      expectInOrder(resumed, [["┃ Stop me midway"], ["Checking the folder."], [MODEL, "in 120", "out 18", genId(4)], ["Ran", "printf"]]);
      const [sent, shown] = [promptTimes(live)[0]!, promptTimes(resumed)[0]!];
      expect(Math.abs(secondsOf(shown) - secondsOf(sent))).toBeLessThanOrEqual(2);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a failed model call shows as an error in the order it happened, with its details", async () => {
    const env = setup([rateLimited(), textReply("Recovered answer.", 90, 4, genId(7))]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await ask(session, "Try the flaky route", "Recovered answer.");
      const rows = await fullDetail(session);
      expectNoClutter(rows);
      expectInOrder(rows, [
        ["┃ Try the flaky route"],
        ["Error ·", "rate limited"],
        ["gateway", MODEL],
        ["Recovered answer."],
        [MODEL, "in 90", "out 4", genId(7)],
        ["Turn ·"],
      ]);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a call with no gen ID says so, and a step with only tools shows its call line alone before them", async () => {
    const env = setup([toolOnlyStep("run_1", "printf quiet", genId(5)), anonymousReply("Answered without an ID.")]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await ask(session, "Run it quietly", "Answered without an ID.");
      const rows = await fullDetail(session);
      expectNoClutter(rows);
      expectInOrder(rows, [
        ["┃ Run it quietly"],
        [MODEL, "in 50", "out 6", genId(5)],
        ["Ran", "printf quiet"],
        ["Answered without an ID."],
        [MODEL, "in 7", "out 2", "no gen ID"],
        ["Turn ·"],
      ]);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a server error then a success shows each attempt in order", async () => {
    const env = setup([serverError(), textReply("Second try worked.", 30, 3, genId(8))]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await ask(session, "Try the broken route", "Second try worked.");
      const rows = await fullDetail(session);
      expectNoClutter(rows);
      expectInOrder(rows, [["┃ Try the broken route"], ["Error ·"], ["gateway", MODEL], ["Second try worked."], [MODEL, "in 30", "out 3", genId(8)]]);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a call stopped with Esc shows as cancelled after the text it wrote, live and after a resume", async () => {
    // A whole paragraph, so it shows before the stop.
    const env = setup([stalledReply("PARTIAL_ANSWER_BEFORE_ESC\n\n")]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env);
      await session.sendText("Start and stop");
      await session.waitForText("PARTIAL_ANSWER_BEFORE_ESC", TIMEOUT);
      await session.sendKeys("Escape");
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await session.sendKeys("Escape");
      await session.waitForText("Cancelled", TIMEOUT);
      const order = [["┃ Start and stop"], ["PARTIAL_ANSWER_BEFORE_ESC"], [MODEL, "cancelled"]];
      expectInOrder(await fullDetail(session), order);
      await session.kill();
      session = await start(`${binary} --resume ${onlySessionId(env.home)}`, env.workspace, env.env);
      expectInOrder(await fullDetail(session), order);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  for (const width of [48, 200]) {
    test.skipIf(!tmuxAvailable())(`at ${width} columns every line wraps without rails and keeps its gen ID`, async () => {
      const env = setup([
        shellStep("Checking the folder.", "run_1", "printf 'alpha\\nbeta\\n'", 120, 18, genId(1)),
        textReply("Done: two lines.", 210, 9, genId(2)),
      ]);
      let session: Session | undefined;
      try {
        session = await start(binary, env.workspace, env.env, width);
        await ask(session, "List the folder", "Done: two lines.");
        const rows = await fullDetail(session);
        expectNoClutter(rows);
        for (const row of rows) expect([...row].length).toBeLessThanOrEqual(width);
        expectInOrder(rows, [["┃ List the folder"], ["Checking the folder."], [genId(1)], ["Ran"], ["alpha"], ["Done: two lines."], [genId(2)]]);
      } finally {
        await session?.kill();
        env.cleanup();
      }
    }, 120_000);
  }

  test.skipIf(!tmuxAvailable())("a turn's Ctrl+O rows at 100 columns match the approved layout exactly", async () => {
    const env = setup([
      shellStep("Checking the folder.", "run_1", "printf 'alpha\\nbeta\\n'", 120, 18, genId(1)),
      textReply("Done: two lines.", 210, 9, genId(2)),
    ]);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env, 100);
      await ask(session, "List the folder", "Done: two lines.");
      const rows = await fullDetail(session);
      const first = rows.findIndex((row) => row.startsWith("┃ List the folder"));
      const last = rows.findIndex((row) => row.startsWith("  Turn · "));
      expect(first, rows.join("\n")).toBeGreaterThanOrEqual(0);
      expect(last, rows.join("\n")).toBeGreaterThan(first);
      // Below the turn's totals only blank rows, then the hint.
      const hint = rows.indexOf("  esc close · pgup/pgdn scroll");
      expect(hint, rows.join("\n")).toBeGreaterThan(last);
      expect(rows.slice(last + 1, hint).every((row) => row.trim() === "")).toBe(true);
      // Times and durations change from run to run; everything else is exact.
      const normalized = rows.slice(first, last + 1).map((row) =>
        row
          .replace(/\b[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2}\b/g, "<date>")
          .replace(/\b\d{2}:\d{2}:\d{2}\b/g, "<time>")
          .replace(/\b\d+(?:\.\d)? s\b/g, "<secs>")
          .replace(/\b\d+s \(/g, "<secs> (")
      );
      expect(normalized).toEqual([
        "┃ List the folder",
        "  <date>",
        "",
        "  Checking the folder.",
        `  <time> · gpt-5 · <secs> · in 120 · out 18 · ${genId(1)}`,
        "",
        "● Ran printf 'alpha\\nbeta\\n'",
        "    action: run",
        "    yield_time_ms: 30000",
        "    <time>",
        "    alpha",
        "    beta",
        "",
        "  Done: two lines.",
        `  <time> · gpt-5 · <secs> · in 210 · out 9 · ${genId(2)}`,
        "",
        "  Turn · <time> · <secs> (↑4 ↓27)",
      ]);
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("a configured chat-completions provider's response id is the call's ID, live and after a resume", async () => {
    // The chunk id a chat-completions provider streams names the response.
    const reply = (body: any) => {
      const chunks = [
        { id: "chatcmpl-FDX42", model: body.model, choices: [{ index: 0, delta: { role: "assistant", content: "LOCAL_PROVIDER_REPLY" }, finish_reason: null }] },
        { id: "chatcmpl-FDX42", model: body.model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
        { id: "chatcmpl-FDX42", model: body.model, choices: [], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } },
      ];
      return new Response(chunks.map((value) => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    };
    const f = createConfiguredProviderFixture(reply);
    let session: Session | undefined;
    try {
      session = await start(binary, f.workspace, f.env);
      await ask(session, "Answer from the local provider", "LOCAL_PROVIDER_REPLY");
      const order = [["┃ Answer from the local provider"], ["LOCAL_PROVIDER_REPLY"], ["local-model", "in 12", "out 3", "chatcmpl-FDX42"]];
      expectInOrder(await fullDetail(session), order);
      await session.kill();
      session = await start(`${binary} --resume ${onlySessionId(f.home)}`, f.workspace, f.env);
      expectInOrder(await fullDetail(session), order);
    } finally {
      await session?.kill();
      f.close();
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("Ctrl+O opened and closed while calls settle keeps every call line once, in order", async () => {
    const steps = 6;
    const responses: Response[] = [];
    for (let index = 0; index < steps; index += 1) {
      responses.push(shellStep(`Step ${index} text.`, `run_${index}`, `printf 'race ${index}\\n'`, 20 + index, 4, genId(30 + index)));
    }
    responses.push(textReply("RACE_ALL_DONE", 90, 9, genId(40)));
    const env = setup(responses);
    let session: Session | undefined;
    try {
      session = await start(binary, env.workspace, env.env, 120, 90);
      await session.sendText("Run the six steps");
      // Open and close Ctrl+O over and over while the steps' calls settle.
      for (let round = 0; round < 200; round += 1) {
        await session.sendHexBytes(["0f"]);
        await Bun.sleep(30);
        await session.sendHexBytes(["0f"]);
        await Bun.sleep(30);
        const pane = await session.capturePane();
        if (pane.includes("RACE_ALL_DONE") && !pane.includes("esc close")) break;
      }
      await session.waitForText("RACE_ALL_DONE", TIMEOUT);
      if ((await session.capturePane()).includes("esc close")) await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      const rows = await fullDetail(session);
      expectNoClutter(rows);
      const order: string[][] = [["┃ Run the six steps"]];
      for (let index = 0; index < steps; index += 1) order.push([`Step ${index} text.`], [genId(30 + index)], [`race ${index}`]);
      order.push(["RACE_ALL_DONE"], [genId(40)]);
      expectInOrder(rows, order);
      for (let index = 0; index < steps; index += 1) {
        expect(rows.filter((row) => row.includes(genId(30 + index)))).toHaveLength(1);
      }
    } finally {
      await session?.kill();
      env.cleanup();
    }
  }, 180_000);
});
