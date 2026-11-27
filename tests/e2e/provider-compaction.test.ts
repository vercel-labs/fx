import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Body, Message, ProviderGatewayOptions } from "./provider-compaction-gateway";
import { compactionRecordPath } from "./saved-sessions";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const { FAMILIES, isCompactionRequest, isFxSummaryRequest, lastUserText, leadingSystem, startProviderGateway, withoutCacheMarkers, blockKeyOf } = await import("./provider-compaction-gateway");
const { TmuxSession, tmuxAvailable } = await import("./tmux-helpers");
type Gateway = ReturnType<typeof startProviderGateway>;
const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");

// Claude 4.6 and later, and OpenAI GPT-6 and later, bind each reply's
// reasoning to everything sent before it. fx compacts their conversations with
// the provider's own summary block: the older turns go to the provider exactly
// as they were sent, its block takes their place, and the newest turns follow
// it unchanged. provider-compaction-gateway.ts answers the compaction request
// with frames recorded from AI Gateway, reads that block as the turns it stands
// for, and answers any signed reasoning sent after a changed prefix with the
// provider's 400. When the provider does not give a block, fx writes its own
// summary and keeps no turn after it.

const OLDER_TEXT = "Older turn detail that only the summary keeps. ".repeat(4_200);

/** A ThreadSanitizer build of fx reads its options from the environment;
 * passing them on lets a race check collect every report. */
function sanitizerOptions(): Record<string, string> {
  return process.env.TSAN_OPTIONS ? { TSAN_OPTIONS: process.env.TSAN_OPTIONS } : {};
}

type Session = {
  root: string;
  home: string;
  cwd: string;
  env: Record<string, string>;
  sessionId: string;
  /** What the sixth turn's request sent from turn 1 on. */
  sixthConversation: Message[];
  /** The kept turns as the sixth turn's request sent them. fx keeps four
   * turns, the one in progress counted (window.zig max_kept_turns), so turns
   * 4 to 6 stay and turn 7 follows them. */
  sixthTurns: Message[];
  /** Requests before the seventh turn. */
  before: number;
};

function fixture(model: string) {
  const root = mkdtempSync(join(tmpdir(), `fx-provider-compaction-${model.replace(/\W+/g, "-")}-`));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  return { root, home, cwd };
}

async function ask(env: Record<string, string>, cwd: string, root: string, label: string, args: string[], prompt: string, onChild?: (child: ReturnType<typeof Bun.spawn>) => void) {
  const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
  const child = Bun.spawn([binary, "ask", "--json", "--full-access", ...args, prompt], { cwd, env, stdin: "ignore", stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
  onChild?.(child);
  const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
  try {
    const code = await child.exited;
    return { code, json: code === 0 ? JSON.parse(readFileSync(stdout, "utf8")) : null, stderr: readFileSync(stderr, "utf8") };
  } finally {
    clearTimeout(timer);
  }
}

/** Turns 1 and 2 are large, turn 4 runs a shell call, the rest answer. */
function step(request: { body: Body }) {
  const turn = Number(lastUserText(request.body).match(/TURN (\d+)/)?.[1] ?? 0);
  const toolResult = request.body.prompt.at(-1)?.role === "tool";
  if (turn === 4 && !toolResult) return { kind: "tool" as const };
  return { kind: "final" as const, text: turn <= 2 ? `Turn ${turn} done. ${OLDER_TEXT}` : `Turn ${turn} done.` };
}

/**
 * A session of six turns on `model` through the fake gateway, then `body`
 * with it. The gateway's evidence is kept when `body` fails.
 */
async function withSession(model: string, options: Partial<ProviderGatewayOptions>, body: (session: Session, gateway: Gateway) => Promise<void>, turnArgs: (turn: number) => string[] = () => []) {
  const { root, home, cwd } = fixture(model);
  const started = startProviderGateway({
    models: [{ id: model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }],
    defaultModel: model,
    step,
    compaction: () => ({ kind: "block" }),
    ...options,
  });
  const { gateway, edits, observed, counts } = started;
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    ...sanitizerOptions(),
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model, FX_TRACE_LOG: join(root, "trace.log"),
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let passed = false;
  try {
    const first = await ask(env, cwd, root, "t1", turnArgs(1), "TURN 1 Start the work.");
    expect(first.code).toBe(0);
    const sessionId: string = first.json.session_id;
    for (let turn = 2; turn <= 6; turn += 1) {
      const next = await ask(env, cwd, root, `t${turn}`, ["--resume", sessionId, ...turnArgs(turn)], `TURN ${turn} Continue.`);
      expect(next.code).toBe(0);
    }
    const sixth = observed.at(-1)!.body;
    const sixthConversation = sixth.prompt.slice(leadingSystem(sixth.prompt), -1);
    const sixthTurns = sixth.prompt.slice(sixth.prompt.findIndex((message) => message.role === "user" && JSON.stringify(message.content).includes("TURN 4")));
    await body({ root, home, cwd, env, sessionId, sixthConversation, sixthTurns, before: observed.length }, started);
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else {
      writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request) => request.body), null, 1));
      console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
    }
  }
}

