// Stresses the quiet notice on the built fx, far past normal use, through
// fx ask against a local gateway:
//
//   sessions   60 quiet sessions alive at once, near the runtime's 64, each
//              result with its time fields, then each stopped
//   flood      200 MB of output while 5 s waits run, then quiet: the wait after
//              the flood reports the notice at its ceiling
//   rearm      a command that prints a line when signaled at each wait's start;
//              100 5 s waits in a row, each begun past the limit, re-armed by
//              the new line, and crossing again at its ceiling
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/managed_execution/stress.ts
//   bun tests/tla/drivers/managed_execution/stress.ts --rounds 300
//
// Exit codes: 0 every check held, 1 a check failed, 2 a harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { outDir } from "../lib/tlc";

const MODEL = "openai/gpt-5.5";

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} takes a whole number above 0`);
  return value;
}

const options = { sessions: option("--sessions", 60), rounds: option("--rounds", 100), floodMb: option("--flood-mb", 200) };

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function shellResult(body: string, callId: string): Record<string, any> {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content: unknown }> }).prompt;
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && part.toolCallId === callId) return JSON.parse(contentText(part.output));
    }
  }
  throw new Error(`missing tool result for ${callId}`);
}

type Step = (body: string, now: number, workspace: string) => Response | null;

// Runs one fx ask that plays `next` as the model until it returns null, then
// ends the turn. Returns the failed checks.
async function play(
  name: string,
  limitMs: number,
  next: Step,
  out: string,
): Promise<{ failures: string[]; trace: string }> {
  const { startDynamicFakeGateway, fakeGatewayFinalText } = await targetHelpers();
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-quiet-stress-${name}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const failures: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    if (failures.length > 0) return fakeGatewayFinalText("Stress failed.");
    try {
      return next(body, Date.now(), workspace) ?? fakeGatewayFinalText("Stress done.");
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
      return fakeGatewayFinalText("Stress failed.");
    }
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const started = performance.now();
  try {
    const proc = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-save", `Run the ${name} stress.`], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-quiet-stress-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: MODEL,
        FX_MAX_AGENT_STEPS: "1000",
        FX_TEST_SHELL_QUIET_NOTICE_MS: String(limitMs),
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "shell",
      }),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    writeFileSync(join(out, `${name}.log`), `${stdout}\n[stderr]\n${stderr}\n`);
    if (exitCode !== 0) failures.push(`fx exited ${exitCode}: ${stderr.slice(0, 400)}`);
    if (!stdout.includes("Stress done.") && failures.length === 0) failures.push("the turn did not end with the final reply");
    console.log(`${name}: ${failures.length === 0 ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms`);
    return { failures, trace };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

function check(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

async function sessions(out: string): Promise<string[]> {
  const { fakeGatewayToolCall } = await targetHelpers();
  const ids: string[] = [];
  let step = 0;
  const { failures } = await play("sessions", 1_000, (body) => {
    const n = options.sessions;
    const k = step++;
    if (k > 0 && k <= n) {
      const started = shellResult(body, `start_${k - 1}`);
      check(started.state === "running", `session ${k - 1} state ${started.state}`);
      check(typeof started.running_ms === "number" && typeof started.quiet_ms === "number", `session ${k - 1} has no time fields`);
      ids.push(started.session_id);
    }
    if (k > n && k <= 2 * n) {
      const stopped = shellResult(body, `stop_${k - n - 1}`);
      check(stopped.state === "stopped", `stop ${k - n - 1} state ${stopped.state}`);
      check(stopped.running_ms === undefined && stopped.quiet_notice === undefined, `stop ${k - n - 1} kept time fields`);
    }
    if (k < n) {
      return fakeGatewayToolCall(`start_${k}`, "shell", {
        request: { action: "run", command: `printf 'session-${k}\\n'; sleep 60`, profile: "clean", yield_time_ms: 0 },
      });
    }
    if (k < 2 * n) {
      return fakeGatewayToolCall(`stop_${k - n}`, "shell", { request: { action: "stop", session_id: ids[k - n] } });
    }
    return null;
  }, out);
  return failures;
}

async function flood(out: string): Promise<string[]> {
  const { fakeGatewayToolCall } = await targetHelpers();
  const limitMs = 150;
  const maxWaits = 30;
  let step = 0;
  let sessionId = "";
  let waitStarted = 0;
  let sawFloodEnd = false;
  let totalWaited = 0;
  const { failures } = await play("flood", limitMs, (body, now) => {
    const k = step++;
    if (k === 0) {
      return fakeGatewayToolCall("flood_run", "shell", {
        request: {
          action: "run",
          command: `head -c ${options.floodMb * 1_000_000} /dev/zero | tr '\\0' x; printf '\\nFLOOD-END\\n'; sleep 60`,
          profile: "clean",
          yield_time_ms: 0,
        },
      });
    }
    if (k === 1) {
      sessionId = shellResult(body, "flood_run").session_id;
      waitStarted = Date.now();
      return fakeGatewayToolCall("flood_wait_0", "shell", {
        request: { action: "interact", session_id: sessionId, yield_time_ms: 5_000 },
      });
    }
    const waitIndex = k - 2;
    if (waitIndex < maxWaits) {
      const waited = now - waitStarted;
      totalWaited += waited;
      const result = shellResult(body, `flood_wait_${waitIndex}`);
      check(waited >= 5_000, `flood wait ${waitIndex} ended early after ${waited} ms`);
      check(result.state === "running", `flood state ${result.state}`);
      if (typeof result.output_delta === "string" && result.output_delta.includes("FLOOD-END")) {
        sawFloodEnd = true;
      }
      if (sawFloodEnd && typeof result.quiet_notice === "string") {
        check(result.quiet_ms >= limitMs, `flood quiet_ms ${result.quiet_ms}`);
        check(result.running_ms - result.quiet_ms > 0, `flood running_ms ${result.running_ms}`);
        console.log(`flood: ${options.floodMb} MB, ${waitIndex + 1} waits (${totalWaited} ms), running ${result.running_ms} ms, quiet ${result.quiet_ms} ms`);
        step = maxWaits + 2;
        return fakeGatewayToolCall("flood_stop", "shell", { request: { action: "stop", session_id: sessionId } });
      }
      if (waitIndex + 1 < maxWaits) {
        waitStarted = Date.now();
        return fakeGatewayToolCall(`flood_wait_${waitIndex + 1}`, "shell", {
          request: { action: "interact", session_id: sessionId, yield_time_ms: 5_000 },
        });
      }
      throw new Error(`flood did not settle with quiet_notice within ${maxWaits} waits`);
    }
    return null;
  }, out);
  return failures;
}

async function rearm(out: string): Promise<string[]> {
  const { fakeGatewayToolCall } = await targetHelpers();
  const limitMs = 150;
  let step = 0;
  let sessionId = "";
  let waitStarted = 0;
  const waits: number[] = [];
  const { failures, trace } = await play("rearm", limitMs, (body, now, workspace) => {
    const k = step++;
    if (k === 0) {
      return fakeGatewayToolCall("rearm_run", "shell", {
        request: {
          action: "run",
          command: "i=0; while :; do if [ -f \"step-$i\" ]; then rm -f \"step-$i\"; printf 'tick-%d\\n' \"$i\"; i=$((i+1)); fi; sleep 0.05; done",
          profile: "clean",
          yield_time_ms: 0,
        },
      });
    }
    if (k === 1) {
      sessionId = shellResult(body, "rearm_run").session_id;
    } else if (k <= options.rounds + 1) {
      const result = shellResult(body, `rearm_wait_${k - 2}`);
      const waited = now - waitStarted;
      waits.push(waited);
      check(waited >= 5_000, `wait ${k - 2} ended early after ${waited} ms`);
      check(result.state === "running", `wait ${k - 2} state ${result.state}`);
      check(typeof result.quiet_notice === "string", `wait ${k - 2} ended without the notice after ${waited} ms`);
      check(result.quiet_ms >= limitMs && result.quiet_ms < 5_500, `wait ${k - 2} quiet_ms ${result.quiet_ms}`);
      check(result.output_delta.includes(`tick-${k - 2}`), `wait ${k - 2} carried no new line`);
    }
    if (k <= options.rounds) {
      const round = k - 1;
      writeFileSync(join(workspace, `step-${round}`), "");
      waitStarted = Date.now();
      return fakeGatewayToolCall(`rearm_wait_${round}`, "shell", {
        request: { action: "interact", session_id: sessionId, yield_time_ms: 5_000 },
      });
    }
    if (k === options.rounds + 1) {
      const sorted = [...waits].sort((a, b) => a - b);
      const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
      console.log(`rearm: ${waits.length} waits, p50 ${at(0.5)} ms, p99 ${at(0.99)} ms, max ${sorted[sorted.length - 1]} ms`);
      return fakeGatewayToolCall("rearm_stop", "shell", { request: { action: "stop", session_id: sessionId } });
    }
    return null;
  }, out);
  const crossings = trace.split("\n").filter((line) => line.includes("event=quiet_crossing")).length;
  if (crossings !== options.rounds) failures.push(`expected ${options.rounds} quiet_crossing events, got ${crossings}`);
  return failures;
}

const out = outDir("managed-execution-stress");
const failures: string[] = [];
for (const [name, run] of [["sessions", sessions], ["flood", flood], ["rearm", rearm]] as const) {
  for (const failure of await run(out)) failures.push(`${name}: ${failure}`);
}
for (const failure of failures) console.log(`  ${failure}`);
console.log(`${failures.length === 0 ? "ok" : "FAIL"}; output in ${out}`);
process.exit(failures.length === 0 ? 0 : 1);
