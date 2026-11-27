// Code-to-spec driver for tests/tla/ask_events/AskEvents.tla.
//
// Runs the built `fx ask --json --events-file` binary against a local fake
// gateway across happy path + parallel tools + recovery, SIGTERM mid-tool,
// and /dev/full (ENOSPC), then asks TLC whether each observed run is a valid
// behavior of AskEventsTrace.tla (Design = "design-b"). Also verifies TLC
// rejects tampered controls.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { outDir, runTlc, TLA_ROOT } from "../lib/tlc";

const SPEC_DIR = join(TLA_ROOT, "ask_events");
const helpers = await targetHelpers();

type Obs = {
  exitKind: "ok" | "fail" | "sigterm" | "killed";
  sinkClosed: boolean;
  stdoutLen: number;
  fileLen: number;
  requiredEvents: string[];
  forbiddenEvents: string[];
};

function obsModule(obs: Obs): string {
  const tlaSet = (items: string[]) => `{${items.map((x) => JSON.stringify(x)).join(", ")}}`;
  return [
    "--------------------------- MODULE AskEventsObs ---------------------------",
    "EXTENDS Integers",
    `ObsExitKind == ${JSON.stringify(obs.exitKind)}`,
    `ObsSinkClosed == ${obs.sinkClosed ? "TRUE" : "FALSE"}`,
    `ObsStdoutLen == ${obs.stdoutLen}`,
    `ObsFileLen == ${obs.fileLen}`,
    `ObsRequiredEvents == ${tlaSet(obs.requiredEvents)}`,
    `ObsForbiddenEvents == ${tlaSet(obs.forbiddenEvents)}`,
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "SPECIFICATION Spec",
  "CONSTANTS",
  '    Design = "design-b"',
  '    Mutant = "none"',
  '    Class = "all"',
  "INVARIANT NotMatched",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

async function checkTrace(name: string, obs: Obs): Promise<"ACCEPTED" | "REJECTED"> {
  const dir = join(outDir("ask-events-driver"), name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AskEventsObs.tla"), obsModule(obs));
  writeFileSync(join(dir, "AskEventsTrace.cfg"), TRACE_CFG);
  const res = await runTlc(
    dir,
    "AskEventsTrace.tla",
    "AskEventsTrace.cfg",
    ["AskEvents.tla", "AskEventsTrace.tla"],
    SPEC_DIR,
  );
  if (res.exitCode === 12 && res.violated === "NotMatched") return "ACCEPTED";
  if (res.exitCode === 0 && /No error has been found/.test(res.output)) return "REJECTED";
  throw new Error(`Unexpected TLC result for ${name}: exit=${res.exitCode} violated=${res.violated}\n${res.output}`);
}

function makeEnv(home: string, gateway: any) {
  return testEnvironment({
    HOME: home,
    AI_GATEWAY_API_KEY: "tla-ask-events-key",
    FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CREDITS_URL: "http://127.0.0.1:9/coding-agent/v1/credits",
  });
}

async function waitForFileMatch(path: string, needle: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${needle} in ${path}`);
}

test("AskEventsTrace validates real fx runs and rejects tampered controls", async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-tla-ask-events-"));
  const home = join(root, "home");
  const ws = join(root, "ws");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(ws, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ session_titles: false, permission_mode: "auto" }));
  writeFileSync(join(ws, "a.txt"), "alpha\n");
  writeFileSync(join(ws, "b.txt"), "beta\n");

  // 1. Happy path with recovery wait + parallel tools
  let reqIdx = 0;
  const gw1 = helpers.startDynamicFakeGateway(() => {
    const idx = reqIdx++;
    if (idx === 0) {
      return new Response(JSON.stringify({ error: { message: "temp down" } }), {
        status: 503,
        headers: { "content-type": "application/json", "retry-after": "1" },
      });
    }
    if (idx === 1) {
      return helpers.fakeGatewaySse([
        { type: "tool-call", toolCallId: "c1", toolName: "read_file", input: { path: "a.txt" } },
        { type: "tool-call", toolCallId: "c2", toolName: "read_file", input: { path: "b.txt" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
      ]);
    }
    return helpers.fakeGatewayFinalText("TLA_HAPPY_OK");
  });

  try {
    const events1 = join(root, "happy.jsonl");
    const proc1 = Bun.spawn(
      [binary, "ask", "--json", "--events-file", events1, "--auto", "--no-save", "Read both."],
      { cwd: ws, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeEnv(home, gw1) },
    );
    const [out1, err1, code1] = await Promise.all([
      new Response(proc1.stdout).text(),
      new Response(proc1.stderr).text(),
      proc1.exited,
    ]);
    expect(code1, err1).toBe(0);
    expect(JSON.parse(out1).output).toBe("TLA_HAPPY_OK");
    const rows1 = readFileSync(events1, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(rows1.some((r) => r.event === "recovery")).toBe(true);
    expect(rows1.filter((r) => r.event === "tool_started")).toHaveLength(2);
    expect(rows1.filter((r) => r.event === "tool_finished")).toHaveLength(2);
    expect(rows1.at(-1)?.event).toBe("run_finished");
    // Map concrete binary event sequence to AskEvents model event set
    expect(
      await checkTrace("happy-recovery-parallel", {
        exitKind: "ok",
        sinkClosed: false,
        stdoutLen: 1,
        fileLen: 11,
        requiredEvents: [
          "run_started",
          "step_start",
          "recovery",
          "step_end",
          "tool_a_start",
          "tool_a_end",
          "tool_b_start",
          "tool_b_end",
          "run_finished",
        ],
        forbiddenEvents: ["cancel"],
      }),
    ).toBe("ACCEPTED");
  } finally {
    gw1.stop();
  }

  // 2. SIGTERM mid-tool
  let req2 = 0;
  const gw2 = helpers.startDynamicFakeGateway(() => {
    if (req2++ === 0) {
      return helpers.fakeGatewaySse([
        {
          type: "tool-call",
          toolCallId: "sh1",
          toolName: "shell",
          input: { request: { action: "run", command: "sleep 10" } },
        },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
      ]);
    }
    return helpers.fakeGatewayFinalText("UNREACHED");
  });

  try {
    const events2 = join(root, "sigterm.jsonl");
    const proc2 = Bun.spawn(
      [binary, "ask", "--json", "--events-file", events2, "--full-access", "--no-save", "Sleep."],
      { cwd: ws, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeEnv(home, gw2) },
    );
    await waitForFileMatch(events2, '"tool_started"');
    proc2.kill("SIGTERM");
    const [out2, code2] = await Promise.all([new Response(proc2.stdout).text(), proc2.exited]);
    expect(out2).toBe("");
    expect(code2 === 143 || proc2.signalCode === "SIGTERM").toBe(true);
    const rows2 = readFileSync(events2, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(rows2.at(-1)?.event).toBe("run_cancelled");
    expect(rows2.some((r) => r.event === "run_finished")).toBe(false);
    expect(
      await checkTrace("sigterm-mid-tool", {
        exitKind: "sigterm",
        sinkClosed: false,
        stdoutLen: 0,
        fileLen: 4,
        requiredEvents: ["run_started", "step_start", "step_end", "cancel"],
        forbiddenEvents: ["run_finished"],
      }),
    ).toBe("ACCEPTED");
  } finally {
    gw2.stop();
  }

  // 3. /dev/full ENOSPC
  if (existsSync("/dev/full")) {
    const gw3 = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("TLA_FULL_OK"));
    try {
      const proc3 = Bun.spawn(
        [binary, "ask", "--json", "--events-file", "/dev/full", "--auto", "--no-save", "Hi."],
        { cwd: ws, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeEnv(home, gw3) },
      );
      const [out3, err3, code3] = await Promise.all([
        new Response(proc3.stdout).text(),
        new Response(proc3.stderr).text(),
        proc3.exited,
      ]);
      expect(code3, err3).toBe(0);
      expect(JSON.parse(out3).output).toBe("TLA_FULL_OK");
      expect(
        await checkTrace("dev-full-enospc", {
          exitKind: "ok",
          sinkClosed: true,
          stdoutLen: 1,
          fileLen: 0,
          requiredEvents: [],
          forbiddenEvents: ["cancel"],
        }),
      ).toBe("ACCEPTED");
    } finally {
      gw3.stop();
    }
  }

  // 4. Closed stdout reader (OutputReaderGone -> exit 141)
  const events4 = join(root, "events4.jsonl");
  const status4 = join(root, "status4.txt");
  const gw4 = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("TLA_EPIPE"));
  try {
    const proc4 = Bun.spawn(
      [
        "sh",
        "-c",
        '(sleep 0.2; "$0" ask --json --events-file "$FX_EV" --auto --no-save "Hi."; echo $? > "$FX_ST") | true',
        binary,
      ],
      {
        cwd: ws,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "pipe",
        env: { ...makeEnv(home, gw4), FX_EV: events4, FX_ST: status4 },
      },
    );
    await proc4.exited;
    expect(Number(readFileSync(status4, "utf8").trim())).toBe(141);
    const rows4 = readFileSync(events4, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(rows4.at(-1)?.event).toBe("run_finished");
    expect(rows4.at(-1)?.exit_code).toBe(141);
    expect(
      await checkTrace("closed-stdout-epipe", {
        exitKind: "fail",
        sinkClosed: false,
        stdoutLen: 0,
        fileLen: 4,
        requiredEvents: ["run_started", "step_start", "step_end", "run_finished"],
        forbiddenEvents: ["cancel"],
      }),
    ).toBe("ACCEPTED");
  } finally {
    gw4.stop();
  }

  // 5. Negative controls: model must reject missing cancel on SIGTERM, stdout>0 on SIGTERM,
  //    and two terminal events in one run.
  expect(
    await checkTrace("control-missing-cancel", {
      exitKind: "sigterm",
      sinkClosed: false,
      stdoutLen: 0,
      fileLen: 1,
      requiredEvents: ["run_started"],
      forbiddenEvents: ["cancel"],
    }),
  ).toBe("REJECTED");

  expect(
    await checkTrace("control-sigterm-stdout-nonempty", {
      exitKind: "sigterm",
      sinkClosed: false,
      stdoutLen: 1,
      fileLen: 2,
      requiredEvents: ["run_started", "cancel"],
      forbiddenEvents: [],
    }),
  ).toBe("REJECTED");

  expect(
    await checkTrace("control-double-terminal", {
      exitKind: "ok",
      sinkClosed: false,
      stdoutLen: 1,
      fileLen: 5,
      requiredEvents: ["run_started", "run_finished", "cancel"],
      forbiddenEvents: [],
    }),
  ).toBe("REJECTED");

  rmSync(root, { recursive: true, force: true });
}, 60_000);
