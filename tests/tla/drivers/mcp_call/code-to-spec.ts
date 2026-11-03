// Code to spec: runs event sequences through the real core, with faults,
// records each run as a JSON trace, and has TLC check that every trace is a
// behavior of McpCall and keeps its laws (TraceMcpCall.tla).
//
// Each trace starts in a new harness process. The scripted traces are the
// adversarial cases the design names. The random ones choose each event from
// what the core shows, mixed with every fault the model allows: a crash at
// any step (the process is killed), forged and revoked tokens, other
// versions, an answer delivered twice, late, or for a request that is gone or
// was never admitted, a disconnect at any stage, a lost reply, and the
// session stopping or a subagent ending mid-call.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Harness, actFor, checkTlc, seededRandom, specFiles, toTla, type CheckedTlc, type Event, type Shown } from "./lib.ts";

const start = (token = "t1"): Event => ({ event: "started", token });
const stop: Event = { event: "stopped" };
const add = (token = "t2", owner = "child"): Event => ({ event: "owner_added", owner, token });
const remove = (owner = "child"): Event => ({ event: "owner_removed", owner });
const request = (token = "t1", version = 1): Event => ({ event: "request", token, version });
const allow = (id: number): Event => ({ event: "authorized", id, allow: true });
const deny = (id: number): Event => ({ event: "authorized", id, allow: false });
const finish = (id: number, outcome = "ok"): Event => ({ event: "call_finished", id, outcome });
const replied = (id: number, delivered = true): Event => ({ event: "reply_done", id, delivered });
const gone = (id: number): Event => ({ event: "client_gone", id });
const crash: Event = { event: "crash" };

/// The adversarial cases, by name.
export const scripted: Record<string, Event[]> = {
  "a call from start to reply": [start(), request(), allow(0), finish(0), replied(0), gone(0)],
  "a denied call is answered once": [start(), request(), deny(0), replied(0), deny(0), finish(0)],
  "forged, revoked, and other-version requests are refused": [
    request(), start(), request("forged"), request("forged", 2), request("t1", 2), stop, request(), start("t2"), request("t1"), request("t2"),
  ],
  "a late allow for a withdrawn prompt starts nothing": [start(), request(), gone(0), allow(0), request()],
  "a result whose client left is dropped and logged": [start(), request(), allow(0), gone(0), finish(0, "ok"), request(), allow(1), gone(1), finish(1, "failed")],
  "duplicated answers are stale": [start(), request(), allow(0), allow(0), finish(0, "tool_error"), finish(0), replied(0), replied(0), gone(0)],
  "abandoned requests hold their slots": [start(), request(), request(), gone(0), request(), allow(0), request(), allow(1), finish(1), request()],
  "stopping mid-call lets work go and the next session drains it": [
    start(), request(), request(), allow(0), stop, request(), allow(1), start("t2"), request("t2"), finish(0, "ok"), request("t2"), finish(2), allow(2),
  ],
  "a subagent ends mid-call": [start(), add(), request("t2"), request("t2"), allow(0), remove(), request("t2"), finish(0, "ok"), allow(1), add("t2"), request("t2")],
  "a subagent cannot take a token in use or register twice": [start(), add("t1"), add("t2", "main"), add("t2"), add("t1"), remove("main"), request("t2"), remove(), remove()],
  "a crash mid-call starts the next process from nothing": [start(), request(), allow(0), crash, finish(0), start(), request(), allow(0), finish(0, "failed")],
  "a lost reply is logged": [start(), request(), allow(0), finish(0), replied(0, false), replied(0)],
  "answers for ids never issued are stale": [start(), allow(5), finish(7), replied(9), gone(3), request(), finish(1), allow(0)],
};

function pick<T>(random: () => number, items: T[]): T {
  return items[Math.floor(random() * items.length)]!;
}

