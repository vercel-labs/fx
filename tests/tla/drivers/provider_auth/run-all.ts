// Exhaustive TLC checks of ProviderAuth, grouped by the pull request that
// added each provider's credential edge.
//
//   bun tests/tla/drivers/provider_auth/run-all.ts <report-dir> [1210|1211|1212]...
//
// Each check fixes the model's constants and names the verdict every property
// must reach. Designs the code implements must HOLD; planted bugs must be
// VIOLATED, which shows each property can fail. A check whose verdicts differ
// from the expectation fails the run.
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { checkModel, hashes, PROPERTIES, type Property, type Setup, type Verdict } from "./tlc";

const base: Omit<Setup, "provider" | "requests"> = {
  expiring: false, rejecting: false, foreignRefresh: false, checkAccount: true, scopeAll: false, noSingleFlight: false,
};
const oneEngine = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e1", url: "provider" as const }];
const twoEngines = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e2", url: "provider" as const }];
const withOther = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e1", url: "other" as const }];
const corners = [[false, false], [false, true], [true, false], [true, true]] as const;

interface Check { pr: string; name: string; setup: Setup; expect: Partial<Record<Property, Verdict>>; why: string }
const holdsAll = Object.fromEntries(PROPERTIES.map((p) => [p, "HOLDS"])) as Record<Property, Verdict>;

function refreshableChecks(pr: string, provider: "codex" | "grok"): Check[] {
  const checks: Check[] = corners.map(([expiring, rejecting]) => {
    // Both requests carry the rejected token; the later 401 refreshes the
    // credential it used, whose refresh token the first refresh already spent.
    const lateRetry = rejecting && !expiring;
    return {
      pr, name: `${provider}-one-engine-${expiring ? "expiring" : "fresh"}-${rejecting ? "rejecting" : "accepting"}`,
      setup: { ...base, provider, requests: oneEngine, expiring, rejecting },
      expect: lateRetry ? { ...holdsAll, NoRefreshReuse: "VIOLATED" } : holdsAll,
      why: lateRetry
        ? "finding: a 401 that arrives after another request's refresh redeems the spent refresh token again"
        : "the design: two requests on one engine share one refresh",
    };
  });
  checks.push({
    pr, name: `${provider}-two-engines-expiring`,
    setup: { ...base, provider, requests: twoEngines, expiring: true },
    expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
    why: "libfx opens one engine per session, each with its own authorizer: two sessions near expiry each redeem the same refresh token",
  });
  checks.push({
    pr, name: `${provider}-planted-no-single-flight`,
    setup: { ...base, provider, requests: oneEngine, expiring: true, noSingleFlight: true },
    expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
    why: "planted bug: without the shared task, NoRefreshReuse must fail",
  });
  if (provider === "grok") {
    checks.push({
      pr, name: "grok-refresh-for-another-account",
      setup: { ...base, provider, requests: oneEngine, expiring: true, foreignRefresh: true },
      expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
      why: "another account's token is refused and never used or saved; the host's refresh token is spent by then, so the next request redeems it again and the user must sign in again",
    });
    checks.push({
      pr, name: "grok-planted-no-account-check",
      setup: { ...base, provider, requests: oneEngine, expiring: true, foreignRefresh: true, checkAccount: false },
      expect: { ...holdsAll, NoForeignToken: "VIOLATED" },
      why: "planted bug: without the account check, another account's token is used and saved",
    });
  }
  return checks;
}

