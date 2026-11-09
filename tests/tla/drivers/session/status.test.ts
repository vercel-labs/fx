// Runs the real fx binary along tests/tla/session/ShellSession.tla: a profile
// outlives several processes, each of which launches, prompts, runs
// `/status`, `/new`, `/clear`, `/resume` and `/fork`, then quits or crashes.
// After every step the driver records what fx showed and saved, from fx's
// own output only: the session each step opened from the wiring trace, each
// `/status` panel as fx's virtual terminal replays it from the recorded
// tape, the exit line, and the session folders on disk. TLC then replays the
// whole run through the model (ShellSessionTrace.tla). Every panel must also
// close without adding a row to the transcript.
//
// The scripted walk reaches every action and every case D90 names. The
// random walks (FX_TLA_WALKS, default 2, of FX_TLA_STEPS steps, default 16,
// from FX_TLA_SEED, default 1) choose among the steps a user could take
// next; the driver tracks only what it did, never what fx should show.
// Planted changes to a kept run must be rejected, and an empty run is no
// evidence at all.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { artifacts, binary, targetModule } from "../lib/context";
import { writeJson } from "../lib/tlc";
import { checkTrace, type Observation, type Op } from "./bridge";

const { Profile } = await targetModule("shell-sessions.ts");
const { closedAsBefore, panelSession, showsStatusPanel } = await targetModule("info-panel.ts");
const { tmuxAvailable } = await targetModule("tmux-helpers.ts");

const TIMEOUT = 900_000;
const MAX_TURNS = 3;

type Step =
  | { op: "launch" | "launch_no_store" | "begin" | "end" | "status" | "new" | "clear" | "quit" | "crash" }
  | { op: "launch_resume"; target: string }
  | { op: "resume"; marker: string }
  | { op: "fork"; up: number };

/// What the driver did to one session: the prompts it holds, copied ones
/// included, the marker its own prompts carry, the session it was forked
/// from, and whether its first prompt was answered, which titles it (D52).
type Tracked = { prompts: string[]; marker: string | null; source: string | null; titled: boolean };

/// What the driver did, and nothing it expects fx to show: which process
/// runs, which session it last opened, what each session was given, and
/// whether a reply is held.
class Walk {
  readonly profile: any;
  readonly observations: Observation[] = [];
  readonly sessions = new Map<string, Tracked>();
  shell: any = null;
  blocked = false;
  held: { release(answer: string): Promise<void> } | null = null;
  /// Each `/status` observation's index, per shell, filled once it ends.
  private pending: Array<{ shell: any; index: number }> = [];
  private prompts = 0;
  private markers = 0;

  constructor(readonly name: string) {
    this.profile = new Profile(name, binary);
  }

  current(): string | null {
    return this.shell?.current() ?? null;
  }

  tracked(id: string): Tracked {
    if (!this.sessions.has(id)) this.sessions.set(id, { prompts: [], marker: null, source: null, titled: false });
    return this.sessions.get(id)!;
  }

  /// The saved sessions, as the last step left the disk.
  saved(): string[] {
    return Object.keys(this.observations.at(-1)?.disk ?? {});
  }

  /// Saved sessions the `/resume` picker finds alone by their marker: not
  /// open, not a fork, titled, and with no fork on disk, whose title and
  /// copied prompts carry the same marker.
  pickable(): Array<{ id: string; marker: string }> {
    const saved = this.saved();
    const descends = (id: string, from: string): boolean => {
      for (let at = this.sessions.get(id)?.source ?? null; at; at = this.sessions.get(at)?.source ?? null) {
        if (at === from) return true;
      }
      return false;
    };
    return saved.flatMap((id) => {
      const session = this.sessions.get(id);
      if (!session?.marker || !session.titled || session.source || id === this.current()) return [];
      if (saved.some((other) => descends(other, id))) return [];
      return [{ id, marker: session.marker }];
    });
  }

