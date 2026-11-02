// Code to spec: runs event sequences through the real core, with faults,
// records each run as a JSON trace, and has TLC check that every trace is a
// behavior of ImageRoute and keeps its laws (TraceImageRoute.tla).
//
// Each trace starts in a new harness process. The scripted traces are the
// adversarial cases the design names; the random ones mix every event with
// the faults the model allows: a crash at any step (the process is killed),
// a request delivered twice, a reply that is lost (the next turn starts
// first), stale, or duplicated, and a catalog that is down, missing the
// model, or flapping between answers.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Harness, actFor, checkTlc, seededRandom, specFiles, toTla, type CheckedTlc, type Event, type Request, type View } from "./lib.ts";

const listed = (vision: boolean, file_input: boolean): View => ({ kind: "listed", vision, file_input });
const down: View = { kind: "down", vision: false, file_input: false };
const missing: View = { kind: "missing", vision: false, file_input: false };
// The live catalog's entry for the default model, spacexai/grok-4.7.
const visionOnly = listed(true, false);
const views: View[] = [listed(true, true), visionOnly, listed(false, true), listed(false, false), missing, down];

function req(flags: Partial<Request>): Request {
  return { user_images: false, earlier_images: false, pending_images: false, tool_images: false, fallback: false, catalog_down: false, ...flags };
}

const requests: Request[] = [];
for (let bits = 0; bits < 64; bits += 1) {
  const r = req({
    user_images: (bits & 1) !== 0,
    pending_images: (bits & 2) !== 0,
    tool_images: (bits & 4) !== 0,
    fallback: (bits & 8) !== 0,
    catalog_down: (bits & 16) !== 0,
    earlier_images: (bits & 32) !== 0,
  });
  if (r.pending_images && !r.user_images) continue;
  requests.push(r);
}

const turn = (view: View): Event => ({ event: "turn_started", view });
const ready = (flags: Partial<Request>): Event => ({ event: "request_ready", req: req(flags) });
const reply = (view: View): Event => ({ event: "capabilities_resolved", view });
const crash: Event = { event: "crash" };

/// The adversarial cases, by name.
export const scripted: Record<string, Event[]> = {
  // The reported bug: a tool image under the default model's catalog entry.
  "default model tool image": [turn(visionOnly), ready({ tool_images: true, fallback: true }), ready({ tool_images: true, user_images: true })],
  // A down catalog: one notice per turn, however many requests.
  "catalog down notice once per turn": [
    turn(down), ready({ tool_images: true, catalog_down: true }), reply(down),
    ready({ tool_images: true, catalog_down: true }), ready({ tool_images: true, catalog_down: true }),
    turn(down), ready({ tool_images: true, catalog_down: true }), reply(down),
  ],
  // A request delivered again, then another, while the reply is owed.
  "duplicate request while a reply is owed": [
    turn(missing), ready({ user_images: true }), ready({ user_images: true }), ready({ tool_images: true }), reply(visionOnly),
  ],
  // The reply is lost when the turn ends first, then arrives stale.
  "lost reply then stale reply": [turn(down), ready({ tool_images: true }), turn(visionOnly), reply(down), ready({ tool_images: true })],
  // The process dies while a reply is owed.
  "crash while a reply is owed": [turn(down), ready({ user_images: true, pending_images: true }), crash, reply(visionOnly), ready({ user_images: true }), reply(visionOnly)],
  // A duplicated reply, the second with a different answer.
  "duplicated reply": [turn(missing), ready({ tool_images: true, fallback: true }), reply(listed(false, false)), reply(visionOnly), ready({ tool_images: true, fallback: true })],
  // User images on a model without vision and no vision tool fail.
  "user images with no route": [turn(listed(false, true)), ready({ user_images: true, pending_images: true }), ready({ user_images: true, fallback: true, pending_images: true })],
  // The catalog recovers within the turn: the one resolve picks it up.
  "catalog recovers within the turn": [turn(down), ready({ tool_images: true, user_images: true, fallback: true }), reply(listed(true, false)), ready({ tool_images: true })],
  // The reported session: an earlier screenshot, then text-only turns after
  // a restart with the catalog unreachable. Each is sent, the image
  // withheld with a note, and the user hears once per turn.
  "earlier image while the catalog is down": [
    turn(down), ready({ earlier_images: true, fallback: true, catalog_down: true }), reply(down),
    ready({ earlier_images: true, fallback: true, catalog_down: true }),
    turn(down), ready({ earlier_images: true, fallback: true, catalog_down: true }), reply(down),
  ],
  // An image attached now still fails while support is unknown.
  "image attached now while the catalog is down": [turn(down), ready({ user_images: true, pending_images: true, earlier_images: true, catalog_down: true }), reply(down)],
  // A model without vision and no vision tool: the earlier image is a dead end, not a failure.
  "earlier image with no route": [turn(listed(false, false)), ready({ earlier_images: true })],
  // Earlier images go inline again once the catalog lists vision.
  "earlier image after the catalog recovers": [turn(missing), ready({ earlier_images: true }), reply(missing), turn(visionOnly), ready({ earlier_images: true })],
};

function randomEvents(random: () => number, length: number): Event[] {
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  const pickView = () => (random() < 0.3 ? visionOnly : pick(views));
  const events: Event[] = [turn(pickView())];
  for (let i = 1; i < length; i += 1) {
    const roll = random();
    const previous = events[events.length - 1]!;
    if (roll < 0.1 && previous.event === "request_ready") events.push(previous);
    else if (roll < 0.5) events.push({ event: "request_ready", req: pick(requests) });
    else if (roll < 0.75) events.push(reply(pickView()));
    else if (roll < 0.93) events.push(turn(pickView()));
    else events.push(crash);
  }
  return events;
}

export type CodeToSpecResult = {
  traces: number;
  steps: number;
  tracesPath: string;
  tlc: CheckedTlc;
};

/// Runs the traces through `bin` and checks them with `cfgName` from
/// `cfgText` (TraceImageRoute.cfg by default).
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
  const runs: { name: string; events: Event[] }[] = Object.entries(scripted).map(([name, events]) => ({ name, events }));
  for (let i = 0; i < options.randomTraces; i += 1) {
    runs.push({ name: `random ${i + 1} (seed ${options.seed})`, events: randomEvents(random, 2 + Math.floor(random() * (options.maxLength - 1))) });
  }

  const harness = await Harness.start(options.bin);
  const traces: { name: string; states: Record<string, unknown>[] }[] = [];
  let steps = 0;
  try {
    for (const run of runs) {
      await harness.crash();
      const states: Record<string, unknown>[] = [{ ...harness.last, act: { name: "Init" } }];
      for (const event of run.events) {
        const before = harness.last;
        const shown = await harness.send(event);
        states.push({ ...shown, act: actFor(event, before) });
        steps += 1;
      }
      traces.push({ name: run.name, states });
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
  const cfgName = options.cfgName ?? "TraceImageRoute.cfg";
  if (options.cfgText) files[cfgName as keyof typeof files] = options.cfgText;
  const tlc = await checkTlc(join(options.dir, "tlc"), "TraceImageRoute", cfgName, files);
  return { traces: traces.length, steps, tracesPath, tlc };
}
