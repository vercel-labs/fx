// Runs the real benchmarks/startup.sh in a private TMPDIR and checks that it
// removes only the fixture folder it made: a folder already at the old path,
// fx-session-list-benchmark-$$, survives early exits, faults, and signals,
// and a normal run leaves nothing of its own behind. The rules are
// tests/tla/benchmarks/StartupFixture.tla, and
// tests/tla/drivers/benchmarks/driver.ts has TLC check runs like these.
//
// The runs that reach hyperfine need a built fx (zig build), and the normal
// run needs hyperfine too; without them they are skipped.
//
//   FX_SOUND=0 bun test ./benchmarks/startup_fixture.test.ts
//   FX_STARTUP_FUZZ_RUNS=200 FX_STARTUP_FUZZ_SEED=7 bun test ./benchmarks/startup_fixture.test.ts -t fuzz
//   FX_STARTUP_STRESS=1 bun test ./benchmarks/startup_fixture.test.ts -t stress
//   FX_STARTUP_MUTANT=pid-path bun test ./benchmarks/startup_fixture.test.ts   # must fail
import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MARKER, PREFIX, fixtureNames, folderOf, fxBinary, plant, realHyperfine, runStartup } from "../tests/tla/drivers/benchmarks/run";

const root = mkdtempSync(join(tmpdir(), "fx-startup-fixture-test-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

const built = existsSync(fxBinary());
const canBench = built && realHyperfine() !== null;
// A run that reaches hyperfine runs the whole benchmark, which takes seconds.
const LONG = 300_000;
const OWN = new RegExp(`^${PREFIX.replaceAll("-", "\\-")}\\.[A-Za-z0-9]{6}$`);

function scratch(name: string): string {
  return mkdtempSync(join(root, `${name}-`));
}

function folder(path: string): string {
  mkdirSync(path, { recursive: true });
  return path;
}

function intact(tmp: string, name: string): boolean {
  try {
    return readFileSync(join(tmp, name, MARKER), "utf8") === "keep\n";
  } catch {
    return false;
  }
}

test("a folder already at the old PID path survives an early exit without the fx binary", async () => {
  const s = scratch("no-binary");
  const tmp = folder(join(s, "tmp"));
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true });
  expect(run.stdout).toContain("error: fx binary not found");
  expect(run.code).toBe(1);
  expect(intact(tmp, run.pidName)).toBe(true);
  expect(run.after).toEqual([run.pidName]);
  expect(run.gatewayRequests).toBe(0);
});

test.skipIf(!built)("a folder already at the old PID path survives an early exit without hyperfine", async () => {
  const s = scratch("no-hyperfine");
  const tmp = folder(join(s, "tmp"));
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true, binary: true, hyperfine: "missing" });
  expect(run.stdout).toContain("error: hyperfine is not installed");
  expect(run.code).toBe(1);
  expect(intact(tmp, run.pidName)).toBe(true);
  expect(run.after).toEqual([run.pidName]);
}, LONG);

test.skipIf(!canBench)("a normal run removes the folder it made and nothing else", async () => {
  const s = scratch("normal");
  const tmp = folder(join(s, "tmp"));
  plant(tmp, `${PREFIX}.decoy0`);
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true, binary: true, hyperfine: "real" });
  expect(run.stdout).toContain("--- summary ---");
  if (process.platform === "darwin") expect(run.code).toBe(0);
  expect(run.during).not.toBeNull();
  const own = run.during!.names.filter((name) => !run.planted.includes(name));
  expect(own).toHaveLength(1);
  expect(own[0]).toMatch(OWN);
  expect(folderOf(tmp, run.during!.home)).toBe(own[0]);
  expect(run.after).toEqual([...run.planted].sort());
  for (const name of run.planted) expect(intact(tmp, name)).toBe(true);
  expect(run.gatewayRequests).toBe(0);
}, LONG);

test("edge: a folder of the mktemp pattern next to the run's own survives", async () => {
  const s = scratch("pattern");
  const tmp = folder(join(s, "tmp"));
  for (const name of [`${PREFIX}.decoy0`, `${PREFIX}.XXXXXX`, PREFIX, `${PREFIX}-0123`]) plant(tmp, name);
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true });
  expect(run.code).toBe(1);
  expect(run.after).toEqual([...run.planted].sort());
  for (const name of run.planted) expect(intact(tmp, name)).toBe(true);
});

