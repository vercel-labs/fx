// Fake sign-in helper for tests/tla/drivers/configured_provider/driver.ts (`auth`).
// Reads scenario.json in <run-dir>, increments count, reports start and then
// printed/failed over HTTP to the driver's server so every event sits in one
// ordered log, then acts as the scenario says.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type HelperStep =
  | { kind: "token"; expires_at_offset_s?: number }
  | { kind: "fail"; exit_code?: number; stderr?: string }
  | { kind: "garbage" }
  | { kind: "hang"; delay_ms: number };

type HelperScenario = {
  server_url: string;
  steps: HelperStep[];
};

const runDir = process.argv[2];
if (!runDir) {
  process.stderr.write("missing run directory argument\n");
  process.exit(2);
}

const scenario = JSON.parse(readFileSync(join(runDir, "scenario.json"), "utf8")) as HelperScenario;
const countPath = join(runDir, "count");
const previous = existsSync(countPath) ? Number(readFileSync(countPath, "utf8").trim()) || 0 : 0;
const run = previous + 1;
writeFileSync(countPath, `${run}\n`);

async function report(body: Record<string, unknown>): Promise<void> {
  const response = await fetch(scenario.server_url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    process.stderr.write(`helper event post failed: ${response.status}\n`);
    process.exit(2);
  }
}

const step = scenario.steps[run - 1] ?? scenario.steps.at(-1);
if (!step) {
  process.stderr.write("empty helper scenario\n");
  process.exit(2);
}

await report({ event: "start", run });

if (step.kind === "hang") {
  await Bun.sleep(step.delay_ms);
  process.exit(0);
}

if (step.kind === "fail") {
  await report({ event: "failed", run });
  process.stderr.write(`${step.stderr ?? "no session"}\n`);
  process.exit(step.exit_code ?? 3);
}

if (step.kind === "garbage") {
  await report({ event: "failed", run });
  process.stdout.write("not-json-garbage\n");
  process.exit(0);
}

await report({ event: "printed", run, gen: run });
const payload: Record<string, unknown> = { token: `tok-${run}` };
if (step.expires_at_offset_s !== undefined) {
  payload.expires_at = Math.floor(Date.now() / 1000) + step.expires_at_offset_s;
}
process.stdout.write(`${JSON.stringify(payload)}\n`);
process.exit(0);
