import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  type FakeGatewayOptions,
  fakeGatewayFinalText,
  fakeGatewaySerializedToolCall,
  fakeGatewayToolCall,
  fakeShellRun,
  heldFakeGatewayFinalText,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// Sessions v2 behind FX_SESSIONS_V2 and --sessions-v2: every `fx ask` entry
// and exit, the files it writes, and the faults a real disk and a real
// crash produce: kills mid-stream and mid-tool, a torn tail, a flipped
// byte, a second process, a read-only folder and a full disk.

const TIMEOUT = 30_000;

type Fixture = { root: string; home: string; workspace: string };

function createFixture(prefix: string): Fixture {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function env(fixture: Fixture, gateway: { baseUrl: string; chatUrl: string }, v2 = true) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "sessions-v2-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_SESSIONS_V2: v2 ? "1" : undefined,
  };
}

function v2Root(fixture: Fixture) {
  return join(fixture.home, ".fx", "sessions", "v2");
}

type Line = { seq: number; kind: string; type?: string; reason?: string; key?: string };

/// Every line of a session's log. A streamed turn always matches its
/// commit, so no turn is ever superseded.
function logLines(fixture: Fixture, id: string): Line[] {
  const text = readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8");
  const lines: Line[] = text.trimEnd().split("\n").map((line) => JSON.parse(line));
  expect(lines.filter((line) => line.type === "superseded")).toEqual([]);
  return lines;
}

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0x82f63b78 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

/// CRC32C, computed here rather than trusted from the code under test.
function crc32c(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/// The log is whole: every line ends in a newline and carries a CRC32C over
/// the bytes before `,"crc":"`, `seq` counts from 1 without gaps, and each
/// `turn_started` ends once before the next one begins.
function expectWholeLog(fixture: Fixture, id: string) {
  const bytes = readFileSync(join(v2Root(fixture), id, "log.jsonl"));
  expect(bytes.at(-1)).toBe(0x0a);
  const marker = Buffer.from(',"crc":"');
  let start = 0;
  let seq = 0;
  let open = false;
  while (start < bytes.length) {
    const end = bytes.indexOf(0x0a, start);
    const line = bytes.subarray(start, end + 1);
    const at = line.lastIndexOf(marker);
    const stored = parseInt(line.subarray(at + marker.length, at + marker.length + 8).toString(), 16);
    expect(crc32c(line.subarray(0, at))).toBe(stored);
    const entry = JSON.parse(line.toString());
    seq += 1;
    expect(entry.seq).toBe(seq);
    if (entry.kind === "turn_started") {
      expect(open).toBe(false);
      open = true;
    } else if (entry.kind === "turn_committed" || entry.kind === "turn_interrupted") {
      expect(open).toBe(true);
      open = false;
    }
    start = end + 1;
  }
}

/// Every tool call the model is sent has its result: an unpaired call is
/// rejected by providers.
/// The tool calls and tool results in a Gateway request's prompt.
function promptToolParts(body: string) {
  const prompt: any[] = JSON.parse(body).prompt ?? [];
  const parts: any[] = prompt.flatMap((message) => (Array.isArray(message.content) ? message.content : []));
  return {
    calls: parts.filter((part) => part.type === "tool-call"),
    results: parts.filter((part) => part.type === "tool-result"),
  };
}

/// The text of the assistant message that issued `callId`, in a request.
function assistantTextBeside(body: string, callId: string) {
  const prompt: any[] = JSON.parse(body).prompt ?? [];
  const message = prompt.find(
    (entry) =>
      entry.role === "assistant" &&
      Array.isArray(entry.content) &&
      entry.content.some((part: any) => part.type === "tool-call" && part.toolCallId === callId),
  );
  return (message?.content ?? [])
    .filter((part: any) => part.type === "text")
    .map((part: any) => part.text)
    .join("");
}

/// Every title the session's log stores, oldest first.
function storedTitles(fixture: Fixture, id: string): string[] {
  return logLines(fixture, id)
    .filter((line: any) => line.kind === "set" && line.key === "title")
    .map((line: any) => line.value);
}

function expectPairedToolCalls(body: string) {
  const { calls, results } = promptToolParts(body);
  expect(calls.length).toBeGreaterThan(0);
  const answered = new Set(results.map((part) => part.toolCallId));
  for (const call of calls) expect(answered.has(call.toolCallId)).toBe(true);
}

/// Waits until the log contains `needle`, or fails after `timeoutMs`.
async function waitForLog(fixture: Fixture, id: string, needle: string, timeoutMs = 10_000) {
  const path = join(v2Root(fixture), id, "log.jsonl");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(needle)) return;
    await Bun.sleep(50);
  }
  throw new Error(`log never contained ${needle}`);
}

function spawnAsk(fixture: Fixture, gateway: any, args: string[]) {
  const child = spawn(FX_BIN, ["ask", "--json", "--auto", ...args], {
    cwd: fixture.workspace,
    env: { ...process.env, ...env(fixture, gateway) } as Record<string, string>,
    stdio: "ignore",
  });
  const exited = new Promise((resolve) => child.on("exit", resolve));
  return { child, exited };
}

/// Bytes in one `ulimit -f` block of `/bin/sh`: bash, which is `/bin/sh` on
/// macOS, counts 1024; dash on Linux counts 512. Measured once.
const SH_LIMIT_BLOCK = (() => {
  const probe = join(tmpdir(), `fx-v2-ulimit-${process.pid}`);
  Bun.spawnSync(["/bin/sh", "-c", `trap '' XFSZ; ulimit -f 1; head -c 4096 /dev/zero > '${probe}'`]);
  const bytes = statSync(probe).size;
  rmSync(probe, { force: true });
  return bytes;
})();

/// The `ulimit -f` value that leaves at most one block of room past `path`.
function blocksJustPast(path: string) {
  return Math.ceil(statSync(path).size / SH_LIMIT_BLOCK) + 1;
}

