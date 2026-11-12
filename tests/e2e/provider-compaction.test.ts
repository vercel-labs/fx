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
async function withSession(model: string, options: Partial<ProviderGatewayOptions>, body: (session: Session, gateway: Gateway) => Promise<void>) {
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
    const first = await ask(env, cwd, root, "t1", [], "TURN 1 Start the work.");
    expect(first.code).toBe(0);
    const sessionId: string = first.json.session_id;
    for (let turn = 2; turn <= 6; turn += 1) {
      const next = await ask(env, cwd, root, `t${turn}`, ["--resume", sessionId], `TURN ${turn} Continue.`);
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
