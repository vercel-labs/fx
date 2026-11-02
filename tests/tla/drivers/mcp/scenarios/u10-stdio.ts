// U10 subscriptions over stdio, step 6: the stdio lab's `listen` and
// `unlisten` drive src/mcp/core/subscription.zig against the fake stdio
// server, whose listen rules acknowledge and never answer. Every listen
// shares the one channel, so notifications are told apart only by their
// subscriptionId (SUBS-02). Detection takes request id 1, so listens get 2,
// 3, and so on, and later rules can name them.

import type { Rule } from "../fakes/stdio";
import { labScenario, type LabCase, type Seen } from "../lab";
import type { Scenario } from "../scenario";

const MODERN = "2026-07-28";
const sid = "io.modelcontextprotocol/subscriptionId";
const discover: Rule = { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: { listChanged: true } } } };
const ack = (notifications: object) => ({ jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: { _meta: { [sid]: "$id" }, notifications } });
const changed = (what: string, id: number) => ({ jsonrpc: "2.0", method: `notifications/${what}/list_changed`, params: { _meta: { [sid]: id } } });
const listen = (notifications: object, times?: number): Rule => ({ method: "subscriptions/listen", before: [ack(notifications)], noReply: true, ...(times ? { times } : {}) });

const START = ["start", "detect", "expect era-modern"];
const subs = (lines: Seen[]) => lines.filter((l) => l.sub).map((l) => l.sub!);
const sent = (log: { dir: string; line: string }[], method: string) =>
  log.filter((l) => l.dir === "in").map((l) => JSON.parse(l.line)).filter((m) => m.method === method);

function stdioScenario(c: Omit<LabCase, "unit">): Scenario {
  return labScenario({
    unit: "U10",
    requestTrace: true,
    era: { preferred: 1 },
    subscription: {},
    labFlags: ["--preferred", MODERN, "--probe-ms", "3000", "--backoff-ms", "200"],
    ...c,
  });
}

export const scenarios: Scenario[] = [
  stdioScenario({
    name: "u10-stdio-demux",
    description: "Two subscriptions on one channel: changes for both, interleaved, reach only the subscription whose id they carry and only what it asked for (SUBS-02)",
    rules: [
      discover,
      listen({ toolsListChanged: true }, 1),
      listen({ promptsListChanged: true }, 1),
      { method: "ping", before: [changed("tools", 2), changed("prompts", 3), changed("tools", 3), changed("prompts", 2), changed("tools", 9)], result: {} },
    ],
    script: [...START, "listen 0 1", "listen 1 2", "drain 300", "request ping", "drain 300", "stop", "expect stopped 5000"],
    check(lines) {
      const delivered = subs(lines).filter((s) => s.deliver).map((s) => [s.sub, s.deliver]);
      const acked = subs(lines).filter((s) => s.acknowledged !== undefined).map((s) => [s.sub, s.acknowledged]);
      if (JSON.stringify(acked) !== JSON.stringify([[0, 1], [1, 2]])) return `acknowledgments were ${JSON.stringify(acked)}`;
      return JSON.stringify(delivered) === JSON.stringify([[0, "tools"], [1, "prompts"]]) ? null : `deliveries were ${JSON.stringify(delivered)}`;
    },
  }),
  stdioScenario({
    name: "u10-stdio-cancel",
    description: "Cancelling a subscription on stdio sends notifications/cancelled naming its listen (SUBS-04)",
    rules: [discover, listen({ toolsListChanged: true })],
    script: [...START, "listen 0 1", "drain 300", "unlisten 0", "drain 300", "stop", "expect stopped 5000"],
    check(lines, _final, log) {
      const cancels = sent(log, "notifications/cancelled").map((m) => m.params?.requestId);
      const [l] = sent(log, "subscriptions/listen");
      if (JSON.stringify(cancels) !== JSON.stringify([l?.id])) return `cancels named ${JSON.stringify(cancels)}, the listen was ${l?.id}`;
      return subs(lines).some((s) => s.ended) ? "the host's own cancel was reported as an end" : null;
    },
  }),
  stdioScenario({
    name: "u10-stdio-restart",
    description: "The server process crashes: once the new process is detected, the listen goes out again with a new id and is acknowledged again (SUBS-05)",
    rules: [discover, listen({ toolsListChanged: true }), { method: "crash", result: {}, then: "crash" }],
    script: [...START, "listen 0 1", "drain 300", "request crash", "drain 3000", "stop", "expect stopped 5000"],
    timeoutMs: 30_000,
    check(lines, _final, log) {
      const listens = sent(log, "subscriptions/listen").map((m) => m.id);
      if (listens.length !== 2 || !(listens[1] > listens[0])) return `listens went out with ids ${JSON.stringify(listens)}`;
      const acked = subs(lines).filter((s) => s.acknowledged !== undefined).length;
      if (acked !== 2) return `acknowledged ${acked} times`;
      return subs(lines).some((s) => s.ended) ? "the subscription ended" : null;
    },
  }),
  stdioScenario({
    name: "u10-stdio-server-cancel",
    description: "The server's notifications/cancelled for the listen ends the subscription, and it isn't listened to again (SUBS-03)",
    rules: [discover, listen({ toolsListChanged: true }), { method: "bye", before: [{ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2 } }], result: {} }],
    script: [...START, "listen 0 1", "drain 300", "request bye", "drain 500", "stop", "expect stopped 5000"],
    check(lines, _final, log) {
      const ended = subs(lines).filter((s) => s.ended).map((s) => s.ended);
      if (JSON.stringify(ended) !== JSON.stringify(["server_cancelled"])) return `ends were ${JSON.stringify(ended)}`;
      return sent(log, "subscriptions/listen").length === 1 ? null : "the listen went out again";
    },
  }),
];
