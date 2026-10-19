// Shared runtime bridge for the permission-mode bundle: an ACP stdio client
// that declines permission requests, an isolated fx home and fake Gateway,
// the client-visible projection of the mode option, the profile's saved
// mode, and a prompt probe that shows how fx enforced the current mode.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ------------------------------------------------------------ observation --

/// What a client sees of the mode setting in one response. `legacy` and
/// `legacyListed` come from the older `modes` field; responses without it
/// (set_config_option) report "n/a".
export type View = {
  current: string;
  legacy: string;
  listed: string;
  legacyListed: string;
  names: string;
  schemaOk: boolean;
};

export type Observation = {
  op: string;
  arg: string;
  ok: boolean;
  hasView: boolean;
  view: View;
  enforce: string;
  stored: string;
  detail?: unknown;
};

export const NO_VIEW: View = { current: "", legacy: "", listed: "", legacyListed: "", names: "", schemaOk: true };

// The ACP schema's fields for a select value (session config options).
const VALUE_KEYS = new Set(["value", "name", "description", "_meta"]);

function flatValues(options: unknown): any[] {
  if (!Array.isArray(options)) return [];
  return options.flatMap((entry: any) => (Array.isArray(entry?.options) ? entry.options : [entry]));
}

export function viewOf(result: any): View | null {
  const configOptions = result?.configOptions;
  if (!Array.isArray(configOptions)) return null;
  const mode = configOptions.find((option: any) => option?.id === "mode");
  if (!mode || typeof mode.currentValue !== "string") return null;
  const values = flatValues(mode.options);
  const modes = result?.modes;
  return {
    current: mode.currentValue,
    legacy: modes === undefined ? "n/a" : String(modes?.currentModeId ?? "missing"),
    listed: values.map((value) => String(value?.value)).join(","),
    legacyListed: modes === undefined ? "n/a" : (modes?.availableModes ?? []).map((entry: any) => String(entry?.id)).join(","),
    names: values.map((value) => String(value?.name)).join(","),
    schemaOk:
      mode.type === "select" &&
      mode.category === "mode" &&
      values.every((value) => value && Object.keys(value).every((key) => VALUE_KEYS.has(key))),
  };
}

/// The profile's saved permission mode, in the CLI's names.
export function storedMode(home: string): string {
  const path = join(home, ".fx", "settings.json");
  if (!existsSync(path)) return "unset";
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"))?.permission_mode;
  } catch {
    return "unreadable";
  }
  if (raw === undefined || raw === null) return "unset";
  const value = String(raw).toLowerCase();
  if (value === "ask" || value === "auto") return value;
  if (value === "yolo" || value === "full-access" || value === "full access") return "full-access";
  return `raw:${value}`;
}

// -------------------------------------------------------------- ACP client --

