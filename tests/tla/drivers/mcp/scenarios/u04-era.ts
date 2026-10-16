// U04 version detection, step 6: the era core (src/mcp/core/era.zig) driven by
// tests/tla/drivers/mcp/labs/stdio_lab.zig against the scripted fake server. Every scenario
// checks the era, stdio, and request traces against their models, and what
// the server actually received, from its own log.

import type { Rule } from "../fakes/stdio";
import { expectFinal, labScenario, outcomes, type LabCase, type Seen } from "../lab";
import type { Scenario } from "../scenario";

const MODERN = "2026-07-28";
const NEXT = "2027-01-01";
const LEGACY = "2025-11-25";
const VERSION_KEY = "io.modelcontextprotocol/protocolVersion";

const discoverResult = (versions: string[]): Rule => ({
  method: "server/discover",
  result: { resultType: "complete", supportedVersions: versions, capabilities: {}, _meta: { "io.modelcontextprotocol/serverInfo": { name: "fake", version: "1" } } },
});
const unsupported = (supported: string[], extra: Partial<Rule> = {}): Rule => ({
  method: "server/discover",
  error: { code: -32022, message: "Unsupported protocol version", data: { supported, requested: MODERN } },
  ...extra,
});
const initializeResult = (version = LEGACY): Rule => ({
  method: "initialize",
  result: { protocolVersion: version, capabilities: {}, serverInfo: { name: "fake", version: "1" } },
});
// A tools/list that answers only the given era: a version, or null for none sent.
const toolsFor = (version: string | null): Rule => ({ method: "tools/list", version, result: { tools: [] } });

interface Received {
  method?: string;
  version: string | null;
}

// What the server received, in order: each message's method and 2026 _meta version.
function received(log: { dir: string; line: string }[]): Received[] {
  return log
    .filter((l) => l.dir === "in")
    .map((l) => {
      const m = JSON.parse(l.line) as { method?: string; params?: { _meta?: Record<string, string> } };
      return { method: m.method, version: m.params?._meta?.[VERSION_KEY] ?? null };
    });
}

const methods = (log: { dir: string; line: string }[]) => received(log).map((r) => r.method);
const eraLines = (lines: Seen[]) => lines.filter((l) => l.era).map((l) => l.era!);

function sameList(got: unknown[], want: unknown[], what: string): string | null {
  return JSON.stringify(got) === JSON.stringify(want) ? null : `${what} were ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`;
}

// Detection with one preferred version unless the case says otherwise.
function eraScenario(c: Omit<LabCase, "unit" | "requestTrace" | "era"> & { preferred?: string[]; eraVerdict?: "ACCEPTED" | "REJECTED"; modelPreferred?: number }): Scenario {
  const preferred = c.preferred ?? [MODERN];
  return labScenario({
    ...c,
    unit: "U04",
    requestTrace: true,
    era: { preferred: c.modelPreferred ?? preferred.length, verdict: c.eraVerdict },
    labFlags: ["--preferred", preferred.join(","), ...(c.labFlags ?? ["--probe-ms", "3000"])],
  });
}

const STOP = ["stop", "expect stopped 5000"];

