import { expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { chmodSync, copyFileSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeGatewaySse, startFakeGateway } from "../tests/e2e/tmux-helpers";

type CommandResult = { pid: number | null; code: number | null; stdout: string; stderr: string; elapsedMs: number; failure: string | null };
type CommandOptions = { cwd: string; env: Record<string, string>; timeoutMs?: number; captureLimit?: number };

async function runCommand(argv: string[], options: CommandOptions): Promise<CommandResult> {
  const started = performance.now();
  const child = spawn(argv[0], argv.slice(1), { cwd: options.cwd, env: options.env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  const chunks = { stdout: [] as Buffer[], stderr: [] as Buffer[] };
  const lengths = { stdout: 0, stderr: 0 };
  const limit = options.captureLimit ?? 1024 * 1024;
  let failure: string | null = null;
  let stopped = false;
  const stop = (reason: string) => {
    failure ??= reason;
    if (stopped) return;
    stopped = true;
    // The detached group remains ours until close, even if its leader exited.
    if (child.pid && child.pid > 1) {
      try { process.kill(-child.pid, "SIGKILL"); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") {
          failure += `; group termination failed: ${String(error)}`;
          child.kill("SIGKILL");
        }
      }
    }
    child.stdout!.destroy();
    child.stderr!.destroy();
  };
  for (const channel of ["stdout", "stderr"] as const) {
    child[channel]!.on("data", (chunk: Buffer) => {
      const remaining = Math.max(0, limit - lengths[channel]);
      if (remaining) chunks[channel].push(chunk.subarray(0, remaining));
      lengths[channel] += chunk.length;
      if (lengths[channel] > limit) stop("output limit");
    });
  }
  const deadline = setTimeout(() => stop("timeout"), options.timeoutMs ?? 15_000);
  let code: number | null;
  try {
    code = await new Promise<number | null>((resolve) => {
      child.once("error", (error) => { failure = String(error); });
      child.once("close", (exitCode) => resolve(exitCode));
    });
  } finally { clearTimeout(deadline); }
  return { pid: child.pid ?? null, code, stdout: Buffer.concat(chunks.stdout).toString(), stderr: Buffer.concat(chunks.stderr).toString(), elapsedMs: performance.now() - started, failure };
}

type Provenance = {
  artifact: {
    id: number; name: string; expired: boolean;
    workflow_run: { id: number; head_sha: string; repository_id: number; head_repository_id: number };
  };
  run: {
    id: number; path: string; status: string; conclusion: string; run_attempt: number;
    head_sha: string; head_branch: string; event: string;
    repository: { id: number; full_name: string };
    head_repository: { id: number; full_name: string };
  };
  source: { sha: string; parents: Array<{ sha: string }> };
  ancestry?: {
    status: string; ahead_by: number; behind_by: number; total_commits: number;
    base_commit: { sha: string }; merge_base_commit: { sha: string }; commits: Array<{ sha: string }>;
  };
  manifest: {
    stage: string; status: string; eligible: boolean;
    evidence: {
      identity: { source_sha: string; target: string; host_arch: string; zig_version: string; llvm_version: string };
      profile: { sha256: string };
      artifacts: { candidate: { sha256: string; size: { size_bytes: number }; architecture: string; signature_valid: boolean; version: string; minimum_macos: string } };
    };
  };
};

type Statistic = "mean" | "p50" | "p95";
type Interval = { delta: number; lower: number; upper: number };

function intervalPasses(interval: Interval, calibration: boolean): boolean {
  return interval.lower <= 0 && (!calibration || interval.upper >= 0);
}

const digest = (bytes: Uint8Array | string) => new Bun.CryptoHasher("sha256").update(bytes).digest("hex");

function validateBinary(bytes: Buffer, expected: { sha256: string; size: { size_bytes: number } }): void {
  requireValue(bytes.length === expected.size.size_bytes && digest(bytes) === expected.sha256, "candidate bytes do not match manifest");
  requireValue(bytes.length >= 32 && bytes.readUInt32LE(0) === 0xfeedfacf && bytes.readUInt32LE(4) === 0x0100000c && bytes.readUInt32LE(12) === 2, "candidate is not an arm64 Mach-O executable");
}

function memoryUsage(text: string): { rss: number; footprint: number } {
  const read = (name: string) => {
    const matches = [...text.matchAll(new RegExp(`^\\s*(\\d+)\\s+${name}\\s*$`, "gm"))];
    requireValue(matches.length === 1, `missing or duplicate ${name}`);
    const value = Number(matches[0][1]);
    requireValue(Number.isSafeInteger(value) && value > 0, `invalid ${name}`);
    return value;
  };
  return { rss: read("maximum resident set size"), footprint: read("peak memory footprint") };
}

function resourceOutput(path: string): { resources: string | null; resourceError: string | null } {
  try { return { resources: readFileSync(path, "utf8"), resourceError: null }; }
  catch (error) { return { resources: null, resourceError: String(error) }; }
}

type Inputs = { control: Provenance; candidate: Provenance; binaries: { control: string; candidate: string }; output: string };
type Scenario = "normal" | "recovered";
type Sample = { lane: "control" | "candidate"; pair: number; elapsedMs: number; rss?: number; footprint?: number };

function loadInputs(): Inputs {
  requireValue(process.platform === "darwin" && process.arch === "arm64", "native macOS arm64 is required");
  const input = process.env.FX_PGSO_COMPARE_INPUT, output = process.env.FX_PGSO_COMPARE_OUTPUT;
  requireValue(input && output, "artifact input and comparison output directories are required");
  const root = realpathSync(input);
  const read = (path: string) => JSON.parse(readFileSync(join(root, path), "utf8"));
  const load = (label: string): Provenance => ({ artifact: read(`${label}-artifact.json`), run: read(`${label}-run.json`), source: read(`${label}-source.json`), manifest: read(`${label}/manifest.json`) });
  const control = load("control"), candidate = load("candidate");
  if (candidate.run.event === "workflow_dispatch") candidate.ancestry = read("candidate-ancestry.json");
  validateProvenance(control, candidate);
  mkdirSync(output, { recursive: true });
  const binaries = { control: "", candidate: "" };
  for (const [label, provenance] of [["control", control], ["candidate", candidate]] as const) {
    const source = join(root, label, "candidate/fx");
    requireValue(lstatSync(source).isFile() && !lstatSync(source).isSymbolicLink() && realpathSync(source).startsWith(root + sep), "candidate path escapes artifact directory");
    requireValue(lstatSync(source).size <= 16 * 1024 * 1024, "candidate exceeds input bound");
    const bytes = readFileSync(source);
    validateBinary(bytes, provenance.manifest.evidence.artifacts.candidate);
    binaries[label] = source;
    const signature = spawnSync("/usr/bin/codesign", ["--verify", "--strict", source], { encoding: "utf8", timeout: 60_000 });
    requireValue(signature.status === 0 && !signature.error, `invalid ${label} signature: ${signature.stderr}`);
  }
  writeFileSync(join(output, "manifest.json"), JSON.stringify({
    driver_sha: process.env.GITHUB_SHA ?? spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim(),
    driver_digest: digest(readFileSync(import.meta.path)), bun: Bun.version,
    platform: process.platform, arch: process.arch, control, candidate,
    model: FAKE_GATEWAY_MODEL, planned_memory_pairs: 100, planned_timing_pairs: 50, timing_warmup_pairs: 5,
    bootstrap: { samples: 10_000, seed: 4112026, generator: "lcg32", confidence: 0.95 },
    boundary: "native fx process; Gateway memory excluded; timing and memory collected separately",
    claim_limit: "normal and recovered no-history flows; not a universal performance or leak proof",
  }, null, 2));
  return { control, candidate, binaries, output };
}

type Cohort = { name: string; kind: "memory" | "timing"; pairs: number; warmups: number; calibration: boolean; reverse: boolean };

async function runCohort(inputs: Inputs, cohort: Cohort): Promise<Record<Scenario, Sample[]>> {
  const directory = join(inputs.output, cohort.name);
  mkdirSync(directory);
  const binaries = { control: "", candidate: "" };
  for (const [label, lane] of [["control", cohort.reverse ? 1 : 0], ["candidate", cohort.reverse ? 0 : 1]] as const) {
    const path = join(directory, `lane-${lane}`);
    mkdirSync(path);
    binaries[label] = join(path, "fx");
    copyFileSync(inputs.binaries[cohort.calibration ? "control" : label], binaries[label]);
    chmodSync(binaries[label], 0o755);
    validateBinary(readFileSync(binaries[label]), (cohort.calibration ? inputs.control : inputs[label]).manifest.evidence.artifacts.candidate);
  }
  const replies: Parameters<typeof startFakeGateway>[0] = [];
  const gateway = startFakeGateway(replies, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }] });
  const samples: Record<Scenario, Sample[]> = { normal: [], recovered: [] };
  try {
    for (const scenario of ["normal", "recovered"] as const) {
      mkdirSync(join(directory, scenario));
      for (let pair = -cohort.warmups; pair < cohort.pairs; pair++) {
        const fixture = mkdtempSync(join(tmpdir(), "fx-pgso-pair-"));
        const workspace = join(fixture, "workspace");
        mkdirSync(workspace);
        let reference: string | null = null;
        try {
          const order = Boolean(pair % 2) !== cohort.reverse ? ["candidate", "control"] as const : ["control", "candidate"] as const;
          for (const lane of order) {
            const home = join(fixture, lane === "control" ? "home-0" : "home-1");
            mkdirSync(join(home, ".fx"), { recursive: true });
            writeFileSync(join(home, ".fx/settings.json"), "{}");
            requireValue(replies.length === 0 && gateway.requests.length === 0 && gateway.modelRequests.length === 0 && gateway.classifierRequests.length === 0 && gateway.titleRequests.length === 0, "Gateway state leaked between children");
            if (scenario === "recovered") replies.push(fakeGatewaySse([
              { type: "tool-input-start", id: "read_1", toolName: "read_file" },
              { type: "finish", finishReason: { unified: "error", raw: "provider_error" } },
            ]));
            replies.push(fakeGatewayFinalText("MEMORY_CHECK_DONE"));
            const resourcePath = join(fixture, `${lane}-resources.txt`);
            const argv = [binaries[lane], "ask", "--json", "--auto", "--no-save", "Complete the fixed memory fixture."];
            if (cohort.kind === "memory") argv.unshift("/usr/bin/time", "-l", "-o", resourcePath);
            const result = await runCommand(argv, { cwd: workspace, env: {
              PATH: process.env.PATH ?? "", TMPDIR: fixture, LANG: "en_US.UTF-8", TZ: "UTC", HOME: home,
              AI_GATEWAY_API_KEY: "synthetic-memory-fixture", VERCEL_OIDC_TOKEN: "",
              FX_DISABLE_KEYCHAIN: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_SKIP_ONBOARDING: "1",
              FX_E2E_DISABLE_DOTENV: "1", FX_MODEL: FAKE_GATEWAY_MODEL,
              FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
              FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            } });
            const requests = gateway.requests.map((request) => request.body);
            const { resources, resourceError } = cohort.kind === "memory" ? resourceOutput(resourcePath) : { resources: null, resourceError: null };
            writeFileSync(join(directory, scenario, `${pair}-${lane}.json`), JSON.stringify({ ...result, requests, resources, resourceError, pendingReplies: replies.length }, null, 2));
            requireValue(result.failure === null && result.code === 0, `native fixture failed: ${result.failure ?? result.stderr}`);
            requireValue(resourceError === null, `native resource capture failed: ${resourceError}`);
            if (scenario === "normal") expect(result.stderr).toBe("");
            else {
              expect(result.stderr).toContain("provider_error");
              expect(result.stderr).toContain("recovered");
              expect(result.stderr).not.toContain("not retrying");
            }
            const response = JSON.parse(result.stdout);
            expect(response.exit_code).toBe(0);
            expect(response.output).toBe("MEMORY_CHECK_DONE");
            expect(response.tool_calls).toEqual([]);
            expect(requests).toHaveLength(scenario === "normal" ? 1 : 2);
            expect(replies).toHaveLength(0);
            expect(gateway.classifierRequests).toHaveLength(0);
            expect(gateway.titleRequests).toHaveLength(0);
            const canonical = JSON.stringify({ requests, stderr: result.stderr }).replaceAll(home, "<HOME>").replaceAll(workspace, "<WORKSPACE>");
            expect(canonical).not.toContain("<available_skills>");
            if (reference === null) reference = digest(canonical);
            else expect(digest(canonical)).toBe(reference);
            if (pair >= 0) samples[scenario].push({ lane, pair, elapsedMs: result.elapsedMs, ...(resources === null ? {} : memoryUsage(resources)) });
            gateway.requests.length = 0;
            gateway.modelRequests.length = 0;
            gateway.classifierRequests.length = 0;
            gateway.titleRequests.length = 0;
            gateway.generationRequests.length = 0;
          }
        } finally { rmSync(fixture, { recursive: true, force: true }); }
        writeFileSync(join(directory, "samples.json"), JSON.stringify(samples, null, 2));
        if (pair % 10 === 0) console.log(`${cohort.name}: ${scenario} pair ${pair}/${cohort.pairs}`);
      }
    }
    for (const lane of ["control", "candidate"] as const) {
      expect(digest(readFileSync(binaries[lane]))).toBe((cohort.calibration ? inputs.control : inputs[lane]).manifest.evidence.artifacts.candidate.sha256);
    }
    return samples;
  } finally { gateway.stop(); }
}

