// A fake Vercel REST API for fx's built-in remote runner and its in-chat
// setup (src/core/runner/): the account, team and
// project reads and the project create that setup makes, persistent and
// isolated sandboxes, and the session calls of one run. Routes and bodies
// follow the shell runner contracts that tests/tla/runner/RemoteRun.tla and
// RunnerSetup.tla model.
//
// Every remote path lives under the fake's private root: the sandbox path P
// is the folder <privateRoot>/fs/P, so a remote write never lands at the
// real path on this machine. Commands run on this machine with a clean
// environment, the mapped working directory, and every Mac root the test
// names rewritten to its mapped folder in their arguments. A command body
// without `logs: true` is refused. Every request is logged in arrival order,
// without its authorization header.
//
// Bodies, sizes and the errors whose text is quoted follow the real API as
// measured on 2026-11-21: create answers `{routes, sandbox, session}` with no
// `expiresAt`; a GET or list answers `sandbox.expiresAt` (session start plus
// timeout); `resources.vcpus` is 1 or even and memory is always vcpus * 2048
// MB; PATCH resizes the sandbox, and the next session takes the new size.
//
// Fault knobs (`api.faults`, each used once unless noted):
//   createStatus        POST /v3/sandboxes answers this status
//   dropAfterExecBody   the next exec: the body is read, then the connection
//                       drops before any line; "ran" starts the command first
//   delayCommandLineMs  the next exec stream holds its first line, the one
//                       with the command's id, this long
//   idleCloseAfterBytes the next exec stream ends cleanly after this many
//                       output bytes, without the exit line; the command
//                       keeps running and its logs stay readable
//   cutBringBackAfterBytes the next bring-back stream ends after this many
//                       output bytes, without the exit line
//   goneOnce            the next session call answers 410 and stops the session
//   goneWrites          the next N fs/write calls each answer 410 and stop the session
//   goneExtends         the next N extend-timeout calls each answer 410 and stop the session
//   sandboxGone         the next sandbox GET answers 404 and deletes it
//   slowKillMs          every kill waits this long before it acts (not once)
//   hostileBringBack    the next bring-back exec streams, base64, a tar of
//                       HOSTILE_BRING_BACK_ENTRIES instead of running
//
// Self-test: bun tests/e2e/fixtures/fake-vercel-api.ts --self-test
import { constants as osConstants, tmpdir } from "node:os";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import { gunzipSync, gzipSync } from "node:zlib";

// The sandbox's scripts need GNU find, xargs, dirname and realpath, and bash 4 or later, as the Linux sandbox has them.
// On a Mac the fake puts Homebrew's copies first, for its own commands only, when Homebrew has them.
const homebrewSandboxTools = [
  "/opt/homebrew/opt/findutils/libexec/gnubin",
  "/opt/homebrew/opt/coreutils/libexec/gnubin",
  "/opt/homebrew/bin",
];

function sandboxPath(): string {
  return [...homebrewSandboxTools.filter((dir) => existsSync(dir)), process.env.PATH ?? "/usr/bin:/bin"].join(":");
}

const sandboxToolsMessage =
  "the fake sandbox needs GNU findutils, GNU coreutils and bash 4.4 or later on this host: brew install bash coreutils findutils";
// The calls the sandbox scripts make, with the flags they use.
const sandboxToolsProbe =
  "find . -maxdepth 0 -printf '' >/dev/null && find -files0-from /dev/null -maxdepth 0 >/dev/null && " +
  "dirname -z -- / >/dev/null && realpath -m -z --relative-to=/ / >/dev/null && " +
  "declare -A seen=() && mapfile -d '' -t list < /dev/null";
let sandboxToolsChecked = false;

function sandboxToolsReady(): boolean {
  try {
    return Bun.spawnSync(["bash", "-c", sandboxToolsProbe], { env: { PATH: sandboxPath() }, stdin: "ignore" }).exitCode === 0;
  } catch {
    // bash itself is missing from the sandbox PATH, so the tools are missing too.
    return false;
  }
}

// On a host that is not Linux, stop at once when the sandbox scripts' tools are missing, not later in a bring-back.
function requireSandboxTools(): void {
  if (process.platform === "linux" || sandboxToolsChecked) return;
  if (!sandboxToolsReady()) throw new Error(sandboxToolsMessage);
  sandboxToolsChecked = true;
}

export type FakeVercelUser = { id: string; username: string; email: string };
export type FakeVercelTeam = { id: string; slug: string; name: string };
export type FakeVercelProject = { id: string; name: string; createdAt: number };

export type FakeVercelRoute =
  | "user" | "teams" | "teamBySlug" | "projects" | "project" | "createProject"
  | "createSandbox" | "getSandbox" | "updateSandbox" | "listSandboxes" | "deleteSandbox"
  | "cmd" | "cmdGet" | "cmdLogs" | "kill" | "write" | "extendTimeout" | "stopSession";

/// How the fake tells the runner's command requests apart: the first-use
/// setup runs with sudo, the stamp and the bring-back name the run's stamp
/// file, and the bring-back also packs a tar.
export type FakeVercelCommandKind = "setup" | "stamp" | "exec" | "bring_back";

export type FakeVercelLogEntry = {
  seq: number;
  at: number; // ms since the fake started
  method: string;
  path: string;
  query: Record<string, string>;
  route: FakeVercelRoute | "unknown";
  status: number | null; // null while the handler runs, or after a dropped connection
  kind?: FakeVercelCommandKind; // cmd only
  commandId?: string; // cmd, cmdGet, cmdLogs, kill
  body?: unknown; // parsed JSON body
  bytes?: number; // fs/write body size
  notes: string[]; // faults applied and stream ends, in order
  /// What the Authorization header held: nothing, the test override's token, or any other token (AC-30).
  auth: "none" | "test" | "other";
  /// ms since the fake started, when the answer body ended or the client closed it (AC-23).
  endAt?: number;
};

function authClass(header: string | null, testToken: string | undefined): "none" | "test" | "other" {
  if (header === null) return "none";
  return testToken !== undefined && header === `Bearer ${testToken}` ? "test" : "other";
}

/// Passes an answer's body through, and calls `onEnd` when the body is read to its end or the client closes it.
function endTracked(answer: Response, onEnd: () => void): Response {
  if (!answer.body) {
    onEnd();
    return answer;
  }
  const reader = answer.body.getReader();
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const next = await reader.read();
      if (next.done) {
        onEnd();
        controller.close();
        return;
      }
      controller.enqueue(next.value);
    },
    cancel(reason) {
      onEnd();
      return reader.cancel(reason);
    },
  });
  return new Response(body, { status: answer.status, statusText: answer.statusText, headers: answer.headers });
}

export type FakeVercelFaults = {
  createStatus?: number;
  // The next create answers 200 with this raw body, once: a body fx cannot read.
  createBody?: string;
  // The next command whose arguments contain `contains` answers `status` with an error body, once, before any command line.
  commandStatus?: { contains: string; status: number };
  dropAfterExecBody?: "ran" | "not_run";
  delayCommandLineMs?: number;
  idleCloseAfterBytes?: number;
  // The next bring-back stream ends after this many output bytes, without the exit line, once.
  cutBringBackAfterBytes?: number;
  goneOnce?: boolean;
  // The next command whose arguments contain this text answers 410 and stops the session, once.
  goneCommand?: string;
  // How many commands in a row answer 410 for `goneCommand`, each stopping the session. Default 1.
  goneCommandTimes?: number;
  goneWrites?: number;
  goneExtends?: number;
  sandboxGone?: boolean;
  slowKillMs?: number;
  hostileBringBack?: boolean;
  // The next sandbox list answers 500, once (AC-31).
  listFails?: boolean;
  // The session time of the next created sandbox, in ms, instead of the one the create asks for, once.
  /** The next session that is created or resumed lasts this long, once. */
  nextSessionMs?: number;
  // The size a sandbox reports after a size PATCH, when it differs from the request (N18).
  reportedVcpus?: number;
};

export type FakeVercelCommandView = {
  id: string;
  kind: FakeVercelCommandKind;
  sandbox: string;
  session: string;
  args: string[];
  cwd: string; // the remote path
  status: "running" | "exited" | "killed";
  exitCode: number | null;
  signals: number[];
  startedAt: number;
  endedAt: number | null;
};

/// Test-only: a copy of a team or project entry with `bytes` of extra text, so a list reply is as
/// large as the real API's (U5). Without padding the entry is returned as it is.
function padded<T extends object>(entry: T, bytes: number | undefined): T & { description?: string } {
  return bytes ? { ...entry, description: "x".repeat(bytes) } : entry;
}

