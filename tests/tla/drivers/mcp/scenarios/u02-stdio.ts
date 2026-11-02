// U02 request lifecycle over a real transport: requests are encoded by U01,
// tracked by the U02 request table, and carried by the U03 stdio connection
// to the scripted fake server. Each run must produce request traces that TLC
// accepts as behaviors of spec/Request.tla, and stdio traces it accepts as
// behaviors of spec/StdioConn.tla.

import { expectFinal, labScenario, type LabCase, outcomes } from "../lab";
import type { Scenario } from "../scenario";

const overStdio = (c: Omit<LabCase, "unit" | "requestTrace">): Scenario => labScenario({ ...c, unit: "U02", requestTrace: true });
const received = (log: { dir: string; line: string }[], method: string) => log.filter((l) => l.dir === "in" && l.line.includes(`"method":"${method}"`));
const want = (got: Record<string, string>, expected: Record<string, string>): string | null => {
  for (const [id, outcome] of Object.entries(expected)) if (got[id] !== outcome) return `request ${id} ended ${got[id]}, expected ${outcome}`;
  return null;
};

export const scenarios: Scenario[] = [
  overStdio({
    name: "u02-stdio-responses",
    description: "Three requests end with their own outcomes, including an error from the server",
    rules: [
      { method: "tools/list", result: { tools: [] }, delayMs: 100 },
      { method: "ping", result: {} },
      { method: "boom", error: { code: -32602, message: "bad params" } },
    ],
    script: ["start", "request tools/list", "request ping", "request boom", "outcome 1 result", "outcome 2 result", "outcome 3 peer_error", "stop", "expect stopped"],
    check: (lines, final, log) => {
      const problem = want(outcomes(lines), { 1: "result", 2: "result", 3: "peer_error" });
      if (problem) return problem;
      // Every request carried its id as the progress token (WIRE-06).
      if (!received(log, "tools/list").some((l) => l.line.includes('"progressToken":1'))) return "tools/list was sent without its progress token";
      return expectFinal(final, { state: "stopped", in_flight: 0 });
    },
  }),
  overStdio({
    name: "u02-stdio-cancel-race",
    description: "A cancelled request stays cancelled when the server's late response arrives (REQ-01, REQ-02)",
    rules: [{ method: "slow", result: {}, delayMs: 500 }],
    script: ["start", "request slow", "cancel 1", "outcome 1 cancelled", "drain 900", "stop", "expect stopped"],
    check: (lines, _, log) => {
      if (received(log, "notifications/cancelled").length !== 1) return "the server should get exactly one notifications/cancelled";
      if (!lines.some((l) => l.seen?.message?.includes('"id":1'))) return "the late response should arrive and be ignored";
      return want(outcomes(lines), { 1: "cancelled" });
    },
  }),
  overStdio({
    name: "u02-stdio-timeout",
    description: "A request the server never answers times out, and the server is told to stop (REQ-03)",
    rules: [{ method: "hang", noReply: true }],
    labFlags: ["--idle-ms", "300", "--hard-ms", "2000"],
    script: ["start", "request hang", "outcome 1 timed_out 5000", "stop", "expect stopped"],
    check: (lines, _, log) => {
      if (received(log, "notifications/cancelled").length !== 1) return "a timeout should send notifications/cancelled";
      return want(outcomes(lines), { 1: "timed_out" });
    },
  }),
  overStdio({
    name: "u02-stdio-progress",
    description: "Progress notifications for a request in flight are accepted before its result (REQ-04)",
    rules: [
      {
        method: "work",
        before: [
          { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 1, progress: 1 } },
          { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 1, progress: 2 } },
          { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 9, progress: 1 } },
        ],
        result: {},
      },
    ],
    script: ["start", "request work", "outcome 1 result", "stop", "expect stopped"],
    check: (lines) => want(outcomes(lines), { 1: "result" }),
  }),
  overStdio({
    name: "u02-stdio-crash-lost",
    description: "A crash ends requests in flight as lost; a request while backing off is lost too; after the restart requests work (STDIO-07)",
    rules: [
      { method: "crashy", noReply: true, then: "crash" },
      { method: "ping", result: {} },
    ],
    labFlags: ["--backoff-ms", "300"],
    script: ["start", "request crashy", "outcome 1 lost", "expect backoff", "request ping", "outcome 2 lost", "expect idle", "start", "request ping", "outcome 3 result", "stop", "expect stopped"],
    check: (lines, final) => want(outcomes(lines), { 1: "lost", 2: "lost", 3: "result" }) ?? expectFinal(final, { state: "stopped", generation: 2 }),
  }),
];