/// `fx ask` under a file-size limit of `blocks` shell blocks with SIGXFSZ
/// ignored, so a write past it fails with EFBIG the way a full disk fails
/// with ENOSPC. The ignored signal survives the `exec`.
function askWithSizeLimit(fixture: Fixture, gateway: any, blocks: number, args: string[]) {
  return new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve) => {
    const child = spawn(
      "/bin/sh",
      ["-c", `trap '' XFSZ; ulimit -f ${blocks}; exec "$0" "$@"`, FX_BIN, "ask", "--json", "--auto", ...args],
      { cwd: fixture.workspace, env: { ...process.env, ...env(fixture, gateway) } as Record<string, string> },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

test("the TypeScript CRC32C matches the standard check value", () => {
  expect(crc32c(Buffer.from("123456789"))).toBe(0xe3069283);
});

/// Kinds and item types, in order: `item:user`, `turn_committed`, ...
function shape(lines: Line[]): string[] {
  return lines
    .filter((line) => line.kind !== "snapshot" && line.kind !== "set")
    .map((line) => (line.kind === "item" ? `item:${line.type}` : line.kind));
}

/// The v1 sessions folder holds nothing but the v2 root: no dual writes.
/// No v2 session ever makes a side folder either (D48).
function expectNoV1Sessions(fixture: Fixture) {
  const sessions = join(fixture.home, ".fx", "sessions");
  expect(readdirSync(sessions).filter((name) => name !== "v2")).toEqual([]);
  expect(existsSync(join(fixture.home, ".fx", "session-files"))).toBe(false);
}

/// The blob a v2 handle names: the hash at its end, in the session's own
/// folder (D44).
function blobPath(fixture: Fixture, id: string, handle: string): string {
  const match = /-([a-f0-9]{64})(\.[a-z]+)?$/.exec(handle);
  expect(match).not.toBeNull();
  return join(v2Root(fixture), id, "blobs", match![1]!);
}

/// A session's blobs, each read-only (D49).
function blobNames(fixture: Fixture, id: string): string[] {
  const dir = join(v2Root(fixture), id, "blobs");
  if (!existsSync(dir)) return [];
  const names = readdirSync(dir).filter((name) => /^[a-f0-9]{64}$/.test(name));
  for (const name of names) expect(statSync(join(dir, name)).mode & 0o777).toBe(0o400);
  return names;
}

/// A local command such as `fx sessions`, run in the fixture's workspace.
function command(fixture: Fixture, gateway: any, args: string[], v2 = true, cwd = fixture.workspace) {
  return runFx(args, { cwd, env: env(fixture, gateway, v2), timeoutMs: TIMEOUT });
}

async function ask(fixture: Fixture, gateway: any, args: string[], v2 = true) {
  const result = await runFx(["ask", "--json", "--auto", ...args], {
    cwd: fixture.workspace,
    env: env(fixture, gateway, v2),
    timeoutMs: TIMEOUT,
  });
  return result;
}

test("fx ask saves to v2, resumes by id and by last, and never writes v1", async () => {
  const fixture = createFixture("fx-v2-ask-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("V2_FIRST_ANSWER"),
    fakeGatewayFinalText("V2_SECOND_ANSWER"),
    fakeGatewayFinalText("V2_THIRD_ANSWER"),
  ]);
  try {
    const created = await ask(fixture, gateway, ["First v2 question."]);
    expect(created.code).toBe(0);
    expect(created.stderr).toBe("");
    const first = JSON.parse(created.stdout);
    expect(first.output).toBe("V2_FIRST_ANSWER");
    const id: string = first.session_id;
    expect(id.length).toBeGreaterThan(0);
    expect(shape(logLines(fixture, id))).toEqual([
      "session_created",
      "turn_started",
      "item:user",
      "item:assistant",
      "item:turn_end",
      "turn_committed",
      "closed",
    ]);
    expectNoV1Sessions(fixture);
    // Owner-only folders and files.
    expect(statSync(v2Root(fixture)).mode & 0o777).toBe(0o700);
    expect(statSync(join(v2Root(fixture), id, "log.jsonl")).mode & 0o777).toBe(0o600);

    const byId = await ask(fixture, gateway, ["--resume-id", id, "Second v2 question."]);
    expect(byId.code).toBe(0);
    expect(byId.stderr).toBe("");
    expect(JSON.parse(byId.stdout).session_id).toBe(id);
    expect(gateway.requests[1]!.body).toContain("V2_FIRST_ANSWER");

    const byLast = await ask(fixture, gateway, ["--resume", "last", "Third v2 question."]);
    expect(byLast.code).toBe(0);
    expect(JSON.parse(byLast.stdout).session_id).toBe(id);
    expect(gateway.requests[2]!.body).toContain("V2_SECOND_ANSWER");
    expect(gateway.requests[2]!.body).toContain("First v2 question.");

    const kinds = logLines(fixture, id).map((line) => line.kind);
    expect(kinds.filter((kind) => kind === "turn_committed").length).toBe(3);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("the flag works before and after ask, and --no-save writes nothing", async () => {
  const fixture = createFixture("fx-v2-flag-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("FLAG_BEFORE"),
    fakeGatewayFinalText("FLAG_AFTER"),
    fakeGatewayFinalText("NOT_SAVED"),
  ]);
  try {
    const before = await runFx(["--sessions-v2", "ask", "--json", "--auto", "Flag before ask."], {
      cwd: fixture.workspace,
      env: env(fixture, gateway, false),
      timeoutMs: TIMEOUT,
    });
    expect(before.code).toBe(0);
    expect(before.stderr).toBe("");
    const before_id = JSON.parse(before.stdout).session_id;
    expect(existsSync(join(v2Root(fixture), before_id, "log.jsonl"))).toBe(true);

    const after = await ask(fixture, gateway, ["--sessions-v2", "Flag after ask."], false);
    expect(after.code).toBe(0);
    expect(after.stderr).toBe("");
    const after_id = JSON.parse(after.stdout).session_id;
    expect(existsSync(join(v2Root(fixture), after_id, "log.jsonl"))).toBe(true);
    expectNoV1Sessions(fixture);

    const unsaved = await ask(fixture, gateway, ["--no-save", "Not saved."]);
    expect(unsaved.code).toBe(0);
    expect(JSON.parse(unsaved.stdout).session_id).toBe("");
    const folders = readdirSync(v2Root(fixture)).filter((name) => !name.startsWith(".") && !name.startsWith("index"));
    expect(folders.sort()).toEqual([before_id, after_id].sort());
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("fx ask keeps the conversation language when a resumed turn has no language of its own", async () => {
  const fixture = createFixture("fx-v2-language-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("こんにちは。"),
    fakeGatewayFinalText("完了しました。"),
  ]);
  try {
    const seeded = await ask(fixture, gateway, ["こんにちは。日本語で返答してください。"]);
    expect(seeded.code).toBe(0);
    const id = JSON.parse(seeded.stdout).session_id;
    const languages = () =>
      (logLines(fixture, id) as any[]).filter((line) => line.kind === "set" && line.key === "language").map((line) => line.value);
    const seededLanguages = languages();
    expect(seededLanguages.at(-1)).toBe("ja");

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "👍"]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    // The language is written only when it changes, so the resumed turn
    // adds none, and the session still reads as Japanese.
    expect(languages()).toEqual(seededLanguages);
    expect(gateway.requests).toHaveLength(2);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

/// The blob of the compactor record `name` (D50): the newest
/// `compaction_records` line names the blob mapping record names to blobs.
function compactionRecordPath(fixture: Fixture, id: string, name: string): string | undefined {
  const line = (logLines(fixture, id) as any[]).filter((l) => l.kind === "set" && l.key === "compaction_records").at(-1);
  if (!line) return undefined;
  expect(line.blobs).toContain(line.value.map);
  const blobs = join(v2Root(fixture), id, "blobs");
  const hash = JSON.parse(readFileSync(join(blobs, line.value.map), "utf8"))[name];
  return hash ? join(blobs, hash) : undefined;
}

const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

for (const userHeavy of [false, true]) {
  test(`fx ask compacts on its own, keeps what it summarized as blobs, and resumes from the summary, userHeavy=${userHeavy}`, async () => {
    const fixture = createFixture("fx-v2-compaction-");
    const model = "fixture/compaction";
    const originalUser = "Keep café and the original constraint unchanged." +
      (userHeavy ? "\n" + "user_reference_abcdefghijklmnop ".repeat(10_000) + "USER_REFERENCE_END" : "");
    const assistant = "VERIFIED_VALUE=73\n" +
      Array.from({ length: 14_000 }, (_, n) => `Assistant reference ${n}: group ${n % 19}, historical data, not new completed work.\n`).join("") +
      "PENDING_CHECK=transport-resume\n";
    let phase: "seed" | "continue" | "read" = "seed";
    // fx-compactor's notes request. A turn with nothing between its message
    // and its final reply has nothing to note, so it may need none.
    let notesCalls = 0;
    const bodies: string[] = [];
    const gateway = startDynamicFakeGateway((body: string) => {
      bodies.push(body);
      if (body.includes("Write the compaction notes")) {
        notesCalls += 1;
        return fakeGatewayFinalText("none");
      }
      if (phase === "read") {
        if (body.includes("compaction-read-1")) return fakeGatewayFinalText("READ_SAVED_TURN_DONE");
        return fakeGatewayToolCall("compaction-read-1", "read_tool_result", { request: { handle: "M1", query: "Assistant reference 7000:" } });
      }
      return fakeGatewayFinalText(phase === "seed" ? assistant : "CONTINUED_FROM_COMMITTED_MEMORY");
    }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: userHeavy ? 256_000 : 128_000, max_tokens: 8192 }] });
    const compactEnv = { ...env(fixture, gateway), FX_MODEL: model, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models` };
    const run = (args: string[], stdin?: string) =>
      runFx(["ask", "--json", ...args], { cwd: fixture.workspace, env: compactEnv, stdin, timeoutMs: TIMEOUT });
    try {
      const seed = await run([], originalUser);
      expect(seed.code).toBe(0);
      expect(seed.stderr).toBe("");
      expect(notesCalls).toBe(0);
      const id = JSON.parse(seed.stdout).session_id;
      const logPath = join(v2Root(fixture), id, "log.jsonl");
      const before = readFileSync(logPath);

      phase = "continue";
      const continued = await run(["--resume-id", id, "Continue the saved task without losing its pending check."]);
      expect(continued.code).toBe(0);
      expect(continued.stderr).toBe("");
      expect(JSON.parse(continued.stdout).output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");

      // One compaction line holding the compacted conversation, and the
      // turn it compacted saved whole as a compactor record, a blob of the
      // session (D50).
      const compactions = (logLines(fixture, id) as any[]).filter((line) => line.kind === "compacted");
      expect(compactions).toHaveLength(1);
      const data = typeof compactions[0].data === "string" ? JSON.parse(compactions[0].data) : compactions[0].data;
      expect(data.summary.startsWith("fx-compactor-v1\n")).toBe(true);
      const turnPath = compactionRecordPath(fixture, id, "compacted-M1.txt");
      expect(turnPath).toBeDefined();
      const savedTurn = readFileSync(turnPath!, "utf8");
      expect(savedTurn).toContain(originalUser);
      expect(savedTurn).toContain("Assistant reference 7000:");
      expect(savedTurn).toContain("PENDING_CHECK=transport-resume");
      // The model reads both ends of the long reply, and the saved turn's
      // handle for the rest.
      const sent = bodies.at(-1)!;
      expect(sent).toContain("VERIFIED_VALUE=73");
      expect(sent).toContain("PENDING_CHECK=transport-resume");
      expect(sent).not.toContain("Assistant reference 7000:");
      expect(sent).toContain("the whole text is saved in M1");
      // The user's message stays word for word unless it alone outgrows the
      // room; then it keeps its start and end.
      const promptText = (body: string) => JSON.stringify(JSON.parse(body).prompt);
      const shown = (text: string) => JSON.stringify(text).slice(1, -1);
      const expectUserShown = (body: string) => {
        const text = promptText(body);
        if (!userHeavy) return expect(text).toContain(shown(`User 1:\n${originalUser}\n`));
        expect(text).toContain(shown("User 1:\nKeep café and the original constraint unchanged.\n"));
        expect(text).toContain("USER_REFERENCE_END");
        expect(text).not.toContain(shown(originalUser));
      };
      expectUserShown(sent);
      expect(readFileSync(logPath).subarray(0, before.length).equals(before)).toBe(true);
      const notesCallsBeforeReopen = notesCalls;

      // A fresh process resumes from the summary: it sends the summary, not
      // the turns it replaced, and has nothing left to summarize.
      const reopened = await run(["--resume-id", id, "Continue after this fresh process restart."]);
      expect(reopened.code).toBe(0);
      expect(reopened.stderr).toBe("");
      expect(JSON.parse(reopened.stdout).output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
      expect(bodies.at(-1)).toContain("VERIFIED_VALUE=73");
      expect(bodies.at(-1)).not.toContain("Assistant reference 7000:");
      expectUserShown(bodies.at(-1)!);
      expect(notesCalls).toBe(notesCallsBeforeReopen);
      expect((logLines(fixture, id) as any[]).filter((line) => line.kind === "compacted")).toHaveLength(1);
      expect(readFileSync(logPath).subarray(0, before.length).equals(before)).toBe(true);

      // Another fresh process reads the saved turn by its ID, through the
      // records the session keeps as blobs (D50).
      phase = "read";
      const read = await run(["--resume-id", id, "Read the saved turn."]);
      expect(read.code).toBe(0);
      // Tool progress goes to stderr.
      expect(read.stderr).not.toContain("panic");
      expect(JSON.parse(read.stdout).output).toBe("READ_SAVED_TURN_DONE");
      expect(bodies.findLast((body) => body.includes("compaction-read-1"))).toContain("Assistant reference 7000: group 8");
      expectWholeLog(fixture, id);
      expectNoV1Sessions(fixture);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, 90_000);
}

test("a tool turn keeps its result as a blob of the session and v1 ignores the v2 root", async () => {
  const fixture = createFixture("fx-v2-tool-");
  const gateway = startFakeGateway([
    fakeShellRun("v2-shell-1", "echo V2_TOOL_OUTPUT_7731"),
    fakeGatewayFinalText("V2_TOOL_DONE"),
    fakeGatewayFinalText("V2_TOOL_RESUMED"),
  ]);
  try {
    const created = await ask(fixture, gateway, ["Run the tool."]);
    expect(created.code).toBe(0);
    // Tool progress goes to stderr; the answer and session id to stdout.
    expect(created.stderr).toContain("V2_TOOL_OUTPUT_7731");
    const id = JSON.parse(created.stdout).session_id;
    const lines = logLines(fixture, id);
    expect(shape(lines)).toContain("item:tool_call");
    expect(shape(lines)).toContain("item:tool_result");
    // The body is a read-only blob named by its hash, not in the log, and
    // the result item lists it (D44).
    const result = (lines as any[]).find((line) => line.kind === "item" && line.type === "tool_result");
    const handle = /result-[a-f0-9]{64}\.txt/.exec(JSON.stringify(itemData(result)))?.[0] ?? "";
    expect(handle).toMatch(/^result-[a-f0-9]{64}\.txt$/);
    const hash = /-([a-f0-9]{64})\./.exec(handle)![1]!;
    expect(blobNames(fixture, id)).toContain(hash);
    expect(readFileSync(blobPath(fixture, id, handle), "utf8")).toContain("V2_TOOL_OUTPUT_7731");
    expect((lines as any[]).some((line) => (line.blobs ?? []).includes(hash))).toBe(true);

    const resumed = await ask(fixture, gateway, ["--resume", "last", "What did the tool print?"]);
    expect(resumed.code).toBe(0);
    expect(gateway.requests.at(-1)!.body).toContain("V2_TOOL_OUTPUT_7731");

    // A v1 process lists no session named v2.
    const listed = await runFx(["sessions", "--json"], {
      cwd: fixture.workspace,
      env: env(fixture, gateway, false),
      timeoutMs: TIMEOUT,
    });
    expect(listed.code).toBe(0);
    expect(listed.stdout).not.toContain("\"v2\"");
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a long command output is kept as one read-only blob, and the model pages it after a resume", async () => {
  const fixture = createFixture("fx-v2-replay-");
  // Past the inline capture limit, the output spools outside the session
  // while the command runs and is kept with a chunked copy (D44).
  const lineCount = 200_000;
  const expected = Array.from({ length: lineCount }, (_, i) => `${i + 1}\n`).join("");
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("Page the output again.")) {
      if (body.includes("replay-read-1")) return fakeGatewayFinalText("REPLAY_PAGED_DONE");
      const handle = /fx-command-replay-[a-f0-9]{64}\.bin/.exec(body)?.[0] ?? "missing-handle";
      return fakeGatewayToolCall("replay-read-1", "read_tool_result", {
        request: { handle, query: "150001" },
      });
    }
    if (body.includes("replay-run-1")) return fakeGatewayFinalText("LONG_RUN_DONE");
    return fakeShellRun("replay-run-1", `seq 1 ${lineCount}`);
  });
  try {
    const created = await ask(fixture, gateway, ["Run the long command."]);
    expect(created.code).toBe(0);
    expect(JSON.parse(created.stdout).output).toBe("LONG_RUN_DONE");
    const id = JSON.parse(created.stdout).session_id;

    const handle = /fx-command-replay-[a-f0-9]{64}\.bin/.exec(JSON.stringify(logLines(fixture, id)))?.[0] ?? "";
    expect(handle).toMatch(/^fx-command-replay-[a-f0-9]{64}\.bin$/);
    const hash = /-([a-f0-9]{64})\./.exec(handle)![1]!;
    expect(blobNames(fixture, id)).toContain(hash);
    expect(blobNames(fixture, id).every((name) => /^[a-f0-9]{64}$/.test(name))).toBe(true);
    const blob = blobPath(fixture, id, handle);
    expect(statSync(blob).mode & 0o777).toBe(0o400);
    // The blob is the whole replay file, named by its own hash: the magic,
    // then frames of a stream byte, a little-endian u64 length and bytes.
    const replay = readFileSync(blob);
    expect(createHash("sha256").update(replay).digest("hex")).toBe(hash);
    expect(replay.subarray(0, 8).toString("latin1")).toBe("FXRPLY01");
    const stdout: Buffer[] = [];
    for (let offset = 8; offset < replay.length;) {
      const length = Number(replay.readBigUInt64LE(offset + 1));
      if (replay[offset] === 0) stdout.push(replay.subarray(offset + 9, offset + 9 + length));
      offset += 9 + length;
    }
    expect(Buffer.concat(stdout).toString("utf8")).toBe(expected);

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Page the output again."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).not.toContain("panic");
    expect(JSON.parse(resumed.stdout).output).toBe("REPLAY_PAGED_DONE");
    // The middle of the output reaches the model only through the page read.
    const beforeRead = gateway.requests.findLast((request: any) => request.body.includes("Page the output again.") && !request.body.includes("replay-read-1"));
    expect(beforeRead!.body).not.toContain("150001");
    // The replay store answers, from the decoded output rather than the
    // blob's raw frames: the matching line comes back as the model sees it.
    const afterRead = gateway.requests.findLast((request: any) => request.body.includes("replay-read-1"))!.body;
    expect(afterRead).toContain("<command_output_query handle=");
    expect(afterRead).toContain("150001\\\\x0a");
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("fx ask killed in the middle of a turn resumes with that turn interrupted", async () => {
  const fixture = createFixture("fx-v2-kill-");
  let stalled: () => void = () => {};
  const reachedStall = new Promise<void>((resolve) => (stalled = resolve));
  // Replies follow the request, not the call count: a fresh session also
  // asks for a title in the background.
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the kill.")) return fakeGatewayFinalText("AFTER_KILL_ANSWER");
    if (body.includes("This turn is killed.")) {
      stalled();
      return new Promise<Response>(() => {});
    }
    return fakeGatewayFinalText("BEFORE_KILL_ANSWER");
  });
  try {
    const created = await ask(fixture, gateway, ["Before the kill."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;

    const child = spawn(FX_BIN, ["ask", "--json", "--auto", "--resume-id", id, "This turn is killed."], {
      cwd: fixture.workspace,
      env: { ...process.env, ...env(fixture, gateway) } as Record<string, string>,
      stdio: "ignore",
    });
    await reachedStall;
    const exited = new Promise((resolve) => child.on("exit", resolve));
    child.kill("SIGKILL");
    await exited;

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the kill."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_KILL_ANSWER");
    // The history the model sees keeps the first turn.
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_KILL_ANSWER");
    // The killed turn's user piece was saved before the model call; the
    // reopen ended that turn as a crash, and the model saw it.
    expect(gateway.requests.at(-1)!.body).toContain("This turn is killed.");
    const lines = logLines(fixture, id);
    for (const [index, line] of lines.entries()) expect(line.seq).toBe(index + 1);
    const crashed = lines.filter((line) => line.kind === "turn_interrupted");
    expect(crashed.map((line) => line.reason)).toEqual(["crash"]);
    expect(shape(lines).filter((kind) => kind === "turn_committed").length).toBe(2);
    expect(shape(lines).filter((kind) => kind === "item:user").length).toBe(3);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a kill while a tool runs keeps the finished tool and answers the running one", async () => {
  const fixture = createFixture("fx-v2-kill-tool-");
  let slowServed: () => void = () => {};
  const slowStarted = new Promise<void>((resolve) => (slowServed = resolve));
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the tool kill.")) return fakeGatewayFinalText("AFTER_TOOL_KILL");
    if (body.includes("Run two tools.") && body.includes("FIRST_TOOL_OUTPUT_5521")) {
      slowServed();
      return fakeShellRun("v2-slow-2", "sleep 5");
    }
    if (body.includes("Run two tools.")) return fakeShellRun("v2-fast-1", "echo FIRST_TOOL_OUTPUT_5521");
    return fakeGatewayFinalText("BEFORE_TOOL_KILL");
  });
  try {
    const created = await ask(fixture, gateway, ["Before the tool kill."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;

    const run = spawnAsk(fixture, gateway, ["--resume-id", id, "Run two tools."]);
    await slowStarted;
    // The call is saved before it runs (D28).
    await waitForLog(fixture, id, "v2-slow-2");
    run.child.kill("SIGKILL");
    await run.exited;

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the tool kill."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_TOOL_KILL");
    const body = gateway.requests.at(-1)!.body;
    expect(body).toContain("BEFORE_TOOL_KILL");
    // The finished tool survives the crash, and the running one comes back
    // answered as possibly run, so every call keeps a result.
    expect(body).toContain("FIRST_TOOL_OUTPUT_5521");
    expectPairedToolCalls(body);
    const { calls, results } = promptToolParts(body);
    expect(calls.map((part) => part.toolCallId)).toEqual(["v2-fast-1", "v2-slow-2"]);
    const slow = results.find((part) => part.toolCallId === "v2-slow-2");
    expect(slow?.output?.type).toBe("error-text");
    expect(slow?.output?.value).toContain("may have partly run");
    const lines = logLines(fixture, id);
    expect(lines.filter((line) => line.kind === "item" && line.type === "tool_running").length).toBe(2);
    expect(lines.filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual(["crash"]);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a kill while a tool runs keeps the text of the message that issued it", async () => {
  const fixture = createFixture("fx-v2-kill-text-");
  let slowServed: () => void = () => {};
  const slowStarted = new Promise<void>((resolve) => (slowServed = resolve));
  const shell = (command: string) => JSON.stringify({ request: { yield_time_ms: 30_000, action: "run", command } });
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the text kill.")) return fakeGatewayFinalText("AFTER_TEXT_KILL");
    if (body.includes("Run the build.") && body.includes("FIRST_STEP_OUTPUT_4410")) {
      slowServed();
      return fakeGatewaySerializedToolCall("v2-slow-2", "shell", shell("sleep 5"), "RUNNING_PLAN_7731 builds it now.");
    }
    if (body.includes("Run the build.")) {
      return fakeGatewaySerializedToolCall("v2-fast-1", "shell", shell("echo FIRST_STEP_OUTPUT_4410"), "EARLIER_PLAN_2209 reads first.");
    }
    return fakeGatewayFinalText("BEFORE_TEXT_KILL");
  });
  try {
    const created = await ask(fixture, gateway, ["Before the text kill."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;

    const run = spawnAsk(fixture, gateway, ["--resume-id", id, "Run the build."]);
    await slowStarted;
    await waitForLog(fixture, id, "v2-slow-2");
    run.child.kill("SIGKILL");
    await run.exited;
    // The text is saved with the running call, before the tool finishes (D51).
    const running = logLines(fixture, id).filter((line) => line.kind === "item" && line.type === "assistant_running");
    expect(running.length).toBe(2);
    expect(JSON.stringify(running.at(-1))).toContain("RUNNING_PLAN_7731");

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the text kill."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_TEXT_KILL");
    const body = gateway.requests.at(-1)!.body;
    expectPairedToolCalls(body);
    // Each step keeps its own text, beside its own call, once.
    expect(assistantTextBeside(body, "v2-fast-1")).toBe("EARLIER_PLAN_2209 reads first.");
    expect(assistantTextBeside(body, "v2-slow-2")).toBe("RUNNING_PLAN_7731 builds it now.");
    expect(body.split("RUNNING_PLAN_7731").length - 1).toBe(1);
    expect(body.split("EARLIER_PLAN_2209").length - 1).toBe(1);
    const { results } = promptToolParts(body);
    expect(results.find((part) => part.toolCallId === "v2-slow-2")?.output?.value).toContain("may have partly run");
    expect(logLines(fixture, id).filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual([
      "crash",
    ]);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a session whose first turn was killed takes its first prompt as title", async () => {
  const fixture = createFixture("fx-v2-first-kill-title-");
  let slowServed: () => void = () => {};
  const slowStarted = new Promise<void>((resolve) => (slowServed = resolve));
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the first-turn kill.")) return fakeGatewayFinalText("AFTER_FIRST_TURN_KILL");
    slowServed();
    return fakeShellRun("v2-first-slow", "sleep 30");
  });
  try {
    const run = spawnAsk(fixture, gateway, ["Why is the sky orange at dusk?"]);
    await slowStarted;
    const deadline = Date.now() + 10_000;
    while (savedSessions(fixture).length === 0 && Date.now() < deadline) await Bun.sleep(50);
    const id = onlySession(fixture);
    await waitForLog(fixture, id, "v2-first-slow");
    run.child.kill("SIGKILL");
    await run.exited;
    expect(storedTitles(fixture, id)).toEqual([]);

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the first-turn kill."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    // The title comes from the first prompt, which the crashed turn kept (D52).
    expect(storedTitles(fixture, id)).toEqual(["Why is the sky orange at dusk?"]);
    const listed = await command(fixture, gateway, ["sessions", "--json"]);
    expect(listed.code).toBe(0);
    const summary = JSON.parse(listed.stdout).sessions.find((entry: any) => entry.id === id);
    expect(summary.title).toBe("Why is the sky orange at dusk?");
    // Later turns leave it.
    expect((await ask(fixture, gateway, ["--resume-id", id, "After the first-turn kill. Again."])).code).toBe(0);
    expect(storedTitles(fixture, id)).toEqual(["Why is the sky orange at dusk?"]);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a torn tail is cut on resume and the session goes on", async () => {
  const fixture = createFixture("fx-v2-torn-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("BEFORE_TORN_TAIL"),
    fakeGatewayFinalText("AFTER_TORN_TAIL"),
  ]);
  try {
    const created = await ask(fixture, gateway, ["Before the torn tail."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;
    // A write cut short by a power loss: part of a line, no newline.
    appendFileSync(join(v2Root(fixture), id, "log.jsonl"), '{"v":1,"seq":99,"ts":1,"kind":"item","ty');

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the torn tail."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_TORN_TAIL");
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_TORN_TAIL");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8")).not.toContain('"seq":99');
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a flipped byte inside the log stops resume and leaves the file as it was", async () => {
  const fixture = createFixture("fx-v2-flip-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("FLIP_FIRST"),
    fakeGatewayFinalText("FLIP_SECOND"),
    fakeGatewayFinalText("FLIP_NEVER"),
  ]);
  try {
    const created = await ask(fixture, gateway, ["Flip question one."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;
    expect((await ask(fixture, gateway, ["--resume-id", id, "Flip question two."])).code).toBe(0);
    const path = join(v2Root(fixture), id, "log.jsonl");
    const damaged = readFileSync(path, "utf8").replace("Flip question one.", "Flip question 0ne.");
    writeFileSync(path, damaged);
    const requests = gateway.requests.length;

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Flip question three."]);
    expect(resumed.code).toBe(1);
    expect(resumed.stdout + resumed.stderr).toContain("InvalidSessionFormat");
    // No request was made, and the damaged file is left for recovery.
    expect(gateway.requests.length).toBe(requests);
    expect(readFileSync(path, "utf8")).toBe(damaged);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a blob that went missing stops resume as damage, not as a missing session", async () => {
  const fixture = createFixture("fx-v2-lost-blob-");
  const big = "LOST_BLOB_START " + "blob-body ".repeat(30_000) + "LOST_BLOB_END";
  const gateway = startFakeGateway([fakeGatewayFinalText(big)]);
  try {
    const created = await ask(fixture, gateway, ["Answer at great length."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;
    const referenced = (logLines(fixture, id) as any[]).find((line) => Array.isArray(line.blobs) && line.blobs.length === 1);
    rmSync(join(v2Root(fixture), id, "blobs", referenced.blobs[0]));

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Continue after the lost blob."]);
    expect(resumed.code).toBe(1);
    expect(resumed.stdout + resumed.stderr).toContain("InvalidSessionFormat");
    expect(resumed.stdout + resumed.stderr).not.toContain("NotFound");
    expect(gateway.requests).toHaveLength(1);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test("a second process on an open session is refused and writes nothing", async () => {
  const fixture = createFixture("fx-v2-busy-");
  let stalled: () => void = () => {};
  const reachedStall = new Promise<void>((resolve) => (stalled = resolve));
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the busy session.")) return fakeGatewayFinalText("AFTER_BUSY");
    if (body.includes("Hold the session.")) {
      stalled();
      return new Promise<Response>(() => {});
    }
    return fakeGatewayFinalText("BEFORE_BUSY");
  });
  try {
    const created = await ask(fixture, gateway, ["Before the busy session."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;

    const holder = spawnAsk(fixture, gateway, ["--resume-id", id, "Hold the session."]);
    await reachedStall;
    const second = await ask(fixture, gateway, ["--resume-id", id, "A second process."]);
    expect(second.code).toBe(1);
    expect(second.stdout + second.stderr).toContain("SessionBusy");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8")).not.toContain("A second process.");
    holder.child.kill("SIGKILL");
    await holder.exited;

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the busy session."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_BUSY");
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a read-only session folder fails cleanly and resumes once writable", async () => {
  const fixture = createFixture("fx-v2-readonly-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("BEFORE_READ_ONLY"),
    fakeGatewayFinalText("AFTER_READ_ONLY"),
  ]);
  const folder = () => join(v2Root(fixture), id);
  let id = "";
  try {
    const created = await ask(fixture, gateway, ["Before the read-only folder."]);
    expect(created.code).toBe(0);
    id = JSON.parse(created.stdout).session_id;
    const before = readFileSync(join(folder(), "log.jsonl"));
    chmodSync(join(folder(), "log.jsonl"), 0o400);
    chmodSync(folder(), 0o500);

    const refused = await ask(fixture, gateway, ["--resume-id", id, "While read-only."]);
    expect(refused.code).toBe(1);
    // The OS cause, not a bare `Io` (D29).
    expect(JSON.parse(refused.stdout).error).toBe("AccessDenied");
    expect(gateway.requests.length).toBe(1);
    expect(readFileSync(join(folder(), "log.jsonl")).equals(before)).toBe(true);

    chmodSync(folder(), 0o700);
    chmodSync(join(folder(), "log.jsonl"), 0o600);
    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the read-only folder."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_READ_ONLY");
    expectWholeLog(fixture, id);
  } finally {
    if (id) {
      chmodSync(folder(), 0o700);
      chmodSync(join(folder(), "log.jsonl"), 0o600);
    }
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a full disk fails the turn cleanly and the session resumes after", async () => {
  const fixture = createFixture("fx-v2-full-");
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the full disk.")) return fakeGatewayFinalText("AFTER_FULL_DISK");
    if (body.includes("The disk is full.")) return fakeGatewayFinalText("X".repeat(8192));
    return fakeGatewayFinalText("BEFORE_FULL_DISK");
  });
  try {
    const created = await ask(fixture, gateway, ["Before the full disk."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;
    const path = join(v2Root(fixture), id, "log.jsonl");
    // A file-size limit just above the log, with SIGXFSZ ignored: the next
    // growing write fails with EFBIG, as a full disk fails with ENOSPC.
    const blocks = blocksJustPast(path);
    const full = await askWithSizeLimit(fixture, gateway, blocks, ["--resume-id", id, "The disk is full."]);
    // The answer was shown, but the turn could not be saved.
    expect(full.code).toBe(1);
    expect(JSON.parse(full.stdout).error).toBe("FileTooBig");

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "After the full disk."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_FULL_DISK");
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_FULL_DISK");
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

// ---------------------------------------------------------------------------
// The interactive app

/// Answers the newest prompt in the request, in the order given: every
/// request carries the earlier prompts, and a fresh session also asks for a
/// title. A null answer holds that request open and calls `held`.
function replyToLatest(pairs: [string, string | null][], held?: () => void, options: FakeGatewayOptions = {}) {
  return startDynamicFakeGateway(async (body) => {
    for (let index = pairs.length - 1; index >= 0; index -= 1) {
      const [prompt, answer] = pairs[index]!;
      if (!body.includes(prompt)) continue;
      if (answer !== null) return fakeGatewayFinalText(answer);
      held?.();
      return new Promise<Response>(() => {});
    }
    return fakeGatewayFinalText("UNEXPECTED_REQUEST");
  }, options);
}

async function startApp(fixture: Fixture, gateway: any, args: string[], waitForComposer = true, extraEnv: Record<string, string> = {}) {
  const stderrPath = join(fixture.root, "stderr.log");
  writeFileSync(stderrPath, "");
  const session = await TmuxSession.create({
    cmd: `${FX_BIN} --sessions-v2 ${args.join(" ")}`.trim(),
    cwd: fixture.workspace,
    env: { ...env(fixture, gateway, false), NO_COLOR: "1", ...extraEnv },
    stderrPath,
  });
  if (waitForComposer) await session.waitForComposer(TIMEOUT);
  return { session, stderrPath };
}

async function quitApp(app: { session: TmuxSession; stderrPath: string }) {
  await app.session.sendText("/quit");
  expect(await app.session.waitForSessionEnd()).toBe(true);
  await app.session.kill();
  expect(readFileSync(app.stderrPath, "utf8")).toBe("");
}

function savedSessions(fixture: Fixture): string[] {
  return readdirSync(v2Root(fixture)).filter((name) => !name.startsWith(".") && !name.startsWith("index"));
}

function onlySession(fixture: Fixture): string {
  const ids = savedSessions(fixture);
  expect(ids.length).toBe(1);
  return ids[0]!;
}

async function scrollbackContains(session: TmuxSession, marker: string) {
  const deadline = Date.now() + TIMEOUT;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.captureFullScrollback();
    if (latest.includes(marker)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`scrollback never showed ${marker}`);
}

test.skipIf(!tmuxAvailable())("the interactive app saves to v2 and resumes with -c, --resume last and the id", async () => {
  const fixture = createFixture("fx-v2-app-");
  const gateway = replyToLatest([
    ["First interactive question.", "APP_V2_FIRST"],
    ["Continue with -c.", "APP_V2_CONTINUE"],
    ["Continue with --resume last.", "APP_V2_LAST"],
    ["Continue with the id.", "APP_V2_BY_ID"],
  ]);
  try {
    const first = await startApp(fixture, gateway, []);
    await first.session.sendText("First interactive question.");
    await first.session.waitForText("APP_V2_FIRST", TIMEOUT);
    await quitApp(first);
    const id = onlySession(fixture);
    expectNoV1Sessions(fixture);

    const runs: [string[], string, string, string][] = [
      [["-c"], "APP_V2_FIRST", "Continue with -c.", "APP_V2_CONTINUE"],
      [["--resume", "last"], "APP_V2_CONTINUE", "Continue with --resume last.", "APP_V2_LAST"],
      [["--resume", id], "APP_V2_LAST", "Continue with the id.", "APP_V2_BY_ID"],
    ];
    for (const [args, restored, prompt, answer] of runs) {
      const app = await startApp(fixture, gateway, args);
      expect(await scrollbackContains(app.session, restored)).toContain(restored);
      await app.session.sendText(prompt);
      await app.session.waitForText(answer, TIMEOUT);
      await quitApp(app);
      expect(onlySession(fixture)).toBe(id);
    }
    expect(gateway.requests.at(-1)!.body).toContain("First interactive question.");
    const kinds = logLines(fixture, id).map((line) => line.kind);
    expect(kinds.filter((kind) => kind === "turn_committed").length).toBe(4);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 6);

test.skipIf(!tmuxAvailable())("the interactive app resumes a session with a shell result and takes the next prompt", async () => {
  const fixture = createFixture("fx-v2-app-shell-resume-");
  const gateway = startFakeGateway([
    fakeShellRun("app-shell-1", "printf 'APP_SHELL_OUTPUT_4417\\n'"),
    fakeGatewayFinalText("APP_SHELL_DONE"),
    fakeGatewayFinalText("APP_AFTER_SHELL_RESUME"),
  ]);
  try {
    const first = await startApp(fixture, gateway, []);
    await first.session.sendText("Run the shell command.");
    await scrollbackContains(first.session, "APP_SHELL_DONE");
    await first.session.waitForComposer(TIMEOUT);
    await quitApp(first);
    const id = onlySession(fixture);

    // Drawing the saved shell row reads its command replay from the side
    // folder while the history is being visited.
    const resumed = await startApp(fixture, gateway, ["-c"]);
    const shown = await scrollbackContains(resumed.session, "APP_SHELL_DONE");
    expect(shown).toContain("printf 'APP_SHELL_OUTPUT_4417");
    await resumed.session.sendText("Continue after the shell turn.");
    await resumed.session.waitForText("APP_AFTER_SHELL_RESUME", TIMEOUT);
    await quitApp(resumed);
    expect(onlySession(fixture)).toBe(id);
    expect(gateway.requests.at(-1)!.body).toContain("APP_SHELL_OUTPUT_4417");
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test.skipIf(!tmuxAvailable())("an app quit before its first prompt leaves no session and no folder outside the manager", async () => {
  const fixture = createFixture("fx-v2-app-pristine-");
  const gateway = replyToLatest([]);
  try {
    const app = await startApp(fixture, gateway, []);
    await quitApp(app);
    expect(existsSync(v2Root(fixture)) ? savedSessions(fixture) : []).toEqual([]);
    expect(existsSync(join(fixture.home, ".fx", "session-files"))).toBe(false);
    const terminals = join(fixture.home, ".fx", "terminal");
    expect(existsSync(terminals) ? readdirSync(terminals) : []).toEqual([]);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test.skipIf(!tmuxAvailable())("a killed interactive turn comes back interrupted and -c continues it", async () => {
  const fixture = createFixture("fx-v2-app-kill-");
  let held: () => void = () => {};
  const reachedHold = new Promise<void>((resolve) => (held = resolve));
  const gateway = replyToLatest(
    [
      ["Before the interactive kill.", "APP_BEFORE_KILL"],
      ["This interactive turn is killed.", null],
      ["After the interactive kill.", "APP_AFTER_KILL"],
    ],
    () => held(),
  );
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Before the interactive kill.");
    await app.session.waitForText("APP_BEFORE_KILL", TIMEOUT);
    await app.session.sendText("This interactive turn is killed.");
    await reachedHold;
    Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
    await app.session.kill();
    const id = onlySession(fixture);

    const resumed = await startApp(fixture, gateway, ["-c"]);
    expect(await scrollbackContains(resumed.session, "APP_BEFORE_KILL")).toContain("APP_BEFORE_KILL");
    await resumed.session.sendText("After the interactive kill.");
    await resumed.session.waitForText("APP_AFTER_KILL", TIMEOUT);
    await quitApp(resumed);
    expect(onlySession(fixture)).toBe(id);
    // The killed prompt was saved before its request, and the model sees it.
    expect(gateway.requests.at(-1)!.body).toContain("This interactive turn is killed.");
    const lines = logLines(fixture, id);
    expect(lines.filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual(["crash"]);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test.skipIf(!tmuxAvailable())("the picker lists v2 sessions, /rename sticks, and /new starts another", async () => {
  const fixture = createFixture("fx-v2-app-picker-");
  const gateway = replyToLatest([
    ["Picker session one.", "PICK_ONE"],
    ["Picker session two.", "PICK_TWO"],
    ["Back in session one.", "PICK_BACK"],
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Picker session one.");
    await app.session.waitForText("PICK_ONE", TIMEOUT);
    await app.session.sendText("/rename Renamed picker session");
    await app.session.waitForText('renamed to "Renamed picker session"', TIMEOUT);
    await app.session.waitForStableComposer();
    await app.session.sendText("/new");
    await app.session.waitForStableComposer();
    await app.session.sendText("Picker session two.");
    await app.session.waitForText("PICK_TWO", TIMEOUT);
    await quitApp(app);
    const ids = savedSessions(fixture);
    expect(ids.length).toBe(2);

    const picker = await startApp(fixture, gateway, ["-r"], false);
    await picker.session.waitForPane((pane) => pane.includes("Renamed picker session") && pane.includes("enter resume"), TIMEOUT);
    await picker.session.sendLiteralText("Renamed");
    await picker.session.waitForPane((pane) => pane.includes("Renamed picker session"), TIMEOUT);
    await picker.session.sendKeys("Enter");
    await picker.session.waitForComposer(TIMEOUT);
    expect(await scrollbackContains(picker.session, "PICK_ONE")).toContain("PICK_ONE");
    await picker.session.sendText("Back in session one.");
    await picker.session.waitForText("PICK_BACK", TIMEOUT);
    await quitApp(picker);

    // The resumed session is the renamed one: its log holds both of its turns.
    const renamed = ids.find((id) => readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8").includes("Renamed picker session"))!;
    const log = readFileSync(join(v2Root(fixture), renamed, "log.jsonl"), "utf8");
    expect(log).toContain("Back in session one.");
    expect(log).not.toContain("Picker session two.");
    for (const id of ids) expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 6);

test.skipIf(!tmuxAvailable())("the picker shows a session open in another fx as busy at once, and opens it once the owner quits", async () => {
  const fixture = createFixture("fx-v2-app-picker-busy-");
  const gateway = replyToLatest([["Hold this session open.", "PICKER_BUSY_SAVED"]]);
  const busy = "This session is open in another fx. Close it there, then press enter to retry.";
  let contender: TmuxSession | null = null;
  try {
    const owner = await startApp(fixture, gateway, []);
    await owner.session.sendText("Hold this session open.");
    await owner.session.waitForText("PICKER_BUSY_SAVED", TIMEOUT);
    const id = onlySession(fixture);

    const contenderStderr = join(fixture.root, "contender-stderr.log");
    writeFileSync(contenderStderr, "");
    contender = await TmuxSession.create({
      cmd: `${FX_BIN} --sessions-v2 -r`,
      cwd: fixture.workspace,
      env: { ...env(fixture, gateway, false), NO_COLOR: "1" },
      stderrPath: contenderStderr,
    });
    await contender.waitForPane((pane) => pane.includes("Hold this session open.") && pane.includes("enter resume"), TIMEOUT);
    // v1's picker takes no lock wait, and neither does v2's (D38).
    const pressed = Date.now();
    await contender.sendKeys("Enter");
    await contender.waitForPane((pane) => pane.includes(busy), 1_000);
    expect(Date.now() - pressed).toBeLessThan(1_000);
    expect(owner.session.isPaneAlive()).toBe(true);

    await quitApp(owner);
    await contender.sendKeys("Enter");
    await contender.waitForComposer(TIMEOUT);
    expect(await scrollbackContains(contender, "PICKER_BUSY_SAVED")).toContain("PICKER_BUSY_SAVED");
    await contender.sendText("/quit");
    expect(await contender.waitForSessionEnd()).toBe(true);
    expect(readFileSync(contenderStderr, "utf8")).toBe("");
    expect(onlySession(fixture)).toBe(id);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    if (contender) await contender.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

// ---------------------------------------------------------------------------
// ACP

/// A minimal ACP client: requests by id, every `session/update` kept,
/// permission requests allowed once.
class AcpRpc {
  private proc: ReturnType<typeof spawn>;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, (msg: any) => void>();
  readonly updates: any[] = [];
  readonly exited: Promise<number | null>;

  constructor(fixture: Fixture, gateway: any, extraEnv: Record<string, string | undefined> = {}, limitBlocks?: number) {
    // With `limitBlocks`, under a file-size limit as `askWithSizeLimit` sets.
    const [command, args] = limitBlocks === undefined
      ? [FX_BIN, ["acp"]]
      : ["/bin/sh", ["-c", `trap '' XFSZ; ulimit -f ${limitBlocks}; exec "$0" "$@"`, FX_BIN, "acp"]];
    this.proc = spawn(command, args, {
      cwd: fixture.workspace,
      env: { ...process.env, ...env(fixture, gateway), ...extraEnv } as Record<string, string>,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.exited = new Promise((resolve) => this.proc.on("exit", (code) => resolve(code)));
    this.proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        if (line.trim()) this.onMessage(JSON.parse(line));
      }
    });
  }

  static async start(fixture: Fixture, gateway: any, extraEnv: Record<string, string | undefined> = {}, limitBlocks?: number) {
    const client = new AcpRpc(fixture, gateway, extraEnv, limitBlocks);
    const initialized = await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    if (initialized.error) throw new Error(JSON.stringify(initialized.error));
    return client;
  }

  private onMessage(msg: any) {
    if (msg.method === "session/update") {
      this.updates.push(msg.params);
    } else if (msg.method !== undefined && msg.id !== undefined) {
      const result = msg.method === "session/request_permission" ? { outcome: { outcome: "selected", optionId: "allow_once" } } : {};
      this.proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");
    } else if (msg.id !== undefined && this.pending.has(msg.id)) {
      this.pending.get(msg.id)!(msg);
      this.pending.delete(msg.id);
    }
  }

  /// Resolves with the whole response, `error` included.
  request(method: string, params: object, timeoutMs = 20_000): Promise<any> {
    const id = this.nextId++;
    this.proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      this.pending.set(id, (msg) => {
        clearTimeout(timer);
        resolve(msg);
      });
    });
  }

  async ok(method: string, params: object) {
    const response = await this.request(method, params);
    if (response.error) throw new Error(`${method}: ${JSON.stringify(response.error)}`);
    return response.result;
  }

  /// Text of the updates of one kind, in order.
  texts(kind: "user_message_chunk" | "agent_message_chunk") {
    return this.updates.filter((u) => u.update?.sessionUpdate === kind).map((u) => u.update.content?.text ?? "");
  }

  async close() {
    this.proc.stdin!.end();
    const exited = await Promise.race([this.exited, Bun.sleep(10_000).then(() => "timeout")]);
    if (exited === "timeout") this.proc.kill("SIGKILL");
    return exited;
  }

  kill() {
    this.proc.kill("SIGKILL");
    return this.exited;
  }
}

function acpPrompt(text: string) {
  return { prompt: [{ type: "text", text }] };
}

test("ACP keeps a session once prompted, lists it, and loads every turn after a restart", async () => {
  const fixture = createFixture("fx-v2-acp-");
  const gateway = replyToLatest([
    ["First ACP question.", "ACP_ONE"],
    ["Second ACP question.", "ACP_TWO"],
    ["Third ACP question.", "ACP_THREE"],
  ]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    // Never prompted, so never written (D24).
    const unused = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    expect(id).not.toBe(unused);
    expect((await client.ok("session/prompt", { sessionId: id, ...acpPrompt("First ACP question.") })).stopReason).toBe("end_turn");
    expect((await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Second ACP question.") })).stopReason).toBe("end_turn");
    const listed = await client.ok("session/list", { cwd: fixture.workspace });
    expect(listed.sessions.map((s: any) => s.sessionId)).toEqual([id]);
    expect(listed.sessions[0].cwd).toBe(fixture.workspace);
    expect(Date.parse(listed.sessions[0].updatedAt)).toBeGreaterThan(0);
    expect((await client.ok("session/list", { cwd: join(fixture.root, "elsewhere") })).sessions).toEqual([]);
    // v1 matches the folder after trailing slashes too.
    expect((await client.ok("session/list", { cwd: `${fixture.workspace}/` })).sessions.map((s: any) => s.sessionId)).toEqual([id]);
    expect(await client.close()).toBe(0);
    expect(existsSync(join(v2Root(fixture), unused))).toBe(false);

    client = await AcpRpc.start(fixture, gateway);
    const missing = await client.request("session/load", { sessionId: unused, cwd: fixture.workspace, mcpServers: [] });
    expect(missing.error?.message).toBe("Session not found");
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.texts("user_message_chunk")).toEqual(["First ACP question.", "Second ACP question."]);
    expect(client.texts("agent_message_chunk")).toEqual(["ACP_ONE", "ACP_TWO"]);
    // Resume attaches without replaying.
    const replayed = client.updates.length;
    await client.ok("session/resume", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.updates.slice(replayed).filter((u) => u.update?.sessionUpdate === "user_message_chunk")).toEqual([]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Third ACP question.") });
    const body = gateway.requests.at(-1)!.body;
    expect(body).toContain("ACP_ONE");
    expect(body).toContain("ACP_TWO");
    expect(await client.close()).toBe(0);
    client = undefined;

    const lines = logLines(fixture, id);
    expect(lines.filter((line) => line.kind === "turn_committed").length).toBe(3);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test("ACP killed in the middle of a prompt loads with that turn interrupted", async () => {
  const fixture = createFixture("fx-v2-acp-kill-");
  let held: () => void = () => {};
  const holding = new Promise<void>((resolve) => (held = resolve));
  const gateway = replyToLatest(
    [
      ["Before the ACP kill.", "ACP_BEFORE"],
      ["Held ACP question.", null],
      ["After the ACP kill.", "ACP_AFTER"],
    ],
    () => held(),
  );
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Before the ACP kill.") });
    void client.request("session/prompt", { sessionId: id, ...acpPrompt("Held ACP question.") }).catch(() => {});
    await holding;
    await waitForLog(fixture, id, "Held ACP question.");
    await client.kill();

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.texts("user_message_chunk")).toEqual(["Before the ACP kill.", "Held ACP question."]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the ACP kill.") });
    expect(gateway.requests.at(-1)!.body).toContain("ACP_BEFORE");
    expect(await client.close()).toBe(0);
    client = undefined;
    const lines = logLines(fixture, id);
    expect(lines.filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual(["crash"]);
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP saves a model change with the session and loads it back", async () => {
  const fixture = createFixture("fx-v2-acp-prefs-");
  const gateway = replyToLatest([["Pick a model.", "ACP_MODEL"]]);
  // A process-wide model would win over the saved one on load, as on v1.
  const noModel = { FX_MODEL: undefined };
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway, noModel);
    const created = await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] });
    const id = created.sessionId;
    const current = created.configOptions.find((option: any) => option.id === "model").currentValue;
    const other = "openai/gpt-5-mini";
    expect(other).not.toBe(current);
    const changed = await client.ok("session/set_config_option", { sessionId: id, configId: "model", value: other });
    expect(changed.configOptions.find((option: any) => option.id === "model").currentValue).toBe(other);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Pick a model.") });
    expect(gateway.requests.at(-1)!.headers.get("ai-language-model-id")).toBe(other);
    expect(await client.close()).toBe(0);

    client = await AcpRpc.start(fixture, gateway, noModel);
    const loaded = await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(loaded.configOptions.find((option: any) => option.id === "model").currentValue).toBe(other);
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(logLines(fixture, id).filter((line) => line.kind === "set" && line.key === "prefs").length).toBeGreaterThan(1);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP session/load with another cwd moves the session to that workspace", async () => {
  const fixture = createFixture("fx-v2-acp-cwd-");
  const elsewhere = join(fixture.root, "elsewhere");
  mkdirSync(elsewhere);
  const other = realpathSync(elsewhere);
  const gateway = replyToLatest([
    ["Start in the workspace.", "ACP_HERE"],
    ["Carry on elsewhere.", "ACP_THERE"],
  ]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Start in the workspace.") });
    expect(await client.close()).toBe(0);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: other, mcpServers: [] });
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Carry on elsewhere.") });
    expect(gateway.requests.at(-1)!.body).toContain("ACP_HERE");
    expect((await client.ok("session/list", { cwd: other })).sessions.map((s: any) => s.sessionId)).toEqual([id]);
    expect((await client.ok("session/list", { cwd: fixture.workspace })).sessions).toEqual([]);
    expect(await client.close()).toBe(0);
    client = undefined;
    const moves = logLines(fixture, id).filter((line) => line.kind === "set" && line.key === "workspace");
    expect(moves.map((line: any) => line.value)).toEqual([other]);
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP keeps a tool result as a blob, and load replays the call with its result", async () => {
  const fixture = createFixture("fx-v2-acp-tool-");
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("After the ACP tool.")) return fakeGatewayFinalText("ACP_AFTER_TOOL");
    if (body.includes("Run an ACP tool.") && body.includes("ACP_TOOL_OUTPUT_77")) return fakeGatewayFinalText("ACP_TOOL_DONE");
    if (body.includes("Run an ACP tool.")) return fakeShellRun("acp-tool-1", "echo ACP_TOOL_OUTPUT_77");
    return fakeGatewayFinalText("ACP_OTHER");
  });
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Run an ACP tool.") });
    // session/close ends the session; it stays saved.
    await client.ok("session/close", { sessionId: id });
    expect(await client.close()).toBe(0);
    expect(blobNames(fixture, id).length).toBeGreaterThan(0);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    const calls = client.updates.filter((u) => u.update?.sessionUpdate === "tool_call" && u.update.toolCallId === "acp-tool-1");
    expect(calls.length).toBe(1);
    const results = client.updates.filter((u) => u.update?.sessionUpdate === "tool_call_update" && u.update.toolCallId === "acp-tool-1");
    // The replay sends the stored preview, as on v1; the model gets the
    // whole output back from the blob (below).
    expect(results.length).toBe(1);
    expect(results[0].update.status).toBe("completed");
    expect(results[0].update.content[0].content.text.length).toBeGreaterThan(0);
    expect(client.texts("agent_message_chunk")).toEqual(["ACP_TOOL_DONE"]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the ACP tool.") });
    expect(gateway.requests.at(-1)!.body).toContain("ACP_TOOL_OUTPUT_77");
    expect(await client.close()).toBe(0);
    client = undefined;
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP lists more than a page of sessions with a cursor, newest first, each once", async () => {
  const fixture = createFixture("fx-v2-acp-page-");
  const gateway = startDynamicFakeGateway(async () => fakeGatewayFinalText("ACP_PAGE"));
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const created: string[] = [];
    for (let index = 0; index < 101; index += 1) {
      const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
      await client.ok("session/prompt", { sessionId: id, ...acpPrompt(`Page session ${index}.`) });
      created.push(id);
    }
    const first = await client.ok("session/list", {});
    expect(first.sessions.length).toBe(100);
    expect(typeof first.nextCursor).toBe("string");
    const second = await client.ok("session/list", { cursor: first.nextCursor });
    expect(second.nextCursor).toBeUndefined();
    const listed = [...first.sessions, ...second.sessions];
    expect(listed.map((s: any) => s.sessionId).sort()).toEqual([...created].sort());
    const times = listed.map((s: any) => Date.parse(s.updatedAt));
    for (let index = 1; index < times.length; index += 1) expect(times[index - 1]).toBeGreaterThanOrEqual(times[index]);
    const bad = await client.request("session/list", { cursor: "not-a-cursor" });
    expect(bad.error?.message).toBe("Invalid params");
    expect(await client.close()).toBe(0);
    client = undefined;
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// A catalog whose model can see images, so fx sends them to it as they are.
const VISION_MODEL: FakeGatewayOptions = {
  models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["vision", "file-input", "tool-use"] }],
};
const PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// A piece's data: fx's JSON, which the log keeps as a string.
function itemData(line: any): any {
  return typeof line.data === "string" ? JSON.parse(line.data) : line.data;
}

/// The images a session keeps inside its user items (D44), as the bytes
/// each decodes to.
function inlineImages(fixture: Fixture, id: string): Buffer[] {
  const found: Buffer[] = [];
  for (const line of logLines(fixture, id) as any[]) {
    if (line.kind !== "item" || line.type !== "user") continue;
    for (const image of itemData(line).images ?? []) {
      if (image.inline_data) found.push(Buffer.from(image.inline_data, "base64"));
    }
  }
  return found;
}

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

test("fx ask keeps an image inside its turn, and resume in a new process sends it again", async () => {
  const fixture = createFixture("fx-v2-image-");
  const gateway = replyToLatest([
    ["Describe the image.", "IMAGE_SEEN"],
    ["And again.", "IMAGE_AGAIN"],
  ], undefined, VISION_MODEL);
  try {
    const image = join(fixture.workspace, "dot.png");
    writeFileSync(image, Buffer.from(PNG_1X1, "base64"));
    const created = await ask(fixture, gateway, ["--image", image, "Describe the image."]);
    expect(created.code).toBe(0);
    expect(JSON.parse(created.stdout).output).toBe("IMAGE_SEEN");
    const id = JSON.parse(created.stdout).session_id;
    const images = inlineImages(fixture, id);
    expect(images.length).toBe(1);
    expect(images[0]!.subarray(0, 8).equals(PNG_SIGNATURE)).toBe(true);
    const resumed = await ask(fixture, gateway, ["--resume-id", id, "And again."]);
    expect(resumed.code).toBe(0);
    // The prompt text says "image" too, so match the part's media type.
    expect(gateway.requests[0]!.body).toContain("image/png");
    expect(gateway.requests.at(-1)!.body).toContain("image/png");
    expectWholeLog(fixture, id);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test("ACP keeps an image prompt and replays it with the image on load", async () => {
  const fixture = createFixture("fx-v2-acp-image-");
  const gateway = replyToLatest([["Describe this ACP image.", "ACP_IMAGE_SEEN"]], undefined, VISION_MODEL);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    const prompted = await client.ok("session/prompt", {
      sessionId: id,
      prompt: [
        { type: "text", text: "Describe this ACP image." },
        { type: "image", data: PNG_1X1, mimeType: "image/png" },
      ],
    });
    expect(prompted.stopReason).toBe("end_turn");
    expect(inlineImages(fixture, id).length).toBe(1);
    expect(await client.close()).toBe(0);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    const images = client.updates.filter((u) => u.update?.sessionUpdate === "user_message_chunk" && u.update.content?.type === "image");
    expect(images.length).toBe(1);
    expect(await client.close()).toBe(0);
    client = undefined;
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a second ACP process is refused an open v2 session, then loads it once the owner exits", async () => {
  const fixture = createFixture("fx-v2-acp-busy-");
  const gateway = replyToLatest([["Hold this session.", "ACP_OWNER"]]);
  let owner: AcpRpc | undefined;
  let other: AcpRpc | undefined;
  try {
    owner = await AcpRpc.start(fixture, gateway);
    const id = (await owner.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await owner.ok("session/prompt", { sessionId: id, ...acpPrompt("Hold this session.") });
    other = await AcpRpc.start(fixture, gateway);
    const refused = await other.request("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(refused.error?.message).toBe("Session is busy");
    expect(await owner.close()).toBe(0);
    owner = undefined;
    await other.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(other.texts("agent_message_chunk")).toEqual(["ACP_OWNER"]);
    expect(await other.close()).toBe(0);
    other = undefined;
    expectWholeLog(fixture, id);
  } finally {
    if (owner) await owner.kill();
    if (other) await other.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

function infoTitles(updates: any[]) {
  return updates.filter((u) => u.update?.sessionUpdate === "session_info_update").map((u) => u.update.title);
}

test("ACP keeps a generated title, and list and load show it after a restart", async () => {
  const fixture = createFixture("fx-v2-acp-title-");
  const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("ACP_TITLED_ANSWER"), {
    titleResponses: [fakeGatewayFinalText("ACP Generated Title")],
  });
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Name this conversation for me.") });
    expect(infoTitles(client.updates)).toContain("ACP Generated Title");
    expect(await client.close()).toBe(0);

    client = await AcpRpc.start(fixture, gateway);
    const listed = await client.ok("session/list", { cwd: fixture.workspace });
    expect(listed.sessions.map((s: any) => [s.sessionId, s.title])).toEqual([[id, "ACP Generated Title"]]);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(infoTitles(client.updates)).toEqual(["ACP Generated Title"]);
    expect(await client.close()).toBe(0);
    client = undefined;
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP lists by workspace: each cwd sees its own sessions, and no cwd sees all", async () => {
  const fixture = createFixture("fx-v2-acp-cwd-");
  const other = join(fixture.root, "other-workspace");
  mkdirSync(other);
  const otherRoot = realpathSync(other);
  const gateway = replyToLatest([
    ["First workspace prompt.", "FIRST_WORKSPACE"],
    ["Second workspace prompt.", "SECOND_WORKSPACE"],
  ]);
  let client: AcpRpc | undefined;
  try {
    // A session belongs to the workspace its ACP process runs in, as in v1.
    client = await AcpRpc.start(fixture, gateway);
    const first = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: first, ...acpPrompt("First workspace prompt.") });
    expect(await client.close()).toBe(0);
    client = await AcpRpc.start({ ...fixture, workspace: otherRoot }, gateway);
    const second = (await client.ok("session/new", { cwd: otherRoot, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: second, ...acpPrompt("Second workspace prompt.") });
    expect(await client.close()).toBe(0);

    client = await AcpRpc.start(fixture, gateway);
    const ids = async (params: object) => (await client!.ok("session/list", params)).sessions.map((s: any) => [s.sessionId, s.cwd]);
    expect(await ids({ cwd: fixture.workspace })).toEqual([[first, fixture.workspace]]);
    expect(await ids({ cwd: `${fixture.workspace}/` })).toEqual([[first, fixture.workspace]]);
    expect(await ids({ cwd: otherRoot })).toEqual([[second, otherRoot]]);
    expect(await ids({ cwd: join(fixture.root, "no-sessions-here") })).toEqual([]);
    expect((await ids({})).sort()).toEqual([[first, fixture.workspace], [second, otherRoot]].sort());
    expect(await client.close()).toBe(0);
    client = undefined;
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP load takes a special-token id literally and never loads the newest session", async () => {
  const fixture = createFixture("fx-v2-acp-literal-id-");
  const gateway = replyToLatest([["The only saved prompt.", "ONLY_SAVED_ANSWER"]]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("The only saved prompt.") });
    expect(await client.close()).toBe(0);
    const saved = readFileSync(join(v2Root(fixture), id, "log.jsonl"));

    client = await AcpRpc.start(fixture, gateway);
    for (const token of ["last", "last_opened", ".", "..", `../${id}`]) {
      const response = await client.request("session/load", { sessionId: token, cwd: fixture.workspace, mcpServers: [] });
      expect(response.error, token).toBeDefined();
    }
    expect(client.updates).toEqual([]);
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"))).toEqual(saved);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test.skipIf(!tmuxAvailable())("ACP load after a compaction shows every earlier turn and never the handoff", async () => {
  const fixture = createFixture("fx-v2-acp-compacted-");
  const gateway = startFakeGateway([
    fakeShellRun("saved-history-effect", "printf 'V2_SAVED_TOOL_OUTPUT\\n' >> replay-effects.txt; printf 'V2_SAVED_TOOL_OUTPUT\\n'"),
    fakeGatewayFinalText("V2_EARLIER_VISIBLE"),
    fakeGatewayFinalText("V2_MIDDLE_VISIBLE"),
    fakeGatewayFinalText("V2_LATEST_VISIBLE"),
    fakeGatewayFinalText("V2_INTERNAL_HANDOFF: continue the task."),
  ]);
  let client: AcpRpc | undefined;
  try {
    const app = await startApp(fixture, gateway, []);
    for (const [prompt, answer] of [
      ["Earlier v2 request", "V2_EARLIER_VISIBLE"],
      ["Middle v2 request", "V2_MIDDLE_VISIBLE"],
      ["Latest v2 request", "V2_LATEST_VISIBLE"],
    ]) {
      await app.session.sendText(prompt!);
      await scrollbackContains(app.session, answer!);
      await app.session.waitForComposer(TIMEOUT);
    }
    const id = onlySession(fixture);
    await app.session.sendText("/compact");
    await waitForLog(fixture, id, "V2_INTERNAL_HANDOFF", TIMEOUT);
    await app.session.waitForComposer(TIMEOUT);
    await quitApp(app);
    const saved = readFileSync(join(v2Root(fixture), id, "log.jsonl"));
    expect(gateway.requests).toHaveLength(5);

    client = await AcpRpc.start(fixture, gateway);
    for (let load = 0; load < 2; load += 1) {
      client.updates.length = 0;
      await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
      const visible = JSON.stringify(client.updates);
      expect(infoTitles(client.updates)).toEqual(["Earlier v2 request"]);
      expect(client.texts("user_message_chunk")).toEqual(["Earlier v2 request", "Middle v2 request", "Latest v2 request"]);
      expect(visible).toContain("V2_SAVED_TOOL_OUTPUT");
      expect(visible).not.toContain("V2_INTERNAL_HANDOFF");
      const order = ["V2_EARLIER_VISIBLE", "V2_MIDDLE_VISIBLE", "V2_LATEST_VISIBLE"].map((text) => visible.indexOf(text));
      expect(order.every((at) => at >= 0)).toBe(true);
      expect(order).toEqual([...order].sort((a, b) => a - b));
    }
    expect(await client.close()).toBe(0);
    client = undefined;
    const after = readFileSync(join(v2Root(fixture), id, "log.jsonl"));
    // Load adds no history: its writable open ends with the clean-exit
    // marker every close appends.
    expect(after.subarray(0, saved.length)).toEqual(saved);
    const appended = after.subarray(saved.length).toString("utf8").split("\n").filter(Boolean);
    expect(appended.map((line) => JSON.parse(line).kind)).toEqual(["closed"]);
    expect(readFileSync(join(fixture.workspace, "replay-effects.txt"), "utf8")).toBe("V2_SAVED_TOOL_OUTPUT\n");
    expect(gateway.requests).toHaveLength(5);
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// The parent's lines about its children, with fx's data parsed.
function childLines(fixture: Fixture, id: string): any[] {
  return (logLines(fixture, id) as any[])
    .filter((line) => line.kind === "child_spawned" || line.kind === "child_finished")
    .map((line) => ({ ...line, data: typeof line.data === "string" ? JSON.parse(line.data) : line.data }));
}

/// A child's requests never offer the subagent tool, so they tell apart.
const isChildRequest = (body: string) => !body.includes('"name":"subagent"');

test("fx ask runs a one-off subagent as a v2 child with its own log, recorded in the parent's log", async () => {
  const fixture = createFixture("fx-v2-subagent-run-");
  const gateway = startDynamicFakeGateway((body) => {
    if (isChildRequest(body)) return fakeGatewayFinalText("CHILD_ANSWER_5521");
    if (body.includes("CHILD_ANSWER_5521")) return fakeGatewayFinalText("PARENT_DONE");
    return fakeGatewayToolCall("delegate-run", "subagent", { request: { action: "run", task: "Report the child marker." } });
  }, { classifierDecision: "clear" });
  try {
    // A subagent run prints its progress on stderr.
    const result = await ask(fixture, gateway, ["Delegate the marker report."]);
    expect(result.code).toBe(0);
    expect(result.stderr).not.toContain("panic");
    const output = JSON.parse(result.stdout);
    expect(output.output).toBe("PARENT_DONE");
    const id = output.session_id;
    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([["child_spawned", null], ["child_finished", "ok"]]);
    const childId = lines[0].child;
    expect(lines[1].child).toBe(childId);
    expect(lines[1].work_id).toBe(lines[0].work_id);
    expect(lines[0].data.agent ?? null).toBe(null);
    expect(lines[0].data.fingerprint).toMatch(/^[0-9a-f]{64}$/);

    // The child's own log names its parent and holds its answer.
    const child = logLines(fixture, childId) as any[];
    expect(child[0].kind).toBe("session_created");
    expect(child[0].role).toBe("child");
    expect(child[0].parent).toBe(id);
    expect(JSON.stringify(child)).toContain("CHILD_ANSWER_5521");
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
    // No v1 subagent files and no side folder: the parent's log is the
    // record (D22, D48).
    expectNoV1Sessions(fixture);
    // A child is reached only through its parent: never listed, read or recovered.
    const listed = JSON.parse((await command(fixture, gateway, ["sessions", "--all", "--json"])).stdout);
    expect(listed.sessions.map((summary: any) => summary.id)).toEqual([id]);
    for (const args of [["session", childId, "--json"], ["session", "recover", childId, "--json"]]) {
      const direct = await command(fixture, gateway, args);
      expect(direct.code).toBe(1);
      expect(JSON.parse(direct.stdout).code).toBe("SessionNotFound");
    }
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test("a named subagent keeps its id, history and instructions across fx ask runs", async () => {
  const fixture = createFixture("fx-v2-subagent-named-");
  const childBodies: string[] = [];
  let parentRequests = 0;
  const gateway = startDynamicFakeGateway((body) => {
    if (isChildRequest(body)) {
      childBodies.push(body);
      return fakeGatewayFinalText(childBodies.length === 1 ? "REVIEW_ONE" : "REVIEW_TWO");
    }
    parentRequests += 1;
    switch (parentRequests) {
      case 1:
        return fakeGatewayToolCall("delegate-one", "subagent", { request: { action: "message", agent: "reviewer", message: "Review round one.", instructions: "Follow REVIEWER_RULES." } });
      case 3:
        return fakeGatewayToolCall("delegate-two", "subagent", { request: { action: "message", agent: "reviewer", message: "Review round two." } });
      default:
        return fakeGatewayFinalText(parentRequests === 2 ? "FIRST_DONE" : "SECOND_DONE");
    }
  }, { classifierDecision: "clear" });
  try {
    const first = await ask(fixture, gateway, ["First review."]);
    expect(first.code).toBe(0);
    expect(JSON.parse(first.stdout).output).toBe("FIRST_DONE");
    const id = JSON.parse(first.stdout).session_id;
    const second = await ask(fixture, gateway, ["--resume-id", id, "Second review."]);
    expect(second.code).toBe(0);
    expect(second.stderr).not.toContain("panic");
    expect(JSON.parse(second.stdout).output).toBe("SECOND_DONE");

    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([
      ["child_spawned", null], ["child_finished", "ok"], ["child_spawned", null], ["child_finished", "ok"],
    ]);
    expect(new Set(lines.map((line) => line.child)).size).toBe(1);
    expect(lines[0].data.agent).toBe("reviewer");
    expect(lines[2].data.agent).toBe("reviewer");
    expect(lines[2].work_id).not.toBe(lines[0].work_id);

    // The second round continues the same child: its first turn and its
    // instructions, kept in the child's own prefs (D34), reach the model.
    expect(childBodies).toHaveLength(2);
    expect(childBodies[0]).toContain("REVIEWER_RULES");
    expect(childBodies[1]).toContain("REVIEWER_RULES");
    expect(childBodies[1]).toContain("Review round one.");
    expect(childBodies[1]).toContain("REVIEW_ONE");
    const childId = lines[0].child;
    const child = logLines(fixture, childId);
    expect(shape(child).filter((kind) => kind === "turn_committed").length).toBe(2);
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a crash while a named subagent works records it interrupted, and its next message runs under its id with nothing of the lost work", async () => {
  const fixture = createFixture("fx-v2-subagent-lost-");
  let held: () => void = () => {};
  const childHeld = new Promise<void>((resolve) => (held = resolve));
  let phase: "crash" | "again" = "crash";
  const gateway = startDynamicFakeGateway(async (body) => {
    if (isChildRequest(body)) {
      if (phase === "crash") {
        held();
        return new Promise<Response>(() => {});
      }
      return fakeGatewayFinalText("FRESH_CHILD_ANSWER");
    }
    if (body.includes("FRESH_CHILD_ANSWER")) return fakeGatewayFinalText("AFTER_LOST_DONE");
    return fakeGatewayToolCall(phase === "crash" ? "delegate-lost" : "delegate-again", "subagent", {
      request: { action: "message", agent: "worker", message: phase === "crash" ? "Start the long job." : "Start it again." },
    });
  }, { classifierDecision: "clear" });
  try {
    const { child, exited } = spawnAsk(fixture, gateway, ["Delegate the long job."]);
    await childHeld;
    // The child's turn opened on disk as its work started (D44), so the
    // child has a log beside its parent's.
    const roots = rootSessions(fixture);
    expect(roots).toHaveLength(1);
    const id = roots[0]!;
    await waitForLog(fixture, id, "child_spawned");
    child.kill("SIGKILL");
    await exited;

    phase = "again";
    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Try the job again."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).not.toContain("panic");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_LOST_DONE");

    // The reopen recorded the started work as interrupted, as
    // `tla/Subagents.tla` repairs a child with a log; the next message is new
    // work for the same child. A child streams no pieces, so its log holds
    // nothing of the lost work.
    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([
      ["child_spawned", null], ["child_finished", "interrupted"], ["child_spawned", null], ["child_finished", "ok"],
    ]);
    expect(new Set(lines.map((line) => line.child)).size).toBe(1);
    expect(lines[2].work_id).not.toBe(lines[0].work_id);
    const childId = lines[0].child;
    const childLog = JSON.stringify(logLines(fixture, childId));
    expect(childLog).toContain("Start it again.");
    expect(childLog).not.toContain("Start the long job.");
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

/// Saved root sessions: a child's folder sits beside its parent's.
function rootSessions(fixture: Fixture): string[] {
  return savedSessions(fixture).filter((id) => (logLines(fixture, id)[0] as any).role !== "child");
}

test.skipIf(!tmuxAvailable())("the interactive app runs a subagent on v2 and records it in the session's log", async () => {
  const fixture = createFixture("fx-v2-app-subagent-");
  const gateway = startDynamicFakeGateway((body) => {
    if (isChildRequest(body)) return fakeGatewayFinalText("APP_CHILD_ANSWER");
    if (body.includes("APP_CHILD_ANSWER")) return fakeGatewayFinalText("APP_PARENT_DONE");
    return fakeGatewayToolCall("app-delegate", "subagent", { request: { action: "run", task: "Report from the app child." } });
  }, { classifierDecision: "clear" });
  try {
    const app = await startApp(fixture, gateway, [], true, { FX_PERMISSION_MODE: "auto" });
    await app.session.sendText("Delegate from the app.");
    await scrollbackContains(app.session, "APP_PARENT_DONE");
    await app.session.waitForComposer(TIMEOUT);
    await quitApp(app);

    const roots = rootSessions(fixture);
    expect(roots).toHaveLength(1);
    const id = roots[0]!;
    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([["child_spawned", null], ["child_finished", "ok"]]);
    const childId = lines[0].child;
    const child = logLines(fixture, childId) as any[];
    expect(child[0].role).toBe("child");
    expect(child[0].parent).toBe(id);
    expect(JSON.stringify(child)).toContain("APP_CHILD_ANSWER");
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP runs a subagent on v2, and load replays the delegation", async () => {
  const fixture = createFixture("fx-v2-acp-subagent-");
  const gateway = startDynamicFakeGateway((body) => {
    if (isChildRequest(body)) return fakeGatewayFinalText("ACP_CHILD_ANSWER");
    if (body.includes("ACP_CHILD_ANSWER")) return fakeGatewayFinalText("ACP_PARENT_DONE");
    return fakeGatewayToolCall("acp-delegate", "subagent", { request: { action: "run", task: "Report from the ACP child." } });
  }, { classifierDecision: "clear" });
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    const prompted = await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Delegate over ACP.") });
    expect(prompted.stopReason).toBe("end_turn");
    expect(client.texts("agent_message_chunk")).toContain("ACP_PARENT_DONE");
    expect(await client.close()).toBe(0);

    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([["child_spawned", null], ["child_finished", "ok"]]);
    const childId = lines[0].child;
    expect((logLines(fixture, childId)[0] as any).parent).toBe(id);
    expect(rootSessions(fixture)).toEqual([id]);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    const replay = JSON.stringify(client.updates);
    expect(replay).toContain("ACP_CHILD_ANSWER");
    expect(client.texts("agent_message_chunk")).toEqual(["ACP_PARENT_DONE"]);
    // Children stay out of the list.
    const listed = await client.ok("session/list", { cwd: fixture.workspace });
    expect(listed.sessions.map((s: any) => s.sessionId)).toEqual([id]);
    expect(await client.close()).toBe(0);
    client = undefined;
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

// -- fx sessions, fx session and doctor ----------------------------------------

/// Every file under `dir`, as paths relative to it with their modes.
function treeOf(dir: string, prefix = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    const name = prefix + entry.name;
    const mode = (statSync(path).mode & 0o777).toString(8);
    return entry.isDirectory() ? [`${name}/ ${mode}`, ...treeOf(path, `${name}/`)] : [`${name} ${mode}`];
  }).sort();
}

test("fx sessions and fx session show v2 sessions by workspace, page them, and v1 sees none", async () => {
  const fixture = createFixture("fx-v2-commands-");
  mkdirSync(join(fixture.root, "other"));
  const other = realpathSync(join(fixture.root, "other"));
  const gateway = startFakeGateway([
    fakeGatewayFinalText("LIST_A1"),
    fakeGatewayFinalText("LIST_A2"),
    fakeGatewayFinalText("LIST_B1"),
    fakeGatewayFinalText("LIST_C1"),
  ]);
  try {
    const a = JSON.parse((await ask(fixture, gateway, ["List question A."])).stdout).session_id;
    expect((await ask(fixture, gateway, ["--resume-id", a, "List question A two."])).code).toBe(0);
    const inOther = await runFx(["ask", "--json", "--auto", "List question B."], { cwd: other, env: env(fixture, gateway), timeoutMs: TIMEOUT });
    const b = JSON.parse(inOther.stdout).session_id;
    const c = JSON.parse((await ask(fixture, gateway, ["List question C."])).stdout).session_id;
    const ids = (listed: any) => listed.sessions.map((summary: any) => summary.id);

    const here = await command(fixture, gateway, ["sessions", "--json"]);
    expect(here.code).toBe(0);
    expect(here.stderr).toBe("");
    const listed = JSON.parse(here.stdout);
    expect(ids(listed)).toEqual([c, a]);
    expect(listed.sessions[1].title).toBe("List question A.");
    expect(listed.sessions[1].history_len).toBe(2);
    expect(listed.sessions[1].workspace_root).toBe(fixture.workspace);
    expect(ids(JSON.parse((await command(fixture, gateway, ["sessions", "--json"], true, other)).stdout))).toEqual([b]);
    expect(ids(JSON.parse((await command(fixture, gateway, ["sessions", "--all", "--json"])).stdout))).toEqual([c, b, a]);
    const text = await command(fixture, gateway, ["sessions"]);
    expect(text.code).toBe(0);
    expect(text.stdout).toContain(a);
    expect(text.stdout).toContain("List question A.");

    // A page at a time, each session once, newest first.
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 3; page += 1) {
      const args = ["sessions", "--all", "--limit", "1", "--json", ...(cursor ? ["--cursor", cursor] : [])];
      const result = JSON.parse((await command(fixture, gateway, args)).stdout);
      seen.push(...ids(result));
      cursor = result.next_cursor ?? undefined;
    }
    expect(seen).toEqual([c, b, a]);
    expect(cursor).toBeUndefined();

    const last = await command(fixture, gateway, ["session", "last", "--json"]);
    expect(last.code).toBe(0);
    expect(JSON.parse(last.stdout).id).toBe(c);
    expect(JSON.parse((await command(fixture, gateway, ["session", "last", "--json"], true, other)).stdout).id).toBe(b);

    const detail = await command(fixture, gateway, ["session", a, "--json"]);
    expect(detail.code).toBe(0);
    expect(detail.stderr).toBe("");
    const shown = JSON.parse(detail.stdout);
    expect(shown.kind).toBe("session_detail");
    expect(shown.id).toBe(a);
    expect(shown.history_len).toBe(2);
    expect(shown.history.map((turn: any) => [turn.user.text, turn.assistant])).toEqual([
      ["List question A.", "LIST_A1"],
      ["List question A two.", "LIST_A2"],
    ]);
    const detailText = await command(fixture, gateway, ["session", a]);
    expect(detailText.stdout).toContain(`[session] ${a}`);
    expect(detailText.stdout).toContain("List question A two.");

    const missing = await command(fixture, gateway, ["session", "NoSuchSession1", "--json"]);
    expect(missing.code).toBe(1);
    expect(JSON.parse(missing.stdout).code).toBe("SessionNotFound");

    // A v1 process reads only v1 sessions, and there are none.
    const v1 = JSON.parse((await command(fixture, gateway, ["sessions", "--all", "--json"], false)).stdout);
    expect(v1.sessions).toEqual([]);
    expect((await command(fixture, gateway, ["session", a, "--json"], false)).code).toBe(1);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// Waits until some file under `dir` contains `needle`, on either store.
async function waitForSavedText(dir: string, needle: string, timeoutMs = TIMEOUT) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const files = existsSync(dir) ? (readdirSync(dir, { recursive: true }) as string[]) : [];
    for (const name of files) {
      const path = join(dir, name);
      if (statSync(path).isFile() && readFileSync(path, "utf8").includes(needle)) return;
    }
    await Bun.sleep(50);
  }
  throw new Error(`no saved file ever contained ${needle}`);
}

test.skipIf(!tmuxAvailable())("fx session lists a compacted session's every turn and summary as v1 does", async () => {
  // The same turns and `/compact` on each store, then `fx session {id}`.
  const shapes: Record<string, unknown[]> = {};
  for (const v2 of [false, true]) {
    const fixture = createFixture(v2 ? "fx-v2-detail-compacted-" : "fx-v1-detail-compacted-");
    // Plain turns have nothing to note, so `/compact` needs no model call.
    const gateway = startFakeGateway([
      fakeGatewayFinalText("DETAIL_EARLIER"),
      fakeGatewayFinalText("DETAIL_MIDDLE"),
      fakeGatewayFinalText("DETAIL_LATEST"),
      fakeGatewayFinalText("DETAIL_AFTER"),
    ]);
    let session: TmuxSession | undefined;
    try {
      const stderrPath = join(fixture.root, "stderr.log");
      writeFileSync(stderrPath, "");
      session = await TmuxSession.create({
        cmd: v2 ? `${FX_BIN} --sessions-v2` : FX_BIN,
        cwd: fixture.workspace,
        env: { ...env(fixture, gateway, false), NO_COLOR: "1" },
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      const turns = [
        ["Earlier detail request", "DETAIL_EARLIER"],
        ["Middle detail request", "DETAIL_MIDDLE"],
        ["Latest detail request", "DETAIL_LATEST"],
      ];
      for (const [prompt, answer] of turns) {
        await session.sendText(prompt!);
        await scrollbackContains(session, answer!);
        await session.waitForComposer(TIMEOUT);
      }
      await session.sendText("/compact");
      await waitForSavedText(join(fixture.home, ".fx", "sessions"), "fx-compactor-v1");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("After detail request");
      await scrollbackContains(session, "DETAIL_AFTER");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const last = await command(fixture, gateway, ["session", "last", "--json"], v2);
      expect(last.code).toBe(0);
      const id = JSON.parse(last.stdout).id;
      const detail = await command(fixture, gateway, ["session", id, "--json"], v2);
      expect(detail.code).toBe(0);
      expect(detail.stderr).toBe("");
      const shown = JSON.parse(detail.stdout);
      expect(shown.history_len).toBe(shown.history.length);
      // The summary's text carries fx's own handles, so only its marker counts.
      shapes[v2 ? "v2" : "v1"] = shown.history.map((entry: any) =>
        entry.kind === "compacted_summary"
          ? ["summary", String(entry.summary).startsWith("fx-compactor-v1\n"), entry.removed_turn_count, entry.compaction_count]
          : [entry.kind, entry.user?.text, entry.assistant],
      );
      if (v2) {
        const text = await command(fixture, gateway, ["session", id], true);
        expect(text.stdout).toContain("Earlier detail request");
        expect(text.stdout).toContain("[compacted] removed_turns=3 compactions=1");
        expectWholeLog(fixture, id);
      }
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }
  expect(shapes.v2).toEqual([
    ["assistant", "Earlier detail request", "DETAIL_EARLIER"],
    ["assistant", "Middle detail request", "DETAIL_MIDDLE"],
    ["assistant", "Latest detail request", "DETAIL_LATEST"],
    ["summary", true, 3, 1],
    ["assistant", "After detail request", "DETAIL_AFTER"],
  ]);
  expect(shapes.v2).toEqual(shapes.v1);
}, TIMEOUT * 8);

test("fx session reads a session another process holds, and reads past a torn tail without cutting it", async () => {
  const fixture = createFixture("fx-v2-peek-");
  let stalled: () => void = () => {};
  const reachedStall = new Promise<void>((resolve) => (stalled = resolve));
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("Hold the session for reading.")) {
      stalled();
      return new Promise<Response>(() => {});
    }
    return fakeGatewayFinalText("BEFORE_THE_HOLD");
  });
  try {
    const id = JSON.parse((await ask(fixture, gateway, ["Before the held read."])).stdout).session_id;
    const holder = spawnAsk(fixture, gateway, ["--resume-id", id, "Hold the session for reading."]);
    await reachedStall;
    const path = join(v2Root(fixture), id, "log.jsonl");
    const held = readFileSync(path);
    const read = await command(fixture, gateway, ["session", id, "--json"]);
    expect(read.code).toBe(0);
    expect(read.stderr).toBe("");
    expect(JSON.parse(read.stdout).history[0].user.text).toBe("Before the held read.");
    expect(JSON.parse((await command(fixture, gateway, ["sessions", "--json"])).stdout).sessions.map((summary: any) => summary.id)).toEqual([id]);
    // Reading took no lock and wrote nothing.
    expect(readFileSync(path)).toEqual(held);
    holder.child.kill("SIGKILL");
    await holder.exited;

    appendFileSync(path, '{"v":1,"seq":99,"ts":1,"kind":"item","ty');
    const torn = readFileSync(path);
    const past = await command(fixture, gateway, ["session", id, "--json"]);
    expect(past.code).toBe(0);
    expect(JSON.parse(past.stdout).history[0].assistant).toBe("BEFORE_THE_HOLD");
    // Only a writer cuts a torn tail.
    expect(readFileSync(path)).toEqual(torn);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("fx session recover copies the good turns and side files of a damaged session, which stays as it was", async () => {
  const fixture = createFixture("fx-v2-recover-");
  const gateway = startFakeGateway([
    fakeShellRun("recover-shell", "echo RECOVER_TOOL_OUTPUT_4410"),
    fakeGatewayFinalText("RECOVER_ONE"),
    fakeGatewayFinalText("RECOVER_TWO"),
    fakeGatewayFinalText("RECOVER_THREE"),
    fakeGatewayFinalText("RECOVER_LOST"),
    fakeGatewayFinalText("RECOVER_AFTER"),
  ]);
  try {
    const id = JSON.parse((await ask(fixture, gateway, ["Recover question one."])).stdout).session_id;
    expect((await ask(fixture, gateway, ["--resume-id", id, "Recover question two."])).code).toBe(0);
    expect((await ask(fixture, gateway, ["--resume-id", id, "Recover question three."])).code).toBe(0);
    const path = join(v2Root(fixture), id, "log.jsonl");
    writeFileSync(path, readFileSync(path, "utf8").replace("Recover question three.", "Recover question thr3e."));
    const damaged = readFileSync(path);

    const result = await command(fixture, gateway, ["session", "recover", id, "--json"]);
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    const recovered = JSON.parse(result.stdout);
    expect(recovered).toMatchObject({ kind: "session_recovery", source_id: id, status: "recovered", history_turns: 2 });
    const copy: string = recovered.recovered_id;
    expect(copy).not.toBe(id);
    expect(readFileSync(path)).toEqual(damaged);
    expectWholeLog(fixture, copy);
    // The copy holds the source's blobs, still read-only, and no side folder.
    expect(blobNames(fixture, copy).length).toBeGreaterThan(0);
    for (const name of blobNames(fixture, copy)) expect(blobNames(fixture, id)).toContain(name);
    expectNoV1Sessions(fixture);

    // The tool output shows only if the copy has its blob.
    const shown = await command(fixture, gateway, ["session", copy, "--json"]);
    expect(shown.code).toBe(0);
    expect(JSON.parse(shown.stdout).history_len).toBe(2);
    expect(shown.stdout).toContain("RECOVER_TOOL_OUTPUT_4410");
    const resumed = await ask(fixture, gateway, ["--resume-id", copy, "After the recovery."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("RECOVER_LOST");
    const sent = gateway.requests.at(-1)!.body;
    expect(sent).toContain("RECOVER_TOOL_OUTPUT_4410");
    expect(sent).toContain("RECOVER_TWO");
    expect(sent).not.toContain("RECOVER_THREE");
    expect(sent).not.toContain("thr3e");

    // A session whose first turn is damaged has nothing to copy.
    const lone = JSON.parse((await ask(fixture, gateway, ["Lone question."])).stdout).session_id;
    const lonePath = join(v2Root(fixture), lone, "log.jsonl");
    writeFileSync(lonePath, readFileSync(lonePath, "utf8").replace("Lone question.", "L0ne question."));
    const count = JSON.parse((await command(fixture, gateway, ["sessions", "--all", "--json"])).stdout).count;
    const nothing = await command(fixture, gateway, ["session", "recover", lone, "--json"]);
    expect(nothing.code).toBe(1);
    expect(JSON.parse(nothing.stdout).code).toBe("SessionRecoveryBoundaryInvalid");
    const text = await command(fixture, gateway, ["session", "recover", lone]);
    expect(text.stderr).toContain("the source was left unchanged");
    expect(JSON.parse((await command(fixture, gateway, ["sessions", "--all", "--json"])).stdout).count).toBe(count);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test("an older session moves off its side folder on its next open, and the model still reads an old handle (D47)", async () => {
  const fixture = createFixture("fx-v2-move-");
  const oldHandle = "result-shell-0011223344556677-8899aabbccddeeff.txt";
  const gateway = startFakeGateway([
    fakeGatewayFinalText("MOVE_FIRST"),
    fakeGatewayToolCall("move-read-1", "read_tool_result", { handle: oldHandle }),
    fakeGatewayFinalText("MOVE_READ_DONE"),
    fakeGatewayFinalText("MOVE_AGAIN"),
  ]);
  try {
    const created = await ask(fixture, gateway, ["First, before the move."]);
    expect(created.code).toBe(0);
    const id = JSON.parse(created.stdout).session_id;
    // An older fx kept bodies and terminal state beside the log (D27).
    const files = join(fixture.home, ".fx", "session-files");
    const side = join(files, id);
    mkdirSync(join(side, "tool-results"), { recursive: true, mode: 0o700 });
    writeFileSync(join(side, "tool-results", oldHandle), "MOVED_OLD_BODY_3301", { mode: 0o600 });
    mkdirSync(join(side, "terminal", "state"), { recursive: true, mode: 0o700 });
    writeFileSync(join(side, "terminal", "state", "note.json"), "{}", { mode: 0o600 });

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Read the old result."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("MOVE_READ_DONE");
    // The old name resolved through the map to the moved body.
    expect(gateway.requests.at(-1)!.body).toContain("MOVED_OLD_BODY_3301");
    expect(existsSync(side)).toBe(false);
    expect(readdirSync(files)).toEqual([]);
    expect(existsSync(join(fixture.home, ".fx", "terminal", id, "terminal", "state", "note.json"))).toBe(true);
    const moved = logLines(fixture, id).filter((line) => line.kind === "set" && line.key === "moved_files");
    expect(moved).toHaveLength(1);
    expect(blobNames(fixture, id).length).toBeGreaterThanOrEqual(2);
    expectWholeLog(fixture, id);

    // Opened again, nothing moves twice.
    const again = await ask(fixture, gateway, ["--resume-id", id, "Once more."]);
    expect(again.code).toBe(0);
    expect(logLines(fixture, id).filter((line) => line.kind === "set" && line.key === "moved_files")).toHaveLength(1);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("fx session migrate refuses on v2 and changes nothing", async () => {
  const fixture = createFixture("fx-v2-migrate-");
  const gateway = startFakeGateway([fakeGatewayFinalText("MIGRATE_ANSWER")]);
  try {
    const id = JSON.parse((await ask(fixture, gateway, ["Migrate question."])).stdout).session_id;
    const before = readFileSync(join(v2Root(fixture), id, "log.jsonl"));
    const refused = await command(fixture, gateway, ["session", "migrate", id, "--json"]);
    expect(refused.code).toBe(1);
    expect(JSON.parse(refused.stdout).code).toBe("SessionMigrationUnavailable");
    const text = await command(fixture, gateway, ["session", "migrate", id]);
    expect(text.code).toBe(1);
    expect(text.stderr).toBe("fx session: session migrate converts v1 sessions and is not available with sessions v2 yet\n");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"))).toEqual(before);
    expectNoV1Sessions(fixture);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test("doctor on v2 reports a damaged session and removes only old terminal and side folders with no session", async () => {
  const fixture = createFixture("fx-v2-doctor-");
  const gateway = startFakeGateway([
    fakeShellRun("doctor-shell", "echo DOCTOR_TOOL_OUTPUT"),
    fakeGatewayFinalText("DOCTOR_ONE"),
    fakeGatewayFinalText("DOCTOR_TWO"),
  ]);
  try {
    const kept = JSON.parse((await ask(fixture, gateway, ["Doctor question one."])).stdout).session_id;
    const damaged = JSON.parse((await ask(fixture, gateway, ["Doctor question two."])).stdout).session_id;
    const path = join(v2Root(fixture), damaged, "log.jsonl");
    writeFileSync(path, readFileSync(path, "utf8").replace("Doctor question two.", "Doctor question tw0."));
    const before = readFileSync(path);
    // A side folder an older fx left (D48), and terminal folders (D45).
    const files = join(fixture.home, ".fx", "session-files");
    const terminals = join(fixture.home, ".fx", "terminal");
    const old = join(files, "OldOrphan0001");
    const young = join(files, "NewOrphan0002");
    const oldTerminal = join(terminals, "OldOrphan0003");
    const keptTerminal = join(terminals, kept);
    for (const dir of [old, young, oldTerminal, keptTerminal]) mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(old, "left.txt"), "left", { mode: 0o600 });
    const twoDaysAgo = (Date.now() - 2 * 24 * 3600 * 1000) / 1000;
    utimesSync(old, twoDaysAgo, twoDaysAgo);
    utimesSync(oldTerminal, twoDaysAgo, twoDaysAgo);
    // An old folder whose session exists is never an orphan.
    utimesSync(keptTerminal, twoDaysAgo, twoDaysAgo);

    const result = await command(fixture, gateway, ["doctor", "--json"]);
    expect(result.code).toBe(0);
    const checks: any[] = JSON.parse(result.stdout).checks;
    const named = (name: string) => checks.filter((check) => check.name === name).map((check) => `${check.status}: ${check.detail}`);
    expect(named("state")).toEqual(["ok: sessions v2"]);
    expect(named("session")).toEqual([
      `warn: session ${damaged} has a damaged log; \`fx session recover ${damaged}\` copies its good turns`,
      "ok: removed 2 terminal or side folder(s) whose session is gone",
    ]);
    expect(named("sessions")).toEqual([`ok: 2 saved session(s); latest=${damaged}`]);
    expect(existsSync(old)).toBe(false);
    expect(existsSync(oldTerminal)).toBe(false);
    expect(existsSync(young)).toBe(true);
    expect(existsSync(keptTerminal)).toBe(true);
    // Doctor reports damage and repairs nothing.
    expect(readFileSync(path)).toEqual(before);
    const again = JSON.parse((await command(fixture, gateway, ["doctor", "--json"])).stdout).checks;
    expect(again.filter((check: any) => check.detail.includes("removed"))).toEqual([]);

    // v1's doctor on the same profile sees no v2 folder as a session.
    const v1 = await command(fixture, gateway, ["doctor", "--json"], false);
    expect(v1.code).toBe(0);
    const v1Checks: any[] = JSON.parse(v1.stdout).checks;
    expect(v1Checks.filter((check) => check.status === "fail" || check.name === "session")).toEqual([]);
    expect(v1Checks.find((check) => check.name === "sessions").detail).toBe("no saved sessions yet");
    expect(JSON.stringify(v1Checks)).not.toContain("sessions/v2");
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("doctor reports a session whose blob went missing, and recover copies the turns before it", async () => {
  const fixture = createFixture("fx-v2-lost-blob-recover-");
  const big = "RECOVER_BLOB_START " + "blob-body ".repeat(30_000) + "RECOVER_BLOB_END";
  const gateway = startFakeGateway([
    fakeGatewayFinalText("RECOVER_TURN_ONE"),
    fakeGatewayFinalText(big),
    fakeGatewayFinalText("RECOVER_TURN_THREE"),
    fakeGatewayFinalText("AFTER_RECOVER"),
  ]);
  try {
    const id = JSON.parse((await ask(fixture, gateway, ["Recover question one."])).stdout).session_id;
    expect((await ask(fixture, gateway, ["--resume-id", id, "Recover question two."])).code).toBe(0);
    expect((await ask(fixture, gateway, ["--resume-id", id, "Recover question three."])).code).toBe(0);
    const referenced = (logLines(fixture, id) as any[]).find((line) => Array.isArray(line.blobs) && line.blobs.length === 1);
    rmSync(join(v2Root(fixture), id, "blobs", referenced.blobs[0]));
    const logPath = join(v2Root(fixture), id, "log.jsonl");
    const before = readFileSync(logPath);

    // The log is intact, but a turn it holds is not: doctor says so.
    const checks = JSON.parse((await command(fixture, gateway, ["doctor", "--json"])).stdout).checks;
    expect(checks.filter((check: any) => check.name === "session").map((check: any) => `${check.status}: ${check.detail}`)).toEqual([
      `warn: session ${id} has a damaged log; \`fx session recover ${id}\` copies its good turns`,
    ]);

    // Recover keeps the turn before the one whose blob is gone.
    const result = await command(fixture, gateway, ["session", "recover", id, "--json"]);
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    const recovered = JSON.parse(result.stdout);
    expect(recovered).toMatchObject({ kind: "session_recovery", source_id: id, status: "recovered", history_turns: 1 });
    const copy: string = recovered.recovered_id;
    const resumed = await ask(fixture, gateway, ["--resume-id", copy, "Continue in the copy."]);
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_RECOVER");
    const last = gateway.requests.at(-1)!.body;
    expect(last).toContain("RECOVER_TURN_ONE");
    expect(last).not.toContain("RECOVER_BLOB_END");
    expect(last).not.toContain("RECOVER_TURN_THREE");
    expect(readFileSync(logPath)).toEqual(before);
    expectWholeLog(fixture, copy);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

// ---------------------------------------------------------------------------
// Flows v1's suites check only through v1 files: a blob-sized piece, a
// compacted app session, steering and cancelling an app turn.

test("fx ask keeps a piece over 256 KB as a blob, and resume sends it whole", async () => {
  const fixture = createFixture("fx-v2-blob-");
  const big = "BLOB_PIECE_START " + "blob-body ".repeat(30_000) + "BLOB_PIECE_END";
  const gateway = startFakeGateway([fakeGatewayFinalText(big), fakeGatewayFinalText("AFTER_BLOB_RESUME")]);
  try {
    const created = await ask(fixture, gateway, ["Answer at great length."]);
    expect(created.code).toBe(0);
    expect(created.stderr).toBe("");
    const id = JSON.parse(created.stdout).session_id;
    const lines = logLines(fixture, id) as any[];
    const referenced = lines.filter((line) => Array.isArray(line.blobs) && line.blobs.length > 0);
    expect(referenced).toHaveLength(1);
    // The log line holds only the reference; the body is the blob.
    expect(JSON.stringify(referenced[0])).not.toContain("blob-body blob-body");
    const hash = referenced[0].blobs[0];
    const blobPath = join(v2Root(fixture), id, "blobs", hash);
    // Read-only: a tool cannot change a blob by accident (D49).
    expect(statSync(blobPath).mode & 0o777).toBe(0o400);
    expect(sha256(readFileSync(blobPath))).toBe(hash);
    expect(readFileSync(blobPath, "utf8")).toContain("BLOB_PIECE_END");

    const resumed = await ask(fixture, gateway, ["--resume-id", id, "Continue after the long answer."]);
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).output).toBe("AFTER_BLOB_RESUME");
    expect(gateway.requests.at(-1)!.body).toContain(big);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

test.skipIf(!tmuxAvailable())("the app resumes a compacted session from its summary and still shows every turn", async () => {
  const fixture = createFixture("fx-v2-app-compact-resume-");
  // Plain turns have nothing to note, so `/compact` needs no model call.
  const gateway = startFakeGateway([
    fakeGatewayFinalText("COMPACT_EARLIER_ANSWER"),
    fakeGatewayFinalText("COMPACT_MIDDLE_ANSWER"),
    fakeGatewayFinalText("COMPACT_LATEST_ANSWER"),
    fakeGatewayFinalText("AFTER_COMPACT_RESUME"),
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    for (const [prompt, answer] of [
      ["Earlier compact request", "COMPACT_EARLIER_ANSWER"],
      ["Middle compact request", "COMPACT_MIDDLE_ANSWER"],
      ["Latest compact request", "COMPACT_LATEST_ANSWER"],
    ]) {
      await app.session.sendText(prompt!);
      await scrollbackContains(app.session, answer!);
      await app.session.waitForComposer(TIMEOUT);
    }
    const id = onlySession(fixture);
    await app.session.sendText("/compact");
    await waitForLog(fixture, id, "fx-compactor-v1", TIMEOUT);
    await app.session.waitForComposer(TIMEOUT);
    await quitApp(app);
    const saved = readFileSync(join(v2Root(fixture), id, "log.jsonl"));

    const resumed = await startApp(fixture, gateway, ["-c"]);
    const shown = await scrollbackContains(resumed.session, "COMPACT_LATEST_ANSWER");
    expect(shown).toContain("COMPACT_EARLIER_ANSWER");
    expect(shown).not.toContain("compacted_conversation");
    await resumed.session.sendText("Continue after the compaction.");
    await resumed.session.waitForText("AFTER_COMPACT_RESUME", TIMEOUT);
    await quitApp(resumed);

    // The model gets the compacted conversation in place of the turns it
    // replaced; their messages and replies stay in it word for word.
    expect(gateway.requests).toHaveLength(4);
    const prompt = JSON.parse(gateway.requests.at(-1)!.body).prompt as Array<{ role: string; content: unknown }>;
    const userTexts = prompt
      .filter((message) => message.role === "user")
      .map((message) => typeof message.content === "string" ? message.content : JSON.stringify(message.content));
    const earlier = userTexts.filter((text) => text.includes("Earlier compact request"));
    expect(earlier).toHaveLength(1);
    expect(earlier[0]).toContain("compacted_conversation");
    expect(earlier[0]).toContain("COMPACT_EARLIER_ANSWER");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl")).subarray(0, saved.length)).toEqual(saved);
    expect(logLines(fixture, id).filter((line) => line.kind === "compacted")).toHaveLength(1);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

type Hold = { started: boolean; cancelled: boolean; release?: () => void };

/// A reply that streams `text`, then stays open until released or until fx
/// cancels the request.
function heldReply(hold: Hold, text: string): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  return new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      hold.started = true;
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "held", delta: text })}\n\n`));
      timer = setInterval(() => {
        if (!closed) controller.enqueue(encoder.encode(": held\n\n"));
      }, 50);
      hold.release = () => {
        if (closed) return;
        closed = true;
        clearInterval(timer);
        controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n'));
        controller.close();
      };
    },
    cancel() {
      closed = true;
      hold.cancelled = true;
      clearInterval(timer);
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

async function until(check: () => boolean, what: string) {
  const deadline = Date.now() + TIMEOUT;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(25);
  }
}

test.skipIf(!tmuxAvailable())("text typed while the app answers steers that turn, and it is saved and resumed inside it", async () => {
  const fixture = createFixture("fx-v2-app-steering-");
  const hold: Hold = { started: false, cancelled: false };
  const steering = "What are you doing right now?";
  const gateway = startFakeGateway([
    () => heldReply(hold, "ACTIVE_RESPONSE_HELD\n"),
    fakeGatewayFinalText("STEERED_ANSWER"),
    fakeGatewayFinalText("AFTER_STEERING_RESUME"),
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Hold this response until the test releases it.");
    await until(() => hold.started, "the held reply");
    await app.session.sendText(steering);
    await until(() => hold.cancelled, "steering to stop the held reply");
    await app.session.waitForText("STEERED_ANSWER", TIMEOUT);
    await app.session.waitForComposer(TIMEOUT);
    const steered = gateway.requests[1]!.body;
    expect(steered).toContain("<user_steering>");
    expect(steered).toContain(steering);
    expect(steered).toContain("ACTIVE_RESPONSE_HELD");
    expect(steered).not.toContain("<turn_aborted>");
    await quitApp(app);

    // Steering continues the turn it interrupts: one committed turn that
    // holds the steering, and nothing interrupted.
    const id = onlySession(fixture);
    const kinds = logLines(fixture, id).map((line) => line.kind);
    expect(kinds.filter((kind) => kind === "turn_committed")).toHaveLength(1);
    expect(kinds).not.toContain("turn_interrupted");
    expect(countIn(readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8"), steering)).toBe(1);

    const resumed = await startApp(fixture, gateway, ["-c"]);
    const shown = await scrollbackContains(resumed.session, "STEERED_ANSWER");
    expect(countIn(shown, steering)).toBe(1);
    await resumed.session.sendText("Continue after the steered turn.");
    await resumed.session.waitForText("AFTER_STEERING_RESUME", TIMEOUT);
    await quitApp(resumed);
    expect(gateway.requests.at(-1)!.body).toContain(steering);
    expectWholeLog(fixture, id);
  } finally {
    hold.release?.();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test.skipIf(!tmuxAvailable())("a cancelled app reply is saved as cancelled, and the session continues after a resume", async () => {
  const fixture = createFixture("fx-v2-app-cancel-");
  const hold: Hold = { started: false, cancelled: false };
  const gateway = startFakeGateway([
    // The newest streamed line waits for the next, so a second line lets
    // the first show.
    () => heldReply(hold, "PARTIAL_BEFORE_CANCEL\nPARTIAL_STILL_STREAMING\n"),
    fakeGatewayFinalText("AFTER_CANCEL_ANSWER"),
    fakeGatewayFinalText("AFTER_CANCEL_RESUME"),
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Stream a reply that I will cancel.");
    await until(() => hold.started, "the held reply");
    await app.session.waitForText("PARTIAL_BEFORE_CANCEL", TIMEOUT);
    await app.session.sendKeys("Escape");
    await app.session.waitForText("esc again to interrupt", TIMEOUT);
    await app.session.sendKeys("Escape");
    await until(() => hold.cancelled, "the cancel to reach the gateway");
    await app.session.waitForComposer(TIMEOUT);
    await app.session.sendText("Confirm the next prompt still works.");
    await app.session.waitForText("AFTER_CANCEL_ANSWER", TIMEOUT);
    const followUp = gateway.requests[1]!.body;
    expect(countIn(followUp, "<turn_aborted>")).toBe(1);
    expect(followUp).toContain("PARTIAL_BEFORE_CANCEL");
    await quitApp(app);

    const id = onlySession(fixture);
    const lines = logLines(fixture, id);
    expect(lines.filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual(["cancel"]);
    expect(lines.filter((line) => line.kind === "turn_committed")).toHaveLength(1);

    const resumed = await startApp(fixture, gateway, ["-c"]);
    const shown = await scrollbackContains(resumed.session, "AFTER_CANCEL_ANSWER");
    expect(shown).toContain("PARTIAL_BEFORE_CANCEL");
    await resumed.session.sendText("Continue after the resume.");
    await resumed.session.waitForText("AFTER_CANCEL_RESUME", TIMEOUT);
    await quitApp(resumed);
    // The cancelled turn is still one aborted turn in what the model sees.
    expect(countIn(gateway.requests.at(-1)!.body, "<turn_aborted>")).toBe(1);
    expectWholeLog(fixture, id);
  } finally {
    hold.release?.();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

function countIn(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

test("a parent killed while a named child runs a tool records that work interrupted, stops the tool, and the child continues with its history", async () => {
  const fixture = createFixture("fx-v2-child-crash-");
  const started = join(fixture.root, "child-tool-pid");
  let phase: "first" | "crash" | "again" = "first";
  const childBodies: string[] = [];
  const gateway = startDynamicFakeGateway(async (body) => {
    if (isChildRequest(body)) {
      childBodies.push(body);
      if (phase === "first") return fakeGatewayFinalText("CHILD_FIRST_DONE");
      if (phase === "crash") return fakeShellRun("child-crash-shell", `echo $$ > '${started}'; exec sleep 300`);
      return fakeGatewayFinalText("CHILD_AGAIN_DONE");
    }
    if (phase === "first" && body.includes("CHILD_FIRST_DONE")) return fakeGatewayFinalText("PARENT_FIRST_DONE");
    if (phase === "again" && body.includes("CHILD_AGAIN_DONE")) return fakeGatewayFinalText("PARENT_AGAIN_DONE");
    return fakeGatewayToolCall(`delegate-${phase}`, "subagent", {
      request: { action: "message", agent: "worker", message: `Child work ${phase}.` },
    });
  }, { classifierDecision: "clear" });
  try {
    const first = await ask(fixture, gateway, ["Start the worker."]);
    expect(first.code).toBe(0);
    expect(JSON.parse(first.stdout).output).toBe("PARENT_FIRST_DONE");
    const id = JSON.parse(first.stdout).session_id;
    const childId = childLines(fixture, id)[0].child;
    const childBefore = readFileSync(join(v2Root(fixture), childId, "log.jsonl"));

    phase = "crash";
    const { child, exited } = spawnAsk(fixture, gateway, ["--resume-id", id, "Give the worker a long job."]);
    await until(() => existsSync(started) && readFileSync(started, "utf8").trim() !== "", "the child's tool to start");
    const toolPid = Number(readFileSync(started, "utf8").trim());
    child.kill("SIGKILL");
    await exited;
    // fx's own processes go with it.
    await until(() => { try { process.kill(toolPid, 0); return false; } catch { return true; } }, "the child's tool to stop");

    const last = await command(fixture, gateway, ["session", "last", "--json"]);
    expect(last.code).toBe(0);
    expect(JSON.parse(last.stdout).id).toBe(id);
    // The killed turn opened on disk as its work started (D44), and holds no
    // piece: a child writes its pieces whole at its end.
    const childAfter = readFileSync(join(v2Root(fixture), childId, "log.jsonl"));
    expect(childAfter.subarray(0, childBefore.length).equals(childBefore)).toBe(true);
    const added = childAfter.subarray(childBefore.length).toString("utf8").trimEnd().split("\n").map((line) => JSON.parse(line));
    expect(added.map((line) => line.kind)).toEqual(["turn_started"]);

    phase = "again";
    const again = await ask(fixture, gateway, ["--resume-id", id, "Ask the worker again."]);
    expect(again.code).toBe(0);
    expect(again.stderr).not.toContain("panic");
    expect(JSON.parse(again.stdout).output).toBe("PARENT_AGAIN_DONE");
    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([
      ["child_spawned", null], ["child_finished", "ok"],
      ["child_spawned", null], ["child_finished", "interrupted"],
      ["child_spawned", null], ["child_finished", "ok"],
    ]);
    expect(new Set(lines.map((line) => line.child))).toEqual(new Set([childId]));
    // The next message continues the same child, with its first turn.
    expect(childBodies.at(-1)).toContain("CHILD_FIRST_DONE");
    expect(childBodies.at(-1)).toContain("Child work again.");
    expect(logLines(fixture, childId).filter((line) => line.kind === "turn_committed")).toHaveLength(2);
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// The newest work a parent's log records for its only child: the spawn,
/// and its finish once there is one.
function childWork(fixture: Fixture, parent: string) {
  const lines = childLines(fixture, parent);
  const spawned = lines.filter((line) => line.kind === "child_spawned");
  const current = spawned.at(-1);
  const finished = current ? lines.find((line) => line.kind === "child_finished" && line.work_id === current.work_id) : undefined;
  return { spawns: spawned.length, child: current?.child, work: current?.work_id, outcome: finished?.outcome ?? null };
}

// v1's steering test: the user keeps talking to the parent while its child
// runs, and the child's result arrives later.
for (const action of ["run", "message"] as const) {
  test.skipIf(!tmuxAvailable())(`the app talks to the user while a child runs, and records it done, ${action}`, async () => {
    const fixture = createFixture("fx-v2-app-child-steering-");
    const held = heldFakeGatewayFinalText();
    const parentReply = heldFakeGatewayFinalText();
    const activity = (pane: string) => pane.match(/^[• ] (?:Thinking|Generating|Running) \([^\n]+$/gm)?.at(-1)?.slice(2) ?? "";
    const requests: string[] = [];
    let childRequests = 0;
    let delegated = false;
    let afterChildTool = false;
    writeFileSync(join(fixture.workspace, "after-child.txt"), "AFTER_CHILD_TOOL_OK");
    const gateway = startDynamicFakeGateway((raw) => {
      const body = JSON.parse(raw);
      const latest = JSON.stringify(body.prompt?.filter((item: any) => item.role === "user").at(-1)?.content);
      if (latest.includes("STEERING_CHILD")) {
        childRequests++;
        return held.response;
      }
      requests.push(raw);
      if (!delegated) {
        delegated = true;
        return fakeGatewayToolCall("steering-delegation", "subagent", { request: action === "run"
          ? { action, task: "STEERING_CHILD" }
          : { action, agent: "worker", message: "STEERING_CHILD" } });
      }
      if (latest.includes("STEERING_LATER")) return fakeGatewayFinalText("LATER_OK");
      if (raw.includes("HELD_CHILD_RESULT")) {
        if (!afterChildTool) {
          afterChildTool = true;
          return fakeGatewayToolCall("after-child", "read_file", { path: "after-child.txt" });
        }
        return fakeGatewayFinalText("CHILD_COMPLETE");
      }
      if (latest.includes("STEERING_SECOND")) return fakeGatewayFinalText("SECOND_ACCEPTED");
      return new Response(parentReply.response.body!.pipeThrough(new TransformStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(
            'data: {"type":"text-start","id":"answer_1"}\n\n' +
              `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: "FIRST_STREAMING\n\nStill composing the first reply. " })}\n\n`,
          ));
        },
      })), { headers: parentReply.response.headers });
    }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }] });
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    let tui: TmuxSession | undefined;
    try {
      tui = await TmuxSession.create({
        cmd: JSON.stringify(FX_BIN), cwd: fixture.workspace, isolated: true, remainOnExit: true, stderrPath,
        env: {
          ...env(fixture, gateway), NO_COLOR: "1", FX_PERMISSION_MODE: "full-access", FX_MAX_AGENT_STEPS: "5",
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "subagent,worker,agent,tool",
        },
      });
      await tui.waitForStableComposer(15000);
      await tui.sendText("STEERING_START");
      await tui.waitForPane(() => childRequests === 1, 10000);
      const parent = rootSessions(fixture)[0]!;
      await until(() => childWork(fixture, parent).spawns === 1, "the child's spawn in the parent's log");
      const original = childWork(fixture, parent);
      expect(original.outcome).toBeNull();

      await tui.sendText("STEERING_FIRST");
      const streaming = await tui.waitForText("FIRST_STREAMING", 10000);
      expect(activity(streaming)).toMatch(/^Generating \(/);
      parentReply.release("FIRST_ACCEPTED");
      await tui.waitForText("FIRST_ACCEPTED", 10000);
      await tui.waitForPane((pane) => activity(pane).startsWith("Running ("), 10000);
      await tui.sendText("STEERING_SECOND");
      await tui.waitForText("SECOND_ACCEPTED", 10000);
      expect(childRequests).toBe(1);
      // Still the one piece of work, still running.
      expect(childWork(fixture, parent)).toEqual(original);
      expect(requests.some((raw) => raw.includes(original.child!) && raw.includes(original.work!))).toBe(true);
      expect(await tui.captureFullScrollback()).toContain("still running");

      held.release("HELD_CHILD_RESULT");
      await tui.waitForText("CHILD_COMPLETE", 10000);
      expect(requests.filter((raw) => raw.includes("HELD_CHILD_RESULT"))).toHaveLength(2);
      await until(() => childWork(fixture, parent).outcome === "ok", "the child's work to be recorded done");
      await tui.waitForStableComposer(10000);
      await tui.sendText("STEERING_LATER");
      await tui.waitForText("LATER_OK", 10000);
      expect(childRequests).toBe(1);
      await tui.sendText("/quit");
      await tui.waitForPane(() => tui!.paneStatus().dead, 10000);
      expect(tui.paneStatus().status).toBe(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      // One result for the delegation, and the child's work ends once.
      const results = logLines(fixture, parent).filter((line: any) =>
        line.kind === "item" && line.type === "tool_result" && JSON.stringify(line).includes("steering-delegation"));
      expect(results).toHaveLength(1);
      expect(childLines(fixture, parent).filter((line) => line.kind === "child_finished")).toHaveLength(1);
      expect(childWork(fixture, parent)).toEqual({ ...original, outcome: "ok" });
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("event=steering_wait_yielded ");
      expect(trace.split("\n").filter((line) => line.includes("event=steering_result_delivered "))).toHaveLength(1);
      expectWholeLog(fixture, parent);
    } finally {
      parentReply.dispose();
      held.dispose();
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, 60000);
}

// ---------------------------------------------------------------------------
// The fault matrix beyond fx ask: kills between turns, a damaged or missing
// piece, a read-only folder, a full disk and contention, for the app and
// ACP, and a damaged child log for subagents.

/// Flips one bit in the middle of the log's middle line.
function flipMiddleByte(path: string) {
  const bytes = readFileSync(path);
  const lines = bytes.toString("utf8").split("\n");
  const target = Math.floor(lines.length / 2);
  let offset = 0;
  for (let i = 0; i < target; i += 1) offset += Buffer.byteLength(lines[i]!) + 1;
  const at = offset + Math.floor(Buffer.byteLength(lines[target]!) / 2);
  bytes[at] = bytes[at]! ^ 0x01;
  writeFileSync(path, bytes);
}

/// Two saved `fx ask` turns, for a fault to damage.
async function savedTwoTurns(fixture: Fixture, gateway: any) {
  const first = await ask(fixture, gateway, ["Fault question one."]);
  expect(first.code).toBe(0);
  const id = JSON.parse(first.stdout).session_id;
  expect((await ask(fixture, gateway, ["--resume-id", id, "Fault question two."])).code).toBe(0);
  return { id, log: join(v2Root(fixture), id, "log.jsonl") };
}

/// The app started with `args`, left to exit on its own; its stderr once it has.
async function appExit(fixture: Fixture, gateway: any, args: string[]) {
  const stderrPath = join(fixture.root, `stderr-${Date.now()}.log`);
  writeFileSync(stderrPath, "");
  const session = await TmuxSession.create({
    cmd: `${FX_BIN} --sessions-v2 ${args.join(" ")}`,
    cwd: fixture.workspace,
    env: { ...env(fixture, gateway, false), NO_COLOR: "1" },
    stderrPath,
    remainOnExit: true,
  });
  await until(() => session.paneStatus().dead === true, "the app to exit");
  const status = session.paneStatus().status;
  await session.kill();
  return { status, stderr: readFileSync(stderrPath, "utf8") };
}

test.skipIf(!tmuxAvailable())("an app killed between turns resumes with its last turn whole", async () => {
  const fixture = createFixture("fx-v2-app-kill-idle-");
  const gateway = replyToLatest([
    ["Save this turn before the kill.", "SAVED_BEFORE_IDLE_KILL"],
    ["Continue after the idle kill.", "AFTER_IDLE_KILL"],
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Save this turn before the kill.");
    await app.session.waitForText("SAVED_BEFORE_IDLE_KILL", TIMEOUT);
    await app.session.waitForComposer(TIMEOUT);
    const id = onlySession(fixture);
    await waitForLog(fixture, id, "turn_committed");
    Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
    await app.session.kill();

    const resumed = await startApp(fixture, gateway, ["--resume", id]);
    expect(await scrollbackContains(resumed.session, "SAVED_BEFORE_IDLE_KILL")).toContain("SAVED_BEFORE_IDLE_KILL");
    await resumed.session.sendText("Continue after the idle kill.");
    await resumed.session.waitForText("AFTER_IDLE_KILL", TIMEOUT);
    await quitApp(resumed);
    const kinds = logLines(fixture, id).map((line) => line.kind);
    expect(kinds.filter((kind) => kind === "turn_committed")).toHaveLength(2);
    expect(kinds).not.toContain("turn_interrupted");
    expect(gateway.requests.at(-1)!.body).toContain("SAVED_BEFORE_IDLE_KILL");
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test("ACP killed between prompts loads with its last turn whole", async () => {
  const fixture = createFixture("fx-v2-acp-kill-idle-");
  const gateway = replyToLatest([
    ["Before the idle ACP kill.", "ACP_BEFORE_IDLE_KILL"],
    ["After the idle ACP kill.", "ACP_AFTER_IDLE_KILL"],
  ]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Before the idle ACP kill.") });
    await waitForLog(fixture, id, "turn_committed");
    await client.kill();

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.texts("user_message_chunk")).toEqual(["Before the idle ACP kill."]);
    expect(client.texts("agent_message_chunk")).toEqual(["ACP_BEFORE_IDLE_KILL"]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the idle ACP kill.") });
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(logLines(fixture, id).map((line) => line.kind)).not.toContain("turn_interrupted");
    expect(gateway.requests.at(-1)!.body).toContain("ACP_BEFORE_IDLE_KILL");
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test.skipIf(!tmuxAvailable())("the app refuses a damaged session, a busy one and a read-only one, and says which", async () => {
  const fixture = createFixture("fx-v2-app-faults-");
  const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("FAULT_ANSWER"));
  try {
    const { id, log } = await savedTwoTurns(fixture, gateway);
    const requests = gateway.requests.length;
    const good = readFileSync(log);

    flipMiddleByte(log);
    const damaged = readFileSync(log);
    const flipped = await appExit(fixture, gateway, ["--resume", id]);
    expect(flipped.status).toBe(1);
    expect(flipped.stderr).toContain("saved session is unreadable");
    expect(flipped.stderr).toContain(`fx session recover`);
    expect(readFileSync(log)).toEqual(damaged);
    writeFileSync(log, good);

    const folder = join(v2Root(fixture), id);
    chmodSync(log, 0o400);
    chmodSync(folder, 0o500);
    try {
      const readOnly = await appExit(fixture, gateway, ["--resume", id]);
      expect(readOnly.status).toBe(1);
      expect(readOnly.stderr).toBe("fx: this session cannot be opened for writing: permission denied. Check the permissions under ~/.fx/sessions/v2, then resume again.\n");
    } finally {
      chmodSync(folder, 0o700);
      chmodSync(log, 0o600);
    }
    expect(readFileSync(log)).toEqual(good);

    const owner = await startApp(fixture, gateway, ["--resume", id]);
    const busy = await appExit(fixture, gateway, ["--resume", id]);
    expect(busy.status).toBe(1);
    expect(busy.stderr).toContain("another fx process may be using this session");
    await quitApp(owner);
    expect(gateway.requests.length).toBe(requests);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 5);

test("ACP refuses a damaged or read-only session and leaves its log as it was", async () => {
  const fixture = createFixture("fx-v2-acp-faults-");
  const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("FAULT_ANSWER"));
  let client: AcpRpc | undefined;
  try {
    const { id, log } = await savedTwoTurns(fixture, gateway);
    const good = readFileSync(log);
    const load = async () => {
      client = await AcpRpc.start(fixture, gateway);
      const response = await client.request("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
      expect(await client.close()).toBe(0);
      client = undefined;
      return response;
    };

    flipMiddleByte(log);
    const damaged = readFileSync(log);
    expect((await load()).error.message).toBe("Session could not be loaded");
    expect(readFileSync(log)).toEqual(damaged);
    writeFileSync(log, good);

    const folder = join(v2Root(fixture), id);
    chmodSync(log, 0o400);
    chmodSync(folder, 0o500);
    try {
      expect((await load()).error.message).toBe("Session could not be loaded: permission denied");
    } finally {
      chmodSync(folder, 0o700);
      chmodSync(log, 0o600);
    }
    expect(readFileSync(log)).toEqual(good);
    expect((await load()).error).toBeUndefined();
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test.skipIf(!tmuxAvailable())("the app and ACP refuse a session whose blob went missing as damaged, not missing", async () => {
  const fixture = createFixture("fx-v2-lost-blob-hosts-");
  const big = "HOST_BLOB_START " + "blob-body ".repeat(30_000) + "HOST_BLOB_END";
  const gateway = startFakeGateway([fakeGatewayFinalText(big)]);
  let client: AcpRpc | undefined;
  try {
    const id = JSON.parse((await ask(fixture, gateway, ["Answer at great length."])).stdout).session_id;
    const referenced = (logLines(fixture, id) as any[]).find((line) => Array.isArray(line.blobs) && line.blobs.length === 1);
    rmSync(join(v2Root(fixture), id, "blobs", referenced.blobs[0]));

    const app = await appExit(fixture, gateway, ["--resume", id]);
    expect(app.status).toBe(1);
    expect(app.stderr).toContain("saved session is unreadable");
    expect(app.stderr).not.toContain("NotFound");
    client = await AcpRpc.start(fixture, gateway);
    const load = await client.request("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(load.error.message).toBe("Session could not be loaded");
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(gateway.requests).toHaveLength(1);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

/// A `/bin/sh` script that starts the app on session `id` under a file-size
/// limit of `blocks` shell blocks; a script, so the limit survives the
/// pane's own shell quoting.
function limitedAppScript(fixture: Fixture, id: string, blocks: number) {
  const script = join(fixture.root, `limited-fx-${blocks}.sh`);
  writeFileSync(script, `#!/bin/sh\ntrap '' XFSZ\nulimit -f ${blocks}\nexec '${FX_BIN}' --sessions-v2 --resume ${id}\n`, { mode: 0o700 });
  return script;
}

test.skipIf(!tmuxAvailable())("an app whose disk fills keeps running, and the session resumes after", async () => {
  const fixture = createFixture("fx-v2-app-full-disk-");
  const long = "LONG_UNSAVED_START " + "unsaved ".repeat(800) + "LONG_UNSAVED_END";
  const gateway = replyToLatest([
    ["Before the full disk.", "BEFORE_APP_FULL_DISK"],
    ["The disk fills in this turn.", long],
    ["The disk is already full.", "NEVER_ASKED_ON_FULL_DISK"],
    ["After the full disk.", "AFTER_APP_FULL_DISK"],
  ]);
  let full: TmuxSession | undefined;
  const launch = async (id: string, blocks: number) => {
    full = await TmuxSession.create({
      cmd: limitedAppScript(fixture, id, blocks),
      cwd: fixture.workspace,
      env: { ...env(fixture, gateway, false), NO_COLOR: "1" },
      stderrPath: join(fixture.root, `stderr-${blocks}.log`),
    });
    await full.waitForComposer(TIMEOUT);
    return full;
  };
  const quit = async () => {
    await full!.sendText("/quit");
    expect(await full!.waitForSessionEnd()).toBe(true);
    await full!.kill();
    full = undefined;
  };
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Before the full disk.");
    await app.session.waitForText("BEFORE_APP_FULL_DISK", TIMEOUT);
    await quitApp(app);
    const id = onlySession(fixture);
    const log = join(v2Root(fixture), id, "log.jsonl");

    // No room at all: the prompt is refused before the model is asked, and
    // nothing reaches the log.
    const asked = gateway.requests.length;
    const whole = readFileSync(log);
    let app2 = await launch(id, Math.floor(whole.length / SH_LIMIT_BLOCK));
    await app2.sendText("The disk is already full.");
    await app2.waitForText("FileTooBig", TIMEOUT);
    await app2.waitForComposer(TIMEOUT);
    await quit();
    expect(gateway.requests.length).toBe(asked);
    expect(readFileSync(log)).toEqual(whole);

    // Room for the turn's start (about 1.6 KB) but not its 6 KB answer: the
    // model is asked, the answer shows, and saving it fails. The log keeps a
    // torn tail that the next open cuts.
    app2 = await launch(id, Math.ceil((whole.length + 2000) / SH_LIMIT_BLOCK));
    await app2.sendText("The disk fills in this turn.");
    // It names the write that failed first, even when an earlier streamed
    // write took the log down (D40).
    await app2.waitForText("Turn completed, but fx could not save it (FileTooBig)", TIMEOUT);
    await app2.waitForComposer(TIMEOUT);
    await quit();
    expect(gateway.requests.length).toBe(asked + 1);

    const resumed = await startApp(fixture, gateway, ["--resume", id]);
    expect(await scrollbackContains(resumed.session, "BEFORE_APP_FULL_DISK")).toContain("BEFORE_APP_FULL_DISK");
    await resumed.session.sendText("After the full disk.");
    await resumed.session.waitForText("AFTER_APP_FULL_DISK", TIMEOUT);
    await quitApp(resumed);
    // The filled turn kept its prompt, not its answer, and a resume closed it
    // as interrupted; the refused prompt left nothing.
    const kinds = logLines(fixture, id).map((line) => line.kind);
    expect(kinds.filter((kind) => kind === "turn_committed")).toHaveLength(2);
    expect(kinds.filter((kind) => kind === "turn_interrupted")).toHaveLength(1);
    const last = gateway.requests.at(-1)!.body;
    expect(last).toContain("The disk fills in this turn.");
    expect(last).not.toContain("LONG_UNSAVED_START");
    expect(last).not.toContain("The disk is already full.");
    expectWholeLog(fixture, id);
  } finally {
    if (full) await full.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 6);

test("ACP on a full disk fails the prompt, and the session loads and continues after", async () => {
  const fixture = createFixture("fx-v2-acp-full-disk-");
  const gateway = replyToLatest([
    ["Before the ACP full disk.", "BEFORE_ACP_FULL_DISK"],
    ["The ACP disk is full.", "NEVER_SAVED_ACP"],
    ["After the ACP full disk.", "AFTER_ACP_FULL_DISK"],
  ]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Before the ACP full disk.") });
    expect(await client.close()).toBe(0);
    const log = join(v2Root(fixture), id, "log.jsonl");
    const saved = readFileSync(log);

    client = await AcpRpc.start(fixture, gateway, {}, Math.floor(saved.length / SH_LIMIT_BLOCK));
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    const asked = gateway.requests.length;
    const refused = await client.request("session/prompt", { sessionId: id, ...acpPrompt("The ACP disk is full.") });
    expect(refused.error).toEqual({ code: -32603, message: "Session could not be saved: a file-size limit was reached" });
    expect(await client.close()).toBe(0);
    // Refused before the model is asked, and nothing reached the log.
    expect(gateway.requests.length).toBe(asked);
    expect(readFileSync(log)).toEqual(saved);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.texts("agent_message_chunk")).toEqual(["BEFORE_ACP_FULL_DISK"]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the ACP full disk.") });
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_ACP_FULL_DISK");
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test.skipIf(!tmuxAvailable())("an app killed after a named child finished resumes, and the child continues with its history", async () => {
  const fixture = createFixture("fx-v2-app-kill-after-child-");
  let phase = 1;
  const gateway = startDynamicFakeGateway((body) => {
    if (isChildRequest(body)) {
      if (phase === 1) return fakeGatewayFinalText("CHILD_FIRST_ANSWER");
      return fakeGatewayFinalText(body.includes("CHILD_FIRST_ANSWER") ? "CHILD_REMEMBERED" : "CHILD_FORGOT");
    }
    if (body.includes(`delegate-${phase}`)) return fakeGatewayFinalText(`PARENT_${phase}_DONE`);
    return fakeGatewayToolCall(`delegate-${phase}`, "subagent", { request: { action: "message", agent: "worker", message: `Worker message ${phase}.` } });
  }, { classifierDecision: "clear" });
  try {
    const app = await startApp(fixture, gateway, [], true, { FX_PERMISSION_MODE: "auto" });
    await app.session.sendText("Start the worker.");
    await scrollbackContains(app.session, "PARENT_1_DONE");
    await app.session.waitForComposer(TIMEOUT);
    const roots = rootSessions(fixture);
    expect(roots).toHaveLength(1);
    const id = roots[0]!;
    await waitForLog(fixture, id, "turn_committed");
    Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
    await app.session.kill();

    phase = 2;
    const resumed = await startApp(fixture, gateway, ["--resume", id], true, { FX_PERMISSION_MODE: "auto" });
    await resumed.session.sendText("Ask the worker again.");
    await scrollbackContains(resumed.session, "PARENT_2_DONE");
    await resumed.session.waitForComposer(TIMEOUT);
    await quitApp(resumed);

    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([
      ["child_spawned", null], ["child_finished", "ok"], ["child_spawned", null], ["child_finished", "ok"],
    ]);
    expect(lines[2].child).toBe(lines[0].child);
    const childId = lines[0].child;
    const child = logLines(fixture, childId).map((line) => line.kind);
    expect(child.filter((kind) => kind === "turn_committed")).toHaveLength(2);
    expect(JSON.stringify(logLines(fixture, childId))).toContain("CHILD_REMEMBERED");
    expect(logLines(fixture, id).map((line) => line.kind)).not.toContain("turn_interrupted");
    expectWholeLog(fixture, id);
    expectWholeLog(fixture, childId);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// Hosted terminal records for a v2 session: its terminal folder (D45).
function terminalRecords(fixture: Fixture, id: string): Array<Record<string, unknown>> {
  const root = join(fixture.home, ".fx", "terminal", id, "terminal", "state");
  if (!existsSync(root)) return [];
  return readdirSync(root)
    .filter((name) => name.startsWith("record-") && name.endsWith(".json"))
    .map((name) => JSON.parse(readFileSync(join(root, name), "utf8")));
}

test.skipIf(!tmuxAvailable())("a hosted terminal ends with an app crash, and the resumed app reports it ended", async () => {
  const fixture = createFixture("fx-v2-tty-crash-");
  let shellId = "";
  const gateway = startFakeGateway([
    fakeGatewayToolCall("tty_run", "shell", {
      request: {
        action: "run",
        command: "printf 'TTY_READY\\n'; while IFS= read -r line; do printf 'TTY_ECHO:%s\\n' \"$line\"; done",
        profile: "clean",
        tty: true,
        yield_time_ms: 0,
      },
    }),
    (body: string) => {
      shellId = body.match(/shell-[A-Za-z0-9_-]{22}/)?.[0] ?? "";
      return fakeGatewayFinalText("TTY_STARTED");
    },
    () => fakeGatewayToolCall("tty_interact", "shell", {
      request: { action: "interact", session_id: shellId, chars: "after the crash\n", yield_time_ms: 2000 },
    }),
    () => fakeGatewayToolCall("tty_stop", "shell", { request: { action: "stop", session_id: shellId, force: true } }),
    fakeGatewayFinalText("TTY_ENDED_REPORTED"),
  ]);
  const appEnv = { FX_PERMISSION_MODE: "full-access", SHELL: "/bin/sh" };
  const alive = (pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  try {
    const app = await startApp(fixture, gateway, [], true, appEnv);
    await app.session.sendText("Start a terminal.");
    await app.session.waitForText("TTY_STARTED", TIMEOUT);
    expect(shellId).toMatch(/^shell-[A-Za-z0-9_-]{22}$/);
    const id = onlySession(fixture);
    await waitForLog(fixture, id, "turn_committed");
    const shellPid = Number(terminalRecords(fixture, id).find((record) => record.session_id === shellId)?.pid);
    expect(alive(shellPid)).toBe(true);
    Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
    await app.session.kill();

    // The terminal belonged to the crashed process and ended with it.
    const deadline = Date.now() + 2_000;
    while (alive(shellPid) && Date.now() < deadline) await Bun.sleep(10);
    expect(alive(shellPid)).toBe(false);

    const resumed = await startApp(fixture, gateway, ["--resume", id], true, appEnv);
    await resumed.session.sendText("Talk to the terminal, then stop it.");
    await resumed.session.waitForText("TTY_ENDED_REPORTED", TIMEOUT);
    // Neither interact nor stop reattaches; both report why it is gone.
    for (const index of [3, 4]) {
      expect(gateway.requests[index]!.body).toContain("TerminalEnded");
      expect(gateway.requests[index]!.body).toContain("ended when the fx process that started it exited");
    }
    expect(gateway.requests[3]!.body).not.toContain("TTY_ECHO:after the crash");
    await quitApp(resumed);
    expect(terminalRecords(fixture, id).find((record) => record.session_id === shellId)?.lifecycle).toBe("lost");
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

/// A gateway that runs a fast tool, then a slow one, for `prompt`; `slow`
/// resolves once the slow call is served. Any other prompt ends with `after`.
function twoToolGateway(prefix: string, prompt: string, after: [string, string]) {
  let served: () => void = () => {};
  const slow = new Promise<void>((resolve) => (served = resolve));
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes(after[0])) return fakeGatewayFinalText(after[1]);
    if (body.includes(prompt) && body.includes(`${prefix}_FIRST_TOOL_OUTPUT`)) {
      served();
      const input = JSON.stringify({ request: { yield_time_ms: 30_000, action: "run", command: "sleep 30" } });
      return fakeGatewaySerializedToolCall(`${prefix}-slow-2`, "shell", input, `${prefix}_RUNNING_PLAN starts the slow one.`);
    }
    if (body.includes(prompt)) return fakeShellRun(`${prefix}-fast-1`, `echo ${prefix}_FIRST_TOOL_OUTPUT`);
    return fakeGatewayFinalText(`${prefix}_UNEXPECTED`);
  });
  return { gateway, slow };
}

/// After a kill mid-tool: the finished call keeps its result, the running one
/// comes back answered as possibly run with its message's text, and the crash
/// interrupted the turn.
function expectToolKillRepaired(fixture: Fixture, id: string, body: string, prefix: string) {
  expect(body).toContain(`${prefix}_FIRST_TOOL_OUTPUT`);
  expectPairedToolCalls(body);
  expect(assistantTextBeside(body, `${prefix}-slow-2`)).toBe(`${prefix}_RUNNING_PLAN starts the slow one.`);
  const { calls, results } = promptToolParts(body);
  expect(calls.map((part) => part.toolCallId)).toEqual([`${prefix}-fast-1`, `${prefix}-slow-2`]);
  expect(results.find((part) => part.toolCallId === `${prefix}-slow-2`)?.output?.value).toContain("may have partly run");
  expect(logLines(fixture, id).filter((line) => line.kind === "turn_interrupted").map((line) => line.reason)).toEqual(["crash"]);
  expectWholeLog(fixture, id);
}

/// A write cut short by a power loss: part of a line, no newline.
function tearTail(fixture: Fixture, id: string) {
  appendFileSync(join(v2Root(fixture), id, "log.jsonl"), '{"v":1,"seq":99,"ts":1,"kind":"item","ty');
}

test.skipIf(!tmuxAvailable())("an app killed while a tool runs answers that call on resume and goes on", async () => {
  const fixture = createFixture("fx-v2-app-kill-tool-");
  const { gateway, slow } = twoToolGateway("APP", "Run two app tools.", ["After the app tool kill.", "AFTER_APP_TOOL_KILL"]);
  const appEnv = { FX_PERMISSION_MODE: "full-access" };
  try {
    const app = await startApp(fixture, gateway, [], true, appEnv);
    await app.session.sendText("Run two app tools.");
    await slow;
    const id = onlySession(fixture);
    // The call is saved before it runs (D28).
    await waitForLog(fixture, id, "APP-slow-2");
    Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
    await app.session.kill();

    const resumed = await startApp(fixture, gateway, ["--resume", id], true, appEnv);
    // The resumed transcript shows the text fx showed before the kill.
    expect(await scrollbackContains(resumed.session, "APP_RUNNING_PLAN")).toContain("APP_RUNNING_PLAN");
    await resumed.session.sendText("After the app tool kill.");
    await resumed.session.waitForText("AFTER_APP_TOOL_KILL", TIMEOUT);
    await quitApp(resumed);
    expectToolKillRepaired(fixture, id, gateway.requests.at(-1)!.body, "APP");
    // The crash took the first turn, so the next one names the session (D52).
    expect(storedTitles(fixture, id)).toEqual(["Run two app tools."]);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 4);

test("ACP killed while a tool runs answers that call on load and goes on", async () => {
  const fixture = createFixture("fx-v2-acp-kill-tool-");
  const { gateway, slow } = twoToolGateway("ACP", "Run two ACP tools.", ["After the ACP tool kill.", "AFTER_ACP_TOOL_KILL"]);
  const acpEnv = { FX_PERMISSION_MODE: "full-access" };
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway, acpEnv);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    void client.request("session/prompt", { sessionId: id, ...acpPrompt("Run two ACP tools.") }).catch(() => {});
    await slow;
    await waitForLog(fixture, id, "ACP-slow-2");
    await client.kill();

    client = await AcpRpc.start(fixture, gateway, acpEnv);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    // Load replays the text fx sent before the kill.
    expect(client.texts("agent_message_chunk").join("")).toContain("ACP_RUNNING_PLAN");
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the ACP tool kill.") });
    expect(await client.close()).toBe(0);
    client = undefined;
    expectToolKillRepaired(fixture, id, gateway.requests.at(-1)!.body, "ACP");
    // The crash took the first turn, so the next one names the session (D52).
    expect(storedTitles(fixture, id)).toEqual(["Run two ACP tools."]);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test.skipIf(!tmuxAvailable())("the app cuts a torn tail on resume and the session goes on", async () => {
  const fixture = createFixture("fx-v2-app-torn-");
  const gateway = replyToLatest([
    ["Before the app torn tail.", "BEFORE_APP_TORN"],
    ["After the app torn tail.", "AFTER_APP_TORN"],
  ]);
  try {
    const app = await startApp(fixture, gateway, []);
    await app.session.sendText("Before the app torn tail.");
    await app.session.waitForText("BEFORE_APP_TORN", TIMEOUT);
    await quitApp(app);
    const id = onlySession(fixture);
    tearTail(fixture, id);

    const resumed = await startApp(fixture, gateway, ["--resume", id]);
    expect(await scrollbackContains(resumed.session, "BEFORE_APP_TORN")).toContain("BEFORE_APP_TORN");
    await resumed.session.sendText("After the app torn tail.");
    await resumed.session.waitForText("AFTER_APP_TORN", TIMEOUT);
    await quitApp(resumed);
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_APP_TORN");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8")).not.toContain('"seq":99');
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("ACP cuts a torn tail on load and the session goes on", async () => {
  const fixture = createFixture("fx-v2-acp-torn-");
  const gateway = replyToLatest([
    ["Before the ACP torn tail.", "BEFORE_ACP_TORN"],
    ["After the ACP torn tail.", "AFTER_ACP_TORN"],
  ]);
  let client: AcpRpc | undefined;
  try {
    client = await AcpRpc.start(fixture, gateway);
    const id = (await client.ok("session/new", { cwd: fixture.workspace, mcpServers: [] })).sessionId;
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("Before the ACP torn tail.") });
    expect(await client.close()).toBe(0);
    tearTail(fixture, id);

    client = await AcpRpc.start(fixture, gateway);
    await client.ok("session/load", { sessionId: id, cwd: fixture.workspace, mcpServers: [] });
    expect(client.texts("agent_message_chunk")).toEqual(["BEFORE_ACP_TORN"]);
    await client.ok("session/prompt", { sessionId: id, ...acpPrompt("After the ACP torn tail.") });
    expect(await client.close()).toBe(0);
    client = undefined;
    expect(gateway.requests.at(-1)!.body).toContain("BEFORE_ACP_TORN");
    expect(readFileSync(join(v2Root(fixture), id, "log.jsonl"), "utf8")).not.toContain('"seq":99');
    expectWholeLog(fixture, id);
  } finally {
    if (client) await client.kill();
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a named child whose log is damaged fails that message, and the parent turn goes on", async () => {
  const fixture = createFixture("fx-v2-child-damaged-");
  let phase = 1;
  const gateway = startDynamicFakeGateway(async (body) => {
    if (isChildRequest(body)) return fakeGatewayFinalText(`CHILD_ANSWER_${phase}`);
    if (phase === 1 && body.includes("CHILD_ANSWER_1")) return fakeGatewayFinalText("PARENT_FIRST_DONE");
    if (phase === 2 && body.includes("delegate-2")) return fakeGatewayFinalText("PARENT_AFTER_CHILD_FAILED");
    return fakeGatewayToolCall(`delegate-${phase}`, "subagent", { request: { action: "message", agent: "worker", message: `Child work ${phase}.` } });
  }, { classifierDecision: "clear" });
  try {
    const first = await ask(fixture, gateway, ["Start the worker."]);
    expect(JSON.parse(first.stdout).output).toBe("PARENT_FIRST_DONE");
    const id = JSON.parse(first.stdout).session_id;
    const childId = childLines(fixture, id)[0].child;
    const childLog = join(v2Root(fixture), childId, "log.jsonl");
    flipMiddleByte(childLog);
    const damaged = readFileSync(childLog);

    phase = 2;
    const again = await ask(fixture, gateway, ["--resume-id", id, "Ask the worker again."]);
    expect(again.code).toBe(0);
    expect(JSON.parse(again.stdout).output).toBe("PARENT_AFTER_CHILD_FAILED");
    expect(JSON.parse(again.stdout).tool_calls).toEqual([{ name: "subagent", status: "error" }]);
    const lines = childLines(fixture, id);
    expect(lines.map((line) => [line.kind, line.outcome ?? null])).toEqual([
      ["child_spawned", null], ["child_finished", "ok"], ["child_spawned", null], ["child_finished", "failed"],
    ]);
    expect(JSON.stringify(lines[3].data)).toContain("Corrupt");
    // The damaged log is left for recovery.
    expect(readFileSync(childLog)).toEqual(damaged);
    expectWholeLog(fixture, id);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 2);

// ---------------------------------------------------------------------------
// The fault grid: every way a run leaves a session, every fault, and every
// way back in. Each case copies a saved home, applies one fault and enters
// once. A refusal must name its cause and leave the log as it was; a fault
// that can clear must give way once it has; and whatever comes back must be
// the history the run left.

type GridExit = "committed" | "cancelled" | "crashed" | "crashed-mid-tool";
type GridFault = "none" | "torn-tail" | "flipped-byte" | "lost-blob" | "read-only" | "full-disk" | "busy";
type GridEntry = "ask-id" | "ask-last" | "app-id" | "app-last" | "acp-load" | "acp-resume" | "ask-new" | "app-new" | "acp-new";
type GridHost = "ask" | "app" | "acp";

const GRID_EXITS: GridExit[] = ["committed", "cancelled", "crashed", "crashed-mid-tool"];
const GRID_FAULTS: GridFault[] = ["none", "torn-tail", "flipped-byte", "lost-blob", "read-only", "full-disk", "busy"];
const GRID_ENTRIES: GridEntry[] = ["ask-id", "ask-last", "app-id", "app-last", "acp-load", "acp-resume"];
const gridHost = (entry: GridEntry) => entry.slice(0, entry.indexOf("-")) as GridHost;

/// macOS fills a real disk image; elsewhere a file-size limit stands in.
const REAL_FULL_DISK = process.platform === "darwin";

/// What each host says when it refuses, by cause.
const GRID_SAYS: Record<"damaged" | "denied" | "busy" | "full", Record<GridHost, RegExp>> = {
  damaged: { ask: /InvalidSessionFormat/, app: /saved session is unreadable/, acp: /^Session could not be loaded$/ },
  denied: { ask: /AccessDenied/, app: /cannot be opened for writing: permission denied|AccessDenied/, acp: /permission denied/ },
  busy: { ask: /SessionBusy/, app: /another fx process may be using this session/, acp: /^Session is busy$/ },
  full: REAL_FULL_DISK
    ? { ask: /NoSpaceLeft/, app: /NoSpaceLeft|the disk is full/, acp: /the disk is full/ }
    : { ask: /FileTooBig/, app: /FileTooBig|a file-size limit was reached/, acp: /a file-size limit was reached/ },
};

/// A first reply over the blob limit, so every base session has a blob.
const GRID_BIG = `GRID_BIG_START ${"grid-body ".repeat(30_000)}GRID_BIG_END`;

/// One saved home per exit and host, made once and copied into every case.
/// The first turn is always `fx ask`'s; the app's `-c` continues only a
/// session the app has opened, so its bases end their second turn in the app.
const gridBases = new Map<string, Promise<{ fixture: Fixture; id: string }>>();

function gridBase(exit: GridExit, by: "ask" | "app") {
  const key = `${exit}:${by}`;
  let base = gridBases.get(key);
  if (!base) {
    base = makeGridBase(exit, by);
    gridBases.set(key, base);
  }
  return base;
}

async function makeGridBase(exit: GridExit, by: "ask" | "app") {
  const fixture = createFixture(`fx-v2-grid-${by}-${exit}-`);
  let stall: () => void = () => {};
  const stalled = new Promise<void>((resolve) => (stall = resolve));
  const hold: Hold = { started: false, cancelled: false };
  const gateway = startDynamicFakeGateway(async (body) => {
    if (!body.includes("Grid second.")) return fakeGatewayFinalText(GRID_BIG);
    if (exit === "committed") return fakeGatewayFinalText("GRID_SECOND_ANSWER");
    if (exit === "crashed-mid-tool") {
      if (!body.includes("GRID_FAST_TOOL_OUTPUT")) return fakeShellRun("grid-fast-1", "echo GRID_FAST_TOOL_OUTPUT");
      stall();
      return fakeShellRun("grid-slow-2", "sleep 5");
    }
    stall();
    // The app shows a streamed line once the next begins.
    if (by === "app" && exit === "cancelled") return heldReply(hold, "GRID_PARTIAL\nGRID_STILL_STREAMING\n");
    return new Promise<Response>(() => {});
  });
  try {
    const first = await ask(fixture, gateway, ["Grid first."]);
    expect(first.code, `${exit} base by ${by}: signal ${first.signal}: ${first.stderr}`).toBe(0);
    const id: string = JSON.parse(first.stdout).session_id;
    if (by === "ask" && exit === "committed") {
      expect((await ask(fixture, gateway, ["--resume-id", id, "Grid second."])).code).toBe(0);
    } else if (by === "ask") {
      const run = spawnAsk(fixture, gateway, ["--resume-id", id, "Grid second."]);
      await stalled;
      if (exit === "crashed-mid-tool") await waitForLog(fixture, id, "grid-slow-2");
      run.child.kill(exit === "cancelled" ? "SIGINT" : "SIGKILL");
      await run.exited;
    } else {
      const app = await startApp(fixture, gateway, ["--resume", id], true, { FX_PERMISSION_MODE: "full-access" });
      try {
        // Typed while the resumed history still draws, a prompt's turn can
        // go undrawn (F33), so wait for the screen to settle.
        await app.session.waitForStableComposer(TIMEOUT, 300);
        await app.session.sendText("Grid second.");
        if (exit === "committed") {
          await app.session.waitForText("GRID_SECOND_ANSWER", TIMEOUT);
          await app.session.waitForComposer(TIMEOUT);
          await quitApp(app);
        } else if (exit === "cancelled") {
          // Mid-reply by the gateway and the log, not the screen: an open
          // stream may not draw after a large resume (F33).
          await until(() => hold.started, "the held reply");
          await waitForLog(fixture, id, "Grid second.");
          await app.session.sendKeys("Escape");
          await app.session.waitForText("esc again to interrupt", TIMEOUT);
          await app.session.sendKeys("Escape");
          await until(() => hold.cancelled, "the cancel to reach the gateway");
          await app.session.waitForComposer(TIMEOUT);
          await quitApp(app);
        } else {
          await stalled;
          if (exit === "crashed-mid-tool") await waitForLog(fixture, id, "grid-slow-2");
          Bun.spawnSync(["kill", "-9", String(app.session.processPid())]);
        }
      } finally {
        await app.session.kill();
      }
    }
    // A crash leaves its turn open, for the next open to end.
    const kinds = logLines(fixture, id).map((line) => line.kind);
    const ended = kinds.filter((kind) => kind === "turn_committed" || kind === "turn_interrupted").length;
    expect(kinds.filter((kind) => kind === "turn_started").length - ended).toBe(exit.startsWith("crashed") ? 1 : 0);
    return { fixture, id };
  } finally {
    gateway.stop();
  }
}

/// Answers `Grid token T.` with `GRID_ANSWER_T`, by the newest token in the
/// request, so history never answers for the prompt. `hold(T)` keeps T's
/// reply until the returned release runs.
function gridGateway() {
  const holds = new Map<string, { reached: () => void; released: Promise<void> }>();
  const gateway = startDynamicFakeGateway(async (body) => {
    const token = [...body.matchAll(/Grid token (\w+)\./g)].at(-1)?.[1];
    if (token === undefined) return fakeGatewayFinalText("GRID_NO_TOKEN");
    const hold = holds.get(token);
    if (hold) {
      hold.reached();
      await hold.released;
    }
    return fakeGatewayFinalText(`GRID_ANSWER_${token}`);
  });
  const hold = (token: string) => {
    let reached: () => void = () => {};
    let release: () => void = () => {};
    const reachedHold = new Promise<void>((resolve) => (reached = resolve));
    holds.set(token, { reached, released: new Promise<void>((resolve) => (release = resolve)) });
    return { reached: reachedHold, release };
  };
  /// The request that asked for `token`, if one reached the gateway.
  const asked = (token: string) =>
    gateway.requests.filter((request: any) => [...request.body.matchAll(/Grid token (\w+)\./g)].at(-1)?.[1] === token).at(-1)?.body as string | undefined;
  return { gateway, hold, asked };
}

/// `harness` holds the test's own files, never on a full disk.
type GridCase = { fixture: Fixture; id: string; log: string; harness: string };

/// A fresh copy of a base home as `under/name`, modes kept, with its
/// harness folder in `outside`.
function gridCopy(base: { fixture: Fixture; id: string }, under: string, outside: string, name: string): GridCase {
  const root = join(under, name);
  const harness = join(outside, `${name}-harness`);
  mkdirSync(root);
  mkdirSync(harness);
  const copied = Bun.spawnSync(["cp", "-Rp", base.fixture.home, join(root, "home")]);
  if (copied.exitCode !== 0) throw new Error(`cp: ${copied.stderr}`);
  const fixture = { root, home: realpathSync(join(root, "home")), workspace: base.fixture.workspace };
  return { fixture, id: base.id, log: join(v2Root(fixture), base.id, "log.jsonl"), harness };
}

/// A small HFS+ disk image mounted at `mountpoint`, which `fillDisk` fills.
function attachDiskImage(image: string, mountpoint: string) {
  const made = Bun.spawnSync(["hdiutil", "create", "-size", "24m", "-fs", "HFS+", "-volname", "fxgrid", "-layout", "NONE", image]);
  if (made.exitCode !== 0) throw new Error(`hdiutil create: ${made.stderr}`);
  mkdirSync(mountpoint, { recursive: true });
  const attached = Bun.spawnSync(["hdiutil", "attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountpoint, image]);
  if (attached.exitCode !== 0) throw new Error(`hdiutil attach: ${attached.stderr}`);
  return () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      if (Bun.spawnSync(["hdiutil", "detach", "-force", mountpoint]).exitCode === 0) return;
      Bun.sleepSync(200);
    }
  };
}

function fillDisk(mountpoint: string) {
  Bun.spawnSync(["/bin/sh", "-c", `head -c 100000000 /dev/zero > '${mountpoint}/.filler' 2>/dev/null; true`]);
}

type GridAttempt = { entered: boolean; said: string };

/// Enters the case through `entry` and asks for `token`. Under `limit`, the
/// host runs with that file-size limit.
async function gridEnter(entry: GridEntry, c: GridCase, gateway: any, token: string, limit?: number): Promise<GridAttempt> {
  const prompt = `Grid token ${token}.`;
  const answer = `GRID_ANSWER_${token}`;
  switch (gridHost(entry)) {
    case "ask": {
      const args = entry === "ask-id" ? ["--resume-id", c.id, prompt] : entry === "ask-last" ? ["--resume", "last", prompt] : [prompt];
      const result = limit === undefined ? await ask(c.fixture, gateway, args) : await askWithSizeLimit(c.fixture, gateway, limit, args);
      let json: any;
      try {
        json = JSON.parse(result.stdout);
      } catch {}
      return { entered: result.code === 0 && json?.output === answer, said: `${json?.error ?? ""} ${result.stderr}` };
    }
    case "app": {
      const args = entry === "app-id" ? `--resume ${c.id}` : entry === "app-last" ? "-c" : "";
      const stderrPath = join(c.harness, `stderr-${token}.log`);
      writeFileSync(stderrPath, "");
      let cmd = `${FX_BIN} --sessions-v2 ${args}`;
      if (limit !== undefined) {
        cmd = join(c.harness, `limited-${token}.sh`);
        writeFileSync(cmd, `#!/bin/sh\ntrap '' XFSZ\nulimit -f ${limit}\nexec '${FX_BIN}' --sessions-v2 ${args}\n`, { mode: 0o700 });
      }
      const session = await TmuxSession.create({ cmd, cwd: c.fixture.workspace, env: { ...env(c.fixture, gateway, false), NO_COLOR: "1" }, stderrPath, remainOnExit: true });
      // The pane stays after fx exits, so its end is the pane dying.
      const exit = async (what: string) => {
        const deadline = Date.now() + TIMEOUT;
        while (!session.paneStatus().dead) {
          if (Date.now() > deadline) throw new Error(`${entry}: the app did not exit ${what}`);
          await Bun.sleep(50);
        }
      };
      try {
        // Either the composer shows or the app refuses and exits.
        let settled = false;
        const died = (async () => {
          while (!settled && !session.paneStatus().dead) await Bun.sleep(50);
          return "exited";
        })();
        let started = await Promise.race([session.waitForComposer(TIMEOUT).then(() => "composer", () => "neither"), died]);
        settled = true;
        if (started === "neither" && session.paneStatus().dead) started = "exited";
        if (started === "exited") return { entered: false, said: readFileSync(stderrPath, "utf8") };
        if (started === "neither") throw new Error(`${entry}: the app neither showed its composer nor exited`);
        await session.waitForStableComposer(TIMEOUT, 300);
        await session.sendText(prompt);
        let screen = "";
        const deadline = Date.now() + TIMEOUT;
        while (Date.now() < deadline) {
          screen = await session.captureFullScrollback();
          if (screen.includes(answer) || /✗ .*|could not save/.test(screen.slice(screen.lastIndexOf(prompt)))) break;
          await Bun.sleep(100);
        }
        // The reply shows even when saving it fails, so read the turn's end.
        await session.waitForComposer(TIMEOUT);
        screen = await session.captureFullScrollback();
        const turn = screen.slice(screen.lastIndexOf(prompt));
        await session.sendText("/quit");
        await exit("after /quit");
        return { entered: turn.includes(answer) && !/✗ |could not save/.test(turn), said: `${turn}\n${readFileSync(stderrPath, "utf8")}` };
      } finally {
        await session.kill();
      }
    }
    case "acp": {
      const client = await AcpRpc.start(c.fixture, gateway, {}, limit);
      try {
        let sessionId = c.id;
        if (entry === "acp-new") {
          const created = await client.request("session/new", { cwd: c.fixture.workspace, mcpServers: [] });
          if (created.error) return { entered: false, said: created.error.message };
          sessionId = created.result.sessionId;
        } else {
          const method = entry === "acp-load" ? "session/load" : "session/resume";
          const opened = await client.request(method, { sessionId, cwd: c.fixture.workspace, mcpServers: [] });
          if (opened.error) return { entered: false, said: opened.error.message };
        }
        const prompted = await client.request("session/prompt", { sessionId, ...acpPrompt(prompt) });
        if (prompted.error) return { entered: false, said: prompted.error.message };
        return { entered: client.texts("agent_message_chunk").join("").includes(answer), said: "" };
      } finally {
        await client.close();
      }
    }
  }
}

/// The history an entered session must show the model, by how the run left it.
function expectGridHistory(exit: GridExit, body: string, label: string) {
  // The blob comes back whole.
  expect(body, label).toContain("GRID_BIG_END");
  if (exit === "committed") expect(body, label).toContain("GRID_SECOND_ANSWER");
  else expect(body, label).toContain("Grid second.");
  if (exit === "crashed-mid-tool") {
    // Every call keeps a result: the finished one its own, the running
    // one an answer that it may have partly run.
    expectPairedToolCalls(body);
    expect(body, label).toContain("GRID_FAST_TOOL_OUTPUT");
    expect(body, label).toContain("may have partly run");
  }
}

/// A refused entry leaves the log as it was, except a lost blob: like a bad
/// line that open does not read, it is found by the history read after a
/// writable open, so that open has already ended a crashed turn, and its
/// close is written (D39).
function expectLogKept(faulted: Buffer, after: Buffer, exit: GridExit, fault: GridFault, label: string) {
  if (fault !== "lost-blob") return expect(after.equals(faulted), `${label} log unchanged`).toBe(true);
  expect(after.subarray(0, faulted.length).equals(faulted), `${label} log kept`).toBe(true);
  const added = after.subarray(faulted.length).toString("utf8").trimEnd().split("\n").filter(Boolean).map((line) => JSON.parse(line).kind);
  expect(added, label).toEqual(exit.startsWith("crashed") ? ["turn_interrupted", "closed"] : ["closed"]);
}

let gridTokens = 0;

/// One exit through one entry under every fault.
async function gridRow(exit: GridExit, entry: GridEntry) {
  const host = gridHost(entry);
  const base = await gridBase(exit, entry === "app-last" ? "app" : "ask");
  const under = mkdtempSync(join(tmpdir(), `fx-v2-grid-${exit}-${entry}-`));
  const { gateway, hold, asked } = gridGateway();
  const volume = join(under, "volume");
  const detach = REAL_FULL_DISK ? attachDiskImage(join(under, "disk.dmg"), volume) : () => {};
  try {
    for (const fault of GRID_FAULTS) {
      const label = `${exit} / ${fault} / ${entry}`;
      const c = gridCopy(base, fault === "full-disk" && REAL_FULL_DISK ? volume : under, under, fault);
      const token = `T${++gridTokens}`;
      const retry = `T${++gridTokens}`;
      let limit: number | undefined;
      let clear: () => Promise<void> = async () => {};
      let holder: ReturnType<typeof spawnAsk> | undefined;
      switch (fault) {
        case "torn-tail":
          tearTail(c.fixture, c.id);
          break;
        case "flipped-byte":
          flipMiddleByte(c.log);
          break;
        case "lost-blob": {
          const referenced = (logLines(c.fixture, c.id) as any[]).find((line) => Array.isArray(line.blobs) && line.blobs.length > 0);
          rmSync(join(v2Root(c.fixture), c.id, "blobs", referenced.blobs[0]));
          break;
        }
        case "read-only": {
          const folder = join(v2Root(c.fixture), c.id);
          chmodSync(c.log, 0o400);
          chmodSync(folder, 0o500);
          clear = async () => {
            chmodSync(folder, 0o700);
            chmodSync(c.log, 0o600);
          };
          break;
        }
        case "full-disk":
          if (REAL_FULL_DISK) {
            fillDisk(volume);
            clear = async () => rmSync(join(volume, ".filler"));
          } else {
            limit = blocksJustPast(c.log);
            clear = async () => {
              limit = undefined;
            };
          }
          break;
        case "busy": {
          const held = hold(`H${token}`);
          holder = spawnAsk(c.fixture, gateway, ["--resume-id", c.id, `Grid token H${token}.`]);
          await held.reached;
          clear = async () => {
            held.release();
            await holder!.exited;
          };
          break;
        }
      }
      const faulted = readFileSync(c.log);
      try {
        const first = await gridEnter(entry, c, gateway, token, limit);
        if (fault === "none" || fault === "torn-tail") {
          expect(first.entered, `${label}: ${first.said}`).toBe(true);
          expectGridHistory(exit, asked(token)!, label);
        } else if (fault === "full-disk" && first.entered) {
          // Every write fit in space its files already held; nothing is lost.
          expectGridHistory(exit, asked(token)!, label);
        } else {
          expect(first.entered, `${label} entered`).toBe(false);
          const cause = fault === "flipped-byte" || fault === "lost-blob" ? "damaged" : fault === "read-only" ? "denied" : fault === "full-disk" ? "full" : "busy";
          expect(first.said.trim(), label).toMatch(GRID_SAYS[cause][host]);
          if (cause === "damaged" || cause === "denied" || cause === "busy") {
            // Refused before the model: nothing asked, nothing written.
            expect(asked(token), label).toBeUndefined();
            if (cause !== "busy") expectLogKept(faulted, readFileSync(c.log), exit, fault, label);
          }
          if (cause !== "damaged") {
            await clear();
            clear = async () => {};
            const second = await gridEnter(entry, c, gateway, retry, limit);
            expect(second.entered, `${label} after the fault cleared: ${second.said}`).toBe(true);
            expectGridHistory(exit, asked(retry)!, `${label} after the fault cleared`);
          }
        }
        if (fault !== "flipped-byte" && fault !== "lost-blob") {
          const tail = readFileSync(c.log).subarray(-160);
          expect(tail.at(-1), `${label}: the log ends in ${JSON.stringify(tail.toString("utf8"))}`).toBe(0x0a);
          expectWholeLog(c.fixture, c.id);
          const reasons = logLines(c.fixture, c.id).filter((line) => line.kind === "turn_interrupted").map((line) => line.reason);
          if (exit === "cancelled") expect(reasons, label).toContain("cancel");
          if (exit === "crashed" || exit === "crashed-mid-tool") expect(reasons, label).toContain("crash");
          expect(logLines(c.fixture, c.id).map((line) => line.kind).at(-1), label).toBe("closed");
        }
      } finally {
        await clear();
        if (holder) await holder.exited;
        rmSync(c.fixture.root, { recursive: true, force: true });
        rmSync(c.harness, { recursive: true, force: true });
      }
    }
  } finally {
    gateway.stop();
    detach();
    rmSync(under, { recursive: true, force: true });
  }
}

/// A new session beside a saved one, with nothing wrong, with the sessions
/// folder read-only, and on a full disk. A refused turn creates nothing.
async function gridNewRow(entry: GridEntry) {
  const host = gridHost(entry);
  const base = await gridBase("committed", "ask");
  const under = mkdtempSync(join(tmpdir(), `fx-v2-grid-${entry}-`));
  const { gateway, asked } = gridGateway();
  const volume = join(under, "volume");
  const detach = REAL_FULL_DISK ? attachDiskImage(join(under, "disk.dmg"), volume) : () => {};
  try {
    for (const fault of ["none", "read-only", "full-disk"] as const) {
      const label = `new / ${fault} / ${entry}`;
      const c = gridCopy(base, fault === "full-disk" && REAL_FULL_DISK ? volume : under, under, fault);
      const root = v2Root(c.fixture);
      const token = `T${++gridTokens}`;
      const retry = `T${++gridTokens}`;
      let limit: number | undefined;
      let clear: () => void = () => {};
      if (fault === "read-only") {
        chmodSync(root, 0o500);
        clear = () => chmodSync(root, 0o700);
      } else if (fault === "full-disk" && REAL_FULL_DISK) {
        fillDisk(volume);
        clear = () => rmSync(join(volume, ".filler"));
      } else if (fault === "full-disk") {
        // Room for the new log's first lines, not for the turn.
        limit = 1;
        clear = () => {
          limit = undefined;
        };
      }
      const sessions = () => readdirSync(root).filter((name) => /^[A-Za-z0-9_-]{12}$/.test(name) && name !== c.id);
      try {
        const first = await gridEnter(entry, c, gateway, token, limit);
        if (fault === "none" || (fault === "full-disk" && first.entered)) {
          expect(first.entered, `${label}: ${first.said}`).toBe(true);
        } else {
          expect(first.entered, `${label} entered`).toBe(false);
          expect(first.said.trim(), label).toMatch(GRID_SAYS[fault === "read-only" ? "denied" : "full"][host]);
          if (fault === "read-only") expect(sessions(), `${label} created nothing`).toEqual([]);
          clear();
          clear = () => {};
          const second = await gridEnter(entry, c, gateway, retry, limit);
          expect(second.entered, `${label} after the fault cleared: ${second.said}`).toBe(true);
        }
        // A new session: none of the saved one's history.
        expect(asked(first.entered ? token : retry), label).not.toContain("GRID_BIG_END");
        const created = sessions();
        expect(created.length, label).toBeGreaterThan(0);
        for (const id of created) expectWholeLog(c.fixture, id);
        expect(readFileSync(c.log, "utf8"), label).not.toContain("Grid token");
      } finally {
        clear();
        rmSync(c.fixture.root, { recursive: true, force: true });
        rmSync(c.harness, { recursive: true, force: true });
      }
    }
  } finally {
    gateway.stop();
    detach();
    rmSync(under, { recursive: true, force: true });
  }
}

for (const entry of ["ask-new", "app-new", "acp-new"] as const) {
  const define = gridHost(entry) === "app" ? test.skipIf(!tmuxAvailable()) : test;
  define(`fault grid: a new session by ${entry.slice(0, -4)}, with nothing wrong, a read-only folder and a full disk`, () => gridNewRow(entry), TIMEOUT * 6);
}

for (const exit of GRID_EXITS) {
  for (const entry of GRID_ENTRIES) {
    const define = gridHost(entry) === "app" ? test.skipIf(!tmuxAvailable()) : test;
    define(`fault grid: a session ${exit}, entered by ${entry}, under every fault`, () => gridRow(exit, entry), TIMEOUT * 10);
  }
}