async function fixtureSmoke(inputs: Inputs): Promise<void> {
  for (const kind of ["memory", "timing"] as const) {
    const samples = await runCohort(inputs, { name: `smoke-${kind}`, kind, pairs: 1, warmups: 0, calibration: false, reverse: false });
    expect(samples.normal).toHaveLength(2);
    expect(samples.recovered).toHaveLength(2);
  }
}

function cohortReport(samples: Record<Scenario, Sample[]>, cohort: Cohort) {
  const metrics = [];
  for (const scenario of ["normal", "recovered"] as const) {
    const control = samples[scenario].filter((row) => row.lane === "control");
    const candidate = samples[scenario].filter((row) => row.lane === "candidate");
    requireValue(control.length === cohort.pairs && candidate.length === cohort.pairs, "incomplete measured cohort");
    requireValue(control.every((row, index) => row.pair === index && candidate[index].pair === index), "mispaired samples");
    const selected = cohort.kind === "memory" ? ["rss", "footprint"] as const : ["elapsedMs"] as const;
    for (const metric of selected) {
      const left = control.map((row) => row[metric]!);
      const right = candidate.map((row) => row[metric]!);
      for (const kind of cohort.kind === "memory" ? ["mean"] as const : ["mean", "p50", "p95"] as const) {
        const interval = pairedInterval(left, right, kind);
        metrics.push({ scenario, metric, statistic: kind, control: statistic(left, kind), candidate: statistic(right, kind), interval, passed: intervalPasses(interval, cohort.calibration) });
      }
    }
  }
  return { ...cohort, metrics, passed: metrics.every((metric) => metric.passed) };
}

