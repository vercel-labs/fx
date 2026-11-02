// The interactive shell's sessions, driven through tmux, and what fx showed
// and saved about them: the panels `/status` and `/permissions` painted,
// read back through fx's virtual terminal (`info-panel.ts`), the id each launch, `/new`,
// `/clear`, `/resume` and `/fork` opened, from fx's wiring trace, the exit
// line, and the session folders on disk. `tui-status-session.test.ts` and
// `tests/tla/drivers/session/` use it.
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { infoPanel, panelReports, showsPanel, type InfoPanel, type PanelReport, type PanelTitle } from "./info-panel";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, heldFakeGatewayFinalText, startDynamicFakeGateway, TmuxSession } from "./tmux-helpers";

const TIMEOUT = 30_000;

export type WiringLine = { action: string; session: string; pid: number };

type Held = ReturnType<typeof heldFakeGatewayFinalText>;

/// One reply of a scripted prompt's.
type Reply = () => Response | Promise<Response>;

/// One profile, its workspace, and a fake gateway that answers each prompt
/// it was given, by the newest scripted prompt the request holds.
export class Profile {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly wiring: string;
  readonly gateway: ReturnType<typeof startDynamicFakeGateway>;
  private readonly answers = new Map<string, string>();
  private readonly held = new Map<string, Held>();
  private readonly scripted = new Map<string, Reply[]>();
  private readonly shells: Shell[] = [];
  private blocked = false;