test("edge: a TMPDIR with spaces, glob characters, and a trailing slash", async () => {
  const s = scratch("odd-name");
  const tmp = folder(join(s, "a b*?[x] $HOME 'q'"));
  const run = await runStartup({ scratch: s, tmpdir: `${tmp}/`, plantPid: true });
  expect(run.code).toBe(1);
  expect(intact(tmp, run.pidName)).toBe(true);
  expect(fixtureNames(tmp)).toEqual([run.pidName]);
});

test("edge: runs at once in one TMPDIR each remove only their own folder", async () => {
  const s = scratch("together");
  const tmp = folder(join(s, "tmp"));
  const runs = await Promise.all(Array.from({ length: 4 }, (_, i) =>
    runStartup({ scratch: folder(join(s, `run${i}`)), tmpdir: tmp, plantPid: true })));
  const pids = runs.map((run) => run.pidName).sort();
  for (const run of runs) expect(run.code).toBe(1);
  expect(fixtureNames(tmp)).toEqual(pids);
  for (const name of pids) expect(intact(tmp, name)).toBe(true);
});

test("fault: a read-only TMPDIR makes mktemp fail, and nothing is removed", async () => {
  const s = scratch("read-only");
  const tmp = folder(join(s, "tmp"));
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true, readOnly: true, binary: true });
  if (!run.readOnlyHeld) return; // root can write anyway
  expect(run.stderr).toContain("mktemp");
  expect(run.code).not.toBe(0);
  expect(run.during).toBeNull();
  expect(intact(tmp, run.pidName)).toBe(true);
  expect(run.after).toEqual([run.pidName]);
}, LONG);

test("fault: a missing TMPDIR makes mktemp fail, and nothing is made", async () => {
  const s = scratch("missing");
  const tmp = join(s, "missing");
  const run = await runStartup({ scratch: s, tmpdir: tmp, binary: true });
  expect(run.stderr).toContain("mktemp");
  expect(run.code).not.toBe(0);
  expect(existsSync(tmp)).toBe(false);
}, LONG);

test("fault: a TMPDIR that is a file makes mktemp fail, and the file is kept", async () => {
  const s = scratch("file");
  const tmp = join(s, "tmp");
  writeFileSync(tmp, "not a folder\n");
  const run = await runStartup({ scratch: s, tmpdir: tmp, binary: true });
  expect(run.stderr).toContain("mktemp");
  expect(run.code).not.toBe(0);
  expect(readFileSync(tmp, "utf8")).toBe("not a folder\n");
}, LONG);

test.skipIf(!built)("crash: SIGTERM while hyperfine runs: the trap removes only the run's own folder", async () => {
  const s = scratch("sigterm");
  const tmp = folder(join(s, "tmp"));
  plant(tmp, `${PREFIX}.decoy0`);
  const run = await runStartup({ scratch: s, tmpdir: tmp, plantPid: true, binary: true, hyperfine: "sigterm" });
  expect(run.signal === "SIGTERM" || run.code === 143).toBe(true);
  expect(run.during).not.toBeNull();
  const own = run.during!.names.filter((name) => !run.planted.includes(name));
  expect(own).toHaveLength(1);
  expect(own[0]).toMatch(OWN);
  expect(run.after).toEqual([...run.planted].sort());
  for (const name of run.planted) expect(intact(tmp, name)).toBe(true);
}, LONG);

test.skipIf(!built)("crash: SIGKILL while hyperfine runs leaves the run's folder, and the next run leaves it alone", async () => {
  const s = scratch("sigkill");
  const tmp = folder(join(s, "tmp"));
  const killed = await runStartup({ scratch: folder(join(s, "killed")), tmpdir: tmp, binary: true, hyperfine: "sigkill" });
  expect(killed.signal).toBe("SIGKILL");
  expect(killed.during).not.toBeNull();
  const leaked = killed.during!.names;
  expect(leaked).toHaveLength(1);
  expect(killed.after).toEqual(leaked);
  const contents = readdirSync(join(tmp, leaked[0]!)).sort();
  expect(contents).toEqual(["general-home", "home", "workspace"]);

  const next = await runStartup({ scratch: folder(join(s, "next")), tmpdir: tmp, plantPid: true });
  expect(next.code).toBe(1);
  expect(next.after).toEqual([...leaked, next.pidName].sort());
  expect(readdirSync(join(tmp, leaked[0]!)).sort()).toEqual(contents);
  expect(intact(tmp, next.pidName)).toBe(true);
}, LONG);