function requireValue(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function validateProvenance(control: Provenance, candidate: Provenance): void {
  requireValue(control.artifact.id !== candidate.artifact.id, "comparison requires distinct artifact IDs");
  for (const value of [control, candidate]) {
    const { artifact, run, manifest, source } = value;
    const identity = manifest.evidence.identity;
    const binary = manifest.evidence.artifacts.candidate;
    requireValue(Number.isSafeInteger(artifact.id) && artifact.id > 0 && artifact.expired === false, "invalid artifact ID or expired artifact");
    requireValue([run.id, run.repository.id, run.head_repository.id].every((id) => Number.isSafeInteger(id) && id > 0), "invalid source run identity");
    requireValue(/^[a-f0-9]{40}$/.test(run.head_sha), "invalid source run head");
    const releaseControl = value === control && run.path === ".github/workflows/release.yml" &&
      run.head_branch === "main" && (run.event === "push" || run.event === "workflow_dispatch");
    requireValue((run.path === ".github/workflows/pgso-macos-arm64.yml" || releaseControl) && run.status === "completed" && run.conclusion === "success", "source run did not pass PGSO");
    requireValue(run.repository.full_name === "vercel-labs/fx" && run.head_repository.full_name === "vercel-labs/fx", "foreign repository");
    requireValue(artifact.workflow_run.repository_id === run.repository.id && artifact.workflow_run.head_repository_id === run.head_repository.id, "artifact repository mismatch");
    requireValue(artifact.workflow_run.id === run.id && artifact.workflow_run.head_sha === run.head_sha, "artifact run mismatch");
    requireValue(manifest.stage === "complete" && manifest.status === "passed" && manifest.eligible === true, "artifact is not qualified");
    requireValue(/^[a-f0-9]{40}$/.test(identity.source_sha) && source.sha === identity.source_sha, "invalid source commit");
    requireValue(Number.isSafeInteger(run.run_attempt) && run.run_attempt > 0, "invalid run attempt");
    const name = `pgso-evidence-macos-arm64-${source.sha}`;
    requireValue(artifact.name === `${name}-attempt-${run.run_attempt}` || (artifact.name === name && run.run_attempt === 1), "stale or mismatched artifact name");
    requireValue(identity.target === "aarch64-macos" && identity.host_arch === "arm64" && binary.architecture === "arm64" && binary.signature_valid === true, "invalid native candidate");
    requireValue([identity.zig_version, identity.llvm_version].every((version) => /^\d+\.\d+\.\d+(?:[-+].+)?$/.test(version)), "invalid toolchain version");
    requireValue(/^[a-f0-9]{64}$/.test(binary.sha256) && /^[a-f0-9]{64}$/.test(manifest.evidence.profile.sha256), "invalid candidate digest");
    requireValue(Number.isSafeInteger(binary.size.size_bytes) && binary.size.size_bytes >= 32 && binary.size.size_bytes <= 16 * 1024 * 1024, "invalid candidate size");
  }
  requireValue(control.run.head_branch === "main" && control.run.head_sha === control.source.sha, "control is not exact main");
  if (candidate.run.event === "workflow_dispatch") {
    requireValue(typeof candidate.run.head_branch === "string" && candidate.run.head_branch.length > 0 && candidate.run.head_branch !== "main" && candidate.source.sha === candidate.run.head_sha, "candidate is not an exact manual branch head");
    const ancestry = candidate.ancestry;
    requireValue(ancestry?.status === "ahead" && ancestry.behind_by === 0 && Number.isSafeInteger(ancestry.ahead_by) && ancestry.ahead_by > 0, "candidate ancestry is not strictly ahead");
    requireValue(ancestry.base_commit?.sha === control.source.sha && ancestry.merge_base_commit?.sha === control.source.sha, "candidate ancestry does not match exact control");
    requireValue(ancestry.total_commits === ancestry.ahead_by && Array.isArray(ancestry.commits) && ancestry.commits.length === ancestry.ahead_by, "candidate ancestry is incomplete");
    requireValue(ancestry.commits.every((commit) => typeof commit?.sha === "string" && /^[a-f0-9]{40}$/.test(commit.sha) && commit.sha !== control.source.sha), "invalid candidate ancestry commit");
    requireValue(new Set(ancestry.commits.map((commit) => commit.sha)).size === ancestry.commits.length && ancestry.commits.at(-1)!.sha === candidate.source.sha, "candidate ancestry does not end at exact head");
  } else {
    requireValue(candidate.run.event === "pull_request" && candidate.source.parents.length === 2, "candidate is not a PR merge");
    requireValue(candidate.source.parents[0].sha === control.source.sha && candidate.source.parents[1].sha === candidate.run.head_sha, "candidate merge parents do not match control and PR head");
  }
  for (const field of ["target", "host_arch", "zig_version", "llvm_version"] as const) {
    requireValue(control.manifest.evidence.identity[field] === candidate.manifest.evidence.identity[field], `different ${field}`);
  }
}

function statistic(values: readonly number[], kind: Statistic): number {
  if (kind === "mean") return values.reduce((sum, value) => sum + value, 0) / values.length;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * (kind === "p50" ? 0.5 : 0.95)) - 1];
}

