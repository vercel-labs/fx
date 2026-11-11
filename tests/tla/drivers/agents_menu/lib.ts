// The built fx, driven through the agent list in tmux, as the model in
// tests/tla/agents_menu/spec/AgentsMenu.tla sees it.
//
// A world is one fx process with `instances` instances started together
// (FX_TEST_INSTANCES) and, under the first, the subagents `subs`, which the
// first instance's opening turn starts through the subagent tool. A local
// fake gateway holds each subagent's turn until the driver releases it, so
// the driver decides when one finishes work and the list reorders.
//
// `observe` reads the model's variables from what the person sees and what fx
// logs: the list is open while its hint row shows, its rows and highlight come
// from the pane (the highlighted row is drawn bold), an armed close shows its
// warning in the hint row, and the agent on screen is the last one the trace
// log's `agent_switched` names. The model names instances i1, i2, ... in
// launch order and subagents by their own names. An instance's row is named
// `main` or `fx N` by its place among the open instances, so the k-th instance
// row is the k-th open instance.
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../lib/context";

export const NONE = "none";
export const LIST_HINT = "enter switch";
export const ARMED_HINT = "press delete again to close this";

export type State = {
  order: string[];
  onScreen: string;
  open: boolean;
  sel: string;
  armed: string;
  act: string;
};

export type WorldOptions = { instances: number; subs: string[]; width?: number; height?: number; label: string };

/// A seeded, replayable random source (mulberry32).
export function seeded(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function held() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => (release = resolve));
  return { promise, release };
}

function userTexts(body: string): string[] {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  return (request.prompt ?? []).filter((message) => message.role === "user").map((message) => {
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";
    return message.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
  });
}