  constructor(label: string, readonly bin: string = FX_BIN) {
    this.root = realpathSync(createIsolatedTestHome());
    this.home = join(this.root, "home");
    this.workspace = join(this.root, `workspace-${label}`);
    this.wiring = join(this.root, "wiring.log");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace);
    this.gateway = startDynamicFakeGateway((body) => {
      const prompt = [...this.answers.keys(), ...this.held.keys(), ...this.scripted.keys()]
        .map((text) => [text, body.lastIndexOf(text)] as const)
        .filter(([, at]) => at >= 0)
        .sort((a, b) => b[1] - a[1])[0]?.[0];
      if (prompt === undefined) return fakeGatewayFinalText("UNSCRIPTED PROMPT");
      const script = this.scripted.get(prompt);
      if (script) return script.shift()?.() ?? fakeGatewayFinalText("UNSCRIPTED REQUEST");
      return this.held.get(prompt)?.response ?? fakeGatewayFinalText(this.answers.get(prompt)!);
    });
  }

  /// Puts a file where `~/.fx/sessions` belongs, so no process started until
  /// `unblockStore` can create or open a session. Saved sessions wait aside
  /// and come back unchanged.
  blockStore() {
    if (this.blocked) return;
    if (existsSync(this.sessions)) renameSync(this.sessions, this.aside);
    writeFileSync(this.sessions, "not a folder\n");
    this.blocked = true;
  }

  unblockStore() {
    if (!this.blocked) return;
    rmSync(this.sessions);
    if (existsSync(this.aside)) renameSync(this.aside, this.sessions);
    this.blocked = false;
  }

  private get sessions(): string {
    return join(this.home, ".fx", "sessions");
  }

  private get aside(): string {
    return join(this.root, "sessions-set-aside");
  }

  answer(prompt: string, text: string) {
    this.answers.set(prompt, text);
  }

  /// The requests for `prompt` take `replies` in order, one each: a turn
  /// that calls a tool asks again with its result.
  script(prompt: string, replies: Reply[]) {
    this.scripted.set(prompt, [...replies]);
  }

  /// Writes the profile's `~/.fx/settings.json`.
  settings(value: object) {
    writeFileSync(join(this.home, ".fx", "settings.json"), JSON.stringify(value));
  }

  /// `prompt`'s reply waits until `release` sends `text`.
  hold(prompt: string): { release(text: string): void } {
    const held = heldFakeGatewayFinalText();
    this.held.set(prompt, held);
    return { release: (text: string) => held.release(text) };
  }

  async launch(options: { args?: string[]; width?: number; height?: number; env?: Record<string, string> } = {}): Promise<Shell> {
    const n = this.shells.length + 1;
    const shell = new Shell(this, n, await TmuxSession.create({
      cmd: [this.bin, ...(options.args ?? [])].map(shellQuote).join(" "),
      cwd: this.workspace,
      env: { ...this.env(join(this.root, `shell-${n}.fxtape`)), ...options.env },
      stderrPath: join(this.root, `shell-${n}.stderr`),
      width: options.width ?? 120,
      height: options.height ?? 48,
      remainOnExit: true,
    }));
    this.shells.push(shell);
    await shell.session.waitForStableComposer(TIMEOUT);
    shell.pid = shell.session.processPid();
    return shell;
  }

  env(tape: string): Record<string, string | undefined> {
    return {
      HOME: this.home,
      AI_GATEWAY_API_KEY: "status-session-fixture",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      FX_RECORD: tape,
      FX_RECORD_INPUT: "1",
      FX_TRACE_LOG: this.wiring,
      FX_TRACE_SCOPES: "wiring",
    };
  }

  /// Every `[wiring]` line fx wrote, in order.
  wiringLines(): WiringLine[] {
    if (!existsSync(this.wiring)) return [];
    return readFileSync(this.wiring, "utf8").split("\n").flatMap((line) => {
      const match = /\[wiring\] action=(\S+) session=(\S+)(?: .*)? pid=(\d+)$/.exec(line);
      return match ? [{ action: match[1]!, session: match[2]!, pid: Number(match[3]) }] : [];
    });
  }

  /// Each saved session's id and the turns its log holds, as the store left
  /// them on disk.
  disk(): Record<string, number> {
    const store = join(this.blocked ? this.aside : this.sessions, "v2");
    if (!existsSync(store) || !statSync(store).isDirectory()) return {};
    const saved: Record<string, number> = {};
    for (const id of readdirSync(store).sort()) {
      const log = join(store, id, "log.jsonl");
      if (id.startsWith(".") || !existsSync(log)) continue;
      const text = readFileSync(log, "utf8");
      // Only whole lines: fx may still be appending.
      const lines = text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean);
      saved[id] = lines.filter((line) => JSON.parse(line).kind === "turn_started").length;
    }
    return saved;
  }

  /// Whether a later fx opens session `id`, as `fx --resume <id>` would.
  async resumable(id: string): Promise<boolean> {
    const result = Bun.spawnSync([this.bin, "session", "--id", id, "--json"], {
      cwd: this.workspace,
      env: { PATH: process.env.PATH ?? "", HOME: this.home, FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1" },
      stdout: "pipe",
      stderr: "pipe",
      timeout: TIMEOUT,
    });
    return result.exitCode === 0 && JSON.parse(result.stdout.toString()).id === id;
  }

  /// Ends every shell and the gateway. Keeps the files when `keep` is set.
  async close(keep: boolean) {
    for (const shell of this.shells) await shell.session.kill().catch(() => {});
    this.gateway.stop();
    if (keep) console.error(`retained status session artifacts at ${this.root}`);
    else cleanupIsolatedTestHome(this.root);
  }
}

/// One fx process of a profile.
export class Shell {
  pid = 0;
  readonly tape: string;
  readonly stderr: string;
  private readonly panelsShown: Record<PanelTitle, number> = { Status: 0, Permissions: 0 };

  constructor(readonly profile: Profile, readonly n: number, readonly session: TmuxSession) {
    this.tape = join(profile.root, `shell-${n}.fxtape`);
    this.stderr = join(profile.root, `shell-${n}.stderr`);
  }

  /// The sessions this process opened, in order: each `Open` and `Fork`.
  opened(): string[] {
    return this.profile.wiringLines()
      .filter((line) => line.pid === this.pid && (line.action === "Open" || line.action === "Fork"))
      .map((line) => line.session);
  }

  /// The session this process opened last, or null when it opened none.
  current(): string | null {
    return this.opened().at(-1) ?? null;
  }

