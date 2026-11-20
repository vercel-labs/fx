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
// warning in the hint row, the composer holds a search while the hint row
// offers `esc clear`, and the agent on screen is the last one the trace log's
// `agent_switched` names.
// With a search, the rows are the matches, and the ones the search hides are
// the open agents the last full list showed and the pane does not. With no
// match there is no row, so the highlight is the agent on screen, as the model
// keeps it. The agent the list opened on, which Esc goes back to, is what was
// on screen when it opened, until it closes. `run` and `pressed` are the one
// part no pane shows: which close key, Backspace ("bs") or forward Delete
// ("del"), the driver pressed last, and whose run of presses has edited the
// search since another key. They come from the keys the driver sends, so TLC
// checks what the binary did against what was pressed.
// The model names instances i1, i2, ... in launch order and subagents by their
// own names. An instance's row is named `fx N` by its place among the open
// instances, or `main` when it is the only one.
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../lib/context";

export const NONE = "none";
export const LIST_HINT = "enter switch";
export const ARMED_HINT = "press delete again to close this";
/// The hint row while the composer, the list's search box, holds a search.
export const SEARCH_HINT = "esc clear";

export type State = {
  order: string[];
  onScreen: string;
  open: boolean;
  sel: string;
  armed: string;
  origin: string;
  searching: boolean;
  hidden: string[];
  /// The close key whose run has edited the search, or NONE.
  run: string;
  /// The close key the step pressed, or NONE.
  pressed: string;
  act: string;
};

/// The close keys: Backspace and forward Delete.
export type CloseKey = "bs" | "del";
export const CLOSE_KEYS: CloseKey[] = ["bs", "del"];
const KEY_NAMES: Record<CloseKey, string> = { bs: "BSpace", del: "DC" };

/// Letters a search types: each is in some agent's name, title, or purpose
/// (a subagent's purpose is its task, `AM_TASK_<name> wait`) and not in others'.
export const SEARCH_LETTERS = ["a", "b", "e", "f", "g", "l", "m", "p", "t", "x", "z"];

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

