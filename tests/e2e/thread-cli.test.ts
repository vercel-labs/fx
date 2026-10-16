import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 15_000;
const ROOT_ID = "thread-root";
const ALPHA_SESSION = "thread-alpha-session";
const BETA_SESSION = "thread-beta-session";
const SAVED_NOTE =
  "saved state; live state is only visible inside the running fx session";

type Fixture = { root: string; home: string; workspace: string };

function sessionDir(fixture: Fixture, id: string): string {
  return join(fixture.home, ".fx", "sessions", id);
}

function writeConversation(
  fixture: Fixture,
  id: string,
  opts: { child?: boolean; replies?: string[]; updatedAtMs?: number },
): void {
  const dir = sessionDir(fixture, id);
  const updated = opts.updatedAtMs ?? 2;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(join(fixture.home, ".fx"), 0o700);
  chmodSync(join(fixture.home, ".fx", "sessions"), 0o700);
  chmodSync(dir, 0o700);
  writeFileSync(
    join(dir, "session.json"),
    JSON.stringify({
      schema_version: 4,
      id,
      origin_workspace_root: fixture.workspace,
      workspace_root: fixture.workspace,
      created_at_ms: 1,
      updated_at_ms: updated,
      conversation_language: "en",
      provider: "gateway",
      model: "openai/gpt-5.5",
      effort: "auto",
      fast_mode: false,
      title: null,
      subagent_child: opts.child ?? false,
    }) + "\n",
    { mode: 0o600 },
  );
  let seq = 0;
  const frames: string[] = [];
  const append = (event: object): void => {
    seq += 1;
    frames.push(
      JSON.stringify({ schema_version: 1, seq, timestamp_ms: updated, event }),
    );
  };
  for (const reply of opts.replies ?? []) {
    append({ user: { text: "task", images: [], work_id: null } });
    append({ assistant: { text: reply } });
    append({ turn_completed: {} });
  }
  const events = join(dir, "events.jsonl");
  writeFileSync(events, frames.length ? `${frames.join("\n")}\n` : "", {
    mode: 0o600,
  });
  utimesSync(events, updated / 1000, updated / 1000);
  writeFileSync(join(dir, "session.lock"), "", { mode: 0o600 });
}

function writeChildState(
  fixture: Fixture,
  children: { id: string; agent: string; phase: string; outcome: string | null }[],
): void {
  const control = join(sessionDir(fixture, ROOT_ID), "subagent");
  mkdirSync(control, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(control, "children.json"),
    JSON.stringify({
      schema_version: 2,
      parent_id: ROOT_ID,
      generation: 1,
      children: children.map((child) => ({
        id: child.id,
        kind: "persistent",
        persistent: { agent: child.agent, instructions: "" },
        phase: child.phase,
        work_generation: 1,
        active: null,
        last_work_id: null,
        last_request_fingerprint: null,
        last_outcome: child.outcome,
        last_failure: null,
      })),
    }),
    { mode: 0o600 },
  );
  for (const child of children) {
    const childControl = join(sessionDir(fixture, child.id), "subagent");
    mkdirSync(childControl, { recursive: true, mode: 0o700 });
    writeFileSync(
      join(childControl, "owner.json"),
      JSON.stringify({ schema_version: 1, parent_id: ROOT_ID }),
      { mode: 0o600 },
    );
  }
}

function writeThreadList(
  fixture: Fixture,
  threads: { name: string; agent: string; session_id: string }[],
): void {
  const dir = join(fixture.home, ".fx", "threads");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(dir, `${ROOT_ID}.json`),
    JSON.stringify({
      schema_version: 1,
      root_id: ROOT_ID,
      threads: threads.map((thread) => ({ ...thread, created_at_ms: 10 })),
    }),
    { mode: 0o600 },
  );
}