// mulberry32: a small seeded generator, so a failing case replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Seeds kept from earlier runs; FX_STARTUP_FUZZ_RUNS adds more from
// FX_STARTUP_FUZZ_SEED.
const SAVED_SEEDS = [1, 2, 3, 5, 8, 13, 21, 34];
const NAME_CHARS = "abcXYZ019 -_.*?[]'\"$`\\!#%&();<>|~=é";
const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

async function fuzzCase(seed: number) {
  const next = generator(seed);
  const pick = (chars: string) => chars[Math.floor(next() * chars.length)]!;
  const length = 1 + Math.floor(next() * 12);
  let name = Array.from({ length }, () => pick(NAME_CHARS)).join("");
  if (name === "." || name === "..") name = `${name}x`;
  const s = scratch(`fuzz-${seed}`);
  const tmp = folder(join(s, name));
  const planted: string[] = [];
  for (let i = Math.floor(next() * 4); i > 0; i--) {
    const kind = Math.floor(next() * 3);
    const planted_name = kind === 0
      ? `${PREFIX}.${Array.from({ length: 6 }, () => pick(ALNUM)).join("")}`
      : kind === 1
      ? `${PREFIX}-0${Math.floor(next() * 100000)}` // a leading 0: never a real PID
      : `${PREFIX}${pick("._-")}${pick(ALNUM)}`;
    if (planted.includes(planted_name)) continue;
    plant(tmp, planted_name);
    planted.push(planted_name);
  }
  const slash = next() < 0.5 ? "/" : "";
  const plantPid = next() < 0.7;
  const run = await runStartup({ scratch: s, tmpdir: `${tmp}${slash}`, plantPid });
  const kept = plantPid ? [...planted, run.pidName] : planted;
  const where = `seed ${seed}, TMPDIR ${JSON.stringify(tmp + slash)}`;
  expect(run.code, where).toBe(1);
  expect(fixtureNames(tmp), where).toEqual([...kept].sort());
  for (const name of kept) expect(intact(tmp, name), `${where}, ${name}`).toBe(true);
}

test("fuzz: random TMPDIR names and planted folders", async () => {
  const extra = Number(process.env.FX_STARTUP_FUZZ_RUNS ?? "0");
  const first = Number(process.env.FX_STARTUP_FUZZ_SEED ?? "1000");
  const seeds = [...SAVED_SEEDS, ...Array.from({ length: extra }, (_, i) => first + i)];
  console.log(`fuzz: ${seeds.length} cases, seeds ${SAVED_SEEDS.join(",")}${extra ? ` and ${first}..${first + extra - 1}` : ""}`);
  for (const seed of seeds) await fuzzCase(seed);
}, 600_000);

test.skipIf(process.env.FX_STARTUP_STRESS !== "1")("stress: 1000 planted folders and 32 runs at once", async () => {
  const s = scratch("stress");
  const tmp = folder(join(s, "tmp"));
  const planted: string[] = [];
  for (let i = 0; i < 1000; i++) {
    const name = i % 2 === 0 ? `${PREFIX}.s${String(i).padStart(5, "0")}` : `${PREFIX}-0${i}`;
    plant(tmp, name);
    planted.push(name);
  }
  const started = performance.now();
  const runs = await Promise.all(Array.from({ length: 32 }, (_, i) =>
    runStartup({ scratch: folder(join(s, `run${i}`)), tmpdir: tmp, plantPid: true })));
  console.log(`stress: 32 runs over 1000 planted folders in ${Math.round(performance.now() - started)} ms`);
  const kept = [...planted, ...runs.map((run) => run.pidName)].sort();
  for (const run of runs) expect(run.code).toBe(1);
  expect(fixtureNames(tmp)).toEqual(kept);
  for (const name of kept) expect(intact(tmp, name)).toBe(true);
}, 600_000);
