// Drives the built fx doctor along tests/tla/doctor/Doctor.tla: each run
// makes the provider catalog, one MCP server, and gh answer or hang, maps the
// report to the spec's `report` variable, and has TLC confirm the spec can
// reach that report. A report the spec cannot produce must be rejected,
// doctor's own time, from its first trace line to its exit, must end by the
// deadline plus a grace, which it can only do once it has cancelled and
// joined every check (NoTaskAfterReport), and
// neither a child nor a process a child started in its group may outlive
// doctor (NoChildAfterExit): the hanging gh runs a sleep of its own. One more
// run sends SIGTERM while doctor starts its checks: doctor must end by the
// signal, as the spec's `exited` state, with no check child and no server it
// started left behind.
import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fxBin, outDir, REPO_ROOT, runTlc, TLA_ROOT } from "../lib/tlc";

const FIXTURE = join(REPO_ROOT, "tests", "e2e", "fixtures", "mcp-modern-stdio.mjs");
const DEADLINE_MS = 1500;
// Doctor's own time, from its first trace line to its exit, may pass its
// deadline by this much: the stop, the reap grace, the join, and the report.
const GRACE_MS = 2500;
// The whole process, fx's start and local checks included, which a loaded
// machine slows; only a hang should cross it.
const PROCESS_LIMIT_MS = 10_000;
type Outcome = "result" | "timed_out" | "none";
type Observation = { catalog: Outcome; mcp1: Outcome; gh: Outcome };
const GH_GRANDCHILD = "sleep 59.8765";
// TLC searches the whole model to reject a report, which takes about a minute.
const TLC_TIMEOUT_MS = 180_000;

const servers: Array<{ stop: (force?: boolean) => void }> = [];
afterAll(() => {
  for (const s of servers) s.stop(true);
});

function serve(fetch: (req: Request) => Response | Promise<Response>) {
  const s = Bun.serve({ hostname: "127.0.0.1", port: 0, idleTimeout: 0, fetch });
  servers.push(s);
  return s.port;
}
const never = () => new Promise<Response>(() => {});
const answering = serve(() => Response.json({ data: [{ id: "fake/m", type: "language", tags: [] }] }));
const hanging = serve(never);

const running = (marker: string) => spawnSync("/usr/bin/pgrep", ["-f", marker]).stdout.toString().trim();

/**
 * One doctor run where the catalog and the MCP server each answer or hang.
 * gh hangs with the server, running a sleep of its own, and otherwise says
 * it is signed out.
 */
async function run(catalogHangs: boolean, mcpHangs: boolean): Promise<{ observed: Observation; ms: number; span: number; left: string }> {
  const root = mkdtempSync(join(tmpdir(), "fx-tla-doctor-"));
  try {
    const home = join(root, "h");
    const ws = join(root, "w");
    const bin = join(root, "bin");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(ws);
    mkdirSync(bin);
    // gh runs only inside a repository.
    if (spawnSync("/usr/bin/git", ["init", "-q", ws]).status !== 0) throw new Error("git init failed");
    writeFileSync(join(bin, "gh"), mcpHangs ? `#!/bin/sh\n/bin/${GH_GRANDCHILD}\nexit 0\n` : "#!/bin/sh\nexit 1\n");
    chmodSync(join(bin, "gh"), 0o755);
    const mcp1 = mcpHangs
      ? { type: "http", url: `http://127.0.0.1:${hanging}/mcp`, startup_timeout_ms: 60_000 }
      : { command: [process.execPath, FIXTURE] };
    writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: { mcp1 } }));
    const base = `http://127.0.0.1:${catalogHangs ? hanging : answering}`;
    const env = {
      HOME: home, PATH: bin, FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", FX_MODEL: "fake/m",
      AI_GATEWAY_API_KEY: "driver-key", FX_GATEWAY_BASE_URL: base,
      FX_TEST_GATEWAY_MODELS_URL: `${base}/coding-agent/v1/models`, FX_TEST_DOCTOR_DEADLINE_MS: String(DEADLINE_MS),
      FX_TRACE_LOG: join(root, "trace.log"), FX_TRACE_SCOPES: "doctor",
    };
    const started = performance.now();
    const proc = Bun.spawn([fxBin(), "doctor", "--json"], { env, cwd: ws, stdout: "pipe", stderr: "ignore" });
    const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
    const ms = performance.now() - started;
    const exited = Date.now();
    // Each trace line starts with its wall-clock time in milliseconds; the
    // first one comes once doctor starts its checks, after its deadline is set.
    const first = Number(readFileSync(join(root, "trace.log"), "utf8").split(" ", 1)[0]);
    if (!Number.isFinite(first) || first <= 0) throw new Error("doctor wrote no trace line");
    const span = exited - first;
    const left = [running("mcp show mcp1 --json"), running(GH_GRANDCHILD)].filter(Boolean).join("\n");
    const checks: Array<{ name: string; status: string; detail: string }> = JSON.parse(out).checks;
    const catalog: Outcome = checks.some((c) => c.name === "provider" && c.detail.includes("could not reach"))
      ? "timed_out"
      : checks.some((c) => c.name === "model") ? "result" : "none";
    const server = checks.find((c) => c.name === "mcp" && c.detail.startsWith("mcp1"));
    const mcp: Outcome = !server ? "none" : server.detail.includes("did not start in") ? "timed_out" : "result";
    const ghLine = checks.find((c) => c.name === "gh");
    const gh: Outcome = !ghLine ? "none" : ghLine.detail.includes("did not answer") ? "timed_out" : "result";
    return { observed: { catalog, mcp1: mcp, gh }, ms, span, left };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** Whether the spec can reach `main = "reported"` with this report. */
