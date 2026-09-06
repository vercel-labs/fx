import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
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

function expectLegacyArchive(source: string) {
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

describe("session recovery", () => {
  test("healthy current conversation needs no recovery or migration", async () => {
    const fixture = createFixture("fx-session-current-healthy-");
    const gateway = startFakeGateway([fakeGatewayFinalText("SAVED_HEALTHY")]);
    try {
      const id = await createSavedSession(fixture, gateway);
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
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const { checkpointedTurn, missingUsage, fullCoverage } of [
    { checkpointedTurn: false, missingUsage: false, fullCoverage: false },
    { checkpointedTurn: true, missingUsage: false, fullCoverage: false },
    { checkpointedTurn: false, missingUsage: true, fullCoverage: false },
    { checkpointedTurn: false, missingUsage: false, fullCoverage: true },
  ]) {
    test(`current conversation recovery preserves exact checkpoints and artifacts with open=${checkpointedTurn} missing usage=${missingUsage} full coverage=${fullCoverage}`, async () => {
      const fixture = createFixture("fx-session-current-copy-");
      const responses = [
        fakeShellRun("saved-effect", "printf 'ONCE_RECOVERY_731\\n' >> effect.log; printf 'RESULT_RECOVERY_982\\n'"),
        fakeGatewayFinalText("WORK_SAVED"),
      ];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save one command result."], {
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
        const after = readFileSync(join(target, "events.jsonl"), "utf8").trimEnd().split("\n").map(JSON.parse);
        const readResult = after.find((record) => record.event.tool_result?.call_id === "read-recovered").event.tool_result;
        expect(readResult.status).toBe("success");
        expect(readFileSync(join(target, "tool-results", readResult.artifact_ref), "utf8")).toContain("RESULT_RECOVERY_982");
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
    test(`current recovery excludes checkpoint splitting a call/result pair with tail=${tail.length > 0}`, async () => {
      const fixture = createFixture("fx-session-current-cut-");
      const responses = [fakeShellRun("cut-call", "printf 'CUT_RESULT_619\\n'"), fakeGatewayFinalText("CUT_SAVED")];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save one result."], {
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
    test(`current conversation recovery refuses ${damage} without publishing a copy`, async () => {
      const fixture = createFixture("fx-session-current-refusal-");
      const gateway = startFakeGateway([
        fakeShellRun("retained-result", "printf 'REQUIRED_RESULT_619\\n'"),
        fakeGatewayFinalText("RESULT_SAVED"),
      ]);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save a result."], {
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

  test.skipIf(!tmuxAvailable())("resume picker discovers a checkpoint from an unfinished first turn", async () => {
    const fixture = createFixture("fx-session-first-checkpoint-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("CHECKPOINT_TURN_RECOVERED"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const sessionId = await createSavedSession(fixture, gateway);
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

      const stderrPath = join(fixture.root, "tui.stderr");
      tui = await TmuxSession.create({ cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), stderrPath });
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/resume");
      await tui.waitForText("Create the first saved turn.", TIMEOUT);
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);
      await tui.sendKeys("Enter");
      await tui.waitForText("unfinished first request", TIMEOUT);
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("Continue after checkpoint.");
      await tui.waitForPane(() => readFileSync(eventsPath, "utf8").includes("CHECKPOINT_TURN_RECOVERED"), TIMEOUT);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("FIRST_CHECKPOINT_FACT");
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())("continue ignores unrelated history and unfinished migration", async () => {
    const fixture = createFixture("fx-continue-isolated-discovery-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("LOCAL_HISTORY_KEPT"),
      fakeGatewayFinalText("CONTINUE_DISCOVERY_OK"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const id = await createSavedSession(fixture, gateway);
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
        cmd: `${JSON.stringify(FX_BIN)} -c`,
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
      expect(readFileSync(join(sessions, id, "events.jsonl"), "utf8")).toContain("CONTINUE_DISCOVERY_OK");
      expect(savedFileHashes(foreign)).toEqual(foreignBefore);
      expect(savedFileHashes(fenced)).toEqual(fencedBefore);
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())("continue reuses legacy ranking after opening the resume picker", async () => {
    const fixture = createFixture("fx-continue-ranking-cache-");
    const legacy = createLegacySession(fixture, 3);
    const gateway = startFakeGateway([fakeGatewayFinalText("LATEST_CACHE_HISTORY")]);
    let tui: TmuxSession | null = null;
    try {
      const id = await createSavedSession(fixture, gateway);
      const before = savedFileHashes(legacy.source);
      for (const iteration of [0, 1]) {
        const trace = join(fixture.root, `ranking-${iteration}.trace`);
        const stderrPath = join(fixture.root, `ranking-${iteration}.stderr`);
        tui = await TmuxSession.create({
          cmd: `${JSON.stringify(FX_BIN)} -c`, cwd: fixture.workspace, stderrPath,
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
      expect(resumed.code).toBe(0);
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
    test.skipIf(!tmuxAvailable())(`legacy v${version} checkpoint resumes through ${entry} and survives close/reopen`, async () => {
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
        const initialArgs = entry === "/resume" ? [] : entry === "-r" ? ["-r"] : ["--resume", legacy.id];
        for (const [index, args] of [initialArgs, ["-c"], ["--resume", legacy.id]].entries()) {
          const stderrPath = join(fixture.root, `legacy-${index}.stderr`);
          tui = await TmuxSession.create({
            cmd: [FX_BIN, ...args].map((arg) => JSON.stringify(arg)).join(" "),
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
            await tui.waitForPane(() => readFileSync(join(legacy.source, "events.jsonl"), "utf8").includes(reply), TIMEOUT);
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

      for (const [index, args] of [["--resume-id", legacy.id], ["--resume", "last"]].entries()) {
        const result = await runFx(["ask", "--json", "--auto", ...args, "Continue the synthetic saved conversation."], {
          cwd: fixture.workspace, env: legacyGatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
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
        expect(result.code).toBe(0);
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
        const migrated = readFileSync(eventsPath, "utf8");
        expect(migrated).toContain(LEGACY_ANSWER);
        expect(migrated).toContain("SUPERSESSION_ASK_SAVED");
        expect(migrated).not.toContain(LEGACY_PARTIAL);
        expect(migrated).not.toContain(LEGACY_TOOL_CALL_ID);
        expect(migrated).not.toContain(LEGACY_TOOL_EVIDENCE);
        expect(migrated.trimEnd().split("\n").map(JSON.parse).filter((record) => record.event.interrupted))
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
        const id = fenced ? "fenced-legacy-fifo" : await createSavedSession(fixture, gateway);
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

  test("latest resume discovers and repairs a partial final JSONL record", async () => {
    const fixture = createFixture("fx-session-partial-record-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("PARTIAL_RECORD_RECOVERED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
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

      const resumed = await continueSession(fixture, gateway, sessionId, true);
      expect(resumed.code).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).session_id).toBe(sessionId);
      expect(JSON.parse(resumed.stdout).output).toBe("PARTIAL_RECORD_RECOVERED");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).not.toContain("partial-tail");

      const repaired = readFileSync(eventsPath, "utf8");
      expect(repaired.startsWith(committed)).toBe(true);
      expect(repaired).not.toContain("partial-tail");
      const files = readdirSync(sessionDir, { withFileTypes: true })
        .filter((entry) => entry.isFile())
        .map((entry) => entry.name)
        .sort();
      expect(files).toEqual([
        "events.jsonl",
        "permissions.json",
        "session.json",
        "session.lock",
        "usage-v2.json",
      ]);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const partialNextRecord of [false, true]) {
    test(`writable resume truncates an unfinished turn with partial next record=${partialNextRecord}`, async () => {
      const fixture = createFixture("fx-session-unfinished-turn-");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("FIRST_TURN_SAVED"),
        fakeGatewayFinalText("UNFINISHED_TURN_RECOVERED"),
      ]);
      try {
        const sessionId = await createSavedSession(fixture, gateway);
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

        const resumed = await continueSession(fixture, gateway, sessionId);
        expect(resumed.code).toBe(0);
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

  test("committed-history corruption fails closed without rewriting JSONL", async () => {
    const fixture = createFixture("fx-session-middle-corruption-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const eventsPath = join(
        fixture.home,
        ".fx",
        "sessions",
        sessionId,
        "events.jsonl",
      );
      const committed = readFileSync(eventsPath, "utf8");
      const corrupted = `[${committed.slice(1)}`;
      writeFileSync(eventsPath, corrupted, { mode: 0o600 });

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
      expect(readFileSync(eventsPath, "utf8")).toBe(corrupted);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
