#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { cp, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { serializeError } from "./package-report.mjs";

const input = process.argv[2];
assert.ok(input, "provide a published libfx version or local tarball");
const projectId = process.env.LIBFX_VERCEL_PROJECT_ID;
const orgId = process.env.LIBFX_VERCEL_ORG_ID;
assert.ok(projectId && orgId, "LIBFX_VERCEL_PROJECT_ID and LIBFX_VERCEL_ORG_ID are required");
assert.ok(process.env.AI_GATEWAY_API_KEY, "AI_GATEWAY_API_KEY is required for live verification");
const artifactRoot = process.env.LIBFX_TEST_ARTIFACT_ROOT || tmpdir();
await mkdir(artifactRoot, { recursive: true });
const directory = await mkdtemp(resolve(artifactRoot, "libfx-vercel-"));
const app = resolve(directory, "app");
const secret = randomUUID();
const tokenArgs = process.env.LIBFX_VERCEL_TOKEN ? ["--token", process.env.LIBFX_VERCEL_TOKEN] : [];
const redact = (text) => [secret, process.env.AI_GATEWAY_API_KEY, process.env.LIBFX_VERCEL_TOKEN]
  .filter(Boolean).reduce((value, credential) => value.replaceAll(credential, "[redacted]"), text);
const results = [];
let deployment;
let deploymentRef;
let failure;

async function run(command, args, name) {
  const child = spawn(command, args, { cwd: app, stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  let errors = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { errors += chunk; });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 300_000);
  try {
    const [code] = await once(child, "close");
    await writeFile(resolve(directory, `${name}.log`), redact(`${output}\n${errors}`));
    assert.equal(code, 0, `Vercel ${name} failed; see ${directory}/${name}.log`);
    return output;
  } finally { clearTimeout(timeout); }
}

function vercel(args, name) {
  return run("vercel", [...args, "--scope", orgId, ...tokenArgs], name);
}

try {
  await cp(fileURLToPath(new URL("./next/", import.meta.url)), app, {
    recursive: true, filter: (path) => !["node_modules", ".next"].includes(path.split("/").at(-1)),
  });
  const manifest = JSON.parse(await readFile(resolve(app, "package.json"), "utf8"));
  if (input.endsWith(".tgz")) {
    await cp(resolve(input), resolve(app, "libfx.tgz"));
    manifest.dependencies.libfx = "file:./libfx.tgz";
  } else {
    assert.match(input, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, "pin an immutable version, not a tag");
    manifest.dependencies.libfx = input;
  }
  await writeFile(resolve(app, "package.json"), JSON.stringify(manifest, null, 2));
  await run(process.env.PNPM_BIN || "pnpm", ["install", "--lockfile-only", "--no-frozen-lockfile", "--ignore-scripts"], "prepare");
  await mkdir(resolve(app, ".vercel"));
  await writeFile(resolve(app, ".vercel/project.json"), JSON.stringify({ projectId, orgId }));
  const output = await vercel([
    "deploy", "--yes", "--no-wait", "--force", "--target", "preview",
    "--env", `LIBFX_SMOKE_TOKEN=${secret}`,
    "--env", "LIBFX_LIVE=1",
    "--env", `AI_GATEWAY_API_KEY=${process.env.AI_GATEWAY_API_KEY}`,
    "--env", `LIBFX_TEST_MODEL=${process.env.LIBFX_TEST_MODEL || "openai/gpt-5.4-mini"}`,
  ], "deploy");
  try {
    const result = JSON.parse(output).deployment;
    deployment = result?.url;
    deploymentRef = result?.id;
  } catch {}
  deployment ??= output.trim().split(/\s+/).findLast((value) => /^https:\/\/[^/]+$/.test(value));
  assert.ok(deployment, `No deployment URL returned; see ${directory}/deploy.log`);
  deploymentRef ??= deployment;
  await vercel(["inspect", deploymentRef, "--wait", "--timeout", "5m"], "inspect");
  const unauthorized = await fetch(`${deployment}/api/fx`);
  assert.equal(unauthorized.status, 401, "live tool endpoint must require its verification token");
  for (let round = 0; round < 3; round++) {
    for (const backend of ["native", "auto"]) {
      for (const scenario of ["host", "mcp"]) {
        const response = await fetch(`${deployment}/api/fx?backend=${backend}&scenario=${scenario}`, {
          headers: { authorization: `Bearer ${secret}` }, signal: AbortSignal.timeout(60_000),
        });
        const result = await response.json();
        assert.equal(response.status, 200, JSON.stringify(result));
        assert.equal(result.ok, true);
        assert.equal(result.probe.backend, "native");
        assert.equal(result.toolCalls, 1);
        assert.ok(result.events.includes("tool_start") && result.events.includes("tool_end"));
        assert.ok(result.checkpointBytes > 48);
        assert.equal(result.result.stopReason, "end_turn");
        if (scenario === "mcp") assert.equal(result.closedMcp, true);
        results.push({ round, backend, scenario, ...result });
        console.log(`Vercel round ${round + 1}/${backend}/${scenario} passed (${result.node}, glibc ${result.glibc})`);
      }
    }
  }
} catch (error) {
  failure = error;
  if (deploymentRef) {
    try { await vercel(["inspect", deploymentRef, "--logs"], "build"); } catch {}
  }
} finally {
  if (deployment && process.env.LIBFX_KEEP_DEPLOYMENT !== "1") {
    try { await vercel(["remove", deploymentRef, "--yes"], "cleanup"); }
    catch (error) { failure = failure ? new AggregateError([failure, error], "Verification and cleanup failed") : error; }
  }
  await writeFile(resolve(directory, "results.json"), redact(JSON.stringify({
    input, deployment, results,
    status: failure ? "failed" : "passed",
    error: serializeError(failure),
  }, null, 2)));
  console.log(`Vercel package evidence: ${directory}`);
}
if (failure) throw failure;
console.log(`Live Vercel package verification passed: ${directory}`);