function pairedInterval(control: readonly number[], candidate: readonly number[], kind: Statistic): Interval {
  requireValue(control.length >= 50 && control.length === candidate.length, "at least 50 complete pairs are required");
  requireValue([...control, ...candidate].every((value) => Number.isFinite(value) && value > 0), "invalid sample");
  let seed = 4112026;
  const next = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 0x1_0000_0000;
  };
  const draws: number[] = [];
  const left = new Array<number>(control.length), right = new Array<number>(control.length);
  for (let draw = 0; draw < 10_000; draw++) {
    for (let index = 0; index < control.length; index++) {
      const selected = Math.floor(next() * control.length);
      left[index] = control[selected];
      right[index] = candidate[selected];
    }
    draws.push(statistic(right, kind) - statistic(left, kind));
  }
  draws.sort((a, b) => a - b);
  return { delta: statistic(candidate, kind) - statistic(control, kind), lower: draws[249], upper: draws[9749] };
}

function provenanceFixture(): [Provenance, Provenance] {
  const base = "a".repeat(40), head = "b".repeat(40), merge = "c".repeat(40);
  const make = (id: number, source: string, sha: string, branch: string, event: string): Provenance => ({
    artifact: { id, name: `pgso-evidence-macos-arm64-${source}`, expired: false,
      workflow_run: { id: id + 10, head_sha: sha, repository_id: 1, head_repository_id: 1 } },
    run: { id: id + 10, path: ".github/workflows/pgso-macos-arm64.yml", status: "completed", conclusion: "success", run_attempt: 1,
      head_sha: sha, head_branch: branch, event, repository: { id: 1, full_name: "vercel-labs/fx" }, head_repository: { id: 1, full_name: "vercel-labs/fx" } },
    source: { sha: source, parents: source === merge ? [{ sha: base }, { sha: head }] : [] },
    manifest: { stage: "complete", status: "passed", eligible: true, evidence: {
      identity: { source_sha: source, target: "aarch64-macos", host_arch: "arm64", zig_version: "0.17.0", llvm_version: "22.1.8" },
      profile: { sha256: "d".repeat(64) },
      artifacts: { candidate: { sha256: "e".repeat(64), size: { size_bytes: 6_000_000 }, architecture: "arm64", signature_valid: true, version: "0.0.9", minimum_macos: "13.0" } },
    } },
  });
  return [make(1, base, base, "main", "workflow_dispatch"), make(2, merge, head, "feature", "pull_request")];
}

