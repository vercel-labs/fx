// Code-to-spec driver for the interactive TUI pacer (src/ui/assistant/pacer.zig)
// along StreamTail.tla / StreamTailTrace.tla.
//
// Runs the built fx in tmux (FX_PERMISSION_MODE=ask, FX_SOUND=0) against a fake
// gateway across three streaming fixtures, polls the tmux pane every 5 ms on
// fixture (a) to measure peak newly revealed words per frame, parses
// FX_TRACE_LOG (FX_TRACE_SCOPES=pacer), and checks each trace with TLC.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { artifacts, binary, targetHelpers } from "../lib/context";
import { TLA_ROOT, runTlc, writeJson } from "../lib/tlc";

const TIMEOUT_MS = 30_000;
const PANE_POLL_MS = 5;
const MAX_NEW_WORDS_PER_FRAME_A = 12;
// pacer.zig: reveal_drain_window_ns = 100 ms, reveal_frame_ns = 16 ms -> ceil(100 / 16) = 7.
const PACER_WINDOW_FRAMES = Math.ceil(100 / 16);

type PacerEvent =
  | { type: "slot_queued"; backlog: number }
  | { type: "reveal"; k: number; backlog: number; rate: number; window: number; finish: number; finishing: number }
  | { type: "finish_deferred"; backlog: number }
  | { type: "finish_fired"; pending: number; slots: number };

function words(prefix: string, start: number, count: number): string {
  return Array.from({ length: count }, (_, i) => `${prefix}${String(start + i).padStart(2, "0")}`).join(" ");
}

function parsePacerTrace(raw: string): PacerEvent[] {
  const out: PacerEvent[] = [];
  for (const line of raw.split("\n")) {
    if (!line.includes("[pacer]") && !line.includes("scope=pacer") && !/\bpacer\b/.test(line)) continue;
    const slotQueued = /\bslot_queued backlog=(\d+)/.exec(line);
    if (slotQueued) {
      out.push({ type: "slot_queued", backlog: Number(slotQueued[1]) });
      continue;
    }
    const reveal = /\breveal k=(\d+) backlog=(\d+) rate_steps=(\d+) window_steps=(\d+) finish_steps=(\d+) finishing=(\d+)/.exec(line);
    if (reveal) {
      out.push({
        type: "reveal",
        k: Number(reveal[1]),
        backlog: Number(reveal[2]),
        rate: Number(reveal[3]),
        window: Number(reveal[4]),
        finish: Number(reveal[5]),
        finishing: Number(reveal[6]),
      });
      continue;
    }
    const finishDeferred = /\bfinish_deferred backlog=(\d+)/.exec(line);
    if (finishDeferred) {
      out.push({ type: "finish_deferred", backlog: Number(finishDeferred[1]) });
      continue;
    }
    const finishFired = /\bfinish_fired pending=(\d+) slots=(\d+)/.exec(line);
    if (finishFired) {
      out.push({ type: "finish_fired", pending: Number(finishFired[1]), slots: Number(finishFired[2]) });
    }
  }
  return out;
}

function toTlaSeq(events: PacerEvent[]): string {
  const items = events.map((ev) => {
    switch (ev.type) {
      case "slot_queued":
        return `[type |-> "slot_queued", backlog |-> ${ev.backlog}]`;
      case "reveal":
        return `[type |-> "reveal", k |-> ${ev.k}, backlog |-> ${ev.backlog}, rate |-> ${ev.rate}, window |-> ${ev.window}, finish |-> ${ev.finish}, finishing |-> ${ev.finishing}]`;
      case "finish_deferred":
        return `[type |-> "finish_deferred", backlog |-> ${ev.backlog}]`;
      case "finish_fired":
        return `[type |-> "finish_fired", pending |-> ${ev.pending}, slots |-> ${ev.slots}]`;
    }
  });
  return `<<\n  ${items.join(",\n  ")}\n>>`;
}

