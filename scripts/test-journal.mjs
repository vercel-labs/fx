#!/usr/bin/env node
// Focused, opt-in red suite. Run every selected layer even if an earlier one
// fails; never translate expected-red assertions into successful exit status.
import { spawnSync } from "node:child_process";
import { mkdirSync, openSync, closeSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
process.chdir(root);
const args = process.argv.slice(2);
const only = args.find((arg) => arg.startsWith("--only="))?.slice(7);
const layers = ["simulation", "core", "cli", "sdk"];
for (const arg of args) {
  if (arg !== "--no-build" && arg !== `--only=${only}`) throw new Error(`unknown argument: ${arg}`);
}
if (only && !layers.includes(only)) throw new Error(`--only must be one of ${layers.join(", ")}`);
const selected = only ? [only] : layers;
const logDirectory = join(root, ".zig-cache", "journal-results");
mkdirSync(logDirectory, { recursive: true });
let failed = false;
function run(name, command, argv) {
  const log = join(logDirectory, `${name}.log`);
  const fd = openSync(log, "w");
  let result;
  try {
    result = spawnSync(command, argv, {
      cwd: root, stdio: ["ignore", fd, fd],
      env: { ...process.env, FX_E2E_DISABLE_DOTENV: "1", FX_JOURNAL_RED: "1" },
    });
  } finally { closeSync(fd); }
  const ok = !result.error && result.signal == null && result.status === 0;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${command} ${argv.join(" ")} (exit ${result.status ?? "none"}${result.signal ? `, signal ${result.signal}` : ""})`);
  console.log(`  .zig-cache/journal-results/${name}.log`);
  if (result.error) console.error(result.error.message);
  failed ||= !ok;
  return ok;
}
if (!args.includes("--no-build") && selected.some((layer) => layer === "cli" || layer === "sdk")) {
  const buildArgs = selected.includes("sdk") ? ["build", "-Dnapi-surface=core", "-Dwasm-surface=core"] : ["build"];
  if (!run("build", "zig", buildArgs)) process.exit(1);
}
if (selected.includes("simulation")) {
  run("simulation-zig", "zig", ["test", "src/core/session/journal_simulation_tests.zig"]);
  run("simulation-host", process.execPath, ["--test", "--test-reporter=tap", "sdk/tests/journal/host-simulation.test.mjs"]);
}
if (selected.includes("core")) run("core", "zig", ["build", "test-journal"]);
if (selected.includes("cli")) run("cli", "bun", ["test", "tests/e2e/session-recovery.test.ts", "--test-name-pattern", "journal witness native crash"]);
if (selected.includes("sdk")) run("sdk", process.execPath, ["--test", "--test-reporter=tap", "sdk/tests/journal/runtime.test.mjs"]);
process.exitCode = failed ? 1 : 0;