export type FakeVercelOptions = {
  /// Bearer token -> the user it signs in. Any other token gets 403.
  users: Record<string, FakeVercelUser>;
  teams: FakeVercelTeam[];
  projects?: Record<string, Array<{ id: string; name: string }>>;
  /// Every remote path lives under here. Must not overlap a Mac root.
  privateRoot: string;
  /// Mac paths, such as the repository root, rewritten in command arguments.
  macRoots?: string[];
  /// Extra bytes on each team and project entry of a list reply (the real sizes, U5).
  padding?: { team: number; project: number };
  /// The token the test override sends in place of the login. Its requests are logged as "test".
  testToken?: string;
  /// Called once a request has its status, before its body streams.
  afterRequest?: (entry: FakeVercelLogEntry) => void | Promise<void>;
};

export type FakeVercelApi = {
  url: string;
  startedAt: number; // Date.now() when the fake started; log `at` counts from here
  log: FakeVercelLogEntry[];
  faults: FakeVercelFaults;
  remotePath(path: string): string;
  commands(): FakeVercelCommandView[];
  sandboxes(): Array<{ id: string; name: string; persistent: boolean; status: string; session: string }>;
  // A sandbox that exists before the run, created at `createdAt` (ms since the epoch), so a test can
  // age one past the sweep limit (AC-31). It is an ordinary sandbox of the first team's project prj_1.
  seedSandbox(options: { name: string; createdAt: number; teamId?: string; projectId?: string; status?: "running" | "stopped" }): void;
  // Makes the user check answer with `user` for this token from now on, as when the login changed to another account.
  signInAs(token: string, user: FakeVercelUser): void;
  stop(): void;
};

/// The entries of the hostile bring-back tar. `sub/y` is hostile only where
/// the test made `sub` a symlink on the Mac.
export const HOSTILE_BRING_BACK_ENTRIES = [
  "../x",
  "/abs",
  "link",
  "sub/y",
  ".git/hooks/pre-commit",
  ".GIT/config",
  "sub/.git/hooks/post-checkout",
  ".g\u200cit/config",
] as const;

const ROUTES: Array<[string, RegExp, FakeVercelRoute]> = [
  ["GET", /^\/v2\/user$/, "user"],
  ["GET", /^\/v2\/teams$/, "teams"],
  ["GET", /^\/v2\/teams\/([^/]+)$/, "teamBySlug"],
  ["GET", /^\/v10\/projects$/, "projects"],
  ["GET", /^\/v9\/projects\/([^/]+)$/, "project"],
  ["POST", /^\/v11\/projects$/, "createProject"],
  ["POST", /^\/v3\/sandboxes$/, "createSandbox"],
  ["GET", /^\/v2\/sandboxes$/, "listSandboxes"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd$/, "cmd"],
  ["GET", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd\/([^/]+)\/logs$/, "cmdLogs"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd\/([^/]+)\/kill$/, "kill"],
  ["GET", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd\/([^/]+)$/, "cmdGet"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/fs\/write$/, "write"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/extend-timeout$/, "extendTimeout"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/stop$/, "stopSession"],
  ["GET", /^\/v2\/sandboxes\/([^/]+)$/, "getSandbox"],
  ["PATCH", /^\/v2\/sandboxes\/([^/]+)$/, "updateSandbox"],
  ["DELETE", /^\/v2\/sandboxes\/([^/]+)$/, "deleteSandbox"],
];
const TEAM_ROUTES = new Set<FakeVercelRoute>([
  "projects", "project", "createProject", "createSandbox", "getSandbox", "updateSandbox", "listSandboxes", "deleteSandbox",
]);
const SESSION_ROUTES = new Set<FakeVercelRoute>(["cmd", "cmdGet", "cmdLogs", "kill", "write", "extendTimeout", "stopSession"]);
const DEFAULT_REMOTE_CWD = "/vercel/sandbox";
const DEFAULT_PAGE = 20;
const MAX_PAGE = 100;
const DEFAULT_VCPUS = 2;
const MEMORY_MB_PER_VCPU = 2048;
const DEFAULT_SESSION_TIMEOUT_MS = 300_000;

type Session = { id: string; status: "running" | "stopped"; startedAt: number; timeout: number; vcpus: number; memory: number };
type Sandbox = {
  id: string;
  name: string;
  teamId: string;
  projectId: string;
  persistent: boolean;
  networkPolicy: unknown;
  createdAt: number;
  status: "running" | "stopped";
  vcpus: number;
  memory: number;
  session: Session;
};
type CommandBody = {
  command?: unknown;
  args?: unknown;
  cwd?: unknown;
  env?: unknown;
  sudo?: unknown;
  wait?: unknown;
  logs?: unknown;
  timeout?: unknown;
};
type Chunk = { stream: "stdout" | "stderr"; data: string };
type CommandState = {
  view: FakeVercelCommandView;
  process: ReturnType<typeof Bun.spawn> | null;
  chunks: Chunk[];
  finished: boolean;
  finishedPromise: Promise<void>;
  killRequested: boolean;
  listeners: Set<() => void>;
};

const encoder = new TextEncoder();

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message: `fake: ${message}` } }, { status });
}

/// An error whose body is the real API's, word for word.
function measuredError(status: number, message: string, extra: Record<string, unknown> = {}): Response {
  return Response.json({ error: { code: "bad_request", message, ...extra } }, { status });
}

/// The real API's check of `resources.vcpus`, or null when the value is good.
function vcpusError(vcpus: unknown): Response | null {
  if (typeof vcpus !== "number" || !Number.isInteger(vcpus) || vcpus < 1) {
    return errorAnswer(400, "bad_request", "resources.vcpus must be a positive integer");
  }
  if (vcpus > 1 && vcpus % 2 === 1) return measuredError(400, "`resources.vcpus` should be even");
  return null;
}

function tarballError(stderr: string): Response {
  return measuredError(400, "The submitted tarball could not be extracted", { stderr });
}

function sleep(ms: number): Promise<void> {
  return new Promise((done) => setTimeout(done, ms));
}

function inside(child: string, parent: string): boolean {
  const rel = relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function pageOf<T>(items: T[], url: URL): { page: T[]; next: number | null } {
  const limit = Math.min(MAX_PAGE, Math.max(1, Number(url.searchParams.get("limit") ?? DEFAULT_PAGE) || DEFAULT_PAGE));
  // `until` is the cursor a previous page returned as `pagination.next`.
  const from = Math.max(0, Number(url.searchParams.get("until") ?? 0) || 0);
  const page = items.slice(from, from + limit);
  return { page, next: from + limit < items.length ? from + limit : null };
}

function signalNumber(name: string | null | undefined): number {
  if (!name) return 0;
  return (osConstants.signals as Record<string, number>)[name] ?? 0;
}

function tarEntry(name: string, type: "0" | "2", body: Uint8Array, linkname = ""): Uint8Array {
  const header = new Uint8Array(512);
  const put = (offset: number, length: number, text: string) => header.set(encoder.encode(text).subarray(0, length), offset);
  const octal = (offset: number, length: number, value: number) =>
    put(offset, length, `${value.toString(8).padStart(length - 1, "0")}\0`);
  put(0, 100, name);
  octal(100, 8, type === "2" ? 0o777 : 0o644);
  octal(108, 8, 0);
  octal(116, 8, 0);
  octal(124, 12, type === "0" ? body.length : 0);
  octal(136, 12, Math.floor(Date.now() / 1000));
  header.fill(0x20, 148, 156);
  put(156, 1, type);
  put(157, 100, linkname);
  put(257, 6, "ustar\0");
  put(263, 2, "00");
  const sum = header.reduce((total, byte) => total + byte, 0);
  put(148, 8, `${sum.toString(8).padStart(6, "0")}\0 `);
  const data = type === "0" ? body : new Uint8Array(0);
  const out = new Uint8Array(512 + Math.ceil(data.length / 512) * 512);
  out.set(header, 0);
  out.set(data, 512);
  return out;
}

/// A tar.gz of the AC-14 entries that bring back must refuse: a parent escape,
/// an absolute path, a symlink, a file under a folder that is a symlink on the
/// Mac, files under .git in three spellings (the last one has U+200C inside
/// the name, which HFS+ ignores), and a file under a .git folder that does not
/// exist on the Mac.
export function hostileBringBackTar(): Uint8Array {
  const parts = [
    tarEntry("../x", "0", encoder.encode("escaped\n")),
    tarEntry("/abs", "0", encoder.encode("absolute\n")),
    tarEntry("link", "2", new Uint8Array(0), "../../outside"),
    tarEntry("sub/y", "0", encoder.encode("through a symlink\n")),
    tarEntry(".git/hooks/pre-commit", "0", encoder.encode("hook\n")),
    tarEntry(".GIT/config", "0", encoder.encode("[core]\n")),
    tarEntry("sub/.git/hooks/post-checkout", "0", encoder.encode("hook\n")),
    tarEntry(".g\u200cit/config", "0", encoder.encode("[core]\n")),
    new Uint8Array(1024),
  ];
  const tar = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    tar.set(part, offset);
    offset += part.length;
  }
  return gzipSync(tar);
}