async function checkTraceWithTlc(name: string, events: PacerEvent[]) {
  const specDir = mkdtempSync(join(tmpdir(), `fx-stream-trace-${name}-`));
  try {
    const streamTail = readFileSync(join(TLA_ROOT, "assistant_stream", "StreamTail.tla"), "utf8");
    const streamTailTrace = readFileSync(join(TLA_ROOT, "assistant_stream", "StreamTailTrace.tla"), "utf8");
    writeFileSync(join(specDir, "StreamTail.tla"), streamTail);
    writeFileSync(join(specDir, "StreamTailTrace.tla"), streamTailTrace);
    writeFileSync(
      join(specDir, "StreamTailTraceObserved.tla"),
      [
        "---------------------- MODULE StreamTailTraceObserved ----------------------",
        "EXTENDS Naturals, Sequences",
        `Observed == ${toTlaSeq(events)}`,
        "=============================================================================",
        "",
      ].join("\n"),
    );
    writeFileSync(
      join(specDir, "StreamTailTrace.cfg"),
      [
        "SPECIFICATION TraceSpec",
        "CONSTANTS",
        "    MaxLen = 1",
        '    Variant = "design_paced"',
        "    ScreenRows = 3",
        "    ScrollLag = 0",
        "    ChunkMax = 1",
        `    W = ${PACER_WINDOW_FRAMES}`,
        "INVARIANTS",
        "    RevealInBounds",
        "    TraceBoundedStall",
        "    TraceNoLossAtFinish",
        "    NotAllMatched",
        "",
      ].join("\n"),
    );
    return await runTlc(
      join(artifacts, `tlc-trace-${name}`),
      "StreamTailTrace",
      "StreamTailTrace.cfg",
      ["StreamTail.tla", "StreamTailTrace.tla", "StreamTailTraceObserved.tla", "StreamTailTrace.cfg"],
      specDir,
    );
  } finally {
    rmSync(specDir, { recursive: true, force: true });
  }
}