function withFixture(
  body: (fixture: Fixture) => Promise<void>,
): () => Promise<void> {
  return async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-thread-cli-")));
    try {
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx", "sessions"), { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      const fixture = { root, home, workspace: realpathSync(workspace) };

      // The root session, one thread that ran and one that never started.
      writeConversation(fixture, ROOT_ID, { replies: ["main reply"], updatedAtMs: 100 });
      writeConversation(fixture, ALPHA_SESSION, {
        child: true,
        replies: ["first answer", "alpha final answer\nwith AI_GATEWAY_API_KEY=abcdefghijklmnop\nplain \x1b[31mred"],
      });
      writeChildState(fixture, [
        { id: ALPHA_SESSION, agent: "th-1-alpha", phase: "idle", outcome: "completed" },
      ]);
      writeThreadList(fixture, [
        { name: "alpha", agent: "th-1-alpha", session_id: ALPHA_SESSION },
        { name: "beta", agent: "th-2-beta", session_id: "" },
      ]);
      await body(fixture);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };
}

function run(fixture: Fixture, args: string[], env: Record<string, string> = {}) {
  return runFx(args, {
    cwd: fixture.workspace,
    env: { HOME: fixture.home, FX_DISABLE_KEYCHAIN: "1", ...env },
    timeoutMs: TIMEOUT,
  });
}

