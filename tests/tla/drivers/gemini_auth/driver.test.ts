// GeminiDpopRefresh: real fx processes (`fx ask --provider google` and
// `fx logout google` from zig-out/bin/fx, or FX_BIN) share one saved Google
// AI Pro or Ultra plan login (`google-auth.json` under `google-auth.lock`) against a
// fake Google OAuth + Gemini server. Each scenario's ordered log of token
// requests (with DPoP nonce), issuer answers, disk saves/clears, sign-outs, and
// kills is checked by TLC through tests/tla/gemini_auth/GeminiDpopRefreshTrace.tla,
// Design A of tests/tla/gemini_auth/GeminiDpopRefresh.tla. Every real run must
// be ACCEPTED.
import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import {
  barrier,
  cleanupHome,
  deferred,
  googleAuthPath,
  readGoogleAuthDisk,
  spawnGoogleAsk,
  spawnGoogleLogout,
  startFakeGoogleWorld,
  waitUntil,
  type FakeGoogleWorld,
  type SeedLoginOptions,
  type SpawnedFx,
  type WorldOptions,
} from "./fake-google";
import { checkTrace, type GeminiAuthEvent, type TraceConfig, type Verdict } from "./trace";

const TIMEOUT = 60_000;

function waitForProcessBlockedOrDone(
  pid: number,
  earlyStop: () => boolean,
  timeoutMs = 15_000,
): Promise<void> {
  // On Linux, leased_lock.acquire polls in 10 ms io_mod.sleep() intervals
  // (hrtimer_nanosleep / do_nanosleep / clock_nanosleep in /proc/<pid>/wchan).
  const deadline = Date.now() + timeoutMs;
  return (async () => {
    while (Date.now() < deadline) {
      if (earlyStop()) return;
      if (process.platform === "linux") {
        try {
          const wchan = readFileSync(`/proc/${pid}/wchan`, "utf8").trim();
          if (/nanosleep|futex|flock/.test(wchan)) return;
        } catch {
          return;
        }
      }
      await Bun.sleep(10);
    }
  })();
}

type RunResult = {
  events: GeminiAuthEvent[];
  verdict: Verdict;
  world: FakeGoogleWorld;
  authExistsAtEnd: boolean;
  diskAtEnd: ReturnType<typeof readGoogleAuthDisk>;
};

const runs = new Map<string, { events: GeminiAuthEvent[]; config: TraceConfig; verdict: Verdict }>();

async function withWorld(
  name: string,
  opts: Omit<WorldOptions, "home">,
  traceConfig: Omit<TraceConfig, "initAccess" | "initRefresh" | "initNonce" | "serverNonce">,
  fn: (world: FakeGoogleWorld) => Promise<void>,
): Promise<RunResult> {
  const home = mkdtempSync(join(tmpdir(), `fx-tla-gemini-auth-${name}-`));
  const world = startFakeGoogleWorld({ home, ...opts });
  let authExistsAtEnd = false;
  let diskAtEnd: ReturnType<typeof readGoogleAuthDisk> = null;
  try {
    await fn(world);
    authExistsAtEnd = existsSync(googleAuthPath(home));
    diskAtEnd = readGoogleAuthDisk(home);
  } finally {
    world.stop();
  }
  const seed: SeedLoginOptions = opts.seed ?? {};
  const initAccess = seed.accessGen ?? 0;
  const initRefresh = seed.refreshGen ?? 0;
  const initNonce = seed.nonce === undefined ? 0 : (seed.nonce ?? -1);
  const fullConfig: TraceConfig = {
    ...traceConfig,
    rotatesRefresh: opts.rotatesRefresh ?? true,
    initAccess,
    initRefresh,
    initNonce,
    serverNonce: opts.initialServerNonce ?? initNonce,
  };
  const events = [...world.events];
  try {
    const verdict = await checkTrace(events, fullConfig, join(artifacts, name));
    runs.set(name, { events, config: fullConfig, verdict });
    return { events, verdict, world, authExistsAtEnd, diskAtEnd };
  } finally {
    cleanupHome(home);
  }
}