function sseResponse(driver: (send: (delta: string) => void, finish: () => void) => Promise<void>): Response {
  const encoder = new TextEncoder();
  let closed = false;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        const send = (delta: string) => {
          if (closed) return;
          controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta })}\n\n`));
        };
        const finish = () => {
          if (closed) return;
          closed = true;
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
                usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
              })}\n\ndata: [DONE]\n\n`,
            ),
          );
          controller.close();
        };
        void driver(send, finish).catch((err) => {
          if (!closed) {
            closed = true;
            controller.error(err);
          }
        });
      },
      cancel() {
        closed = true;
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function runFixtureInTui(
  name: string,
  prompt: string,
  responseFactory: () => Response,
  options: { pollWords?: RegExp; expectedEndText: string },
) {
  const { startFakeGateway, FAKE_GATEWAY_MODEL, TmuxSession, turnSettled, hasEmptyComposer } = await targetHelpers();
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-paced-${name}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(tracePath, "");
  writeFileSync(stderrPath, "");

  const gateway = startFakeGateway([() => responseFactory()]);
  let session: InstanceType<typeof TmuxSession> | null = null;
  const wordDeltas: number[] = [];
  let maxNewWordsPerFrame = 0;

  try {
    session = await TmuxSession.create({
      isolated: true,
      cmd: binary,
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-paced-trace-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "ask",
        FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "pacer",
        NO_COLOR: "1",
      },
      width: 140,
      height: 36,
      stderrPath,
    });

    await session.waitForComposer(TIMEOUT_MS);
    await session.sendLiteral(prompt);
    session.sendKeysImmediate(["Enter"]);

    const seenWords = new Set<string>();
    const deadline = Date.now() + TIMEOUT_MS;
    let settledSince: number | null = null;
    while (Date.now() < deadline) {
      const pane = await session.capturePane();
      if (options.pollWords) {
        let added = 0;
        for (const match of pane.matchAll(options.pollWords)) {
          if (!seenWords.has(match[0])) {
            seenWords.add(match[0]);
            added += 1;
          }
        }
        if (added > 0) {
          wordDeltas.push(added);
          if (added > maxNewWordsPerFrame) maxNewWordsPerFrame = added;
        }
      }
      const done = pane.includes(options.expectedEndText) && turnSettled(pane) && hasEmptyComposer(pane);
      if (done) {
        settledSince ??= Date.now();
        if (Date.now() - settledSince >= 150) break;
      } else {
        settledSince = null;
      }
      await Bun.sleep(PANE_POLL_MS);
    }
    if (settledSince === null) {
      const lastPane = await session.capturePane();
      throw new Error(`fixture ${name} timed out waiting for ${options.expectedEndText}.\nPane:\n${lastPane}`);
    }

    const traceRaw = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "";
    const events = parsePacerTrace(traceRaw);
    const fullScreen = await session.captureFullScrollback();
    writeJson(join(artifacts, `paced-${name}.json`), {
      name,
      binary,
      maxNewWordsPerFrame,
      wordDeltas,
      eventCount: events.length,
      events,
      stderr,
    });
    return { events, traceRaw, stderr, maxNewWordsPerFrame, wordDeltas, fullScreen };
  } finally {
    await session?.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

describe("paced TUI trace against StreamTailTrace", () => {
  test("fixture (a): 24-word burst then single words reveals smoothly and passes TLC", async () => {
    const burst = words("pa", 1, 24);
    const run = await runFixtureInTui(
      "burst24",
      "1111",
      () =>
        sseResponse(async (send, finish) => {
          send(`${burst} `);
          await Bun.sleep(220);
          for (let i = 1; i <= 4; i++) {
            send(`ps0${i} `);
            await Bun.sleep(30);
          }
          finish();
        }),
      { pollWords: /\b(?:pa\d{2}|ps\d{2})\b/g, expectedEndText: "ps04" },
    );

    console.log(`[fixture a] binary=${binary} maxNewWordsPerFrame=${run.maxNewWordsPerFrame} deltas=${JSON.stringify(run.wordDeltas)} events=${run.events.length}`);
    expect(run.stderr).toBe("");
    expect(run.fullScreen).toContain("pa01");
    expect(run.fullScreen).toContain("ps04");
    expect(run.maxNewWordsPerFrame).toBeLessThanOrEqual(MAX_NEW_WORDS_PER_FRAME_A);

    const reveals = run.events.filter((e) => e.type === "reveal");
    expect(reveals.length).toBeGreaterThan(0);

    const tlc = await checkTraceWithTlc("burst24", run.events);
    console.log(`[fixture a TLC] violated=${tlc.violated} distinct=${tlc.distinctStates} ms=${tlc.durationMs}`);
    expect(tlc.violated).toBe("NotAllMatched");
  }, 60_000);

  test("fixture (b): prose, fenced code block in bursts, prose after passes TLC", async () => {
    const openProse = words("pb", 1, 12);
    const closeProse = words("pb", 13, 12);
    const run = await runFixtureInTui(
      "fenced",
      "2222",
      () =>
        sseResponse(async (send, finish) => {
          send(`${openProse}\n\n`);
          await Bun.sleep(220);
          send("```zig\nconst alpha = 1;\nconst beta = 2;\n");
          await Bun.sleep(40);
          send("const gamma = alpha + beta;\n```\n\n");
          await Bun.sleep(220);
          send(closeProse);
          finish();
        }),
      { expectedEndText: "pb24" },
    );

    console.log(`[fixture b] binary=${binary} events=${run.events.length}`);
    expect(run.stderr).toBe("");
    expect(run.fullScreen).toContain("pb01");
    expect(run.fullScreen).toContain("const gamma = alpha + beta;");
    expect(run.fullScreen).toContain("pb24");

    const reveals = run.events.filter((e) => e.type === "reveal");
    expect(reveals.length).toBeGreaterThan(0);

    const tlc = await checkTraceWithTlc("fenced", run.events);
    console.log(`[fixture b TLC] violated=${tlc.violated} distinct=${tlc.distinctStates} ms=${tlc.durationMs}`);
    expect(tlc.violated).toBe("NotAllMatched");
  }, 60_000);

  test("fixture (c): 60-word paragraph before finish exercises finish deadline and passes TLC", async () => {
    const para60 = words("pc", 1, 60);
    const run = await runFixtureInTui(
      "finish60",
      "3333",
      () =>
        sseResponse(async (send, finish) => {
          send(para60);
          finish();
        }),
      { expectedEndText: "pc60" },
    );

    console.log(`[fixture c] binary=${binary} events=${run.events.length}`);
    expect(run.stderr).toBe("");
    expect(run.fullScreen).toContain("pc01");
    expect(run.fullScreen).toContain("pc60");

    const reveals = run.events.filter((e) => e.type === "reveal");
    expect(reveals.length).toBeGreaterThan(0);
    expect(run.events.some((e) => e.type === "finish_deferred")).toBe(true);
    expect(run.events.some((e) => e.type === "finish_fired")).toBe(true);

    const tlc = await checkTraceWithTlc("finish60", run.events);
    console.log(`[fixture c TLC] violated=${tlc.violated} distinct=${tlc.distinctStates} ms=${tlc.durationMs}`);
    expect(tlc.violated).toBe("NotAllMatched");
  }, 60_000);
});