/// One random event, chosen from what the core shows now.
function randomEvent(random: () => number, shown: Shown, previous: Event | undefined): Event {
  const ids = shown.entries.map((e) => e.id);
  const anyId = () => (ids.length > 0 && random() < 0.75 ? pick(random, ids) : Math.floor(random() * (shown.next + 2)));
  const mainToken = shown.registered.find((r) => r.owner === "main")?.token;
  const childToken = shown.registered.find((r) => r.owner === "child")?.token;
  const token = () => {
    const roll = random();
    if (roll < 0.5 && mainToken) return mainToken;
    if (roll < 0.7 && childToken) return childToken;
    if (roll < 0.85) return pick(random, ["t1", "t2"]);
    return "forged";
  };
  const roll = random();
  if (previous && previous.event !== "crash" && roll < 0.05) return previous;
  if (!shown.open && roll < 0.35) return start(pick(random, ["t1", "t2"]));
  if (roll < 0.3) return request(token(), random() < 0.9 ? 1 : 2);
  if (roll < 0.45) return random() < 0.75 ? allow(anyId()) : deny(anyId());
  if (roll < 0.6) return finish(anyId(), pick(random, ["ok", "ok", "tool_error", "failed"]));
  if (roll < 0.7) return replied(anyId(), random() < 0.85);
  if (roll < 0.78) return gone(anyId());
  if (roll < 0.84) return add(pick(random, ["t1", "t2"]), random() < 0.9 ? "child" : "main");
  if (roll < 0.89) return remove(random() < 0.9 ? "child" : "main");
  if (roll < 0.93) return stop;
  if (roll < 0.96) return start(pick(random, ["t1", "t2"]));
  return crash;
}

export type CodeToSpecResult = {
  traces: number;
  steps: number;
  crashes: number;
  tracesPath: string;
  tlc: CheckedTlc;
};

/// Runs the traces through `bin` and checks them with `cfgName` from
/// `cfgText` (TraceMcpCall.cfg by default).
export async function codeToSpec(options: {
  bin: string;
  dir: string;
  seed: number;
  randomTraces: number;
  maxLength: number;
  cfgName?: string;
  cfgText?: string;
}): Promise<CodeToSpecResult> {
  const random = seededRandom(options.seed);
  const harness = await Harness.start(options.bin);
  const traces: { name: string; states: Record<string, unknown>[] }[] = [];
  let steps = 0;
  const record = async (name: string, next: (shown: Shown, previous: Event | undefined) => Event | null) => {
    await harness.crash();
    const states: Record<string, unknown>[] = [{ ...harness.last, act: { name: "Init" } }];
    let previous: Event | undefined;
    for (let event = next(harness.last, previous); event; event = next(harness.last, previous)) {
      const shown = await harness.send(event);
      states.push({ ...shown, act: actFor(event) });
      steps += 1;
      previous = event;
    }
    traces.push({ name, states });
  };
  try {
    for (const [name, events] of Object.entries(scripted)) {
      let at = 0;
      await record(name, () => events[at++] ?? null);
    }
    for (let i = 0; i < options.randomTraces; i += 1) {
      const length = 2 + Math.floor(random() * (options.maxLength - 1));
      let at = 0;
      await record(`random ${i + 1} (seed ${options.seed})`, (shown, previous) => (at++ < length ? randomEvent(random, shown, previous) : null));
    }
  } finally {
    await harness.close();
  }

  mkdirSync(options.dir, { recursive: true });
  const tracesPath = join(options.dir, "traces.json");
  writeFileSync(tracesPath, `${JSON.stringify(traces, null, 1)}\n`);
  const data = [
    "---- MODULE TraceData ----",
    "EXTENDS Sequences",
    "Traces == <<",
    traces.map((trace) => `  \\* ${trace.name}\n  ${toTla(trace.states)}`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  const files = { ...specFiles(), "TraceData.tla": data };
  const cfgName = options.cfgName ?? "TraceMcpCall.cfg";
  if (options.cfgText) files[cfgName as keyof typeof files] = options.cfgText;
  const tlc = await checkTlc(join(options.dir, "tlc"), "TraceMcpCall", cfgName, files);
  return { traces: traces.length, steps, crashes: harness.crashes, tracesPath, tlc };
}