test("PGSO provenance requires qualified exact main and merge inputs", () => {
  const valid = provenanceFixture();
  expect(() => validateProvenance(...valid)).not.toThrow();
  valid[1].artifact.name += "-attempt-1";
  expect(() => validateProvenance(...valid)).not.toThrow();
  const mutations: Array<(pair: [Provenance, Provenance]) => void> = [
    (pair) => { pair[1].artifact.id = pair[0].artifact.id; },
    (pair) => { pair[1].artifact.expired = true; },
    (pair) => { pair[1].manifest.eligible = false; },
    (pair) => { pair[1].run.conclusion = "failure"; },
    (pair) => { pair[1].run.path = ".github/workflows/other.yml"; },
    (pair) => { pair[1].run.head_repository.full_name = "foreign/repository"; },
    (pair) => { pair[1].artifact.workflow_run.id++; },
    (pair) => { pair[1].artifact.workflow_run.head_sha = "f".repeat(40); },
    (pair) => { pair[1].artifact.name += "-attempt-2"; },
    (pair) => { pair[1].run.run_attempt = 2; },
    (pair) => { pair[0].run.head_branch = "feature"; },
    (pair) => { pair[1].source.parents[0].sha = "f".repeat(40); },
    (pair) => { pair[1].source.parents[1].sha = "f".repeat(40); },
    (pair) => { pair[1].manifest.evidence.identity.source_sha = "../outside"; },
    (pair) => { pair[1].manifest.evidence.artifacts.candidate.sha256 = "bad"; },
    (pair) => { pair[1].manifest.evidence.artifacts.candidate.size.size_bytes = 0; },
    (pair) => { pair[1].manifest.evidence.artifacts.candidate.architecture = "x86_64"; },
    (pair) => { pair[1].run.id = 0; pair[1].artifact.workflow_run.id = 0; },
    (pair) => { pair[1].run.head_sha = ""; pair[1].artifact.workflow_run.head_sha = ""; pair[1].source.parents[1].sha = ""; },
    (pair) => { pair[0].manifest.evidence.identity.zig_version = ""; pair[1].manifest.evidence.identity.zig_version = ""; },
  ];
  for (const mutate of mutations) {
    const pair = structuredClone(valid);
    mutate(pair);
    expect(() => validateProvenance(...pair)).toThrow();
  }
});

