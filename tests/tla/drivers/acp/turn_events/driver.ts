// Runtime driver: runs the real `fx acp` binary through three turns (a large
// reply, a turn that compacts the context first, and a shell call with a
// reply) for clients that list different parts of the turn events, and
// checks the camelCase fields of each sh.fx/commandResult it reads.
// It records every turn event the client reads, in order, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpTurnEvents.tla.
//
//   bun tests/tla/drivers/acp/turn_events/driver.ts                 # after zig build
//   bun tests/tla/drivers/acp/turn_events/driver.ts --model today   # fx acp before turn events
//   bun tests/tla/drivers/acp/turn_events/driver.ts --model root-field   # before sh.fx/commandResult
//
// --model rules (the default) checks the turn events rules. --model today
// checks the model of fx acp before them; a build of #2021, chosen with
// FX_WORKTREE or FX_BIN, fails --model rules for every client that lists a
// part. --model root-field checks fx acp with those rules but a root
// command_result field on shell calls; a build of #2044 fails --model rules
// for every client. --only takes a pattern of plan names. No model calls: every reply
// comes from a fake Gateway.
import { existsSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, SHELL_CALL_ID, SHELL_COMMAND } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Model, type Observation, type Parts, validate } from "./trace";

type Plan = { name: string; parts: Parts };

const PLANS: Plan[] = [
  { name: "all-parts", parts: ["progress", "calls", "usage", "compaction", "command"] },
  { name: "plain-client", parts: [] },
  { name: "calls-and-compaction", parts: ["calls", "compaction"] },
  { name: "progress-and-usage", parts: ["progress", "usage"] },
  { name: "command-only", parts: ["command"] },
];

const PROMPTS = ["Write the long reply.", "Continue.", `Run ${SHELL_COMMAND}, then finish.`];

/// Where a shell call's last update carried its command result.
function commandTag(update: any): "meta" | "root" | "both" | "none" {
  const meta = update._meta?.["sh.fx/commandResult"] !== undefined;
  const root = "command_result" in update;
  return meta && root ? "both" : meta ? "meta" : root ? "root" : "none";
}

/// The fields of sh.fx/commandResult that this run fixes, in camelCase, with
/// no snake_case name and no value left as null.
function checkCommandResult(result: any, workspace: string): string | null {
  if (typeof result !== "object" || result === null) return "is not an object";
  const snake = Object.keys(result).filter((key) => key.includes("_"));
  if (snake.length) return `has snake_case names ${snake.join(", ")}`;
  const nulls = Object.keys(result).filter((key) => result[key] === null);
  if (nulls.length) return `has null values ${nulls.join(", ")}`;
  if ("kind" in result) return "has kind";
  if (result.command !== SHELL_COMMAND) return `command is ${JSON.stringify(result.command)}`;
  if (result.cwd !== workspace) return `cwd is ${JSON.stringify(result.cwd)}`;
  if (result.exitCode !== 0) return `exitCode is ${JSON.stringify(result.exitCode)}`;
  if (result.timedOut !== false) return `timedOut is ${JSON.stringify(result.timedOut)}`;
  if (result.stdoutBytes !== "TURN_EVENTS_NOTE\n".length) return `stdoutBytes is ${JSON.stringify(result.stdoutBytes)}`;
  return null;
}

function capabilities(parts: Parts): object {
  const meta: Record<string, object> = {};
  if (parts.includes("progress")) meta["sh.fx/turnProgress"] = {};
  if (parts.includes("calls")) meta["sh.fx/modelCalls"] = {};
  if (parts.includes("usage")) meta["sh.fx/usage"] = {};
  if (parts.includes("command")) meta["sh.fx/commandResult"] = {};
  return { ...(parts.includes("compaction") ? { session: { compaction: {} } } : {}), _meta: meta };
}

