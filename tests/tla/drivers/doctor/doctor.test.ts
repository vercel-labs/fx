// Drives the built fx doctor along tests/tla/doctor/Doctor.tla: each run
// makes the provider catalog, one MCP server, and gh answer or hang, maps the
// report to the spec's `report` variable, and has TLC confirm the spec can
// reach that report. A report the spec cannot produce must be rejected,
// doctor must end by the deadline plus its reap grace, which it can only do
// once it has cancelled and joined every check (NoTaskAfterReport), and
// neither a child nor a process a child started in its group may outlive
// doctor (NoChildAfterExit): the hanging gh runs a sleep of its own.
import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fxBin, outDir, REPO_ROOT, runTlc, TLA_ROOT } from "../lib/tlc";

const FIXTURE = join(REPO_ROOT, "tests", "e2e", "fixtures", "mcp-modern-stdio.mjs");
const DEADLINE_MS = 1500;
const GRACE_MS = 2500;
type Outcome = "result" | "timed_out" | "none";
type Observation = { catalog: Outcome; mcp1: Outcome; gh: Outcome };
const GH_GRANDCHILD = "sleep 59.8765";

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
async function run(catalogHangs: boolean, mcpHangs: boolean): Promise<{ observed: Observation; ms: number; left: string }> {
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
    };
    const started = performance.now();
    const proc = Bun.spawn([fxBin(), "doctor", "--json"], { env, cwd: ws, stdout: "pipe", stderr: "ignore" });
    const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
    const ms = performance.now() - started;
    const left = [running("mcp show mcp1 --json"), running(GH_GRANDCHILD)].filter(Boolean).join("\n");
    const checks: Array<{ name: string; status: string; detail: string }> = JSON.parse(out).checks;
    const catalog: Outcome = checks.some((c) => c.name === "provider" && c.detail.includes("could not reach"))
      ? "timed_out"
      : checks.some((c) => c.name === "model") ? "result" : "none";
    const server = checks.find((c) => c.name === "mcp" && c.detail.startsWith("mcp1"));
    const mcp: Outcome = !server ? "none" : server.detail.includes("did not start in") ? "timed_out" : "result";
    const ghLine = checks.find((c) => c.name === "gh");
    const gh: Outcome = !ghLine ? "none" : ghLine.detail.includes("did not answer") ? "timed_out" : "result";
    return { observed: { catalog, mcp1: mcp, gh }, ms, left };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** Whether the spec can reach `main = "reported"` with this report. */
async function reachable(observed: Observation, label: string): Promise<boolean> {
  const dir = outDir(`doctor-driver-${label}`);
  const value = (o: Outcome) => `"${o}"`;
  writeFileSync(join(dir, "DoctorObserved.tla"), [
    "---- MODULE DoctorObserved ----",
    "EXTENDS Doctor",
    `Observed == [x \\in Checks |-> IF x = "catalog" THEN ${value(observed.catalog)} ELSE IF x = "mcp1" THEN ${value(observed.mcp1)} ELSE ${value(observed.gh)}]`,
    "NotObserved == ~(main = \"reported\" /\\ report = Observed)",
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
    "    UseCancel = TRUE",
    "    UseJoin = TRUE",
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
      const { observed, ms, left } = await run(catalogHangs, mcpHangs);
      expect(observed).toEqual(want);
      expect(ms).toBeLessThan(DEADLINE_MS + GRACE_MS);
      expect(left).toBe("");
      expect(await reachable(observed, label)).toBe(true);
    }, 60_000);
  }

  test("a report the spec cannot produce is rejected", async () => {
    expect(await reachable({ catalog: "none", mcp1: "result", gh: "result" }, "impossible")).toBe(false);
  }, 60_000);
});