function manualProvenanceFixture() {
  const [control, candidate] = provenanceFixture();
  candidate.run.event = "workflow_dispatch";
  candidate.source = { sha: candidate.run.head_sha, parents: [{ sha: "f".repeat(40) }] };
  candidate.manifest.evidence.identity.source_sha = candidate.source.sha;
  candidate.artifact.name = `pgso-evidence-macos-arm64-${candidate.source.sha}-attempt-1`;
  return [control, Object.assign(candidate, { ancestry: {
    status: "ahead", ahead_by: 2, behind_by: 0, total_commits: 2,
    base_commit: { sha: control.source.sha }, merge_base_commit: { sha: control.source.sha },
    commits: [{ sha: "f".repeat(40) }, { sha: candidate.source.sha }],
  } })] as const;
}

test("PGSO provenance accepts qualified manual branch heads with exact control ancestry", () => {
  const pair = manualProvenanceFixture();
  expect(() => validateProvenance(...pair)).not.toThrow();
  pair[0].run.path = ".github/workflows/release.yml";
  expect(() => validateProvenance(...pair)).not.toThrow();
});

test("PGSO provenance rejects unproven manual branch heads without weakening qualification", () => {
  const valid = manualProvenanceFixture();
  const mutations: Array<(pair: typeof valid) => void> = [
    (pair) => { Object.assign(pair[1], { ancestry: undefined }); },
    (pair) => { Object.assign(pair[1], { ancestry: null }); },
    (pair) => { Object.assign(pair[1], { ancestry: {} }); },
    (pair) => { pair[1].ancestry.status = "diverged"; },
    (pair) => { pair[1].ancestry.behind_by = 1; },
    (pair) => { Object.assign(pair[1].ancestry, { behind_by: "0" }); },
    (pair) => { pair[1].ancestry.ahead_by = 0; },
    (pair) => { pair[1].ancestry.ahead_by = -1; },
    (pair) => { pair[1].ancestry.ahead_by = 1.5; },
    (pair) => { Object.assign(pair[1].ancestry, { ahead_by: "2" }); },
    (pair) => { pair[1].ancestry.total_commits = 3; },
    (pair) => { Object.assign(pair[1].ancestry, { total_commits: undefined }); },
    (pair) => { pair[1].ancestry.base_commit.sha = "d".repeat(40); },
    (pair) => { pair[1].ancestry.merge_base_commit.sha = "d".repeat(40); },
    (pair) => { Object.assign(pair[1].ancestry, { base_commit: null }); },
    (pair) => { Object.assign(pair[1].ancestry, { merge_base_commit: {} }); },
    (pair) => { Object.assign(pair[1].ancestry, { commits: null }); },
    (pair) => { pair[1].ancestry.commits = []; },
    (pair) => { pair[1].ancestry.commits.pop(); },
    (pair) => { pair[1].ancestry.commits.shift(); },
    (pair) => { pair[1].ancestry.commits[0].sha = "invalid"; },
    (pair) => { Object.assign(pair[1].ancestry.commits, { 0: null }); },
    (pair) => { pair[1].ancestry.commits[0].sha = pair[1].source.sha; },
    (pair) => { pair[1].ancestry.commits[0].sha = pair[0].source.sha; },
    (pair) => { pair[1].ancestry.commits.reverse(); },
    (pair) => { pair[1].run.event = "push"; },
    (pair) => { pair[1].run.head_branch = "main"; },
    (pair) => { pair[1].run.head_branch = ""; },
    (pair) => { pair[1].run.head_sha = "d".repeat(40); pair[1].artifact.workflow_run.head_sha = pair[1].run.head_sha; },
    (pair) => { pair[1].run.path = ".github/workflows/release.yml"; },
    (pair) => { pair[1].run.status = "in_progress"; },
    (pair) => { pair[1].run.conclusion = "failure"; },
    (pair) => { pair[1].manifest.stage = "train"; },
    (pair) => { pair[1].manifest.status = "failed"; },
    (pair) => { pair[1].manifest.eligible = false; },
    (pair) => { pair[1].run.head_repository.full_name = "foreign/repository"; },
    (pair) => { pair[1].run.run_attempt++; },
    (pair) => { pair[1].manifest.evidence.artifacts.candidate.signature_valid = false; },
    (pair) => { pair[1].manifest.evidence.identity.zig_version = "0.17.0"; },
  ];
  for (const mutate of mutations) {
    const pair = structuredClone(valid);
    mutate(pair);
    expect(() => validateProvenance(...pair)).toThrow();
  }
});