  /// Sends a prompt and waits for its answer.
  async prompt(text: string, answer: string) {
    this.profile.answer(text, answer);
    const before = this.profile.gateway.requests.length;
    await this.session.sendText(text);
    await this.waitUntil(() => this.profile.gateway.requests.length > before, `the request for ${text}`);
    await this.session.waitForText(answer, TIMEOUT);
    await this.session.waitForStableComposer(TIMEOUT);
  }

  /// Sends a prompt whose reply is held, and waits until fx asked for it.
  async begin(text: string): Promise<{ release(answer: string): Promise<void> }> {
    const held = this.profile.hold(text);
    const before = this.profile.gateway.requests.length;
    await this.session.sendText(text);
    await this.waitUntil(() => this.profile.gateway.requests.length > before, `the request for ${text}`);
    return {
      release: async (answer: string) => {
        held.release(answer);
        await this.session.waitForText(answer, TIMEOUT);
        await this.session.waitForStableComposer(TIMEOUT);
      },
    };
  }

  /// Opens the `/status` panel; see `panel`.
  async status(options: { scroll?: number } = {}): Promise<InfoPanel> {
    return this.panel("Status", options);
  }

  /// Opens the `/permissions` panel; see `panel`.
  async permissions(options: { scroll?: number } = {}): Promise<InfoPanel> {
    return this.panel("Permissions", options);
  }

  /// Opens the panel titled `title`, waits until it has settled, presses ↓
  /// `scroll` times, and closes it with Esc. A Ctrl-U, which changes nothing
  /// in an empty composer, then marks on the tape where the closed shell was
  /// painted. `reports` reads each panel back from the tape; this returns
  /// the panel as the live pane showed it when it opened, for a step that
  /// needs what it showed. Fails when the panel's text stayed in the
  /// terminal.
  async panel(title: PanelTitle, options: { scroll?: number } = {}): Promise<InfoPanel> {
    await this.session.sendKeys("C-u");
    await settled(this.session);
    await this.session.sendText(title === "Status" ? "/status" : "/permissions");
    await this.waitUntilAsync(async () => showsPanel(lines(await this.session.capturePane()), title), `the ${title} panel`);
    const opened = infoPanel(lines(await settled(this.session)), title, this.session.paneSize().cols);
    if (!opened) throw new Error(`the ${title} panel did not parse:\n${(await this.session.capturePane()).trimEnd()}`);
    for (let n = 0; n < (options.scroll ?? 0); n++) {
      await this.session.sendKeys("Down");
      await settled(this.session);
    }
    await this.session.sendKeys("Escape");
    await this.waitUntilAsync(async () => !showsPanel(lines(await this.session.capturePane()), title), `the ${title} panel to close`);
    await settled(this.session);
    await this.session.sendKeys("C-u");
    this.panelsShown[title]++;
    const own = title === "Status" ? /^ {2}Session grants {2,}\S/ : /^ {2}Change mode {2,}\S/;
    const left = lines(await this.session.captureFullScrollback()).filter((line) => own.test(line));
    if (left.length > 0) throw new Error(`the ${title} panel left its text in the terminal: ${left.join(" | ")}`);
    return opened;
  }

  /// How many `/status` panels this process was asked for.
  statusCount(): number {
    return this.panelsShown.Status;
  }

  /// Sends a slash command and waits for the composer, for a command that
  /// opens no session, such as `/new` in a shell without a store.
  async command(text: string) {
    await this.session.sendKeys("C-u");
    await this.session.sendText(text);
    await this.session.waitForStableComposer(TIMEOUT);
    await settled(this.session);
  }

  /// `/new` or `/clear`, and the session it opened.
  async newSession(command: "/new" | "/clear"): Promise<string> {
    return this.switching(async () => {
      await this.session.sendKeys("C-u");
      await this.session.sendText(command);
    }, "Open");
  }

  /// `/resume`, filtered to the one session whose title holds `title`.
  async resume(title: string): Promise<string> {
    return this.switching(async () => {
      await this.session.sendKeys("C-u");
      await this.session.sendText("/resume");
      await this.session.waitForPane((pane) => pane.includes("Sessions") && /\[(Current|All) workspaces?\]/.test(pane), TIMEOUT);
      await this.session.sendLiteralText(title);
      await this.session.waitForPane((pane) => pane.includes("Sessions 1"), TIMEOUT);
      await this.session.sendKeys("Enter");
      await this.session.waitForText("session resumed", TIMEOUT);
    }, "Open");
  }

