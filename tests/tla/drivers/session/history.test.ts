// Runs the real fx binary along tests/tla/session/PromptHistory.tla: a
// profile starts with a seeded input history, fx's TUI submits prompts
// against a fake gateway, and after every step the driver reads what fx left
// in the history file: its length, the sizes of its newest valid records, and
// the bytes after its last newline. TLC then replays the run through the
// model (PromptHistoryTrace.tla) with the store's limits, so a compaction the
// limits do not allow, or a missing one, rejects the run.
//
// Every fx process starts through `env -i` with each variable written out:
// a temporary HOME and FX_HOME, FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, and the
// fake gateway's URLs and key. Every prompt must reach the gateway once.
//
// The scenarios: a history over the trigger, then the largest record the
// store takes; one between the old and the new trigger; the record limit
// binding; malformed lines, a torn tail and a duplicate; fx killed during a
// turn and a torn write before the next launch; and, on macOS, a compaction
// whose rename fails (../lib/path-fault.c). The seeded fuzz walks
// (FX_TLA_WALKS, default 2, of FX_TLA_STEPS steps, default 6, from
// FX_TLA_SEED, default 1) pick seed sizes and prompts around the trigger.
// FX_TLA_STRESS=1 adds a 64 MiB history. FX_TLA_BASE_BIN names a build of fx
// before the change, whose run the old limits must accept and the new ones
// reject. FX_TLA_KEEP=1 keeps every profile.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { platform } from "node:os";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers } from "../lib/context";
import { writeJson } from "../lib/tlc";
import {
  BEFORE, checkTrace, FIXED, type HistoryObservation, type Limits, readHistoryFile, recordLine, type TraceResult,
} from "./history-bridge";

const { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, heldFakeGatewayFinalText, startDynamicFakeGateway, TmuxSession, tmuxAvailable } =
  await targetHelpers();

const TIMEOUT = 900_000;
const STEP = 60_000;
const KiB = 1024;
const MiB = 1024 * KiB;
const keep = process.env.FX_TLA_KEEP === "1";

/// A small seeded generator (mulberry32), so a walk replays from its seed.
function random(seed: number) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { next, int: (lo: number, hi: number) => lo + Math.floor(next() * (hi - lo + 1)) };
}

/// Prompt text of `length` bytes that JSON and the composer keep as typed.
function words(label: string, length: number, rng = random(length)): string {
  const letters = "abcdefghijklmnopqrstuvwxyz";
  let text = `${label} `;
  while (text.length < length) {
    text += letters[Math.floor(rng.next() * letters.length)];
    if (rng.next() < 0.15 && text.length < length - 1) text += " ";
  }
  return text.slice(0, length).trimEnd();
}

/// Seed text of `length` bytes, cheap enough for a 64 MiB history.
function filler(label: string, length: number): string {
  return `${label} ${"x".repeat(Math.max(0, length - label.length - 1))}`;
}

let pathFault: string | null = null;
/// ../lib/path-fault.c, built once per run.
function pathFaultLibrary(): string {
  if (pathFault) return pathFault;
  const library = join(artifacts, "path-fault.dylib");
  const built = Bun.spawnSync([
    "clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", join(import.meta.dirname, "../lib/path-fault.c"), "-o", library,
  ]);
  if (built.exitCode !== 0) throw new Error(`building the path fault failed: ${built.stderr.toString()}`);
  return (pathFault = library);
}

/// One profile: a seeded history, the fx processes that use it, and what the
/// driver did to it.
class Profile {
  readonly root: string;
  readonly home: string;
  readonly fxHome: string;
  readonly workspace: string;
  readonly history: string;
  readonly trace: string;
  readonly observations: HistoryObservation[] = [];
  readonly gateway: any;
  shell: any = null;
  private prompts = 0;
  private launches = 0;
  private lastText: string | null = null;
  private held: ReturnType<typeof heldFakeGatewayFinalText> | null = null;
  private holdNext = false;

  constructor(readonly name: string, readonly bin: string, readonly limits: Limits = FIXED) {
    this.root = realpathSync(mkdtempSync(join(artifacts, `${name}-`)));
    this.home = join(this.root, "home");
    this.fxHome = join(this.root, "fx-home");
    this.workspace = join(this.root, "workspace");
    for (const dir of [this.home, this.fxHome, this.workspace]) mkdirSync(dir, { mode: 0o700 });
    this.history = join(this.fxHome, "history.jsonl");
    this.trace = join(this.root, "trace.log");
    this.gateway = startDynamicFakeGateway(() => {
      const n = this.gateway.requestCount();
      if (this.holdNext) {
        this.holdNext = false;
        this.held = heldFakeGatewayFinalText();
        return this.held.response;
      }
      return fakeGatewayFinalText(`answer ${n} done`);
    });
  }

