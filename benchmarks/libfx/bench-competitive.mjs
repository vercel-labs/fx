#!/usr/bin/env node
import { execFile, spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { sampleStats as stats } from "./workload.mjs";

const run = promisify(execFile);
const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const serverInput = value("--server", null);
const piInput = value("--pi-root", null);
const outDir = resolve(value("--out", "benchmarks/results/libfx"));
const samples = Number(value("--samples", "100"));
const warmups = Number(value("--warmups", "3"));
const rounds = Number(value("--rounds", "3"));
if (!serverInput || !piInput || samples !== 100 || warmups !== 3 || rounds !== 3) {
  throw new Error("competitive benchmark requires --server, --pi-root, --samples 100, --warmups 3, and --rounds 3");
}
const serverPath = resolve(serverInput);
const piRoot = resolve(piInput);

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const targetScript = resolve(root, "benchmarks/libfx/bench-competitive-target.mjs");
const piPackage = JSON.parse(await readFile(resolve(piRoot, "node_modules/@earendil-works/pi-coding-agent/package.json"), "utf8"));
if (piPackage.version !== "0.84.4") throw new Error("competitive benchmark requires Pi 0.84.4");
await mkdir(outDir, { recursive: true });
const server = spawn(serverPath, ["--port", "0"], { stdio: ["ignore", "pipe", "pipe"] });
const serverExit = new Promise((resolveExit) => server.once("close", resolveExit));
let serverError = "";
server.stderr.on("data", (chunk) => { serverError = (serverError + chunk).slice(-8192); });
const lines = createInterface({ input: server.stdout });
let startupTimer;
const addressReady = new Promise((resolveAddress, reject) => {
  startupTimer = setTimeout(() => reject(new Error("competitive server startup timed out")), 5000);
  server.once("error", reject);
  server.once("exit", (code) => reject(new Error(`competitive server exited ${code}: ${serverError}`)));
  lines.once("line", (line) => {
    try { resolveAddress(JSON.parse(line)); } catch (error) { reject(error); }
  });
});
let gatewayOrigin;

function summarize(rows) {
  return Object.fromEntries([
    "prompt_to_first_text_ms",
    "prompt_to_completion_ms",
    "prompt_to_fetch_ms",
    "fetch_to_headers_ms",
    "first_body_to_first_text_ms",
    "request_bytes",
  ].map((field) => [field, stats(rows.map((row) => row[field]))]));
}

async function execute(runtime, target) {
  const command = runtime === "node" ? process.execPath : "bun";
  const { stdout, stderr } = await run(command, [
    targetScript,
    "--target", target,
    "--gateway-origin", gatewayOrigin,
    "--pi-root", piRoot,
    "--samples", String(samples),
    "--warmups", String(warmups),
  ], { cwd: root, maxBuffer: 8 * 1024 * 1024, timeout: 60_000 });
  if (stderr) throw new Error(`${runtime} ${target} wrote unexpected stderr: ${stderr}`);
  return JSON.parse(stdout);
}

try {
  const address = await addressReady;
  clearTimeout(startupTimer);
  if (address.host !== "127.0.0.1" || !Number.isInteger(address.port) || address.port < 1 || address.port > 65535) {
    throw new Error("invalid benchmark server address");
  }
  gatewayOrigin = `http://${address.host}:${address.port}`;
  for (const runtime of ["node", "bun"]) {
    const reports = { libfx: [], pi: [] };
    const roundReports = [];
    for (let round = 0; round < rounds; round += 1) {
      const order = round % 2 === 0 ? ["libfx", "pi"] : ["pi", "libfx"];
      const completed = {};
      for (const target of order) {
        const report = await execute(runtime, target);
        if (report.request_count !== samples + warmups || report.rows.length !== samples) {
          throw new Error(`${runtime} ${target} round ${round + 1} made unexpected inference requests`);
        }
        reports[target].push(...report.rows);
        completed[target] = report;
        await writeFile(resolve(outDir, `competitive-${runtime}-${target}-r${round + 1}.json`), `${JSON.stringify(report, null, 2)}\n`);
      }
      roundReports.push({
        order,
        libfx_request_count: completed.libfx.request_count,
        pi_request_count: completed.pi.request_count,
      });
    }
    const report = {
      format_version: 1,
      pi_version: piPackage.version,
      runtime,
      samples_per_round: samples,
      warmups_per_round: warmups,
      rounds: roundReports,
      libfx: summarize(reports.libfx),
      pi: summarize(reports.pi),
    };
    await writeFile(resolve(outDir, `competitive-${runtime}.json`), `${JSON.stringify(report, null, 2)}\n`);
  }
} finally {
  clearTimeout(startupTimer);
  lines.close();
  if (server.exitCode === null) server.kill();
  await serverExit;
}
if (serverError) throw new Error(serverError);

console.log("wrote three alternating 100-sample native libfx versus Pi rounds for Node and Bun");