describe("cli: thread", () => {
  test(
    "fx thread lists the threads of the latest session as text",
    withFixture(async (fixture) => {
      const result = await run(fixture, ["thread"]);
      expect(result).toMatchObject({ code: 0, stderr: "" });
      expect(result.stdout).toBe(
        `[threads] ${ROOT_ID} 2 saved\nnote: ${SAVED_NOTE}\n` +
          "  alpha  idle  completed\n  beta  not_started\n",
      );

      const explicit = await run(fixture, ["thread", "list", ROOT_ID]);
      expect(explicit.stdout).toBe(result.stdout);
    }),
    TIMEOUT,
  );

  test(
    "fx thread --json lists threads with a stable kind",
    withFixture(async (fixture) => {
      const result = await run(fixture, ["thread", ROOT_ID, "--json"]);
      expect(result).toMatchObject({ code: 0, stderr: "" });
      expect(JSON.parse(result.stdout)).toEqual({
        kind: "threads",
        session_id: ROOT_ID,
        state_source: "saved",
        threads: [
          {
            name: "alpha",
            session_id: ALPHA_SESSION,
            state: "idle",
            last_outcome: "completed",
          },
          { name: "beta", session_id: null, state: "not_started", last_outcome: null },
        ],
      });
    }),
    TIMEOUT,
  );

  test(
    "fx thread show prints state, masked last reply, and turn count",
    withFixture(async (fixture) => {
      const result = await run(fixture, ["thread", "show", "alpha"]);
      expect(result).toMatchObject({ code: 0, stderr: "" });
      expect(result.stdout).toContain("[thread] alpha\n");
      expect(result.stdout).toContain(`session: ${ROOT_ID}\n`);
      expect(result.stdout).toContain(`thread_session: ${ALPHA_SESSION}\n`);
      expect(result.stdout).toContain("state: idle\n");
      expect(result.stdout).toContain(`note: ${SAVED_NOTE}\n`);
      expect(result.stdout).toContain("last_outcome: completed\n");
      expect(result.stdout).toContain("turns: 2\n");
      expect(result.stdout).toContain(
        "alpha final answer\nwith AI_GATEWAY_API_KEY=[redacted]\nplain \\x1b[31mred\n",
      );
      expect(result.stdout).not.toContain("abcdefghijklmnop");
      expect(result.stdout).not.toContain("first answer");
      expect(result.stdout).not.toContain("\x1b");
    }),
    TIMEOUT,
  );

  test(
    "fx thread show --json reports a thread that never started",
    withFixture(async (fixture) => {
      const alpha = await run(fixture, ["thread", "show", "alpha", ROOT_ID, "--json"]);
      expect(alpha).toMatchObject({ code: 0, stderr: "" });
      const alphaJson = JSON.parse(alpha.stdout);
      expect(alphaJson).toMatchObject({
        kind: "thread",
        session_id: ROOT_ID,
        name: "alpha",
        thread_session_id: ALPHA_SESSION,
        state_source: "saved",
        state: "idle",
        last_outcome: "completed",
        turns: 2,
        last_reply_truncated: false,
      });
      expect(alphaJson.last_reply).toContain("alpha final answer");
      expect(alphaJson.last_reply).toContain("AI_GATEWAY_API_KEY=[redacted]");
      expect(alpha.stdout).not.toContain("abcdefghijklmnop");

      const beta = await run(fixture, ["thread", "show", "beta", "--json"]);
      expect(beta).toMatchObject({ code: 0, stderr: "" });
      expect(JSON.parse(beta.stdout)).toEqual({
        kind: "thread",
        session_id: ROOT_ID,
        name: "beta",
        thread_session_id: null,
        state_source: "saved",
        state: "not_started",
        last_outcome: null,
        turns: 0,
        last_reply: null,
        last_reply_truncated: false,
      });
    }),
    TIMEOUT,
  );

  test(
    "fx thread reports the saved state honestly, such as interrupted",
    withFixture(async (fixture) => {
      writeChildState(fixture, [
        { id: ALPHA_SESSION, agent: "th-1-alpha", phase: "interrupted", outcome: "interrupted" },
      ]);
      const result = await run(fixture, ["thread", "show", "alpha", "--json"]);
      expect(JSON.parse(result.stdout)).toMatchObject({
        state: "interrupted",
        last_outcome: "interrupted",
      });
    }),
    TIMEOUT,
  );

  test(
    "fx thread rejects unknown sessions, unknown threads, and bad arguments",
    withFixture(async (fixture) => {
      const missingSession = await run(fixture, ["thread", "no-such-session", "--json"]);
      expect(missingSession.code).toBe(1);
      expect(JSON.parse(missingSession.stdout)).toEqual({
        kind: "threads",
        error: "record not found",
        code: "SessionNotFound",
      });
      const missingText = await run(fixture, ["thread", "no-such-session"]);
      expect(missingText.code).toBe(1);
      expect(missingText.stdout).toBe("");
      expect(missingText.stderr).toBe("fx thread: record not found\n");

      // A thread's own session is a managed child, not a root.
      const child = await run(fixture, ["thread", ALPHA_SESSION, "--json"]);
      expect(child.code).toBe(1);
      expect(JSON.parse(child.stdout).code).toBe("SessionNotFound");

      const missingThread = await run(fixture, ["thread", "show", "nope", "--json"]);
      expect(missingThread.code).toBe(1);
      expect(JSON.parse(missingThread.stdout)).toEqual({
        kind: "thread",
        error: "thread not found in that session",
        code: "ThreadNotFound",
      });
      const missingThreadText = await run(fixture, ["thread", "show", "nope"]);
      expect(missingThreadText.code).toBe(1);
      expect(missingThreadText.stderr).toBe("fx thread: thread not found in that session\n");

      const noName = await run(fixture, ["thread", "show"]);
      expect(noName.code).toBe(1);
      expect(noName.stderr).toContain("usage: fx thread");
      const noNameJson = await run(fixture, ["thread", "show", "--json"]);
      expect(noNameJson.code).toBe(1);
      expect(JSON.parse(noNameJson.stdout)).toEqual({
        kind: "thread",
        error: "invalid arguments",
        code: "InvalidThreadArgs",
      });
      const extra = await run(fixture, ["thread", "list", "a", "b"]);
      expect(extra.code).toBe(1);
      expect(extra.stderr).toContain("usage: fx thread");
    }),
    TIMEOUT,
  );

  test(
    "fx thread needs the default session format",
    withFixture(async (fixture) => {
      const flag = await run(fixture, ["--sessions-v2", "thread", "--json"]);
      expect(flag.code).toBe(1);
      expect(JSON.parse(flag.stdout)).toEqual({
        kind: "threads",
        error: "threads need the default session format; run without --sessions-v2",
        code: "ThreadsNeedDefaultSessionFormat",
      });
      const env = await run(fixture, ["thread", "show", "alpha"], { FX_SESSIONS_V2: "1" });
      expect(env.code).toBe(1);
      expect(env.stderr).toBe(
        "fx thread: threads need the default session format; run without --sessions-v2\n",
      );
    }),
    TIMEOUT,
  );

  test(
    "fx thread --help says it shows saved state only",
    async () => {
      const result = await runFx(["thread", "--help"], { timeoutMs: TIMEOUT });
      expect(result).toMatchObject({ code: 0, stderr: "" });
      expect(result.stdout).toContain("cannot show live state");
      expect(result.stdout).toContain("thread show <name>");
    },
    TIMEOUT,
  );
});