  /// Seed records of `sizes[i]` bytes each, newline included, as fx writes
  /// them, then `extra` raw bytes.
  seed(sizes: number[], extra = "") {
    const lines: string[] = [];
    sizes.forEach((size, index) => {
      const empty = recordLine(1_000_000 + index, this.workspace, "").length;
      lines.push(recordLine(1_000_000 + index, this.workspace, filler(`seed${index}`, size - empty)));
    });
    writeFileSync(this.history, lines.join("") + extra, { mode: 0o600 });
    this.observe("seed", 0);
  }

  /// Seed records of about `size` bytes until the file passes `bytes`.
  seedUntil(bytes: number, size: number, rng = random(bytes)) {
    const sizes: number[] = [];
    let total = 0;
    while (total <= bytes) {
      const next = Math.max(120, size + rng.int(-size / 10, size / 10));
      sizes.push(next);
      total += next;
    }
    this.seed(sizes);
  }

  observe(op: HistoryObservation["op"], size: number) {
    const { observation } = readHistoryFile(this.history, this.limits);
    this.observations.push({ op, size, ...observation });
  }

  env(extra: Record<string, string>): Record<string, string> {
    return {
      HOME: this.home,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      TERM: "xterm-256color",
      LANG: "en_US.UTF-8",
      FX_HOME: this.fxHome,
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_DOTENV: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_TEST_INPUT_LOOP_NETWORK_GUARD: "1",
      AI_GATEWAY_API_KEY: "prompt-history-fixture",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_TRACE_LOG: this.trace,
      FX_TRACE_SCOPES: "prompt_history",
      ...extra,
    };
  }

  /// Starts fx through `env -i`, with every variable on its command line.
  async launch(extra: Record<string, string> = {}) {
    this.launches += 1;
    const assignments = Object.entries(this.env(extra)).map(([key, value]) => `${key}=${value}`);
    this.shell = await TmuxSession.create({
      cmd: ["/usr/bin/env", "-i", ...assignments, this.bin].map(shellQuote).join(" "),
      cwd: this.workspace,
      width: 120,
      height: 40,
      stderrPath: join(this.root, `fx-${this.launches}.stderr`),
      remainOnExit: true,
      isolated: true,
    });
    await this.shell.waitForStableComposer(STEP);
  }

  /// fx starts again on the same profile; starting writes nothing.
  async restart(extra: Record<string, string> = {}) {
    await this.launch(extra);
    this.observe("restart", 0);
  }

  /// Types `text` (or pastes it when long) and submits it; waits for the
  /// reply unless `hold` keeps the turn open.
  async submit(text: string, hold = false) {
    const n = (this.prompts += 1);
    const duplicate = text === this.lastText;
    this.holdNext = hold;
    if (text.length > 8 * KiB) await this.shell.pasteText(text);
    else await this.shell.sendLiteral(text);
    await this.shell.sendKeys("Enter");
    if (hold) {
      const deadline = Date.now() + STEP;
      while (this.gateway.requestCount() < n && Date.now() < deadline) await Bun.sleep(25);
    } else {
      await this.shell.waitForText(`answer ${n} done`, STEP);
    }
    // One model request per prompt: the run really went through fx.
    expect(this.gateway.requestCount()).toBe(n);
    this.lastText = text;
    const { observation, records } = readHistoryFile(this.history, this.limits);
    if (duplicate) {
      this.observations.push({ op: "duplicate", size: 0, ...observation });
      return;
    }
    const newest = records.at(-1);
    if (newest?.text !== text) {
      throw new Error(`${this.name}: the newest record is not prompt ${n}: ${JSON.stringify(newest?.text.slice(0, 80))}`);
    }
    this.observations.push({ op: "append", size: newest.size, ...observation });
  }

  /// SIGKILL the fx process, as a crash would.
  async crash() {
    const pid = this.shell.processPid();
    process.kill(pid, "SIGKILL");
    const deadline = Date.now() + STEP;
    while (Date.now() < deadline) {
      try {
        process.kill(pid, 0);
      } catch {
        break;
      }
      await Bun.sleep(25);
    }
    this.held?.dispose();
    this.held = null;
    await this.shell.kill();
    this.shell = null;
  }

