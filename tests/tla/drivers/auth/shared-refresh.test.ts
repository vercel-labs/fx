// SharedLoginRefresh: real fx processes (`fx ask` from zig-out/bin/fx, or
// FX_BIN) share one saved fx login against the fakes in
// tests/e2e/shared-login-fakes.ts: an issuer that rotates the refresh token
// on every refresh, and a gateway that then takes only the newest access
// token. Each scenario's ordered log, what the fakes saw and what the harness
// did, is checked by TLC through tests/tla/auth/SharedLoginRefreshTrace.tla,
// the rules of tests/tla/auth/SharedLoginRefresh.tla. Every run must be
// ACCEPTED.
//
// The named scenarios are the cases tests/e2e/auth-refresh.test.ts asserts.
// The random rounds (FX_TLA_AUTH_ROUNDS, seeded by FX_TLA_AUTH_SEED, printed)
// mix process counts, delays, an outside rotation, and an issuer failure.
// Controls: a log with a planted redundant refresh, one with a resend that no
// 401 called for, an impossible record, and an empty log must not be
// accepted.
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  barrier,
  seededRandom,
  spawnSharedAsk,
  startSharedLoginWorld,
  type IssuerOptions,
  type SharedLoginEvent,
  type SharedLoginWorld,
  type SharedProvider,
} from "../../../e2e/shared-login-fakes";
import { artifacts, binary } from "../lib/context";
import { checkTrace, type Verdict } from "./trace";

const TIMEOUT = 180_000;

type Hold = (label: string, attempt: number) => Promise<void> | void;
type Scenario = {
  name: string;
  procs: number;
  issuer?: IssuerOptions;
  /** Whose login the processes share; the fx login when left out. */
  provider?: SharedProvider;
  /** Sets the gateway's hold and runs the processes to their end. */
  drive: (world: SharedLoginWorld, setHold: (hold: Hold) => void, labels: string[]) => Promise<void>;
};

async function runAll(world: SharedLoginWorld, labels: string[]): Promise<void> {
  await Promise.all(labels.map((label) => spawnSharedAsk(world, label, {}, binary).done));
}

async function waitUntil(what: string, condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(10);
  }
}

/** All `labels` hold generation 0, which the gateway no longer takes, and get their 401 together. */
function together(name: string, procs: number, issuer?: IssuerOptions, answerDelayMs?: () => number, provider?: SharedProvider): Scenario {
  return {
    name,
    procs,
    issuer,
    provider,
    drive: async (world, setHold, labels) => {
      const allSent = barrier(labels.length);
      setHold(async (_label, attempt) => {
        if (attempt !== 0) return;
        await allSent();
        if (answerDelayMs) await Bun.sleep(answerDelayMs());
      });
      world.revoke(0);
      await runAll(world, labels);
    },
  };
}

/** One process whose token another fx replaces while its first request is out. */
function replaced(name: string, expiresInMs?: number, provider?: SharedProvider): Scenario {
  return {
    name,
    procs: 1,
    provider,
    drive: async (world, setHold, labels) => {
      setHold((_label, attempt) => {
        if (attempt === 0) world.replaceOutside(expiresInMs === undefined ? undefined : Date.now() + expiresInMs);
      });
      await runAll(world, labels);
    },
  };
}

const named: Scenario[] = [
  together("together-2", 2),
  replaced("replaced"),
  replaced("past-deadline", 30_000),
  replaced("before-deadline", 90_000),
  together("slow-issuer-3", 3, { beforeAnswer: () => Bun.sleep(1_500) }),
  together("issuer-500", 2, { failWith: (index) => (index === 0 ? 500 : null) }),
  together("stress-6", 6),
  together("codex-together-3", 3, undefined, undefined, "codex"),
  together("grok-together-3", 3, undefined, undefined, "grok"),
  together("codex-kept-refresh-2", 2, { keepRefreshToken: true }, undefined, "codex"),
  replaced("codex-replaced", undefined, "codex"),
  replaced("grok-replaced", undefined, "grok"),
  replaced("grok-past-deadline", 30_000, "grok"),
  {
    name: "killed-after-save",
    procs: 2,
    drive: async (world, setHold) => {
      const bothSent = barrier(2);
      let markKilled = () => {};
      const killed = new Promise<void>((resolve) => {
        markKilled = resolve;
      });
      setHold(async (label, attempt) => {
        if (attempt === 0) {
          await bothSent();
          if (label === "p2") await killed;
        } else if (label === "p1") {
          await killed;
          throw new Error("p1 was killed");
        }
      });
      world.revoke(0);
      const p1 = spawnSharedAsk(world, "p1", {}, binary);
      const p2 = spawnSharedAsk(world, "p2", {}, binary);
      await waitUntil("p1's retry", () => world.events.some((e) => e.event === "send" && e.data.p === "p1" && e.data.tok === 1));
      p1.kill();
      world.noteKill("p1");
      await p1.done;
      markKilled();
      await p2.done;
    },
  },
  {
    name: "killed-mid-refresh",
    procs: 2,
    issuer: { reuseGrace: true },
    drive: async (world, setHold) => {
      const bothSent = barrier(2);
      let markKilled = () => {};
      const killed = new Promise<void>((resolve) => {
        markKilled = resolve;
      });
      // The issuer's first answer waits for the kill; see `issuerHold` below.
      issuerHold = (index) => (index === 0 ? killed : Promise.resolve());
      setHold(async (label, attempt) => {
        if (attempt !== 0) return;
        await bothSent();
        if (label === "p2") await killed;
      });
      world.revoke(0);
      const p1 = spawnSharedAsk(world, "p1", {}, binary);
      const p2 = spawnSharedAsk(world, "p2", {}, binary);
      await waitUntil("p1's refresh", () => world.tokenRequests.length === 1);
      p1.kill();
      world.noteKill("p1");
      await p1.done;
      markKilled();
      await p2.done;
    },
  },
];