  async run(step: Step): Promise<void> {
    const observed: Observation = { op: step.op as Op, id: "none", point: 0, saved: false, handoff: "none", disk: {} };
    switch (step.op) {
      case "launch":
        this.shell = await this.profile.launch();
        observed.id = this.current() ?? "none";
        break;
      case "launch_resume":
        this.shell = await this.profile.launch({ args: ["--resume", step.target] });
        observed.id = this.current() ?? "none";
        break;
      case "launch_no_store":
        this.profile.blockStore();
        this.blocked = true;
        this.shell = await this.profile.launch();
        observed.id = this.current() ?? "none";
        break;
      case "begin": {
        const id = this.current();
        const session = id ? this.tracked(id) : null;
        if (session && !session.marker) session.marker = `M${String(++this.markers).padStart(3, "0")}X`;
        const text = `Walk ${this.name} ${session?.marker ?? "unsaved"} prompt ${++this.prompts}.`;
        this.held = await this.shell.begin(text);
        session?.prompts.push(text);
        break;
      }
      case "end": {
        await this.held!.release(`ANSWER_${this.prompts}`);
        this.held = null;
        const id = this.current();
        if (id) this.tracked(id).titled = true;
        break;
      }
      case "status":
        await this.shell.status();
        this.pending.push({ shell: this.shell, index: this.observations.length });
        break;
      case "new":
      case "clear":
        if (this.blocked) await this.shell.command(`/${step.op}`);
        else await this.shell.newSession(`/${step.op}`);
        observed.id = this.blocked ? "none" : this.current()!;
        break;
      case "resume":
        observed.id = await this.shell.resume(step.marker);
        break;
      case "fork": {
        const source = this.current()!;
        const prompts = this.tracked(source).prompts;
        observed.point = prompts.length - step.up;
        observed.id = await this.shell.fork(step.up);
        Object.assign(this.tracked(observed.id), { prompts: prompts.slice(0, observed.point - 1), source });
        break;
      }
      case "quit":
        observed.handoff = (await this.shell.quit()) ?? "none";
        this.ended();
        break;
      case "crash":
        await this.shell.crash();
        this.ended();
        break;
    }
    observed.disk = this.profile.disk();
    this.observations.push(observed);
    if (step.op === "quit" || step.op === "crash") this.fillReports();
  }

  /// The id the newest `/status` of an ended process showed.
  lastStatusId(): string {
    return this.observations.findLast((o) => o.op === "status" && o.id !== "none")!.id;
  }

  /// The process is gone, and with it any reply it was waiting for.
  private ended() {
    this.shell.ended = true;
    this.held = null;
    if (this.blocked) {
      this.profile.unblockStore();
      this.blocked = false;
    }
  }

  /// Each `/status` the ended shell ran gets the panel its tape replays.
  private fillReports() {
    const shell = this.shell;
    const mine = this.pending.filter((entry) => entry.shell === shell);
    const reports = shell.reports();
    expect(reports.length).toBe(mine.length);
    mine.forEach((entry, n) => {
      const report = reports[n];
      const session = panelSession(report);
      this.observations[entry.index]!.id = session.id ?? "none";
      this.observations[entry.index]!.saved = session.saved;
      expect(showsStatusPanel(report.closed)).toBe(false);
      expect(closedAsBefore(report)).toBe(true);
    });
    this.pending = this.pending.filter((entry) => entry.shell !== shell);
    expect(shell.stderrText()).toBe("");
    this.shell = null;
  }

  async finish(keep: boolean) {
    if (this.shell && !this.shell.ended) await this.run({ op: "quit" });
    await this.profile.close(keep);
  }
}