  /// A crash in the middle of an append: the append cut any torn tail, as
  /// `repairIncompleteTail` does, then wrote `bytes` of its line, no newline.
  tear(bytes: number) {
    const current = readFileSync(this.history);
    const whole = current.subarray(0, current.lastIndexOf(0x0a) + 1);
    const partial = recordLine(1, this.workspace, filler("torn", bytes)).slice(0, bytes);
    writeFileSync(this.history, Buffer.concat([whole, Buffer.from(partial)]));
    this.observe("torn", bytes);
  }

  async check(limits: Limits = this.limits): Promise<TraceResult> {
    const result = await checkTrace(this.observations, limits, join(this.root, `tlc-${limits.trigger}`));
    writeJson(join(this.root, "observations.json"), this.observations);
    return result;
  }

  async close(passed: boolean) {
    if (this.shell) await this.shell.kill().catch(() => {});
    this.held?.dispose();
    this.gateway.stop();
    if (keep || !passed) console.error(`kept prompt history profile ${this.name} at ${this.root}`);
    else rmSync(this.root, { recursive: true, force: true });
  }
}

/// The compactions in a run: steps after which the file is not the previous
/// file plus the new line.
function compactions(observations: HistoryObservation[]): number[] {
  const at: number[] = [];
  observations.forEach((o, i) => {
    if (i > 0 && o.op === "append" && o.len !== observations[i - 1]!.len - observations[i - 1]!.torn + o.size) at.push(i);
  });
  return at;
}

/// Runs `body` on a new profile, then `checks` on what it observed, and
/// keeps the profile's files when either fails.
async function scenario(
  name: string,
  bin: string,
  limits: Limits,
  body: (profile: Profile) => Promise<void>,
  checks: (profile: Profile) => Promise<void> = expectAccepted,
) {
  const profile = new Profile(name, bin, limits);
  let passed = false;
  try {
    await body(profile);
    if (profile.shell) await profile.shell.kill();
    profile.shell = null;
    await checks(profile);
    passed = true;
  } finally {
    await profile.close(passed);
  }
  return profile;
}

async function expectAccepted(profile: Profile) {
  const result = await profile.check();
  writeJson(join(artifacts, `${profile.name}-verdict.json`), { ...result, compactions: compactions(profile.observations) });
  expect(result.verdict, `${profile.name}: ${result.detail}`).toBe("ACCEPTED");
}

let kept: HistoryObservation[] = [];

/// A history over the trigger: the first prompt compacts it, then the largest
/// record the store takes and records of the report's 1.1 KiB only add.
async function overTrigger(profile: Profile) {
  profile.seedUntil(FIXED.trigger + 64 * KiB, 1100);
  await profile.launch();
  await profile.submit(words("first", 1029));
  await profile.submit(words("largest", FIXED.maxRecord - 2 * KiB));
  for (let i = 0; i < 6; i += 1) await profile.submit(words(`report${i}`, 1029));
}

/// Seeds records of about 1.1 KiB to between 6 KiB and 4.8 KiB under the
/// trigger, so two prompts of 1.1 KiB stay under it and a third of 5 KiB
/// passes it, whatever the record overhead of the profile's paths.
function seedUnderTrigger(profile: Profile) {
  profile.seedUntil(FIXED.trigger - 6 * KiB, 1100);
}

const tmux = tmuxAvailable();

test.skipIf(!tmux)("a history over the trigger compacts once, then each prompt only adds its line", async () => {
  const profile = await scenario("over-trigger", binary, FIXED, overTrigger, async (p) => {
    await expectAccepted(p);
    expect(compactions(p.observations)).toEqual([1]);
  });
  kept = profile.observations;
}, TIMEOUT);

test.skipIf(!tmux)("a history between the old and the new trigger is not compacted", async () => {
  await scenario("between-triggers", binary, FIXED, async (p) => {
    p.seedUntil(1.5 * MiB, 1100);
    await p.launch();
    for (let i = 0; i < 4; i += 1) await p.submit(words(`between${i}`, 1029));
  }, async (p) => {
    await expectAccepted(p);
    expect(compactions(p.observations)).toEqual([]);
  });
}, TIMEOUT);

test.skipIf(!tmux)("when the record limit binds, a compaction keeps 1000 records under the byte target", async () => {
  await scenario("record-limit", binary, FIXED, async (p) => {
    p.seedUntil(FIXED.trigger + 16 * KiB, 800);
    await p.launch();
    for (let i = 0; i < 3; i += 1) await p.submit(words(`limit${i}`, 700));
  }, async (p) => {
    await expectAccepted(p);
    expect(compactions(p.observations)).toEqual([1]);
    expect(p.observations[1]!.tail.length).toBe(FIXED.recordLimit);
    expect(p.observations[1]!.len).toBeLessThan(FIXED.target);
  });
}, TIMEOUT);