/// Entry names and types of a tar.gz, read without extracting it.
export function tarEntries(gz: Uint8Array): Array<{ name: string; type: string }> {
  const tar = gunzipSync(gz);
  const decoder = new TextDecoder();
  const entries: Array<{ name: string; type: string }> = [];
  for (let offset = 0; offset + 512 <= tar.length;) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const field = (start: number, length: number) => decoder.decode(header.subarray(start, start + length)).replace(/\0.*$/s, "");
    const prefix = field(345, 155);
    const name = field(0, 100);
    const size = parseInt(field(124, 12).trim() || "0", 8);
    const type = field(156, 1) || "0";
    entries.push({ name: prefix ? `${prefix}/${name}` : name, type });
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function classify(body: CommandBody, args: string[]): FakeVercelCommandKind {
  if (body.sudo === true) return "setup";
  const text = args.join(" ");
  // The built-in runner's exec: `bash -c W fx STAMP C cmd`, where W deletes from `.git/fx-delete-*`.
  if (args[0] === "-c" && args[1]?.includes("fx-delete-")) return "exec";
  if (text.includes("fx-stamp-") && /\btar\b/.test(text)) return "bring_back";
  if (text.includes("fx-stamp-")) return "stamp";
  // The runner's generation write (V4) is setup, so an exec-only fault never lands on it. Any other
  // shell command is an exec (the fake's own tests run bash); a probe such as `id -un` is setup.
  if (text.includes("fx-generation")) return "setup";
  return body.command === "bash" ? "exec" : "setup";
}

export function startFakeVercelApi(options: FakeVercelOptions): FakeVercelApi {
  requireSandboxTools();
  const privateRoot = resolve(options.privateRoot);
  const macRoots = [...(options.macRoots ?? [])].map((root) => resolve(root)).sort((a, b) => b.length - a.length);
  for (const root of macRoots) {
    if (inside(privateRoot, root) || inside(root, privateRoot)) {
      throw new Error(`fake Vercel API: private root ${privateRoot} overlaps Mac root ${root}`);
    }
  }
  const fsRoot = join(privateRoot, "fs");
  const home = join(privateRoot, "home");
  mkdirSync(fsRoot, { recursive: true });
  mkdirSync(home, { recursive: true });

  const started = Date.now();
  const log: FakeVercelLogEntry[] = [];
  const faults: FakeVercelFaults = {};
  const projects = new Map<string, FakeVercelProject[]>();
  let projectCount = 0;
  for (const team of options.teams) {
    projects.set(team.id, (options.projects?.[team.id] ?? []).map((project, index) => ({
      ...project,
      createdAt: started - (index + 1) * 1000, // listed order is newest first
    })));
  }
  const byName = new Map<string, Sandbox>();
  const bySession = new Map<string, Sandbox>();
  const commands = new Map<string, CommandState>();
  const pendingDrops: Array<(response: Response) => void> = [];
  let sandboxCount = 0;
  let sessionCount = 0;
  let commandCount = 0;

  const remotePath = (path: string) => join(fsRoot, resolve("/", path));
  const rewrite = (arg: string) => {
    let out = arg;
    for (const root of macRoots) out = out.split(root).join(remotePath(root));
    return out;
  };

  /// A session takes the sandbox's size when it starts; a later resize waits
  /// for the next session.
  function newSession(vcpus: number, memory: number, timeout: number): Session {
    return { id: `sess_${++sessionCount}`, status: "running", startedAt: Date.now(), timeout, vcpus, memory };
  }

  /// Create answers no `expiresAt`; a GET, PATCH or list does.
  function sandboxView(sandbox: Sandbox, withExpiresAt: boolean) {
    const view: Record<string, unknown> = {
      name: sandbox.name,
      vcpus: sandbox.vcpus,
      memory: sandbox.memory,
      currentSessionId: sandbox.session.id,
      timeout: sandbox.session.timeout,
      persistent: sandbox.persistent,
      status: sandbox.status,
      createdAt: sandbox.createdAt,
      statusUpdatedAt: sandbox.createdAt,
      updatedAt: sandbox.createdAt,
      workloadType: "sandbox",
      region: "iad1",
      failoverRegions: [],
      runtime: "node22",
      architecture: "amd64",
      image: "vercel/sandbox/universal",
      expiryNotificationLeadTime: 60_000,
      cwd: "/vercel",
    };
    if (withExpiresAt) {
      view.expiresAt = sandbox.session.startedAt + sandbox.session.timeout;
      Object.assign(view, { totalEgressBytes: 0, totalIngressBytes: 0, totalActiveCpuDurationMs: 0, totalDurationMs: 0 });
    }
    return view;
  }

  function sessionView(sandbox: Sandbox) {
    return {
      id: sandbox.session.id,
      startedAt: sandbox.session.startedAt,
      timeout: sandbox.session.timeout,
      vcpus: sandbox.session.vcpus,
      memory: sandbox.session.memory,
      status: sandbox.session.status,
      requestedAt: sandbox.session.startedAt,
      createdAt: sandbox.session.startedAt,
      updatedAt: sandbox.session.startedAt,
      runtime: "node22",
      architecture: "amd64",
      region: "iad1",
      cwd: "/vercel",
      workloadType: "sandbox",
      sourceSandboxName: sandbox.name,
      projectId: sandbox.projectId,
      interactivePort: 0,
    };
  }

  function commandAnswer(state: CommandState) {
    const { endedAt, startedAt } = state.view;
    return { command: { ...state.view, durationMs: endedAt === null ? null : endedAt - startedAt } };
  }

  function stopCommands(sandbox: Sandbox) {
    for (const state of commands.values()) {
      if (state.view.sandbox !== sandbox.name || state.finished || !state.process) continue;
      try {
        state.process.kill(9);
      } catch {
        // The command already exited.
      }
    }
  }

  function removeSandbox(sandbox: Sandbox) {
    stopCommands(sandbox);
    byName.delete(sandbox.name);
    for (const [id, owner] of bySession) if (owner === sandbox) bySession.delete(id);
  }

  function notify(state: CommandState) {
    for (const listener of [...state.listeners]) listener();
  }

  function startCommand(sandbox: Sandbox, kind: FakeVercelCommandKind, body: CommandBody, args: string[]): CommandState {
    const remoteCwd = typeof body.cwd === "string" ? body.cwd : DEFAULT_REMOTE_CWD;
    const view: FakeVercelCommandView = {
      id: `cmd_${++commandCount}`,
      kind,
      sandbox: sandbox.name,
      session: sandbox.session.id,
      args,
      cwd: remoteCwd,
      status: "running",
      exitCode: null,
      signals: [],
      startedAt: Date.now(),
      endedAt: null,
    };
    let finish!: () => void;
    const state: CommandState = {
      view,
      process: null,
      chunks: [],
      finished: false,
      finishedPromise: new Promise((done) => { finish = done; }),
      killRequested: false,
      listeners: new Set(),
    };
    commands.set(view.id, state);
    const end = (code: number | null) => {
      view.exitCode = code;
      view.status = state.killRequested ? "killed" : "exited";
      view.endedAt = Date.now();
      state.finished = true;
      finish();
      notify(state);
    };
    if (kind === "bring_back" && faults.hostileBringBack) {
      faults.hostileBringBack = false;
      state.chunks.push({ stream: "stdout", data: Buffer.from(hostileBringBackTar()).toString("base64") });
      end(0);
      return state;
    }
    // bsdtar on macOS adds AppleDouble ._ entries for files with extended attributes; the Linux sandbox has none.
    const env: Record<string, string> = { PATH: sandboxPath(), HOME: home, LANG: "C.UTF-8", COPYFILE_DISABLE: "1" };
    if (body.env && typeof body.env === "object") {
      for (const [name, value] of Object.entries(body.env as Record<string, unknown>)) {
        if (typeof value === "string") env[name] = value;
      }
    }
    const child = Bun.spawn([rewrite(String(body.command)), ...args.map(rewrite)], {
      cwd: remotePath(remoteCwd),
      env,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    state.process = child;
    const pump = async (source: ReadableStream<Uint8Array>, stream: Chunk["stream"]) => {
      const decoder = new TextDecoder();
      for await (const value of source) {
        const data = decoder.decode(value, { stream: true });
        if (data.length > 0) {
          state.chunks.push({ stream, data });
          notify(state);
        }
      }
      const tail = decoder.decode();
      if (tail.length > 0) state.chunks.push({ stream, data: tail });
    };
    void (async () => {
      await Promise.all([
        pump(child.stdout as ReadableStream<Uint8Array>, "stdout"),
        pump(child.stderr as ReadableStream<Uint8Array>, "stderr"),
      ]);
      const code = await child.exited;
      end(child.signalCode ? 128 + signalNumber(child.signalCode) : code);
    })();
    return state;
  }

  /// ND-JSON: for an exec, the command first, then each output chunk as it
  /// comes, then the command with its exit code; for logs, the chunks only.
  function streamOf(state: CommandState, entry: FakeVercelLogEntry, withCommand: boolean, closeAfterBytes?: number, delayMs = 0) {
    let index = 0;
    let sent = 0;
    let closed = false;
    let flush = () => {};
    return new ReadableStream<Uint8Array>({
      async start(controller) {
        if (delayMs > 0) {
          entry.notes.push(`fault: command line held ${delayMs} ms`);
          await sleep(delayMs);
        }
        const send = (value: unknown) => controller.enqueue(encoder.encode(`${JSON.stringify(value)}\n`));
        const close = (note: string) => {
          closed = true;
          state.listeners.delete(flush);
          entry.notes.push(note);
          controller.close();
        };
        flush = () => {
          if (closed) return;
          while (index < state.chunks.length) {
            const chunk = state.chunks[index++]!;
            send({ stream: chunk.stream, data: chunk.data });
            sent += encoder.encode(chunk.data).length;
            if (closeAfterBytes !== undefined && sent >= closeAfterBytes) return close(`stream closed after ${sent} bytes`);
          }
          if (state.finished) {
            if (withCommand) send({ command: { ...state.view } });
            close("stream end");
          }
        };
        if (withCommand) {
          send({ command: { ...state.view, exitCode: null, status: "running" } });
          entry.notes.push("command line sent");
        }
        state.listeners.add(flush);
        flush();
      },
      cancel() {
        closed = true;
        state.listeners.delete(flush);
        entry.notes.push("client closed the stream");
      },
    });
  }

  function commandFor(params: string[]): CommandState | undefined {
    const state = commands.get(params[1]!);
    return state && state.view.session === params[0] ? state : undefined;
  }

  async function handle(
    route: FakeVercelRoute,
    params: string[],
    url: URL,
    request: Request,
    server: ReturnType<typeof Bun.serve>,
    entry: FakeVercelLogEntry,
    user: FakeVercelUser,
    body: any,
  ): Promise<Response> {
    const teamId = url.searchParams.get("teamId") ?? "";
    switch (route) {
      case "user":
        return Response.json({ user });
      case "teams": {
        const { page, next } = pageOf(options.teams, url);
        return Response.json({ teams: page.map((team) => padded(team, options.padding?.team)), pagination: { count: page.length, next } });
      }
      case "teamBySlug": {
        const team = options.teams.find((item) => item.slug === params[0]);
        return team ? Response.json(team) : errorAnswer(404, "not_found", "team not found");
      }
      case "projects": {
        const list = [...(projects.get(teamId) ?? [])].sort((a, b) => b.createdAt - a.createdAt);
        const { page, next } = pageOf(list, url);
        return Response.json({ projects: page.map((project) => padded(project, options.padding?.project)), pagination: { count: page.length, next } });
      }
      case "project": {
        const project = (projects.get(teamId) ?? []).find((item) => item.name === params[0] || item.id === params[0]);
        return project ? Response.json(project) : errorAnswer(404, "not_found", "project not found");
      }
      case "createProject": {
        if (typeof body?.name !== "string" || body.name.length === 0) return errorAnswer(400, "bad_request", "name required");
        const list = projects.get(teamId) ?? [];
        projects.set(teamId, list);
        if (list.some((item) => item.name === body.name)) return errorAnswer(409, "conflict", "project exists");
        const project = { id: `prj_new_${++projectCount}`, name: body.name, createdAt: Date.now() };
        list.push(project);
        return Response.json(project);
      }
      case "createSandbox": {
        if (faults.createBody !== undefined) {
          const raw = faults.createBody;
          faults.createBody = undefined;
          entry.notes.push("fault: create body");
          return new Response(raw, { status: 200, headers: { "content-type": "application/json" } });
        }
        if (faults.createStatus !== undefined) {
          const status = faults.createStatus;
          faults.createStatus = undefined;
          entry.notes.push(`fault: create ${status}`);
          return errorAnswer(status, "internal_error", "sandbox create failed");
        }
        if (typeof body?.name !== "string" || typeof body?.projectId !== "string") {
          return errorAnswer(400, "bad_request", "name and projectId required");
        }
        if (!(projects.get(teamId) ?? []).some((item) => item.id === body.projectId)) {
          return errorAnswer(404, "not_found", "project not found");
        }
        const vcpus = body.resources?.vcpus ?? DEFAULT_VCPUS;
        const badVcpus = vcpusError(vcpus);
        if (badVcpus) return badVcpus;
        if (byName.has(body.name)) return errorAnswer(409, "conflict", "a sandbox with this name exists");
        const memory = vcpus * MEMORY_MB_PER_VCPU;
        const timeout = faults.nextSessionMs ?? (typeof body.timeout === "number" ? body.timeout : DEFAULT_SESSION_TIMEOUT_MS);
        faults.nextSessionMs = undefined;
        const sandbox: Sandbox = {
          id: `sbx_${++sandboxCount}`,
          name: body.name,
          teamId,
          projectId: body.projectId,
          persistent: body.persistent === true,
          networkPolicy: body.networkPolicy ?? null,
          createdAt: Date.now(),
          status: "running",
          vcpus,
          memory,
          session: newSession(vcpus, memory, timeout),
        };
        byName.set(sandbox.name, sandbox);
        bySession.set(sandbox.session.id, sandbox);
        return Response.json({ routes: [], sandbox: sandboxView(sandbox, false), session: sessionView(sandbox) });
      }
      case "getSandbox": {
        const sandbox = byName.get(params[0]!);
        if (sandbox && faults.sandboxGone) {
          faults.sandboxGone = false;
          entry.notes.push("fault: sandbox gone");
          removeSandbox(sandbox);
          return errorAnswer(404, "not_found", "sandbox not found");
        }
        if (!sandbox || sandbox.teamId !== teamId) return errorAnswer(404, "not_found", "sandbox not found");
        const resumed = url.searchParams.get("resume") === "true" && sandbox.session.status === "stopped";
        if (resumed) {
          const timeout = faults.nextSessionMs ?? sandbox.session.timeout;
          faults.nextSessionMs = undefined;
          sandbox.session = newSession(sandbox.vcpus, sandbox.memory, timeout);
          sandbox.status = "running";
          bySession.set(sandbox.session.id, sandbox);
          entry.notes.push(`resumed as ${sandbox.session.id}`);
        }
        return Response.json({
          sandbox: sandboxView(sandbox, true),
          session: sessionView(sandbox),
          routes: [],
          ...(resumed ? { resumed: true } : {}),
        });
      }
      case "updateSandbox": {
        const sandbox = byName.get(params[0]!);
        if (!sandbox || sandbox.teamId !== teamId) return errorAnswer(404, "not_found", "sandbox not found");
        const vcpus = body?.resources?.vcpus;
        const memory = body?.resources?.memory;
        const badVcpus = vcpusError(vcpus);
        if (badVcpus) return badVcpus;
        if (memory !== vcpus * MEMORY_MB_PER_VCPU) {
          return measuredError(400, "`resources.memory` should equal `resources.vcpus` * 2048");
        }
        sandbox.vcpus = faults.reportedVcpus ?? vcpus;
        sandbox.memory = memory;
        entry.notes.push(`resized to ${vcpus} vcpus, ${memory} MB`);
        return Response.json({ sandbox: sandboxView(sandbox, true) });
      }
      case "listSandboxes": {
        if (faults.listFails) {
          faults.listFails = false;
          entry.notes.push("fault: list failed");
          return errorAnswer(500, "internal_error", "the list failed");
        }
        const project = url.searchParams.get("project") ?? url.searchParams.get("projectId");
        const prefix = url.searchParams.get("namePrefix");
        const byNameOrder = url.searchParams.get("sortBy") === "name";
        if (prefix !== null && !byNameOrder) {
          return measuredError(400, "Invalid request: `namePrefix` is only valid when `sortBy` is `name`");
        }
        const list = [...byName.values()].filter((sandbox) =>
          sandbox.teamId === teamId && (!project || sandbox.projectId === project) && sandbox.name.startsWith(prefix ?? ""));
        if (byNameOrder) list.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
        const { page, next } = pageOf(list, url);
        return Response.json({
          pagination: { count: page.length, next },
          sandboxes: page.map((sandbox) => sandboxView(sandbox, true)),
        });
      }
      case "deleteSandbox": {
        const sandbox = byName.get(params[0]!);
        if (!sandbox || sandbox.teamId !== teamId) return errorAnswer(404, "not_found", "sandbox not found");
        removeSandbox(sandbox);
        return Response.json({ sandbox: { ...sandboxView(sandbox, true), status: "deleted" } });
      }
      default:
        break;
    }

    // Session routes.
    const sandbox = bySession.get(params[0]!);
    if (!sandbox) return errorAnswer(404, "not_found", "session not found");
    if (faults.goneOnce) {
      faults.goneOnce = false;
      sandbox.session.status = "stopped";
      sandbox.status = "stopped";
      stopCommands(sandbox);
      entry.notes.push("fault: session gone");
    }
    if (route === "write" && faults.goneWrites && faults.goneWrites > 0) {
      faults.goneWrites -= 1;
      sandbox.session.status = "stopped";
      sandbox.status = "stopped";
      stopCommands(sandbox);
      entry.notes.push("fault: session gone on write");
    }
    if (route === "extendTimeout" && faults.goneExtends && faults.goneExtends > 0) {
      faults.goneExtends -= 1;
      sandbox.session.status = "stopped";
      sandbox.status = "stopped";
      stopCommands(sandbox);
      entry.notes.push("fault: session gone on extend");
    }
    if (sandbox.session.id !== params[0] || sandbox.session.status === "stopped") {
      return errorAnswer(410, "sandbox_stopped", "the session has stopped");
    }
    switch (route) {
      case "cmd": {
        const cmd = body as CommandBody;
        if (typeof cmd?.command !== "string") return errorAnswer(400, "bad_request", "command required");
        // Stricter than the real API on purpose: without `logs: true` it
        // answers 200 and streams no output lines, which a runner would read
        // as a silent command. Refusing it makes that bug fail fast in tests.
        if (cmd.logs !== true) return errorAnswer(400, "bad_request", "logs: true is required");
        const args = Array.isArray(cmd.args) ? cmd.args.map(String) : [];
        if (faults.commandStatus && args.join(" ").includes(faults.commandStatus.contains)) {
          const { status } = faults.commandStatus;
          faults.commandStatus = undefined;
          entry.notes.push(`fault: the command answers ${status}`);
          return errorAnswer(status, "forbidden", "Not authorized");
        }
        if (faults.goneCommand && args.join(" ").includes(faults.goneCommand)) {
          entry.notes.push(`fault: session gone on the command with ${faults.goneCommand}`);
          faults.goneCommandTimes = (faults.goneCommandTimes ?? 1) - 1;
          if (faults.goneCommandTimes <= 0) {
            faults.goneCommand = undefined;
            faults.goneCommandTimes = undefined;
          }
          sandbox.session.status = "stopped";
          sandbox.status = "stopped";
          stopCommands(sandbox);
          return errorAnswer(410, "sandbox_stopped", "the session has stopped");
        }
        const remoteCwd = typeof cmd.cwd === "string" ? cmd.cwd : DEFAULT_REMOTE_CWD;
        if (!isAbsolute(remoteCwd)) return errorAnswer(400, "bad_request", "cwd must be absolute");
        if (remoteCwd === DEFAULT_REMOTE_CWD) mkdirSync(remotePath(remoteCwd), { recursive: true });
        if (!existsSync(remotePath(remoteCwd))) return errorAnswer(422, "bad_request", `cwd ${remoteCwd} does not exist`);
        const kind = classify(cmd, args);
        entry.kind = kind;
        const drop = kind === "exec" ? faults.dropAfterExecBody : undefined;
        if (drop) {
          faults.dropAfterExecBody = undefined;
          if (drop === "ran") entry.commandId = startCommand(sandbox, kind, cmd, args).view.id;
          entry.notes.push(`fault: dropped after the exec body (${drop})`);
          // The socket closes once its 1 s idle timeout passes; the answer
          // below never reaches the client.
          server.timeout(request, 1);
          return await new Promise<Response>((done) => pendingDrops.push(done));
        }
        const state = startCommand(sandbox, kind, cmd, args);
        entry.commandId = state.view.id;
        if (cmd.wait !== true) return Response.json({ command: { ...state.view } });
        const closeAfter = kind === "exec" ? faults.idleCloseAfterBytes : undefined;
        if (closeAfter !== undefined) faults.idleCloseAfterBytes = undefined;
        const cutAfter = kind === "bring_back" ? faults.cutBringBackAfterBytes : undefined;
        if (cutAfter !== undefined) faults.cutBringBackAfterBytes = undefined;
        const delay = kind === "exec" ? faults.delayCommandLineMs ?? 0 : 0;
        if (delay > 0) faults.delayCommandLineMs = undefined;
        return new Response(streamOf(state, entry, true, closeAfter ?? cutAfter, delay), { headers: { "content-type": "application/x-ndjson" } });
      }
      case "cmdGet": {
        const state = commandFor(params);
        if (!state) return errorAnswer(404, "not_found", "command not found");
        entry.commandId = state.view.id;
        if (url.searchParams.get("wait") === "true") await state.finishedPromise;
        return Response.json(commandAnswer(state));
      }
      case "cmdLogs": {
        const state = commandFor(params);
        if (!state) return errorAnswer(404, "not_found", "command not found");
        entry.commandId = state.view.id;
        return new Response(streamOf(state, entry, false), { headers: { "content-type": "application/x-ndjson" } });
      }
      case "kill": {
        const state = commandFor(params);
        if (!state) return errorAnswer(404, "not_found", "command not found");
        entry.commandId = state.view.id;
        const signal = typeof body?.signal === "number" ? body.signal : 15;
        state.view.signals.push(signal);
        if (faults.slowKillMs) {
          entry.notes.push(`fault: slow kill ${faults.slowKillMs} ms`);
          await sleep(faults.slowKillMs);
        }
        if (!state.finished && state.process) {
          state.killRequested = true;
          try {
            state.process.kill(signal);
          } catch {
            // The command exited meanwhile.
          }
        }
        return Response.json({ command: { ...state.view } });
      }
      case "write": {
        const cwd = request.headers.get("x-cwd");
        if (!cwd || !isAbsolute(cwd)) return errorAnswer(400, "bad_request", "an absolute x-cwd header is required");
        const bytes = new Uint8Array(await request.arrayBuffer());
        entry.bytes = bytes.byteLength;
        const target = remotePath(cwd);
        // The real API extracts into x-cwd and never makes it, except the
        // sandbox's own folder, which always exists.
        if (cwd === DEFAULT_REMOTE_CWD) mkdirSync(target, { recursive: true });
        if (!existsSync(target)) {
          return tarballError(`tar: ${cwd}: Cannot open: No such file or directory\ntar: Error is not recoverable: exiting now\n`);
        }
        // GNU tar refuses members with `..` and strips a leading `/`.
        const tar = Bun.spawn(["tar", "-xzf", "-", "-C", target, "--no-same-owner"], {
          stdin: bytes,
          stdout: "ignore",
          stderr: "pipe",
        });
        const [code, stderr] = await Promise.all([tar.exited, new Response(tar.stderr as ReadableStream<Uint8Array>).text()]);
        if (code !== 0) return tarballError(stderr);
        return Response.json({});
      }
      case "extendTimeout": {
        if (typeof body?.duration !== "number" || body.duration <= 0) return errorAnswer(400, "bad_request", "duration required");
        sandbox.session.timeout += body.duration;
        // The real extend answer's session also carries sourceSnapshotId (18 keys). The captured create answer has none,
        // so only this answer adds it.
        return Response.json({ session: { ...sessionView(sandbox), sourceSnapshotId: null } });
      }
      case "stopSession": {
        sandbox.session.status = "stopped";
        sandbox.status = "stopped";
        stopCommands(sandbox);
        return Response.json({ session: sessionView(sandbox) });
      }
      default:
        return errorAnswer(404, "not_found", "no such route");
    }
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request, srv) {
      const url = new URL(request.url);
      let route: FakeVercelRoute | "unknown" = "unknown";
      let params: string[] = [];
      for (const [verb, pattern, name] of ROUTES) {
        const match = verb === request.method ? pattern.exec(url.pathname) : null;
        if (match) {
          route = name;
          params = match.slice(1).map((part) => decodeURIComponent(part));
          break;
        }
      }
      const entry: FakeVercelLogEntry = {
        seq: log.length + 1,
        at: Date.now() - started,
        method: request.method,
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        route,
        status: null,
        notes: [],
        auth: authClass(request.headers.get("authorization"), options.testToken),
      };
      log.push(entry);
      let body: unknown;
      if (route !== "write" && (request.method === "POST" || request.method === "PATCH")) {
        const text = await request.text();
        if (text.length > 0) {
          try {
            body = JSON.parse(text);
          } catch {
            entry.status = 400;
            return errorAnswer(400, "bad_request", "invalid JSON body");
          }
          entry.body = body;
        }
      }
      const answer = await (async () => {
        const auth = request.headers.get("authorization");
        if (!auth) return errorAnswer(401, "unauthorized", "missing authorization");
        const user = options.users[auth.replace(/^Bearer /, "")];
        if (!auth.startsWith("Bearer ") || !user) return errorAnswer(403, "forbidden", "not authorized");
        if (route === "unknown") return errorAnswer(404, "not_found", "no such route");
        if (TEAM_ROUTES.has(route)) {
          const teamId = url.searchParams.get("teamId");
          if (!teamId || !options.teams.some((team) => team.id === teamId)) {
            return errorAnswer(403, "forbidden", "a teamId of this user's team is required");
          }
        }
        if (!SESSION_ROUTES.has(route) && !TEAM_ROUTES.has(route) && route !== "user" && route !== "teams" && route !== "teamBySlug") {
          return errorAnswer(404, "not_found", "no such route");
        }
        return handle(route, params, url, request, srv, entry, user, body);
      })();
      entry.status = answer.status;
      await options.afterRequest?.(entry);
      return endTracked(answer, () => {
        entry.endAt = Date.now() - started;
      });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    startedAt: started,
    log,
    faults,
    remotePath,
    commands: () => [...commands.values()].map((state) => ({ ...state.view, signals: [...state.view.signals] })),
    sandboxes: () => [...byName.values()].map((sandbox) => ({
      id: sandbox.id,
      name: sandbox.name,
      persistent: sandbox.persistent,
      status: sandbox.status,
      session: sandbox.session.id,
    })),
    seedSandbox(seed: { name: string; createdAt: number; teamId?: string; projectId?: string; status?: "running" | "stopped" }) {
      const vcpus = DEFAULT_VCPUS;
      const memory = vcpus * MEMORY_MB_PER_VCPU;
      const sandbox: Sandbox = {
        id: `sbx_${++sandboxCount}`,
        name: seed.name,
        teamId: seed.teamId ?? options.teams[0]?.id ?? "team_1",
        projectId: seed.projectId ?? "prj_1",
        persistent: false,
        networkPolicy: null,
        createdAt: seed.createdAt,
        status: seed.status ?? "running",
        vcpus,
        memory,
        session: newSession(vcpus, memory, DEFAULT_SESSION_TIMEOUT_MS),
      };
      byName.set(sandbox.name, sandbox);
      bySession.set(sandbox.session.id, sandbox);
    },
    signInAs(token, user) {
      options.users[token] = user;
    },
    stop() {
      for (const sandbox of [...byName.values()]) stopCommands(sandbox);
      for (const done of pendingDrops.splice(0)) done(new Response(null, { status: 499 }));
      server.stop(true);
    },
  };
}

// ---------------------------------------------------------------------------
// Self-test.

type Check = { name: string; ok: boolean; detail: string };

async function readLines(response: Response): Promise<any[]> {
  const text = await response.text();
  return text.split("\n").filter((line) => line.length > 0).map((line) => JSON.parse(line));
}

async function selfTest(): Promise<number> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-fake-vercel-")));
  const mac = join(root, "mac", "repo");
  mkdirSync(mac, { recursive: true });
  writeFileSync(join(mac, "keep.txt"), "mac\n");
  const tokA = "fake-token-a";
  const tokB = "fake-token-b";
  const userA = { id: "user_a", username: "alice", email: "alice@example.com" };
  const userB = { id: "user_b", username: "bob", email: "bob@example.com" };
  const afterRequests: string[] = [];
  const api = startFakeVercelApi({
    users: { [tokA]: userA, [tokB]: userB },
    teams: [{ id: "team_1", slug: "one", name: "One" }, { id: "team_2", slug: "two", name: "Two" }],
    projects: { team_1: [{ id: "prj_1", name: "web" }] },
    privateRoot: join(root, "private"),
    macRoots: [mac],
    afterRequest: (entry) => { afterRequests.push(entry.route); },
  });
  const checks: Check[] = [];
  const check = (name: string, ok: boolean, detail: unknown = "") =>
    checks.push({ name, ok, detail: typeof detail === "string" ? detail : JSON.stringify(detail) });
  const call = (path: string, init: RequestInit & { token?: string | null } = {}) => {
    const headers = new Headers(init.headers);
    const token = init.token === undefined ? tokA : init.token;
    if (token !== null) headers.set("authorization", `Bearer ${token}`);
    if (init.body !== undefined && typeof init.body === "string") headers.set("content-type", "application/json");
    return fetch(`${api.url}${path}`, { ...init, headers });
  };
  const post = (path: string, body: unknown) => call(path, { method: "POST", body: JSON.stringify(body) });
  const exec = (session: string, command: string, extra: Record<string, unknown> = {}) =>
    post(`/v2/sandboxes/sessions/${session}/cmd`, { command: "bash", args: ["-c", command], cwd: mac, env: {}, wait: true, logs: true, ...extra });
  const output = (lines: any[], stream: string) => lines.filter((line) => line.stream === stream).map((line) => line.data).join("");
  const keys = (value: unknown) => JSON.stringify(Object.keys(value ?? {}).sort());

  try {
    // Account, teams and projects.
    check("no authorization is 401", (await call("/v2/user", { token: null })).status === 401);
    check("an unknown token is 403", (await call("/v2/user", { token: "other" })).status === 403);
    const meA = await (await call("/v2/user")).json() as any;
    const meB = await (await call("/v2/user", { token: tokB })).json() as any;
    check("each token signs in its own user", meA.user.id === "user_a" && meB.user.id === "user_b", [meA, meB]);
    const page1 = await (await call("/v2/teams?limit=1")).json() as any;
    const page2 = await (await call(`/v2/teams?limit=1&until=${page1.pagination.next}`)).json() as any;
    check("teams page with pagination.next", page1.teams[0].id === "team_1" && page2.teams[0].id === "team_2" && page2.pagination.next === null, [page1, page2]);
    const teamBySlug = await call("/v2/teams/two");
    check("a team found by slug", teamBySlug.status === 200 && (await teamBySlug.json() as any).id === "team_2");
    const noProjects = await (await call("/v10/projects?teamId=team_2&limit=50")).json() as any;
    check("a team with no projects lists none", Array.isArray(noProjects.projects) && noProjects.projects.length === 0, noProjects);
    check("a missing team slug is 404", (await call("/v2/teams/nope")).status === 404);
    check("a project route without teamId is 403", (await call("/v10/projects?limit=50")).status === 403);
    check("a project found by name", (await call("/v9/projects/web?teamId=team_1")).status === 200);
    check("a missing project is 404", (await call("/v9/projects/nope?teamId=team_1")).status === 404);
    const created = await post("/v11/projects?teamId=team_1", { name: "fx-sandbox" });
    const createdProject = await created.json() as any;
    check("a project create", created.status === 200 && createdProject.name === "fx-sandbox");
    check("a second create of the same name is 409", (await post("/v11/projects?teamId=team_1", { name: "fx-sandbox" })).status === 409);
    const listed = await (await call("/v10/projects?teamId=team_1&limit=50")).json() as any;
    check("projects list newest first", listed.projects[0].name === "fx-sandbox" && listed.projects[1].name === "web", listed);

    // Sandbox create, with the create fault.
    const sandboxBody = { name: "fx-0123456789abcdef", projectId: "prj_1", persistent: true, timeout: 2_700_000 };
    api.faults.createStatus = 500;
    check("create fault answers 500", (await post("/v3/sandboxes?teamId=team_1", sandboxBody)).status === 500);
    const made = await post("/v3/sandboxes?teamId=team_1", sandboxBody);
    const madeBody = await made.json() as any;
    let session = madeBody.session?.id as string;
    check("create answers the sandbox and its session", made.status === 200 && madeBody.sandbox.currentSessionId === session, madeBody);
    check("create answers routes, sandbox and session", keys(madeBody) === keys({ routes: 0, sandbox: 0, session: 0 }), madeBody);
    check("create's sandbox has the measured fields and no expiresAt",
      keys(madeBody.sandbox) === JSON.stringify(["architecture", "createdAt", "currentSessionId", "cwd", "expiryNotificationLeadTime", "failoverRegions", "image", "memory", "name", "persistent", "region", "runtime", "status", "statusUpdatedAt", "timeout", "updatedAt", "vcpus", "workloadType"]), madeBody.sandbox);
    check("create's session has the measured fields, startedAt in ms",
      keys(madeBody.session) === JSON.stringify(["architecture", "createdAt", "cwd", "id", "interactivePort", "memory", "projectId", "region", "requestedAt", "runtime", "sourceSandboxName", "startedAt", "status", "timeout", "updatedAt", "vcpus", "workloadType"]) &&
      typeof madeBody.session.startedAt === "number" && madeBody.session.startedAt > 1e12, madeBody.session);
    check("create without resources is 2 vcpus and 4096 MB",
      madeBody.sandbox.vcpus === 2 && madeBody.sandbox.memory === 4096 && madeBody.session.vcpus === 2 && madeBody.session.memory === 4096, madeBody);
    check("a second create of the same name is 409 again", (await post("/v3/sandboxes?teamId=team_1", sandboxBody)).status === 409);
    const odd = await post("/v3/sandboxes?teamId=team_1", { name: "fx-odd", projectId: "prj_1", resources: { vcpus: 3 } });
    const oddBody = await odd.json();
    check("an odd vcpus above 1 is 400 with the real error", odd.status === 400 &&
      JSON.stringify(oddBody) === JSON.stringify({ error: { code: "bad_request", message: "`resources.vcpus` should be even" } }), oddBody);
    const one = await (await post("/v3/sandboxes?teamId=team_1", { name: "fx-one", projectId: "prj_1", resources: { vcpus: 1 } })).json() as any;
    check("1 vcpu is allowed, with 2048 MB", one.sandbox?.vcpus === 1 && one.sandbox?.memory === 2048 && one.session?.memory === 2048, one);

    // Get and resize.
    const getSandbox = async () => await (await call(`/v2/sandboxes/${sandboxBody.name}?projectId=prj_1&teamId=team_1`)).json() as any;
    const got = await getSandbox();
    check("get answers sandbox, session and routes, without resumed", keys(got) === JSON.stringify(["routes", "sandbox", "session"]), got);
    check("get's expiresAt is the session start plus its timeout",
      got.sandbox.expiresAt === got.session.startedAt + got.session.timeout && got.session.timeout === 2_700_000, got);
    const patch = (resources: unknown) =>
      call(`/v2/sandboxes/${sandboxBody.name}?teamId=team_1`, { method: "PATCH", body: JSON.stringify({ resources }) });
    const badMemory = await patch({ vcpus: 4, memory: 4096 });
    const badMemoryBody = await badMemory.json() as any;
    check("patch with memory other than vcpus * 2048 is 400", badMemory.status === 400 &&
      badMemoryBody.error?.message === "`resources.memory` should equal `resources.vcpus` * 2048", badMemoryBody);
    const resized = await patch({ vcpus: 4, memory: 8192 });
    const resizedBody = await resized.json() as any;
    check("patch answers the sandbox with the new size", resized.status === 200 && keys(resizedBody) === JSON.stringify(["sandbox"]) &&
      resizedBody.sandbox.vcpus === 4 && resizedBody.sandbox.memory === 8192, resizedBody);
    check("patch is logged", api.log.some((entry) => entry.route === "updateSandbox" && entry.status === 200 && (entry.body as any)?.resources?.vcpus === 4));
    const regot = await getSandbox();
    check("get reflects the latest size", regot.sandbox.vcpus === 4 && regot.sandbox.memory === 8192, regot);

    // First use: the setup command makes the Mac path inside the private root only.
    const setup = await readLines(await post(`/v2/sandboxes/sessions/${session}/cmd`, {
      command: "bash",
      args: ["-c", `mkdir -p ${mac} && cd ${mac} && git init -q`],
      sudo: true,
      wait: true,
      logs: true,
    }));
    check("setup command exits 0", setup.at(-1)?.command?.exitCode === 0, setup);
    check("setup made the repository under the private root", existsSync(join(api.remotePath(mac), ".git")));
    check("setup left the Mac path alone", !existsSync(join(mac, ".git")));

    // Push: fs/write extracts under the private root.
    const staging = join(root, "staging");
    mkdirSync(staging, { recursive: true });
    writeFileSync(join(staging, "hello.txt"), "hello\n");
    const tarred = Bun.spawnSync(["tar", "-cz", "-C", staging, "hello.txt"], { stdout: "pipe" });
    const wrote = await call(`/v2/sandboxes/sessions/${session}/fs/write`, {
      method: "POST",
      headers: { "x-cwd": mac, "content-type": "application/gzip" },
      body: tarred.stdout,
    });
    check("fs/write answers 200", wrote.status === 200);
    check("fs/write lands under the private root, not the Mac path",
      existsSync(join(api.remotePath(mac), "hello.txt")) && !existsSync(join(mac, "hello.txt")));
    const missing = await call(`/v2/sandboxes/sessions/${session}/fs/write`, {
      method: "POST",
      headers: { "x-cwd": join(mac, "missing"), "content-type": "application/gzip" },
      body: tarred.stdout,
    });
    const missingBody = await missing.json() as any;
    check("fs/write into a missing x-cwd is 400 and names the tar error", missing.status === 400 &&
      missingBody.error?.message === "The submitted tarball could not be extracted" &&
      String(missingBody.error?.stderr).includes("Cannot open: No such file or directory") &&
      !existsSync(api.remotePath(join(mac, "missing"))), missingBody);

    // Exec rules and the stream.
    check("exec without logs is 400", (await exec(session, "true", { logs: undefined })).status === 400);
    check("exec with logs false is 400", (await exec(session, "true", { logs: false })).status === 400);
    const lines = await readLines(await exec(session, "echo hi; echo err >&2; touch made.txt; exit 7"));
    check("exec stream starts with the command and its id", typeof lines[0]?.command?.id === "string" && lines[0].command.exitCode === null, lines[0]);
    check("exec stream carries stdout and stderr", output(lines, "stdout") === "hi\n" && output(lines, "stderr") === "err\n", lines);
    check("exec stream ends with the exit code", lines.at(-1)?.command?.exitCode === 7, lines.at(-1));
    check("exec ran in the mapped repository", existsSync(join(api.remotePath(mac), "made.txt")) && !existsSync(join(mac, "made.txt")));

    // A cmd without wait, then a wait on it.
    const detached = await exec(session, "sleep 0.2; exit 3", { wait: undefined });
    const detachedBody = await detached.json() as any;
    check("a cmd without wait answers the command and its id", detached.status === 200 && keys(detachedBody) === JSON.stringify(["command"]) &&
      typeof detachedBody.command?.id === "string" && detachedBody.command.exitCode === null, detachedBody);
    const detachedDone = await (await call(`/v2/sandboxes/sessions/${session}/cmd/${detachedBody.command.id}?wait=true`)).json() as any;
    check("a wait on the cmd answers exitCode and durationMs", detachedDone.command?.exitCode === 3 &&
      typeof detachedDone.command.durationMs === "number" && detachedDone.command.durationMs >= 150, detachedDone);

    // Idle close, then logs and wait.
    api.faults.idleCloseAfterBytes = 1;
    const closed = await readLines(await exec(session, "printf a; sleep 0.4; printf b; exit 0"));
    const closedId = closed[0]?.command?.id as string;
    check("idle close ends the stream without the exit line", output(closed, "stdout") === "a" && !closed.slice(1).some((line) => line.command), closed);
    const logs = await readLines(await call(`/v2/sandboxes/sessions/${session}/cmd/${closedId}/logs`));
    check("logs carry every byte once", output(logs, "stdout") === "ab", logs);
    const waited = await (await call(`/v2/sandboxes/sessions/${session}/cmd/${closedId}?wait=true`)).json() as any;
    check("wait answers the exit code", waited.command.exitCode === 0 && waited.command.status === "exited", waited);

    // The command line held back: no line before the delay.
    api.faults.delayCommandLineMs = 400;
    const heldAt = Date.now();
    const held = await exec(session, "exit 0");
    const heldReader = held.body!.getReader();
    const heldFirst = await heldReader.read();
    const heldMs = Date.now() - heldAt;
    while (!(await heldReader.read()).done) { /* drain */ }
    check("a held command line arrives after the delay", heldMs >= 400 && new TextDecoder().decode(heldFirst.value).includes("\"command\""), `${heldMs} ms`);

    // Drop after the exec body: the command ran, or it did not.
    for (const mode of ["ran", "not_run"] as const) {
      const before = api.commands().length;
      api.faults.dropAfterExecBody = mode;
      let dropped = false;
      try {
        const answer = await exec(session, `touch dropped-${mode}.txt`);
        await answer.text();
      } catch {
        dropped = true;
      }
      for (let i = 0; i < 40 && mode === "ran" && !existsSync(join(api.remotePath(mac), `dropped-${mode}.txt`)); i += 1) await sleep(50);
      check(`drop after the exec body (${mode}) closes the connection`, dropped);
      check(`drop after the exec body (${mode}) ${mode === "ran" ? "ran" : "did not run"} the command`,
        (api.commands().length === before + (mode === "ran" ? 1 : 0)) &&
        existsSync(join(api.remotePath(mac), `dropped-${mode}.txt`)) === (mode === "ran"));
    }

    // Kill, slow kill.
    for (const slow of [0, 300]) {
      api.faults.slowKillMs = slow || undefined;
      const response = await exec(session, "sleep 30");
      const reader = response.body!.getReader();
      const first = JSON.parse(new TextDecoder().decode((await reader.read()).value).split("\n")[0]!);
      const killStarted = Date.now();
      const killed = await post(`/v2/sandboxes/sessions/${session}/cmd/${first.command.id}/kill`, { signal: 15 });
      const killMs = Date.now() - killStarted;
      let rest = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        rest += new TextDecoder().decode(value);
      }
      const last = JSON.parse(rest.trim().split("\n").at(-1)!);
      const view = api.commands().find((command) => command.id === first.command.id)!;
      check(`kill 15${slow ? " (slow)" : ""} ends the command as killed`,
        killed.status === 200 && view.status === "killed" && view.signals[0] === 15 && last.command.exitCode === 143, { view, last });
      if (slow) check("slow kill waits before it acts", killMs >= slow, `${killMs} ms`);
    }
    api.faults.slowKillMs = undefined;
    const sleeper = await (await exec(session, "sleep 30", { wait: undefined })).json() as any;
    await post(`/v2/sandboxes/sessions/${session}/cmd/${sleeper.command.id}/kill`, { signal: 15 });
    const sleeperDone = await (await call(`/v2/sandboxes/sessions/${session}/cmd/${sleeper.command.id}?wait=true`)).json() as any;
    check("a wait on a killed cmd answers exit code 143", sleeperDone.command?.exitCode === 143 && sleeperDone.command.status === "killed", sleeperDone);

    // Session gone once, then resume.
    api.faults.goneOnce = true;
    check("a stopped session answers 410", (await exec(session, "true")).status === 410);
    const resumed = await (await call(`/v2/sandboxes/${sandboxBody.name}?projectId=prj_1&resume=true&teamId=team_1`)).json() as any;
    check("resume starts a new session", resumed.session.id !== session && resumed.sandbox.currentSessionId === resumed.session.id, resumed);
    check("a resumed get says resumed: true, and its expiresAt counts from the new session",
      resumed.resumed === true && resumed.sandbox.expiresAt === resumed.session.startedAt + resumed.session.timeout, resumed);
    check("the resumed session takes the latest size", resumed.session.vcpus === 4 && resumed.session.memory === 8192, resumed.session);
    check("the old session stays 410", (await exec(session, "true")).status === 410);
    session = resumed.session.id;
    check("the new session runs commands", (await readLines(await exec(session, "exit 0"))).at(-1)?.command?.exitCode === 0);

    // Bring back: real, then hostile.
    // touch -t is the form BSD and GNU touch both accept; touch -d is GNU only.
    const bringBack = "touch -t 200001010000 .git/fx-stamp-r1 && touch back.txt && " +
      "find . -newer .git/fx-stamp-r1 ! -path './.git/*' -type f -print0 | tar -cz --null -T - | base64 -w0";
    const real = await readLines(await exec(session, bringBack));
    const realNames = tarEntries(Buffer.from(output(real, "stdout"), "base64")).map((item) => item.name).sort();
    check("bring back streams the new files", realNames.includes("./back.txt") && !realNames.some((name) => name.includes(".git/")), realNames);
    check("bring back is logged as bring_back", api.log.at(-1)?.kind === "bring_back", api.log.at(-1));
    api.faults.hostileBringBack = true;
    const before = api.commands().length;
    const hostile = await readLines(await exec(session, bringBack));
    const hostileNames = tarEntries(Buffer.from(output(hostile, "stdout"), "base64")).map((item) => item.name);
    check("hostile bring back streams the hostile entries", JSON.stringify(hostileNames) === JSON.stringify(HOSTILE_BRING_BACK_ENTRIES), hostileNames);
    check("hostile bring back ran nothing", api.commands().at(-1)?.args.length === 2 && api.commands().length === before + 1 &&
      !existsSync(join(root, "x")) && !existsSync("/abs"));

    // Extend the session.
    const extended = await (await post(`/v2/sandboxes/sessions/${session}/extend-timeout`, { duration: 1_800_000 })).json() as any;
    check("extend-timeout answers the session with the longer timeout",
      keys(extended) === JSON.stringify(["session"]) && extended.session.timeout === 2_700_000 + 1_800_000, extended);
    check("extend-timeout's session has the measured keys, sourceSnapshotId included",
      keys(extended.session) === JSON.stringify(["architecture", "createdAt", "cwd", "id", "interactivePort", "memory", "projectId", "region",
        "requestedAt", "runtime", "sourceSandboxName", "sourceSnapshotId", "startedAt", "status", "timeout", "updatedAt", "vcpus", "workloadType"]),
      extended.session);

    // Stop the session.
    const stopped = await post(`/v2/sandboxes/sessions/${session}/stop`, {});
    check("stop answers 200", stopped.status === 200, await stopped.text());
    check("a session call after stop is 410", (await exec(session, "true")).status === 410 &&
      (await post(`/v2/sandboxes/sessions/${session}/extend-timeout`, { duration: 1000 })).status === 410);

    // Isolated sandboxes: list by prefix, delete.
    const iso = { name: "fx-iso-abcd1234-0123456789ab", projectId: "prj_1", persistent: false, networkPolicy: { mode: "deny-all" } };
    check("isolated create", (await post("/v3/sandboxes?teamId=team_1", iso)).status === 200);
    const unsorted = await call("/v2/sandboxes?project=prj_1&namePrefix=fx-iso-abcd1234-&teamId=team_1");
    const unsortedBody = await unsorted.json() as any;
    check("namePrefix without sortBy=name is 400 with the real error", unsorted.status === 400 &&
      unsortedBody.error?.message === "Invalid request: `namePrefix` is only valid when `sortBy` is `name`", unsortedBody);
    const prefixed = await (await call("/v2/sandboxes?project=prj_1&namePrefix=fx-iso-abcd1234-&sortBy=name&teamId=team_1")).json() as any;
    check("list by namePrefix", prefixed.sandboxes.length === 1 && prefixed.sandboxes[0].name === iso.name, prefixed);
    check("list answers pagination and sandboxes, each with expiresAt",
      keys(prefixed) === JSON.stringify(["pagination", "sandboxes"]) && keys(prefixed.pagination) === JSON.stringify(["count", "next"]) &&
      prefixed.sandboxes.every((item: any) => typeof item.expiresAt === "number"), prefixed);
    check("delete", (await call(`/v2/sandboxes/${iso.name}?teamId=team_1`, { method: "DELETE" })).status === 200);
    check("a deleted sandbox is 404", (await call(`/v2/sandboxes/${iso.name}?projectId=prj_1&teamId=team_1`)).status === 404);
    // Test-only hooks (AC-31, N18): a seeded old sandbox, a one-shot list failure, a reported size.
    api.seedSandbox({ name: "fx-iso-seed-old", createdAt: Date.now() - 7_200_000 });
    const seededList = "/v2/sandboxes?project=prj_1&namePrefix=fx-iso-seed-&sortBy=name&teamId=team_1";
    const seeded = await (await call(seededList)).json() as any;
    check("a seeded sandbox lists with its older createdAt", seeded.sandboxes.length === 1 &&
      seeded.sandboxes[0].createdAt <= Date.now() - 7_000_000, seeded);
    api.faults.listFails = true;
    const failedList = await call(seededList);
    const nextList = await call(seededList);
    check("a one-shot list failure answers 500, and the next list works", failedList.status === 500 && nextList.status === 200, failedList.status);
    api.seedSandbox({ name: "fx-iso-seed-size", createdAt: Date.now() });
    api.faults.reportedVcpus = 2;
    const reported = await (await call("/v2/sandboxes/fx-iso-seed-size?teamId=team_1", {
      method: "PATCH",
      body: JSON.stringify({ resources: { vcpus: 4, memory: 8192 } }),
    })).json() as any;
    api.faults.reportedVcpus = undefined;
    check("a reported size can differ from the requested one", reported.sandbox?.vcpus === 2, reported);
    await call("/v2/sandboxes/fx-iso-seed-old?teamId=team_1", { method: "DELETE" });
    await call("/v2/sandboxes/fx-iso-seed-size?teamId=team_1", { method: "DELETE" });

    // Sandbox gone: the resume GET is 404, and the sandbox can be made again.
    api.faults.sandboxGone = true;
    check("sandbox gone answers 404", (await call(`/v2/sandboxes/${sandboxBody.name}?projectId=prj_1&resume=true&teamId=team_1`)).status === 404);
    check("a gone sandbox can be made again", (await post("/v3/sandboxes?teamId=team_1", sandboxBody)).status === 200);

    // The log.
    check("the log is in arrival order", api.log.every((entry, index) => entry.seq === index + 1 && (index === 0 || entry.at >= api.log[index - 1]!.at)));
    check("the log starts with the requests in the order sent",
      JSON.stringify(api.log.slice(0, 4).map((entry) => entry.route)) === JSON.stringify(["user", "user", "user", "user"]));
    check("every request got its afterRequest call", afterRequests.length === api.log.filter((entry) => entry.status !== null).length);
    check("the log never holds a token", !JSON.stringify(api.log).includes(tokA) && !JSON.stringify(api.log).includes(tokB));
    check("the Mac repository is unchanged", JSON.stringify(readdirSync(mac)) === JSON.stringify(["keep.txt"]), readdirSync(mac));
  } catch (error) {
    check("self-test ran to the end", false, error instanceof Error ? error.stack ?? error.message : String(error));
  } finally {
    api.stop();
    rmSync(root, { recursive: true, force: true });
  }
  for (const item of checks) console.log(`${item.ok ? "ok  " : "FAIL"} ${item.name}${item.ok || !item.detail ? "" : `: ${item.detail}`}`);
  const failed = checks.filter((item) => !item.ok).length;
  console.log(`${checks.length - failed}/${checks.length} fake Vercel API checks passed`);
  return failed === 0 ? 0 : 1;
}

if (import.meta.main && process.argv.includes("--self-test")) process.exit(await selfTest());