/// Every action and every D90 case: a session unsaved until its first turn,
/// saved while it runs, `/new` and `/clear` from saved and unsaved sessions,
/// `/resume`, a fork before the first prompt and a later one, a resume of the
/// id the exit line printed and of the id `/status` showed, crashes with and
/// without a saved session, and a launch without a store.
function scriptedSteps(): Array<Step | ((w: Walk) => Step)> {
  const pick = (w: Walk): Step => ({ op: "resume", marker: w.pickable()[0]!.marker });
  return [
    { op: "launch" }, { op: "status" },
    { op: "begin" }, { op: "status" }, { op: "end" }, { op: "status" },
    { op: "new" }, { op: "status" }, { op: "clear" }, { op: "status" },
    { op: "begin" }, { op: "end" }, { op: "status" },
    pick, { op: "status" },
    { op: "begin" }, { op: "end" },
    { op: "fork", up: 1 }, { op: "status" },
    { op: "quit" },
    (w) => ({ op: "launch_resume", target: w.observations.at(-1)!.handoff }), { op: "status" },
    { op: "begin" }, { op: "end" }, { op: "begin" }, { op: "end" },
    { op: "fork", up: 0 }, { op: "status" },
    { op: "crash" },
    { op: "launch" }, { op: "status" }, { op: "begin" }, { op: "status" }, { op: "crash" },
    (w) => ({ op: "launch_resume", target: w.lastStatusId() }), { op: "status" }, { op: "quit" },
    { op: "launch" }, { op: "status" }, { op: "crash" },
    { op: "launch_no_store" }, { op: "status" }, { op: "begin" }, { op: "end" }, { op: "new" }, { op: "status" }, { op: "quit" },
    (w) => ({ op: "launch_resume", target: w.saved()[0]! }), { op: "status" }, { op: "quit" },
  ];
}

/// A small seeded generator, so a failing walk can be run again.
function prng(seed: number) {
  let state = seed >>> 0 || 1;
  return (n: number) => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state % n;
  };
}

/// The steps a user could take next, from what the driver did, each listed
/// as often as it should be taken: prompts, forks and resumes more often
/// than ending a process, so a walk reaches sessions worth checking.
function choices(w: Walk): Step[] {
  const times = (count: number, step: Step): Step[] => Array.from({ length: count }, () => step);
  if (!w.shell) {
    return [
      ...times(3, { op: "launch" }), { op: "launch_no_store" },
      ...w.saved().flatMap((target) => times(2, { op: "launch_resume", target })),
    ];
  }
  if (w.held) return [...times(3, { op: "end" }), ...times(2, { op: "status" }), { op: "quit" }, { op: "crash" }];
  const cur = w.current();
  const prompts = cur ? w.tracked(cur).prompts.length : 0;
  const steps: Step[] = [...times(3, { op: "status" }), { op: "new" }, { op: "clear" }, { op: "quit" }, { op: "crash" }];
  if (prompts < MAX_TURNS) steps.push(...times(4, { op: "begin" }));
  if (cur && !w.blocked) {
    for (let up = 0; up < prompts; up++) steps.push(...times(2, { op: "fork", up }));
    for (const { marker } of w.pickable()) steps.push(...times(2, { op: "resume", marker }));
  }
  return steps;
}

async function walk(name: string, plan: (w: Walk) => Promise<void>) {
  const w = new Walk(name);
  let passed = false;
  try {
    await plan(w);
    await w.finish(false);
    passed = true;
  } finally {
    if (!passed) await w.finish(true).catch(() => {});
    writeJson(join(artifacts, name, "observations.json"), w.observations);
  }
  const result = await checkTrace(w.observations, join(artifacts, name, "tlc"));
  console.log(`${name}: ${result.verdict} ${result.matched}/${result.length} ${result.detail}`);
  return { observations: w.observations, result };
}

let kept: Observation[] | null = null;