test.skipIf(!tmux)("malformed lines and a torn tail are cut, and a duplicate writes nothing", async () => {
  await scenario("junk-and-duplicate", binary, FIXED, async (p) => {
    const junk = ["not a record\n", '{"schema_version":2,"timestamp_ms":1,"workspace_root":"/x","text":"x"}\n'];
    const lines: string[] = [];
    for (let index = 0, total = 0; total <= FIXED.trigger; index += 1) {
      const empty = recordLine(2_000_000 + index, p.workspace, "").length;
      const line = recordLine(2_000_000 + index, p.workspace, filler(`seed${index}`, 1100 - empty));
      lines.push(line);
      total += line.length;
      if (index % 97 === 0) lines.push(junk[index % 2]!);
    }
    writeFileSync(p.history, lines.join("") + '{"schema_version":1,"timestamp_ms":3,"workspace_r', { mode: 0o600 });
    p.observe("seed", 0);
    await p.launch();
    const text = words("repeated", 900);
    await p.submit(text);
    await p.submit(text);
    await p.submit(words("after", 900));
  }, async (p) => {
    await expectAccepted(p);
    expect(p.observations[0]!.torn).toBeGreaterThan(0);
    expect(p.observations.map((o) => o.op)).toEqual(["seed", "append", "duplicate", "append"]);
    expect(compactions(p.observations)).toEqual([1]);
  });
}, TIMEOUT);

test.skipIf(!tmux)("after a kill during a turn and a torn write, the next launch compacts by length alone", async () => {
  await scenario("crash", binary, FIXED, async (p) => {
    seedUnderTrigger(p);
    await p.launch();
    await p.submit(words("before-crash", 1029));
    await p.submit(words("held", 1029), true);
    await p.crash();
    p.tear(300);
    await p.restart();
    await p.submit(words("after-crash", 5000));
    await p.submit(words("then", 1029));
    await p.submit(words("and-then", 1029));
  }, async (p) => {
    await expectAccepted(p);
    expect(p.observations.map((o) => o.op)).toEqual(["seed", "append", "append", "torn", "restart", "append", "append", "append"]);
    expect(compactions(p.observations)).toEqual([5]);
  });
}, TIMEOUT);

test.skipIf(!tmux || platform() !== "darwin")("a compaction whose rename fails keeps the line and is retried by the next prompt", async () => {
  await scenario("rename-fault", binary, { ...FIXED, faults: true }, async (p) => {
    seedUnderTrigger(p);
    const arm = join(p.root, "fault.arm");
    await p.launch({
      DYLD_INSERT_LIBRARIES: pathFaultLibrary(),
      FX_PATH_FAULT_TARGETS: realpathSync(p.fxHome),
      FX_PATH_FAULT_MODE: "refuse",
      FX_PATH_FAULT_ARM: arm,
      FX_PATH_FAULT_RECORD: join(p.root, "fault.record"),
    });
    // The first prompt opens the session before any rename is refused.
    await p.submit(words("warm-up", 1029));
    writeFileSync(arm, "");
    await p.submit(words("refused", 5000));
    rmSync(arm);
    await p.submit(words("retried", 1029));
    await p.submit(words("after-retry", 1029));
  }, async (p) => {
    // The fault reached the compaction's rename, and fx logged the stale outcome.
    const record = join(p.root, "fault.record");
    expect(existsSync(record) ? readFileSync(record, "utf8") : "").toMatch(/refused .*\/\.history\.jsonl\.tmp\.[0-9a-f]+/);
    expect(existsSync(p.trace) ? readFileSync(p.trace, "utf8") : "").toContain("compaction stale after append");
    await expectAccepted(p);
    expect(compactions(p.observations)).toEqual([3]);
  });
}, TIMEOUT);