export class Acp {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private nextId = 1;
  stderr = "";
  permissionRequests = 0;
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly log: (entry: object) => void) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      for (const waiter of this.waiters.splice(0)) waiter("");
      return code;
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) {
          if (!line.trim()) continue;
          const waiter = this.waiters.shift();
          if (waiter) waiter(line);
          else this.lines.push(line);
        }
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  private async readLine(): Promise<any> {
    const buffered = this.lines.shift();
    if (buffered) return JSON.parse(buffered);
    if (this.closed) throw new Error(`fx acp exited: ${this.stderr.slice(-400)}`);
    const line = await new Promise<string>((resolveLine, reject) => {
      const timer = setTimeout(() => reject(new Error(`fx acp read timeout: ${this.stderr.slice(-400)}`)), 30_000);
      this.waiters.push((value) => {
        clearTimeout(timer);
        resolveLine(value);
      });
    });
    if (!line) throw new Error(`fx acp exited: ${this.stderr.slice(-400)}`);
    return JSON.parse(line);
  }

  private send(message: object) {
    (this.proc.stdin as any).write(`${JSON.stringify(message)}\n`);
    (this.proc.stdin as any).flush?.();
  }

  async call(method: string, params: Record<string, unknown>): Promise<any> {
    const id = this.nextId++;
    this.log({ dir: "out", id, method, params });
    this.send({ jsonrpc: "2.0", id, method, params });
    while (true) {
      const message = await this.readLine();
      if ("method" in message && "id" in message) {
        // Agent-to-client request. Permission requests are declined with the
        // reject option fx offers, so an "ask" turn never runs the tool.
        if (message.method === "session/request_permission") {
          this.permissionRequests += 1;
          const options: any[] = message.params?.options ?? [];
          const reject = options.find((option) => String(option?.kind ?? "").startsWith("reject"));
          this.log({ dir: "in-request", method: message.method, options: options.map((option) => option?.kind), chose: reject?.optionId ?? "cancelled" });
          this.send({
            jsonrpc: "2.0",
            id: message.id,
            result: { outcome: reject ? { outcome: "selected", optionId: reject.optionId } : { outcome: "cancelled" } },
          });
        } else {
          this.log({ dir: "in-request", method: message.method, answered: "error" });
          this.send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
        }
        continue;
      }
      if (message.id === id) {
        this.log({ dir: "in", id, method, error: message.error ?? null, result: message.result ?? null });
        return message;
      }
    }
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

// -------------------------------------------------------------- fx fixture --

type Helpers = {
  startDynamicFakeGateway: (respond: (body: string) => Response, options: object) => any;
  fakeGatewayFinalText: (text: string) => Response;
  fakeShellRun: (id: string, command: string, options?: Record<string, unknown>) => Response;
};

export async function loadHelpers(worktree: string): Promise<Helpers> {
  return (await import(join(worktree, "tests", "e2e", "tmux-helpers.ts"))) as Helpers;
}

// Process overrides that would mask what the profile and ACP decide.
const STRIPPED_ENV = [
  "VERCEL_OIDC_TOKEN", "FX_PROVIDER", "FX_MODEL", "FX_FAST", "FX_ULTRAFAST",
  "FX_PERMISSION_MODE", "FX_DEBUG_RECORD", "FX_SESSIONS_V2",
];

/// An isolated fx home, workspace and fake Gateway for one run. `profile` is
/// the saved permission_mode the run starts from ("unset" leaves it out).
export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly acpLog: object[] = [];
  readonly gatewayLog: object[] = [];
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  private readonly gateway: any;
  private probe: { id: string; marker: string } | null = null;
  private probeCount = 0;
  acp: Acp | null = null;

  constructor(private readonly worktree: string, private readonly helpers: Helpers, profile: string, traceLog?: string) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-modes-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    const settings: Record<string, unknown> = { session_titles: false };
    if (profile !== "unset") settings.permission_mode = profile;
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify(settings)}\n`, { mode: 0o600 });

    this.gateway = helpers.startDynamicFakeGateway((body: string) => {
      const probe = this.probe;
      const kind = !probe ? "no-probe" : body.includes(probe.id) ? "final" : "tool-call";
      this.gatewayLog.push({ n: this.gatewayLog.length + 1, probe: probe?.id ?? null, kind });
      if (probe && kind === "tool-call") return helpers.fakeShellRun(probe.id, `printf ran > ${JSON.stringify(probe.marker)}`);
      return helpers.fakeGatewayFinalText("done");
    }, {});
    this.traceLog = traceLog;
  }

  private traceLog?: string;

  env(): Record<string, string> {
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries({
      ...process.env,
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-modes-fake-key",
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      ...(this.traceLog ? { FX_TRACE_LOG: this.traceLog, FX_TRACE_SCOPES: "acp,permission,host_config" } : {}),
    })) {
      if (value === undefined || STRIPPED_ENV.includes(key)) continue;
      env[key] = value;
    }
    return env;
  }

  async start(): Promise<Acp> {
    const fxBin = join(this.worktree, "zig-out", "bin", "fx");
    const processNumber = this.processes.length + 1;
    this.acp = new Acp(
      Bun.spawn([fxBin, "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }),
      (entry) => this.acpLog.push({ process: processNumber, ...entry }),
    );
    await this.acp.call("initialize", { protocolVersion: 1 });
    return this.acp;
  }

  async restart(): Promise<Acp> {
    if (this.acp) this.processes.push(await this.acp.close());
    return this.start();
  }

  /// Runs one turn whose model asks to write a marker file with the shell
  /// tool, and reports how fx handled it: "asked" (a permission request
  /// reached the client), "reviewed" (fx's automatic reviewer was called),
  /// or "direct", plus whether the command ran.
  async probePrompt(sessionId: string): Promise<{ ok: boolean; enforce: string; detail: object }> {
    const acp = this.acp!;
    this.probeCount += 1;
    const marker = join(this.workspace, `probe-${this.probeCount}.txt`);
    this.probe = { id: `probe_call_${this.probeCount}`, marker };
    const asked0 = acp.permissionRequests;
    const reviewed0 = this.gateway.classifierRequests.length + this.gateway.evaluationRequests.length;
    const response = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "write the probe marker" }] });
    this.probe = null;
    const asked = acp.permissionRequests - asked0;
    const reviewed = this.gateway.classifierRequests.length + this.gateway.evaluationRequests.length - reviewed0;
    const ran = existsSync(marker);
    const ok = !response.error && response.result?.stopReason === "end_turn";
    const how = asked > 0 && reviewed > 0 ? "asked+reviewed" : asked > 0 ? "asked" : reviewed > 0 ? "reviewed" : "direct";
    return {
      ok,
      enforce: ok ? `${how}/${ran ? "ran" : "no-run"}` : "none",
      detail: { asked, reviewed, ran, stopReason: response.result?.stopReason ?? null, error: response.error ?? null },
    };
  }

  stored(): string {
    return storedMode(this.home);
  }

  /// Runs `fx status --json` in the workspace and projects its modes the way
  /// a client would read them before a session exists.
  status(): { ok: boolean; view: View | null; detail: object } {
    const fxBin = join(this.worktree, "zig-out", "bin", "fx");
    const run = Bun.spawnSync([fxBin, "status", "--json"], { cwd: this.workspace, env: this.env(), stdout: "pipe", stderr: "pipe" });
    const text = new TextDecoder().decode(run.stdout).trim();
    let parsed: any = null;
    try { parsed = JSON.parse(text); } catch {}
    const modes: any[] | null = Array.isArray(parsed?.modes) ? parsed.modes : null;
    const ok = run.exitCode === 0 && typeof parsed?.mode === "string" && modes !== null;
    const statusKeys = new Set(["id", "name", "description"]);
    const view: View | null = ok ? {
      current: parsed.mode,
      legacy: "n/a",
      listed: modes!.map((mode) => String(mode?.id)).join(","),
      legacyListed: "n/a",
      names: modes!.map((mode) => String(mode?.name)).join(","),
      schemaOk: modes!.every((mode) => typeof mode?.id === "string" && typeof mode?.name === "string" && Object.keys(mode).every((key) => statusKeys.has(key))),
    } : null;
    return { ok, view, detail: { exit: run.exitCode, stderr: new TextDecoder().decode(run.stderr).slice(0, 300), permission_mode: parsed?.permission_mode ?? null } };
  }

  /// Saves a mode the way another fx process would (the CLI's /permissions
  /// or another ACP process). Older fx saved full access as "yolo", which fx
  /// still reads.
  saveFromOtherProcess(mode: string) {
    const path = join(this.home, ".fx", "settings.json");
    const settings = JSON.parse(readFileSync(path, "utf8"));
    settings.permission_mode = mode === "full-access" ? "yolo" : mode;
    writeFileSync(path, `${JSON.stringify(settings)}\n`, { mode: 0o600 });
  }

  async dispose() {
    if (this.acp) this.processes.push(await this.acp.close());
    this.acp = null;
    this.gateway.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
