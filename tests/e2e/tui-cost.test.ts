import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewaySse,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const GENERATION_ID = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV";
const MODEL = "anthropic/claude-opus-4.8";
const RESPONSE_TEXT = "COST_ACCOUNTING_COMPLETE";
const FOLLOW_UP_TEXT = "RESUMED_FOLLOW_UP_COMPLETE";

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let root: string | null = null;

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  if (root) {
    rmSync(root, { recursive: true, force: true });
    root = null;
  }
});

function gatewayEnvironment(home: string) {
  if (!gateway) throw new Error("fake gateway not started");
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "test-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function eventLogs(directory: string): string[] {
  const logs: string[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) logs.push(...eventLogs(path));
    if (entry.isFile() && entry.name === "events.jsonl") logs.push(path);
  }
  return logs;
}

type UsageCheckpoint = {
  billing: string;
  pending: Array<{ id: string }>;
  total_cost: number;
  input_tokens: number;
  output_tokens: number;
  models: Array<{ model: string }>;
};

type SessionEvent = {
  kind: string;
  payload?: { usage?: UsageCheckpoint };
};

function eventRecords(events: string): SessionEvent[] {
  return events
    .trim()
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as SessionEvent);
}

function latestUsageCheckpoint(events: string): UsageCheckpoint {
  const records = eventRecords(events);
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index]!;
    if (record.kind === "usage_checkpointed" && record.payload?.usage) {
      return record.payload.usage;
    }
  }
  throw new Error("missing usage checkpoint");
}

function authoritativeGeneration(generationId: string): Response {
  return Response.json({
    data: {
      id: generationId,
      total_cost: 0.0123,
      created_at: new Date().toISOString(),
      model: MODEL,
      is_byok: false,
      native_tokens_prompt: 100,
      native_tokens_completion: 20,
      native_tokens_reasoning: 5,
      native_tokens_cached: 20,
      native_tokens_cache_creation: 10,
      billable_web_search_calls: 2,
    },
  });
}

async function waitForGenerationRequests(
  activeGateway: ReturnType<typeof startFakeGateway>,
  count: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (
    activeGateway.generationRequests.length < count &&
    Date.now() < deadline
  ) {
    await Bun.sleep(20);
  }
  expect(activeGateway.generationRequests).toHaveLength(count);
}

async function waitForProfileUsage(
  home: string,
  generationId: string,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  const usagePath = join(home, ".fx", "usage.jsonl");
  while (Date.now() < deadline) {
    try {
      if (readFileSync(usagePath, "utf8").includes(generationId)) return;
    } catch {}
    await Bun.sleep(20);
  }
  throw new Error("Timed out waiting for profile usage publication");
}