/// One random walk: a seed size and record size, then prompts, repeats, and
/// crashes with a torn write, all from `seed` and `walk`.
async function fuzzWalk(seed: number, walk: number, steps: number) {
  const rng = random(seed * 1000 + walk);
  await scenario(`fuzz-${seed}-${walk}`, binary, FIXED, async (p) => {
    p.seedUntil(rng.int(1.6 * MiB, 2.4 * MiB), rng.int(200, 3000), rng);
    await p.launch();
    let last: string | null = null;
    for (let step = 0; step < steps; step += 1) {
      const roll = rng.next();
      if (roll < 0.15 && last) {
        await p.submit(last);
      } else if (roll < 0.25) {
        await p.crash();
        p.tear(rng.int(1, 400));
        await p.restart();
      } else {
        last = words(`walk${walk}step${step}`, rng.next() < 0.1 ? rng.int(16 * KiB, 120 * KiB) : rng.int(20, 4000), rng);
        await p.submit(last);
      }
    }
  }, async (p) => {
    const result = await p.check();
    writeJson(join(artifacts, `${p.name}-verdict.json`), { ...result, compactions: compactions(p.observations) });
    expect(result.verdict, `walk ${walk} of seed ${seed} (replay with FX_TLA_SEED=${seed}): ${result.detail}`).toBe("ACCEPTED");
  });
}

/// Walks that once failed, replayed on every run: [seed, walk, steps].
/// 7/3 tore the file twice with no append between, which only a tear that
/// keeps the earlier torn tail can do.
const SAVED_WALKS: Array<[number, number, number]> = [[7, 3, 8]];

test.skipIf(!tmux)("seeded fuzz: random history sizes and prompts around the trigger", async () => {
  for (const [seed, walk, steps] of SAVED_WALKS) await fuzzWalk(seed, walk, steps);
  const seed = Number(process.env.FX_TLA_SEED ?? "1");
  const walks = Number(process.env.FX_TLA_WALKS ?? "2");
  const steps = Number(process.env.FX_TLA_STEPS ?? "6");
  for (let walk = 0; walk < walks; walk += 1) await fuzzWalk(seed, walk, steps);
}, TIMEOUT);

test.skipIf(!tmux || process.env.FX_TLA_STRESS !== "1")("stress: a 64 MiB history compacts once and then only grows", async () => {
  let firstMs = 0;
  await scenario("stress", binary, FIXED, async (p) => {
    p.seedUntil(64 * MiB, 1100);
    await p.launch();
    const started = performance.now();
    await p.submit(words("first", 1029));
    firstMs = performance.now() - started;
    for (let i = 0; i < 10; i += 1) await p.submit(words(`stress${i}`, 1029));
  }, async (p) => {
    writeJson(join(artifacts, "stress-timing.json"), { seededBytes: p.observations[0]!.len, firstSubmitMs: Math.round(firstMs) });
    await expectAccepted(p);
    expect(compactions(p.observations)).toEqual([1]);
  });
}, TIMEOUT);

test.skipIf(!tmux)("planted changes to a kept run are rejected, and an empty run is no evidence", async () => {
  expect(kept.length).toBeGreaterThan(2);
  const dir = join(artifacts, "planted");
  const at = compactions(kept)[0]!;
  // The compaction claimed as a plain append.
  const missed = kept.map((o, i) => i === at ? { ...o, len: kept[i - 1]!.len + o.size } : o);
  // The append after it claimed as another compaction.
  const extra = kept.map((o, i) => i === at + 1 ? { ...o, len: kept[at]!.len, tail: [...kept[at]!.tail.slice(1), o.size] } : o);
  // One byte off.
  const off = kept.map((o, i) => i === kept.length - 1 ? { ...o, len: o.len + 1 } : o);
  for (const [name, planted] of [["missed", missed], ["extra", extra], ["off", off]] as const) {
    const result = await checkTrace(planted, FIXED, join(dir, name));
    expect(result.verdict, `${name}: ${result.detail}`).toBe("REJECTED");
  }
  // The same run is not one the old rule could make: that rule compacts again.
  expect((await checkTrace(kept, BEFORE, join(dir, "before"))).verdict).toBe("REJECTED");
  expect((await checkTrace([], FIXED, join(dir, "empty"))).verdict).toBe("TOOL_ERROR");
}, TIMEOUT);

const baseBin = process.env.FX_TLA_BASE_BIN;
test.skipIf(!tmux || !baseBin)("fx before the change follows the old rule and breaks the new one", async () => {
  await scenario("base-over-trigger", baseBin!, BEFORE, overTrigger, async (p) => {
    const before = await checkTrace(p.observations, BEFORE, join(p.root, "tlc-before"));
    const fixed = await checkTrace(p.observations, FIXED, join(p.root, "tlc-fixed"));
    writeJson(join(artifacts, "base-verdicts.json"), { before, fixed, compactions: compactions(p.observations) });
    expect(before.verdict, before.detail).toBe("ACCEPTED");
    expect(fixed.verdict, fixed.detail).toBe("REJECTED");
  });
}, TIMEOUT);