test(
  "expired-concurrent-2: two fx processes refreshing the same expired login share one refresh and the other adopts",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    const firstHold = deferred<void>();
    let p2Spawned: SpawnedFx | null = null;
    let p1Ref: SpawnedFx | null = null;
    let activeWorld: FakeGoogleWorld | null = null;
    let r1!: Awaited<SpawnedFx["done"]>;
    let r2!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, diskAtEnd } = await withWorld(
      "expired-concurrent-2",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: async (ctx) => {
          if (ctx.index === 0) {
            await waitUntil("p2 spawned", () => p2Spawned !== null);
            await waitForProcessBlockedOrDone(
              p2Spawned!.pid,
              () => (activeWorld?.tokenRequests.length ?? 0) > 1,
            );
            await firstHold.promise;
          }
          return { kind: "auto" };
        },
      },
      { procs: ["p1", "p2"] },
      async (w) => {
        activeWorld = w;
        p1Ref = spawnGoogleAsk(w, "p1", binary);
        await waitUntil("p1 token request", () => w.tokenRequests.length >= 1);
        p2Spawned = spawnGoogleAsk(w, "p2", binary);
        firstHold.resolve();
        [r1, r2] = await Promise.all([p1Ref.done, p2Spawned.done]);
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code, `p1 stderr: ${r1.stderr}\np1 stdout: ${r1.stdout}`).toBe(0);
    expect(r2.code, `p2 stderr: ${r2.stderr}\np2 stdout: ${r2.stdout}`).toBe(0);
    expect(r1.stdout).toContain("GEMINI_AUTH_DONE_p1");
    expect(r2.stdout).toContain("GEMINI_AUTH_DONE_p2");
    expect(world.tokenRequests).toHaveLength(1);
    expect(diskAtEnd).toEqual({ access: 1, rt: 1, nonce: 1 });
  },
  TIMEOUT,
);

test(
  "401-concurrent-2: two fx processes hitting 401 together refresh once and both replay with the saved token",
  async () => {
    const bothSent = barrier(2);
    let r1!: Awaited<SpawnedFx["done"]>;
    let r2!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, diskAtEnd } = await withWorld(
      "401-concurrent-2",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0 },
        rotatesRefresh: true,
        holdApi: async (_label, attempt) => {
          if (attempt === 0) await bothSent();
        },
      },
      { procs: ["p1", "p2"] },
      async (w) => {
        w.revokeAccess(0);
        const p1 = spawnGoogleAsk(w, "p1", binary);
        const p2 = spawnGoogleAsk(w, "p2", binary);
        [r1, r2] = await Promise.all([p1.done, p2.done]);
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code, `p1 stderr: ${r1.stderr}\np1 stdout: ${r1.stdout}`).toBe(0);
    expect(r2.code, `p2 stderr: ${r2.stderr}\np2 stdout: ${r2.stdout}`).toBe(0);
    expect(r1.stdout).toContain("GEMINI_AUTH_DONE_p1");
    expect(r2.stdout).toContain("GEMINI_AUTH_DONE_p2");
    expect(world.tokenRequests).toHaveLength(1);
    expect(diskAtEnd).toEqual({ access: 1, rt: 1, nonce: 1 });
  },
  TIMEOUT,
);

test(
  "401-no-rotate-concurrent-2: non-rotating refresh token is kept while access token and nonce update",
  async () => {
    const bothSent = barrier(2);
    let r1!: Awaited<SpawnedFx["done"]>;
    let r2!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, diskAtEnd } = await withWorld(
      "401-no-rotate-concurrent-2",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0 },
        rotatesRefresh: false,
        holdApi: async (_label, attempt) => {
          if (attempt === 0) await bothSent();
        },
      },
      { procs: ["p1", "p2"] },
      async (w) => {
        w.revokeAccess(0);
        const p1 = spawnGoogleAsk(w, "p1", binary);
        const p2 = spawnGoogleAsk(w, "p2", binary);
        [r1, r2] = await Promise.all([p1.done, p2.done]);
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code, `p1 stderr: ${r1.stderr}\np1 stdout: ${r1.stdout}`).toBe(0);
    expect(r2.code, `p2 stderr: ${r2.stderr}\np2 stdout: ${r2.stdout}`).toBe(0);
    expect(world.tokenRequests).toHaveLength(1);
    expect(diskAtEnd).toEqual({ access: 1, rt: 0, nonce: 1 });
  },
  TIMEOUT,
);