test("PGSO manual ancestry cannot bypass PR merge parent validation", () => {
  const pair = provenanceFixture();
  Object.assign(pair[1], { ancestry: manualProvenanceFixture()[1].ancestry });
  pair[1].source.parents[0].sha = "f".repeat(40);
  expect(() => validateProvenance(...pair)).toThrow("candidate merge parents do not match control and PR head");
});

test("paired confidence detects calibration errors and resolved regressions", () => {
  const control = Array.from({ length: 100 }, (_, index) => 100 + index % 7);
  for (const statistic of ["mean", "p50", "p95"] as const) {
    expect(pairedInterval(control, control, statistic)).toEqual({ delta: 0, lower: 0, upper: 0 });
    expect(pairedInterval(control, control.map((value) => value + 10), statistic).lower).toBeGreaterThan(0);
    expect(pairedInterval(control, control.map((value) => value - 10), statistic).upper).toBeLessThan(0);
  }
  expect(() => pairedInterval([], [], "mean")).toThrow();
  expect(() => pairedInterval(control, control.slice(1), "mean")).toThrow();
  expect(() => pairedInterval(control, control.map(() => NaN), "mean")).toThrow();
});

test("PGSO provenance accepts qualified main controls from the release pipeline", () => {
  const valid = provenanceFixture();
  valid[0].run.path = ".github/workflows/release.yml";
  valid[0].run.event = "push";
  expect(() => validateProvenance(...valid)).not.toThrow();
  valid[0].run.event = "workflow_dispatch";
  expect(() => validateProvenance(...valid)).not.toThrow();
  const mutations: Array<(pair: [Provenance, Provenance]) => void> = [
    (pair) => { pair[0].run.event = "pull_request"; },
    (pair) => { pair[0].run.event = "workflow_run"; },
    (pair) => { pair[0].run.head_branch = "feature"; },
    (pair) => { pair[0].run.path = ".github/workflows/dev-release.yml"; },
    (pair) => { pair[0].run.conclusion = "failure"; },
    (pair) => { pair[0].manifest.eligible = false; },
    (pair) => { pair[0].artifact.workflow_run.id++; },
    (pair) => { pair[1].source.parents[0].sha = "f".repeat(40); },
    (pair) => { pair[1].run.path = ".github/workflows/release.yml"; },
  ];
  for (const mutate of mutations) {
    const pair = structuredClone(valid);
    mutate(pair);
    expect(() => validateProvenance(...pair)).toThrow();
  }
});

test("paired confidence verdict rejects biased calibration and slower candidates", () => {
  expect(intervalPasses({ delta: 0, lower: -1, upper: 1 }, true)).toBe(true);
  expect(intervalPasses({ delta: 0, lower: 0, upper: 0 }, true)).toBe(true);
  expect(intervalPasses({ delta: 2, lower: 1, upper: 3 }, true)).toBe(false);
  expect(intervalPasses({ delta: -2, lower: -3, upper: -1 }, true)).toBe(false);
  expect(intervalPasses({ delta: 2, lower: 1, upper: 3 }, false)).toBe(false);
  expect(intervalPasses({ delta: -2, lower: -3, upper: -1 }, false)).toBe(true);
});

test("PGSO command capture stops and joins its owned process group", async () => {
  const options = { cwd: tmpdir(), env: { PATH: process.env.PATH ?? "" } };
  const timed = await runCommand([process.execPath, "-e", "setInterval(() => {}, 1000)"], { ...options, timeoutMs: 150 });
  expect(timed.failure).toBe("timeout");
  expect(timed.pid).toBeGreaterThan(1);
  expect(() => process.kill(timed.pid!, 0)).toThrow();
  const bounded = await runCommand([process.execPath, "-e", 'process.stdout.write("x".repeat(4096)); setInterval(() => {}, 1000)'], { ...options, captureLimit: 16, timeoutMs: 2000 });
  expect(bounded.failure).toBe("output limit");
  expect(bounded.stdout).toBe("x".repeat(16));
  expect(() => process.kill(bounded.pid!, 0)).toThrow();
  const missing = await runCommand(["/nonexistent/fx-pgso-test-command"], options);
  expect(missing.failure).toContain("ENOENT");
});

test("PGSO command capture terminates descendants after the leader exits", async () => {
  const result = await runCommand(["/bin/sh", "-c", '(sleep 1; printf "descendant survived") & exit 0'], {
    cwd: tmpdir(), env: { PATH: "/usr/bin:/bin" }, timeoutMs: 150,
  });
  expect(result.code).toBe(0);
  expect(result.failure).toBe("timeout");
  expect(result.stdout).toBe("");
  expect(() => process.kill(-result.pid!, 0)).toThrow();
});