/// Each row's state as the open list draws it, "working" or "idle": a
/// subagent that finished counts as idle whether or not the person has seen it
/// (the list calls that "finished"). Any other state, such as one that waits
/// for an approval, or one whose last turn failed or was stopped, is an error
/// here, since the drivers that read it start no such agent.
export function listStates(paneEscapes: string): Array<{ name: string; instance: boolean; state: "working" | "idle" }> {
  const rows: Array<{ name: string; instance: boolean; state: "working" | "idle" }> = [];
  for (const line of paneEscapes.split("\n")) {
    const plain = line.replace(/\x1b\[[0-9;]*m/g, "");
    const row = /^ {2}(?:(fx \d+|main)|(?:[\u2502 ] )?[\u251c\u2514] (\S+)) {2,}\S(.*)$/.exec(plain);
    if (!row) continue;
    const state = /(?: {2,})(working|idle|finished|failed|stopped|needs approval|has a question|needs you)(?: {2,}|$)/.exec(row[3] ?? "")?.[1];
    if (state === undefined) continue;
    if (state !== "working" && state !== "idle" && state !== "finished") throw new Error(`the list shows a row in state "${state}": ${plain}`);
    rows.push({ name: (row[1] ?? row[2])!, instance: row[1] !== undefined, state: state === "working" ? "working" : "idle" });
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
  /// The length of the draft each agent's composer holds from pastes.
  private drafts = new Map<string, number>();
  steps: State[] = [];
  /// How many letters the search box holds, as the driver typed and erased
  /// them, so a held key can clear it and go on.
  searchLength = 0;

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

  /// The model name of an instance row named `name`: `fx N` is the N-th
  /// open instance, and `main` the only one.
  private instanceOf(name: string): string {
    const number = name === "main" ? 1 : Number(name.slice(3));
    const id = this.alive[number - 1];
    if (!id) throw new Error(`no open instance for the row ${name}; open: ${this.alive.join(", ")}`);
    return id;
  }

  /// The model's variables as the binary shows them now.
  async observe(act: string): Promise<State> {
    const escapes: string = await this.session.capturePaneEscapes();
    const plain = escapes.replace(/\x1b\[[0-9;]*m/g, "");
    const open = plain.includes(LIST_HINT) || plain.includes(ARMED_HINT);
    const searching = open && plain.includes(SEARCH_HINT);
    const onScreen = this.onScreen();
    let order = this.state?.order ?? [];
    let sel = NONE;
    let hidden: string[] = [];
    if (open) {
      const rows = listRows(escapes);
      const shown = rows.map((row) => (row.instance ? this.instanceOf(row.name) : row.name));
      if (searching) {
        // The search hides rows only; the full order is the last one shown.
        if (shown.some((name) => !order.includes(name)) || shown.join() !== order.filter((name) => shown.includes(name)).join()) {
          throw new Error(`the search shows ${JSON.stringify(shown)}, not a part of ${JSON.stringify(order)}:\n${plain}`);
        }
        hidden = order.filter((name) => !shown.includes(name));
      } else {
        const instanceRows = rows.filter((row) => row.instance).length;
        if (instanceRows !== this.alive.length) {
          throw new Error(`the list shows ${instanceRows} instance rows while ${this.alive.length} are open:\n${plain}`);
        }
        order = shown;
      }
      const selected = rows.findIndex((row) => row.selected);
      if (selected >= 0) sel = shown[selected]!;
      else if (shown.length === 0) sel = onScreen;
    }
    const armed = open && plain.includes(ARMED_HINT) ? sel : NONE;
    const before = this.state?.origin ?? NONE;
    const origin = !open ? NONE : act === "open" ? onScreen : order.includes(before) ? before : NONE;
    // A step that presses a close key says so after this; any other step
    // leaves the run as it was, and a closed list has none.
    const run = open ? (this.state?.run ?? NONE) : NONE;
    return { order, onScreen, open, sel, armed, origin, searching, hidden, run, pressed: NONE, act };
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
    this.state = { order, onScreen: "i1", open: false, sel: NONE, armed: NONE, origin: NONE, searching: false, hidden: [], run: NONE, pressed: NONE, act: "init" };
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
    this.note(`${next.act.padEnd(11)} ${JSON.stringify({ order: next.order, onScreen: next.onScreen, open: next.open, sel: next.sel, armed: next.armed, origin: next.origin, searching: next.searching, hidden: next.hidden, run: next.run, pressed: next.pressed })}`);
  }

  async capture(): Promise<string> {
    return (await this.session.capturePane()) as string;
  }

  /// The pane with its escapes, as `listRows` and `listStates` read it.
  async captureEscapes(): Promise<string> {
    return (await this.session.capturePaneEscapes()) as string;
  }

  /// Pastes `text`, which closes the list and lands in the composer of the
  /// agent on screen.
  async paste(text: string) {
    await this.session.pasteText(text);
    this.drafts.set(this.state.onScreen, (this.drafts.get(this.state.onScreen) ?? 0) + text.length);
  }

  async type(text: string) {
    await this.session.sendLiteral(text);
  }

  /// Runs slash command `text` on the agent on screen, after erasing the
  /// draft a paste left there.
  async command(text: string) {
    for (let left = this.drafts.get(this.state.onScreen) ?? 0; left > 0; left -= 1) await this.session.sendKeys("BSpace");
    this.drafts.delete(this.state.onScreen);
    await this.session.waitForPane((pane: string) => !/\u00b7 ctrl\+x/.test(pane), 10_000);
    await this.session.sendText(text);
  }

  /// Whether the composer of the agent on screen holds a draft, so Down no
  /// longer opens the list.
  hasDraft(): boolean {
    return (this.drafts.get(this.state.onScreen) ?? 0) > 0;
  }
}

/// One step of the person or the environment, and the trace events that
/// mark it done.
export const STEP_EVENTS: Record<string, string[]> = {
  open: ["agents_menu_opened"],
  down: ["agents_menu_previewed"],
  up: ["agents_menu_previewed", "agents_menu_closed"],
  enter: ["agents_menu_chosen"],
  back: ["agents_menu_back"],
  close: ["agents_menu_closed"],
  search: ["agents_menu_search"],
  arm: ["agents_menu_close_armed"],
  delete: ["subagent_closed", "instance_closed"],
  // A press that goes on past an emptied search is left alone; before fx did
  // that, it armed the close instead.
  ignored: ["agents_menu_close_ignored", "agents_menu_close_armed"],
  run: ["agents_menu_search"],
  slash_close: ["instance_closed"],
};

/// Drops instance `target` and, with the first, its subagents, from what the
/// world knows is open.
function closeInstance(world: World, target: string) {
  world.alive = world.alive.filter((id) => id !== target);
  // Its subagents close with it; every subagent here is the first's.
  if (target === "i1") world.working.clear();
}

/// `key` sent `count` times in one write, as a held key repeats it: fx reads
/// them one after the other with nothing between.
function burst(key: string, count: number): string {
  return Array.from({ length: count }, () => key).join(" ");
}

/// The close key a press arms or closes with: not the one whose run has
/// edited the search, which that run would leave unpressed.
function freshCloseKey(world: World, random: () => number): CloseKey {
  const keys = CLOSE_KEYS.filter((key) => key !== world.state.run);
  return keys[Math.floor(random() * keys.length)]!;
}

/// Performs one model action on the binary and returns what it shows after.
///
/// Besides the model's steps there are two the person takes with a close key:
/// `run` holds Backspace, or Delete with the cursor at the start, down through
/// the whole search and past it, in one write; and `ignored` presses the key
/// of a run that emptied the search once more.
export async function perform(world: World, act: string, random: () => number): Promise<State> {
  world.mark();
  const before = world.state;
  // The close key the step pressed, and the run it leaves, when the step is
  // one of the close key's; any other step ends a run.
  let pressed: CloseKey | null = null;
  let run: string | null = null;
  switch (act) {
    // Down opens the list only from an empty composer.
    case "open": await world.keys(random() < 0.5 || world.hasDraft() ? "C-x" : "Down"); break;
    case "down": await world.keys("Down"); break;
    case "up": await world.keys("Up"); break;
    case "enter": await world.keys("Enter"); break;
    // Esc with a search clears it instead.
    case "back": await world.keys(random() < 0.5 && !world.state.searching ? "Escape" : "C-x"); break;
    case "close": await world.paste("am-paste "); break;
    case "search": {
      const roll = random();
      if (world.state.searching && roll < 0.25) {
        await world.keys("BSpace");
        pressed = "bs";
        run = "bs";
        world.searchLength = Math.max(0, world.searchLength - 1);
      } else if (world.state.searching && roll < 0.4) {
        await world.keys("Escape");
        world.searchLength = 0;
      } else {
        await world.type(SEARCH_LETTERS[Math.floor(random() * SEARCH_LETTERS.length)]!);
        world.searchLength += 1;
      }
      break;
    }
    case "run": {
      const key: CloseKey = random() < 0.5 ? "bs" : "del";
      const extra = 1 + Math.floor(random() * 4);
      // Delete takes text from the cursor on, so the cursor goes to the start.
      if (key === "del") await world.keys(burst("Left", world.searchLength));
      await world.keys(burst(KEY_NAMES[key], world.searchLength + extra));
      pressed = key;
      run = key;
      world.searchLength = 0;
      break;
    }
    case "ignored": {
      const key = before.run as CloseKey;
      await world.keys(KEY_NAMES[key]);
      pressed = key;
      run = key;
      break;
    }
    case "arm": {
      pressed = freshCloseKey(world, random);
      await world.keys(KEY_NAMES[pressed]);
      break;
    }
    case "delete": {
      const target = world.state.sel;
      pressed = freshCloseKey(world, random);
      await world.keys(KEY_NAMES[pressed]);
      if (world.instances.includes(target)) closeInstance(world, target);
      world.working.delete(target);
      break;
    }
    case "slash_close": {
      const target = world.state.onScreen;
      await world.command("/close");
      closeInstance(world, target);
      // The list is closed, so the pane shows no rows: the order is the last
      // full one without what closed.
      const gone = target === "i1" ? [target, ...world.subs] : [target];
      world.state = { ...world.state, order: world.state.order.filter((name) => !gone.includes(name)) };
      break;
    }
    default: throw new Error(`no binary step for ${act}`);
  }
  await world.settle(STEP_EVENTS[act] ?? []);
  // A run is a search edit to the model, whatever its length.
  const shown = await world.observe(act === "run" ? "search" : act);
  if (!shown.searching) world.searchLength = 0;
  // Every other key a step presses ends the run.
  if (pressed === null) return { ...shown, run: NONE, pressed: NONE };
  // A press that arms or closes ends the run of the other key and goes on
  // with its own; an edit or a press left alone sets it.
  const left = run ?? (before.run === pressed ? pressed : NONE);
  return { ...shown, run: shown.open ? left : NONE, pressed };
}

/// TraceData.tla for TLC: the world's constants and every recorded trace.
export function traceModule(world: World, traces: State[][]): string {
  const str = (value: string) => JSON.stringify(value);
  const seq = (items: string[]) => `<<${items.map(str).join(", ")}>>`;
  const state = (s: State) =>
    `[order |-> ${seq(s.order)}, onScreen |-> ${str(s.onScreen)}, open |-> ${s.open ? "TRUE" : "FALSE"}, sel |-> ${str(s.sel)}, armed |-> ${str(s.armed)}, origin |-> ${str(s.origin)}, searching |-> ${s.searching ? "TRUE" : "FALSE"}, hidden |-> {${s.hidden.map(str).join(", ")}}, run |-> ${str(s.run)}, pressed |-> ${str(s.pressed)}, act |-> ${str(s.act)}]`;
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