async function runPlan(plan: Plan) {
  const fixture = new Fixture();
  const observations: Observation[] = [];
  const compactionIds = new Map<string, number>();
  let error: string | null = null;
  let process: { exit: number; stderr: string } | null = null;
  try {
    const client = await fixture.start(capabilities(plan.parts));
    const created = await client.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
    if (created.answer.error) throw new Error(`session/new failed: ${JSON.stringify(created.answer.error)}`);
    const sessionId = created.answer.result.sessionId;
    for (const text of PROMPTS) {
      const start = client.inbox.length;
      const requestsBefore = fixture.requests.length;
      observations.push({ kind: "prompt" });
      const { answer, id } = await client.request("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
      if (answer.error || answer.result?.stopReason !== "end_turn") throw new Error(`prompt failed: ${JSON.stringify(answer)}`);
      const turnRequests = fixture.requests.slice(requestsBefore);
      for (const message of client.inbox.slice(start)) {
        if (message.method === "_sh.fx/session/turn_progress") observations.push({ kind: "progress" });
        else if (message.method === "_sh.fx/session/model_call") observations.push({ kind: "call" });
        else if (
          message.method === "session/update" && message.params?.update?.sessionUpdate === "tool_call_update" &&
          message.params.update.toolCallId === SHELL_CALL_ID && ["completed", "failed"].includes(message.params.update.status)
        ) {
          const update = message.params.update;
          const status = commandTag(update);
          if (status === "meta") {
            const wrong = checkCommandResult(update._meta["sh.fx/commandResult"], fixture.workspace);
            if (wrong) throw new Error(`sh.fx/commandResult ${wrong}`);
          }
          observations.push({ kind: "tool", status });
        } else if (message.method === "session/update" && message.params?.update?.sessionUpdate === "compaction_update") {
          const update = message.params.update;
          if (!compactionIds.has(update.compactionId)) compactionIds.set(update.compactionId, compactionIds.size + 1);
          observations.push({ kind: "comp", k: compactionIds.get(update.compactionId)!, status: update.status });
        } else if (message.id === id) {
          observations.push({
            kind: "response",
            usage: message.result?._meta?.["sh.fx/usage"] !== undefined,
            calls: turnRequests.length,
            shells: turnRequests.some((request) => request.body.includes(SHELL_CALL_ID)) ? 1 : 0,
            streamed: true,
            compacted: turnRequests.some((request) => request.body.includes("compacted_conversation")),
          });
        }
      }
    }
    const second = observations.filter((o) => o.kind === "response")[1];
    if (!second || second.kind !== "response" || !second.compacted) throw new Error("the second turn did not compact the context");
    process = await client.close();
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  } finally {
    fixture.dispose();
  }
  return { observations, error, process };
}

/// A run the model must not allow. Under the rules, the first model call
/// the client read is dropped; today, a progress message is added.
function tamper(observations: Observation[], rules: boolean): Observation[] | null {
  const copy = observations.map((o) => ({ ...o }));
  if (rules) {
    const at = copy.findIndex((o) => o.kind === "call");
    if (at === -1) return null;
    copy.splice(at, 1);
    return copy;
  }
  const at = copy.findIndex((o) => o.kind === "response");
  if (at === -1) return null;
  copy.splice(at, 0, { kind: "progress" });
  return copy;
}

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = (argValue("--model") ?? "rules") as Model;
  if (!["rules", "today", "root-field"].includes(model)) throw new Error(`--model must be rules, today, or root-field, not ${model}`);
  const rules = model !== "today";
  const only = argValue("--only");

  const reportDir = outDir(`acp-turn-events-${model}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const results = [];
  let tamperSource: { observations: Observation[]; parts: Parts } | null = null;
  for (const plan of PLANS.filter((p) => !only || new RegExp(only).test(p.name))) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan);
    writeJson(join(dir, "observations.json"), run.observations);
    const processFailed = run.process !== null && (run.process.exit !== 0 || run.process.stderr !== "");
    const checked = run.error ? null : await validate(run.observations, dir, model, plan.parts);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    if (verdict === "ACCEPTED" && !tamperSource && tamper(run.observations, rules)) tamperSource = { observations: run.observations, parts: plan.parts };
    const kinds = run.observations.reduce<Record<string, number>>((acc, o) => ({ ...acc, [o.kind]: (acc[o.kind] ?? 0) + 1 }), {});
    results.push({ name: plan.name, verdict, kinds, error: run.error, process: run.process });
    console.log(`${plan.name} [${plan.parts.join(",") || "none"}]: ${verdict} ${JSON.stringify(kinds)}${run.error ? ` ${run.error}` : ""}`);
  }

  // Controls show the checker separates runs the model allows from runs it doesn't.
  const controls = [];
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), model, [])).verdict });
  if (tamperSource) {
    const tampered = tamper(tamperSource.observations, rules)!;
    controls.push({ name: rules ? "tampered-dropped-call" : "tampered-added-progress", expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", "tampered"), model, tamperSource.parts)).verdict });
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.length === 2 && controls.every((control) => control.got === control.expect);
  writeJson(join(reportDir, "summary.json"), { manifest, counts, controlsPassed, controls, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "pass" : "FAIL"}`);
  console.log(`report: ${reportDir}`);
  if (!controlsPassed || results.some((result) => result.verdict !== "ACCEPTED")) process.exit(1);
}

await main();