/** The first agent request whose newest user message names `turn`. */
function agentRequestFor(observed: { body: Body }[], from: number, turn: number) {
  return observed.slice(from).map((request) => request.body).find((body) => !isCompactionRequest(body) && !isFxSummaryRequest(body) && lastUserText(body).includes(`TURN ${turn}`));
}

function conversationOf(body: Body): Message[] {
  return body.prompt.slice(leadingSystem(body.prompt));
}

function isFxSummary(message: Message): boolean {
  return message.role === "user" && JSON.stringify(message.content).includes("<compacted_conversation>");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function trace(root: string): string {
  return existsSync(join(root, "trace.log")) ? readFileSync(join(root, "trace.log"), "utf8") : "";
}

describe("provider compaction", () => {
  for (const family of Object.values(FAMILIES)) {
    test(`a ${family.name} compaction sends the provider's block, then the newest turns unchanged`, async () => {
      await withSession(family.model, {}, async (session, { observed, counts, edits }) => {
        const { root, home, cwd, env, sessionId, sixthTurns, before } = session;
        const seventh = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 What did the first turns cover?");
        expect(seventh.code).toBe(0);
        expect({ provider: counts.provider, fx: counts.fx }).toEqual({ provider: 1, fx: 0 });

        const compactionRequest = observed.slice(before).find((request) => request.kind === "compaction")!;
        const compaction = compactionRequest.body;
        const after = agentRequestFor(observed, before, 7)!;
        // The compaction request keeps the conversation's instructions.
        expect(after.prompt.slice(0, leadingSystem(after.prompt)).map(withoutCacheMarkers)).toEqual(compaction.prompt.slice(0, leadingSystem(compaction.prompt)).map(withoutCacheMarkers));
        // The block comes first, then the kept turns exactly as sent.
        const conversation = conversationOf(after);
        expect(conversation[0]!.role).toBe("assistant");
        expect(blockKeyOf(conversation[0]!)).toBe(compactionRequest.block!);
        expect(conversation.slice(1, 1 + sixthTurns.length).map(withoutCacheMarkers)).toEqual(sixthTurns.map(withoutCacheMarkers));
        // The compacted turns stay saved word for word.
        expect(existsSync(compactionRecordPath(home, sessionId, "compacted-M1.txt") ?? "")).toBe(true);

        const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId], "TURN 8 Thanks.");
        expect(eighth.code).toBe(0);
        expect(edits).toEqual([]);
      });
    }, 240_000);
  }

  // Every way the provider can fail to give a block, each family in turn: fx
  // writes its own summary, keeps no turn after it, and says why in its trace.
  const failures = [
    { kind: "status", status: 400 },
    { kind: "status", status: 429 },
    { kind: "status", status: 500 },
    { kind: "no_block" },
    { kind: "answer" },
    { kind: "empty" },
    { kind: "cut" },
    { kind: "oversized" },
  ] as const;
  failures.forEach((failure, index) => {
    const family = index % 2 === 0 ? FAMILIES.anthropic : FAMILIES.openai;
    const name = failure.kind === "status" ? `a ${failure.status}` : failure.kind === "answer" ? "an answer" : `a ${failure.kind.replace("_", " ")} reply`;
    test(`${name} from the ${family.name} compaction ends with fx's summary and no kept turns`, async () => {
      await withSession(family.model, { compaction: () => failure }, async (session, { observed, counts, edits }) => {
        const { root, cwd, env, sessionId, before } = session;
        const seventh = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.");
        expect(seventh.code).toBe(0);
        expect(counts.provider).toBeGreaterThanOrEqual(1);
        const conversation = conversationOf(agentRequestFor(observed, before, 7)!);
        expect(conversation.length).toBe(2);
        expect(isFxSummary(conversation[0]!)).toBe(true);
        expect(JSON.stringify(conversation[1]!.content)).toContain("TURN 7");
        expect(trace(root)).toContain("event=provider_block_failed");
        const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId], "TURN 8 Thanks.");
        expect(eighth.code).toBe(0);
        expect(edits).toEqual([]);
      });
    }, 240_000);
  });

  // After a provider's block, GPT-6 runs at the request's own effort plus
  // the updates sent after the block, not at the effort the replaced turns
  // set (measured live). Each turn saves the update it sent, so the kept
  // turns keep their bytes, and a new turn decides against that (D103).
  const effortModels = (contextWindow: () => number) => (() => [{ id: FAMILIES.openai.model, type: "language", tags: ["tool-use", "reasoning"], context_window: contextWindow(), max_tokens: 8192, reasoning_options: [{ type: "effort", values: ["low", "medium", "high", "xhigh"] }] }]) as any;
  const effortUpdates = (body: Body) => body.prompt.flatMap((message, index) => {
    const value = (message.providerOptions as any)?.openai?.reasoningEffortUpdate;
    return value === undefined ? [] : [`${value} before ${lastUserText({ prompt: [body.prompt[index + 1]!] }).match(/TURN \d+/)?.[0]}`];
  });
  /** The effort the model runs at for the request's last user message: the
   * request's own, then each update in the prompt. */
  const runsAt = (body: Body & { reasoning?: string }) => {
    let effort = body.reasoning ?? "default";
    const last = body.prompt.map((message) => message.role).lastIndexOf("user");
    for (const message of body.prompt.slice(0, last)) {
      const value = (message.providerOptions as any)?.openai?.reasoningEffortUpdate;
      if (value !== undefined) effort = value;
    }
    return effort;
  };

  test("a GPT-6 block keeps the session's first effort, and the turn after its kept turns sets its own (D103)", async () => {
    // Turn 1 asks for high and turns 2 to 6 for low. The block replaces
    // turns 1 to 3 and keeps 4 to 6, which went out with no update.
    const model = FAMILIES.openai.model;
    await withSession(model, { models: effortModels(() => 400_000) }, async (session, { observed, counts, edits }) => {
      const { root, cwd, env, sessionId, sixthTurns, before } = session;
      const sixth = observed.at(-1)!.body as Body & { reasoning?: string };
      expect(sixth.reasoning).toBe("high");
      expect(effortUpdates(sixth)).toEqual(["low before TURN 2"]);
      const seventh = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId, "--effort", "low"], "TURN 7 What did the first turns cover?");
      expect(seventh.code).toBe(0);
      expect(counts.provider).toBe(1);

      const compaction = observed.slice(before).find((request) => request.kind === "compaction")!.body as Body & { reasoning?: string };
      expect(compaction.reasoning).toBe("high");
      expect(effortUpdates(compaction)).toEqual(["low before TURN 2"]);
      // After the block: the anchor, the kept turns exactly as sent, and the
      // new turn's own update, so it runs at low.
      const after = agentRequestFor(observed, before, 7)! as Body & { reasoning?: string };
      expect(after.reasoning).toBe("high");
      expect(conversationOf(after).slice(1, 1 + sixthTurns.length).map(withoutCacheMarkers)).toEqual(sixthTurns.map(withoutCacheMarkers));
      expect(effortUpdates(after)).toEqual(["low before TURN 7"]);
      expect(runsAt(after)).toBe("low");

      const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId, "--effort", "low"], "TURN 8 Thanks.");
      expect(eighth.code).toBe(0);
      const next = agentRequestFor(observed, before, 8)! as Body & { reasoning?: string };
      expect(next.reasoning).toBe("high");
      expect(next.prompt.slice(0, after.prompt.length)).toEqual(after.prompt);
      expect(effortUpdates(next)).toEqual(["low before TURN 7"]);
      expect(runsAt(next)).toBe("low");
      expect(edits).toEqual([]);
    }, (turn) => ["--effort", turn === 1 ? "high" : "low"]);
  }, 240_000);

  test("a second GPT-6 block keeps turns with and without their own update unchanged (D103)", async () => {
    // Block 1 replaces turns 1 and 2 and keeps 3 to 5, which went out with no
    // update; turn 6 is new after it and sends `low`. A smaller context window
    // makes turn 7 compact again, keeping turns from both kinds.
    const model = FAMILIES.openai.model;
    let contextWindow = 400_000;
    const { root, home, cwd } = fixture(model);
    const turnOf = (request: { body: Body }) => Number(lastUserText(request.body).match(/TURN (\d+)/)?.[1] ?? 0);
    const started = startProviderGateway({
      models: effortModels(() => contextWindow),
      defaultModel: model,
      step: (request) => ({ kind: "final" as const, text: turnOf(request) === 2 ? `Turn 2 done. ${OLDER_TEXT}` : `Turn ${turnOf(request)} done.` }),
      compaction: () => ({ kind: "block" }),
    });
    const { gateway, edits, observed, counts } = started;
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model, FX_TRACE_LOG: join(root, "trace.log"),
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    let passed = false;
    try {
      const first = await ask(env, cwd, root, "t1", ["--effort", "high"], "TURN 1 Start the work.");
      expect(first.code).toBe(0);
      const sessionId: string = first.json.session_id;
      for (let turn = 2; turn <= 7; turn += 1) {
        if (turn === 7) contextWindow = 60_000;
        const compact = turn >= 6 ? { FX_AUTO_COMPACT_PERCENT: "10" } : {};
        const next = await ask({ ...env, ...compact }, cwd, root, `t${turn}`, ["--resume", sessionId, "--effort", "low"], `TURN ${turn} Continue.`);
        expect(next.code).toBe(0);
      }
      expect(counts.provider).toBe(2);
      // Every turn runs at the effort it asked for, and every request names
      // the session's first effort.
      for (const request of observed.filter((request) => request.kind === "agent")) {
        const body = request.body as Body & { reasoning?: string };
        expect(body.reasoning).toBe("high");
        expect(runsAt(body)).toBe(turnOf(request) === 1 ? "high" : "low");
      }
      // The second block keeps turns from block 1's kept ones, which have no
      // update, and turn 6, which has its own, each as it was first sent.
      const last = observed.filter((request) => request.kind === "agent").at(-1)!.body;
      const kept = effortUpdates(last);
      expect(kept).toEqual(["low before TURN 6"]);
      expect(conversationOf(last).some((message) => message.role === "user" && JSON.stringify(message.content).includes("TURN 5"))).toBe(true);
      expect(edits).toEqual([]);
      passed = true;
    } finally {
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
      else {
        writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request) => request.body), null, 1));
        console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
      }
    }
  }, 240_000);

  // Turns 1 to 4 ask for high and turns 5 and 6 for low; turn 4's long reply
  // makes the block replace turns 1 to 4 and keep 5 and 6. Turn 5's update
  // rides after the block, so the model runs at low there, and turn 7, which
  // asks for high, must send its own update (D103).
  async function effortAfterKeptUpdate(compactAt: number) {
    const model = FAMILIES.openai.model;
    const { root, home, cwd } = fixture(model);
    const turnOf = (request: { body: Body }) => Number(lastUserText(request.body).match(/TURN (\d+)/)?.[1] ?? 0);
    const started = startProviderGateway({
      models: effortModels(() => 400_000),
      defaultModel: model,
      step: (request) => ({ kind: "final" as const, text: turnOf(request) === 4 ? `Turn 4 done. ${OLDER_TEXT}` : `Turn ${turnOf(request)} done.` }),
      compaction: () => ({ kind: "block" }),
    });
    const { gateway, edits, observed, counts } = started;
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model, FX_TRACE_LOG: join(root, "trace.log"),
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    const effortOf = (turn: number) => (turn <= 4 || turn >= 7 ? "high" : "low");
    let passed = false;
    try {
      const first = await ask(env, cwd, root, "t1", ["--effort", "high"], "TURN 1 Start the work.");
      expect(first.code).toBe(0);
      const sessionId: string = first.json.session_id;
      for (let turn = 2; turn <= 8; turn += 1) {
        const compact = turn === compactAt ? { FX_AUTO_COMPACT_PERCENT: "10" } : {};
        const next = await ask({ ...env, ...compact }, cwd, root, `t${turn}`, ["--resume", sessionId, "--effort", effortOf(turn)], `TURN ${turn} Continue.`);
        expect(next.code).toBe(0);
        if (turn === compactAt) expect(counts.provider).toBe(1);
      }
      expect(counts.provider).toBe(1);
      const agent = observed.filter((request) => request.kind === "agent");
      const seventh = agent.filter((request) => turnOf(request) === 7)[0]!.body as Body & { reasoning?: string };
      const users = conversationOf(seventh).filter((message) => message.role === "user").map((message) => JSON.stringify(message.content));
      // The block took turns 1 to 4 and kept 5 and 6.
      expect(users.some((text) => text.includes("TURN 4"))).toBe(false);
      expect(users.some((text) => text.includes("TURN 5"))).toBe(true);
      expect(seventh.reasoning).toBe("high");
      expect(effortUpdates(seventh)).toEqual(["low before TURN 5", "high before TURN 7"]);
      expect(runsAt(seventh)).toBe("high");
      // The next turn sends turn 7 as it was sent, and asks for high again,
      // so it adds nothing.
      const eighth = agent.filter((request) => turnOf(request) === 8)[0]!.body as Body & { reasoning?: string };
      expect(eighth.prompt.slice(0, seventh.prompt.length)).toEqual(seventh.prompt);
      expect(effortUpdates(eighth)).toEqual(["low before TURN 5", "high before TURN 7"]);
      expect(runsAt(eighth)).toBe("high");
      for (const request of agent) expect(runsAt(request.body as Body & { reasoning?: string })).toBe(effortOf(turnOf(request)));
      expect(edits).toEqual([]);
      passed = true;
    } finally {
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
      else {
        writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request) => request.body), null, 1));
        console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
      }
    }
  }

  test("a GPT-6 turn after a resumed block counts the update a kept turn saved (D103)", async () => {
    // Turn 6 compacts at its first request; turn 7 is a new process.
    await effortAfterKeptUpdate(6);
  }, 240_000);

  test("a GPT-6 turn that compacts at its first request counts the update a kept turn saved (D103)", async () => {
    // Turn 7 compacts at its first request and decides again in the same process.
    await effortAfterKeptUpdate(7);
  }, 240_000);

  test("a block written after a model switch keeps the other model's steps as their text", async () => {
    const models = Object.values(FAMILIES).map((family) => ({ id: family.model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }));
    await withSession(FAMILIES.anthropic.model, { models }, async (session, { observed, counts, edits }) => {
      const { root, cwd, env, sessionId, before } = session;
      // GPT-6.1 compacts and keeps Claude's turns 4 to 6, the shell call of
      // turn 4 among them. Back on Claude, GPT's block goes as fx's text, so
      // Claude's reasoning in those turns would follow a prefix it was never
      // written after: they go as text.
      const seventh = await ask({ ...env, FX_MODEL: FAMILIES.openai.model, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId, "--model", FAMILIES.openai.model], "TURN 7 Continue.");
      expect(seventh.code).toBe(0);
      expect(counts.provider).toBe(1);
      const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId, "--model", FAMILIES.anthropic.model], "TURN 8 Continue.");
      expect(eighth.code).toBe(0);
      const conversation = conversationOf(agentRequestFor(observed, before, 8)!);
      expect(isFxSummary(conversation[0]!)).toBe(true);
      expect(conversation.some((message) => message.role === "assistant" && JSON.stringify(message.content).includes("SIG_"))).toBe(false);
      expect(edits).toEqual([]);
    });
  }, 240_000);

  test("a fork of a provider-compacted session sends the block to its own model and fx's text to another", async () => {
    const models = Object.values(FAMILIES).map((family) => ({ id: family.model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }));
    await withSession(FAMILIES.anthropic.model, { models }, async (session, { observed, counts, edits }) => {
      const { root, cwd, env, sessionId, before } = session;
      const seventh = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.");
      expect(seventh.code).toBe(0);
      expect(counts.provider).toBe(1);
      const block = observed.slice(before).find((request) => request.kind === "compaction")!.block!;
      const seventhConversation = conversationOf(agentRequestFor(observed, before, 7)!);
      expect(blockKeyOf(seventhConversation[0]!)).toBe(block);

      const fork = async (label: string) => {
        const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
        const child = Bun.spawn([binary, "session", "fork", sessionId, "--json"], { cwd, env, stdin: "ignore", stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
        const code = await child.exited;
        expect(readFileSync(stderr, "utf8")).toBe("");
        expect(code).toBe(0);
        const forked = JSON.parse(readFileSync(stdout, "utf8"));
        expect(forked).toMatchObject({ kind: "session_fork", source_id: sessionId, files_complete: true });
        return forked.fork_id as string;
      };

      // The same model: the block leads, then the turns the compacting request sent, unchanged.
      const sameFork = await fork("fork-same-cli");
      const same = await ask(env, cwd, root, "fork-same", ["--resume", sameFork], "TURN 8 Continue.");
      expect(same.code).toBe(0);
      const sameConversation = conversationOf(agentRequestFor(observed, before, 8)!);
      expect(blockKeyOf(sameConversation[0]!)).toBe(block);
      expect(sameConversation.slice(0, seventhConversation.length).map(withoutCacheMarkers)).toEqual(seventhConversation.map(withoutCacheMarkers));

      // Another model: no block anywhere, and fx's text of the same turns first.
      const otherFork = await fork("fork-other-cli");
      const other = await ask({ ...env, FX_MODEL: FAMILIES.openai.model }, cwd, root, "fork-other", ["--resume", otherFork, "--model", FAMILIES.openai.model], "TURN 9 Continue.");
      expect(other.code).toBe(0);
      const otherRequest = observed.slice(before).find((request) => request.kind === "agent" && lastUserText(request.body).includes("TURN 9"))!;
      expect(otherRequest.model).toBe(FAMILIES.openai.model);
      const otherConversation = conversationOf(otherRequest.body);
      expect(otherConversation.some((message) => blockKeyOf(message) !== null)).toBe(false);
      expect(isFxSummary(otherConversation[0]!)).toBe(true);
      expect(edits).toEqual([]);
    });
  }, 240_000);

  test.skipIf(!tmuxAvailable())("/compact waits for the next message, then compacts with the provider before sending it", async () => {
    // The whole session runs in one terminal: the terminal's instructions
    // differ from fx ask's, and a change before the first turn would void
    // the reasoning on its own. /compact keeps the four newest turns, so six
    // short ones leave turns 1 to 3 to compact.
    const family = FAMILIES.anthropic;
    const { root, home, cwd } = fixture(family.model);
    const { gateway, edits, observed, counts } = startProviderGateway({
      models: [{ id: family.model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }],
      defaultModel: family.model,
      step: (request) => {
        const turn = Number(lastUserText(request.body).match(/TURN (\d+)/)?.[1] ?? 0);
        if (turn === 4 && request.body.prompt.at(-1)?.role !== "tool") return { kind: "tool" };
        return { kind: "final", text: `Turn ${turn} done.` };
      },
      compaction: () => ({ kind: "block" }),
    });
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: family.model, FX_TRACE_LOG: join(root, "trace.log"),
      FX_TEST_SKIP_ONBOARDING: "1",
      ...sanitizerOptions(),
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    const command = `/usr/bin/env -i ${Object.entries(env).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)} --full-access`;
    const terminal = await TmuxSession.create({ cmd: command, cwd, env: { HOME: home, FX_SOUND: "0" }, isolated: true, stderrPath: join(root, "tui.stderr"), width: 100, height: 32, startupWaitMs: 0 });
    let passed = false;
    try {
      await terminal.waitForStableComposer(20_000);
      for (let turn = 1; turn <= 6; turn += 1) {
        await terminal.sendText(`TURN ${turn} Continue.`);
        await terminal.waitForText(`Turn ${turn} done.`, 30_000);
        await terminal.waitForStableComposer(10_000);
      }
      const sixth = observed.at(-1)!.body;
      const sixthTurns = sixth.prompt.slice(sixth.prompt.findIndex((message) => message.role === "user" && JSON.stringify(message.content).includes("TURN 4")));
      const before = observed.length;
      await terminal.sendText("/compact");
      await terminal.waitForText("Context will be compacted before your next message.", 15_000);
      expect(observed.length).toBe(before);
      await terminal.sendText("TURN 7 Continue.");
      await terminal.waitForText("Turn 7 done.", 30_000);
      expect(counts.provider).toBe(1);
      const compaction = observed.slice(before).findIndex((request) => request.kind === "compaction");
      const turn = observed.slice(before).findIndex((request) => request.kind === "agent" && lastUserText(request.body).includes("TURN 7"));
      expect(compaction).toBeGreaterThanOrEqual(0);
      expect(compaction).toBeLessThan(turn);
      const conversation = conversationOf(observed[before + turn]!.body);
      expect(blockKeyOf(conversation[0]!)).toBe(observed[before + compaction]!.block!);
      expect(conversation.slice(1, 1 + sixthTurns.length).map(withoutCacheMarkers)).toEqual(sixthTurns.map(withoutCacheMarkers));
      expect(edits).toEqual([]);
      passed = true;
    } finally {
      await terminal.kill();
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
      else {
        writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request) => request.body), null, 1));
        console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
      }
    }
  }, 240_000);

  test("a model without provider compaction keeps fx's own compactor, with the newest turns after its summary", async () => {
    await withSession("google/gemini-3-pro", {}, async (session, { observed, counts }) => {
      const { root, cwd, env, sessionId, sixthTurns, before } = session;
      const seventh = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.");
      expect(seventh.code).toBe(0);
      expect(counts.provider).toBe(0);
      const conversation = conversationOf(agentRequestFor(observed, before, 7)!);
      expect(isFxSummary(conversation[0]!)).toBe(true);
      expect(conversation.slice(1, 1 + sixthTurns.length).map(withoutCacheMarkers)).toEqual(sixthTurns.map(withoutCacheMarkers));
    });
  }, 240_000);

  test("a compaction stopped while the provider writes its block leaves the conversation as it was", async () => {
    let child: ReturnType<typeof Bun.spawn> | null = null;
    await withSession(FAMILIES.anthropic.model, { compaction: () => ({ kind: "hold" }), onHold: () => child?.kill("SIGINT") }, async (session, { observed, edits }) => {
      const { root, cwd, env, sessionId, sixthConversation, before } = session;
      await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.", (spawned) => { child = spawned; });
      expect(observed.slice(before).some((request) => request.kind === "compaction")).toBe(true);
      const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId], "TURN 8 Continue.");
      expect(eighth.code).toBe(0);
      const conversation = conversationOf(agentRequestFor(observed, before, 8)!);
      expect(conversation.slice(0, sixthConversation.length).map(withoutCacheMarkers)).toEqual(sixthConversation.map(withoutCacheMarkers));
      expect(conversation.some((message) => blockKeyOf(message) !== null || isFxSummary(message))).toBe(false);
      expect(edits).toEqual([]);
    });
  }, 240_000);

  test("fx killed after the block is saved sends the block and the kept turns on resume", async () => {
    let child: ReturnType<typeof Bun.spawn> | null = null;
    let held = false;
    const options: Partial<ProviderGatewayOptions> = {
      // The first request after the compaction never answers, and fx is killed.
      step: (request) => (!held && lastUserText(request.body).includes("TURN 7") ? ((held = true), { kind: "hold" }) : step(request)),
      onHold: () => child?.kill("SIGKILL"),
    };
    await withSession(FAMILIES.openai.model, options, async (session, { observed, edits }) => {
      const { root, cwd, env, sessionId, sixthTurns, before } = session;
      await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.", (spawned) => { child = spawned; });
      expect(held).toBe(true);
      const block = observed.slice(before).find((request) => request.kind === "compaction")!.block!;
      const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId], "TURN 8 Continue.");
      expect(eighth.code).toBe(0);
      const conversation = conversationOf(agentRequestFor(observed, before, 8)!);
      expect(blockKeyOf(conversation[0]!)).toBe(block);
      expect(conversation.slice(1, 1 + sixthTurns.length).map(withoutCacheMarkers)).toEqual(sixthTurns.map(withoutCacheMarkers));
      expect(edits).toEqual([]);
    });
  }, 240_000);

  for (const family of Object.values(FAMILIES)) {
    test(`a ${family.name} session of 30 large turns compacts at every turn and never edits what it sent`, async () => {
      const TURNS = 30;
      const { root, home, cwd } = fixture(family.model);
      const { gateway, edits, observed, counts } = startProviderGateway({
        models: [{ id: family.model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }],
        defaultModel: family.model,
        // Every reply is larger than the 10 % the turns compact at, so every
        // turn after the first starts with a compaction.
        step: (request) => ({ kind: "final", text: `${lastUserText(request.body).match(/TURN \d+/)?.[0]} done. ${OLDER_TEXT}` }),
        compaction: () => ({ kind: "block" }),
      });
      const env: Record<string, string> = {
        PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
        AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
        ...sanitizerOptions(),
        FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: family.model, FX_AUTO_COMPACT_PERCENT: "10",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      };
      let passed = false;
      try {
        let sessionId: string | null = null;
        for (let turn = 1; turn <= TURNS; turn += 1) {
          const next = await ask(env, cwd, root, `t${turn}`, sessionId ? ["--resume", sessionId] : [], `TURN ${turn} Continue.`);
          expect(next.code).toBe(0);
          sessionId ??= next.json.session_id;
        }
        expect(edits).toEqual([]);
        expect(counts.fx).toBe(0);
        expect(counts.provider).toBe(TURNS - 1);
        const agents = observed.filter((request) => request.kind === "agent");
        let largest = 0;
        for (const request of agents) {
          // A newer block replaces the one before it.
          expect(request.body.prompt.filter((message) => blockKeyOf(message) !== null).length).toBeLessThanOrEqual(1);
          largest = Math.max(largest, JSON.stringify(request.body).length);
        }
        // The block and one large turn at most: the session never grows.
        expect(largest).toBeLessThan(3 * OLDER_TEXT.length);
        passed = true;
      } finally {
        gateway.stop();
        if (passed) rmSync(root, { recursive: true, force: true });
        else console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
      }
    }, 600_000);
  }

  test("a running turn whose newest step would fit is compacted whole, with only its message after the block", async () => {
    // At 10 % the second step crosses the threshold, and only that step fits
    // the turns fx keeps. The provider compacts everything the request held,
    // so no step of the turn may follow the block: the first message does.
    const family = FAMILIES.anthropic;
    const { root, home, cwd } = fixture(family.model);
    const sizes = ["x".repeat(128 * 1024), "y".repeat(18 * 1024)];
    const { gateway, edits, observed, counts } = startProviderGateway({
      models: [{ id: family.model, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 }],
      defaultModel: family.model,
      step: (request) => {
        const steps = request.body.prompt.filter((message) => message.role === "tool").length;
        if (!lastUserText(request.body).includes("TURN 1")) return { kind: "final", text: "Turn 2 done." };
        return steps < sizes.length && !request.body.prompt.some((message) => blockKeyOf(message) !== null)
          ? { kind: "tool", text: sizes[steps] }
          : { kind: "final", text: "Turn 1 done." };
      },
      compaction: () => ({ kind: "block" }),
    });
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      AI_GATEWAY_API_KEY: "synthetic-provider-compaction", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
      ...sanitizerOptions(),
      FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: family.model, FX_TRACE_LOG: join(root, "trace.log"),
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    let passed = false;
    try {
      const first = await ask({ ...env, FX_AUTO_COMPACT_PERCENT: "10" }, cwd, root, "t1", [], "TURN 1 Run the commands.");
      expect(first.code).toBe(0);
      expect(counts.provider).toBe(1);
      const compaction = observed.findIndex((request) => request.kind === "compaction");
      const after = observed.slice(compaction + 1).find((request) => request.kind === "agent")!;
      const conversation = conversationOf(after.body);
      expect(blockKeyOf(conversation[0]!)).toBe(observed[compaction]!.block!);
      expect(conversation.length).toBe(2);
      expect(JSON.stringify(conversation[1]!.content)).toContain("TURN 1");
      const second = await ask(env, cwd, root, "t2", ["--resume", first.json.session_id], "TURN 2 Thanks.");
      expect(second.code).toBe(0);
      expect(edits).toEqual([]);
      passed = true;
    } finally {
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
      else {
        writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request) => request.body), null, 1));
        console.error(`provider compaction evidence retained: ${root} edits=${JSON.stringify(edits)} counts=${JSON.stringify(counts)}`);
      }
    }
  }, 240_000);

  test("a request the provider refuses for its size is compacted with fx's summary and sent again", async () => {
    let refused = false;
    const options: Partial<ProviderGatewayOptions> = {
      step: (request) => (!refused && lastUserText(request.body).includes("TURN 7") ? ((refused = true), { kind: "overflow" }) : step(request)),
    };
    await withSession(FAMILIES.anthropic.model, options, async (session, { observed, counts, edits }) => {
      const { root, cwd, env, sessionId, before } = session;
      const seventh = await ask(env, cwd, root, "t7", ["--resume", sessionId], "TURN 7 Continue.");
      expect(seventh.code).toBe(0);
      expect(refused).toBe(true);
      // The refused request is too big for the provider to compact.
      expect(counts.provider).toBe(0);
      expect(trace(root)).toContain("reason=no_request");
      const resent = observed.slice(before).map((request) => request.body).filter((body) => !isCompactionRequest(body) && !isFxSummaryRequest(body) && lastUserText(body).includes("TURN 7")).at(-1)!;
      const conversation = conversationOf(resent);
      expect(isFxSummary(conversation[0]!)).toBe(true);
      expect(conversation.length).toBe(2);
      const eighth = await ask(env, cwd, root, "t8", ["--resume", sessionId], "TURN 8 Thanks.");
      expect(eighth.code).toBe(0);
      expect(edits).toEqual([]);
    });
  }, 240_000);
});