test("PGSO binary identity rejects tampering and wrong architecture", () => {
  const bytes = Buffer.alloc(32);
  bytes.writeUInt32LE(0xfeedfacf, 0);
  bytes.writeUInt32LE(0x0100000c, 4);
  bytes.writeUInt32LE(2, 12);
  const expected = { sha256: digest(bytes), size: { size_bytes: bytes.length } };
  expect(() => validateBinary(bytes, expected)).not.toThrow();
  expect(() => validateBinary(bytes, { ...expected, sha256: "a".repeat(64) })).toThrow();
  expect(() => validateBinary(bytes, { ...expected, size: { size_bytes: 31 } })).toThrow();
  bytes.writeUInt32LE(0x01000007, 4);
  expect(() => validateBinary(bytes, { ...expected, sha256: digest(bytes) })).toThrow();
});

test("PGSO resource accounting requires one positive native value per metric", () => {
  const valid = "  8192 maximum resident set size\n 16384 peak memory footprint\n";
  expect(memoryUsage(valid)).toEqual({ rss: 8192, footprint: 16384 });
  expect(() => memoryUsage("")).toThrow();
  expect(() => memoryUsage(valid + valid)).toThrow();
  expect(() => memoryUsage(valid.replace("8192", "0"))).toThrow();
});

test("PGSO resource accounting retains failed-command diagnostics and missing reports", async () => {
  const fixture = mkdtempSync(join(tmpdir(), "fx-pgso-failed-resources-"));
  try {
    const path = join(fixture, "resources.txt");
    const failed = await runCommand(["/bin/sh", "-c", 'printf "retained report" > "$1"; printf "failed command" >&2; exit 3', "fixture", path], {
      cwd: fixture, env: { PATH: "/usr/bin:/bin" },
    });
    const captured = { ...failed, ...resourceOutput(path) };
    expect(captured.code).toBe(3);
    expect(captured.stderr).toBe("failed command");
    expect(captured.resources).toBe("retained report");
    expect(captured.resourceError).toBeNull();
    const missing = { ...failed, ...resourceOutput(join(fixture, "missing.txt")) };
    expect(missing.code).toBe(3);
    expect(missing.stderr).toBe("failed command");
    expect(missing.resources).toBeNull();
    expect(missing.resourceError).toContain("ENOENT");
    expect(resourceOutput(fixture).resourceError).not.toBeNull();
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});

test("PGSO cohort reporting rejects missing and mispaired rows", () => {
  const rows: Sample[] = Array.from({ length: 100 }, (_, pair) => [
    { lane: "control" as const, pair, elapsedMs: 10, rss: 1000, footprint: 2000 },
    { lane: "candidate" as const, pair, elapsedMs: 10, rss: 1000, footprint: 2000 },
  ]).flat();
  const samples = { normal: rows, recovered: rows };
  const cohort: Cohort = { name: "test", kind: "memory", pairs: 100, warmups: 0, calibration: true, reverse: false };
  expect(cohortReport(samples, cohort).passed).toBe(true);
  expect(() => cohortReport({ ...samples, normal: rows.slice(1) }, cohort)).toThrow();
  const duplicate = rows.map((row, index) => index === 3 ? { ...row, pair: 0 } : row);
  expect(() => cohortReport({ ...samples, normal: duplicate }, cohort)).toThrow();
  const larger = rows.map((row) => row.lane === "candidate" ? { ...row, rss: row.rss! + 1 } : row);
  expect(cohortReport({ normal: larger, recovered: larger }, { ...cohort, calibration: false }).passed).toBe(false);
});

test("PGSO artifact fixture smoke preserves normal and recovered requests", async () => {
  await fixtureSmoke(loadInputs());
}, 120_000);

test("PGSO artifacts qualify paired native memory and latency", async () => {
  const inputs = loadInputs();
  const cohorts: Cohort[] = [
    { name: "memory-aa", kind: "memory", pairs: 100, warmups: 0, calibration: true, reverse: false },
    { name: "memory-ab", kind: "memory", pairs: 100, warmups: 0, calibration: false, reverse: false },
    { name: "timing-aa", kind: "timing", pairs: 50, warmups: 5, calibration: true, reverse: false },
    { name: "timing-ab", kind: "timing", pairs: 50, warmups: 5, calibration: false, reverse: false },
    { name: "timing-ba", kind: "timing", pairs: 50, warmups: 5, calibration: false, reverse: true },
  ];
  const report: { status: string; cohorts: ReturnType<typeof cohortReport>[]; error?: string } = { status: "running", cohorts: [] };
  const save = () => writeFileSync(join(inputs.output, "results.json"), JSON.stringify(report, null, 2));
  try {
    for (const cohort of cohorts) {
      const result = cohortReport(await runCohort(inputs, cohort), cohort);
      report.cohorts.push(result);
      save();
      requireValue(result.passed, `${cohort.name} ${cohort.calibration ? "did not calibrate" : "has a resolved regression"}; see retained metrics`);
    }
    report.status = "passed";
    save();
  } catch (error) {
    report.status = "failed";
    report.error = String(error);
    save();
    throw error;
  }
}, 1_200_000);
