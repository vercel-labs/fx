import { beforeAll, describe, expect, test } from "bun:test";
import "./journal/crash.test";
import { decodeNativeJournal } from "./journal/storage";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { ensureLegacyFixtureBinary, runLegacyFx } from "./legacy-session-fixture";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

function savedFileHashes(root: string): Record<string, string> {
  const hashes: Record<string, string> = {};
  function visit(directory: string, prefix = "") {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === "session.lock") continue;
      const relative = join(prefix, entry.name);
      if (entry.isDirectory()) visit(join(directory, entry.name), relative);
      else hashes[relative] = createHash("sha256")
        .update(readFileSync(join(directory, entry.name)))
        .digest("hex");
    }
  }
  visit(root);
  return hashes;
}

function createFixture(prefix: string) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
  };
}

function gatewayEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "session-recovery-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
  };
}

async function createSavedSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
): Promise<string> {
  const created = await runFx(
    ["ask", "--json", "--auto", "Create the first saved turn."],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
  expect(created.code).toBe(0);
  expect(created.stderr).toBe("");
  return JSON.parse(created.stdout).session_id;
}

async function continueSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  sessionId: string,
  latest = false,
) {
  return runFx(
    [
      "ask",
      "--json",
      "--auto",
      ...(latest ? ["--resume", "last"] : ["--resume-id", sessionId]),
      "Continue after recovery.",
    ],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
}

const LEGACY_TITLE = "Synthetic legacy recovery conversation";

test("latest resume preserves an unrelated pending authority directory", async () => {
  const fixture = createFixture("fx-latest-pending-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("SAVED_PARENT_CONTEXT"),
    fakeGatewayFinalText("CONTINUED_PARENT_CONTEXT"),
  ]);
  try {
    const id = await createSavedSession(fixture, gateway);
    const orphan = join(fixture.home, ".fx", "sessions", "pending-authority");
    mkdirSync(orphan, { mode: 0o700 });
    writeFileSync(join(orphan, "authority.pending.json"), "pending", { mode: 0o600 });
    writeFileSync(join(orphan, "events.jsonl"), "unidentified saved data\n", { mode: 0o600 });
    const resumed = await continueSession(fixture, gateway, id, true);
    expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).session_id).toBe(id);
    expect(gateway.requests.at(-1)?.body).toContain("SAVED_PARENT_CONTEXT");
    expect(readFileSync(join(orphan, "events.jsonl"), "utf8")).toBe("unidentified saved data\n");
    expect(readFileSync(join(orphan, "authority.pending.json"), "utf8")).toBe("pending");
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT);

test("resume keeps conversation history when accounting is damaged", async () => {
  const fixture = createFixture("fx-accounting-resume-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("ACCOUNTING_HISTORY_RETAINED"),
    fakeGatewayFinalText("ACCOUNTING_RESUME_COMPLETED"),
  ]);
  try {
    const id = await createSavedSession(fixture, gateway);
    const dir = join(fixture.home, ".fx", "sessions", id);
    const events = join(dir, "execution.journal");
    const before = readFileSync(events);
    writeFileSync(join(dir, "usage-v2.json"), "{broken accounting", { mode: 0o600 });
    const resumed = await continueSession(fixture, gateway, id);
    expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(resumed.stdout).session_id).toBe(id);
    expect(gateway.requests.at(-1)?.body).toContain("ACCOUNTING_HISTORY_RETAINED");
    expect(readFileSync(events).subarray(0, before.length).equals(before)).toBe(true);
    expect(JSON.parse(readFileSync(join(dir, "usage-v2.json"), "utf8")).snapshot.billing).toBe("incomplete");
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT);

test("conversation language survives an ordinary saved turn and resume", async () => {
  const fixture = createFixture("fx-language-resume-");
  const gateway = startFakeGateway([
    fakeGatewayFinalText("こんにちは。"),
    fakeGatewayFinalText("完了しました。"),
  ]);
  try {
    const seeded = await runFx(["ask", "--json", "こんにちは。日本語で返答してください。"], {
      cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
    });
    expect(seeded.code).toBe(0);
    const id = JSON.parse(seeded.stdout).session_id;
    const metadata = join(fixture.home, ".fx", "sessions", id, "session.json");
    expect(JSON.parse(readFileSync(metadata, "utf8")).metadata.conversation_language).toBe("ja");
    const resumed = await runFx(["ask", "--json", "--resume-id", id, "👍"], {
      cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
    });
    expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
    expect(resumed.stderr).toBe("");
    expect(JSON.parse(readFileSync(metadata, "utf8")).metadata.conversation_language).toBe("ja");
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT);
const LEGACY_ANSWER = "LEGACY_COMMITTED_ANSWER";
const LEGACY_PARTIAL = "LEGACY_PARTIAL_EVIDENCE";
const LEGACY_TOOL_CALL_ID = "legacy-recorded-read";
const LEGACY_TOOL_EVIDENCE = "LEGACY_TOOL_EVIDENCE";
const LEGACY_GATEWAY_OPTIONS = {
  models: [{
    id: FAKE_GATEWAY_MODEL,
    type: "language",
    tags: ["reasoning", "tool-use"],
    reasoning_options: [{ type: "effort", values: ["low", "high"] }],
    fast_options: [{ type: "toggle" }],
  }],
};

// Entirely synthetic schema-v3 data: no copied sessions, credentials, or child markers.
function createLegacySession(fixture: ReturnType<typeof createFixture>, version: 2 | 3 | 4) {
  const id = `synthetic-legacy-v${version}`;
  const source = join(fixture.home, ".fx", "sessions", id);
  mkdirSync(source, { recursive: true, mode: 0o700 });
  const generation = "01".repeat(16);
  const authority = "03".repeat(16);
  const preferences = {
    connection_id: "vercel", model_id: FAKE_GATEWAY_MODEL, effort: "high", fast_mode: true,
  };
  const execution = { schema_version: 4, tool_steps: [], files: [] };
  const checkpointExecution = {
    ...execution,
    tool_steps: [{
      assistant: null,
      tool_calls: [{
        id: LEGACY_TOOL_CALL_ID, name: "read_file",
        arguments_json: JSON.stringify({ path: "synthetic-recorded-read.txt" }), provider_result: null,
      }],
      tool_results: [{
        tool_call_id: LEGACY_TOOL_CALL_ID, tool_name: "read_file", status: "success",
        output: LEGACY_TOOL_EVIDENCE, output_handle: null, preview: null,
        output_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE),
        stored_output_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE),
        truncated: false, provider_native: false, created_at_ms: 25, permission_feedback: [],
        committed_file_presentation: null, command_output_replay: null,
        command_process_presentation: null, terminal_action_presentation: null,
      }],
    }],
  };
  const route = {
    connection_id: "vercel", adapter_kind: "vercel_ai_gateway", permission_review_model_id: "",
    ...(version >= 3 ? { vision_model_id: "", subagent_model_id: "" } : {}),
    ...(version === 4 ? {
      version: 1, endpoint: "https://legacy-route.invalid", protocol: "vercel_ai_gateway",
      credential_ref: "synthetic-unusable-credential",
    } : {}),
  };
  const records = [
    { kind: "session_started", payload: {
      id, created_at_ms: 10, origin_workspace_root: fixture.workspace,
      workspace_root: fixture.workspace, conversation_language: "en", preferences,
    } },
    { kind: "history_turn_committed", payload: {
      conversation_language: "en", total_input_tokens: 0, total_output_tokens: 0,
      turn: { kind: "assistant", user: { text: LEGACY_TITLE, images: [] }, assistant: LEGACY_ANSWER, execution },
    } },
    { kind: "recovery_checkpoint_set", payload: { checkpoint: {
      version, route_identity: route, delivery: "possibly_sent", turn_id: 2,
      user: { text: "An interrupted synthetic request", images: [] },
      assistant_source: LEGACY_PARTIAL, execution: checkpointExecution, cause: "response_interrupted",
      action: "continuing_response", tool_state: "confirmed", route_model: FAKE_GATEWAY_MODEL,
      requested_fast_mode: true, fast_mode: true, max_provider_attempts: 3,
      consumed_provider_attempts: 1, outstanding_reservation: false,
    } } },
  ].map((record, index) => ({
    schema_version: 1, log_generation: generation, seq: index + 1,
    event_id: (index + 1).toString(16).padStart(2, "0").repeat(16),
    timestamp_ms: (index + 1) * 10, ...record,
  }));
  const lines = records.map((record) => JSON.stringify(record) + "\n");
  const events = lines.join("");
  const writeJson = (name: string, value: object) => writeFileSync(
    join(source, name), JSON.stringify(value) + "\n", { mode: 0o600 },
  );
  writeFileSync(join(source, "events.jsonl"), events, { mode: 0o600 });
  writeJson("authority.json", {
    schema_version: 1, storage_format: "event_log_v1", session_id: id,
    authority_id: authority, source: "native_create",
  });
  writeJson("session.json", {
    schema_version: 3, storage_format: "event_log_v1", id, authority_id: authority,
    log_generation: generation, created_at_ms: 10, updated_at_ms: 30,
    origin_workspace_root: fixture.workspace, workspace_root: fixture.workspace,
    conversation_language: "en", history_len: 1, total_input_tokens: 0, total_output_tokens: 0,
    last_event_seq: records.length, event_log_bytes: Buffer.byteLength(events),
    event_log_stat_fingerprint: "00".repeat(32), generation_base_seq: 1,
    generation_base_bytes: Buffer.byteLength(lines[0]!), checkpoint_seq: null,
    checkpoint_sha256: null, preferences,
  });
  const watermarkPath = join(source, `commit.${generation}.json`);
  writeJson(`commit.${generation}.json`, {
    schema_version: 1, session_id: id, log_generation: generation,
    through_seq: records.length, through_event_id: records.at(-1)!.event_id,
    through_event_log_bytes: Buffer.byteLength(events),
  });
  writeJson("display.json", {
    schema_version: 1, title: LEGACY_TITLE, preview: null, origin_workspace_root: fixture.workspace,
  });
  writeFileSync(join(fixture.home, ".fx", "settings.json"), JSON.stringify({
    model: "workspace/default", effort: "low", fast_mode: false, auto_upgrade: false,
  }), { mode: 0o600 });
  return { id, source, watermarkPath };
}

function legacyGatewayEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    ...gatewayEnv(fixture, gateway), FX_MODEL: undefined, FX_EFFORT: undefined,
    FX_FAST_MODE: undefined, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TRACE_LOG: join(fixture.root, "legacy.trace.log"), FX_TRACE_SCOPES: "tool,session,agent",
  };
}

function nativeJournalRecords(source: string) {
  return decodeNativeJournal(readFileSync(join(source, "execution.journal")))
    .map(entry => JSON.parse(Buffer.from(entry.bytes).toString("utf8")));
}

function nativeHistory(source: string) {
  const records = nativeJournalRecords(source);
  expect(records.filter(record => record.kind === "checkpoint")).toHaveLength(1);
  return [
    ...JSON.parse(records[0].nativeBase.stateJson).history,
    ...records.filter(record => record.kind === "turn_end" && record.history).map(record => record.history),
  ];
}

async function expectPendingLegacyRefusal(fixture: ReturnType<typeof createFixture>, gateway: ReturnType<typeof startFakeGateway>, id: string) {
  const source = join(fixture.home, ".fx", "sessions", id);
  const before = savedFileHashes(source);
  const requests = gateway.requests.length;
  const classifiers = gateway.classifierRequests.length;
  const refused = await continueSession(fixture, gateway, id);
  expect(refused.timedOut).toBe(false);
  expect(refused.code).toBe(1);
  expect(refused.stdout + refused.stderr).toContain("PendingTurnError");
  expect(savedFileHashes(source)).toEqual(before);
  expect(gateway.requests).toHaveLength(requests);
  expect(gateway.classifierRequests).toHaveLength(classifiers);
}

function expectLegacyArchive(source: string) {
  if (existsSync(join(source, "execution.journal"))) {
    const history = nativeHistory(source);
    const partial = history.filter(turn => turn.kind === "interrupted" && turn.assistant === LEGACY_PARTIAL);
    expect(partial).toHaveLength(1);
    expect(partial[0].terminal_reason).toBe("failed");
    const steps = partial[0].execution.tool_steps;
    expect(steps).toHaveLength(1);
    expect(steps[0].tool_calls).toHaveLength(1);
    expect(steps[0].tool_calls[0]).toMatchObject({ id: LEGACY_TOOL_CALL_ID, name: "read_file",
      arguments_json: JSON.stringify({ path: "synthetic-recorded-read.txt" }) });
    expect(steps[0].tool_results).toHaveLength(1);
    expect(steps[0].tool_results[0]).toMatchObject({ tool_call_id: LEGACY_TOOL_CALL_ID,
      tool_name: "read_file", status: "success", output: LEGACY_TOOL_EVIDENCE,
      truncated: true, output_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE),
      stored_output_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE) });
    const text = JSON.stringify(history);
    expect(text.split(LEGACY_PARTIAL)).toHaveLength(2);
    expect(text).toContain(LEGACY_ANSWER);
    expect(text).not.toContain("route_identity");
    expect(JSON.parse(readFileSync(join(source, "session.json"), "utf8"))).toMatchObject({
      schema_version: 5, metadata: { provider: "gateway", model: FAKE_GATEWAY_MODEL, effort: "high", fast_mode: true },
    });
    expect(existsSync(join(source, "recovery.json"))).toBe(false);
    return;
  }

  const events = readFileSync(join(source, "events.jsonl"), "utf8");
  const records = events.trimEnd().split("\n").map(JSON.parse);
  const archived = records.filter((record) => record.event.interrupted?.partial_text === LEGACY_PARTIAL);
  expect(archived).toHaveLength(1);
  expect(archived[0].event.interrupted.reason).toBe("failed");
  const calls = records.filter((record) => record.event.tool_call?.call_id === LEGACY_TOOL_CALL_ID);
  expect(calls).toHaveLength(1);
  expect(calls[0].event.tool_call).toMatchObject({
    tool_name: "read_file", arguments_json: JSON.stringify({ path: "synthetic-recorded-read.txt" }),
  });
  const results = records.filter((record) => record.event.tool_result?.call_id === LEGACY_TOOL_CALL_ID);
  expect(results).toHaveLength(1);
  const result = results[0].event.tool_result;
  // Imported inline output has exact retained bytes, but legacy completeness is not trusted.
  expect(result).toMatchObject({
    tool_name: "read_file", status: "success", completeness: "partial",
    output_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE),
    stored_bytes: Buffer.byteLength(LEGACY_TOOL_EVIDENCE), preview: LEGACY_TOOL_EVIDENCE,
  });
  expect(readFileSync(join(source, "tool-results", result.artifact_ref), "utf8")).toBe(LEGACY_TOOL_EVIDENCE);
  expect(events.split(LEGACY_PARTIAL)).toHaveLength(2);
  expect(events).toContain(LEGACY_ANSWER);
  expect(events).not.toContain("route_identity");
  expect(existsSync(join(source, "recovery.json"))).toBe(false);
  expect(existsSync(join(source, "subagent", "owner.json"))).toBe(false);
  const metadata = JSON.parse(readFileSync(join(source, "session.json"), "utf8"));
  expect(metadata).toMatchObject({
    schema_version: 4, provider: "gateway", model: FAKE_GATEWAY_MODEL, effort: "high", fast_mode: true,
  });
  expect(metadata.subagent_child).not.toBe(true);
}

function expectLegacyRequest(request: { body: string; headers: Headers }) {
  expect(request.headers.get("ai-language-model-id")).toBe(FAKE_GATEWAY_MODEL);
  expect(JSON.parse(request.body)).toMatchObject({
    reasoning: "high", providerOptions: { gateway: { speed: "fast" } },
  });
  expect(request.body).toContain(LEGACY_ANSWER);
  expect(request.body).toContain(LEGACY_TOOL_EVIDENCE);
  expect(request.body.split(LEGACY_PARTIAL)).toHaveLength(2);
  expect(request.body).not.toContain("synthetic-unusable-credential");
  expect(request.body).not.toContain("legacy-route.invalid");
}