async function reachable(observed: Observation, label: string): Promise<boolean> {
  const value = (o: Outcome) => `"${o}"`;
  return reaches(`main = "reported" /\\ report = [x \\in Checks |-> IF x = "catalog" THEN ${value(observed.catalog)} ELSE IF x = "mcp1" THEN ${value(observed.mcp1)} ELSE ${value(observed.gh)}]`, label);
}

/** Whether the spec can reach a state where `state`, a TLA+ predicate, holds. */
async function reaches(state: string, label: string): Promise<boolean> {
  const dir = outDir(`doctor-driver-${label}`);
  writeFileSync(join(dir, "DoctorObserved.tla"), [
    "---- MODULE DoctorObserved ----",
    "EXTENDS Doctor",
    `NotObserved == ~(${state})`,
    "====",
    "",
  ].join("\n"));
  writeFileSync(join(dir, "observed.cfg"), [
    "INIT Init",
    "NEXT Next",
    "CONSTANTS",
    "    Probes = {\"catalog\"}",
    "    Children = {\"mcp1\", \"gh\"}",
    "    Deadline = 2",
    "    UseFlag = TRUE",
    "    UseDeadline = TRUE",
    "    UseKill = TRUE",
    "    UseGroupKill = TRUE",
    "    UseSweep = TRUE",
    "    UseCancel = TRUE",
    "    UseJoin = TRUE",
    "    UseStopCheck = TRUE",
    "    UseQuietHandler = TRUE",
    "    UseCap = TRUE",
    "    Cap = 2",
    "INVARIANT NotObserved",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const tlc = await runTlc(dir, "DoctorObserved.tla", "observed.cfg", ["Doctor.tla"], join(TLA_ROOT, "doctor"));
  if (tlc.violated === "NotObserved") return true;
  if (tlc.exitCode === 0) return false;
  throw new Error(`TLC failed for ${label}: ${tlc.output.slice(-2000)}`);
}

describe("fx doctor along Doctor.tla", () => {
  const cases: Array<[string, boolean, boolean, Observation]> = [
    ["both-answer", false, false, { catalog: "result", mcp1: "result", gh: "result" }],
    ["catalog-hangs", true, false, { catalog: "timed_out", mcp1: "result", gh: "result" }],
    ["server-hangs", false, true, { catalog: "result", mcp1: "timed_out", gh: "timed_out" }],
    ["both-hang", true, true, { catalog: "timed_out", mcp1: "timed_out", gh: "timed_out" }],
  ];
  for (const [label, catalogHangs, mcpHangs, want] of cases) {
    test(`${label}: the report is one the spec reaches, by the deadline, with no child left`, async () => {
      const { observed, ms, span, left } = await run(catalogHangs, mcpHangs);
      expect(observed).toEqual(want);
      expect(span).toBeLessThan(DEADLINE_MS + GRACE_MS);
      expect(ms).toBeLessThan(PROCESS_LIMIT_MS);
      expect(left).toBe("");
      expect(await reachable(observed, label)).toBe(true);
    }, TLC_TIMEOUT_MS);
  }

  test("SIGTERM while doctor starts its checks ends it by the signal with nothing left", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-tla-doctor-signal-"));
    // Names and a server line unique to this run, so no other fx on the
    // machine matches them.
    const run = `${process.pid}${Date.now() % 100_000}`;
    const check = `mcp show s${run}_`;
    const server = `sleep 58.${run}`;
    try {
      const home = join(root, "h");
      mkdirSync(join(home, ".fx"), { recursive: true });
      const mcp: Record<string, unknown> = {};
      // Servers that ignore SIGTERM, so only doctor's kill of each check's
      // tree ends them at once.
      for (let i = 0; i < 12; i++) mcp[`s${run}_${i}`] = { command: ["/bin/sh", "-c", `trap '' TERM; exec /bin/${server}`] };
      writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp }));
      const env = { HOME: home, PATH: "/usr/bin:/bin", FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", FX_TEST_DOCTOR_DEADLINE_MS: "30000" };
      const proc = Bun.spawn([fxBin(), "doctor"], { env, cwd: root, stdout: "ignore", stderr: "ignore" });
      const started = performance.now();
      while (running(check) === "" && performance.now() - started < 10_000) await Bun.sleep(1);
      proc.kill("SIGTERM");
      await proc.exited;
      expect(proc.signalCode).toBe("SIGTERM");
      expect(running(check)).toBe("");
      await Bun.sleep(3000);
      expect(running(server)).toBe("");
      expect(await reaches(`main = "exited" /\\ sig /\\ \\A c \\in Children : child[c] # "running" /\\ server[c] # "untold"`, "signal")).toBe(true);
    } finally {
      spawnSync("/usr/bin/pkill", ["-KILL", "-f", server]);
      spawnSync("/usr/bin/pkill", ["-KILL", "-f", check]);
      rmSync(root, { recursive: true, force: true });
    }
  }, TLC_TIMEOUT_MS);

  test("a report the spec cannot produce is rejected", async () => {
    expect(await reachable({ catalog: "none", mcp1: "result", gh: "result" }, "impossible")).toBe(false);
  }, TLC_TIMEOUT_MS);
});
