// U03 stdio connection, step 6: the real I/O layer (src/mcp/io/process.zig),
// run by tests/tla/drivers/mcp/labs/stdio_lab.zig against the scripted fake server, must
// produce stdio traces that TLC accepts as behaviors of spec/StdioConn.tla.
// The planted case is a known-bad control: the lab allows three failures
// while the model is told two, so TLC must reject the trace.

import { expectFinal, labScenario, type LabCase, messages, PING, PING2 } from "../lab";
import type { Scenario } from "../scenario";

const stdioScenario = (c: Omit<LabCase, "unit">): Scenario => labScenario({ ...c, unit: "U03" });

const crashLoop = ["start", "expect backoff", "expect idle", "start", "expect backoff", "expect idle", "start"];

export const scenarios: Scenario[] = [
  stdioScenario({
    name: "u03-exchange-and-stop",
    description: "A request gets its response; a stop closes stdin and the server exits without signals",
    rules: [{ method: "ping", result: {} }],
    script: ["start", `send request ${PING}`, "expect message", "stop", "expect stopped"],
    check: (lines, final) => (messages(lines).length !== 1 ? "expected one message" : expectFinal(final, { state: "stopped", term_sent: false, kill_sent: false })),
  }),
  stdioScenario({
    name: "u03-crash-restart",
    description: "A server that crashes after each reply backs off, restarts on demand, and answers again",
    rules: [{ method: "ping", result: {}, then: "crash" }],
    labFlags: ["--backoff-ms", "50"],
    script: ["start", `send request ${PING}`, "expect message", "expect backoff", "expect idle", "start", `send request ${PING2}`, "expect message", "expect backoff", "stop"],
    check: (lines, final) => (messages(lines).length !== 2 ? "expected two messages" : expectFinal(final, { state: "stopped", generation: 2 })),
  }),
  stdioScenario({
    name: "u03-server-exits-on-its-own",
    description: "A server that shuts itself down counts as a failure and backs off",
    rules: [{ method: "ping", result: {}, then: "exit" }],
    labFlags: ["--backoff-ms", "50"],
    script: ["start", `send request ${PING}`, "expect message", "expect backoff", "stop"],
    check: (_, final) => expectFinal(final, { state: "stopped", attempts: 1 }),
  }),
  stdioScenario({
    name: "u03-crash-loop-fails",
    description: "A server that dies at startup fails after the attempt limit; a reconnect starts counting again",
    fakeFlags: ["--exit-at-start", "3"],
    labFlags: ["--max-attempts", "3", "--backoff-ms", "20"],
    maxAttempts: 3,
    script: [...crashLoop, "expect failed", "start", "reconnect", "start", "expect backoff", "stop"],
    check: (lines, final) =>
      !lines.some((l) => l.did?.action === "start" && l.did.state === "failed") ? "a start while failed should be ignored" : expectFinal(final, { state: "stopped", attempts: 1, generation: 4 }),
  }),
  stdioScenario({
    name: "u03-ignores-closed-stdin",
    description: "A server that keeps running after stdin closes gets SIGTERM after the grace period",
    fakeFlags: ["--linger"],
    labFlags: ["--grace-ms", "200", "--term-ms", "5000"],
    script: ["start", "stop", "expect stopped"],
    check: (_, final) => expectFinal(final, { state: "stopped", term_sent: true, kill_sent: false }),
  }),
  stdioScenario({
    name: "u03-ignores-sigterm",
    description: "A server that also ignores SIGTERM gets SIGKILL",
    fakeFlags: ["--linger", "--ignore-term"],
    labFlags: ["--grace-ms", "200", "--term-ms", "200"],
    script: ["start", "stop", "expect stopped"],
    check: (_, final) => expectFinal(final, { state: "stopped", term_sent: true, kill_sent: true }),
  }),
  stdioScenario({
    name: "u03-stderr-flood",
    description: "1 MB of stderr before a reply never stalls the server or changes the state (STDIO-05)",
    rules: [{ method: "ping", stderr: ["e".repeat(200)], stderrRepeat: 5000, result: {} }],
    script: ["start", `send request ${PING}`, "expect message 30000", "stop", "expect stopped"],
    check: (lines, final) => {
      const stderr = lines.filter((l) => l.seen?.stderr !== undefined).length;
      if (messages(lines).length !== 1) return "expected the reply after the flood";
      if (stderr + final.stderr_dropped < 5000) return `only ${stderr} stderr lines seen and ${final.stderr_dropped} dropped`;
      return expectFinal(final, { state: "stopped", errored: false });
    },
    timeoutMs: 60_000,
  }),
  stdioScenario({
    name: "u03-oversized-line",
    description: "A stdout line over the limit kills the server at once, without SIGTERM",
    rules: [{ method: "ping", rawBytes: 100_000, result: {} }],
    labFlags: ["--max-line", "65536"],
    script: ["start", `send request ${PING}`, "expect killing", "expect backoff", "stop"],
    check: (_, final) => expectFinal(final, { state: "stopped", errored: true, term_sent: false, kill_sent: true }),
  }),
  stdioScenario({
    name: "u03-banner-dropped",
    description: "A non-MCP line on stdout is dropped and the connection keeps working",
    rules: [{ method: "ping", result: {} }],
    fakeFlags: ["--banner", "Server running on stdio"],
    script: ["start", "expect dropped", `send request ${PING}`, "expect message", "stop", "expect stopped"],
    check: (lines) => (lines.find((l) => l.seen?.dropped)?.seen?.dropped !== "InvalidJson" ? "expected the banner dropped as InvalidJson" : null),
  }),
  stdioScenario({
    name: "u03-crlf-and-empty-lines",
    description: "CRLF line endings and empty lines are handled; nothing is dropped",
    rules: [{ method: "ping", raw: '{"jsonrpc":"2.0","id":1,"result":{}}\r' }],
    fakeFlags: ["--banner", ""],
    script: ["start", `send request ${PING}`, "expect message", "stop", "expect stopped"],
    check: (lines) => {
      if (lines.some((l) => l.seen?.dropped)) return "nothing should be dropped";
      return messages(lines)[0] === '{"jsonrpc":"2.0","id":1,"result":{}}' ? null : `message was ${JSON.stringify(messages(lines)[0])}`;
    },
  }),
  stdioScenario({
    name: "u03-spawn-failure",
    description: "A command that can't start counts as a failure and backs off",
    server: ["/nonexistent/mcpv2-test-server"],
    script: ["start", "expect backoff", "stop"],
    check: (_, final) => (final.spawn_error === null ? "expected a spawn error" : expectFinal(final, { state: "stopped", attempts: 1 })),
  }),
  stdioScenario({
    name: "u03-planted-limit-mismatch",
    description: "Known-bad control: the lab allows three failures but the model is told two",
    fakeFlags: ["--exit-at-start", "3"],
    labFlags: ["--max-attempts", "3", "--backoff-ms", "20"],
    maxAttempts: 2,
    verdict: "REJECTED",
    script: ["start", "expect backoff", "expect idle", "start", "expect backoff", "stop"],
  }),
];