  /// `/fork` with the prompt `up` rows above the newest selected, and the
  /// fork it opened. The fork's prompt is left out of the composer.
  async fork(up: number): Promise<string> {
    return this.switching(async () => {
      await this.session.sendKeys("C-u");
      await this.session.sendText("/fork");
      await this.session.waitForText("enter fork", TIMEOUT);
      for (let n = 0; n < up; n++) await this.session.sendKeys("Up");
      await this.session.sendKeys("Enter");
      await this.session.waitForText("session forked", TIMEOUT);
      await settled(this.session);
      await this.session.sendKeys("C-u");
    }, "Fork");
  }

  /// `/quit`, and the id the exit line named, or null when it named none.
  /// A terminal too narrow for one row puts the command on the next one.
  async quit(): Promise<string | null> {
    await this.session.sendKeys("C-u");
    await this.session.sendText("/quit");
    await this.waitUntil(() => this.session.paneStatus().dead, "fx to exit");
    const text = (await this.session.captureFullScrollback()).split("\n").map((line) => line.trim()).join("\n");
    const named = [...text.matchAll(/^Continue session with:[ \n]fx --resume (\S+)$/gm)].map((match) => match[1]!);
    if (named.length > 1) throw new Error(`the exit line named ${named.length} sessions: ${named}`);
    if (named.length === 0 && text.includes("Continue session with:")) throw new Error(`an exit line fx printed did not parse:\n${text}`);
    return named[0] ?? null;
  }

  /// Kills the process without a chance to write anything.
  async crash() {
    process.kill(this.pid, "SIGKILL");
    await this.waitUntil(() => this.session.paneStatus().dead, "fx to die");
  }

  /// Every panel titled `title` this process painted, read through fx's
  /// virtual terminal. Call it once the process has ended.
  reports(title: PanelTitle = "Status"): PanelReport[] {
    const frames = join(this.profile.root, `shell-${this.n}-${title.toLowerCase()}.frames`);
    const reports = panelReports(this.profile.bin, this.tape, frames, title);
    if (reports.length !== this.panelsShown[title]) {
      throw new Error(`shell ${this.n} opened the ${title} panel ${this.panelsShown[title]} times, but its tape holds ${reports.length}`);
    }
    return reports;
  }

  stderrText(): string {
    return readFileSync(this.stderr, "utf8");
  }

  private async switching(act: () => Promise<void>, action: "Open" | "Fork"): Promise<string> {
    const before = this.profile.wiringLines().filter((line) => line.pid === this.pid && line.action === action).length;
    await act();
    await this.waitUntil(
      () => this.profile.wiringLines().filter((line) => line.pid === this.pid && line.action === action).length > before,
      `a wiring ${action}`,
    );
    await this.session.waitForStableComposer(TIMEOUT);
    return this.current()!;
  }

  private async waitUntil(condition: () => boolean, what: string) {
    await this.waitUntilAsync(async () => condition(), what);
  }

  private async waitUntilAsync(condition: () => Promise<boolean>, what: string) {
    const deadline = Date.now() + TIMEOUT;
    while (Date.now() < deadline) {
      if (await condition()) return;
      await Bun.sleep(25);
    }
    throw new Error(`timed out waiting for ${what}:\n${(await this.session.capturePane()).trimEnd()}`);
  }
}

function lines(text: string): string[] {
  return text.split("\n");
}

/// The pane once it has stopped changing for 300 ms.
async function settled(session: TmuxSession): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let previous = "", since = Date.now();
  while (Date.now() < deadline) {
    const pane = await session.capturePane();
    if (pane !== previous) [previous, since] = [pane, Date.now()];
    else if (Date.now() - since >= 300) return pane;
    await Bun.sleep(25);
  }
  throw new Error(`pane never settled:\n${previous}`);
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