test.skipIf(!tmuxAvailable())("the scripted walk is a behavior of ShellSession", async () => {
  const { observations, result } = await walk("scripted", async (w) => {
    for (const step of scriptedSteps()) await w.run(typeof step === "function" ? step(w) : step);
  });
  expect(result.verdict).toBe("ACCEPTED");
  for (const op of ["launch", "launch_resume", "launch_no_store", "begin", "end", "status", "new", "clear", "resume", "fork", "quit", "crash"]) {
    expect(observations.some((o) => o.op === op)).toBe(true);
  }
  // A fork before the first prompt: saved with no turn, and named at exit.
  const empty = observations.find((o) => o.op === "fork" && o.point === 1)!;
  expect(empty.disk[empty.id]).toBe(0);
  kept = observations;
}, TIMEOUT);

const walks = Number(process.env.FX_TLA_WALKS ?? "2");
const steps = Number(process.env.FX_TLA_STEPS ?? "16");
const seed = Number(process.env.FX_TLA_SEED ?? "1");
for (let n = 0; n < walks; n++) {
  test.skipIf(!tmuxAvailable())(`random walk ${n + 1} from seed ${seed} is a behavior of ShellSession`, async () => {
    const pick = prng(seed * 7919 + n);
    const { result } = await walk(`random-${seed}-${n + 1}`, async (w) => {
      for (let taken = 0; taken < steps; taken++) {
        const next = choices(w);
        await w.run(next[pick(next.length)]!);
      }
    });
    expect(result.verdict).toBe("ACCEPTED");
  }, TIMEOUT);
}

/// The kept scripted run with one planted change. TLC must reject it, and
/// the first step it cannot produce must be the one `plant` changed, whose
/// index `plant` returns.
function planted(name: string, plant: (observations: Observation[]) => number) {
  test.skipIf(!tmuxAvailable())(`planted: ${name} is rejected at the planted step`, async () => {
    if (!kept) throw new Error("the planted runs are made from the scripted walk's run; run this whole file");
    const copy: Observation[] = structuredClone(kept!);
    const at = plant(copy);
    const result = await checkTrace(copy, join(artifacts, "planted", name.replace(/[^A-Za-z0-9]+/g, "-")));
    expect(result.verdict).toBe("REJECTED");
    expect(result.firstMismatch?.step).toBe(at + 1);
  }, TIMEOUT);
}

planted("/status calling a saved session unsaved", (o) => {
  const at = o.findIndex((step) => step.op === "status" && step.saved);
  o[at]!.saved = false;
  return at;
});

planted("/status calling a session saved before its first turn", (o) => {
  const at = o.findIndex((step) => step.op === "status" && !step.saved && step.id !== "none");
  o[at]!.saved = true;
  return at;
});

planted("/status naming the session open before /new", (o) => {
  const at = o.findIndex((step) => step.op === "new");
  expect([o[at - 1]!.op, o[at + 1]!.op]).toEqual(["status", "status"]);
  o[at + 1]!.id = o[at - 1]!.id;
  return at + 1;
});

planted("the exit line before D90, silent after a fork before the first prompt", (o) => {
  const fork = o.findIndex((step) => step.op === "fork" && step.point === 1);
  const at = o.findIndex((step, index) => index > fork && step.op === "quit");
  expect(o[at]!.handoff).toBe(o[fork]!.id);
  o[at]!.handoff = "none";
  return at;
});

planted("a session never prompted left on disk", (o) => {
  // The scripted walk runs /clear in a session /new opened and never prompted.
  const at = o.findIndex((step) => step.op === "clear");
  const left = o[at - 1]!;
  expect(left.op === "status" && !left.saved).toBe(true);
  for (const step of o.slice(at)) step.disk[left.id] = 0;
  return at;
});

planted("a fork holding the turn it was made before", (o) => {
  const at = o.findIndex((step) => step.op === "fork" && step.point > 1);
  for (const step of o.slice(at)) if (o[at]!.id in step.disk) step.disk[o[at]!.id]! += 1;
  return at;
});

test("an empty run is no evidence", async () => {
  expect((await checkTrace([], join(artifacts, "planted", "empty"))).verdict).toBe("TOOL_ERROR");
});
