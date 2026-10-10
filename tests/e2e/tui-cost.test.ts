import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
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

// The fake gateway's default title reply has no generation id or cost, so a
// recorded title call would leave these sessions incomplete. These tests
// count exact turn totals, so they run without session titles.
function disableSessionTitles(home: string) {
  const settings = join(home, ".fx", "settings.json");
  if (existsSync(settings)) return;
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(settings, JSON.stringify({ session_titles: false }), { mode: 0o600 });
}

function gatewayEnvironment(home: string) {
  if (!gateway) throw new Error("fake gateway not started");
  disableSessionTitles(home);
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "test-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function filesNamed(directory: string, name: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...filesNamed(path, name));
    if (entry.isFile() && entry.name === name) files.push(path);
  }
  return files;
}

type UsageCheckpoint = {
  billing: string;
  pending: Array<{ id: string }>;
  total_cost: number;
  input_tokens: number;
  output_tokens: number;
  models: Array<{ model: string }>;
};

function readUsageCheckpoint(path: string): UsageCheckpoint {
  return JSON.parse(readFileSync(path, "utf8")).snapshot;
}

function latestUsageCheckpoint(home: string): UsageCheckpoint {
  const paths = filesNamed(home, "usage-v2.json");
  if (paths.length === 0) throw new Error("missing usage sidecar");
  return readUsageCheckpoint(paths[paths.length - 1]!);
}

function conversationTurnCount(home: string): number {
  let count = 0;
  for (const path of filesNamed(home, "events.jsonl")) {
    for (const line of readFileSync(path, "utf8").trim().split("\n")) {
      if (line.length === 0) continue;
      const event = JSON.parse(line).event;
      if (event?.turn_completed !== undefined || event?.interrupted !== undefined) {
        count += 1;
      }
    }
  }
  return count;
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

// Holds the profile-wide usage ledger lock the way another fx process would.
async function holdProfileUsageLock(home: string) {
  const holder = Bun.spawn(
    [
      "python3",
      "-c",
      "import fcntl, os, sys, time\n" +
        "fd = os.open(sys.argv[1], os.O_RDWR)\n" +
        "fcntl.flock(fd, fcntl.LOCK_EX)\n" +
        "print('locked', flush=True)\n" +
        "time.sleep(120)",
      join(home, ".fx", "usage.lock"),
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const reader = holder.stdout.getReader();
  const decoder = new TextDecoder();
  let output = "";
  while (!output.includes("locked")) {
    const chunk = await reader.read();
    if (chunk.done) throw new Error("usage lock holder exited early");
    output += decoder.decode(chunk.value);
  }
  reader.releaseLock();
  return holder;
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
                gatewayCost: "0.0123",
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
    const events = filesNamed(home, "events.jsonl")
      .map((path) => readFileSync(path, "utf8"))
      .join("\n");
    expect(events).toContain('"turn_completed"');
    const usage = latestUsageCheckpoint(home);
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

  const usage = latestUsageCheckpoint(home);
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

        const usageSidecars = filesNamed(home, "usage-v2.json");
        expect(usageSidecars).toHaveLength(1);
        const beforeResume = readUsageCheckpoint(usageSidecars[0]!);
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
          await session.waitForText("* session resumed:", TIMEOUT);
        }

        await waitForGenerationRequests(gateway, 2);
        expect(releaseResumeGeneration).not.toBeNull();
        releaseResumeGeneration!();
        await waitForProfileUsage(home, GENERATION_ID);

        await session.sendText("/cost");
        const cost = await session.waitForText(/in 130 \(20 cached, 10 written\)  out 25 \(5 reasoning\)/, TIMEOUT);
        expect(cost).toMatch(/\$0\.0123\s+155\s+1\s/);
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
        const afterResume = readUsageCheckpoint(usageSidecars[0]!);
        expect(afterResume.pending).toEqual([]);
        expect(afterResume.total_cost).toBe(0.0123);
        expect(afterResume.models.map((item) => item.model))
          .toContain(MODEL);
        expect(conversationTurnCount(home)).toBe(2);
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
      const firstCost = await session.waitForText(/in 130 \(20 cached, 10 written\)  out 25 \(5 reasoning\)/, TIMEOUT);
      expect(firstCost).toContain("[session]");
      expect(firstCost).toMatch(/\$0\.0123\s+155\s+1\s/);
      await session.sendKeys("Right");
      await session.waitForText("[24h]", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText("[7d]", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText(/\[30d\][\s\S]*\$0\.0123\s+155\s+1\s/, TIMEOUT);
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
      const resumedCost = await session.waitForText(/in 130 \(20 cached, 10 written\)  out 25 \(5 reasoning\)/, TIMEOUT);
      expect(resumedCost).toContain("[session]");
      expect(resumedCost).toMatch(/\$0\.0123\s+155\s+1\s/);
      await session.sendKeys("Right");
      await session.waitForText("[24h]", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText("[7d]", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText(/\[30d\][\s\S]*\$0\.0123\s+155\s+1\s/, TIMEOUT);
      expect(gateway.generationRequests).toEqual([GENERATION_ID, GENERATION_ID]);
    },
    TIMEOUT * 3,
  );

  test(
    "interactive exit keeps pending usage without waiting on a held ledger lock",
    async () => {
      root = mkdtempSync(join(tmpdir(), "fx-cost-held-ledger-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
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

      const fixture = Bun.spawn([FX_BIN, "ask", "Create pending usage."], {
        cwd: workspace,
        env: { ...process.env, ...gatewayEnvironment(home) },
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(await fixture.exited).toBe(0);
      await waitForProfileUsage(home, GENERATION_ID);

      const holder = await holdProfileUsageLock(home);
      try {
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --resume-last`,
          cwd: workspace,
          env: gatewayEnvironment(home),
          stderrPath,
        });
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
      } finally {
        holder.kill();
        await holder.exited;
      }

      const report = JSON.parse(
        readFileSync(
          join(home, ".fx", "diagnostics", "last-shutdown.json"),
          "utf8",
        ),
      );
      const persistence = report.stages.find(
        (stage: { name: string }) => stage.name === "persistence_finalized",
      );
      // Waiting on the held lock costs at least its 2s deadline per attempt.
      expect(persistence.step_ms).toBeLessThan(1000);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(latestUsageCheckpoint(home).pending.map((item) => item.id))
        .toEqual([GENERATION_ID]);
    },
    TIMEOUT * 3,
  );
});