describe("legacy session recovery", () => {
  beforeAll(ensureLegacyFixtureBinary, 600_000);

  async function createLegacySavedSession(fixture: ReturnType<typeof createFixture>, gateway: ReturnType<typeof startFakeGateway>) {
    const created = await runLegacyFx(["ask", "--json", "--auto", "Create the first saved turn."], {
      cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
    });
    expect(created.code).toBe(0);
    expect(created.stderr).toBe("");
    const id = JSON.parse(created.stdout).session_id;
    expect(JSON.parse(readFileSync(join(fixture.home, ".fx", "sessions", id, "session.json"), "utf8")).schema_version).toBe(4);
    return id;
  }

  test("unsupported accounting snapshot versions refuse recovery without changing the source", async () => {
    const fixture = createFixture("fx-session-future-usage-");
    const gateway = startFakeGateway([fakeGatewayFinalText("SAVED_ACCOUNTING_VERSION")]);
    try {
      const id = await createLegacySavedSession(fixture, gateway);
      const sessions = join(fixture.home, ".fx", "sessions");
      const source = join(sessions, id);
      const usagePath = join(source, "usage-v2.json");
      const usage = JSON.parse(readFileSync(usagePath, "utf8"));
      usage.snapshot.schema_version = 4;
      writeFileSync(usagePath, JSON.stringify(usage), { mode: 0o600 });
      const before = savedFileHashes(source);
      const sessionNames = readdirSync(sessions).sort();
      const result = await runFx(["session", "recover", id, "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(result.code).toBe(1);
      expect(result.stdout + result.stderr).toContain("UnsupportedUsageSidecar");
      expect(savedFileHashes(source)).toEqual(before);
      expect(readdirSync(sessions).sort()).toEqual(sessionNames);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const damagedTail of [false, true]) {
    test(`corrupt accounting recovers a source-preserving copy, damaged tail=${damagedTail}`, async () => {
      const fixture = createFixture("fx-session-usage-copy-");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("ACCOUNTING_RECOVERY_SAVED"),
        fakeGatewayFinalText("ACCOUNTING_RECOVERY_CONTINUED"),
      ]);
      try {
        const id = await createLegacySavedSession(fixture, gateway);
        const source = join(fixture.home, ".fx", "sessions", id);
        const committed = readFileSync(join(source, "events.jsonl"));
        writeFileSync(join(source, "usage-v2.json"), "{broken usage", { mode: 0o600 });
        if (damagedTail) appendFileSync(join(source, "events.jsonl"), "{broken tail");
        const before = savedFileHashes(source);
        const result = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code, result.stdout + result.stderr).toBe(0);
        expect(result.stderr).toBe("");
        const recovered = JSON.parse(result.stdout);
        expect(recovered).toMatchObject({ status: "recovered", usage_incomplete: true, source_id: id });
        expect(recovered.recovered_id).not.toBe(id);
        expect(savedFileHashes(source)).toEqual(before);
        const copy = join(fixture.home, ".fx", "sessions", recovered.recovered_id);
        expect(readFileSync(join(copy, "events.jsonl"))).toEqual(committed);
        expect(JSON.parse(readFileSync(join(copy, "usage-v2.json"), "utf8")).snapshot.billing).toBe("incomplete");
        const continued = await continueSession(fixture, gateway, recovered.recovered_id);
        expect(continued.code).toBe(0);
        expect(continued.stderr).toBe("");
        expect(gateway.requests.at(-1)!.body).toContain("ACCOUNTING_RECOVERY_SAVED");
        expect(JSON.parse(readFileSync(join(copy, "usage-v2.json"), "utf8")).snapshot.billing).toBe("incomplete");
        expect(savedFileHashes(source)).toEqual(before);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test.skipIf(!tmuxAvailable())("legacy cache usage resumes through latest and exact session flows", async () => {
    const fixture = createFixture("fx-session-legacy-cache-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("HEALTHY_LATEST_USAGE"),
      fakeGatewayFinalText("LEGACY_USAGE_CONTINUED"),
    ], LEGACY_GATEWAY_OPTIONS);
    let tui: TmuxSession | undefined;
    try {
      const legacy = createLegacySession(fixture, 4);
      const eventPath = join(legacy.source, "events.jsonl");
      const records = readFileSync(eventPath, "utf8").trimEnd().split("\n").map(JSON.parse);
      records.push({
        schema_version: 1, log_generation: records[0].log_generation,
        seq: 4, event_id: "04".repeat(16), timestamp_ms: 40, kind: "usage_checkpointed",
        payload: { usage: {
          billing: "complete", api_duration_complete: true, wall_duration_complete: true,
          code_complete: true, next_sequence: 2, settled_through_sequence: 1,
          api_duration_ms: 10, wall_duration_ms: 20, total_cost: 1,
          input_tokens: 1, output_tokens: 3, cache_read_tokens: 2, cache_write_tokens: 0,
          billable_web_search_calls: 0, lines_added: 0, lines_removed: 0,
          models: [{ model: "test/model", first_sequence: 1, total_cost: 1,
            input_tokens: 1, output_tokens: 3, cache_read_tokens: 2, cache_write_tokens: 0,
            billable_web_search_calls: 0 }], pending: [],
        } },
      });
      const events = records.map(record => JSON.stringify(record) + "\n").join("");
      writeFileSync(eventPath, events, { mode: 0o600 });
      const metadataPath = join(legacy.source, "session.json");
      const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
      writeFileSync(metadataPath, JSON.stringify({ ...metadata, updated_at_ms: 40,
        last_event_seq: 4, event_log_bytes: Buffer.byteLength(events) }), { mode: 0o600 });
      const watermark = JSON.parse(readFileSync(legacy.watermarkPath, "utf8"));
      writeFileSync(legacy.watermarkPath, JSON.stringify({ ...watermark, through_seq: 4,
        through_event_id: records.at(-1).event_id, through_event_log_bytes: Buffer.byteLength(events) }), { mode: 0o600 });
      const oldHashes = savedFileHashes(legacy.source);
      const healthyId = await createLegacySavedSession(fixture, gateway);
      const env = { ...legacyGatewayEnv(fixture, gateway), FX_SOUND: "0", FX_SKIP_ONBOARDING: "1" };
      const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
      async function resume(args: string[], marker: string, label: string, binary = FX_BIN) {
        const stderrPath = join(fixture.root, `${label}.stderr`);
        tui = await TmuxSession.create({
          cmd: [binary, ...args].map(quote).join(" "), cwd: fixture.workspace,
          isolated: true, remainOnExit: true, width: 110, height: 40, stderrPath,
          env: { ...env, FX_RECORD: join(fixture.root, `${label}.fxtape`) },
        });
        await tui.waitForPane(pane => tui!.paneStatus().dead || pane.includes(marker), TIMEOUT);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(tui.paneStatus().dead).toBe(false);
        await tui.waitForStableComposer(TIMEOUT);
        expect(await tui.captureFullScrollback()).toContain(marker);
        await tui.sendText("/quit");
        await tui.waitForPane(() => tui!.paneStatus().dead, TIMEOUT);
        expect(tui.paneStatus().status).toBe(0);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await tui.kill(); tui = undefined;
      }
      await resume(["--resume-last"], "HEALTHY_LATEST_USAGE", "latest");
      expect(savedFileHashes(legacy.source)).toEqual(oldHashes);
      expect(gateway.requests).toHaveLength(1);
      expect(existsSync(join(fixture.home, ".fx", "sessions", healthyId))).toBe(true);

      await expectPendingLegacyRefusal(fixture, gateway, legacy.id);
      await resume(["--resume", legacy.id], LEGACY_ANSWER, "legacy-resolution", await ensureLegacyFixtureBinary());
      await resume(["--resume", legacy.id], LEGACY_ANSWER, "legacy");
      expectLegacyArchive(legacy.source);
      const base = JSON.parse(nativeJournalRecords(legacy.source)[0].nativeBase.stateJson);
      expect(base.id).toBe(legacy.id);
      expect(base.usage.billing).toBe("legacy");
      expect(base.usage.models).toEqual([]);
      expect(gateway.requests).toHaveLength(1);
      const continued = await continueSession(fixture, gateway, legacy.id);
      expect(continued.code).toBe(0);
      expect(continued.stderr).toBe("");
      expect(JSON.parse(continued.stdout).session_id).toBe(legacy.id);
      expect(continued.stdout).toContain("LEGACY_USAGE_CONTINUED");
      expectLegacyArchive(legacy.source);
      expect(gateway.requests).toHaveLength(2);
      expectLegacyRequest(gateway.requests[1]!);
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT * 3);

  test("recovery no-op requires a loadable legacy v4 conversation", async () => {
    const fixture = createFixture("fx-session-current-healthy-");
    const gateway = startFakeGateway([fakeGatewayFinalText("SAVED_HEALTHY")]);
    try {
      const id = await createLegacySavedSession(fixture, gateway);
      const source = join(fixture.home, ".fx", "sessions", id);
      const before = savedFileHashes(source);
      const result = await runFx(["session", "recover", id, "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe("");
      expect(JSON.parse(result.stdout).code).toBe("SessionRecoveryNotNeeded");
      expect(savedFileHashes(source)).toEqual(before);
      expect(readdirSync(join(fixture.home, ".fx", "sessions"))).toEqual([id]);
      expect(gateway.requests).toHaveLength(1);
      async function expectRefused(code: string) {
        const damaged = savedFileHashes(source);
        const refused = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(refused.code).toBe(1);
        expect(refused.stderr).toBe("");
        expect(JSON.parse(refused.stdout).code).toBe(code);
        expect(refused.stdout).not.toContain("resume it normally");
        expect(savedFileHashes(source)).toEqual(damaged);
        expect(readdirSync(join(fixture.home, ".fx", "sessions"))).toEqual([id]);
        expect(gateway.requests).toHaveLength(1);
      }
      const permissionPath = join(source, "permissions.json");
      const permissions = readFileSync(permissionPath);
      writeFileSync(permissionPath, "{broken", { mode: 0o600 });
      await expectRefused("InvalidPermissionState");
      writeFileSync(permissionPath, "", { mode: 0o600 });
      await expectRefused("PermissionStateTooLarge");
      writeFileSync(permissionPath, permissions, { mode: 0o600 });
      const usagePath = join(source, "usage-v2.json");
      rmSync(usagePath);
      mkdirSync(usagePath, { mode: 0o700 });
      await expectRefused("InvalidUsageSidecar");
      expect(readdirSync(usagePath)).toEqual([]);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const { checkpointedTurn, missingUsage, fullCoverage, damagedUsage } of [
    { checkpointedTurn: false, missingUsage: false, fullCoverage: false, damagedUsage: false },
    { checkpointedTurn: true, missingUsage: false, fullCoverage: false, damagedUsage: false },
    { checkpointedTurn: false, missingUsage: true, fullCoverage: false, damagedUsage: false },
    { checkpointedTurn: false, missingUsage: false, fullCoverage: true, damagedUsage: false },
    { checkpointedTurn: false, missingUsage: false, fullCoverage: false, damagedUsage: true },
  ]) {
    test(`legacy v4 conversation recovery preserves exact checkpoints and artifacts with open=${checkpointedTurn} missing usage=${missingUsage} full coverage=${fullCoverage} damaged usage=${damagedUsage}`, async () => {
      const fixture = createFixture("fx-session-current-copy-");
      const responses = [
        fakeShellRun("saved-effect", "printf 'ONCE_RECOVERY_731\\n' >> effect.log; printf 'RESULT_RECOVERY_982\\n'"),
        fakeGatewayFinalText("WORK_SAVED"),
      ];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runLegacyFx(["ask", "--json", "--full-access", "Save one command result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const metadataPath = join(source, "session.json");
        const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
        metadata.title = "Recovered work keeps its chosen title";
        writeFileSync(metadataPath, JSON.stringify(metadata), { mode: 0o600 });
        if (missingUsage) rmSync(join(source, "usage-v2.json"));
        if (damagedUsage) writeFileSync(join(source, "usage-v2.json"), "{damaged usage", { mode: 0o600 });
        const records = readFileSync(eventPath, "utf8").trimEnd().split("\n").map(JSON.parse);
        if (fullCoverage) records[0].event.user.work_id = "covered-recovery-work";
        const stored = records.find((record) => record.event.tool_result).event.tool_result;
        const coverage = fullCoverage ? records[records.length - 1].seq : 1;
        const append = (event: object) => records.push({
          schema_version: 1, seq: records.length + 1, timestamp_ms: Date.now(), event,
        });
        append({ context_checkpoint: { covers_through_seq: coverage, summary: "<context_handoff>Saved command completed.</context_handoff>" } });
        append({ context_checkpoint: { covers_through_seq: coverage, summary: "<context_handoff>Retain the completed command and its result.</context_handoff>" } });
        if (checkpointedTurn) {
          append({ user: { text: "Keep the already completed stored read.", work_id: "checkpointed-recovery-work" } });
          append({ tool_call: { call_id: "checkpointed-read", tool_name: "read_tool_result", arguments_json: JSON.stringify({ handle: stored.artifact_ref }) } });
          append({ tool_result: { ...stored, call_id: "checkpointed-read", tool_name: "read_tool_result" } });
          append({ context_checkpoint: { covers_through_seq: 1, summary: "<context_handoff>Checkpointed read is already complete.</context_handoff>" } });
        }
        const prefix = records.map((record) => JSON.stringify(record)).join("\n") + "\n";
        writeFileSync(eventPath, prefix + "invalid CORRUPT_TAIL_MUST_NOT_REPLAY\n", { mode: 0o600 });
        const before = savedFileHashes(source);
        const recovered = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(recovered.code).toBe(0);
        expect(recovered.stderr).toBe("");
        const result = JSON.parse(recovered.stdout);
        expect(result).toMatchObject({ kind: "session_recovery", source_id: id, status: "recovered" });
        expect(result.recovered_id).not.toBe(id);
        expect(gateway.requests).toHaveLength(2);
        expect(savedFileHashes(source)).toEqual(before);
        const target = join(fixture.home, ".fx", "sessions", result.recovered_id);
        if (damagedUsage || missingUsage) {
          const usage = JSON.parse(readFileSync(join(target, "usage-v2.json"), "utf8")).snapshot;
          expect(usage.billing).toBe("incomplete");
          expect(usage.api_duration_complete).toBe(false);
          expect(usage.wall_duration_complete).toBe(false);
          expect(usage.code_complete).toBe(false);
          expect(usage.incidents.length).toBeGreaterThan(0);
        }
        expect(JSON.parse(readFileSync(join(target, "session.json"), "utf8")).title).toBe(metadata.title);
        const targetEvents = readFileSync(join(target, "events.jsonl"), "utf8");
        expect(targetEvents.startsWith(prefix)).toBe(true);
        expect(targetEvents).not.toContain("CORRUPT_TAIL_MUST_NOT_REPLAY");
        const suffix = targetEvents.slice(prefix.length);
        if (checkpointedTurn) expect(JSON.parse(suffix).event).toEqual({ interrupted: expect.objectContaining({ reason: "failed" }) });
        else expect(suffix).toBe("");
        for (const [path, digest] of Object.entries(before)) {
          if (path.startsWith("tool-results/") || path.startsWith("logs/commands/")) {
            expect(savedFileHashes(target)[path]).toBe(digest);
          }
        }

        responses.push(
          fakeGatewayToolCall("read-recovered", "read_tool_result", { request: { handle: stored.artifact_ref, query: "RESULT_RECOVERY_982" } }),
          fakeGatewayFinalText("RECOVERED_CONTINUATION_SAVED"),
        );
        const tracePath = join(fixture.root, "continue.trace.log");
        const continued = await runFx(["ask", "--json", "--full-access", "--resume-id", result.recovered_id, "Read the retained result. Do not repeat completed commands."], {
          cwd: fixture.workspace,
          env: { ...gatewayEnv(fixture, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "tool,session,agent" },
          timeoutMs: TIMEOUT,
        });
        expect(continued.code).toBe(0);
        expect(JSON.parse(continued.stdout)).toMatchObject({ output: "RECOVERED_CONTINUATION_SAVED", tool_calls: [{ name: "read_tool_result", status: "success" }] });
        expect(gateway.requests).toHaveLength(4);
        const executionStarts = readFileSync(tracePath, "utf8").split("\n")
          .filter((line) => line.includes("[tool] event=execution_start "));
        expect(executionStarts).toHaveLength(1);
        expect(executionStarts[0]).toContain("call_id=read-recovered name=read_tool_result");
        const after = nativeJournalRecords(target);
        const readResult = after.find(record => record.kind === "tool_result" && record.persisted.tool_call_id === "read-recovered").persisted;
        expect(readResult.status).toBe("success");
        expect(readResult.output).toContain("RESULT_RECOVERY_982");
        if (readResult.output_handle) expect(readFileSync(join(target, "tool-results", readResult.output_handle), "utf8")).toContain("RESULT_RECOVERY_982");
        expect(readFileSync(join(fixture.workspace, "effect.log"), "utf8")).toBe("ONCE_RECOVERY_731\n");
        expect(savedFileHashes(source)).toEqual(before);
        const inspected = await runFx(["session", "--id", result.recovered_id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stderr).toBe("");
        expect(inspected.stdout).toContain("RECOVERED_CONTINUATION_SAVED");
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  for (const tail of ["", "invalid tail\n"]) {
    test(`legacy v4 recovery excludes checkpoint splitting a call/result pair with tail=${tail.length > 0}`, async () => {
      const fixture = createFixture("fx-session-current-cut-");
      const responses = [fakeShellRun("cut-call", "printf 'CUT_RESULT_619\\n'"), fakeGatewayFinalText("CUT_SAVED")];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runLegacyFx(["ask", "--json", "--full-access", "Save one result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const prefix = readFileSync(eventPath, "utf8");
        const records = prefix.trimEnd().split("\n").map(JSON.parse);
        const callSeq = records.find((record) => record.event.tool_call).seq;
        appendFileSync(eventPath, JSON.stringify({ schema_version: 1, seq: records.at(-1).seq + 1, timestamp_ms: Date.now(), event: {
          context_checkpoint: { covers_through_seq: callSeq, summary: "INVALID_SPLIT_CHECKPOINT" },
        } }) + "\n" + tail);
        const before = savedFileHashes(source);
        const recovered = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(recovered.code).toBe(0);
        expect(recovered.stderr).toBe("");
        const result = JSON.parse(recovered.stdout);
        expect(result.status).toBe("recovered");
        const target = join(fixture.home, ".fx", "sessions", result.recovered_id);
        expect(readFileSync(join(target, "events.jsonl"), "utf8")).toBe(prefix);
        expect(savedFileHashes(source)).toEqual(before);
        const inspected = await runFx(["session", "--id", result.recovered_id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stderr).toBe("");
        expect(inspected.stdout).toContain("CUT_SAVED");
        responses.push(fakeGatewayFinalText("CUT_CONTINUED"));
        const continued = await continueSession(fixture, gateway, result.recovered_id);
        expect(continued.code).toBe(0);
        expect(JSON.parse(continued.stdout).output).toBe("CUT_CONTINUED");
        expect(gateway.requests).toHaveLength(3);
        expect(savedFileHashes(source)).toEqual(before);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  for (const damage of ["metadata", "private-child", "private-marker", "first-record", "missing-result", "changed-result"] as const) {
    test(`legacy v4 conversation recovery refuses ${damage} without publishing a copy`, async () => {
      const fixture = createFixture("fx-session-current-refusal-");
      const gateway = startFakeGateway([
        fakeShellRun("retained-result", "printf 'REQUIRED_RESULT_619\\n'"),
        fakeGatewayFinalText("RESULT_SAVED"),
      ]);
      try {
        const created = await runLegacyFx(["ask", "--json", "--full-access", "Save a result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const committed = readFileSync(eventPath, "utf8");
        if (damage === "metadata" || damage === "private-child") {
          const metadataPath = join(source, "session.json");
          const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
          if (damage === "metadata") metadata.id = "different-session";
          else metadata.subagent_child = true;
          writeFileSync(metadataPath, JSON.stringify(metadata), { mode: 0o600 });
        } else if (damage === "private-marker") {
          mkdirSync(join(source, "subagent"), { recursive: true, mode: 0o700 });
          writeFileSync(join(source, "subagent", "owner.json"), "{}", { mode: 0o600 });
          appendFileSync(eventPath, "invalid tail\n");
        } else if (damage === "first-record") {
          writeFileSync(eventPath, "[" + committed.slice(1), { mode: 0o600 });
        } else {
          appendFileSync(eventPath, "invalid tail\n");
          const record = committed.trimEnd().split("\n").map(JSON.parse)
            .find((frame) => frame.event.tool_result).event.tool_result;
          const artifactPath = join(source, "tool-results", record.artifact_ref);
          if (damage === "missing-result") rmSync(artifactPath);
          else {
            const bytes = readFileSync(artifactPath);
            bytes[0] ^= 1;
            writeFileSync(artifactPath, bytes);
          }
        }
        const before = savedFileHashes(source);
        const result = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(1);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout).code).toBe(damage === "private-child" || damage === "private-marker" ? "SessionNotFound" : "SessionRecoveryBoundaryInvalid");
        expect(savedFileHashes(source)).toEqual(before);
        const sessionRoot = join(fixture.home, ".fx", "sessions");
        expect(readdirSync(sessionRoot).filter((name) => existsSync(join(sessionRoot, name, "session.json")))).toEqual([id]);
        expect(gateway.requests).toHaveLength(2);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test.skipIf(!tmuxAvailable())("resume picker preserves an unfinished legacy checkpoint until compatible recovery", async () => {
    const fixture = createFixture("fx-session-first-checkpoint-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("CHECKPOINT_TURN_RECOVERED"),
      fakeGatewayFinalText("CHECKPOINT_JOURNAL_CONTINUED"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const sessionId = await createLegacySavedSession(fixture, gateway);
      const eventsPath = join(fixture.home, ".fx", "sessions", sessionId, "events.jsonl");
      const checkpoint = [
        { user: { text: "unfinished first request", images: [], work_id: null } },
        { context_checkpoint: { covers_through_seq: 1, summary: "<context_handoff>FIRST_CHECKPOINT_FACT</context_handoff>" } },
      ].map((event, index) => JSON.stringify({
        schema_version: 1, seq: index + 1, timestamp_ms: Date.now(), event,
      })).join("\n") + "\n";
      writeFileSync(eventsPath, checkpoint, { mode: 0o600 });
      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(JSON.parse(listed.stdout).sessions[0].history_len).toBe(0);
      expect(JSON.parse(listed.stdout).sessions[0]).not.toHaveProperty("has_checkpoint");
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);

      await expectPendingLegacyRefusal(fixture, gateway, sessionId);
      const before = savedFileHashes(join(fixture.home, ".fx", "sessions", sessionId));
      const stderrPath = join(fixture.root, "tui.stderr");
      const tracePath = join(fixture.root, "picker.trace");
      tui = await TmuxSession.create({ cwd: fixture.workspace, env: { ...gatewayEnv(fixture, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "session" }, stderrPath });
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/resume");
      await tui.waitForText("Create the first saved turn.", TIMEOUT);
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);
      await tui.sendLiteralText("Create the first saved turn.");
      await tui.waitForPane(pane => /Sessions\s+1\b/.test(pane) && pane.includes("Create the first saved turn."), TIMEOUT);
      await tui.sendKeys("Enter");
      await tui.waitForPane(() => existsSync(tracePath) && readFileSync(tracePath, "utf8").includes("picker resume failed err=PendingTurnError"), TIMEOUT);
      expect(savedFileHashes(join(fixture.home, ".fx", "sessions", sessionId))).toEqual(before);
      expect(gateway.requests).toHaveLength(1);
      await tui.sendKeys("Escape");
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const resolved = await runLegacyFx(["ask", "--json", "--auto", "--resume-id", sessionId, "Continue after checkpoint."], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(resolved.code, resolved.stdout + resolved.stderr).toBe(0);
      expect(resolved.stdout).toContain("CHECKPOINT_TURN_RECOVERED");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("FIRST_CHECKPOINT_FACT");
      const continued = await continueSession(fixture, gateway, sessionId);
      expect(continued.code, continued.stdout + continued.stderr).toBe(0);
      expect(continued.stdout).toContain("CHECKPOINT_JOURNAL_CONTINUED");
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.requests[2]!.body).toContain("FIRST_CHECKPOINT_FACT");
      expect(gateway.requests[2]!.body).toContain("CHECKPOINT_TURN_RECOVERED");
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())("latest resume ignores unrelated history and unfinished migration", async () => {
    const fixture = createFixture("fx-continue-isolated-discovery-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("LOCAL_HISTORY_KEPT"),
      fakeGatewayFinalText("CONTINUE_DISCOVERY_OK"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const id = await createLegacySavedSession(fixture, gateway);
      const sessions = join(fixture.home, ".fx", "sessions");
      const unpublished = join(sessions, "unpublished");
      mkdirSync(unpublished, { mode: 0o700 });
      writeFileSync(join(unpublished, "session.lock"), "", { mode: 0o600 });
      const metadata = JSON.parse(readFileSync(join(sessions, id, "session.json"), "utf8"));
      const foreign = join(sessions, "foreign-history");
      mkdirSync(foreign, { mode: 0o700 });
      writeFileSync(join(foreign, "session.json"), JSON.stringify({
        ...metadata, id: "foreign-history", workspace_root: "/another-workspace",
      }), { mode: 0o600 });
      writeFileSync(join(foreign, "events.jsonl"), "UNRELATED_UNREADABLE_HISTORY\n", { mode: 0o600 });
      const fenced = join(sessions, "foreign-fenced");
      mkdirSync(fenced, { mode: 0o700 });
      writeFileSync(join(fenced, "session.json"), JSON.stringify({
        schema_version: 1, id: "foreign-fenced", created_at_ms: 1,
        updated_at_ms: Date.now(), workspace_root: "/another-workspace",
        conversation_language: "en", history_len: 0, history: [],
      }), { mode: 0o600 });
      writeFileSync(join(fenced, "authority.pending.json"), "pending", { mode: 0o600 });
      const foreignBefore = savedFileHashes(foreign);
      const fencedBefore = savedFileHashes(fenced);
      const stderrPath = join(fixture.root, "continue.stderr");
      tui = await TmuxSession.create({
        cmd: `${JSON.stringify(FX_BIN)} --resume-last`,
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), stderrPath,
      });
      await tui.waitForComposer(TIMEOUT);
      await tui.waitForText("LOCAL_HISTORY_KEPT", TIMEOUT);
      await tui.sendText("Continue the same conversation.");
      await tui.waitForText("CONTINUE_DISCOVERY_OK", TIMEOUT);
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("LOCAL_HISTORY_KEPT");
      expect(JSON.stringify(nativeHistory(join(sessions, id)))).toContain("CONTINUE_DISCOVERY_OK");
      expect(savedFileHashes(foreign)).toEqual(foreignBefore);
      expect(savedFileHashes(fenced)).toEqual(fencedBefore);
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())("latest resume reuses legacy ranking after opening the resume picker", async () => {
    const fixture = createFixture("fx-continue-ranking-cache-");
    const legacy = createLegacySession(fixture, 3);
    const gateway = startFakeGateway([fakeGatewayFinalText("LATEST_CACHE_HISTORY")]);
    let tui: TmuxSession | null = null;
    try {
      const id = await createLegacySavedSession(fixture, gateway);
      const before = savedFileHashes(legacy.source);
      for (const iteration of [0, 1]) {
        const trace = join(fixture.root, `ranking-${iteration}.trace`);
        const stderrPath = join(fixture.root, `ranking-${iteration}.stderr`);
        tui = await TmuxSession.create({
          cmd: `${JSON.stringify(FX_BIN)} --resume-last`, cwd: fixture.workspace, stderrPath,
          env: { ...gatewayEnv(fixture, gateway), FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "session,core" },
        });
        await tui.waitForComposer(TIMEOUT);
        await tui.waitForText("LATEST_CACHE_HISTORY", TIMEOUT);
        expect(readFileSync(trace, "utf8")).toContain(iteration === 0
          ? "legacy ranking cache reused=0 refreshed=1"
          : "legacy ranking cache reused=1 refreshed=0");
        if (iteration === 0) {
          await tui.sendText("/resume");
          await tui.waitForText(LEGACY_TITLE, TIMEOUT);
          await tui.waitForPane(() => readFileSync(trace, "utf8").includes("session catalog cache reused="), TIMEOUT);
          await tui.sendKeys("Escape");
          await tui.waitForPane((pane) => !pane.includes("Esc Close"), TIMEOUT);
          await tui.waitForComposer(TIMEOUT);
        }
        await tui.sendText("/quit");
        expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(savedFileHashes(legacy.source)).toEqual(before);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.classifierRequests).toHaveLength(0);
        await tui.kill();
        tui = null;
      }
      const resumed = await runFx(["session", "--id", id, "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(resumed.stdout).toContain("LATEST_CACHE_HISTORY");
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT * 2);

  for (const { version, entry } of [
    { version: 2, entry: "-r" },
    { version: 3, entry: "/resume" },
    { version: 4, entry: "--resume id" },
  ] as const) {
    test.skipIf(!tmuxAvailable())(`legacy v${version} pending checkpoint refuses conversion, resolves through ${entry}, and survives journal reopen`, async () => {
      const fixture = createFixture("fx-legacy-resume-flow-");
      const legacy = createLegacySession(fixture, version);
      const gateway = startFakeGateway([
        fakeGatewayFinalText("LEGACY_CONTINUE_SAVED"),
        fakeGatewayFinalText("LEGACY_EXACT_REOPEN_SAVED"),
      ], LEGACY_GATEWAY_OPTIONS);
      let tui: TmuxSession | null = null;
      try {
        const before = savedFileHashes(legacy.source);
        const inspected = await runFx(["session", "--id", legacy.id, "--json"], {
          cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stderr).toBe("");
        expect(inspected.stdout).toContain(LEGACY_ANSWER);
        expect(savedFileHashes(legacy.source)).toEqual(before);
        expect(gateway.requests).toHaveLength(0);

        const sessionsRoot = join(fixture.home, ".fx", "sessions");
        const sessionEntries = () => readdirSync(sessionsRoot).filter((name) => name !== ".resume-catalog").sort();
        const expectedSessionIds = [legacy.id];
        let blankSessionDir: string | null = null;
        expect(sessionEntries()).toEqual(expectedSessionIds);
        await expectPendingLegacyRefusal(fixture, gateway, legacy.id);
        const initialArgs = entry === "/resume" ? [] : entry === "-r" ? ["-r"] : ["--resume", legacy.id];
        // The compatible older binary predates remembered selection. Select its
        // migrated session in current fx before exercising -c.
        for (const [index, args] of [initialArgs, ["--resume", legacy.id], ["-c"]].entries()) {
          const stderrPath = join(fixture.root, `legacy-${index}.stderr`);
          tui = await TmuxSession.create({
            cmd: [index === 0 ? await ensureLegacyFixtureBinary() : FX_BIN, ...args].map((arg) => JSON.stringify(arg)).join(" "),
            cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), stderrPath,
          });
          if (index === 0 && entry !== "--resume id") {
            if (entry === "/resume") {
              await tui.waitForComposer(TIMEOUT);
              const created = sessionEntries().filter((name) => !expectedSessionIds.includes(name));
              expect(created).toHaveLength(1);
              const blankId = created[0]!;
              blankSessionDir = join(sessionsRoot, blankId);
              expect(lstatSync(blankSessionDir).isDirectory()).toBe(true);
              const blankMetadata = JSON.parse(readFileSync(join(blankSessionDir, "session.json"), "utf8"));
              expect(blankMetadata).toMatchObject({ schema_version: 4, id: blankId, workspace_root: fixture.workspace });
              expect(blankMetadata.subagent_child).not.toBe(true);
              expect(readFileSync(join(blankSessionDir, "events.jsonl"), "utf8")).toBe("");
              expect(existsSync(join(blankSessionDir, "recovery.json"))).toBe(false);
              expectedSessionIds.push(blankId);
              expectedSessionIds.sort();
              expect(sessionEntries()).toEqual(expectedSessionIds);
              await tui.sendText("/resume");
            }
            await tui.waitForText(LEGACY_TITLE, TIMEOUT);
            expect(savedFileHashes(legacy.source)).toEqual(before);
            expect(gateway.requests).toHaveLength(0);
            await tui.sendKeys("Enter");
          }
          await tui.waitForText(LEGACY_PARTIAL, TIMEOUT);
          await tui.waitForComposer(TIMEOUT);
          const scrollback = await tui.captureFullScrollbackEscapes();
          expect(scrollback).toContain(LEGACY_ANSWER);
          expect(scrollback.split(LEGACY_PARTIAL)).toHaveLength(2);
          expectLegacyArchive(legacy.source);
          expect(gateway.requests).toHaveLength(Math.max(0, index - 1));
          expect(gateway.classifierRequests).toHaveLength(0);

          // First close without a prompt; reopening must not resurrect recovery work.
          if (index > 0) {
            const reply = index === 1 ? "LEGACY_CONTINUE_SAVED" : "LEGACY_EXACT_REOPEN_SAVED";
            await tui.sendText(`Continue the migrated conversation after reopen ${index}.`);
            await tui.waitForText(reply, TIMEOUT);
            await tui.waitForComposer(TIMEOUT);
            await tui.waitForPane(() => JSON.stringify(nativeHistory(legacy.source)).includes(reply), TIMEOUT);
            expect(gateway.requests).toHaveLength(index);
            expectLegacyRequest(gateway.requests[index - 1]!);
            expectLegacyArchive(legacy.source);
          }
          await tui.sendText("/quit");
          expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
          expect(readFileSync(stderrPath, "utf8")).toBe("");
          expect(gateway.requests).toHaveLength(index);
          expect(gateway.classifierRequests).toHaveLength(0);
          expect(sessionEntries()).toEqual(expectedSessionIds);
          if (blankSessionDir) expect(readFileSync(join(blankSessionDir, "events.jsonl"), "utf8")).toBe("");
          await tui.kill();
          tui = null;
        }
        expect(readFileSync(join(fixture.root, "legacy.trace.log"), "utf8"))
          .not.toContain("[tool] event=execution_start ");
        expect(sessionEntries()).toEqual(expectedSessionIds);
      } finally {
        await tui?.kill();
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT * 3);
  }

  test("legacy ask resume fails closed at a bad watermark then preserves archived evidence on retry", async () => {
    const fixture = createFixture("fx-legacy-ask-recovery-");
    const legacy = createLegacySession(fixture, 4);
    const gateway = startFakeGateway([
      fakeGatewayFinalText("LEGACY_ASK_SAVED"),
      fakeGatewayFinalText("LEGACY_ASK_REOPEN_SAVED"),
    ], LEGACY_GATEWAY_OPTIONS);
    try {
      const watermark = readFileSync(legacy.watermarkPath, "utf8");
      writeFileSync(legacy.watermarkPath, JSON.stringify({
        ...JSON.parse(watermark), through_event_log_bytes: Buffer.byteLength(readFileSync(join(legacy.source, "events.jsonl"))) - 1,
      }));
      const before = savedFileHashes(legacy.source);
      const failed = await runFx(["ask", "--json", "--auto", "--resume-id", legacy.id, "Do not run with invalid history."], {
        cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(failed.timedOut).toBe(false);
      expect(failed.code).toBe(1);
      expect(gateway.requests).toHaveLength(0);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(savedFileHashes(legacy.source)).toEqual(before);
      expect(readdirSync(join(fixture.home, ".fx", "sessions"))).toEqual([legacy.id]);
      writeFileSync(legacy.watermarkPath, watermark);
      await expectPendingLegacyRefusal(fixture, gateway, legacy.id);
      for (const [index, args] of [["--resume-id", legacy.id], ["--resume", "last"]].entries()) {
        const result = await (index === 0 ? runLegacyFx : runFx)(["ask", "--json", "--auto", ...args, "Continue the synthetic saved conversation."], {
          cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code, result.stdout + result.stderr).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout)).toMatchObject({
          session_id: legacy.id, model: FAKE_GATEWAY_MODEL, tool_calls: [],
          output: index === 0 ? "LEGACY_ASK_SAVED" : "LEGACY_ASK_REOPEN_SAVED",
        });
        expect(gateway.requests).toHaveLength(index + 1);
        expectLegacyRequest(gateway.requests[index]!);
        expectLegacyArchive(legacy.source);
      }
      expect(gateway.requests[1]!.body).toContain("LEGACY_ASK_SAVED");
      expect(readFileSync(join(fixture.root, "legacy.trace.log"), "utf8"))
        .not.toContain("[tool] event=execution_start ");
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT * 2);

  for (const kind of ["recovery_checkpoint_cleared", "history_turn_committed"] as const) {
    test(`legacy ask resume does not resurrect a checkpoint superseded by ${kind}`, async () => {
      const fixture = createFixture("fx-legacy-checkpoint-superseded-");
      const legacy = createLegacySession(fixture, 4);
      const gateway = startFakeGateway([fakeGatewayFinalText("SUPERSESSION_ASK_SAVED")], LEGACY_GATEWAY_OPTIONS);
      try {
        const eventsPath = join(legacy.source, "events.jsonl");
        const events = readFileSync(eventsPath, "utf8");
        const records = events.trimEnd().split("\n").map(JSON.parse);
        const watermark = JSON.parse(readFileSync(legacy.watermarkPath, "utf8"));
        const supersedingAnswer = "LEGACY_SUPERSEDING_ANSWER";
        const event = {
          schema_version: 1, log_generation: watermark.log_generation,
          seq: watermark.through_seq + 1, event_id: "04".repeat(16), timestamp_ms: 40, kind,
          payload: kind === "recovery_checkpoint_cleared" ? {} : {
            ...records[1].payload,
            turn: {
              ...records[1].payload.turn,
              user: records[2].payload.checkpoint.user,
              assistant: supersedingAnswer,
            },
          },
        };
        const appended = JSON.stringify(event) + "\n";
        appendFileSync(eventsPath, appended);
        // Leave the derived manifest stale; the committed watermark owns the replay boundary.
        writeFileSync(legacy.watermarkPath, JSON.stringify({
          ...watermark, through_seq: event.seq, through_event_id: event.event_id,
          through_event_log_bytes: Buffer.byteLength(events + appended),
        }) + "\n");

        expect(gateway.requests).toHaveLength(0);
        const prompt = "Continue after the superseding legacy event.";
        const result = await runFx(["ask", "--json", "--auto", "--resume-id", legacy.id, prompt], {
          cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code, result.stdout + result.stderr).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout)).toMatchObject({
          session_id: legacy.id, output: "SUPERSESSION_ASK_SAVED", tool_calls: [],
        });
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.classifierRequests).toHaveLength(0);
        const request = gateway.requests[0]!.body;
        expect(request).toContain(prompt);
        expect(request).toContain(LEGACY_ANSWER);
        expect(request).not.toContain(LEGACY_PARTIAL);
        expect(request).not.toContain(LEGACY_TOOL_EVIDENCE);
        const migratedHistory = nativeHistory(legacy.source);
        const migrated = JSON.stringify(migratedHistory);
        expect(migrated).toContain(LEGACY_ANSWER);
        expect(migrated).toContain("SUPERSESSION_ASK_SAVED");
        expect(migrated).not.toContain(LEGACY_PARTIAL);
        expect(migrated).not.toContain(LEGACY_TOOL_CALL_ID);
        expect(migrated).not.toContain(LEGACY_TOOL_EVIDENCE);
        expect(migratedHistory.filter(turn => turn.kind === "interrupted"))
          .toHaveLength(0);
        if (kind === "history_turn_committed") {
          expect(request).toContain(supersedingAnswer);
          expect(migrated).toContain(supersedingAnswer);
        }
        expect(existsSync(join(legacy.source, "recovery.json"))).toBe(false);
        expect(readFileSync(join(fixture.root, "legacy.trace.log"), "utf8"))
          .not.toContain("[tool] event=execution_start ");
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  for (const { target, fileName, fenced } of [
    { target: "event log", fileName: "events.jsonl", fenced: false },
    { target: "fenced legacy snapshot", fileName: "session.legacy.json", fenced: true },
  ]) {
    test.skipIf(process.platform === "win32")(`ask resume last rejects a FIFO ${target} promptly without writes`, async () => {
      const fixture = createFixture("fx-session-fifo-");
      const gateway = startFakeGateway([fakeGatewayFinalText("FIFO_SOURCE_SAVED")]);
      try {
        const id = fenced ? "fenced-legacy-fifo" : await createLegacySavedSession(fixture, gateway);
        const source = join(fixture.home, ".fx", "sessions", id);
        if (fenced) {
          mkdirSync(source, { recursive: true, mode: 0o700 });
          const snapshot = JSON.stringify({
            schema_version: 1, id, created_at_ms: 1, updated_at_ms: Date.now(),
            workspace_root: fixture.workspace, conversation_language: "en", history_len: 0, history: [],
          });
          writeFileSync(join(source, "session.json"), snapshot, { mode: 0o600 });
          writeFileSync(join(source, "session.legacy.json"), snapshot, { mode: 0o600 });
          writeFileSync(join(source, "authority.pending.json"), "pending", { mode: 0o600 });
        }
        const fifoPath = join(source, fileName);
        const before = savedFileHashes(source);
        delete before[fileName];
        rmSync(fifoPath);
        execFileSync("mkfifo", ["-m", "600", fifoPath]);
        const fifoBefore = lstatSync(fifoPath);
        expect(fifoBefore.isFIFO()).toBe(true);
        const namesBefore = readdirSync(source, { recursive: true }).sort();
        const result = await runFx(["ask", "--json", "--auto", "--resume", "last", "Never open the FIFO."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: 5_000,
        });
        expect(result.timedOut).toBe(false);
        expect(result.killSent).toBe(false);
        expect(result.code).toBe(1);
        expect(result.elapsedMs).toBeLessThan(5_000);
        expect(result.stdout + result.stderr).toContain("SessionPathUnsafe");
        expect(gateway.requests).toHaveLength(fenced ? 0 : 1);
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readdirSync(source, { recursive: true }).sort()).toEqual(namesBefore);
        const fifoAfter = lstatSync(fifoPath);
        expect(fifoAfter.isFIFO()).toBe(true);
        expect([fifoAfter.ino, fifoAfter.size, fifoAfter.mtimeMs, fifoAfter.ctimeMs])
          .toEqual([fifoBefore.ino, fifoBefore.size, fifoBefore.mtimeMs, fifoBefore.ctimeMs]);
        // Never hash/read the FIFO: retain the regular-file and directory evidence separately.
        for (const [path, digest] of Object.entries(before)) {
          expect(createHash("sha256").update(readFileSync(join(source, path))).digest("hex")).toBe(digest);
        }
        expect(readdirSync(join(fixture.home, ".fx", "sessions"))).toEqual([id]);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test("latest resume preserves a partial legacy record until explicit recovery", async () => {
    const fixture = createFixture("fx-session-partial-record-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("PARTIAL_RECORD_RECOVERED"),
    ]);
    try {
      const sessionId = await createLegacySavedSession(fixture, gateway);
      const sessionDir = join(fixture.home, ".fx", "sessions", sessionId);
      const eventsPath = join(sessionDir, "events.jsonl");
      const committed = readFileSync(eventsPath, "utf8");
      appendFileSync(eventsPath, '{"schema_version":1,"partial-tail"');

      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace,
        env: gatewayEnv(fixture, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(listed.stderr).toBe("");
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(readFileSync(eventsPath, "utf8")).toBe(committed + '{"schema_version":1,"partial-tail"');

      const before = savedFileHashes(sessionDir);
      const refused = await continueSession(fixture, gateway, sessionId, true);
      expect(refused.code).toBe(1);
      expect(refused.stdout + refused.stderr).toContain("TruncatedEventFrame");
      expect(savedFileHashes(sessionDir)).toEqual(before);
      expect(gateway.requests).toHaveLength(1);
      const recovered = await runFx(["session", "recover", sessionId, "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(recovered.code, recovered.stdout + recovered.stderr).toBe(0);
      const copyId = JSON.parse(recovered.stdout).recovered_id;
      expect(copyId).not.toBe(sessionId);
      const copy = join(fixture.home, ".fx", "sessions", copyId);
      expect(readFileSync(join(copy, "events.jsonl"), "utf8")).toBe(committed);
      const resumed = await continueSession(fixture, gateway, copyId);
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).session_id).toBe(copyId);
      expect(JSON.parse(resumed.stdout).output).toBe("PARTIAL_RECORD_RECOVERED");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).not.toContain("partial-tail");

      expect(savedFileHashes(sessionDir)).toEqual(before);
      expect(JSON.stringify(nativeHistory(copy))).toContain("PARTIAL_RECORD_RECOVERED");
      expect(JSON.stringify(nativeHistory(copy))).not.toContain("partial-tail");
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const partialNextRecord of [false, true]) {
    test(`journal conversion preserves an unfinished legacy turn with partial next record=${partialNextRecord}`, async () => {
      const fixture = createFixture("fx-session-unfinished-turn-");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("FIRST_TURN_SAVED"),
        fakeGatewayFinalText("UNFINISHED_TURN_RECOVERED"),
      ]);
      try {
        const sessionId = await createLegacySavedSession(fixture, gateway);
        const eventsPath = join(
          fixture.home,
          ".fx",
          "sessions",
          sessionId,
          "events.jsonl",
        );
        const committed = readFileSync(eventsPath, "utf8");
        const lines = committed.trimEnd().split("\n");
        const last = JSON.parse(lines[lines.length - 1]!);
        appendFileSync(eventsPath, JSON.stringify({
          schema_version: 1,
          seq: last.seq + 1,
          timestamp_ms: Date.now(),
          event: {
            user: {
              text: "DANGLING_USER_MUST_NOT_REPLAY",
              images: [],
              work_id: null,
            },
          },
        }) + "\n");
        if (partialNextRecord) appendFileSync(eventsPath, '{"schema_version":1,"event":');

        const before = savedFileHashes(join(fixture.home, ".fx", "sessions", sessionId));
        const refused = await continueSession(fixture, gateway, sessionId);
        expect(refused.code).toBe(1);
        expect(refused.stdout + refused.stderr).toContain(partialNextRecord ? "TruncatedEventFrame" : "PendingTurnError");
        expect(savedFileHashes(join(fixture.home, ".fx", "sessions", sessionId))).toEqual(before);
        expect(gateway.requests).toHaveLength(1);
        const inspected = await runFx(["session", "--id", sessionId, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stdout).toContain("FIRST_TURN_SAVED");
        expect(savedFileHashes(join(fixture.home, ".fx", "sessions", sessionId))).toEqual(before);
        const resumed = await runLegacyFx(["ask", "--json", "--auto", "--resume-id", sessionId, "Continue after recovery."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(JSON.parse(resumed.stdout).output).toBe("UNFINISHED_TURN_RECOVERED");
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1]!.body).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
        expect(readFileSync(eventsPath, "utf8")).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test.each(["malformed", "oversized", "unreadable"])("committed-history corruption (%s) fails closed without rewriting JSONL", async (fault) => {
    const fixture = createFixture("fx-session-middle-corruption-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
    ]);
    try {
      const sessionId = await createLegacySavedSession(fixture, gateway);
      const eventsPath = join(
        fixture.home,
        ".fx",
        "sessions",
        sessionId,
        "events.jsonl",
      );
      const committed = readFileSync(eventsPath, "utf8");
      const corrupted = fault === "malformed"
        ? `[${committed.slice(1)}`
        : fault === "oversized" ? "x".repeat(64 * 1024 * 1024 + 1) + "\n" : committed;
      writeFileSync(eventsPath, corrupted, { mode: 0o600 });
      if (fault === "unreadable") chmodSync(eventsPath, 0);

      const detail = await runFx(
        ["session", "--id", sessionId, "--json"],
        {
          cwd: fixture.workspace,
          env: { HOME: fixture.home },
          timeoutMs: TIMEOUT,
        },
      );
      expect(detail.code).toBe(1);
      expect(detail.stderr).toBe("");
      expect(JSON.parse(detail.stdout)).toMatchObject({
        code: "SessionNotFound",
      });
      if (fault === "unreadable") chmodSync(eventsPath, 0o600);
      expect(readFileSync(eventsPath, "utf8")).toBe(corrupted);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