/// The list's rows from a capture with escapes: each row's name and whether
/// it is drawn selected, as tests/e2e/tui-host-instances.test.ts reads them.
export function listRows(paneEscapes: string): Array<{ name: string; instance: boolean; selected: boolean }> {
  const rows: Array<{ name: string; instance: boolean; selected: boolean }> = [];
  for (const line of paneEscapes.split("\n")) {
    const plain = line.replace(/\x1b\[[0-9;]*m/g, "");
    const row = /^ {2}(?:(fx \d+|main)|(?:[\u2502 ] )?[\u251c\u2514] (\S+)) {2,}\S/.exec(plain);
    if (row) rows.push({ name: (row[1] ?? row[2])!, instance: row[1] !== undefined, selected: line.includes("\x1b[1m") });
  }
  return rows;
}

export class World {
  readonly instances: string[];
  readonly subs: string[];
  /// The instances still open, in launch order.
  alive: string[];
  /// Subagents whose turn the gateway still holds.
  working: Set<string>;
  /// fx's agent id for each model name, learned in `calibrate`.
  ids = new Map<string, string>();
  names = new Map<string, string>();
  state!: State;
  readonly log: string;
  private session: any;
  private gateway: any;
  private home = "";
  private workspace = "";
  private holds = new Map<string, ReturnType<typeof held>>();
  private traceMark = 0;
  steps: State[] = [];

  constructor(readonly options: WorldOptions, readonly out: string) {
    this.instances = Array.from({ length: options.instances }, (_, i) => `i${i + 1}`);
    this.subs = options.subs;
    this.alive = [...this.instances];
    this.working = new Set(options.subs);
    for (const sub of options.subs) this.holds.set(sub, held());
    mkdirSync(out, { recursive: true });
    this.log = join(out, `${options.label}.log`);
  }

  note(line: string) {
    appendFileSync(this.log, `${line}\n`);
  }

  get tracePath() {
    return join(this.home, "fx-trace.log");
  }

  async start() {
    const helpers = await targetHelpers();
    const evals = await import(join(worktree, "tests", "evals", "eval-helpers.ts"));
    const { fakeGatewaySse, startDynamicFakeGateway, FAKE_GATEWAY_MODEL, TmuxSession } = helpers;
    const text = (id: string, delta: string) => fakeGatewaySse([
      { type: "text-delta", id, delta },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]);
    const toolCall = (id: string, input: object) => fakeGatewaySse([
      { type: "tool-call", toolCallId: id, toolName: "subagent", input },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
    this.gateway = startDynamicFakeGateway(async (body: string) => {
      const users = userTexts(body);
      if (users.some((user) => user.includes("AM_USER"))) {
        if ((users.at(-1) ?? "").includes('"child_id"')) return text("am_saw", "AM_MAIN_SAW");
        for (const sub of this.subs) {
          if (!body.includes(`"am_spawn_${sub}"`)) {
            return toolCall(`am_spawn_${sub}`, { request: { action: "message", agent: sub, message: `AM_TASK_${sub} wait` } });
          }
        }
        return text("am_ready", "AM_SEEN_i1");
      }
      for (const sub of this.subs) {
        if (users.some((user) => user.includes(`AM_TASK_${sub}`))) {
          await this.holds.get(sub)!.promise;
          return text(`am_done_${sub}`, `AM_DONE_${sub}`);
        }
      }
      return text("am_other", "AM_OTHER");
    });
    this.home = evals.createIsolatedTestHome();
    this.workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-agents-menu-")));
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    this.session = await TmuxSession.create({
      cmd: binary,
      cwd: this.workspace,
      env: {
        HOME: this.home,
        AI_GATEWAY_API_KEY: "fake-agents-menu-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_TRACE_LOG: this.tracePath,
        ...(this.options.instances > 1 ? { FX_TEST_INSTANCES: String(this.options.instances) } : {}),
      },
      width: this.options.width ?? 120,
      height: this.options.height ?? 50,
    });
    await this.session.waitForComposer(30_000);
    if (this.subs.length > 0) {
      await this.session.sendText("AM_USER start your subagents");
      await this.session.waitForText("AM_SEEN_i1", 60_000);
      await this.session.waitForComposer(30_000);
    }
  }

  async stop() {
    for (const hold of this.holds.values()) hold.release();
    try {
      await this.session?.kill();
    } finally {
      this.gateway?.stop();
      const evals = await import(join(worktree, "tests", "evals", "eval-helpers.ts"));
      if (this.home) evals.cleanupIsolatedTestHome(this.home);
      if (this.workspace) rmSync(this.workspace, { recursive: true, force: true });
    }
  }

  private trace(): string[] {
    return existsSync(this.tracePath) ? readFileSync(this.tracePath, "utf8").split("\n") : [];
  }

  /// fx's id for the agent each `agent_switched` names, last first.
  private switchedIds(lines = this.trace()): string[] {
    const ids: string[] = [];
    for (const line of lines) {
      const match = /event=agent_switched agent=(\S+)/.exec(line);
      if (match) ids.push(match[1]!);
    }
    return ids;
  }

  private onScreen(): string {
    const last = this.switchedIds().at(-1);
    if (last === undefined) return "i1";
    const name = this.names.get(last);
    if (!name) throw new Error(`fx switched to agent ${last}, which no row named`);
    return name;
  }

  async keys(...keys: string[]) {
    for (const key of keys) await this.session.sendKeys(key);
  }

  /// Waits until a trace event in `events` lands after the last mark, or
  /// `ms` passes, then until the pane holds still.
  async settle(events: string[], ms = 3_000) {
    const deadline = Date.now() + ms;
    while (events.length > 0 && Date.now() < deadline) {
      const lines = this.trace();
      if (lines.slice(this.traceMark).some((line) => events.some((event) => line.includes(`event=${event}`)))) break;
      await Bun.sleep(20);
    }
    let last = "";
    for (let quiet = 0; quiet < 3 && Date.now() < deadline + 3_000;) {
      const now = await this.session.capturePaneEscapes();
      quiet = now === last ? quiet + 1 : 0;
      last = now;
      await Bun.sleep(40);
    }
  }

  mark() {
    this.traceMark = this.trace().length;
  }

  /// The model's variables as the binary shows them now.
  async observe(act: string): Promise<State> {
    const escapes: string = await this.session.capturePaneEscapes();
    const plain = escapes.replace(/\x1b\[[0-9;]*m/g, "");
    const open = plain.includes(LIST_HINT) || plain.includes(ARMED_HINT);
    let order = this.state?.order ?? [];
    let sel = NONE;
    if (open) {
      const rows = listRows(escapes);
      const instanceRows = rows.filter((row) => row.instance).length;
      if (instanceRows !== this.alive.length) {
        throw new Error(`the list shows ${instanceRows} instance rows while ${this.alive.length} are open:\n${plain}`);
      }
      let k = 0;
      order = rows.map((row) => (row.instance ? this.alive[k++]! : row.name));
      const selected = rows.findIndex((row) => row.selected);
      sel = selected < 0 ? NONE : order[selected]!;
    }
    const armed = open && plain.includes(ARMED_HINT) ? sel : NONE;
    return { order, onScreen: this.onScreen(), open, sel, armed, act };
  }

  /// Learns fx's id for every agent by switching to each row with Enter,
  /// then comes back to the first instance with the list closed. Runs
  /// before a trace starts, so the walk itself never relies on it.
  async calibrate(): Promise<string[]> {
    this.names.set("main", "i1");
    this.ids.set("i1", "main");
    await this.keys("C-x");
    await this.session.waitForText(LIST_HINT, 10_000);
    const first = listRows(await this.session.capturePaneEscapes());
    let k = 0;
    const order = first.map((row) => (row.instance ? this.alive[k++]! : row.name));
    await this.keys("Escape");
    await this.session.waitForPane((pane: string) => !pane.includes(LIST_HINT), 10_000);
    for (let index = 1; index < order.length; index += 1) {
      const before = this.switchedIds().length;
      await this.keys("C-x");
      await this.session.waitForText(LIST_HINT, 10_000);
      await this.moveTo(index);
      await this.keys("Enter");
      const deadline = Date.now() + 10_000;
      for (;;) {
        const ids = this.switchedIds();
        if (ids.length > before) {
          const id = ids.at(-1)!;
          this.ids.set(order[index]!, id);
          this.names.set(id, order[index]!);
          break;
        }
        if (Date.now() > deadline) throw new Error(`no agent_switched after Enter on ${order[index]}`);
        await Bun.sleep(20);
      }
      await this.session.waitForPane((pane: string) => !pane.includes(LIST_HINT), 10_000);
    }
    // Back to the first instance.
    await this.keys("C-x");
    await this.session.waitForText(LIST_HINT, 10_000);
    await this.moveTo(0);
    await this.keys("Enter");
    await this.session.waitForPane((pane: string) => !pane.includes(LIST_HINT), 10_000);
    await this.settle([], 1_000);
    this.note(`calibrated ids: ${JSON.stringify(Object.fromEntries(this.ids))}`);
    this.state = { order, onScreen: "i1", open: false, sel: NONE, armed: NONE, act: "init" };
    if (this.onScreen() !== "i1") throw new Error(`calibration left ${this.onScreen()} on screen`);
    this.steps = [this.state];
    return order;
  }

  /// Moves the open list's highlight to row `index`, from wherever it opened.
  private async moveTo(index: number) {
    const from = listRows(await this.session.capturePaneEscapes()).findIndex((row) => row.selected);
    if (from < 0) throw new Error("the open list highlights no row");
    for (let step = from; step < index; step += 1) await this.keys("Down");
    for (let step = from; step > index; step -= 1) await this.keys("Up");
    await this.waitSelectedIndex(index);
  }

  private async waitSelectedIndex(index: number) {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const rows = listRows(await this.session.capturePaneEscapes());
      if (rows.findIndex((row) => row.selected) === index) return;
      if (Date.now() > deadline) {
        const pane = (await this.session.capturePane()) as string;
        throw new Error(`the list never highlighted row ${index + 1}; rows ${JSON.stringify(rows)}:\n${pane}`);
      }
      await Bun.sleep(20);
    }
  }

  /// Lets subagent `sub`'s held turn finish.
  release(sub: string) {
    this.holds.get(sub)?.release();
    this.working.delete(sub);
  }

  /// Waits until the open list shows subagent `sub` no longer working.
  async waitIdle(sub: string, ms = 15_000) {
    const deadline = Date.now() + ms;
    for (;;) {
      const plain = (await this.session.capturePane()) as string;
      const row = plain.split("\n").find((line) => new RegExp(`^ {2}[\\u251c\\u2514] ${sub} {2,}`).test(line));
      if (row && !/ {2,}working(?: {2,}|$)/.test(row)) return;
      if (!row && !plain.includes(LIST_HINT) && !plain.includes(ARMED_HINT)) return;
      if (Date.now() > deadline) throw new Error(`${sub} never finished:\n${plain}`);
      await Bun.sleep(40);
    }
  }

  /// Records `next` as the world's new state, and a step when it changed.
  record(next: State) {
    const same = JSON.stringify({ ...next, act: "" }) === JSON.stringify({ ...this.state, act: "" });
    this.state = next;
    if (!same || next.act !== this.steps.at(-1)!.act) this.steps.push(next);
    this.note(`${next.act.padEnd(11)} ${JSON.stringify({ order: next.order, onScreen: next.onScreen, open: next.open, sel: next.sel, armed: next.armed })}`);
  }

  async capture(): Promise<string> {
    return (await this.session.capturePane()) as string;
  }
}

/// One step of the person or the environment, and the trace events that
/// mark it done.
export const STEP_EVENTS: Record<string, string[]> = {
  open: ["agents_menu_opened"],
  down: ["agents_menu_moved", "agents_menu_previewed"],
  up: ["agents_menu_moved", "agents_menu_previewed"],
  enter: ["agents_menu_chosen"],
  back: ["agents_menu_back", "agents_menu_closed"],
  arm: ["agents_menu_close_armed"],
  delete: ["subagent_closed", "instance_closed"],
};

/// Performs one model action on the binary and returns what it shows after.
export async function perform(world: World, act: string, random: () => number): Promise<State> {
  world.mark();
  switch (act) {
    case "open": await world.keys(random() < 0.5 ? "C-x" : "Down"); break;
    case "down": await world.keys("Down"); break;
    case "up": await world.keys("Up"); break;
    case "enter": await world.keys("Enter"); break;
    case "back": await world.keys(random() < 0.5 ? "Escape" : "C-x"); break;
    case "arm": await world.keys("BSpace"); break;
    case "delete": {
      const target = world.state.sel;
      await world.keys("BSpace");
      if (world.instances.includes(target)) {
        world.alive = world.alive.filter((id) => id !== target);
        // Its subagents close with it; every subagent here is the first's.
        if (target === "i1") world.working.clear();
      }
      world.working.delete(target);
      break;
    }
    default: throw new Error(`no binary step for ${act}`);
  }
  await world.settle(STEP_EVENTS[act] ?? []);
  return await world.observe(act);
}

/// TraceData.tla for TLC: the world's constants and every recorded trace.
export function traceModule(world: World, traces: State[][]): string {
  const str = (value: string) => JSON.stringify(value);
  const seq = (items: string[]) => `<<${items.map(str).join(", ")}>>`;
  const state = (s: State) =>
    `[order |-> ${seq(s.order)}, onScreen |-> ${str(s.onScreen)}, open |-> ${s.open ? "TRUE" : "FALSE"}, sel |-> ${str(s.sel)}, armed |-> ${str(s.armed)}, act |-> ${str(s.act)}]`;
  return [
    "---- MODULE TraceData ----",
    "\\* Written by tests/tla/drivers/agents_menu/binary-to-spec.ts for one run.",
    "EXTENDS Sequences",
    `TraceInstanceOrder == ${seq(world.instances)}`,
    `TraceSubs == {${world.subs.map(str).join(", ")}}`,
    `TraceParent == [s \\in TraceSubs |-> "i1"]`,
    `TraceInitOrder == ${seq(traces[0]![0]!.order)}`,
    "Traces == <<",
    traces.map((trace) => `  <<\n${trace.map((s) => `    ${state(s)}`).join(",\n")}\n  >>`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
}