// The follow-up fix: one agent's engines share a memory, and a 401 retries on
// newer credentials before it refreshes.
function fixedChecks(provider: "codex" | "grok"): Check[] {
  const fixed = { ...base, provider, sharedMemory: true, recheck: true };
  const checks: Check[] = [];
  for (const [topology, requests] of [["one-engine", oneEngine], ["two-engines", twoEngines]] as const) {
    for (const [expiring, rejecting] of corners) {
      checks.push({
        pr: "fixed", name: `${provider}-fixed-${topology}-${expiring ? "expiring" : "fresh"}-${rejecting ? "rejecting" : "accepting"}`,
        setup: { ...fixed, requests, expiring, rejecting },
        expect: holdsAll,
        why: "the fix: no refresh token is redeemed twice by one agent, in any order",
      });
    }
  }
  checks.push({
    pr: "fixed", name: `${provider}-recheck-only-late-401`,
    setup: { ...base, provider, requests: oneEngine, rejecting: true, recheck: true },
    expect: holdsAll,
    why: "the 401 fix alone closes the late rejection on one engine",
  });
  checks.push({
    pr: "fixed", name: `${provider}-recheck-only-two-engines-rejecting`,
    setup: { ...base, provider, requests: twoEngines, rejecting: true, recheck: true },
    expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
    why: "without a shared memory, two sessions rejected before either saves both refresh; the shared memory closes this",
  });
  checks.push({
    pr: "fixed", name: `${provider}-separate-agents-expiring`,
    setup: { ...base, provider, requests: twoEngines, expiring: true, recheck: true },
    expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
    why: "remaining limit: two processes that both start before either saves still redeem the same refresh token",
  });
  for (const [expiring, rejecting] of corners) {
    checks.push({
      pr: "fixed", name: `${provider}-lock-separate-agents-${expiring ? "expiring" : "fresh"}-${rejecting ? "rejecting" : "accepting"}`,
      setup: { ...base, provider, requests: twoEngines, expiring, rejecting, recheck: true, lock: true },
      expect: holdsAll,
      why: "refreshLock: separate servers that share a lock never redeem one refresh token twice",
    });
  }
  checks.push({
    pr: "fixed", name: `${provider}-fixed-planted-no-single-flight`,
    setup: { ...fixed, requests: oneEngine, expiring: true, noSingleFlight: true },
    expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
    why: "planted bug: the checks still catch a missing shared task",
  });
  if (provider === "grok") {
    checks.push({
      pr: "fixed", name: "grok-fixed-refresh-for-another-account",
      setup: { ...fixed, requests: oneEngine, expiring: true, foreignRefresh: true },
      expect: { ...holdsAll, NoRefreshReuse: "VIOLATED" },
      why: "unchanged by the fix: after a refused cross-account refresh the user must sign in again",
    });
  }
  return checks;
}

const byPr: Record<string, () => Check[]> = {
  "fixed": () => [...fixedChecks("codex"), ...fixedChecks("grok")],
  "1210": () => refreshableChecks("1210", "codex"),
  "1211": () => [...refreshableChecks("1211", "codex"), ...refreshableChecks("1211", "grok")],
  "1212": () => [
    ...[false, true].map((rejecting): Check => ({
      pr: "1212", name: `custom-key-and-other-url-${rejecting ? "rejecting" : "accepting"}`,
      setup: { ...base, provider: "custom", requests: withOther, rejecting },
      expect: holdsAll,
      why: "the design: the key goes to the chat URL only and is never refreshed",
    })),
    {
      pr: "1212", name: "custom-two-engines",
      setup: { ...base, provider: "custom", requests: twoEngines, rejecting: true },
      expect: holdsAll,
      why: "a key has no refresh token, so sessions cannot collide over one",
    },
    {
      pr: "1212", name: "custom-planted-scope-all",
      setup: { ...base, provider: "custom", requests: withOther, scopeAll: true },
      expect: { ...holdsAll, ScopedAuth: "VIOLATED" },
      why: "planted bug: a spec that authorizes every URL must break ScopedAuth",
    },
  ],
};

const [reportArg, ...prArgs] = process.argv.slice(2);
if (!reportArg) throw new Error("usage: run-all.ts <report-dir> [1210|1211|1212]...");
const report = resolve(reportArg);
mkdirSync(report, { recursive: true, mode: 0o700 });
const prs = prArgs.length ? prArgs : Object.keys(byPr);

const results = [];
let failures = 0;
for (const pr of prs) {
  for (const check of byPr[pr]!()) {
    const verdicts: Record<string, { verdict: Verdict; states?: string; log: string }> = {};
    for (const property of PROPERTIES) {
      const { verdict, run, states } = await checkModel(report, `${pr}-${check.name}`, check.setup, property);
      verdicts[property] = { verdict, states, log: join(run.dir, "tlc.log") };
    }
    const wrong = PROPERTIES.filter((p) => verdicts[p]!.verdict !== (check.expect[p] ?? "HOLDS"));
    if (wrong.length) failures += 1;
    results.push({ ...check, verdicts, ok: wrong.length === 0, wrong });
    const summary = PROPERTIES.map((p) => `${p}=${verdicts[p]!.verdict}`).join(" ");
    console.log(`${wrong.length ? "FAIL" : "ok  "} #${pr} ${check.name} (${verdicts.TypeOK!.states ?? "?"} states): ${summary}`);
  }
}
writeFileSync(join(report, "model-results.json"), JSON.stringify({ hashes: hashes(), results }, null, 2), { mode: 0o600 });
console.log(failures ? `${failures} check(s) did not reach their expected verdicts` : "every check reached its expected verdicts");
process.exit(failures ? 1 : 0);