test(
  "fx ask settles authoritative stream usage without delayed reconciliation",
  async () => {
    root = mkdtempSync(join(tmpdir(), "fx-cost-ask-exit-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    gateway = startFakeGateway(
      [
        fakeGatewaySse([
          {
            type: "response-metadata",
            modelId: MODEL,
            timestamp: new Date().toISOString(),
          },
          {
            type: "text-start",
            id: "answer_1",
            providerMetadata: {
              gateway: { generationId: GENERATION_ID },
            },
          },
          { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
          { type: "text-end", id: "answer_1" },
          {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: {
                total: 130,
                cacheRead: 20,
                cacheWrite: 10,
              },
              outputTokens: { total: 25, reasoning: 5 },
            },
            providerMetadata: {
              gateway: {
                generationId: GENERATION_ID,
                cost: "0.0123",
                routing: { canonicalSlug: MODEL },
              },
            },
          },
        ]),
      ],
      {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
        generationResponse() {
          return new Promise<Response>(() => {});
        },
      },
    );

    const proc = Bun.spawn([FX_BIN, "ask", "Reply with the sentinel."], {
      cwd: workspace,
      env: { ...process.env, ...gatewayEnvironment(home) },
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await Promise.race([
      proc.exited,
      Bun.sleep(2_000).then(() => null),
    ]);
    if (exitCode === null) {
      proc.kill();
      await proc.exited;
    }

    expect(exitCode).toBe(0);
    expect(gateway.generationRequests).toEqual([]);
    await waitForProfileUsage(home, GENERATION_ID);
    const events = eventLogs(home)
      .map((path) => readFileSync(path, "utf8"))
      .join("\n");
    const checkpoint = events.indexOf('"kind":"usage_checkpointed"');
    const history = events.indexOf('"kind":"history_turn_committed"');
    expect(checkpoint).toBeGreaterThanOrEqual(0);
    expect(checkpoint).toBeLessThan(history);
    expect(events).toContain(GENERATION_ID);
    const usage = latestUsageCheckpoint(events);
    expect(usage.billing).toBe("complete");
    expect(usage.pending).toEqual([]);
    expect(usage.total_cost).toBe(0.0123);
    expect(usage.input_tokens).toBe(130);
    expect(usage.output_tokens).toBe(25);
  },
  10_000,
);

test("fx ask gives immediate generation reconciliation a bounded drain", async () => {
  root = mkdtempSync(join(tmpdir(), "fx-cost-ask-reconcile-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  gateway = startFakeGateway(
    [
      fakeGatewaySse([
        { type: "response-metadata", modelId: MODEL },
        {
          type: "text-start",
          id: "answer_1",
          providerMetadata: {
            gateway: { generationId: GENERATION_ID },
          },
        },
        { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
        { type: "text-end", id: "answer_1" },
        {
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
        },
      ]),
    ],
    {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      generationResponse(generationId) {
        return authoritativeGeneration(generationId);
      },
    },
  );

  const proc = Bun.spawn([FX_BIN, "ask", "Reply with the sentinel."], {
    cwd: workspace,
    env: { ...process.env, ...gatewayEnvironment(home) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const exitCode = await proc.exited;
  const stderr = await new Response(proc.stderr).text();
  expect(exitCode, stderr).toBe(0);
  expect(gateway.generationRequests).toEqual([GENERATION_ID]);

  const events = eventLogs(home)
    .map((path) => readFileSync(path, "utf8"))
    .join("\n");
  const usage = latestUsageCheckpoint(events);
  expect(usage.billing).toBe("complete");
  expect(usage.total_cost).toBe(0.0123);
  expect(usage.pending).toEqual([]);
});

test("fx usage reports an unresolved delayed fallback as pending", async () => {
  root = mkdtempSync(join(tmpdir(), "fx-cost-pending-profile-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  gateway = startFakeGateway(
    [
      fakeGatewaySse([
        { type: "response-metadata", modelId: MODEL },
        {
          type: "text-start",
          id: "answer_1",
          providerMetadata: {
            gateway: { generationId: GENERATION_ID },
          },
        },
        { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
        { type: "text-end", id: "answer_1" },
        {
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
        },
      ]),
    ],
    {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      generationResponse() {
        return new Response("unauthorized", { status: 401 });
      },
    },
  );

  const ask = Bun.spawn([FX_BIN, "ask", "Reply with the sentinel."], {
    cwd: workspace,
    env: { ...process.env, ...gatewayEnvironment(home) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const askStderr = await new Response(ask.stderr).text();
  expect(await ask.exited, askStderr).toBe(0);
  await waitForProfileUsage(home, GENERATION_ID);

  const usage = Bun.spawn(
    [FX_BIN, "usage", "--period", "24h", "--json"],
    {
      cwd: workspace,
      env: { ...process.env, HOME: home },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const usageStdout = await new Response(usage.stdout).text();
  const usageStderr = await new Response(usage.stderr).text();
  expect(await usage.exited, usageStderr).toBe(0);
  const report = JSON.parse(usageStdout);
  expect(report.completeness).toBe("pending");
  expect(report.totals.request_count).toBe(0);
  expect(gateway.generationRequests).toEqual([GENERATION_ID]);
});

test("fx usage reports a missing generation identity as incomplete", async () => {
  root = mkdtempSync(join(tmpdir(), "fx-cost-incomplete-profile-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  gateway = startFakeGateway(
    [
      fakeGatewaySse([
        { type: "response-metadata", modelId: MODEL },
        { type: "text-start", id: "answer_1" },
        { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
        { type: "text-end", id: "answer_1" },
        {
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
        },
      ]),
    ],
    {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    },
  );

  const ask = Bun.spawn([FX_BIN, "ask", "Reply with the sentinel."], {
    cwd: workspace,
    env: { ...process.env, ...gatewayEnvironment(home) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const askStderr = await new Response(ask.stderr).text();
  expect(await ask.exited, askStderr).toBe(0);

  const usage = Bun.spawn(
    [FX_BIN, "usage", "--period", "24h", "--json"],
    {
      cwd: workspace,
      env: { ...process.env, HOME: home },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const usageStdout = await new Response(usage.stdout).text();
  const usageStderr = await new Response(usage.stderr).text();
  expect(await usage.exited, usageStderr).toBe(0);
  const report = JSON.parse(usageStdout);
  expect(report.completeness).toBe("incomplete");
  expect(report.totals.request_count).toBe(0);
  expect(gateway.generationRequests).toEqual([]);
});

describe.skipIf(!tmuxAvailable())("tui: durable session cost", () => {
  for (const resumeMode of ["startup", "picker"] as const) {
    test(
      `pending generation reconciliation survives ${resumeMode} resume`,
      async () => {
        root = mkdtempSync(join(tmpdir(), `fx-cost-${resumeMode}-resume-`));
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(home, { recursive: true });
        mkdirSync(workspace, { recursive: true });

        let originalGenerationRequests = 0;
        let releaseResumeGeneration: (() => void) | null = null;
        const heldResumeGeneration = new Promise<Response>((resolve) => {
          releaseResumeGeneration = () =>
            resolve(authoritativeGeneration(GENERATION_ID));
        });
        gateway = startFakeGateway(
          [
            fakeGatewaySse([
              { type: "response-metadata", modelId: MODEL },
              {
                type: "text-start",
                id: "answer_1",
                providerMetadata: {
                  gateway: { generationId: GENERATION_ID },
                },
              },
              { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
              { type: "text-end", id: "answer_1" },
              {
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
              },
            ]),
            fakeGatewaySse([
              { type: "text-start", id: "answer_2" },
              { type: "text-delta", id: "answer_2", delta: FOLLOW_UP_TEXT },
              { type: "text-end", id: "answer_2" },
              {
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
              },
            ]),
          ],
          {
            models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
            generationResponse(generationId) {
              if (generationId !== GENERATION_ID) {
                return new Response("not found", { status: 404 });
              }
              originalGenerationRequests += 1;
              if (originalGenerationRequests === 1) {
                return new Promise<Response>(() => {});
              }
              return heldResumeGeneration;
            },
          },
        );

        const fixture = Bun.spawn(
          [FX_BIN, "ask", "Create pending usage for resume."],
          {
            cwd: workspace,
            env: { ...process.env, ...gatewayEnvironment(home) },
            stdout: "pipe",
            stderr: "pipe",
          },
        );
        expect(await fixture.exited).toBe(0);
        expect(gateway.generationRequests).toEqual([GENERATION_ID]);

        const fixtureLogs = eventLogs(home);
        expect(fixtureLogs).toHaveLength(1);
        const resumedEventsPath = fixtureLogs[0]!;
        const beforeResume = latestUsageCheckpoint(
          readFileSync(resumedEventsPath, "utf8"),
        );
        expect(beforeResume.billing).toBe("pending");
        expect(beforeResume.pending.map((item) => item.id))
          .toEqual([GENERATION_ID]);

        session = await TmuxSession.create({
          cmd: resumeMode === "startup" ? `${FX_BIN} --resume-last` : FX_BIN,
          cwd: workspace,
          env: gatewayEnvironment(home),
          stderrPath,
        });
        await session.waitForComposer(TIMEOUT);
        if (resumeMode === "picker") {
          await session.sendText("/resume");
          await session.waitForPane(
            (pane) => pane.includes("Sessions") && /\bturns?\b/.test(pane),
            TIMEOUT,
          );
          await session.sendKeys("Enter");
          await session.waitForText("● Session resumed:", TIMEOUT);
        }

        await waitForGenerationRequests(gateway, 2);
        expect(releaseResumeGeneration).not.toBeNull();
        releaseResumeGeneration!();
        await waitForProfileUsage(home, GENERATION_ID);

        await session.sendText("/cost");
        const cost = await session.waitForText(/\$0\.01 spent/, TIMEOUT);
        expect(cost).toMatch(/155 tokens/);
        expect(cost).toMatch(/130 input/);
        expect(cost).toMatch(/25 output/);
        expect(cost).toMatch(/20 cache read/);
        expect(cost).toMatch(/10 cache write/);
        await session.sendKeys("Escape");
        await session.waitForComposer(TIMEOUT);
        await session.sendText("Confirm resumed input still works.");
        await session.waitForText(FOLLOW_UP_TEXT, TIMEOUT);
        await session.sendLiteral("/re");
        await session.waitForText("/re", TIMEOUT);
        await session.sendKeys("C-u");
        await session.waitForPane((pane) => !pane.includes("❯ /re"), TIMEOUT);
        expect(session.isPaneAlive()).toBe(true);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
        const resumedEvents = readFileSync(resumedEventsPath, "utf8");
        const afterResume = latestUsageCheckpoint(resumedEvents);
        expect(afterResume.pending).toEqual([]);
        expect(afterResume.total_cost).toBe(0.0123);
        expect(afterResume.models.map((item) => item.model))
          .toContain(MODEL);
        expect(
          eventRecords(resumedEvents)
            .filter((record) => record.kind === "history_turn_committed"),
        ).toHaveLength(2);
      },
      TIMEOUT * 2,
    );
  }

  test(
    "authoritative generation totals survive process resume",
    async () => {
      root = mkdtempSync(join(tmpdir(), "fx-cost-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });
      let generationAttempts = 0;

      gateway = startFakeGateway(
        [
          fakeGatewaySse([
            { type: "response-metadata", modelId: MODEL },
            {
              type: "text-start",
              id: "answer_1",
              providerMetadata: {
                gateway: { generationId: GENERATION_ID },
              },
            },
            { type: "text-delta", id: "answer_1", delta: RESPONSE_TEXT },
            { type: "text-end", id: "answer_1" },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: {
                inputTokens: { total: 100 },
                outputTokens: { total: 20 },
              },
            },
          ]),
        ],
        {
          models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
          generationResponse(generationId) {
            generationAttempts += 1;
            if (generationId !== GENERATION_ID) {
              return new Response("not found", { status: 404 });
            }
            if (generationAttempts === 1) {
              return new Response("not ready", { status: 404 });
            }
            return authoritativeGeneration(GENERATION_ID);
          },
        },
      );

      session = await TmuxSession.create({
        cwd: workspace,
        env: gatewayEnvironment(home),
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Reply with the cost accounting sentinel.");
      await session.waitForText(RESPONSE_TEXT, TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      await waitForGenerationRequests(gateway, 2);
      expect(gateway.generationRequests).toEqual([GENERATION_ID, GENERATION_ID]);
      await Bun.sleep(50);
      await session.sendText("/cost");
      const firstCost = await session.waitForText(/\$0\.01 spent/, TIMEOUT);
      expect(firstCost).toMatch(/155 tokens/);
      expect(firstCost).toMatch(/130 input/);
      expect(firstCost).toMatch(/25 output/);
      expect(firstCost).toMatch(/20 cache read/);
      expect(firstCost).toMatch(/10 cache write/);
      await session.sendKeys("Left");
      await session.waitForText("[7 days]", TIMEOUT);
      await session.sendKeys("Left");
      await session.waitForText("[24 hours]", TIMEOUT);
      await session.sendKeys("Left");
      const firstSession = await session.waitForText("[Session]", TIMEOUT);
      expect(firstSession).toMatch(/5 reasoning/);
      expect(firstSession).toMatch(/1 request/);
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TIMEOUT);
      session = null;

      session = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: workspace,
        env: gatewayEnvironment(home),
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/cost");
      const resumedCost = await session.waitForText(/\$0\.01 spent/, TIMEOUT);
      expect(resumedCost).toMatch(/155 tokens/);
      expect(resumedCost).toMatch(/130 input/);
      expect(resumedCost).toMatch(/25 output/);
      expect(resumedCost).toMatch(/20 cache read/);
      expect(resumedCost).toMatch(/10 cache write/);
      await session.sendKeys("Left");
      await session.waitForText("[7 days]", TIMEOUT);
      await session.sendKeys("Left");
      await session.waitForText("[24 hours]", TIMEOUT);
      await session.sendKeys("Left");
      const resumedSession = await session.waitForText(
        "[Session]",
        TIMEOUT,
      );
      expect(resumedSession).toMatch(/5 reasoning/);
      expect(resumedSession).toMatch(/1 request/);
      expect(gateway.generationRequests).toEqual([GENERATION_ID, GENERATION_ID]);
    },
    TIMEOUT * 3,
  );
});