test(
  "use-dpop-nonce-once: first use_dpop_nonce retries once with new nonce and saves the newest nonce from 200",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    let r1!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, diskAtEnd } = await withWorld(
      "use-dpop-nonce-once",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        initialServerNonce: 1,
        rotateNonceOn200: true,
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        r1 = await p1.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code, `stderr: ${r1.stderr}\nstdout: ${r1.stdout}`).toBe(0);
    expect(r1.stdout).toContain("GEMINI_AUTH_DONE_p1");
    expect(world.tokenRequests).toHaveLength(2);
    expect(world.tokenRequests[0]!.nonce).toBe(0);
    expect(world.tokenRequests[1]!.nonce).toBe(1);
    expect(diskAtEnd).toEqual({ access: 1, rt: 1, nonce: 2 });
  },
  TIMEOUT,
);

test(
  "use-dpop-nonce-twice-capped: second use_dpop_nonce in the same refresh stops with no third request and keeps login",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    let nextNonce = 1;
    let r1!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, authExistsAtEnd, diskAtEnd } = await withWorld(
      "use-dpop-nonce-twice-capped",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: () => ({ kind: "use_dpop_nonce", nonce: nextNonce++ }),
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        r1 = await p1.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code).not.toBe(0);
    expect(world.tokenRequests).toHaveLength(2);
    expect(world.tokenRequests.map((r) => r.nonce)).toEqual([0, 1]);
    expect(authExistsAtEnd).toBe(true);
    expect(diskAtEnd).toEqual({ access: 0, rt: 0, nonce: 0 });
  },
  TIMEOUT,
);

test(
  "issuer-503-keeps-login: 503 from /token fails the ask without clearing the saved login",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    let r1!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, authExistsAtEnd, diskAtEnd } = await withWorld(
      "issuer-503-keeps-login",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: () => ({ kind: "fail", status: 503 }),
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        r1 = await p1.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code).not.toBe(0);
    expect(world.tokenRequests).toHaveLength(1);
    expect(authExistsAtEnd).toBe(true);
    expect(diskAtEnd).toEqual({ access: 0, rt: 0, nonce: 0 });
  },
  TIMEOUT,
);

test(
  "issuer-stall-keeps-login: stalled /token request times out cleanly and keeps the saved login",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    let r1!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, authExistsAtEnd, diskAtEnd } = await withWorld(
      "issuer-stall-keeps-login",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: () => ({ kind: "stall" }),
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        r1 = await p1.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code).not.toBe(0);
    expect(world.tokenRequests).toHaveLength(1);
    expect(authExistsAtEnd).toBe(true);
    expect(diskAtEnd).toEqual({ access: 0, rt: 0, nonce: 0 });
  },
  TIMEOUT,
);

test(
  "invalid-grant-clears-login: invalid_grant from /token clears google-auth.json",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    let r1!: Awaited<SpawnedFx["done"]>;

    const { verdict, world, authExistsAtEnd } = await withWorld(
      "invalid-grant-clears-login",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: () => ({ kind: "invalid_grant" }),
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        r1 = await p1.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.code).not.toBe(0);
    expect(world.tokenRequests).toHaveLength(1);
    expect(authExistsAtEnd).toBe(false);
  },
  TIMEOUT,
);