// The issuer's answers can wait on a scenario's own promise, set by `drive`.
let issuerHold: (index: number) => Promise<void> = () => Promise.resolve();

function randomRounds(): Scenario[] {
  const rounds = Number(process.env.FX_TLA_AUTH_ROUNDS ?? "4");
  const seed = Number(process.env.FX_TLA_AUTH_SEED ?? String(Date.now() % 2_147_483_647));
  console.log(`shared login driver: seed=${seed} rounds=${rounds}`);
  const random = seededRandom(seed);
  const scenarios: Scenario[] = [];
  for (let round = 0; round < rounds; round += 1) {
    const procs = 2 + Math.floor(random() * 3);
    const issuerDelay = Math.floor(random() * 200);
    const failFirst = random() < 0.25;
    const outside = random() < 0.35;
    const delays = Array.from({ length: 16 }, () => Math.floor(random() * 120));
    let next = 0;
    const issuer: IssuerOptions = {
      beforeAnswer: () => Bun.sleep(issuerDelay),
      failWith: (index) => (failFirst && index === 0 ? 503 : null),
    };
    scenarios.push({
      name: `random-${seed}-${round}`,
      procs,
      issuer,
      drive: async (world, setHold, labels) => {
        const allSent = barrier(labels.length);
        let replacedOnce = false;
        setHold(async (_label, attempt) => {
          if (attempt !== 0) return;
          await allSent();
          if (outside && !replacedOnce) {
            replacedOnce = true;
            world.replaceOutside();
          }
          await Bun.sleep(delays[next++ % delays.length]!);
        });
        if (!outside) world.revoke(0);
        await runAll(world, labels);
      },
    });
  }
  return scenarios;
}

const runs = new Map<string, { events: SharedLoginEvent[]; procs: string[]; verdict: Verdict }>();

async function drive(scenario: Scenario): Promise<Verdict> {
  const home = mkdtempSync(join(tmpdir(), `fx-tla-auth-${scenario.name}-`));
  let hold: Hold | undefined;
  issuerHold = () => Promise.resolve();
  const before = scenario.issuer?.beforeAnswer;
  const world = startSharedLoginWorld({
    home,
    provider: scenario.provider,
    issuer: {
      ...scenario.issuer,
      beforeAnswer: async (index) => {
        await before?.(index);
        await issuerHold(index);
      },
    },
    hold: (label, attempt) => hold?.(label, attempt),
  });
  const labels = Array.from({ length: scenario.procs }, (_, i) => `p${i + 1}`);
  try {
    await scenario.drive(world, (h) => {
      hold = h;
    }, labels);
  } finally {
    world.stop();
    rmSync(home, { recursive: true, force: true });
  }
  const events = [...world.events];
  const verdict = await checkTrace(events, labels, join(artifacts, scenario.name));
  runs.set(scenario.name, { events, procs: labels, verdict });
  return verdict;
}

for (const scenario of [...named, ...randomRounds()]) {
  test(
    `${scenario.name}: real fx runs are behaviors of SharedLoginRefreshTrace`,
    async () => {
      const verdict = await drive(scenario);
      expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    },
    TIMEOUT,
  );
}

function recorded(name: string) {
  const run = runs.get(name);
  if (!run) throw new Error(`scenario ${name} did not run`);
  return run;
}

test(
  "controls: planted faults in a real log are not accepted",
  async () => {
    const together2 = recorded("together-2");
    const issued = together2.events.findIndex((e) => e.event === "issue");
    expect(issued).toBeGreaterThanOrEqual(0);
    // A second refresh right after the first, while the gateway takes generation 1.
    const redundant = [
      ...together2.events.slice(0, issued + 1),
      { event: "redeem", data: { rt: 1, saved: 1 } } as SharedLoginEvent,
      ...together2.events.slice(issued + 1),
    ];
    const v1 = await checkTrace(redundant, together2.procs, join(artifacts, "control-redundant"));
    expect(v1.verdict).toBe("VIOLATES");
    expect(v1.broken).toContain("NoRedundantRotation");

    // A resend that no 401 called for.
    const replaced = recorded("replaced");
    const resend = [
      { event: "send", data: { p: "p1", tok: 0 } } as SharedLoginEvent,
      { event: "answer", data: { p: "p1", tok: 0, ok: true } } as SharedLoginEvent,
      { event: "send", data: { p: "p1", tok: 0 } } as SharedLoginEvent,
    ];
    const v2 = await checkTrace(resend, replaced.procs, join(artifacts, "control-resend"));
    expect(v2.verdict).toBe("VIOLATES");
    expect(v2.broken).toContain("ReplayAfterReject");

    // A record the wrapper has no step for.
    const impossible = [...replaced.events, { event: "teleport", data: { p: "p1" } } as unknown as SharedLoginEvent];
    const v3 = await checkTrace(impossible, replaced.procs, join(artifacts, "control-impossible"));
    expect(v3.verdict).toBe("REJECTED");
    expect(v3.firstBad?.index).toBe(replaced.events.length);

    const v4 = await checkTrace([], ["p1"], join(artifacts, "control-empty"));
    expect(v4.verdict).toBe("INCONCLUSIVE");

    writeFileSync(join(artifacts, "summary.json"), JSON.stringify(
      Object.fromEntries([...runs].map(([name, run]) => [name, { verdict: run.verdict.verdict, broken: run.verdict.broken, records: run.events.length }])),
      null,
      2,
    ));
  },
  TIMEOUT,
);