export const scenarios: Scenario[] = [
  eraScenario({
    name: "u04-modern",
    description: "A modern server answers server/discover; requests carry the chosen version (VER-02, WIRE-03)",
    rules: [discoverResult([MODERN]), toolsFor(MODERN)],
    script: ["start", "detect", "expect era-modern", "request tools/list", "outcome 2 result", ...STOP],
    check: (lines, final, log) =>
      expectFinal(final, { era: "modern", era_version: MODERN }) ??
      sameList(received(log), [{ method: "server/discover", version: MODERN }, { method: "tools/list", version: MODERN }], "received messages") ??
      sameList(eraLines(lines), [{ ready: MODERN }], "era lines"),
  }),
  eraScenario({
    name: "u04-legacy-method-not-found",
    description: "A legacy server rejects server/discover; initialize, then initialized, then requests without 2026 _meta (VER-03, VER-06, VER-07)",
    rules: [initializeResult(), toolsFor(null)],
    script: ["start", "detect", "expect era-legacy", "request tools/list", "outcome 3 result", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "legacy", era_version: LEGACY }) ??
      sameList(methods(log), ["server/discover", "initialize", "notifications/initialized", "tools/list"], "received methods") ??
      (received(log)[3].version === null ? null : "tools/list carried a 2026 version on a legacy server"),
  }),
  eraScenario({
    name: "u04-legacy-silent",
    description: "A legacy server that ignores server/discover is found by the probe timeout; the probe is never cancelled",
    rules: [{ method: "server/discover", noReply: true }, initializeResult()],
    labFlags: ["--probe-ms", "300"],
    script: ["start", "detect", "expect era-legacy", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "legacy" }) ?? sameList(methods(log), ["server/discover", "initialize", "notifications/initialized"], "received methods"),
  }),
  eraScenario({
    name: "u04-invalid-resulttype",
    description: "A discover result whose resultType is unknown is invalid, so it isn't a modern answer: a server that also speaks 2025 is used at 2025 (WIRE-07)",
    rules: [{ ...discoverResult([MODERN]), result: { ...discoverResult([MODERN]).result, resultType: "bogus" } }, initializeResult(), toolsFor(null)],
    script: ["start", "detect", "expect era-legacy", "request tools/list", "outcome 3 result", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "legacy", era_version: LEGACY }) ??
      sameList(methods(log), ["server/discover", "initialize", "notifications/initialized", "tools/list"], "received methods"),
  }),
  eraScenario({
    name: "u04-legacy-error-without-id",
    description: "An error without an id during the probe means a legacy server",
    rules: [{ method: "server/discover", raw: '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}' }, initializeResult()],
    script: ["start", "detect", "expect era-legacy", ...STOP],
    check: (_, final) => expectFinal(final, { era: "legacy" }),
  }),
  eraScenario({
    name: "u04-unsupported-retry",
    description: "-32022 to the probe retries with the first listed version the client supports (VER-01)",
    preferred: [NEXT, MODERN],
    rules: [unsupported([MODERN], { version: NEXT } as Partial<Rule>), { ...discoverResult([MODERN]), version: MODERN }, toolsFor(MODERN)],
    script: ["start", "detect", "expect era-modern", "request tools/list", "outcome 3 result", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "modern", era_version: MODERN }) ??
      sameList(
        received(log),
        [{ method: "server/discover", version: NEXT }, { method: "server/discover", version: MODERN }, { method: "tools/list", version: MODERN }],
        "received messages",
      ),
  }),
  eraScenario({
    name: "u04-dual-lists-legacy",
    description: "-32022 listing only the legacy version falls back to initialize",
    rules: [unsupported([LEGACY]), initializeResult()],
    script: ["start", "detect", "expect era-legacy", ...STOP],
    check: (_, final, log) => expectFinal(final, { era: "legacy" }) ?? sameList(methods(log), ["server/discover", "initialize", "notifications/initialized"], "received methods"),
  }),
  eraScenario({
    name: "u04-modern-rejection",
    description: "-32021 to the probe fails without falling back",
    rules: [{ method: "server/discover", error: { code: -32021, message: "Missing required client capability", data: { requiredCapabilities: { sampling: {} } } } }],
    script: ["start", "detect", "expect era-failed", ...STOP],
    check: (lines, final, log) =>
      expectFinal(final, { era: "failed", era_failure: "rejected" }) ??
      sameList(methods(log), ["server/discover"], "received methods") ??
      sameList(eraLines(lines), [{ failed: "rejected" }], "era lines"),
  }),
  eraScenario({
    name: "u04-no-shared-version",
    description: "A DiscoverResult with no shared version and no legacy version fails without initialize (VER-01)",
    rules: [discoverResult(["2099-01-01"])],
    script: ["start", "detect", "expect era-failed", ...STOP],
    check: (_, final, log) => expectFinal(final, { era: "failed", era_failure: "no_shared_version" }) ?? sameList(methods(log), ["server/discover"], "received methods"),
  }),
  eraScenario({
    name: "u04-unsupported-initialize-version",
    description: "initialize answered with a version other than the legacy one fails; initialized is never sent (VER-09)",
    rules: [initializeResult("2024-11-05")],
    script: ["start", "detect", "expect era-failed", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "failed", era_failure: "unsupported_version" }) ?? sameList(methods(log), ["server/discover", "initialize"], "received methods"),
  }),
  eraScenario({
    name: "u04-initialize-timeout",
    description: "A server that answers neither the probe nor initialize fails when initialize times out",
    rules: [{ method: "server/discover", noReply: true }, { method: "initialize", noReply: true }],
    labFlags: ["--probe-ms", "200", "--idle-ms", "500"],
    script: ["start", "detect", "expect era-failed", ...STOP],
    check: (lines, final) =>
      expectFinal(final, { era: "failed", era_failure: "initialize_failed" }) ?? (outcomes(lines)[2] === "timed_out" ? null : "initialize should time out"),
  }),
  eraScenario({
    name: "u04-modern-went-quiet",
    description: "A modern server that rejects a version it lists, then stops answering, fails without initialize (VER-03)",
    rules: [unsupported([MODERN], { times: 1 }), { method: "server/discover", noReply: true }],
    labFlags: ["--probe-ms", "300"],
    script: ["start", "detect", "expect era-failed", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "failed", era_failure: "went_quiet" }) ?? sameList(methods(log), ["server/discover", "server/discover"], "received methods"),
  }),
  eraScenario({
    name: "u04-fall-forward",
    description: "A modern server too slow for the probe rejects initialize with -32022; the client probes once more",
    rules: [discoverResult([MODERN]), { method: "initialize", error: { code: -32022, message: `Unsupported protocol version; supported: ${MODERN}`, data: { supported: [MODERN] } } }],
    fakeFlags: ["--start-delay", "800"],
    labFlags: ["--probe-ms", "200"],
    script: ["start", "detect", "expect era-modern 5000", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "modern", era_version: MODERN }) ?? sameList(methods(log), ["server/discover", "initialize", "server/discover"], "received methods"),
  }),
  eraScenario({
    name: "u04-redetect-after-restart",
    description: "A new process detects again before any request",
    rules: [discoverResult([MODERN]), { method: "tools/list", times: 1, result: { tools: [] }, then: "crash" }, toolsFor(MODERN)],
    labFlags: ["--probe-ms", "3000", "--backoff-ms", "20"],
    script: ["start", "detect", "expect era-modern", "request tools/list", "outcome 2 result", "expect idle", "start", "expect era-modern", "request tools/list", "outcome 4 result", ...STOP],
    check: (_, final, log) =>
      expectFinal(final, { era: "modern", generation: 2 }) ?? sameList(methods(log), ["server/discover", "tools/list", "server/discover", "tools/list"], "received methods"),
  }),
  eraScenario({
    name: "u04-requests-wait",
    description: "A request before detection finishes is refused, and nothing reaches the server (VER-08)",
    rules: [{ ...discoverResult([MODERN]), delayMs: 300 }, toolsFor(MODERN)],
    script: ["start", "detect", "request tools/list", "expect era-modern", "request tools/list", "outcome 2 result", ...STOP],
    check: (lines, final, log) => {
      if (!lines.some((l) => l.did?.era_error === "NotReady")) return "the early request should be refused";
      return expectFinal(final, { era: "modern" }) ?? sameList(methods(log), ["server/discover", "tools/list"], "received methods");
    },
  }),
  eraScenario({
    name: "u04-operation-version-rejected",
    description: "-32022 to a request after detection switches to another listed version, never to legacy (VER-01, VER-05)",
    preferred: [NEXT, MODERN],
    rules: [
      discoverResult([NEXT, MODERN]),
      { method: "tools/list", version: NEXT, error: { code: -32022, message: "Unsupported protocol version", data: { supported: [MODERN, LEGACY] } } },
      toolsFor(MODERN),
    ],
    script: ["start", "detect", "expect era-modern", "request tools/list", "outcome 2 peer_error", "request tools/list", "outcome 3 result", ...STOP],
    check: (lines, final, log) =>
      expectFinal(final, { era: "modern", era_version: MODERN }) ??
      sameList(eraLines(lines), [{ ready: NEXT }, { ready: MODERN }], "era lines") ??
      sameList(
        received(log).map((r) => r.version),
        [NEXT, NEXT, MODERN],
        "versions received",
      ),
  }),
  eraScenario({
    name: "u04-planted-count-mismatch",
    description: "Known-bad control: the lab has two preferred versions but the model is told one, so the retry with the second can't be matched",
    preferred: [NEXT, MODERN],
    modelPreferred: 1,
    eraVerdict: "REJECTED",
    rules: [unsupported([MODERN], { version: NEXT } as Partial<Rule>), { ...discoverResult([MODERN]), version: MODERN }],
    script: ["start", "detect", "expect era-modern", ...STOP],
  }),
];