test(
  "signout-during-refresh: fx logout google during another process's refresh keeps the login deleted",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    const tokenHold = deferred<void>();
    let logoutProc: SpawnedFx | null = null;
    let r1!: Awaited<SpawnedFx["done"]>;
    let rLogout!: Awaited<SpawnedFx["done"]>;

    const { verdict, authExistsAtEnd } = await withWorld(
      "signout-during-refresh",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: async (ctx) => {
          if (ctx.index === 0) {
            await tokenHold.promise;
          }
          return { kind: "auto" };
        },
      },
      { procs: ["p1"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        await waitUntil("p1 token request", () => w.tokenRequests.length >= 1);
        logoutProc = spawnGoogleLogout(w, binary);
        await waitForProcessBlockedOrDone(
          logoutProc.pid,
          () => !existsSync(googleAuthPath(w.home)),
        );
        tokenHold.resolve();
        [r1, rLogout] = await Promise.all([p1.done, logoutProc.done]);
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(rLogout.code, `logout stderr: ${rLogout.stderr}\nlogout stdout: ${rLogout.stdout}`).toBe(0);
    expect(rLogout.stdout).toContain("Signed out of Google AI Pro or Ultra plan on this device.");
    expect(authExistsAtEnd).toBe(false);
    expect([0, 1]).toContain(r1.code ?? 1);
  },
  TIMEOUT,
);

test(
  "killed-between-200-and-save: process killed by PID at issuer 200 signal leaves spent refresh unpersisted; peer sees invalid_grant and clears",
  async () => {
    const nowS = Math.floor(Date.now() / 1000);
    const got200Signal = deferred<() => void>();
    let r1!: Awaited<SpawnedFx["done"]>;
    let r2!: Awaited<SpawnedFx["done"]>;
    let diskAfterKill: ReturnType<typeof readGoogleAuthDisk> = null;

    const { verdict, world, authExistsAtEnd } = await withWorld(
      "killed-between-200-and-save",
      {
        seed: { accessGen: 0, refreshGen: 0, nonce: 0, accessExpiresAtS: nowS - 60 },
        rotatesRefresh: true,
        onTokenRequest: (ctx) => {
          if (ctx.index === 0) {
            return {
              kind: "ok_hold_after_200",
              on200Started: (closeStream) => got200Signal.resolve(closeStream),
            };
          }
          return { kind: "auto" };
        },
      },
      { procs: ["p1", "p2"] },
      async (w) => {
        const p1 = spawnGoogleAsk(w, "p1", binary);
        const closeStream = await got200Signal.promise;
        // Kill p1 by PID right at the fake's 200 signal, before p1 can save google-auth.json.
        process.kill(p1.pid, "SIGKILL");
        w.noteKill("p1");
        r1 = await p1.done;
        closeStream();
        diskAfterKill = readGoogleAuthDisk(w.home);

        // p2 runs next under the dropped lock, reads unpersisted rt=0, gets invalid_grant, and clears.
        const p2 = spawnGoogleAsk(w, "p2", binary);
        r2 = await p2.done;
      },
    );

    expect(verdict.verdict, JSON.stringify(verdict, null, 2)).toBe("ACCEPTED");
    expect(r1.signal).toBe("SIGKILL");
    expect(diskAfterKill).toEqual({ access: 0, rt: 0, nonce: 0 });
    expect(r2.code).not.toBe(0);
    expect(world.tokenRequests).toHaveLength(2);
    expect(world.tokenRequests.map((r) => [r.label, r.rt])).toEqual([
      ["p1", 0],
      ["p2", 0],
    ]);
    expect(authExistsAtEnd).toBe(false);
    expect(world.events.some((e) => e.event === "kill" && e.data.p === "p1")).toBe(true);
    expect(world.events.some((e) => e.event === "clear")).toBe(true);
  },
  TIMEOUT,
);

test(
  "controls: planted faults in a trace are rejected or flagged by their named invariant",
  async () => {
    const baseCfg: TraceConfig = {
      procs: ["p1", "p2"],
      rotatesRefresh: true,
      initAccess: 0,
      initRefresh: 0,
      initNonce: 0,
      serverNonce: 0,
    };

    // 1. NonceRetryAtMostOnce: 3rd /token request in the same refresh attempt.
    const thirdNonceRetry: GeminiAuthEvent[] = [
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 0 } },
      { event: "token_nonce", data: { p: "p1", nonce: 1 } },
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 1 } },
      { event: "token_nonce", data: { p: "p1", nonce: 2 } },
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 2 } },
    ];
    const v1 = await checkTrace(thirdNonceRetry, baseCfg, join(artifacts, "control-nonce-retry"));
    expect(v1.verdict).toBe("VIOLATES");
    expect(v1.broken).toContain("NonceRetryAtMostOnce");

    // 2. NoSpentRefresh: p2 sends rt=0 after p1 redeemed it without dying mid-rotation.
    const spentRefresh: GeminiAuthEvent[] = [
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 0 } },
      { event: "token_ok", data: { p: "p1", access: 1, rt: 1, nonce: 1 } },
      { event: "save", data: { access: 1, rt: 1, nonce: 1 } },
      { event: "token_req", data: { p: "p2", rt: 0, nonce: 1 } },
    ];
    const v2 = await checkTrace(spentRefresh, baseCfg, join(artifacts, "control-spent-refresh"));
    expect(v2.verdict).toBe("VIOLATES");
    expect(v2.broken).toContain("NoSpentRefresh");

    // 3. NoLostUpdate + NoStaleOverwrite: a save regresses rt, access, and nonce.
    const staleSave: GeminiAuthEvent[] = [
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 0 } },
      { event: "token_ok", data: { p: "p1", access: 2, rt: 2, nonce: 2 } },
      { event: "save", data: { access: 2, rt: 2, nonce: 2 } },
      { event: "token_req", data: { p: "p2", rt: 2, nonce: 2 } },
      { event: "token_ok", data: { p: "p2", access: 1, rt: 1, nonce: 1 } },
      { event: "save", data: { access: 1, rt: 1, nonce: 1 } },
    ];
    const v3 = await checkTrace(staleSave, baseCfg, join(artifacts, "control-stale-save"));
    expect(v3.verdict).toBe("VIOLATES");
    expect(v3.broken).toContain("NoLostUpdate");
    expect(v3.broken).toContain("NoStaleOverwrite");

    // 4. ClearOnlyWithCause: clear after 503 (no invalid_grant, no sign_out).
    const clearOn503: GeminiAuthEvent[] = [
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 0 } },
      { event: "token_fail", data: { p: "p1", status: 503 } },
      { event: "clear", data: { none: 0 } },
    ];
    const v4 = await checkTrace(clearOn503, baseCfg, join(artifacts, "control-clear-on-503"));
    expect(v4.verdict).toBe("VIOLATES");
    expect(v4.broken).toContain("ClearOnlyWithCause");

    // 5. SignOutSticks: save after sign_out restores the login.
    const saveAfterSignOut: GeminiAuthEvent[] = [
      { event: "token_req", data: { p: "p1", rt: 0, nonce: 0 } },
      { event: "sign_out", data: { none: 0 } },
      { event: "token_ok", data: { p: "p1", access: 1, rt: 1, nonce: 1 } },
      { event: "save", data: { access: 1, rt: 1, nonce: 1 } },
    ];
    const v5 = await checkTrace(saveAfterSignOut, baseCfg, join(artifacts, "control-signout-sticks"));
    expect(v5.verdict).toBe("VIOLATES");
    expect(v5.broken).toContain("SignOutSticks");

    // 6. REJECTED: API replay without prior 401.
    const unrejectedReplay: GeminiAuthEvent[] = [
      { event: "api_send", data: { p: "p1", access: 0 } },
      { event: "api_answer", data: { p: "p1", access: 0, ok: true } },
      { event: "api_send", data: { p: "p1", access: 0 } },
    ];
    const v6 = await checkTrace(unrejectedReplay, baseCfg, join(artifacts, "control-rejected"));
    expect(v6.verdict).toBe("REJECTED");
    expect(v6.firstBad?.index).toBe(2);

    // 7. INCONCLUSIVE: empty trace.
    const v7 = await checkTrace([], baseCfg, join(artifacts, "control-empty"));
    expect(v7.verdict).toBe("INCONCLUSIVE");

    writeFileSync(
      join(artifacts, "summary.json"),
      JSON.stringify(
        Object.fromEntries(
          [...runs].map(([name, run]) => [
            name,
            { verdict: run.verdict.verdict, broken: run.verdict.broken, records: run.events.length },
          ]),
        ),
        null,
        2,
      ),
    );
  },
  TIMEOUT,
);
