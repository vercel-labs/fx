import { afterAll, afterEach, expect, test } from "bun:test";
import {
  execFileSync,
  spawn,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const INTERNAL_MODE = "--fx-internal-terminal-host";
const HEADER_BYTES = 28;
const TERMINAL_FIXTURE_SHELL = terminalFixtureShell();
const CLEANUP_CHILD_EXIT_TIMEOUT_MS = 5_000;
const PRIVATE_TMUX_COMMAND_TIMEOUT_MS = 5_000;
const PRIVATE_TMUX_SETTLE_TIMEOUT_MS = 5_000;
const PRIVATE_TMUX_BLOCKING_COMMAND_PHASES = 5;
const PRIVATE_TMUX_CLEANUP_TIMEOUT_MS =
  PRIVATE_TMUX_COMMAND_TIMEOUT_MS * PRIVATE_TMUX_BLOCKING_COMMAND_PHASES +
  PRIVATE_TMUX_SETTLE_TIMEOUT_MS;
const MAX_PRIVATE_TMUX_SERVERS_PER_TEST = 14;
const CLEANUP_FINALIZATION_BUDGET_MS = 5_000;
const TMUX_SHELL_START_DEADLINE_MS = 60_000;
const TMUX_MARKER_IO_DEADLINE_MS = 14_000;
const TMUX_COMMAND_STARTUP_MARKER_IO_PHASES = 4;
const TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS =
  TMUX_SHELL_START_DEADLINE_MS +
  TMUX_MARKER_IO_DEADLINE_MS * TMUX_COMMAND_STARTUP_MARKER_IO_PHASES +
  CLEANUP_FINALIZATION_BUDGET_MS;
const TMUX_COMMANDLESS_STARTUP_OBSERVATION_BUDGET_MS =
  TMUX_SHELL_START_DEADLINE_MS +
  TMUX_MARKER_IO_DEADLINE_MS +
  CLEANUP_FINALIZATION_BUDGET_MS;
const TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS = 1_000;
const NATIVE_STARTUP_OBSERVATION_BUDGET_MS = 30_000;
const TERMINAL_OPERATION_OBSERVATION_BUDGET_MS = 20_000;
const TMUX_EXPLICIT_BACKEND_TEST_TIMEOUT_MS =
  TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS * 2 +
  TMUX_COMMANDLESS_STARTUP_OBSERVATION_BUDGET_MS +
  CLEANUP_CHILD_EXIT_TIMEOUT_MS +
  CLEANUP_FINALIZATION_BUDGET_MS;
const TMUX_DELAYED_PROFILE_TEST_TIMEOUT_MS =
  TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS +
  TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS +
  CLEANUP_FINALIZATION_BUDGET_MS;
const SHELL_STARTUP_PHASE_BUDGET_MS =
  2_500 + CLEANUP_FINALIZATION_BUDGET_MS;
// Bash and zsh each run normal, boundary, and clean delayed command phases.
// Configured login, signal, and forged completion add three before finalization.
const SHELL_STARTUP_FIXTURE_TEST_TIMEOUT_MS =
  2 * 3 * SHELL_STARTUP_PHASE_BUDGET_MS +
  3 * SHELL_STARTUP_PHASE_BUDGET_MS +
  CLEANUP_FINALIZATION_BUDGET_MS;
const CLEANUP_HOOK_TIMEOUT_MS =
  Math.max(
    CLEANUP_CHILD_EXIT_TIMEOUT_MS,
    PRIVATE_TMUX_CLEANUP_TIMEOUT_MS * MAX_PRIVATE_TMUX_SERVERS_PER_TEST,
  ) + CLEANUP_FINALIZATION_BUDGET_MS;
const homes: string[] = [];
const children: ChildProcessWithoutNullStreams[] = [];
const hostPids: number[] = [];
const fixtureArtifacts: string[] = [];
let currentClientFixtureBinary: string | null = null;
let currentThreadForkFixtureBinary: string | null = null;

function loginShellProfile(): string | null {
  const shell = userInfo().shell;
  if (shell.endsWith("/zsh")) return ".zprofile";
  if (shell.endsWith("/bash")) return ".bash_profile";
  return null;
}

const privateTmuxServers = new Map<string, PrivateTmuxResource>();
const transportRoots = new Set<string>();
const TERMINAL_OWNER_SESSION = "terminal-fixture-owner";
const authorityBySession = new Map<string, Record<string, unknown>>();
const homeBySession = new Map<string, string>();
const writeLeaseSessions = new Set<string>();

type Range = { minimum: number; current: number };
type WireFrame = {
  revision: number;
  kind: number;
  subject: number;
  correlation: number;
  payload: unknown;
};

afterEach(async () => {
  await cleanupOwnedTestResources();
}, CLEANUP_HOOK_TIMEOUT_MS);

afterAll(() => {
  for (const root of fixtureArtifacts.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

async function cleanupOwnedTestResources(
  cleanupTmux: typeof cleanupPrivateTmuxServer = cleanupPrivateTmuxServer,
  waitForChildExit: typeof waitForExit = waitForCleanupChildExit,
): Promise<void> {
  const ownedHostPids = hostPids.splice(0);
  const ownedChildren = children.splice(0);
  const ownedTmuxResources = [...privateTmuxServers.values()];
  privateTmuxServers.clear();
  const ownedHomes = homes.splice(0);
  const ownedTransportRoots = [...transportRoots];
  transportRoots.clear();
  authorityBySession.clear();
  homeBySession.clear();
  writeLeaseSessions.clear();

  let firstFailure: unknown;
  let failed = false;
  const recordFailure = (error: unknown): void => {
    if (failed) return;
    failed = true;
    firstFailure = error;
  };

  for (const pid of ownedHostPids) {
    try {
      process.kill(pid, "SIGKILL");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") {
        recordFailure(error);
      }
    }
  }
  for (const child of ownedChildren) {
    try {
      if (child.exitCode === null) child.kill("SIGKILL");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") {
        recordFailure(error);
      }
    }
  }
  const childCleanupTasks = ownedChildren.map(async (child) => {
    try {
      await waitForChildExit(child);
    } catch (error) {
      recordFailure(error);
    }
  });
  const tmuxCleanupTasks = ownedTmuxResources.map(async (resource) => {
    try {
      await cleanupTmux(resource);
    } catch (error) {
      recordFailure(error);
    }
  });
  const tmuxAndFilesystemCleanup = Promise.all(tmuxCleanupTasks).then(() => {
    for (const home of ownedHomes) {
      try {
        rmSync(home, { recursive: true, force: true });
      } catch (error) {
        recordFailure(error);
      }
    }
    for (const root of ownedTransportRoots) {
      try {
        rmSync(root, { recursive: true, force: true });
      } catch (error) {
        recordFailure(error);
      }
    }
  });
  await Promise.all([...childCleanupTasks, tmuxAndFilesystemCleanup]);
  if (failed) throw firstFailure;
}

function makeHome(): string {
  const home = mkdtempSync(join(tmpdir(), "fx-terminal-host-"));
  chmodSync(home, 0o700);
  const owner = join(home, ".fx", "sessions", TERMINAL_OWNER_SESSION);
  mkdirSync(owner, { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  chmodSync(join(home, ".fx", "sessions"), 0o700);
  chmodSync(owner, 0o700);
  homes.push(home);
  return home;
}

function isolateZshStartupFixture(home: string): void {
  const contents = "unsetopt GLOBAL_RCS\n";
  const zshenv = join(home, ".zshenv");
  writeFileSync(zshenv, contents);
  expect(readFileSync(zshenv, "utf8")).toBe(contents);
}

type PrivateTmuxResource = {
  socket: string;
  durableDir: string;
  identities: Set<string>;
};

function rememberPrivateTmuxServer(home: string): PrivateTmuxResource {
  const socket = terminalTransportPaths(home).tmuxSocket;
  const existing = privateTmuxServers.get(socket);
  if (existing) return existing;
  if (privateTmuxServers.size >= MAX_PRIVATE_TMUX_SERVERS_PER_TEST) {
    throw new Error(
      `test owns more than ${MAX_PRIVATE_TMUX_SERVERS_PER_TEST} private tmux servers`,
    );
  }
  const resource = {
    socket,
    durableDir: hostPaths(home).dir,
    identities: new Set<string>(),
  };
  privateTmuxServers.set(socket, resource);
  return resource;
}

function rememberPrivateTmuxIdentities(resource: PrivateTmuxResource): void {
  if (!existsSync(resource.socket)) return;
  try {
    const names = execFileSync(
      "tmux",
      ["-S", resource.socket, "list-sessions", "-F", "#{session_name}"],
      {
        encoding: "utf8",
        stdio: "pipe",
        timeout: PRIVATE_TMUX_COMMAND_TIMEOUT_MS,
      },
    );
    for (const name of names.trim().split("\n")) {
      if (name.startsWith("fx-") && name.length === 35) {
        resource.identities.add(name.slice(3));
      }
    }
  } catch {}
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function processGroupId(pid: number): number {
  const value = Number(
    execFileSync("ps", ["-p", String(pid), "-o", "pgid="], {
      encoding: "utf8",
    }).trim(),
  );
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`missing process group for ${pid}`);
  }
  return value;
}

function processFdCount(pid: number): number {
  const proc = `/proc/${pid}/fd`;
  if (existsSync(proc)) return readdirSync(proc).length;
  const output = execFileSync(
    "lsof",
    ["-a", "-p", String(pid), "-Fn"],
    { encoding: "utf8" },
  );
  return new Set(
    output
      .split("\n")
      .filter((line) => line.startsWith("n")),
  ).size;
}

function directChildPids(pid: number): number[] {
  const output = execFileSync("ps", ["-axo", "pid=,ppid="], {
    encoding: "utf8",
  });
  return output
    .trim()
    .split("\n")
    .map((line) => line.trim().split(/\s+/).map(Number))
    .filter(([, parent]) => parent === pid)
    .map(([child]) => child);
}

type TmuxCleanupProof = {
  identities: string[];
  panePids: number[];
  processPids: number[];
};

function privateTmuxProcessPids(
  socket: string,
  identities: string[],
  timeoutMs = PRIVATE_TMUX_COMMAND_TIMEOUT_MS,
): number[] {
  const output = execFileSync("ps", ["-axo", "pid=,command="], {
    encoding: "utf8",
    timeout: timeoutMs,
  });
  return output
    .trim()
    .split("\n")
    .map((line) => {
      const match = line.trim().match(/^(\d+)\s+(.*)$/);
      return match ? { pid: Number(match[1]), command: match[2]! } : null;
    })
    .filter((entry): entry is { pid: number; command: string } => entry !== null)
    .filter((entry) =>
      entry.command.includes(socket) ||
      identities.some((identity) => entry.command.includes(identity))
    )
    .map((entry) => entry.pid);
}

function tmuxPeerArtifacts(): string[] {
  return readdirSync("/tmp")
    .filter((name) =>
      name.startsWith("fx-tmux-capture-") ||
      name.startsWith("fx-tmux-marker-")
    )
    .sort();
}

function tmuxCaptureHelperPids(): number[] {
  const output = execFileSync("ps", ["-axo", "pid=,command="], {
    encoding: "utf8",
  });
  return output
    .trim()
    .split("\n")
    .map((line) => {
      const match = line.trim().match(/^(\d+)\s+(.*)$/);
      return match ? { pid: Number(match[1]), command: match[2]! } : null;
    })
    .filter((entry): entry is { pid: number; command: string } => entry !== null)
    .filter((entry) =>
      entry.command.includes(FX_BIN) &&
      entry.command.includes("--fx-internal-terminal-tmux-capture")
    )
    .map((entry) => entry.pid)
    .sort((left, right) => left - right);
}

function tmuxBackendIdentities(resource: PrivateTmuxResource): string[] {
  const root = resource.durableDir;
  if (!existsSync(root)) return [];
  const identities = new Set<string>();
  for (const name of readdirSync(root)) {
    if (!name.endsWith("-manifest.json")) continue;
    try {
      const value = JSON.parse(readFileSync(join(root, name), "utf8")) as {
        backend_identity?: string;
      };
      if (value.backend_identity) identities.add(value.backend_identity);
    } catch {}
  }
  return [...identities];
}

async function cleanupPrivateTmuxServer(
  resource: PrivateTmuxResource,
): Promise<TmuxCleanupProof> {
  const { socket } = resource;
  for (const identity of tmuxBackendIdentities(resource)) {
    resource.identities.add(identity);
  }
  rememberPrivateTmuxIdentities(resource);
  const identities = [...resource.identities];
  let panePids: number[] = [];
  if (existsSync(socket)) {
    try {
      panePids = execFileSync(
        "tmux",
        ["-S", socket, "list-panes", "-a", "-F", "#{pane_pid}"],
        {
          encoding: "utf8",
          stdio: "pipe",
          timeout: PRIVATE_TMUX_COMMAND_TIMEOUT_MS,
        },
      )
        .trim()
        .split("\n")
        .filter(Boolean)
        .map(Number);
    } catch {}
  }
  const processPids = privateTmuxProcessPids(socket, identities);
  if (existsSync(socket)) {
    try {
      execFileSync("tmux", ["-S", socket, "kill-server"], {
        stdio: "pipe",
        timeout: PRIVATE_TMUX_COMMAND_TIMEOUT_MS,
      });
    } catch {}
  }
  for (const pid of privateTmuxProcessPids(socket, identities)) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
  }
  const settleDeadline = Date.now() + PRIVATE_TMUX_SETTLE_TIMEOUT_MS;
  await waitFor(() => {
    const remainingMs = settleDeadline - Date.now();
    if (remainingMs <= 0) return false;
    return panePids.every((pid) => !processExists(pid)) &&
      privateTmuxProcessPids(socket, identities, remainingMs).length === 0;
  }, PRIVATE_TMUX_SETTLE_TIMEOUT_MS);
  for (const identity of identities) {
    rmSync(`/tmp/fx-tmux-capture-${identity}.sock`, { force: true });
    rmSync(`/tmp/fx-tmux-marker-${identity}.sock`, { force: true });
  }
  rmSync(socket, { force: true });
  return { identities, panePids, processPids };
}

async function runClientFixture(
  home: string,
  idleMs = 500,
  extraEnv: NodeJS.ProcessEnv = {},
  binary = FX_BIN,
) {
  const current = binary === FX_BIN;
  const executable = current ? buildCurrentClientFixture() : binary;
  const args = current ? [] : ["--fx-internal-terminal-client-fixture"];
  const child = spawn(executable, args, {
    env: {
      ...process.env,
      HOME: home,
      SHELL: TERMINAL_FIXTURE_SHELL,
      FX_TERMINAL_HOST_IDLE_MS: String(idleMs),
      ...extraEnv,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  const stdout = streamText(child.stdout);
  const stderr = streamText(child.stderr);
  const exitCode = await waitForExit(child);
  return { exitCode, stdout: await stdout, stderr: await stderr };
}

function buildCurrentClientFixture(): string {
  if (currentClientFixtureBinary !== null) return currentClientFixtureBinary;
  const repoRoot = join(import.meta.dir, "../..");
  const fixtureRoot = mkdtempSync(join(tmpdir(), "fx-terminal-client-fixture-"));
  const binary = join(fixtureRoot, "terminal-client-fixture");
  fixtureArtifacts.push(fixtureRoot);
  execFileSync(
    "zig",
    [
      "build-exe",
      "-ODebug",
      "-lc",
      `-femit-bin=${binary}`,
      join(repoRoot, "src", "terminal_client_fixture.zig"),
    ],
    { cwd: repoRoot, stdio: "pipe", timeout: 120_000 },
  );
  currentClientFixtureBinary = binary;
  return binary;
}

function buildThreadForkFixture(): string {
  if (currentThreadForkFixtureBinary !== null) {
    return currentThreadForkFixtureBinary;
  }
  const repoRoot = join(import.meta.dir, "../..");
  const fixtureRoot = mkdtempSync(join(tmpdir(), "fx-terminal-thread-fork-"));
  const source = join(fixtureRoot, "thread-fork.c");
  const binary = join(fixtureRoot, "thread-fork");
  fixtureArtifacts.push(fixtureRoot);
  writeFileSync(
    source,
    String.raw`#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *proof_path;
static const char *term_path;

static void on_term(int signal_number) {
    (void)signal_number;
    int fd = open(term_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        (void)write(fd, "term", 4);
        (void)close(fd);
    }
    _exit(0);
}

static void *fork_child(void *unused) {
    (void)unused;
    int ready[2];
    if (pipe(ready) != 0) _exit(69);
    pid_t worker_tid = (pid_t)syscall(SYS_gettid);
    pid_t child_pid = fork();
    if (child_pid < 0) _exit(70);
    if (child_pid == 0) {
        close(ready[0]);
        if (setpgid(0, 0) != 0) _exit(71);
        struct sigaction action = {0};
        action.sa_handler = on_term;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGTERM, &action, NULL) != 0) _exit(72);
        (void)write(ready[1], "1", 1);
        close(ready[1]);
        for (;;) pause();
    }

    close(ready[1]);
    char ready_byte = 0;
    if (read(ready[0], &ready_byte, 1) != 1) _exit(74);
    close(ready[0]);

    int fd = open(proof_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) _exit(73);
    dprintf(fd, "%d %d %d\n", getpid(), worker_tid, child_pid);
    close(fd);
    (void)write(STDOUT_FILENO, "thread-fork-ready\n", 18);
    int status = 0;
    (void)waitpid(child_pid, &status, 0);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    proof_path = argv[1];
    term_path = argv[2];
    pthread_t worker;
    if (pthread_create(&worker, NULL, fork_child, NULL) != 0) return 65;
    if (pthread_join(worker, NULL) != 0) return 66;
    return 0;
}
`,
  );
  execFileSync(
    "zig",
    ["cc", "-O2", "-pthread", source, "-o", binary],
    { cwd: repoRoot, stdio: "pipe", timeout: 120_000 },
  );
  currentThreadForkFixtureBinary = binary;
  return binary;
}

buildCurrentClientFixture();

function hostPaths(home: string) {
  const dir = join(home, ".fx", "terminal-host");
  return {
    dir,
    socket: join(dir, "host.sock"),
    lock: join(dir, "host.lock"),
    identity: join(dir, "host.json"),
  };
}

function terminalTransportPaths(home: string) {
  const durable = hostPaths(home);
  const capacity = process.platform === "darwin"
    ? 104
    : process.platform === "linux"
    ? 108
    : 0;
  if (capacity === 0 || Buffer.byteLength(durable.socket) < capacity) {
    return {
      dir: durable.dir,
      socket: durable.socket,
      tmuxSocket: join(durable.dir, "tmux.sock"),
    };
  }
  const digest = createHash("sha256")
    .update("fx.terminal.transport.v1\0")
    .update(home)
    .digest("hex")
    .slice(0, 32);
  const uid = process.getuid?.();
  if (uid === undefined) throw new Error("missing Unix uid");
  const base = process.platform === "darwin" ? "/private/tmp" : "/tmp";
  const dir = join(base, `fx-terminal-${uid}-${digest}`);
  return {
    dir,
    socket: join(dir, "host.sock"),
    tmuxSocket: join(dir, "tmux.sock"),
  };
}

function makeLongHome(endpointBytes = 141): string {
  const root = mkdtempSync(join(tmpdir(), "fx-terminal-long-home-"));
  const endpointSuffix = join(".fx", "terminal-host", "host.sock");
  const componentBytes = endpointBytes -
    Buffer.byteLength(root) -
    Buffer.byteLength(endpointSuffix) -
    2;
  if (componentBytes <= 0) throw new Error("temporary root is too long");
  const home = join(root, "x".repeat(componentBytes));
  mkdirSync(home, { recursive: true, mode: 0o700 });
  chmodSync(home, 0o700);
  const owner = join(home, ".fx", "sessions", TERMINAL_OWNER_SESSION);
  mkdirSync(owner, { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  chmodSync(join(home, ".fx", "sessions"), 0o700);
  chmodSync(owner, 0o700);
  homes.push(home, root);
  transportRoots.add(terminalTransportPaths(home).dir);
  return home;
}

function durableTerminalRecord(home: string): {
  path: string;
  value: { session_id: string; lifecycle: string };
} {
  const state = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
  );
  const name = readdirSync(state).find((entry) =>
    entry.startsWith("record-") && entry.endsWith(".json")
  );
  if (!name) throw new Error("terminal record not found");
  const path = join(state, name);
  return {
    path,
    value: JSON.parse(readFileSync(path, "utf8")),
  };
}

function durableTerminalRecordFor(
  home: string,
  sessionId: string,
): Record<string, unknown> {
  return JSON.parse(readFileSync(join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
    `record-${sessionId}.json`,
  ), "utf8"));
}

function durableEventIds(home: string, sessionId: string): number[] {
  const state = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
  );
  const prefix = `event-${sessionId}-`;
  return readdirSync(state)
    .filter((entry) => entry.startsWith(prefix) && entry.endsWith(".json"))
    .map((entry) => Number(entry.slice(prefix.length, -".json".length)))
    .sort((left, right) => left - right);
}

function rememberRecoveredAuthority(
  sessionId: string,
  cwd: string,
  backend: "native" | "tmux",
): void {
  const persistence = (withPersistence({ cwd, backend }) as {
    persistence: {
      grant: { principal: Record<string, unknown>; actor: string; generation: unknown };
      proof: unknown;
    };
  }).persistence;
  authorityBySession.set(sessionId, {
    principal: persistence.grant.principal,
    actor: persistence.grant.actor,
    generation: persistence.grant.generation,
    proof: persistence.proof,
  });
}

function startHost(
  home: string,
  range: Range = { minimum: 4, current: 5 },
  idleMs = 350,
  extraEnv: NodeJS.ProcessEnv = {},
  binary = FX_BIN,
): ChildProcessWithoutNullStreams {
  const child = spawn(binary, [INTERNAL_MODE], {
    env: {
      ...process.env,
      HOME: home,
      SHELL: TERMINAL_FIXTURE_SHELL,
      FX_TERMINAL_HOST_IDLE_MS: String(idleMs),
      FX_TERMINAL_HOST_PROTOCOL_MIN: String(range.minimum),
      FX_TERMINAL_HOST_PROTOCOL_CURRENT: String(range.current),
      ...extraEnv,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  return child;
}

function startHostWithAdvertisedProtocol(
  home: string,
  idleMs = 350,
  extraEnv: NodeJS.ProcessEnv = {},
  binary = FX_BIN,
): ChildProcessWithoutNullStreams {
  const child = spawn(binary, [INTERNAL_MODE], {
    env: {
      ...process.env,
      HOME: home,
      SHELL: TERMINAL_FIXTURE_SHELL,
      FX_TERMINAL_HOST_IDLE_MS: String(idleMs),
      ...extraEnv,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  return child;
}

const protocolFixtureDefinitions = {
  incompatible: {
    range: { minimum: 2, current: 3 },
    capabilities: 3,
  },
  previous: {
    range: { minimum: 3, current: 4 },
    capabilities: 3,
  },
  signal_limited: {
    range: { minimum: 4, current: 5 },
    capabilities: 15,
  },
  current_checkpoint: {
    range: { minimum: 4, current: 5 },
    capabilities: 31,
  },
} as const;

function protocolFixtureEnv(
  fixture: (typeof protocolFixtureDefinitions)[keyof typeof protocolFixtureDefinitions],
): NodeJS.ProcessEnv {
  return {
    FX_TERMINAL_HOST_PROTOCOL_MIN: String(fixture.range.minimum),
    FX_TERMINAL_HOST_PROTOCOL_CURRENT: String(fixture.range.current),
    FX_TERMINAL_HOST_PROTOCOL_CAPABILITIES: String(fixture.capabilities),
  };
}

async function waitFor(
  predicate: () => boolean | Promise<boolean>,
  timeoutMs = 2_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error("fixture timed out");
    await Bun.sleep(10);
  }
}

async function waitForExit(child: ChildProcessWithoutNullStreams): Promise<number> {
  if (child.exitCode !== null) return child.exitCode;
  if (child.signalCode !== null) return 128;
  return await new Promise<number>((resolve, reject) => {
    child.once("exit", (code) => resolve(code ?? 1));
    child.once("error", reject);
  });
}

async function waitForCleanupChildExit(
  child: ChildProcessWithoutNullStreams,
): Promise<number> {
  if (child.exitCode !== null) return child.exitCode;
  if (child.signalCode !== null) return 128;
  return await new Promise<number>((resolve, reject) => {
    const finish = (result: () => void): void => {
      clearTimeout(timeout);
      child.off("exit", onExit);
      child.off("error", onError);
      result();
    };
    const onExit = (code: number | null): void =>
      finish(() => resolve(code ?? 1));
    const onError = (error: Error): void => finish(() => reject(error));
    const timeout = setTimeout(() => {
      finish(() => reject(new Error(
        `fixture child ${child.pid ?? "unknown"} did not exit within ` +
          `${CLEANUP_CHILD_EXIT_TIMEOUT_MS}ms of cleanup`,
      )));
    }, CLEANUP_CHILD_EXIT_TIMEOUT_MS);
    child.once("exit", onExit);
    child.once("error", onError);
  });
}

async function streamText(stream: NodeJS.ReadableStream): Promise<string> {
  let text = "";
  for await (const chunk of stream) text += chunk.toString();
  return text;
}

function encodeFrame(
  revision: number,
  kind: number,
  subject: number,
  correlation: number,
  payload: unknown,
  requiredCapabilities = 0,
): Buffer {
  const body = Buffer.from(JSON.stringify(payload));
  const header = Buffer.alloc(HEADER_BYTES);
  header.write("FXTH", 0, "ascii");
  header.writeUInt16LE(revision, 4);
  header[6] = kind;
  header[7] = subject;
  header.writeBigUInt64LE(BigInt(requiredCapabilities), 8);
  header.writeBigUInt64LE(BigInt(correlation), 16);
  header.writeUInt32LE(body.length, 24);
  return Buffer.concat([header, body]);
}

class FrameClient {
  private buffer = Buffer.alloc(0);
  private wake: (() => void) | undefined;
  private failure: Error | undefined;

  private constructor(readonly socket: Socket) {
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.wake?.();
      this.wake = undefined;
    });
    socket.on("error", (error) => {
      this.failure = error;
      this.wake?.();
      this.wake = undefined;
    });
    socket.on("close", () => {
      this.failure ??= new Error("socket closed");
      this.wake?.();
      this.wake = undefined;
    });
  }

  static async connect(path: string): Promise<FrameClient> {
    const socket = createConnection(path);
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    return new FrameClient(socket);
  }

  send(frame: Buffer): void {
    this.socket.write(frame);
  }

  async read(): Promise<WireFrame> {
    while (this.buffer.length < HEADER_BYTES) await this.waitForData();
    const payloadLength = this.buffer.readUInt32LE(24);
    const frameLength = HEADER_BYTES + payloadLength;
    while (this.buffer.length < frameLength) await this.waitForData();
    const bytes = this.buffer.subarray(0, frameLength);
    this.buffer = this.buffer.subarray(frameLength);
    expect(bytes.subarray(0, 4).toString("ascii")).toBe("FXTH");
    return {
      revision: bytes.readUInt16LE(4),
      kind: bytes[6],
      subject: bytes[7],
      correlation: Number(bytes.readBigUInt64LE(16)),
      payload: JSON.parse(bytes.subarray(HEADER_BYTES).toString("utf8")),
    };
  }

  close(): void {
    this.socket.end();
  }

  private async waitForData(): Promise<void> {
    if (this.failure) throw this.failure;
    await new Promise<void>((resolve) => {
      this.wake = resolve;
    });
    if (this.failure) throw this.failure;
  }
}

async function handshake(
  socketPath: string,
  clientRange: Range,
  capabilities = 31,
  helloRevision = clientRange.current,
): Promise<{
  client: FrameClient;
  hostRange: Range;
  hostCapabilities: number;
  helloRevision: number;
  revision?: number;
}> {
  const client = await FrameClient.connect(socketPath);
  client.send(
    encodeFrame(helloRevision, 0, 0, 0, {
      hello: {
        range: clientRange,
        capabilities,
        required_capabilities: 0,
      },
    }),
  );
  const hello = await client.read();
  const hostHello = (hello.payload as {
    hello: { range: Range; capabilities: number };
  }).hello;
  const hostRange = hostHello.range;
  const minimum = Math.max(clientRange.minimum, hostRange.minimum);
  const current = Math.min(clientRange.current, hostRange.current);
  return {
    client,
    hostRange,
    hostCapabilities: hostHello.capabilities,
    helloRevision: hello.revision,
    revision: minimum <= current ? current : undefined,
  };
}

async function requestScreen(
  client: FrameClient,
  revision: number,
  correlation: number,
): Promise<WireFrame> {
  client.send(
    encodeFrame(revision, 1, 2, correlation, {
      request: { screen: { session_id: "terminal-fixture" } },
    }),
  );
  return client.read();
}

const actionSubjects = {
  start: 0,
  read: 1,
  screen: 2,
  write: 3,
  wait: 4,
  monitor: 5,
  inspect: 6,
  list: 7,
  resize: 8,
  signal: 9,
  close: 10,
} as const;

async function requestAction(
  client: FrameClient,
  revision: number,
  correlation: number,
  action: keyof typeof actionSubjects,
  value: unknown,
): Promise<WireFrame> {
  let payload = action === "start"
    ? ("persistence" in (value as Record<string, unknown>)
      ? value
      : withPersistence(value as Record<string, unknown>))
    : withAuthority(action, value as Record<string, unknown>);
  const writeSessionId = action === "write"
    ? (value as { session_id: string }).session_id
    : undefined;
  if (
    action === "write" &&
    !("lease" in (value as Record<string, unknown>)) &&
    !writeLeaseSessions.has(writeSessionId!)
  ) {
    const acquire = withAuthority("write", {
      session_id: (value as { session_id: string }).session_id,
      lease: "acquire",
    });
    client.send(
      encodeFrame(
        revision,
        1,
        actionSubjects.write,
        correlation + 1_000_000,
        { request: { write: acquire } },
        1,
      ),
    );
    success(await client.read(), "write");
    writeLeaseSessions.add(writeSessionId!);
    payload = { ...(payload as Record<string, unknown>), lease: "use" };
  } else if (action === "write" && !("lease" in (value as Record<string, unknown>))) {
    payload = { ...(payload as Record<string, unknown>), lease: "use" };
  }
  client.send(
    encodeFrame(
      revision,
      1,
      actionSubjects[action],
      correlation,
      { request: { [action]: payload } },
      1,
    ),
  );
  const frame = await client.read();
  if (action === "start") rememberStartAuthority(frame, payload as Record<string, unknown>);
  if (action === "write" && (value as { lease?: string }).lease === "acquire" &&
      (frame.payload as { response?: { success?: unknown } }).response?.success) {
    writeLeaseSessions.add(writeSessionId!);
  }
  if (
    (action === "close" ||
      (action === "write" && ["release", "revoke"].includes(
        (value as { lease?: string }).lease ?? "",
      ))) && writeSessionId
  ) {
    writeLeaseSessions.delete(writeSessionId);
  }
  return frame;
}

function withAuthority(
  action: keyof typeof actionSubjects,
  value: Record<string, unknown>,
): Record<string, unknown> {
  const sessionId = action === "list"
    ? authorityBySession.keys().next().value
    : value.session_id as string;
  const authority = value.authority ??
    (sessionId ? authorityBySession.get(sessionId) : undefined);
  if (!authority) return value;
  if (action !== "list") return { ...value, authority };
  if (value.owner_authority) return value;
  const { authority: _, authority_session_id: __, ...filters } = value;
  return {
    ...filters,
    owner_authority: ownerCatalogAuthorityForSession(sessionId, authority),
  };
}

function rememberStartAuthority(
  frame: WireFrame,
  request: Record<string, unknown>,
): void {
  const start = (frame.payload as {
    response?: { success?: { start?: { session?: { session_id?: string } } } };
  }).response?.success?.start;
  const failedSessionId = (frame.payload as {
    response?: { failure?: { action?: string; session_id?: string } };
  }).response?.failure;
  const sessionId = start?.session?.session_id ??
    (failedSessionId?.action === "start" ? failedSessionId.session_id : undefined);
  const persistence = request.persistence as {
    grant: { principal: Record<string, unknown>; actor: string; generation: unknown };
    proof: unknown;
  } | undefined;
  if (!sessionId || !persistence) return;
  authorityBySession.set(sessionId, {
    principal: persistence.grant.principal,
    actor: persistence.grant.actor,
    generation: persistence.grant.generation,
    proof: persistence.proof,
  });
  const home = homes.find((candidate) => existsSync(join(
    candidate,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
    `record-${sessionId}.json`,
  )));
  if (home) homeBySession.set(sessionId, home);
}

function ownerCatalogAuthorityForSession(
  sessionId: string,
  sessionAuthority: Record<string, unknown>,
): Record<string, unknown> {
  const home = homeBySession.get(sessionId);
  if (!home) throw new Error(`terminal owner home not found for ${sessionId}`);
  const principal = sessionAuthority.principal as Record<string, string>;
  const actor = sessionAuthority.actor as string;
  const ownerPrincipal = {
    profile_user: principal.profile_user,
    durable_session_id: principal.durable_session_id,
    workspace_root: principal.workspace_root,
    transport_role: principal.transport_role,
  };
  const proof = { bytes: Array(32).fill(11) };
  const claim = { principal: ownerPrincipal, actor, proof };
  const key = ownerCatalogDigest(
    "fx.terminal.owner-catalog-key.v2\0",
    ownerPrincipal,
    actor,
  ).toString("hex");
  const verifier = ownerCatalogDigest(
    "fx.terminal.owner-catalog-proof.v2\0",
    ownerPrincipal,
    actor,
    Buffer.from(proof.bytes),
  );
  const terminalRoot = join(
    home,
    ".fx",
    "sessions",
    ownerPrincipal.durable_session_id,
    "terminal",
  );
  const state = join(terminalRoot, "state");
  const proofs = join(terminalRoot, "proofs");
  mkdirSync(state, { recursive: true, mode: 0o700 });
  mkdirSync(proofs, { recursive: true, mode: 0o700 });
  writeFileSync(join(proofs, `catalog-proof-${key}`), Buffer.from(proof.bytes), {
    mode: 0o600,
  });
  writeFileSync(
    join(state, `catalog-authority-${key}.json`),
    JSON.stringify({
      schema_version: 2,
      principal: ownerPrincipal,
      actor,
      verifier: [...verifier],
    }),
    { mode: 0o600 },
  );
  return claim;
}

function ownerCatalogDigest(
  domain: string,
  principal: Record<string, string>,
  actor: string,
  proof?: Buffer,
): Buffer {
  const hash = createHash("sha256");
  hash.update(domain);
  if (proof) hash.update(proof);
  hash.update(actor);
  hash.update(principal.transport_role);
  for (const value of [
    principal.profile_user,
    principal.durable_session_id,
    principal.workspace_root,
  ]) {
    const bytes = Buffer.from(value);
    const length = Buffer.alloc(8);
    length.writeBigUInt64LE(BigInt(bytes.length));
    hash.update(length);
    hash.update(bytes);
  }
  return hash.digest();
}

function authorityVariant(
  sessionId: string,
  changes: {
    actor?: string;
    principal?: Record<string, unknown>;
    generation?: unknown;
    proof?: unknown;
  },
): Record<string, unknown> {
  const current = authorityBySession.get(sessionId)! as {
    principal: Record<string, unknown>;
    actor: string;
    generation: unknown;
    proof: unknown;
  };
  return {
    ...current,
    ...changes,
    principal: changes.principal ?? current.principal,
  };
}

function withPersistence(value: Record<string, unknown>): Record<string, unknown> {
  const cwd = typeof value.cwd === "string" ? value.cwd : "/";
  const backend = value.backend === "tmux" ? "tmux" : "native";
  const repeatedProbes = (
    value.initial_monitors as Array<{
      condition: { custom_probe?: { command: string; cwd: string } };
      check_schedule?: { interval_ms: number };
      notify_schedule: unknown;
      lifetime: unknown;
    }> | undefined
  )?.flatMap((monitor) => monitor.condition.custom_probe && monitor.check_schedule
    ? [{
      command: monitor.condition.custom_probe.command,
      cwd: monitor.condition.custom_probe.cwd,
      check_schedule: monitor.check_schedule,
      notify_schedule: monitor.notify_schedule,
      lifetime: monitor.lifetime,
    }]
    : []) ?? [];
  return {
    ...value,
    persistence: {
      grant: {
        principal: {
          profile_user: "terminal-fixture",
          durable_session_id: TERMINAL_OWNER_SESSION,
          workspace_root: cwd,
          cwd,
          transport_role: "interactive",
          backend,
          lifetime: "session",
        },
        actor: "agent",
        controls: {
          read: true,
          screen: true,
          write: true,
          wait: true,
          monitor: true,
          inspect: true,
          list: true,
          resize: true,
          signal: true,
          close: true,
        },
        generation: { value: 1 },
        repeated_probes: repeatedProbes,
      },
      proof: { bytes: Array(32).fill(7) },
      direct_human_model_read_only: false,
    },
  };
}

function success(frame: WireFrame, action: string): Record<string, unknown> {
  const response = (frame.payload as {
    response?: { success?: Record<string, Record<string, unknown>> };
  }).response;
  const value = response?.success?.[action];
  if (!value) {
    throw new Error(
      `expected successful ${action} response: ${JSON.stringify(frame.payload)}`,
    );
  }
  return value;
}

function failure(frame: WireFrame): { action: string; code: string } {
  const value = (
    frame.payload as {
      response?: { failure?: { action: string; code: string } };
    }
  ).response?.failure;
  if (!value) throw new Error("expected failure response");
  return value;
}

function failureCode(frame: WireFrame): string | undefined {
  return (frame.payload as {
    response?: { failure?: { code?: string } };
  }).response?.failure?.code;
}

async function readSession(
  client: FrameClient,
  revision: number,
  correlation: number,
  sessionId: string,
  offset = 0,
): Promise<{ output: string; session: Record<string, unknown> }> {
  const frame = await requestAction(client, revision, correlation, "read", {
    session_id: sessionId,
    cursor: { segment: 1, offset },
  });
  return success(frame, "read") as {
    output: string;
    session: Record<string, unknown>;
  };
}

async function startCommand(
  client: FrameClient,
  revision: number,
  correlation: number,
  options: {
    cwd: string;
    command?: string;
    shell?: unknown;
    backend?: "native" | "tmux";
    returnWhen?: unknown;
    waitMs?: number;
    dimensions?: { rows: number; columns: number };
    initialMonitors?: unknown[];
    startupAttempts?: number;
  },
): Promise<Record<string, unknown>> {
  const tmuxResource = options.backend === "tmux"
    ? rememberPrivateTmuxServer(options.cwd)
    : null;
  const startupAttempts = Math.max(1, options.startupAttempts ?? 1);
  let frame: WireFrame | undefined;
  for (let attempt = 0; attempt < startupAttempts; attempt++) {
    frame = await requestAction(
      client,
      revision,
      correlation + attempt * 10_000,
      "start",
      {
        cwd: options.cwd,
        command: options.command,
        shell: options.shell ?? { user_login: {} },
        backend: options.backend ?? "native",
        return_when: options.returnWhen ?? { started: {} },
        wait_ceiling_ms: options.waitMs ?? 20_000,
        dimensions: options.dimensions ?? { rows: 24, columns: 80 },
        initial_monitors: options.initialMonitors ?? [],
      },
    );
    if (failureCode(frame) !== "startup_failed" || attempt + 1 === startupAttempts) {
      break;
    }
    await Bun.sleep(50);
  }
  if (tmuxResource) rememberPrivateTmuxIdentities(tmuxResource);
  return success(frame!, "start");
}

async function finishStartupObservation(
  client: FrameClient,
  revision: number,
  correlation: number,
  initial: Record<string, unknown>,
  backend: "native" | "tmux",
  returnWhen: unknown,
  safetyCeilingMs: number,
): Promise<Record<string, unknown>> {
  const outcome = initial.outcome as Record<string, unknown>;
  if (!("safety_ceiling" in outcome)) return initial;
  expect(initial).toMatchObject({
    outcome: { safety_ceiling: {} },
    session: { backend },
  });
  expect(["starting", "running"]).toContain(
    (initial.session as { lifecycle: string }).lifecycle,
  );
  const sessionId = (initial.session as { session_id: string }).session_id;
  const observed = success(
    await requestAction(client, revision, correlation, "wait", {
      session_id: sessionId,
      return_when: returnWhen,
      safety_ceiling_ms: safetyCeilingMs,
    }),
    "wait",
  );
  if ("safety_ceiling" in (observed.outcome as Record<string, unknown>)) {
    throw new Error(
      `terminal startup did not finish within the observation budget: ${JSON.stringify(observed)}`,
    );
  }
  return observed;
}

async function startInteractiveTmuxFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  options: {
    cwd: string;
    command: string;
    marker: string;
  },
): Promise<Record<string, unknown>> {
  const started = await finishStartupObservation(
    client,
    revision,
    correlation + 1,
    await startCommand(client, revision, correlation, {
      cwd: options.cwd,
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { started: {} },
      waitMs: TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS,
    }),
    "tmux",
    { started: {} },
    TMUX_COMMANDLESS_STARTUP_OBSERVATION_BUDGET_MS,
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  success(
    await requestAction(client, revision, correlation + 2, "write", {
      session_id: sessionId,
      payload: { text: `${options.command}\n` },
    }),
    "write",
  );
  const ready = success(
    await requestAction(client, revision, correlation + 3, "wait", {
      session_id: sessionId,
      return_when: { match: options.marker },
      safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    }),
    "wait",
  );
  expect(ready.outcome).toEqual({ condition_met: {} });
  return started;
}

async function forceCloseStartedFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  started: Record<string, unknown>,
): Promise<void> {
  const sessionId = (started.session as { session_id: string }).session_id;
  success(
    await requestAction(client, revision, correlation, "close", {
      session_id: sessionId,
      policy: "force",
    }),
    "close",
  );
}

async function forceCloseTerminalFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  sessionId: string,
): Promise<void> {
  success(
    await requestAction(
      client,
      revision,
      correlation,
      "close",
      { session_id: sessionId, policy: "force" },
    ),
    "close",
  );
}

type StartedFixtureCleanup = {
  correlation: number;
  started: Record<string, unknown>;
};

async function forceCloseStartedFixtures(
  client: FrameClient,
  revision: number,
  cleanups: StartedFixtureCleanup[],
): Promise<void> {
  for (const cleanup of cleanups) {
    await forceCloseStartedFixture(
      client,
      revision,
      cleanup.correlation,
      cleanup.started,
    );
  }
}

async function startNativeShellFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  options: {
    cwd: string;
    shell?: unknown;
    dimensions?: { rows: number; columns: number };
    initialMonitors?: unknown[];
  },
): Promise<Record<string, unknown>> {
  let lastObservation: Record<string, unknown> | undefined;
  const deferredCleanup: StartedFixtureCleanup[] = [];
  for (let attempt = 0; attempt < 2; attempt++) {
    const attemptCorrelation = correlation + attempt * 10_000;
    const initial = await startCommand(client, revision, attemptCorrelation, {
      cwd: options.cwd,
      shell: options.shell ?? {
        executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true },
      },
      backend: "native",
      returnWhen: { started: {} },
      waitMs: NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
      dimensions: options.dimensions,
      initialMonitors: options.initialMonitors,
    });
    const outcome = initial.outcome as Record<string, unknown>;
    if (!("safety_ceiling" in outcome)) {
      await forceCloseStartedFixtures(client, revision, deferredCleanup);
      return initial;
    }

    lastObservation = initial;
    deferredCleanup.push({
      correlation: attemptCorrelation + 9_000,
      started: initial,
    });
    if (attempt === 0) {
      console.error("Retrying native shell fixture after startup observation ceiling");
    }
  }
  await forceCloseStartedFixtures(client, revision, deferredCleanup);
  throw new Error(
    `native shell startup retry exhausted: ${JSON.stringify(lastObservation)}`,
  );
}

async function startInteractiveNativeFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  options: {
    cwd: string;
    command: string;
    marker: string;
    shell?: unknown;
    dimensions?: { rows: number; columns: number };
    initialMonitors?: unknown[];
  },
): Promise<Record<string, unknown>> {
  const started = await startNativeShellFixture(client, revision, correlation, options);
  const sessionId = (started.session as { session_id: string }).session_id;
  success(
    await requestAction(client, revision, correlation + 2, "write", {
      session_id: sessionId,
      payload: { text: `${options.command}\n` },
    }),
    "write",
  );
  const ready = success(
    await requestAction(client, revision, correlation + 3, "wait", {
      session_id: sessionId,
      return_when: { match: options.marker },
      safety_ceiling_ms: NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2,
    }),
    "wait",
  );
  expect(ready.outcome).toEqual({ condition_met: {} });
  return started;
}

async function startNativeCommandFixture(
  client: FrameClient,
  revision: number,
  correlation: number,
  options: {
    cwd: string;
    command: string;
    shell: unknown;
    returnWhen: unknown;
    waitMs?: number;
    dimensions?: { rows: number; columns: number };
    initialMonitors?: unknown[];
  },
): Promise<Record<string, unknown>> {
  let lastObservation: Record<string, unknown> | undefined;
  const deferredCleanup: StartedFixtureCleanup[] = [];
  for (let attempt = 0; attempt < 2; attempt++) {
    const attemptCorrelation = correlation + attempt * 3;
    const startedInitial = await startCommand(
      client,
      revision,
      attemptCorrelation,
      {
        cwd: options.cwd,
        command: options.command,
        shell: options.shell,
        backend: "native",
        returnWhen: options.returnWhen,
        waitMs: Math.max(
          options.waitMs ?? 0,
          NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
        ),
        dimensions: options.dimensions,
        initialMonitors: options.initialMonitors,
      },
    );
    const outcome = startedInitial.outcome as Record<string, unknown>;
    if (!("safety_ceiling" in outcome)) {
      await forceCloseStartedFixtures(client, revision, deferredCleanup);
      return startedInitial;
    }

    lastObservation = startedInitial;
    deferredCleanup.push({
      correlation: attemptCorrelation + 2,
      started: startedInitial,
    });
    if (attempt === 0) {
      console.error("Retrying native command fixture after startup observation ceiling");
    }
  }
  await forceCloseStartedFixtures(client, revision, deferredCleanup);
  throw new Error(
    `native command startup retry exhausted: ${JSON.stringify(lastObservation)}`,
  );
}

test("fresh hidden host is singular, correlated, reconnectable, private, and idle-clean", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const contenders = Array.from({ length: 4 }, () => startHost(home));
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  await waitFor(
    () => contenders.filter((child) => child.exitCode === null).length === 1,
  );

  expect(statSync(join(home, ".fx")).mode & 0o777).toBe(0o700);
  expect(statSync(paths.dir).mode & 0o777).toBe(0o700);
  expect(statSync(paths.lock).mode & 0o777).toBe(0o600);
  expect(statSync(paths.socket).mode & 0o777).toBe(0o600);
  expect(statSync(paths.identity).mode & 0o777).toBe(0o600);

  const identityBefore = readFileSync(paths.identity, "utf8");
  const first = await handshake(paths.socket, { minimum: 4, current: 4 });
  expect(first.revision).toBe(4);
  const firstResponse = await requestScreen(first.client, first.revision!, 71);
  expect(firstResponse.kind).toBe(2);
  expect(firstResponse.subject).toBe(2);
  expect(firstResponse.correlation).toBe(71);
  expect(firstResponse.payload).toMatchObject({
    response: {
      failure: { action: "screen", code: "protocol_incompatible" },
    },
  });
  first.client.close();

  const second = await handshake(paths.socket, { minimum: 4, current: 4 });
  const secondResponse = await requestScreen(second.client, second.revision!, 72);
  expect(secondResponse.correlation).toBe(72);
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);
  second.client.close();

  const authoritative = contenders.find((child) => child.exitCode === null)!;
  expect(await waitForExit(authoritative)).toBe(0);
  await Promise.all(contenders.map(waitForExit));
  expect(existsSync(paths.socket)).toBe(false);
  expect(existsSync(paths.identity)).toBe(false);
  expect(existsSync(paths.lock)).toBe(true);

  for (const child of contenders) {
    expect(await streamText(child.stdout)).toBe("");
    expect(await streamText(child.stderr)).toBe("");
  }
});

test("idle shutdown survives removal of the endpoint directory", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const child = startHost(home, undefined, 200);
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));

  rmSync(paths.dir, { recursive: true, force: true });

  const exitCode = await waitForExit(child);
  const stdout = await streamText(child.stdout);
  const stderr = await streamText(child.stderr);
  expect({ exitCode, stdout, stderr }).toEqual({
    exitCode: 0,
    stdout: "",
    stderr: "",
  });
});

test("client reconciles an idle-retiring host before admitting a request", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const trace = join(home, "idle-retirement.trace");
  const retiring = startHost(home, undefined, 50, {
    FX_TRACE_LOG: trace,
    FX_TRACE_SCOPES: "terminal_host",
    FX_TERMINAL_TEST_IDLE_EXIT_DELAY_MS: "3000",
  }, buildCurrentClientFixture());

  await waitFor(() =>
    existsSync(trace) &&
    readFileSync(trace, "utf8").includes("host retiring idle=true")
  );

  expect(await runClientFixture(home, 700)).toEqual({
    exitCode: 0,
    stdout: '{"kind":"response","correlation":1,"code":"authority_denied"}\n',
    stderr: "",
  });
  expect(await waitForExit(retiring)).toBe(0);
  await waitFor(() => !existsSync(paths.identity), 2_000);
}, 15_000);

test("native PTY starts in the requested cwd and reports exact command exit", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const fixtureShell = join(
    home,
    TERMINAL_FIXTURE_SHELL.endsWith("/zsh") ? "zsh" : "bash",
  );
  writeFileSync(
    fixtureShell,
    `#!/bin/sh\ntrap - TTIN TTOU\nkill -TTIN 0\nkill -TTOU 0\nexec ${TERMINAL_FIXTURE_SHELL} "$@"\n`,
    { mode: 0o700 },
  );
  const host = startHost(home, undefined, 5_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

  const started = await requestAction(
    connected.client,
    connected.revision!,
    101,
    "start",
    {
      cwd: home,
      command: "pwd; printf '\\npty-ready\\n'; exit 23",
      shell: { executable: { path: fixtureShell, clean_start: true } },
      backend: "native",
      return_when: { exit: {} },
      wait_ceiling_ms: 20_000,
      dimensions: { rows: 17, columns: 61 },
      initial_monitors: [],
    },
  );
  expect(started.payload).toMatchObject({
    response: {
      success: {
        start: {
          outcome: { exited: 23 },
          session: { lifecycle: "exited", backend: "native" },
        },
      },
    },
  });
  const sessionId = (
    started.payload as {
      response: { success: { start: { session: { session_id: string } } } };
    }
  ).response.success.start.session.session_id;
  const read = await requestAction(
    connected.client,
    connected.revision!,
    102,
    "read",
    { session_id: sessionId, cursor: { segment: 1, offset: 0 } },
  );
  expect(
    (read.payload as { response: { success: { read: { output: string } } } })
      .response.success.read.output,
  ).toContain(`${home}\r\n`);
  expect(
    (read.payload as { response: { success: { read: { output: string } } } })
      .response.success.read.output,
  ).toContain("pty-ready\r\n");

  const nested = join(home, "nested");
  mkdirSync(nested);
  const nestedStart = await startCommand(
    connected.client,
    connected.revision!,
    103,
    {
      cwd: nested,
      command: "pwd; exit 0",
      shell: { executable: { path: fixtureShell, clean_start: true } },
      returnWhen: { exit: {} },
    },
  );
  const nestedId = (nestedStart.session as { session_id: string }).session_id;
  expect(
    (
      await readSession(
        connected.client,
        connected.revision!,
        104,
        nestedId,
      )
    ).output,
  ).toContain(nested);

  const rawPrivate = await handshake(paths.socket, {
    minimum: 4,
    current: 5,
  });
  await expect(
    requestAction(
      rawPrivate.client,
      rawPrivate.revision!,
      105,
      "start",
      {
        cwd: "nested",
        shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
        backend: "native",
        return_when: { started: {} },
        wait_ceiling_ms: 1_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    ),
  ).rejects.toThrow("socket closed");

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 15_000);

test.skipIf(!tmuxAvailable())("explicit tmux backend is isolated and reports exact command exit", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  isolateZshStartupFixture(home);
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

  const tmuxResource = rememberPrivateTmuxServer(home);
  const started = await finishStartupObservation(
    connected.client,
    connected.revision!,
    111,
    success(
      await requestAction(connected.client, connected.revision!, 110, "start", {
        cwd: home,
        command: "pwd; printf '\\ntmux-ready\\n'; exit 23",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        backend: "tmux",
        return_when: { exit: {} },
        wait_ceiling_ms: TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS,
        dimensions: { rows: 17, columns: 61 },
        initial_monitors: [],
      }),
      "start",
    ),
    "tmux",
    { exit: {} },
    TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS,
  );
  rememberPrivateTmuxIdentities(tmuxResource);
  expect(started).toMatchObject({
    outcome: { exited: 23 },
    session: { lifecycle: "exited", backend: "tmux" },
  });
  const sessionId = (started.session as { session_id: string }).session_id;
  const read = await readSession(
    connected.client,
    connected.revision!,
    112,
    sessionId,
  );
  expect(read.output).toContain(`${home}\r\n`);
  expect(read.output).toContain("tmux-ready\r\n");
  await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

  writeFileSync(join(home, ".zshrc"), "");
  const normalProfile = await finishStartupObservation(
    connected.client,
    connected.revision!,
    114,
    await startCommand(connected.client, connected.revision!, 113, {
      cwd: home,
      command: "printf normal-profile-ready; exit 0",
      shell: { executable: { path: "/bin/zsh", clean_start: false } },
      backend: "tmux",
      returnWhen: { exit: {} },
      waitMs: TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS,
    }),
    "tmux",
    { exit: {} },
    TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS,
  );
  expect(normalProfile).toMatchObject({
    outcome: { exited: 0 },
    session: { lifecycle: "exited", backend: "tmux" },
  });
  await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

  const interactive = await finishStartupObservation(
    connected.client,
    connected.revision!,
    116,
    await startCommand(connected.client, connected.revision!, 115, {
      cwd: home,
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { started: {} },
      waitMs: TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS,
    }),
    "tmux",
    { started: {} },
    TMUX_COMMANDLESS_STARTUP_OBSERVATION_BUDGET_MS,
  );
  const interactiveId = (interactive.session as { session_id: string }).session_id;
  success(
    await requestAction(connected.client, connected.revision!, 117, "write", {
      session_id: interactiveId,
      payload: { text: "printf commandless-ready; exit 0\n" },
    }),
    "write",
  );
  const interactiveExit = success(
    await requestAction(connected.client, connected.revision!, 118, "wait", {
      session_id: interactiveId,
      return_when: { exit: {} },
      safety_ceiling_ms: 5_000,
    }),
    "wait",
  );
  expect(interactiveExit.outcome).toEqual({ exited: 0 });
  expect((await readSession(
    connected.client,
    connected.revision!,
    119,
    interactiveId,
  )).output).toContain("commandless-ready");
  await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, TMUX_EXPLICIT_BACKEND_TEST_TIMEOUT_MS);

test.skipIf(!tmuxAvailable())(
  "tmux first shell marker can arrive after the acknowledgment-duration boundary",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    isolateZshStartupFixture(home);
    const paths = hostPaths(home);
    writeFileSync(
      join(home, ".zprofile"),
      "sleep 14.25\nprintf 'first-marker-profile-ready\\n'\n",
    );
    const host = startHost(home, undefined, 10_000);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

    const startedAt = Date.now();
    const initial = await startCommand(
      connected.client,
      connected.revision!,
      117,
      {
        cwd: home,
        command: "exit 19",
        shell: { executable: { path: "/bin/zsh", clean_start: false } },
        backend: "tmux",
        returnWhen: { exit: {} },
        waitMs: TMUX_INITIAL_STARTUP_OBSERVATION_BUDGET_MS,
      },
    );
    expect(initial).toMatchObject({
      outcome: { safety_ceiling: {} },
      session: { lifecycle: "starting", backend: "tmux" },
    });
    const sessionId = (initial.session as { session_id: string }).session_id;
    const result = success(
      await requestAction(connected.client, connected.revision!, 118, "wait", {
        session_id: sessionId,
        return_when: { exit: {} },
        safety_ceiling_ms: TMUX_COMMAND_STARTUP_OBSERVATION_BUDGET_MS,
      }),
      "wait",
    );
    expect(result).toMatchObject({
      outcome: { exited: 19 },
      session: { lifecycle: "exited", backend: "tmux" },
    });
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(
      TMUX_MARKER_IO_DEADLINE_MS,
    );
    expect(
      (await readSession(
        connected.client,
        connected.revision!,
        119,
        sessionId,
      )).output,
    ).toContain("first-marker-profile-ready");
    await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  },
  TMUX_DELAYED_PROFILE_TEST_TIMEOUT_MS,
);

test.skipIf(!tmuxAvailable())(
  "tmux command release completes within the marker acknowledgment window",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 10_000, {
      FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS: "5000",
    });
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

    const startedAt = Date.now();
    const result = await startCommand(
      connected.client,
      connected.revision!,
      117,
      {
        cwd: home,
        command: "exit 19",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        backend: "tmux",
        returnWhen: { exit: {} },
        waitMs: 12_000,
      },
    );
    expect(result).toMatchObject({
      outcome: { exited: 19 },
      session: { lifecycle: "exited", backend: "tmux" },
    });
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(5_000);
    await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  },
  20_000,
);

const tmuxBoundedPeerFailures = [
  { owner: "marker", point: "no-peer" },
  { owner: "marker", point: "silent-peer" },
  { owner: "marker", point: "partial-marker" },
  { owner: "marker", point: "invalid-nonce" },
  { owner: "marker", point: "child-exit" },
  { owner: "capture", point: "no-peer" },
  { owner: "capture", point: "silent-peer" },
  { owner: "capture", point: "partial-identity" },
  { owner: "capture", point: "wrong-identity" },
  { owner: "capture", point: "child-exit" },
] as const;

test.skipIf(!tmuxAvailable())(
  "tmux marker and capture peers are deadline-bounded and clean every failed attempt twice",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    for (const fixture of tmuxBoundedPeerFailures) {
      for (let pass = 1; pass <= 2; pass++) {
        const home = makeHome();
        const paths = hostPaths(home);
        const transport = terminalTransportPaths(home);
        const trace = join(home, `${fixture.owner}-${fixture.point}-${pass}.log`);
        const host = startHost(home, undefined, 2_000, {
          FX_TRACE_LOG: trace,
          FX_TRACE_SCOPES: "terminal_host",
          FX_TERMINAL_TEST_TMUX_DEADLINE_MS: "150",
          ...(fixture.owner === "marker"
            ? { FX_TERMINAL_TEST_TMUX_MARKER_FAILURE: fixture.point }
            : { FX_TERMINAL_TEST_TMUX_CAPTURE_FAILURE: fixture.point }),
        });
        const stderr = streamText(host.stderr);
        await waitFor(() => existsSync(paths.socket));
        const connected = await handshake(paths.socket, {
          minimum: 4,
          current: 5,
        });
        const baselineFds = processFdCount(host.pid!);
        const baselinePeerArtifacts = tmuxPeerArtifacts();
        const baselineCaptureHelpers = tmuxCaptureHelperPids();
        const response = await requestAction(
          connected.client,
          connected.revision!,
          120,
          "start",
          {
            cwd: home,
            command: "sleep 30",
            shell: { executable: { path: "/bin/zsh", clean_start: true } },
            backend: "tmux",
            return_when: { started: {} },
            wait_ceiling_ms: 5_000,
            dimensions: { rows: 24, columns: 80 },
            initial_monitors: [],
          },
        );
        expect(failure(response), `${fixture.owner}:${fixture.point}:${pass}`)
          .toMatchObject({ action: "start", code: "startup_failed" });
        const state = join(
          home,
          ".fx",
          "sessions",
          TERMINAL_OWNER_SESSION,
          "terminal",
          "state",
        );
        const recordName = readdirSync(state).find((name) =>
          name.startsWith("record-") && name.endsWith(".json")
        );
        const identities = recordName
          ? [(JSON.parse(readFileSync(join(state, recordName), "utf8")) as {
            backend_identity: string;
          }).backend_identity]
          : [];
        await waitFor(() => !existsSync(transport.tmuxSocket), 5_000);
        await waitFor(() => directChildPids(host.pid!).length === 0, 5_000);
        await waitFor(
          () => JSON.stringify(tmuxCaptureHelperPids()) ===
            JSON.stringify(baselineCaptureHelpers),
          5_000,
        );
        expect(
          privateTmuxProcessPids(transport.tmuxSocket, identities),
          `${fixture.owner}:${fixture.point}:${pass}`,
        ).toEqual([]);
        expect(tmuxPeerArtifacts(), `${fixture.owner}:${fixture.point}:${pass}`)
          .toEqual(baselinePeerArtifacts);
        expect(
          readdirSync(paths.dir).filter((name) => name.startsWith("tmux-")),
          `${fixture.owner}:${fixture.point}:${pass}`,
        ).toEqual([]);
        expect(processFdCount(host.pid!)).toBeLessThanOrEqual(baselineFds + 2);
        connected.client.close();
        expect(await waitForExit(host)).toBe(0);
        expect(await stderr).toBe("");
      }
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "tmux foreground handoff failure reaps group and direct-fallback attempts twice",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    for (const fixture of [
      { name: "group", injectGroupKillFailure: false },
      { name: "direct-fallback", injectGroupKillFailure: true },
    ]) {
      for (let pass = 1; pass <= 2; pass++) {
        const home = makeHome();
        const paths = hostPaths(home);
        const transport = terminalTransportPaths(home);
        const trace = join(home, `foreground-${fixture.name}-${pass}.log`);
        const host = startHost(home, undefined, 2_000, {
          FX_TRACE_LOG: trace,
          FX_TRACE_SCOPES: "terminal_host",
          FX_TERMINAL_TEST_TMUX_TCSETPGRP_FAILURE: "1",
          ...(fixture.injectGroupKillFailure
            ? { FX_TERMINAL_TEST_TMUX_GROUP_KILL_FAILURE: "1" }
            : {}),
        });
        const stderr = streamText(host.stderr);
        await waitFor(() => existsSync(paths.socket));
        const connected = await handshake(paths.socket, {
          minimum: 4,
          current: 5,
        });
        const baselineFds = processFdCount(host.pid!);
        const baselinePeerArtifacts = tmuxPeerArtifacts();
        const baselineCaptureHelpers = tmuxCaptureHelperPids();
        for (let attempt = 0; attempt < 2; attempt++) {
          const startedAt = Date.now();
          const response = await requestAction(
            connected.client,
            connected.revision!,
            121 + attempt * 10_000,
            "start",
            {
              cwd: home,
              command: "sleep 30",
              shell: { executable: { path: "/bin/zsh", clean_start: true } },
              backend: "tmux",
              return_when: { started: {} },
              wait_ceiling_ms: 5_000,
              dimensions: { rows: 24, columns: 80 },
              initial_monitors: [],
            },
          );
          expect(Date.now() - startedAt, `${fixture.name}:${pass}`).toBeLessThan(
            5_000,
          );
          expect(failure(response), `${fixture.name}:${pass}`).toMatchObject({
            action: "start",
            code: "startup_failed",
          });
          try {
            await waitFor(
              () =>
                existsSync(trace) &&
                readFileSync(trace, "utf8").includes(
                  "tmux foreground handoff failed pid=",
                ),
              CLEANUP_FINALIZATION_BUDGET_MS * 2,
            );
            break;
          } catch (error) {
            if (attempt === 1) throw error;
            console.error(
              "Retrying tmux handoff failure fixture after unrelated startup failure",
            );
          }
        }
        const traceText = readFileSync(trace, "utf8");
        const childMatch = traceText.match(
          /tmux foreground handoff failed pid=(\d+)/,
        );
        expect(childMatch, `${fixture.name}:${pass}`).not.toBeNull();
        const childPid = Number(childMatch![1]);
        if (fixture.injectGroupKillFailure) {
          expect(traceText, `${fixture.name}:${pass}`).toContain(
            `tmux child group termination failed pid=${childPid} direct_kill_succeeded=true`,
          );
        } else {
          expect(traceText, `${fixture.name}:${pass}`).not.toContain(
            "tmux child group termination failed",
          );
        }
        const record = durableTerminalRecord(home).value as unknown as {
          backend_identity: string;
        };
        await waitFor(() => !existsSync(transport.tmuxSocket), 5_000);
        await waitFor(() => !processExists(childPid), 5_000);
        await waitFor(() => directChildPids(host.pid!).length === 0, 5_000);
        await waitFor(
          () => JSON.stringify(tmuxCaptureHelperPids()) ===
            JSON.stringify(baselineCaptureHelpers),
          5_000,
        );
        expect(processExists(childPid), `${fixture.name}:${pass}`).toBe(false);
        expect(privateTmuxProcessPids(
          transport.tmuxSocket,
          [record.backend_identity],
        )).toEqual([]);
        expect(tmuxPeerArtifacts(), `${fixture.name}:${pass}`).toEqual(
          baselinePeerArtifacts,
        );
        expect(
          readdirSync(paths.dir).filter((name) => name.startsWith("tmux-")),
          `${fixture.name}:${pass}`,
        ).toEqual([]);
        expect(existsSync(`/tmp/fx-tmux-capture-${record.backend_identity}.sock`))
          .toBe(false);
        expect(existsSync(`/tmp/fx-tmux-marker-${record.backend_identity}.sock`))
          .toBe(false);
        expect(processFdCount(host.pid!)).toBeLessThanOrEqual(baselineFds + 2);
        connected.client.close();
        expect(await waitForExit(host)).toBe(0);
        expect(await stderr).toBe("");
      }
    }
  },
  TERMINAL_OPERATION_OBSERVATION_BUDGET_MS * 4 +
    CLEANUP_FINALIZATION_BUDGET_MS * 4,
);

test.skipIf(!tmuxAvailable())(
  "tmux foreground race resumes the exact SIGTTIN group and reports command exit",
  async () => {
    const home = makeHome();
    const paths = hostPaths(home);
    const transport = terminalTransportPaths(home);
    const wrapper = join(
      home,
      TERMINAL_FIXTURE_SHELL.endsWith("/zsh") ? "zsh" : "bash",
    );
    const stoppedProof = join(home, "tmux-sigttin-stopped");
    const resumedProof = join(home, "tmux-sigttin-resumed");
    writeFileSync(
      wrapper,
      `#!/bin/sh\ntrap - TTIN\nprintf '%s %s\\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" > ${JSON.stringify(stoppedProof)}\nkill -TTIN 0\n: > ${JSON.stringify(resumedProof)}\nexec ${JSON.stringify(TERMINAL_FIXTURE_SHELL)} "$@"\n`,
      { mode: 0o700 },
    );

    const tmuxResource = rememberPrivateTmuxServer(home);
    const baselinePeerArtifacts = tmuxPeerArtifacts();
    const baselineCaptureHelpers = tmuxCaptureHelperPids();
    const trace = join(home, "tmux-sigttin-trace.log");
    const host = startHost(home, undefined, 250, {
      FX_TRACE_LOG: trace,
      FX_TRACE_SCOPES: "terminal_host",
      FX_TERMINAL_TEST_TMUX_DEADLINE_MS: "2000",
    });
    const stderr = streamText(host.stderr);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const hostFds = processFdCount(host.pid!);

    const startedAt = Date.now();
    const response = await requestAction(
      connected.client,
      connected.revision!,
      122,
      "start",
      {
        cwd: home,
        command: "printf 'tmux-handoff-ready\\n'; exit 23",
        shell: { executable: { path: wrapper, clean_start: true } },
        backend: "tmux",
        return_when: { exit: {} },
        wait_ceiling_ms: 5_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    );
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    const started = success(response, "start");
    expect(started).toMatchObject({
      outcome: { exited: 23 },
      session: { lifecycle: "exited", backend: "tmux" },
    });

    const [pidText, pgidText] = readFileSync(stoppedProof, "utf8")
      .trim()
      .split(/\s+/);
    const childPid = Number(pidText);
    const childPgid = Number(pgidText);
    expect(childPid).toBeGreaterThan(0);
    expect(childPid).toBe(childPgid);
    expect(existsSync(resumedProof)).toBe(true);
    await waitFor(() =>
      existsSync(trace) &&
      readFileSync(trace, "utf8").includes(
        `resumed terminal child after foreground race pid=${childPid}`,
      )
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    expect((await readSession(
      connected.client,
      connected.revision!,
      123,
      sessionId,
    )).output).toContain("tmux-handoff-ready");

    rememberPrivateTmuxIdentities(tmuxResource);
    const record = durableTerminalRecord(home).value as unknown as {
      backend_identity: string;
    };
    await waitFor(() => !existsSync(transport.tmuxSocket), 5_000);
    await waitFor(() => !processExists(childPid), 5_000);
    await waitFor(() => directChildPids(host.pid!).length === 0, 5_000);
    await waitFor(
      () => JSON.stringify(tmuxCaptureHelperPids()) ===
        JSON.stringify(baselineCaptureHelpers),
      5_000,
    );
    expect(privateTmuxProcessPids(
      transport.tmuxSocket,
      [record.backend_identity],
    )).toEqual([]);
    expect(tmuxPeerArtifacts()).toEqual(baselinePeerArtifacts);
    expect(
      readdirSync(paths.dir).filter((name) => name.startsWith("tmux-")),
    ).toEqual([]);
    expect(existsSync(`/tmp/fx-tmux-capture-${record.backend_identity}.sock`))
      .toBe(false);
    expect(existsSync(`/tmp/fx-tmux-marker-${record.backend_identity}.sock`))
      .toBe(false);
    expect(processFdCount(host.pid!)).toBeLessThanOrEqual(hostFds + 2);
    rmSync(stoppedProof, { force: true });
    rmSync(resumedProof, { force: true });
    rmSync(wrapper, { force: true });
    rmSync(trace, { force: true });
    expect(existsSync(stoppedProof)).toBe(false);
    expect(existsSync(resumedProof)).toBe(false);
    expect(existsSync(wrapper)).toBe(false);
    expect(existsSync(trace)).toBe(false);
    connected.client.close();
    expect(await waitForExit(host)).toBe(0);
    expect(await stderr).toBe("");
  },
  15_000,
);

test.skipIf(process.platform !== "linux" || !tmuxAvailable())(
  "tmux foreground handoff resumes a stopped same-group descendant",
  async () => {
    const home = makeHome();
    const paths = hostPaths(home);
    const transport = terminalTransportPaths(home);
    const wrapper = join(home, "bash");
    const interposerSource = join(home, "tcsetpgrp-gate.c");
    const interposer = join(home, "tcsetpgrp-gate.so");
    const descendantReady = join(home, "descendant-stopped");
    const handoffAssigned = join(home, "tcsetpgrp-assigned");
    const handoffRelease = join(home, "tcsetpgrp-release");
    const processProof = join(home, "process-proof");
    const resumedProof = join(home, "descendant-resumed");
    const laterStoppedPidProof = join(home, "later-stopped-pid");
    const laterResumedProof = join(home, "later-stop-resumed");

    writeFileSync(
      interposerSource,
      `#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int launcher_process(void) {
  char bytes[512];
  int fd = open("/proc/self/cmdline", O_RDONLY);
  if (fd < 0) return 0;
  ssize_t count = read(fd, bytes, sizeof(bytes));
  close(fd);
  const char needle[] = "--fx-internal-terminal-tmux-launcher";
  if (count < (ssize_t)(sizeof(needle) - 1)) return 0;
  for (ssize_t i = 0; i <= count - (ssize_t)(sizeof(needle) - 1); i++) {
    if (memcmp(bytes + i, needle, sizeof(needle) - 1) == 0) return 1;
  }
  return 0;
}

static void touch_path(const char *path) {
  if (path == NULL) return;
  int fd = open(path, O_CREAT | O_WRONLY, 0600);
  if (fd >= 0) close(fd);
}

int tcsetpgrp(int fd, pid_t pgrp) {
  static int (*real_tcsetpgrp)(int, pid_t);
  if (real_tcsetpgrp == NULL) {
    *(void **)(&real_tcsetpgrp) = dlsym(RTLD_NEXT, "tcsetpgrp");
  }
  if (!launcher_process()) return real_tcsetpgrp(fd, pgrp);
  const char *ready = getenv("FX_E2E_TMUX_DESCENDANT_READY");
  for (int i = 0; ready != NULL && access(ready, F_OK) != 0 && i < 1000; i++) {
    usleep(5000);
  }
  int result = real_tcsetpgrp(fd, pgrp);
  touch_path(getenv("FX_E2E_TMUX_HANDOFF_ASSIGNED"));
  const char *release = getenv("FX_E2E_TMUX_HANDOFF_RELEASE");
  for (int i = 0; release != NULL && access(release, F_OK) != 0 && i < 1000; i++) {
    usleep(5000);
  }
  return result;
}
`,
    );
    execFileSync(
      "cc",
      [
        "-shared",
        "-fPIC",
        interposerSource,
        "-ldl",
        "-o",
        interposer,
      ],
      { stdio: "pipe", timeout: 10_000 },
    );
    writeFileSync(
      wrapper,
      `#!/bin/bash
set +m
(
  trap - TTIN
  printf '%s %s\n' "$BASHPID" "$(ps -o pgid= -p "$BASHPID" | tr -d ' ')" > ${JSON.stringify(processProof)}
  kill -TTIN "$BASHPID"
  : > ${JSON.stringify(resumedProof)}
) &
descendant=$!
while :; do
  state=$(ps -o stat= -p "$descendant" | tr -d ' ')
  case "$state" in
    T*) printf '%s %s\n' "$BASHPID" "$descendant" > ${JSON.stringify(descendantReady)}; break ;;
  esac
  sleep 0.005
done
wait "$descendant"
exec /bin/bash "$@"
`,
      { mode: 0o700 },
    );

    const tmuxResource = rememberPrivateTmuxServer(home);
    const baselinePeerArtifacts = tmuxPeerArtifacts();
    const baselineCaptureHelpers = tmuxCaptureHelperPids();
    const host = startHost(home, undefined, 250, {
      LD_PRELOAD: interposer,
      FX_E2E_TMUX_DESCENDANT_READY: descendantReady,
      FX_E2E_TMUX_HANDOFF_ASSIGNED: handoffAssigned,
      FX_E2E_TMUX_HANDOFF_RELEASE: handoffRelease,
      FX_TERMINAL_TEST_TMUX_DEADLINE_MS: "2000",
    });
    const stderr = streamText(host.stderr);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const hostFds = processFdCount(host.pid!);

    const startedAt = Date.now();
    const responsePromise = requestAction(
      connected.client,
      connected.revision!,
      124,
      "start",
      {
        cwd: home,
        command: "printf 'tmux-descendant-ready\\n'; exit 29",
        shell: { executable: { path: wrapper, clean_start: true } },
        backend: "tmux",
        return_when: { exit: {} },
        wait_ceiling_ms: 5_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    );
    await waitFor(
      () => existsSync(descendantReady) &&
        existsSync(handoffAssigned),
      5_000,
    );

    const [descendantPidText, processPgidText] = readFileSync(
      processProof,
      "utf8",
    ).trim().split(/\s+/);
    const [directPidText, observedDescendantText] = readFileSync(
      descendantReady,
      "utf8",
    ).trim().split(/\s+/);
    const descendantPid = Number(descendantPidText);
    const directPid = Number(directPidText);
    const processPgid = Number(processPgidText);
    expect(descendantPid).toBe(Number(observedDescendantText));
    expect(directPid).toBe(processPgid);

    const processLines = execFileSync(
      "ps",
      [
        "-eo",
        "pid=,ppid=,pgid=,sid=,tpgid=,stat=,wchan:32=,args=",
      ],
      { encoding: "utf8", stdio: "pipe" },
    ).split("\n");
    const processRow = (pid: number) => processLines
      .find((line) => Number(line.trim().split(/\s+/)[0]) === pid)!
      .trim()
      .split(/\s+/);
    const directRow = processRow(directPid);
    const descendantRow = processRow(descendantPid);
    const launcherPidText = directRow[1]!;
    expect(directRow.slice(0, 7)).toEqual([
      directPidText,
      launcherPidText,
      directPidText,
      launcherPidText,
      directPidText,
      expect.stringMatching(/^S/),
      "do_wait",
    ]);
    expect(descendantRow.slice(0, 7)).toEqual([
      descendantPidText,
      directPidText,
      directPidText,
      launcherPidText,
      directPidText,
      expect.stringMatching(/^T/),
      "do_signal_stop",
    ]);
    expect(processLines.some((line) =>
      line.includes("--fx-internal-terminal-control")
    )).toBe(false);
    expect(existsSync(resumedProof)).toBe(false);
    const record = durableTerminalRecord(home).value as unknown as {
      backend_identity: string;
    };
    writeFileSync(handoffRelease, "", { mode: 0o600 });

    const response = await responsePromise;
    expect(Date.now() - startedAt).toBeLessThan(6_000);
    const started = success(response, "start");
    expect(started).toMatchObject({
      outcome: { exited: 29 },
      session: { lifecycle: "exited", backend: "tmux" },
    });
    expect(existsSync(resumedProof)).toBe(true);
    const firstSessionId = (started.session as { session_id: string }).session_id;
    expect((await readSession(
      connected.client,
      connected.revision!,
      125,
      firstSessionId,
    )).output).toContain("tmux-descendant-ready");
    await waitFor(() => !existsSync(transport.tmuxSocket), 5_000);

    const later = await startCommand(
      connected.client,
      connected.revision!,
      126,
      {
        cwd: home,
        command:
          `set +m; /bin/bash -c 'trap - TSTP; printf "%s\\n" "$$" > ${JSON.stringify(laterStoppedPidProof)}; kill -TSTP "$$"; : > ${JSON.stringify(laterResumedProof)}' & wait`,
        shell: { executable: { path: "/bin/bash", clean_start: true } },
        backend: "tmux",
        returnWhen: { exit: {} },
        waitMs: 1_000,
      },
    );
    expect(later).toMatchObject({
      outcome: { safety_ceiling: {} },
      session: { lifecycle: "running", backend: "tmux" },
    });
    const laterSessionId = (later.session as { session_id: string }).session_id;
    const laterRecord = durableTerminalRecordFor(
      home,
      laterSessionId,
    ) as { backend_identity: string };
    const laterStoppedPid = Number(
      readFileSync(laterStoppedPidProof, "utf8").trim(),
    );
    expect(execFileSync(
      "ps",
      ["-o", "stat=", "-p", String(laterStoppedPid)],
      { encoding: "utf8", stdio: "pipe" },
    ).trim()).toStartWith("T");
    expect(existsSync(laterResumedProof)).toBe(false);
    rememberPrivateTmuxIdentities(tmuxResource);
    success(
      await requestAction(connected.client, connected.revision!, 127, "close", {
        session_id: laterSessionId,
        policy: "force",
      }),
      "close",
    );

    await waitFor(() => !existsSync(transport.tmuxSocket), 5_000);
    await waitFor(() => !processExists(directPid), 5_000);
    await waitFor(() => !processExists(descendantPid), 5_000);
    await waitFor(() => !processExists(laterStoppedPid), 5_000);
    await waitFor(() => directChildPids(host.pid!).length === 0, 5_000);
    await waitFor(
      () => JSON.stringify(tmuxCaptureHelperPids()) ===
        JSON.stringify(baselineCaptureHelpers),
      5_000,
    );
    expect(privateTmuxProcessPids(
      transport.tmuxSocket,
      [record.backend_identity, laterRecord.backend_identity],
    )).toEqual([]);
    expect(tmuxPeerArtifacts()).toEqual(baselinePeerArtifacts);
    expect(
      readdirSync(paths.dir).filter((name) => name.startsWith("tmux-")),
    ).toEqual([]);
    for (const identity of [record.backend_identity, laterRecord.backend_identity]) {
      expect(existsSync(`/tmp/fx-tmux-capture-${identity}.sock`)).toBe(false);
      expect(existsSync(`/tmp/fx-tmux-marker-${identity}.sock`)).toBe(false);
    }
    expect(processFdCount(host.pid!)).toBeLessThanOrEqual(hostFds + 2);
    for (const path of [
      wrapper,
      interposerSource,
      interposer,
      descendantReady,
      handoffAssigned,
      handoffRelease,
      processProof,
      resumedProof,
      laterStoppedPidProof,
      laterResumedProof,
    ]) {
      rmSync(path, { force: true });
      expect(existsSync(path)).toBe(false);
    }

    connected.client.close();
    expect(await waitForExit(host)).toBe(0);
    expect(await stderr).toBe("");
  },
  20_000,
);

test("missing tmux fails explicitly without changing native selection", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const emptyPath = join(home, "empty-path");
  mkdirSync(emptyPath);
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000, { PATH: emptyPath });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const unavailable = await requestAction(
    connected.client,
    connected.revision!,
    130,
    "start",
    {
      cwd: home,
      command: "exit 0",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      return_when: { exit: {} },
      wait_ceiling_ms: 2_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  );
  expect(failure(unavailable)).toMatchObject({ action: "start", code: "pty_unavailable" });

  const native = await startNativeCommandFixture(connected.client, connected.revision!, 131_000, {
    cwd: home,
    command: "printf native-still-works; exit 0",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    returnWhen: { exit: {} },
    waitMs: 5_000,
  });
  expect(native).toMatchObject({
    outcome: { exited: 0 },
    session: { backend: "native", lifecycle: "exited" },
  });

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("incompatible tmux fails explicitly without native fallback", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const fakePath = join(home, "fake-path");
  mkdirSync(fakePath);
  const fakeTmux = join(fakePath, "tmux");
  writeFileSync(fakeTmux, "#!/bin/sh\nprintf 'tmux 3.1\\n'\n");
  chmodSync(fakeTmux, 0o700);
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000, { PATH: fakePath });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const incompatible = await requestAction(
    connected.client,
    connected.revision!,
    132,
    "start",
    {
      cwd: home,
      command: "exit 0",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      return_when: { exit: {} },
      wait_ceiling_ms: 2_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  );
  expect(failure(incompatible)).toMatchObject({
    action: "start",
    code: "protocol_incompatible",
  });
  expect(existsSync(join(paths.dir, "tmux.sock"))).toBe(false);

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 15_000);

test.skipIf(!tmuxAvailable())("tmux resize checkpoint failures roll back without losing control", async () => {
  if (!existsSync("/bin/zsh")) return;
  for (const failurePoint of ["allocation", "storage", "checkpoint"]) {
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 30_000, {
      FX_TERMINAL_TEST_TMUX_RESIZE_CHECKPOINT_FAILURE: failurePoint,
    });
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const started = await startCommand(connected.client, connected.revision!, 135, {
      cwd: home,
      command: "printf 'resize-ready\\n'; IFS= read -r input; printf 'resize-after:%s\\n' \"$input\"; sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "resize-ready" },
      waitMs: 8_000,
      dimensions: { rows: 24, columns: 80 },
      startupAttempts: 2,
    });
    const sessionId = (started.session as { session_id: string }).session_id;
    const before = success(
      await requestAction(connected.client, connected.revision!, 136, "screen", {
        session_id: sessionId,
      }),
      "screen",
    ) as { snapshot: unknown };
    const recordBefore = durableTerminalRecord(home).value as unknown as {
      dimensions: { rows: number; columns: number };
    };

    const failed = await requestAction(
      connected.client,
      connected.revision!,
      137,
      "resize",
      { session_id: sessionId, dimensions: { rows: 30, columns: 90 } },
    );
    expect(failure(failed), failurePoint).toMatchObject({
      action: "resize",
      code: "invalid_request",
    });
    const after = success(
      await requestAction(connected.client, connected.revision!, 138, "screen", {
        session_id: sessionId,
      }),
      "screen",
    ) as { snapshot: unknown };
    expect(after.snapshot, failurePoint).toEqual(before.snapshot);
    const recordAfter = durableTerminalRecord(home).value as unknown as {
      dimensions: { rows: number; columns: number };
    };
    expect(recordAfter.dimensions, failurePoint).toEqual(recordBefore.dimensions);

    success(
      await requestAction(connected.client, connected.revision!, 139, "write", {
        session_id: sessionId,
        payload: { text: `${failurePoint}\n` },
      }),
      "write",
    );
    const continued = success(
      await requestAction(connected.client, connected.revision!, 140, "wait", {
        session_id: sessionId,
        return_when: { match: `resize-after:${failurePoint}` },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    expect(continued.outcome, failurePoint).toEqual({ condition_met: {} });
    success(
      await requestAction(connected.client, connected.revision!, 141, "close", {
        session_id: sessionId,
        policy: "force",
      }),
      "close",
    );
    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  }
}, 45_000);

test.skipIf(!tmuxAvailable())("revision four client cannot opt into Part 8 tmux recovery", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(
    paths.socket,
    { minimum: 4, current: 4 },
    3,
  );
  const response = await requestAction(
    connected.client,
    connected.revision!,
    133,
    "start",
    {
      cwd: home,
      command: "exit 0",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      return_when: { exit: {} },
      wait_ceiling_ms: 2_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  );
  expect(failure(response).code).toBe("protocol_incompatible");
  expect(existsSync(join(paths.dir, "tmux.sock"))).toBe(false);

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 15_000);

test.skipIf(!tmuxAvailable())("tmux recovers every durable starting boundary", async () => {
  if (!existsSync("/bin/zsh")) return;
  const cases = [
    {
      name: "prepared",
      lifecycleKind: 1,
      commandless: false,
      env: { FX_TERMINAL_TEST_TMUX_PREPARED_RELEASE_DELAY_MS: "5000" },
    },
    {
      name: "shell-ready",
      lifecycleKind: 2,
      commandless: true,
      env: { FX_TERMINAL_TEST_TMUX_SHELL_READY_HOST_DELAY_MS: "5000" },
    },
    {
      name: "command-started",
      lifecycleKind: 3,
      commandless: false,
      env: { FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS: "5000" },
    },
  ];

  for (const fixture of cases) {
    const home = makeHome();
    const paths = hostPaths(home);
    const finish = join(home, `finish-${fixture.name}`);
    const firstHost = startHost(home, undefined, 30_000, fixture.env);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const pending = startCommand(first.client, first.revision!, 140, {
      cwd: home,
      command: fixture.commandless
        ? undefined
        : `printf 'recovered-${fixture.name}\\n'; while [[ ! -f ${JSON.stringify(finish)} ]]; do sleep 0.02; done; exit 0`,
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: fixture.commandless ? { started: {} } : { exit: {} },
      waitMs: 15_000,
    }).catch(() => null);
    await waitFor(() => {
      const lifecycleName = readdirSync(paths.dir).find((name) =>
        name.endsWith("-lifecycle.bin")
      );
      if (!lifecycleName) return false;
      const lifecycle = readFileSync(join(paths.dir, lifecycleName));
      return lifecycle.length >= fixture.lifecycleKind * 5 &&
        lifecycle[lifecycle.length - 5] === fixture.lifecycleKind;
    }, 8_000);
    const record = durableTerminalRecord(home);
    expect(record.value.lifecycle, fixture.name).toBe("starting");
    const hostArtifacts = readdirSync(paths.dir);
    if (!hostArtifacts.some((name) => name.endsWith("-manifest.json"))) {
      throw new Error(`${fixture.name}: ${JSON.stringify(hostArtifacts)}`);
    }
    const oldIdentity = readFileSync(paths.identity, "utf8");
    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);
    await pending;

    const recoveryTrace = join(home, `starting-${fixture.name}.log`);
    const replacement = startHost(home, undefined, 30_000, {
      FX_TRACE_LOG: recoveryTrace,
      FX_TRACE_SCOPES: "terminal_host",
    });
    await waitFor(
      () => existsSync(paths.socket) && existsSync(paths.identity) &&
        readFileSync(paths.identity, "utf8") !== oldIdentity,
      8_000,
    );
    rememberRecoveredAuthority(record.value.session_id, home, "tmux");
    const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
    if (fixture.commandless) {
      success(
        await requestAction(recovered.client, recovered.revision!, 144, "write", {
          session_id: record.value.session_id,
          payload: { text: `printf 'recovered-${fixture.name}\\n'; exit 0\n` },
        }),
        "write",
      );
    }
    const waitFrame = await requestAction(
      recovered.client,
      recovered.revision!,
      141,
      "wait",
      {
        session_id: record.value.session_id,
        return_when: { match: `recovered-${fixture.name}` },
        safety_ceiling_ms: 12_000,
      },
    );
    if (failureCode(waitFrame)) {
      throw new Error(
        `${fixture.name}: ${failureCode(waitFrame)}: ${readFileSync(recoveryTrace, "utf8")}`,
      );
    }
    const waited = success(waitFrame, "wait");
    if (fixture.commandless) {
      const outcome = waited.outcome as {
        condition_met?: Record<string, never>;
        exited?: number;
      };
      expect(outcome.condition_met !== undefined || outcome.exited === 0, fixture.name)
        .toBe(true);
    } else {
      expect(waited.outcome, fixture.name).toEqual({ condition_met: {} });
    }
    const inspected = success(
      await requestAction(recovered.client, recovered.revision!, 142, "inspect", {
        session_id: record.value.session_id,
      }),
      "inspect",
    ) as {
      session: { raw_gap?: { available_from: { segment: number; offset: number } } };
    };
    const outputFrame = await requestAction(
      recovered.client,
      recovered.revision!,
      145,
      "read",
      {
        session_id: record.value.session_id,
        cursor: inspected.session.raw_gap?.available_from ?? { segment: 1, offset: 0 },
      },
    );
    const output = success(outputFrame, "read") as { output: string };
    expect(output.output, fixture.name).toContain(`recovered-${fixture.name}`);
    if (!fixture.commandless) writeFileSync(finish, "go");
    const exited = success(
      await requestAction(recovered.client, recovered.revision!, 143, "wait", {
        session_id: record.value.session_id,
        return_when: { exit: {} },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    expect(exited.outcome, fixture.name).toEqual({ exited: 0 });

    recovered.client.close();
    replacement.kill("SIGKILL");
    await waitForExit(replacement);
  }
}, 60_000);

test.skipIf(!tmuxAvailable())(
  "tmux recovery retains a prepared session when failure follows release",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const preparedReleaseDelayMs = 5_000;
    for (let pass = 1; pass <= 2; pass++) {
      const home = makeHome();
      const paths = hostPaths(home);
      const firstHost = startHost(home, undefined, 30_000, {
        FX_TERMINAL_TEST_TMUX_PREPARED_RELEASE_DELAY_MS:
          String(preparedReleaseDelayMs),
      });
      await waitFor(() => existsSync(paths.socket));
      const first = await handshake(paths.socket, { minimum: 4, current: 5 });
      const pending = startCommand(first.client, first.revision!, 144, {
        cwd: home,
        command: `printf 'release-recovered-${pass}\n'; sleep 30`,
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        backend: "tmux",
        returnWhen: { match: `release-recovered-${pass}` },
        waitMs: 15_000,
      }).catch(() => null);
      await waitFor(() => {
        const lifecycle = readdirSync(paths.dir).find((name) =>
          name.endsWith("-lifecycle.bin")
        );
        return lifecycle !== undefined &&
          readFileSync(join(paths.dir, lifecycle)).at(-5) === 1;
      }, preparedReleaseDelayMs + CLEANUP_FINALIZATION_BUDGET_MS);
      const record = durableTerminalRecord(home).value as unknown as {
        session_id: string;
        backend_identity: string;
      };
      const tmuxSocket = terminalTransportPaths(home).tmuxSocket;
      const sessionName = `fx-${record.backend_identity}`;
      const panePid = Number(execFileSync(
        "tmux",
        ["-S", tmuxSocket, "display-message", "-p", "-t", sessionName, "#{pane_pid}"],
        { encoding: "utf8" },
      ).trim());
      first.client.close();
      firstHost.kill("SIGKILL");
      await waitForExit(firstHost);
      await pending;

      const failed = startHost(home, undefined, 30_000, {
        FX_TERMINAL_TEST_TMUX_RECOVERY_FAILURE: "release",
      });
      expect(await waitForExit(failed), `release:${pass}`).not.toBe(0);
      expect(processExists(panePid), `release:${pass}`).toBe(true);
      execFileSync("tmux", ["-S", tmuxSocket, "has-session", "-t", sessionName]);
      expect(existsSync(`/tmp/fx-tmux-capture-${record.backend_identity}.sock`))
        .toBe(false);

      const replacement = startHost(home, undefined, 500);
      await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity), 8_000);
      rememberRecoveredAuthority(record.session_id, home, "tmux");
      const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
      const waited = success(await requestAction(
        recovered.client,
        recovered.revision!,
        145,
        "wait",
        {
          session_id: record.session_id,
          return_when: { match: `release-recovered-${pass}` },
          safety_ceiling_ms: 8_000,
        },
      ), "wait");
      expect(waited.outcome, `release:${pass}`).toEqual({ condition_met: {} });
      success(await requestAction(
        recovered.client,
        recovered.revision!,
        146,
        "close",
        { session_id: record.session_id, policy: "force" },
      ), "close");
      await waitFor(() => !existsSync(tmuxSocket), 5_000);
      recovered.client.close();
      expect(await waitForExit(replacement)).toBe(0);
      expect(processExists(panePid), `release:${pass}`).toBe(false);
    }
  },
  45_000,
);

test.skipIf(!tmuxAvailable())("transient tmux recovery failures preserve the pane and retry state", async () => {
  if (!existsSync("/bin/zsh")) return;
  for (const failurePoint of [
    "after-backend",
    "lifecycle",
    "allocation",
    "storage",
    "identity",
    "capture",
    "screen-capture",
    "after-gap",
    "screen-reanchor",
    "monitor-arm",
    "begin-capture",
    "accept-capture",
    "output-thread",
    "control-thread",
  ]) {
    const home = makeHome();
    const paths = hostPaths(home);
    const firstHost = startHost(home, undefined, 30_000);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const started = await startCommand(first.client, first.revision!, 145, {
      cwd: home,
      command:
        "printf 'transient-ready\\n'; while ! IFS= read -r input; do :; done; " +
        "printf 'transient-after:%s\\n' \"$input\"; while ! IFS= read -r _; do :; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "transient-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const sessionId = (started.session as { session_id: string }).session_id;
    const sibling = await startCommand(first.client, first.revision!, 152, {
      cwd: home,
      command:
        "printf 'transient-sibling-ready\n'; while IFS= read -r input; do printf 'transient-sibling:%s\n' \"$input\"; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "transient-sibling-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const siblingId = (sibling.session as { session_id: string }).session_id;
    const tmuxSocket = join(paths.dir, "tmux.sock");
    const backendIdentity = (durableTerminalRecordFor(home, sessionId) as {
      backend_identity: string;
    }).backend_identity;
    const siblingIdentity = (durableTerminalRecordFor(home, siblingId) as {
      backend_identity: string;
    }).backend_identity;
    const sessionName = `fx-${backendIdentity}`;
    const siblingName = `fx-${siblingIdentity}`;
    const panePid = Number(execFileSync(
      "tmux",
      ["-S", tmuxSocket, "display-message", "-p", "-t", sessionName, "#{pane_pid}"],
      { encoding: "utf8" },
    ).trim());
    const siblingPanePid = Number(execFileSync(
      "tmux",
      ["-S", tmuxSocket, "display-message", "-p", "-t", siblingName, "#{pane_pid}"],
      { encoding: "utf8" },
    ).trim());
    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);

    const failedRecovery = startHost(home, undefined, 30_000, {
      FX_TERMINAL_TEST_TMUX_RECOVERY_FAILURE: failurePoint,
      FX_TERMINAL_TEST_TMUX_RECOVERY_SESSION_ID: sessionId,
    });
    expect(await waitForExit(failedRecovery), failurePoint).not.toBe(0);
    expect(() => process.kill(panePid, 0), failurePoint).not.toThrow();
    expect(() => process.kill(siblingPanePid, 0), failurePoint).not.toThrow();
    execFileSync("tmux", ["-S", tmuxSocket, "has-session", "-t", sessionName]);
    execFileSync("tmux", ["-S", tmuxSocket, "has-session", "-t", siblingName]);
    await waitFor(
      () => !existsSync(`/tmp/fx-tmux-capture-${backendIdentity}.sock`),
      5_000,
    ).catch(() => {
      throw new Error(`${failurePoint}: target capture socket retained`);
    });
    expect(existsSync(`/tmp/fx-tmux-capture-${backendIdentity}.sock`), failurePoint)
      .toBe(false);

    const failedIdentity = existsSync(paths.identity)
      ? readFileSync(paths.identity, "utf8")
      : null;
    const replacement = startHost(home, undefined, 500);
    await waitFor(
      () => (existsSync(paths.socket) && existsSync(paths.identity) &&
        (failedIdentity === null ||
          readFileSync(paths.identity, "utf8") !== failedIdentity)) ||
        replacement.exitCode !== null,
      8_000,
    );
    if (replacement.exitCode !== null) {
      throw new Error(
        `retry host exited at ${failurePoint}: ${await streamText(replacement.stderr)}`,
      );
    }
    const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
    const siblingInspect = success(
      await requestAction(recovered.client, recovered.revision!, 153, "inspect", {
        session_id: siblingId,
      }),
      "inspect",
    );
    expect(siblingInspect.session, failurePoint).toMatchObject({
      lifecycle: "running",
      backend: "tmux",
    });
    const inspect = success(
      await requestAction(recovered.client, recovered.revision!, 146, "inspect", {
        session_id: sessionId,
      }),
      "inspect",
    ) as {
      session: {
        lifecycle: string;
        raw_gap: { available_from: { segment: number; offset: number } };
      };
    };
    expect(inspect.session.lifecycle, failurePoint).toBe("running");
    expect(inspect.session.raw_gap.available_from.segment, failurePoint).toBe(2);
    success(
      await requestAction(recovered.client, recovered.revision!, 147, "write", {
        session_id: sessionId,
        payload: { text: `${failurePoint}\n` },
      }),
      "write",
    );
    const resumed = success(
      await requestAction(recovered.client, recovered.revision!, 148, "wait", {
        session_id: sessionId,
        return_when: { match: `transient-after:${failurePoint}` },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    expect(resumed.outcome, failurePoint).toEqual({ condition_met: {} });
    const continued = success(
      await requestAction(recovered.client, recovered.revision!, 149, "inspect", {
        session_id: sessionId,
      }),
      "inspect",
    );
    expect(continued.session, failurePoint).toMatchObject({ lifecycle: "running" });
    const output = success(
      await requestAction(recovered.client, recovered.revision!, 150, "read", {
        session_id: sessionId,
        cursor: inspect.session.raw_gap.available_from,
      }),
      "read",
    ) as { output: string };
    expect(output.output, failurePoint).toContain(
      `transient-after:${failurePoint}`,
    );
    success(
      await requestAction(recovered.client, recovered.revision!, 154, "write", {
        session_id: siblingId,
        payload: { text: `${failurePoint}\n` },
      }),
      "write",
    );
    const siblingWait = success(
      await requestAction(recovered.client, recovered.revision!, 155, "wait", {
        session_id: siblingId,
        return_when: { match: `transient-sibling:${failurePoint}` },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    expect(siblingWait.outcome, failurePoint).toEqual({ condition_met: {} });
    await forceCloseTerminalFixture(
      recovered.client,
      recovered.revision!,
      151,
      sessionId,
    );
    expect(existsSync(tmuxSocket), failurePoint).toBe(true);
    success(
      await requestAction(recovered.client, recovered.revision!, 156, "close", {
        session_id: siblingId,
        policy: "force",
      }),
      "close",
    );
    await waitFor(() => !existsSync(tmuxSocket), 5_000);
    recovered.client.close();
    expect(await waitForExit(replacement)).toBe(0);
    expect(processExists(panePid), failurePoint).toBe(false);
    expect(processExists(siblingPanePid), failurePoint).toBe(false);
    expect(existsSync(`/tmp/fx-tmux-capture-${backendIdentity}.sock`), failurePoint)
      .toBe(false);
    expect(existsSync(`/tmp/fx-tmux-capture-${siblingIdentity}.sock`), failurePoint)
      .toBe(false);
    expect(existsSync(`/tmp/fx-tmux-marker-${backendIdentity}.sock`), failurePoint)
      .toBe(false);
    expect(existsSync(`/tmp/fx-tmux-marker-${siblingIdentity}.sock`), failurePoint)
      .toBe(false);
  }
}, 180_000);

test.skipIf(!tmuxAvailable())("tmux recovery restores the saved workspace scope", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const workspace = join(home, "workspace");
  const cwd = join(workspace, "cwd");
  const scopeMarker = join(workspace, "scope-ready");
  const outsideWrite = join(home, "outside-workspace");
  mkdirSync(cwd, { recursive: true });
  const paths = hostPaths(home);
  const tmuxResource = rememberPrivateTmuxServer(home);
  const scopeProbe = `test -f ${JSON.stringify(scopeMarker)}`;
  const initialMonitors: Array<Record<string, unknown>> = [{
    condition: { custom_probe: { command: scopeProbe, cwd: workspace } },
    check_schedule: { interval_ms: 25 },
    notify_schedule: { on_state_change: {} },
    lifetime: { until_session_end: {} },
  }];
  if (process.platform === "darwin") {
    initialMonitors.push({
      condition: {
        custom_probe: {
          command: `printf escaped > ${JSON.stringify(outsideWrite)}`,
          cwd: workspace,
        },
      },
      check_schedule: { interval_ms: 25 },
      notify_schedule: { on_state_change: {} },
      lifetime: { until_session_end: {} },
    });
  }
  const startRequest = withPersistence({
    cwd,
    command:
      "printf 'scope-recovery-ready\\n'; while IFS= read -r line; do printf 'scope-recovery:%s\\n' \"$line\"; done",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "tmux",
    return_when: { match: "scope-recovery-ready" },
    wait_ceiling_ms: 8_000,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: initialMonitors,
  });
  const persistence = startRequest.persistence as {
    grant: { principal: Record<string, unknown> };
  };
  persistence.grant.principal.workspace_root = workspace;

  const firstHost = startHost(home, undefined, 30_000);
  const firstStdout = streamText(firstHost.stdout);
  const firstStderr = streamText(firstHost.stderr);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = success(
    await requestAction(
      first.client,
      first.revision!,
      151,
      "start",
      startRequest,
    ),
    "start",
  );
  const invalidStarted = success(
    await requestAction(
      first.client,
      first.revision!,
      156,
      "start",
      withPersistence({
        cwd,
        command:
          "printf 'invalid-sibling-ready\\n'; while IFS= read -r line; do printf 'invalid-sibling:%s\\n' \"$line\"; done",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        backend: "tmux",
        return_when: { match: "invalid-sibling-ready" },
        wait_ceiling_ms: 8_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      }),
    ),
    "start",
  );
  rememberPrivateTmuxIdentities(tmuxResource);
  const sessionId = (started.session as { session_id: string }).session_id;
  const invalidSessionId = (invalidStarted.session as { session_id: string })
    .session_id;
  const stateDir = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
  );
  const monitorFile = join(
    stateDir,
    `monitors-${sessionId}.json`,
  );
  const monitorRuntimes = (): Array<{
    check_count: number;
    condition_matched: boolean;
  }> => {
    const persisted = JSON.parse(readFileSync(monitorFile, "utf8")) as {
      monitors: Array<{
        runtime: { check_count: number; condition_matched: boolean };
      }>;
    };
    return persisted.monitors.map(({ runtime }) => runtime);
  };
  const tmuxSocket = terminalTransportPaths(home).tmuxSocket;
  const durableIdentity = (id: string): string => {
    const record = JSON.parse(
      readFileSync(join(stateDir, `record-${id}.json`), "utf8"),
    ) as { backend_identity: string };
    return record.backend_identity;
  };
  const backendIdentity = durableIdentity(sessionId);
  const invalidBackendIdentity = durableIdentity(invalidSessionId);
  const sessionName = `fx-${backendIdentity}`;
  const invalidSessionName = `fx-${invalidBackendIdentity}`;
  const panePid = Number(execFileSync(
    "tmux",
    ["-S", tmuxSocket, "display-message", "-p", "-t", sessionName, "#{pane_pid}"],
    { encoding: "utf8" },
  ).trim());
  const invalidPanePid = Number(execFileSync(
    "tmux",
    [
      "-S",
      tmuxSocket,
      "display-message",
      "-p",
      "-t",
      invalidSessionName,
      "#{pane_pid}",
    ],
    { encoding: "utf8" },
  ).trim());
  const invalidAuthorityPath = join(
    stateDir,
    `authority-${invalidSessionId}.json`,
  );
  const invalidAuthority = JSON.parse(
    readFileSync(invalidAuthorityPath, "utf8"),
  ) as { grant: { principal: { workspace_root: string } } };
  invalidAuthority.grant.principal.workspace_root = join(home, "tampered-workspace");
  writeFileSync(invalidAuthorityPath, JSON.stringify(invalidAuthority), {
    mode: 0o600,
  });
  const before = success(
    await requestAction(first.client, first.revision!, 152, "inspect", {
      session_id: sessionId,
    }),
    "inspect",
  ) as {
    monitors: Array<{ monitor_id: string; state: string }>;
    events: unknown[];
  };
  expect(before.monitors).toEqual(initialMonitors.map((_, index) => ({
    monitor_id: `monitor-${index + 1}`,
    state: process.platform === "darwin" && index === 1 ? "matched" : "active",
  })));
  if (process.platform === "darwin") {
    expect(before.events).toHaveLength(1);
    expect(before.events[0]).toMatchObject({ monitor_id: "monitor-2" });
  } else {
    expect(before.events).toEqual([]);
  }
  expect(JSON.stringify(before)).not.toContain("proof");
  let preRecoveryProbeChecks = 0;
  if (process.platform === "darwin") {
    await waitFor(() => monitorRuntimes()[1]!.check_count > 0);
    preRecoveryProbeChecks = monitorRuntimes()[1]!.check_count;
    expect(existsSync(outsideWrite)).toBe(true);
  }

  const oldIdentity = readFileSync(paths.identity, "utf8");
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);
  expect(await firstStdout).toBe("");
  expect(await firstStderr).toBe("");

  const replacement = startHost(home, undefined, 5_000);
  const replacementStdout = streamText(replacement.stdout);
  const replacementStderr = streamText(replacement.stderr);
  await waitFor(() =>
    existsSync(paths.socket) &&
    existsSync(paths.identity) &&
    readFileSync(paths.identity, "utf8") !== oldIdentity
  , 8_000);
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  await waitFor(() => !processExists(invalidPanePid), 5_000);
  const recoveredSessionNames = execFileSync(
    "tmux",
    ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
    { encoding: "utf8" },
  ).trim().split("\n");
  const recoveredPanePid = Number(execFileSync(
    "tmux",
    ["-S", tmuxSocket, "display-message", "-p", "-t", sessionName, "#{pane_pid}"],
    { encoding: "utf8" },
  ).trim());
  expect(recoveredSessionNames).toEqual([sessionName]);
  expect(recoveredPanePid).toBe(panePid);
  const invalidInspect = await requestAction(
    recovered.client,
    recovered.revision!,
    157,
    "inspect",
    { session_id: invalidSessionId },
  );
  expect(failure(invalidInspect).code).toBe("authority_denied");
  expect(JSON.stringify(invalidInspect)).not.toContain("proof");
  expect(existsSync(`/tmp/fx-tmux-capture-${invalidBackendIdentity}.sock`)).toBe(
    false,
  );
  expect(existsSync(`/tmp/fx-tmux-marker-${invalidBackendIdentity}.sock`)).toBe(
    false,
  );

  const recoveredInspect = success(
    await requestAction(recovered.client, recovered.revision!, 153, "inspect", {
      session_id: sessionId,
    }),
    "inspect",
  ) as typeof before;
  expect(recoveredInspect.monitors).toEqual(before.monitors);
  if (process.platform === "darwin") {
    expect(recoveredInspect.events).toHaveLength(1);
    expect(recoveredInspect.events[0]).toMatchObject({ monitor_id: "monitor-2" });
  } else {
    expect(recoveredInspect.events).toEqual([]);
  }
  expect(JSON.stringify(recoveredInspect)).not.toContain("proof");
  if (process.platform === "darwin") {
    await waitFor(() =>
      monitorRuntimes()[1]!.check_count > preRecoveryProbeChecks
    );
    expect(existsSync(outsideWrite)).toBe(true);
  }

  writeFileSync(scopeMarker, "ready");
  await waitFor(() => monitorRuntimes()[0]!.condition_matched, 5_000);
  const after = success(
    await requestAction(
      recovered.client,
      recovered.revision!,
      154,
      "inspect",
      { session_id: sessionId },
    ),
    "inspect",
  ) as {
    monitors: Array<{ monitor_id: string; state: string }>;
    events: Array<{ monitor_id: string; reason: string }>;
  };
  expect(after.monitors).toEqual(before.monitors.map((monitor, index) => ({
    ...monitor,
    state: index === 0 ? "matched" : monitor.state,
  })));
  expect(after.events).toContainEqual(expect.objectContaining({
    monitor_id: "monitor-1",
    reason: "state_changed",
  }));

  success(
    await requestAction(
      recovered.client,
      recovered.revision!,
      155,
      "close",
      { session_id: sessionId, policy: "force" },
    ),
    "close",
  );
  await waitFor(() => !existsSync(tmuxSocket));
  recovered.client.close();
  expect(await waitForExit(replacement)).toBe(0);
  expect(await replacementStdout).toBe("");
  expect(await replacementStderr).toBe("");
  await waitFor(() =>
    !processExists(panePid) &&
    !processExists(invalidPanePid) &&
    privateTmuxProcessPids(
        tmuxSocket,
        [backendIdentity, invalidBackendIdentity],
      ).length === 0
  , 5_000);
  expect(existsSync(paths.socket)).toBe(false);
  expect(existsSync(paths.identity)).toBe(false);
  expect(existsSync(`/tmp/fx-tmux-capture-${backendIdentity}.sock`)).toBe(false);
  expect(existsSync(`/tmp/fx-tmux-marker-${backendIdentity}.sock`)).toBe(false);
  expect(existsSync(`/tmp/fx-tmux-capture-${invalidBackendIdentity}.sock`)).toBe(
    false,
  );
  expect(existsSync(`/tmp/fx-tmux-marker-${invalidBackendIdentity}.sock`)).toBe(
    false,
  );
}, 30_000);

test.skipIf(!tmuxAvailable())("private tmux teardown owns partial recovery resources", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const tmuxSocket = join(paths.dir, "tmux.sock");
  const firstHost = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  await startCommand(first.client, first.revision!, 151, {
    cwd: home,
    command: "printf cleanup-ready; sleep 30",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "tmux",
    returnWhen: { match: "cleanup-ready" },
    waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
    startupAttempts: 2,
  });
  const sessionName = execFileSync(
    "tmux",
    ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
    { encoding: "utf8" },
  ).trim();
  const backendIdentity = sessionName.slice(3);
  const panePid = Number(execFileSync(
    "tmux",
    ["-S", tmuxSocket, "display-message", "-p", "-t", sessionName, "#{pane_pid}"],
    { encoding: "utf8" },
  ).trim());
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);

  const failedRecovery = startHost(home, undefined, 30_000, {
    FX_TERMINAL_TEST_TMUX_RECOVERY_FAILURE: "after-gap",
  });
  expect(await waitForExit(failedRecovery)).not.toBe(0);
  const proof = await cleanupPrivateTmuxServer(
    rememberPrivateTmuxServer(home),
  );

  expect(proof.identities).toContain(backendIdentity);
  expect(proof.panePids).toContain(panePid);
  expect(proof.panePids.every((pid) => !processExists(pid))).toBe(true);
  expect(proof.processPids.every((pid) => !processExists(pid))).toBe(true);
  expect(privateTmuxProcessPids(tmuxSocket, [backendIdentity])).toEqual([]);
  expect(existsSync(tmuxSocket)).toBe(false);
  expect(existsSync(`/tmp/fx-tmux-capture-${backendIdentity}.sock`)).toBe(false);
  expect(existsSync(`/tmp/fx-tmux-marker-${backendIdentity}.sock`)).toBe(false);
  expect(() =>
    execFileSync("tmux", ["-S", tmuxSocket, "has-session", "-t", sessionName], {
      stdio: "pipe",
    })
  ).toThrow();

  const retryProbe: PrivateTmuxResource = {
    socket: join(paths.dir, "cleanup-retry-probe.sock"),
    durableDir: paths.dir,
    identities: new Set(),
  };
  privateTmuxServers.set(retryProbe.socket, retryProbe);
  const transportRoot = mkdtempSync(join(tmpdir(), "fx-terminal-cleanup-root-"));
  transportRoots.add(transportRoot);
  const attempts: string[] = [];
  const cleanupFailure = new Error("cleanup failure");
  const pendingChild = children[0]!;
  let releasePendingChild!: () => void;
  let childWaitStarted = false;
  let childWaitReleased = false;
  const pendingChildExit = new Promise<number>((resolve) => {
    releasePendingChild = () => {
      childWaitReleased = true;
      resolve(0);
    };
  });
  let observedFailure: unknown;
  const cleanup = cleanupOwnedTestResources(async (resource) => {
    attempts.push(resource.socket);
    if (resource.socket === tmuxSocket) throw cleanupFailure;
    return { identities: [], panePids: [], processPids: [] };
  }, async (child) => {
    if (child === pendingChild) {
      childWaitStarted = true;
      return await pendingChildExit;
    }
    return await waitForExit(child);
  });
  try {
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(childWaitStarted).toBe(true);
    expect(childWaitReleased).toBe(false);
    expect(attempts).toEqual([tmuxSocket, retryProbe.socket]);
    expect(privateTmuxServers.size).toBe(0);
    expect(homes).toEqual([]);
    expect(transportRoots.size).toBe(0);
    expect(existsSync(home)).toBe(false);
    expect(existsSync(transportRoot)).toBe(false);
  } finally {
    releasePendingChild();
    try {
      await cleanup;
    } catch (error) {
      observedFailure = error;
    }
  }
  expect(observedFailure).toBe(cleanupFailure);
  expect(attempts).toEqual([tmuxSocket, retryProbe.socket]);
  let childRetryCount = 0;
  await cleanupOwnedTestResources(async (resource) => {
    attempts.push(resource.socket);
    return { identities: [], panePids: [], processPids: [] };
  }, async (child) => {
    childRetryCount += 1;
    return await waitForExit(child);
  });
  expect(attempts).toEqual([tmuxSocket, retryProbe.socket]);
  expect(childRetryCount).toBe(0);
}, 25_000);

test.skipIf(!tmuxAvailable())("alternate-screen host loss keeps tmux facts but reports unprovable modes", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const firstHost = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const command = [
    "printf '\\033[?1049h\\033[?25l\\033[4h\\033[?1h\\033=\\033[?6h\\033[?7l\\033[?1000h\\033[?2004h\\033[?1004h\\033[>1u'",
    "printf 'alt-mode-ready'",
    "IFS= read -r _",
  ].join("; ");
  const started = await startInteractiveTmuxFixture(
    first.client,
    first.revision!,
    150,
    {
      cwd: home,
      command,
      marker: "alt-mode-ready",
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const tmuxSocket = join(paths.dir, "tmux.sock");
  const sessionName = execFileSync(
    "tmux",
    ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
    { encoding: "utf8" },
  ).trim();
  const captureTmuxFacts = () => ({
    cells: execFileSync(
      "tmux",
      ["-S", tmuxSocket, "capture-pane", "-p", "-e", "-t", sessionName],
      { encoding: "utf8" },
    ),
    cursorAndModes: execFileSync(
      "tmux",
      [
        "-S",
        tmuxSocket,
        "display-message",
        "-p",
        "-t",
        sessionName,
        "#{cursor_y},#{cursor_x},#{cursor_flag},#{cursor_shape},#{alternate_on},#{origin_flag},#{wrap_flag},#{insert_flag},#{mouse_standard_flag},#{keypad_cursor_flag},#{keypad_flag}",
      ],
      { encoding: "utf8" },
    ).trim(),
  });
  const before = captureTmuxFacts();
  expect(before.cells).toContain("alt-mode-ready");
  expect(before.cursorAndModes.split(",")[4]).toBe("1");
  const oldIdentity = readFileSync(paths.identity, "utf8");
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);

  const replacement = startHost(home, undefined, 30_000);
  await waitFor(
    () => existsSync(paths.socket) && existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    8_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  success(
    await requestAction(recovered.client, recovered.revision!, 151, "inspect", {
      session_id: sessionId,
    }),
    "inspect",
  );
  expect(captureTmuxFacts()).toEqual(before);
  const screen = await requestAction(
    recovered.client,
    recovered.revision!,
    152,
    "screen",
    { session_id: sessionId },
  );
  expect(failure(screen).code).toBe("screen_unavailable");

  success(
    await requestAction(recovered.client, recovered.revision!, 153, "close", {
      session_id: sessionId,
      policy: "force",
    }),
    "close",
  );
  recovered.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, TMUX_COMMANDLESS_STARTUP_OBSERVATION_BUDGET_MS +
  TERMINAL_OPERATION_OBSERVATION_BUDGET_MS + 30_000);

test.skipIf(!tmuxAvailable())("tmux recovery records one raw gap and refuses an unprovable screen", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const release = join(home, "release-command");
  const firstHost = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startCommand(first.client, first.revision!, 112, {
    cwd: home,
    command: `printf 'before-loss\\n'; while [[ ! -f ${JSON.stringify(release)} ]]; do sleep 0.02; done; printf 'during-loss\\n'; exit 37`,
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "tmux",
    returnWhen: { match: "before-loss" },
    waitMs: 8_000,
    startupAttempts: 2,
  });
  const sessionId = (started.session as { session_id: string }).session_id;
  const before = await readSession(first.client, first.revision!, 113, sessionId);
  expect(before.output).toContain("before-loss");

  const oldIdentity = readFileSync(paths.identity, "utf8");
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);
  writeFileSync(release, "go");
  await waitFor(
    () => readdirSync(paths.dir).some((name) => {
      if (!name.endsWith("-lifecycle.bin")) return false;
      const bytes = readFileSync(join(paths.dir, name));
      return bytes.length >= 20 && bytes[bytes.length - 5] === 4;
    }),
    5_000,
  );

  const replacement = startHost(home, undefined, 30_000);
  await waitFor(
    () =>
      existsSync(paths.socket) &&
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    5_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspect = success(
    await requestAction(
      recovered.client,
      recovered.revision!,
      114,
      "inspect",
      { session_id: sessionId },
    ),
    "inspect",
  ) as { session: { lifecycle: string; raw_gap: unknown; output_cursor: { segment: number } } };
  expect(inspect.session.lifecycle).toBe("exited");
  expect(inspect.session.raw_gap).not.toBeNull();
  expect(inspect.session.output_cursor.segment).toBe(2);

  const retained = await readSession(
    recovered.client,
    recovered.revision!,
    115,
    sessionId,
  );
  expect(retained.output).toContain("before-loss");
  expect(retained.output).not.toContain("during-loss");
  const screen = await requestAction(
    recovered.client,
    recovered.revision!,
    116,
    "screen",
    { session_id: sessionId },
  );
  expect(failure(screen)).toMatchObject({
    action: "screen",
    code: "screen_unavailable",
  });
  await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

  recovered.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, 25_000);

test.skipIf(!tmuxAvailable())("tmux reconnect keeps one protocol responder and degrades gap monitors", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const resume = join(home, "resume-query");
  const command = [
    "function fx_query() {",
    "  printf '\\033[6'; sleep 0.03; printf 'n'",
    "  local fx_reply='' fx_char=''",
    "  while IFS= read -r -k 1 -t 2 fx_char; do fx_reply+=\"$fx_char\"; [[ $fx_char == R ]] && break; done",
    "  local fx_hex=$(printf %s \"$fx_reply\" | od -An -tx1 | tr -d ' \\n')",
    "  printf 'dsr-%s:%s\\n' \"$1\" \"$fx_hex\"",
    "}",
    "fx_query one",
    `while [[ ! -f ${JSON.stringify(resume)} ]]; do sleep 0.02; done`,
    "fx_query two",
    "printf 'input-ready\\n'",
    "IFS= read -r fx_input",
    "printf 'input:%s\\n' \"$fx_input\"",
    "trap 'exit 37' TERM",
    "sleep 30",
  ].join("\n");
  const firstHost = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startCommand(first.client, first.revision!, 117, {
    cwd: home,
    command,
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "tmux",
    returnWhen: { match: "dsr-one:" },
    waitMs: 8_000,
    initialMonitors: [
      {
        condition: { output_contains: "never-cross-gap" },
        notify_schedule: { on_state_change: {} },
        lifetime: { until_session_end: {} },
      },
      {
        condition: { process_exit: {} },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      },
    ],
  });
  const sessionId = (started.session as { session_id: string }).session_id;
  const firstOutput = await readSession(first.client, first.revision!, 118, sessionId);
  expect(firstOutput.output.match(/dsr-one:1b5b[0-9a-f]+52/g)).toHaveLength(1);

  const oldIdentity = readFileSync(paths.identity, "utf8");
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);
  const replacement = startHost(home, undefined, 30_000);
  await waitFor(
    () =>
      existsSync(paths.socket) &&
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    5_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspected = success(
    await requestAction(recovered.client, recovered.revision!, 119, "inspect", {
      session_id: sessionId,
    }),
    "inspect",
  ) as {
    session: { lifecycle: string; raw_gap: { available_from: { segment: number; offset: number } } };
    monitors: Array<{ monitor_id: string; state: string }>;
  };
  expect(inspected.session.lifecycle).toBe("running");
  expect(inspected.session.raw_gap.available_from.segment).toBe(2);
  expect(inspected.monitors).toEqual([
    { monitor_id: "monitor-1", state: "degraded" },
    { monitor_id: "monitor-2", state: "active" },
  ]);

  expect(failure(
    await requestAction(recovered.client, recovered.revision!, 120, "screen", {
      session_id: sessionId,
    }),
  ).code).toBe("screen_unavailable");
  writeFileSync(resume, "go");
  const secondReply = success(
    await requestAction(recovered.client, recovered.revision!, 121, "wait", {
      session_id: sessionId,
      return_when: { match: "dsr-two:" },
      safety_ceiling_ms: 5_000,
    }),
    "wait",
  );
  expect(secondReply.outcome).toEqual({ condition_met: {} });
  const gapCursor = inspected.session.raw_gap.available_from;
  const afterGap = success(
    await requestAction(recovered.client, recovered.revision!, 122, "read", {
      session_id: sessionId,
      cursor: gapCursor,
    }),
    "read",
  ) as { output: string };
  expect(afterGap.output.match(/dsr-two:1b5b[0-9a-f]+52/g)).toHaveLength(1);

  const written = success(
    await requestAction(recovered.client, recovered.revision!, 123, "write", {
      session_id: sessionId,
      payload: { text: "hello\n" },
    }),
    "write",
  );
  expect(written.accepted_bytes).toBe(6);
  success(
    await requestAction(recovered.client, recovered.revision!, 124, "wait", {
      session_id: sessionId,
      return_when: { match: "input:hello" },
      safety_ceiling_ms: 5_000,
    }),
    "wait",
  );
  const screen = await requestAction(
    recovered.client,
    recovered.revision!,
    125,
    "screen",
    {
      session_id: sessionId,
    },
  );
  expect(failure(screen).code).toBe("screen_unavailable");

  success(
    await requestAction(recovered.client, recovered.revision!, 126, "signal", {
      session_id: sessionId,
      signal: "kill",
    }),
    "signal",
  );
  const waited = success(
    await requestAction(recovered.client, recovered.revision!, 127, "wait", {
      session_id: sessionId,
      return_when: { exit: {} },
      safety_ceiling_ms: 5_000,
    }),
    "wait",
  );
  expect(waited.outcome).toEqual({ signal: 9 });
  success(
    await requestAction(recovered.client, recovered.revision!, 128, "close", {
      session_id: sessionId,
      policy: "force",
    }),
    "close",
  );
  const rejected = await requestAction(
    recovered.client,
    recovered.revision!,
    129,
    "write",
    { session_id: sessionId, payload: { text: "stale\n" } },
  );
  expect(failure(rejected).code).toBe("authority_denied");
  await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));

  recovered.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, 30_000);

test.skipIf(!tmuxAvailable())("tmux recovery rejects a replaced pane without signaling it", async () => {
  if (!existsSync("/bin/zsh") || !existsSync("/bin/sleep")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const firstHost = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startCommand(first.client, first.revision!, 133, {
    cwd: home,
    command: "printf identity-ready; sleep 30",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "tmux",
    returnWhen: { match: "identity-ready" },
    waitMs: 8_000,
  });
  const sessionId = (started.session as { session_id: string }).session_id;
  const tmuxSocket = join(paths.dir, "tmux.sock");
  const sessionName = execFileSync(
    "tmux",
    ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
    { encoding: "utf8" },
  ).trim();
  const backendIdentity = sessionName.slice(3);
  const oldIdentity = readFileSync(paths.identity, "utf8");
  first.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);

  execFileSync("tmux", ["-S", tmuxSocket, "kill-session", "-t", sessionName]);
  execFileSync(
    "tmux",
    [
      "-S",
      tmuxSocket,
      "-f",
      "/dev/null",
      "new-session",
      "-d",
      "-s",
      sessionName,
      "-n",
      "terminal",
      "/bin/sleep 30",
    ],
  );
  execFileSync("tmux", [
    "-S",
    tmuxSocket,
    "set-option",
    "-g",
    "@fx_terminal_namespace",
    "1",
  ]);
  execFileSync("tmux", [
    "-S",
    tmuxSocket,
    "set-option",
    "-t",
    sessionName,
    "@fx_terminal_namespace",
    backendIdentity,
  ]);

  const replacement = startHost(home, undefined, 30_000);
  await waitFor(
    () =>
      existsSync(paths.socket) &&
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    5_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspect = success(
    await requestAction(recovered.client, recovered.revision!, 134, "inspect", {
      session_id: sessionId,
    }),
    "inspect",
  );
  expect(inspect.session).toMatchObject({ lifecycle: "lost", backend: "tmux" });
  expect(
    execFileSync("tmux", ["-S", tmuxSocket, "has-session", "-t", sessionName]),
  ).toBeDefined();

  execFileSync("tmux", ["-S", tmuxSocket, "kill-server"]);

  recovered.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, 25_000);

test.skipIf(!tmuxAvailable())("tmux repeated force-close cycles leave no Fx server", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 30_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  for (let index = 0; index < 3; index++) {
    const started = await startCommand(
      connected.client,
      connected.revision!,
      140 + index * 2,
      {
        cwd: home,
        command: `printf cycle-${index}-ready; sleep 30`,
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        backend: "tmux",
        returnWhen: { match: `cycle-${index}-ready` },
        waitMs: 8_000,
        startupAttempts: 2,
      },
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    const closed = success(
      await requestAction(
        connected.client,
        connected.revision!,
        141 + index * 2,
        "close",
        { session_id: sessionId, policy: "force" },
      ),
      "close",
    );
    expect(closed.session).toMatchObject({ lifecycle: "closed", backend: "tmux" });
    await waitFor(() => !existsSync(join(paths.dir, "tmux.sock")));
  }

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 30_000);

test("durable authority survives reconnect and rejects every foreign scope", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    first.client,
    first.revision!,
    120_000,
    {
      cwd: home,
      command:
        "printf auth-ready; while IFS= read -r line; do printf 'got:%s\\n' \"$line\"; done",
      marker: "auth-ready",
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;

  const read = await readSession(first.client, first.revision!, 121, sessionId);
  expect(read.output).toContain("auth-ready");
  const screen = await requestAction(
    first.client,
    first.revision!,
    122,
    "screen",
    { session_id: sessionId },
  );
  expect(success(screen, "screen").session).toMatchObject({
    session_id: sessionId,
  });
  const listed = await requestAction(first.client, first.revision!, 123, "list", {});
  expect(
    (success(listed, "list").sessions as Array<{ session_id: string }>)
      .map((session) => session.session_id),
  ).toContain(sessionId);

  first.client.close();
  const reconnected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspect = await requestAction(
    reconnected.client,
    reconnected.revision!,
    124,
    "inspect",
    { session_id: sessionId },
  );
  expect(success(inspect, "inspect").session).toMatchObject({
    lifecycle: "running",
  });

  const current = authorityBySession.get(sessionId)! as {
    principal: Record<string, unknown>;
    generation: { value: number };
    proof: { bytes: number[] };
  };
  const foreignClaims = [
    authorityVariant(sessionId, {
      principal: { ...current.principal, profile_user: "foreign-profile" },
    }),
    authorityVariant(sessionId, {
      principal: { ...current.principal, durable_session_id: "foreign-owner" },
    }),
    authorityVariant(sessionId, {
      principal: { ...current.principal, workspace_root: "/foreign-workspace" },
    }),
    authorityVariant(sessionId, {
      principal: { ...current.principal, cwd: "/foreign-cwd" },
    }),
    authorityVariant(sessionId, {
      principal: { ...current.principal, transport_role: "acp" },
    }),
    authorityVariant(sessionId, {
      principal: { ...current.principal, backend: "tmux" },
    }),
    authorityVariant(sessionId, { actor: "human" }),
    authorityVariant(sessionId, { proof: { bytes: [8, ...current.proof.bytes.slice(1)] } }),
    authorityVariant(sessionId, { generation: { value: current.generation.value + 1 } }),
  ];
  let correlation = 125;
  for (const authority of foreignClaims) {
    const rejected = await requestAction(
      reconnected.client,
      reconnected.revision!,
      correlation++,
      "read",
      {
        session_id: sessionId,
        cursor: { segment: 1, offset: 0 },
        authority,
      },
    );
    expect(failure(rejected).code).toBe("authority_denied");
  }

  const observerStart = withPersistence({
    cwd: home,
    command: "printf observer-ready; sleep 90",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "native",
    return_when: { match: "observer-ready" },
    wait_ceiling_ms: NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: [],
  });
  const observerPersistence = observerStart.persistence as {
    grant: { controls: Record<string, boolean> };
  };
  observerPersistence.grant.controls = {
    read: true,
    screen: true,
    write: false,
    wait: false,
    monitor: false,
    inspect: true,
    list: true,
    resize: false,
    signal: false,
    close: false,
  };
  const observerFrame = await requestAction(
    reconnected.client,
    reconnected.revision!,
    correlation++,
    "start",
    observerStart,
  );
  const observer = success(observerFrame, "start");
  const observerId = (observer.session as { session_id: string }).session_id;
  expect(observer.session).toMatchObject({ lifecycle: "running" });
  const expanded = await requestAction(
    reconnected.client,
    reconnected.revision!,
    correlation++,
    "write",
    { session_id: observerId, lease: "acquire" },
  );
  expect(failure(expanded).code).toBe("authority_denied");

  const priorIdentity = readFileSync(paths.identity, "utf8");
  reconnected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
  const replacement = startHost(home, undefined, 10_000);
  await waitFor(() =>
    existsSync(paths.identity) &&
    readFileSync(paths.identity, "utf8") !== priorIdentity
  );
  const afterHostRestart = await handshake(paths.socket, { minimum: 4, current: 5 });
  const recoveredRead = await requestAction(
    afterHostRestart.client,
    afterHostRestart.revision!,
    correlation++,
    "read",
    { session_id: sessionId, cursor: { segment: 1, offset: 0 } },
  );
  expect(success(recoveredRead, "read").session).toMatchObject({ lifecycle: "lost" });

  const closed = await requestAction(
    afterHostRestart.client,
    afterHostRestart.revision!,
    correlation++,
    "close",
    { session_id: sessionId, policy: "force" },
  );
  expect(success(closed, "close").session).toMatchObject({ lifecycle: "closed" });
  const stale = await requestAction(
    afterHostRestart.client,
    afterHostRestart.revision!,
    correlation++,
    "read",
    { session_id: sessionId, cursor: { segment: 1, offset: 0 } },
  );
  expect(failure(stale).code).toBe("authority_denied");

  afterHostRestart.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 10 + 30_000);

test("direct human leases keep the owning model observational", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const directStart = withPersistence({
    cwd: home,
    command: "printf direct-ready; sleep 30",
    shell: { executable: { path: "/bin/zsh", clean_start: true } },
    backend: "native",
    return_when: { match: "direct-ready" },
    wait_ceiling_ms: 5_000,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: [],
  });
  const persistence = directStart.persistence as {
    grant: { actor: string };
    direct_human_model_read_only: boolean;
  };
  persistence.grant.actor = "human";
  persistence.direct_human_model_read_only = true;
  const startFrame = await requestAction(
    connected.client,
    connected.revision!,
    180,
    "start",
    directStart,
  );
  const started = success(startFrame, "start");
  const sessionId = (started.session as { session_id: string }).session_id;
  const modelAuthority = authorityVariant(sessionId, { actor: "agent" });

  const humanLease = await requestAction(
    connected.client,
    connected.revision!,
    181,
    "write",
    { session_id: sessionId, lease: "acquire" },
  );
  expect(success(humanLease, "write").session).toMatchObject({
    attention: { attention: "user_takeover", write_lease: "human" },
  });
  const modelRead = await requestAction(
    connected.client,
    connected.revision!,
    182,
    "read",
    {
      session_id: sessionId,
      cursor: { segment: 1, offset: 0 },
      authority: modelAuthority,
    },
  );
  expect(success(modelRead, "read").session).toMatchObject({
    next_actions: {
      read: true,
      screen: true,
      write: false,
      wait: false,
      monitor: false,
      inspect: true,
      list: true,
      resize: false,
      signal: false,
      close: false,
    },
  });
  for (const action of ["screen", "inspect"] as const) {
    const observed = await requestAction(
      connected.client,
      connected.revision!,
      action === "screen" ? 183 : 184,
      action,
      { session_id: sessionId, authority: modelAuthority },
    );
    expect(success(observed, action).session).toMatchObject({ session_id: sessionId });
  }
  const modelList = await requestAction(
    connected.client,
    connected.revision!,
    185,
    "list",
    {
      owner_authority: ownerCatalogAuthorityForSession(sessionId, modelAuthority),
    },
  );
  expect(success(modelList, "list").sessions).toHaveLength(1);
  const conflict = await requestAction(
    connected.client,
    connected.revision!,
    186,
    "write",
    { session_id: sessionId, lease: "acquire", authority: modelAuthority },
  );
  expect(failure(conflict).code).toBe("lease_conflict");

  const released = await requestAction(
    connected.client,
    connected.revision!,
    187,
    "write",
    { session_id: sessionId, lease: "release" },
  );
  expect(success(released, "write").session).toMatchObject({
    attention: { attention: "background", write_lease: "none" },
  });
  const deniedLease = await requestAction(
    connected.client,
    connected.revision!,
    188,
    "write",
    { session_id: sessionId, lease: "acquire", authority: modelAuthority },
  );
  expect(failure(deniedLease).code).toBe("authority_denied");
  for (const [action, value] of [
    ["wait", { return_when: { exit: {} }, safety_ceiling_ms: 1 }],
    ["monitor", { operation: { pause: "model-denied" } }],
    ["resize", { dimensions: { rows: 20, columns: 60 } }],
    ["signal", { signal: "interrupt" }],
    ["close", { policy: "force" }],
  ] as const) {
    const denied = await requestAction(
      connected.client,
      connected.revision!,
      189 + ["wait", "monitor", "resize", "signal", "close"].indexOf(action),
      action,
      { session_id: sessionId, ...value, authority: modelAuthority },
    );
    expect(failure(denied).code).toBe("authority_denied");
  }
  const humanClose = await requestAction(
    connected.client,
    connected.revision!,
    200,
    "close",
    { session_id: sessionId, policy: "force" },
  );
  expect(success(humanClose, "close").session).toMatchObject({ lifecycle: "closed" });
  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 20_000);

test.each([
  { point: "allocation" },
  { point: "validation" },
  { point: "persistence" },
  { point: "timer" },
  { point: "installation" },
])("initial monitor $point failure rolls back before child release", async ({ point }) => {
  const home = makeHome();
  const paths = hostPaths(home);
  const marker = join(home, "monitor-started");
  const host = startHost(home, undefined, 400, {
    FX_TERMINAL_TEST_FAIL_MONITOR_INSTALL: point,
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const initialMonitor = point === "allocation"
    ? {
      condition: { custom_probe: { command: "true", cwd: home } },
      check_schedule: { interval_ms: 25 },
      notify_schedule: { on_match: {} },
      lifetime: { until_match: {} },
    }
    : {
      condition: { output_contains: "ready" },
      notify_schedule: { on_match: {} },
      lifetime: { until_session_end: {} },
    };
  const frame = await requestAction(
    connected.client,
    connected.revision!,
    210,
    "start",
    {
      cwd: home,
      command: `: > '${marker}'; sleep 30`,
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [initialMonitor],
    },
  );
  expect(failure(frame)).toMatchObject({
    action: "start",
    code: ["timer", "installation"].includes(point)
      ? "startup_failed"
      : "invalid_request",
  });
  expect(existsSync(marker)).toBe(false);
  expect(directChildPids(host.pid!)).toEqual([]);
  const terminalState = join(home, ".fx", "sessions", TERMINAL_OWNER_SESSION);
  expect(readdirSync(terminalState).filter((name) => name.includes("terminal-")))
    .toEqual([]);
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, 10_000);

test("poll path escapes preserve exact failures only for capable peers", async () => {
  for (const testCase of [
    { capabilities: 31, expectedCode: "path_outside_workspace" },
    { capabilities: 7, expectedCode: "invalid_request" },
  ]) {
    const home = makeHome();
    const outside = mkdtempSync(join(tmpdir(), "fx-terminal-monitor-outside-"));
    homes.push(outside);
    writeFileSync(join(outside, "ready"), "ready");
    symlinkSync(outside, join(home, "escape"));
    const paths = hostPaths(home);
    const marker = join(home, "monitor-started");
    const host = startHost(home, undefined, 500);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(
      paths.socket,
      { minimum: 4, current: 5 },
      testCase.capabilities,
    );
    const frame = await requestAction(connected.client, connected.revision!, 211, "start", {
      cwd: home,
      command: `: > '${marker}'`,
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { exit: {} },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [{
        condition: { path_exists: join(home, "escape", "ready") },
        check_schedule: { interval_ms: 25 },
        notify_schedule: { on_match: {} },
        lifetime: { until_match: {} },
      }],
    });
    expect(failure(frame).code).toBe(testCase.expectedCode);
    expect(existsSync(marker)).toBe(false);
    expect(directChildPids(host.pid!)).toEqual([]);
    const terminalState = join(home, ".fx", "sessions", TERMINAL_OWNER_SESSION);
    expect(readdirSync(terminalState).filter((name) => name.includes("terminal-")))
      .toEqual([]);
    connected.client.close();
    expect(await waitForExit(host)).toBe(0);
  }
}, 10_000);

test("custom probe re-canonicalization rejects a post-install symlink swap", async () => {
  const home = makeHome();
  const inside = join(home, "inside");
  mkdirSync(inside);
  const outside = mkdtempSync(join(tmpdir(), "fx-terminal-monitor-swap-"));
  homes.push(outside);
  const alias = join(home, "probe-cwd");
  const executed = join(outside, "executed");
  symlinkSync(inside, alias);
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 300);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await requestAction(connected.client, connected.revision!, 211, "start", {
    cwd: home,
    command: "sleep 30",
    shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    backend: "native",
    return_when: { started: {} },
    wait_ceiling_ms: 5_000,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: [{
      condition: {
        custom_probe: {
          command: `[ "$(pwd -P)" = '${outside}' ] && : > '${executed}'`,
          cwd: alias,
        },
      },
      check_schedule: { interval_ms: 500 },
      notify_schedule: { on_match: {} },
      lifetime: { until_session_end: {} },
    }],
  });
  const sessionId = (
    success(started, "start").session as { session_id: string }
  ).session_id;
  rmSync(alias);
  symlinkSync(outside, alias);
  await Bun.sleep(750);
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    212,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { events: unknown[] };
  expect(inspected.events).toEqual([]);
  expect(existsSync(executed)).toBe(false);
  await requestAction(connected.client, connected.revision!, 213, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, 15_000);

test("paused duration monitor expires once and releases idle ownership", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 5_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await requestAction(connected.client, connected.revision!, 214, "start", {
    cwd: home,
    command: "sleep 30",
    shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    backend: "native",
    return_when: { started: {} },
    wait_ceiling_ms: 5_000,
    dimensions: { rows: 24, columns: 80 },
  });
  const sessionId = (
    success(started, "start").session as { session_id: string }
  ).session_id;
  const added = success(await requestAction(
    connected.client,
    connected.revision!,
    215,
    "monitor",
    {
      session_id: sessionId,
      operation: {
        add: {
          condition: { output_contains: "never" },
          notify_schedule: { on_state_change: {} },
          lifetime: { duration_ms: 5_000 },
        },
      },
    },
  ), "monitor");
  expect(added.monitor_id).toBe("monitor-1");
  await Bun.sleep(2_000);
  success(await requestAction(connected.client, connected.revision!, 216, "monitor", {
    session_id: sessionId,
    operation: { pause: "monitor-1" },
  }), "monitor");
  await Bun.sleep(3_500);
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    217,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    session: { active_monitor_count: number };
    monitors: unknown[];
    events: Array<{ reason: string; created_at_ms: number }>;
  };
  expect(inspected.session.active_monitor_count).toBe(0);
  expect(inspected.monitors).toEqual([]);
  expect(inspected.events.map((event) => event.reason)).toEqual([
    "paused",
    "expired",
  ]);
  const pausedEvent = inspected.events[0]!;
  const expiredEvent = inspected.events[1]!;
  expect(expiredEvent.created_at_ms).toBeGreaterThanOrEqual(pausedEvent.created_at_ms);
  expect(expiredEvent.created_at_ms - pausedEvent.created_at_ms).toBeLessThan(4_000);
  await requestAction(connected.client, connected.revision!, 218, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, 20_000);

test("fast split output and exit monitors replay and acknowledge exactly once", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  let connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const start = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    211_000,
    {
      cwd: home,
      command: "printf monitor-; sleep 0.05; printf ready; exit 17",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      returnWhen: { exit: {} },
      waitMs: NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2,
      dimensions: { rows: 24, columns: 80 },
      initialMonitors: [
        {
          condition: { output_contains: "monitor-ready" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { process_exit: {} },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { exit_code: 17 },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { output_matches: "monitor-*ready" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { screen_matches: "monitor-*ready" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
      ],
    },
  );
  const sessionId = (start.session as { session_id: string }).session_id;
  expect(start.outcome).toEqual({ exited: 17 });

  const firstInspect = await requestAction(
    connected.client,
    connected.revision!,
    212,
    "inspect",
    { session_id: sessionId },
  );
  const first = success(firstInspect, "inspect") as {
    events: Array<{ event_id: number; monitor_id: string; reason: string }>;
  };
  expect(first.events.map((event) => event.monitor_id).sort()).toEqual([
    "monitor-1",
    "monitor-2",
    "monitor-3",
    "monitor-4",
    "monitor-5",
  ]);
  expect(first.events.every((event) => event.reason === "matched")).toBe(true);
  expect(new Set(first.events.map((event) => event.event_id)).size).toBe(5);
  const lastEventId = Math.max(...first.events.map((event) => event.event_id));
  connected.client.close();

  await waitFor(() => {
    if (host.exitCode !== null || !processExists(host.pid!)) {
      throw new Error("terminal host exited before replay reconnect");
    }
    return existsSync(paths.socket);
  }, 2_000);
  connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const replayed = success(await requestAction(
    connected.client,
    connected.revision!,
    213,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { events: Array<{ event_id: number }> };
  expect(replayed.events.map((event) => event.event_id)).toEqual(
    first.events.map((event) => event.event_id),
  );

  const currentAuthority = authorityBySession.get(sessionId)! as {
    proof: { bytes: number[] };
  };
  const deniedAcknowledgement = await requestAction(
    connected.client,
    connected.revision!,
    214,
    "inspect",
    {
      session_id: sessionId,
      acknowledge_event_id: lastEventId,
      authority: authorityVariant(sessionId, {
        proof: {
          bytes: [8, ...currentAuthority.proof.bytes.slice(1)],
        },
      }),
    },
  );
  expect(failure(deniedAcknowledgement).code).toBe("authority_denied");
  const retained = success(await requestAction(
    connected.client,
    connected.revision!,
    215,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { events: Array<{ event_id: number }> };
  expect(retained.events.map((event) => event.event_id)).toEqual(
    first.events.map((event) => event.event_id),
  );

  const acknowledged = success(await requestAction(
    connected.client,
    connected.revision!,
    216,
    "inspect",
    {
      session_id: sessionId,
      after_event_id: lastEventId,
      acknowledge_event_id: lastEventId,
    },
  ), "inspect") as { events: unknown[] };
  expect(acknowledged.events).toEqual([]);
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

const automaticTransitionCases = [
  "output",
  "screen",
  "quiet",
  "polling",
  "expiry",
] as const;

test.each(automaticTransitionCases)(
  "automatic %s notification and removal survive reconnect as one transition",
  async (kind) => {
    const home = makeHome();
    const paths = hostPaths(home);
    const watched = join(home, "automatic-ready");
    if (kind === "polling") writeFileSync(watched, "ready");
    const condition = kind === "output"
      ? { output_contains: "transition-ready" }
      : kind === "screen"
      ? { screen_matches: "*transition-ready*" }
      : kind === "quiet"
      ? { output_quiet_ms: 50 }
      : kind === "polling"
      ? { path_exists: watched }
      : { output_contains: "never" };
    const definition = {
      condition,
      ...(kind === "polling"
        ? { check_schedule: { interval_ms: 25 } }
        : {}),
      notify_schedule: kind === "expiry"
        ? { on_state_change: {} }
        : { on_match: {} },
      lifetime: kind === "expiry"
        ? { duration_ms: 100 }
        : { until_match: {} },
    };
    const host = startHost(home, undefined, 300);
    await waitFor(() => existsSync(paths.socket));
    let connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const started = await startInteractiveNativeFixture(
      connected.client,
      connected.revision!,
      230,
      {
        cwd: home,
        command:
          "stty -echo; printf automatic-fixture-ready; while IFS= read -r line; do eval \"$line\"; done",
        marker: "automatic-fixture-ready",
        dimensions: { rows: 6, columns: 40 },
      },
    );
    let correlation = 234;
    const sessionId = (
      started.session as { session_id: string }
    ).session_id;
    success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "monitor",
      { session_id: sessionId, operation: { add: definition } },
    ), "monitor");
    if (kind === "output" || kind === "screen") {
      success(await requestAction(
        connected.client,
        connected.revision!,
        correlation++,
        "write",
        { session_id: sessionId, payload: { text: "printf transition-ready\n" } },
      ), "write");
    }
    let settled: {
      session: { active_monitor_count: number };
      monitors: unknown[];
      events: Array<{ event_id: number; monitor_id: string; reason: string }>;
    } | undefined;
    await waitFor(async () => {
      settled = success(await requestAction(
        connected.client,
        connected.revision!,
        correlation++,
        "inspect",
        { session_id: sessionId },
      ), "inspect") as typeof settled;
      return settled!.monitors.length === 0 && settled!.events.length === 1;
    }, 5_000);
    expect(settled!.session.active_monitor_count).toBe(0);
    expect(settled!.events).toHaveLength(1);
    expect(settled!.events[0]).toMatchObject({
      monitor_id: "monitor-1",
      reason: kind === "expiry" ? "expired" : "matched",
    });
    const eventId = settled!.events[0]!.event_id;
    connected.client.close();

    await waitFor(() => {
      if (host.exitCode !== null || !processExists(host.pid!)) {
        throw new Error(`terminal host exited before ${kind} replay`);
      }
      return existsSync(paths.socket);
    });
    connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const replayed = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as typeof settled;
    expect(replayed.monitors).toEqual([]);
    expect(replayed.events.map((event) => event.event_id)).toEqual([eventId]);
    const acknowledged = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      {
        session_id: sessionId,
        after_event_id: eventId,
        acknowledge_event_id: eventId,
      },
    ), "inspect") as typeof settled;
    expect(acknowledged.events).toEqual([]);
    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "close",
      { session_id: sessionId, policy: "force" },
    );
    connected.client.close();
    expect(await waitForExit(host)).toBe(0);
  },
  NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000,
);

test("non-notifying until-match removal persists without retaining a monitor", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(
    home,
    undefined,
    NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3,
  );
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeShellFixture(
    connected.client,
    connected.revision!,
    240,
    {
      cwd: home,
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      dimensions: { rows: 6, columns: 40 },
      initialMonitors: [{
        condition: { output_contains: "silent-ready" },
        notify_schedule: { on_exit: {} },
        lifetime: { until_match: {} },
      }],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  let correlation = 241;
  success(
    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "write",
      {
        session_id: sessionId,
        payload: { text: "printf silent-ready\n" },
      },
    ),
    "write",
  );
  await waitFor(async () => {
    const inspected = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as { monitors: unknown[]; events: unknown[] };
    if (inspected.monitors.length !== 0) return false;
    expect(inspected.events).toEqual([]);
    return true;
  });
  await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "close",
    { session_id: sessionId, policy: "force" },
  );
  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 15_000);

test("every-check schedules follow polling output screen quiet and exit evaluations", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 5_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    214,
    {
      cwd: home,
      command:
        "sleep 0.08; printf schedule-output; sleep 0.08; printf tail; sleep 0.2; exit 0",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      returnWhen: { exit: {} },
      waitMs: 5_000,
      dimensions: { rows: 4, columns: 40 },
      initialMonitors: [
        {
          condition: { path_exists: join(home, "never-created") },
          check_schedule: { interval_ms: 25 },
          notify_schedule: { every_n_checks: 2 },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { output_contains: "schedule-output" },
          notify_schedule: { every_check: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { screen_matches: "schedule-output*" },
          notify_schedule: { every_check: {} },
          lifetime: { duration_ms: 2_000 },
        },
        {
          condition: { output_quiet_ms: 50 },
          notify_schedule: { every_check: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { process_exit: {} },
          notify_schedule: { every_check: {} },
          lifetime: { until_session_end: {} },
        },
      ],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    215,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    events: Array<{ monitor_id: string; reason: string }>;
  };
  const eventsByMonitor = new Map<string, string[]>();
  for (const event of inspected.events) {
    const reasons = eventsByMonitor.get(event.monitor_id) ?? [];
    reasons.push(event.reason);
    eventsByMonitor.set(event.monitor_id, reasons);
  }
  for (let sequence = 1; sequence <= 5; sequence++) {
    expect(eventsByMonitor.get(`monitor-${sequence}`)).toContain("check");
  }
  expect(eventsByMonitor.get("monitor-2")!.length).toBeGreaterThanOrEqual(2);
  expect(eventsByMonitor.get("monitor-3")!.length).toBeGreaterThanOrEqual(2);
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 15_000);

test("successful resize alone evaluates the changed screen monitor", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 300);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    214,
    {
      cwd: home,
      command: "printf 'ab界'; sleep 90",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      returnWhen: { match: "ab界" },
      waitMs: 5_000,
      dimensions: { rows: 2, columns: 4 },
      initialMonitors: [{
        condition: { screen_matches: "ab\n" },
        notify_schedule: { on_match: {} },
        lifetime: { until_match: {} },
      }],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const before = success(await requestAction(
    connected.client,
    connected.revision!,
    215,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { events: unknown[] };
  expect(before.events).toEqual([]);
  success(await requestAction(connected.client, connected.revision!, 216, "resize", {
    session_id: sessionId,
    dimensions: { rows: 2, columns: 3 },
  }), "resize");
  const after = success(await requestAction(
    connected.client,
    connected.revision!,
    217,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    events: Array<{ monitor_id: string; reason: string }>;
  };
  expect(after.events).toEqual([{
    event_id: expect.any(Number),
    monitor_id: "monitor-1",
    reason: "matched",
    lifecycle: "running",
    cursor: expect.any(Object),
    created_at_ms: expect.any(Number),
  }]);
  await requestAction(connected.client, connected.revision!, 218, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 15_000);

test("screen projection failure leaves every resize owner unchanged", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const winchMarker = join(home, "unexpected-winch");
  const sizeFile = join(home, "pty-size");
  const host = startHost(home, undefined, 5_000, {
    FX_TERMINAL_TEST_FAIL_MONITOR_SCREEN_PROJECTION_ALLOCATION: "1",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    connected.client,
    connected.revision!,
    219_000,
    {
      cwd: home,
      command:
        `trap ': > "${winchMarker}"' WINCH; printf resize-ready; ` +
        `while IFS= read -r line; do eval "$line"; done`,
      marker: "resize-ready",
      dimensions: { rows: 4, columns: 12 },
      initialMonitors: [{
        condition: { screen_matches: "never-match" },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      }],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  await Bun.sleep(100);
  const beforeInspect = success(await requestAction(
    connected.client,
    connected.revision!,
    220,
    "inspect",
    { session_id: sessionId },
  ), "inspect");
  const beforeScreen = success(await requestAction(
    connected.client,
    connected.revision!,
    221,
    "screen",
    { session_id: sessionId },
  ), "screen");
  const stateDir = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
  );
  const durableBefore = new Map(
    readdirSync(stateDir)
      .filter((name) => name.includes(sessionId))
      .map((name) => [name, readFileSync(join(stateDir, name))]),
  );

  const resized = await requestAction(
    connected.client,
    connected.revision!,
    222,
    "resize",
    { session_id: sessionId, dimensions: { rows: 7, columns: 19 } },
  );
  expect(failure(resized)).toMatchObject({
    action: "resize",
    code: "invalid_request",
  });
  await Bun.sleep(100);
  const afterInspect = success(await requestAction(
    connected.client,
    connected.revision!,
    223,
    "inspect",
    { session_id: sessionId },
  ), "inspect");
  const afterScreen = success(await requestAction(
    connected.client,
    connected.revision!,
    224,
    "screen",
    { session_id: sessionId },
  ), "screen");
  expect(afterInspect).toEqual(beforeInspect);
  expect(afterScreen).toEqual(beforeScreen);
  expect(existsSync(winchMarker)).toBe(false);
  const durableAfter = new Map(
    readdirSync(stateDir)
      .filter((name) => name.includes(sessionId))
      .map((name) => [name, readFileSync(join(stateDir, name))]),
  );
  expect([...durableAfter.keys()].sort()).toEqual([...durableBefore.keys()].sort());
  for (const [name, bytes] of durableBefore) {
    expect(durableAfter.get(name)).toEqual(bytes);
  }

  success(await requestAction(
    connected.client,
    connected.revision!,
    225,
    "write",
    { session_id: sessionId, payload: { text: `stty size > '${sizeFile}'\n` } },
  ), "write");
  await waitFor(() =>
    existsSync(sizeFile) && readFileSync(sizeFile, "utf8").trim() === "4 12"
  );
  expect(readFileSync(sizeFile, "utf8").trim()).toBe("4 12");
  await requestAction(connected.client, connected.revision!, 226, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("PTY output projection failure skips screen checks while output checks continue", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 300, {
    FX_TERMINAL_TEST_FAIL_MONITOR_OUTPUT_SCREEN_PROJECTION_ALLOCATION: "1",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    connected.client,
    connected.revision!,
    227,
    {
      cwd: home,
      command: "printf projection-ready; IFS= read -r _",
      marker: "projection-ready",
      dimensions: { rows: 6, columns: 40 },
      initialMonitors: [
        {
          condition: { output_contains: "projection-ready" },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
        {
          condition: { screen_matches: "*projection-ready*" },
          notify_schedule: { every_check: {} },
          lifetime: { until_session_end: {} },
        },
      ],
    },
  );
  const sessionId = (
    started.session as { session_id: string }
  ).session_id;
  let correlation = 231;
  let inspected: {
    monitors: Array<{ monitor_id: string; state: string }>;
    events: Array<{ monitor_id: string; reason: string }>;
  } | undefined;
  await waitFor(async () => {
    inspected = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as typeof inspected;
    return inspected!.events.length === 1;
  });
  expect(inspected!.events).toEqual([{
    event_id: expect.any(Number),
    monitor_id: "monitor-1",
    reason: "matched",
    lifecycle: "running",
    cursor: expect.any(Object),
    created_at_ms: expect.any(Number),
  }]);
  expect(inspected!.monitors).toEqual([{
    monitor_id: "monitor-2",
    state: "active",
  }]);
  const monitorFile = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
    `monitors-${sessionId}.json`,
  );
  const durable = JSON.parse(readFileSync(monitorFile, "utf8")) as {
    monitors: Array<{
      monitor_id: string;
      runtime: { check_count: number; notification_count: number };
    }>;
  };
  expect(durable.monitors).toHaveLength(1);
  expect(durable.monitors[0]).toMatchObject({
    monitor_id: "monitor-2",
    runtime: { check_count: 0, notification_count: 0 },
  });
  await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "close",
    { session_id: sessionId, policy: "force" },
  );
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("filesystem quiet and exact custom-probe monitors run without a client", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const watched = join(home, "watched.txt");
  const probeMarker = join(home, "probe-ready");
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  let connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const probe = `test -f '${probeMarker}'`;
  const started = await requestAction(
    connected.client,
    connected.revision!,
    215,
    "start",
    {
      cwd: home,
      command: "sleep 30",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [
        {
          condition: { path_exists: watched },
          check_schedule: { interval_ms: 25 },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
        {
          condition: { path_changed: watched },
          check_schedule: { interval_ms: 25 },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
        {
          condition: { path_size: { path: watched, minimum_bytes: 5 } },
          check_schedule: { interval_ms: 25 },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
        {
          condition: { output_quiet_ms: 50 },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
        {
          condition: { custom_probe: { command: probe, cwd: home } },
          check_schedule: { interval_ms: 25 },
          notify_schedule: { on_match: {} },
          lifetime: { until_match: {} },
        },
      ],
    },
  );
  const sessionId = (success(started, "start").session as { session_id: string }).session_id;

  const broadened = await requestAction(
    connected.client,
    connected.revision!,
    216,
    "monitor",
    {
      session_id: sessionId,
      operation: {
        update: {
          monitor_id: "monitor-5",
          definition: {
            condition: { custom_probe: { command: "true", cwd: home } },
            check_schedule: { interval_ms: 25 },
            notify_schedule: { on_match: {} },
            lifetime: { until_match: {} },
          },
        },
      },
    },
  );
  expect(failure(broadened).code).toBe("authority_denied");

  connected.client.close();
  writeFileSync(watched, "ready");
  writeFileSync(probeMarker, "ready");
  await Bun.sleep(250);
  connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  let inspectValue: { events: Array<{ monitor_id: string }> } = { events: [] };
  let correlation = 217;
  await waitFor(async () => {
    inspectValue = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as typeof inspectValue;
    return new Set(inspectValue.events.map((event) => event.monitor_id)).size === 5;
  }, 5_000);
  expect(new Set(inspectValue.events.map((event) => event.monitor_id))).toEqual(
    new Set(["monitor-1", "monitor-2", "monitor-3", "monitor-4", "monitor-5"]),
  );
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { session: { active_monitor_count: number } };
  expect(inspected.session.active_monitor_count).toBe(0);
  await requestAction(connected.client, connected.revision!, correlation++, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, 20_000);

test("TCP and HTTP readiness use bounded local polling fixtures", async () => {
  let requestedPath = "";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request) => {
      requestedPath = new URL(request.url).pathname + new URL(request.url).search;
      return new Response("ready");
    },
  });
  try {
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 10_000);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const started = await requestAction(
      connected.client,
      connected.revision!,
      230,
      "start",
      {
        cwd: home,
        command: "sleep 30",
        shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
        backend: "native",
        return_when: { started: {} },
        wait_ceiling_ms: 5_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [
          {
            condition: { tcp_ready: { host: "127.0.0.1", port: server.port } },
            check_schedule: { interval_ms: 25 },
            notify_schedule: { on_match: {} },
            lifetime: { until_match: {} },
          },
          {
            condition: { http_ready: `http://127.0.0.1:${server.port}/ready?probe=1` },
            check_schedule: { interval_ms: 25 },
            notify_schedule: { on_match: {} },
            lifetime: { until_match: {} },
          },
        ],
      },
    );
    const sessionId = (success(started, "start").session as { session_id: string }).session_id;
    let events: Array<{ monitor_id: string }> = [];
    let correlation = 231;
    await waitFor(async () => {
      const inspected = success(await requestAction(
        connected.client,
        connected.revision!,
        correlation++,
        "inspect",
        { session_id: sessionId },
      ), "inspect") as { events: typeof events };
      events = inspected.events;
      return events.length === 2;
    }, 5_000);
    expect(events.map((event) => event.monitor_id).sort()).toEqual([
      "monitor-1",
      "monitor-2",
    ]);
    expect(requestedPath).toBe("/ready?probe=1");
    await requestAction(connected.client, connected.revision!, correlation++, "close", {
      session_id: sessionId,
      policy: "force",
    });
    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  } finally {
    server.stop(true);
  }
}, 20_000);

test("closing a start-ceiling session releases initial monitor ownership", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 300, {
    FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS: "1000",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = success(await requestAction(
    connected.client,
    connected.revision!,
    240,
    "start",
    {
      cwd: home,
      command: "sleep 30",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 25,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [{
        condition: { output_contains: "never-produced" },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      }],
    },
  ), "start") as {
    session: {
      session_id: string;
      lifecycle: string;
      active_monitor_count: number;
    };
    outcome: unknown;
  };
  expect(started.session).toMatchObject({
    lifecycle: "starting",
    active_monitor_count: 1,
  });
  expect(started.outcome).toEqual({ safety_ceiling: {} });

  const closed = success(await requestAction(
    connected.client,
    connected.revision!,
    241,
    "close",
    { session_id: started.session.session_id, policy: "force" },
  ), "close");
  expect(closed.session).toMatchObject({
    lifecycle: "closed",
    active_monitor_count: 0,
  });
  connected.client.close();
  await waitFor(() => !existsSync(paths.identity), 2_000);
  expect(await waitForExit(host)).toBe(0);
}, 10_000);

test("custom probes bound failures output timeout and close cleanup", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const probePidPath = join(home, "probe.pid");
  const host = startHost(home, undefined, 500);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await requestAction(connected.client, connected.revision!, 240, "start", {
    cwd: home,
    command: "sleep 30",
    shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    backend: "native",
    return_when: { started: {} },
    wait_ceiling_ms: 5_000,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: [
      {
        condition: {
          custom_probe: {
            command: "yes x | head -c 65536",
            cwd: home,
          },
        },
        check_schedule: { interval_ms: 10 },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      },
      {
        condition: { custom_probe: { command: "exit 7", cwd: home } },
        check_schedule: { interval_ms: 10 },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      },
      {
        condition: {
          custom_probe: {
            command: `printf '%s' "$$" > '${probePidPath}'; sleep 20`,
            cwd: home,
          },
        },
        check_schedule: { interval_ms: 10 },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      },
    ],
  });
  const sessionId = (success(started, "start").session as { session_id: string }).session_id;
  await waitFor(() => existsSync(probePidPath), 8_000);
  const probePid = Number(readFileSync(probePidPath, "utf8"));
  expect(processExists(probePid)).toBe(true);
  const beforeClose = success(await requestAction(
    connected.client,
    connected.revision!,
    241,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    session: { active_monitor_count: number };
    events: Array<{ monitor_id: string }>;
  };
  expect(beforeClose.session.active_monitor_count).toBe(3);
  expect(beforeClose.events).toEqual([]);
  const closeStartedAt = Date.now();
  const closed = success(await requestAction(
    connected.client,
    connected.revision!,
    242,
    "close",
    { session_id: sessionId, policy: "force" },
  ), "close");
  expect(closed.session).toMatchObject({ lifecycle: "closed" });
  expect(Date.now() - closeStartedAt).toBeLessThan(5_500);
  await waitFor(() => !processExists(probePid), 5_000);
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, 30_000);

test("slow custom probe does not block output monitoring or inspect replies", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const probeStarted = join(home, "slow-probe-started");
  const host = startHost(home, undefined, 300);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    connected.client,
    connected.revision!,
    245_000,
    {
      cwd: home,
      command: "printf slow-probe-fixture-ready; while IFS= read -r _; do :; done",
      marker: "slow-probe-fixture-ready",
      dimensions: { rows: 24, columns: 80 },
      initialMonitors: [
        {
          condition: {
            custom_probe: {
              command: `: > '${probeStarted}'; sleep 1.5; false`,
              cwd: home,
            },
          },
          check_schedule: { interval_ms: 10 },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { output_contains: "fast-ready" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
        {
          condition: { screen_matches: "*fast-ready*" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        },
      ],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  await waitFor(() => existsSync(probeStarted), 3_000);
  const startedAt = Date.now();
  success(await requestAction(connected.client, connected.revision!, 246, "write", {
    session_id: sessionId,
    payload: { text: "printf 'fast-ready\\n'\n" },
  }), "write");
  let events: Array<{ monitor_id: string }> = [];
  let correlation = 247;
  await waitFor(async () => {
    const inspected = success(await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as { events: typeof events };
    events = inspected.events;
    const monitorIds = new Set(events.map((event) => event.monitor_id));
    return monitorIds.has("monitor-2") && monitorIds.has("monitor-3");
  }, 1_000);
  expect(Date.now() - startedAt).toBeLessThan(1_000);
  await requestAction(connected.client, connected.revision!, correlation++, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test.skipIf(!tmuxAvailable())("simultaneous notifications compose with ordered acknowledgement and mutation", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const barrier = join(home, "monitor-event-order");
  const gate = join(home, "monitor-event-gate");
  const host = startHost(home, undefined, 300, {
    FX_TERMINAL_TEST_ORDER_BARRIER: barrier,
    FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION: "248",
  });
  await waitFor(() => existsSync(paths.socket));
  const control = await handshake(paths.socket, { minimum: 4, current: 5 });
  const mutation = await handshake(paths.socket, { minimum: 4, current: 5 });
  const definition = {
    condition: { path_exists: gate },
    check_schedule: { interval_ms: 25 },
    notify_schedule: { on_match: {} },
    lifetime: { until_session_end: {} },
  };
  const started = await startCommand(control.client, control.revision!, 244, {
    cwd: home,
    command: "sleep 30",
    shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    backend: "tmux",
    initialMonitors: [
      definition,
      definition,
      {
        condition: { output_contains: "never" },
        notify_schedule: { on_state_change: {} },
        lifetime: { until_session_end: {} },
      },
    ],
  });
  const sessionId = (started.session as { session_id: string }).session_id;
  success(await requestAction(
    control.client,
    control.revision!,
    245,
    "monitor",
    { session_id: sessionId, operation: { pause: "monitor-3" } },
  ), "monitor");
  const before = success(await requestAction(
    control.client,
    control.revision!,
    246,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    events: Array<{ event_id: number; monitor_id: string; reason: string }>;
  };
  const acknowledgedThrough = before.events.at(-1)?.event_id;
  expect(acknowledgedThrough).toBeDefined();

  control.client.send(encodeFrame(
    control.revision!,
    1,
    actionSubjects.inspect,
    248,
    { request: { inspect: withAuthority("inspect", {
      session_id: sessionId,
      after_event_id: acknowledgedThrough,
      acknowledge_event_id: acknowledgedThrough,
    }) } },
    1,
  ));
  await waitFor(() => existsSync(`${barrier}.248.ready`));
  mutation.client.send(encodeFrame(
    mutation.revision!,
    1,
    actionSubjects.monitor,
    249,
    { request: { monitor: withAuthority("monitor", {
      session_id: sessionId,
      operation: { resume: "monitor-3" },
    }) } },
    1,
  ));
  await waitFor(() => existsSync(`${barrier}.249.admitted`));

  writeFileSync(gate, "ready");
  await waitFor(
    () => durableEventIds(home, sessionId).filter(
      (eventId) => eventId > acknowledgedThrough!,
    ).length >= 2,
    5_000,
  );
  writeFileSync(`${barrier}.248.release`, "release");
  success(await control.client.read(), "inspect");
  success(await mutation.client.read(), "monitor");

  const after = success(await requestAction(
    control.client,
    control.revision!,
    250,
    "inspect",
    { session_id: sessionId, after_event_id: acknowledgedThrough },
  ), "inspect") as {
    monitors: Array<{ monitor_id: string; state: string }>;
    events: Array<{ event_id: number; monitor_id: string; reason: string }>;
  };
  expect(after.events).toHaveLength(3);
  expect(after.events.map((event) => event.event_id)).toEqual(
    [...after.events.map((event) => event.event_id)].sort(
      (left, right) => left - right,
    ),
  );
  expect(new Set(after.events.map((event) => event.event_id)).size).toBe(3);
  expect(after.events.slice(0, 2).map((event) => event.reason)).toEqual([
    "matched",
    "matched",
  ]);
  expect(after.events[2]).toMatchObject({
    monitor_id: "monitor-3",
    reason: "resumed",
  });
  expect(after.monitors).toContainEqual({
    monitor_id: "monitor-3",
    state: "active",
  });
  const eventIds = after.events.map((event) => event.event_id);
  const monitorFile = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
    `monitors-${sessionId}.json`,
  );
  const checkCounts = () => {
    const persisted = JSON.parse(readFileSync(monitorFile, "utf8")) as {
      monitors: Array<{
        monitor_id: string;
        runtime: { check_count: number };
      }>;
    };
    return new Map(
      persisted.monitors.map((monitor) => [
        monitor.monitor_id,
        monitor.runtime.check_count,
      ]),
    );
  };
  const beforeRecovery = checkCounts();
  const oldIdentity = readFileSync(paths.identity, "utf8");
  control.client.close();
  mutation.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);

  const replacement = startHost(home, undefined, 300);
  await waitFor(() =>
    existsSync(paths.socket) && existsSync(paths.identity) &&
    readFileSync(paths.identity, "utf8") !== oldIdentity
  );
  const reopened = await handshake(paths.socket, { minimum: 4, current: 5 });
  const replayed = success(await requestAction(
    reopened.client,
    reopened.revision!,
    251,
    "inspect",
    { session_id: sessionId, after_event_id: acknowledgedThrough },
  ), "inspect") as {
    events: Array<{ event_id: number }>;
  };
  expect(replayed.events.map((event) => event.event_id)).toEqual(eventIds);
  const afterRecovery = checkCounts();
  for (const monitorId of ["monitor-1", "monitor-2"]) {
    expect(afterRecovery.get(monitorId)).toBeGreaterThanOrEqual(
      beforeRecovery.get(monitorId)!,
    );
  }

  await forceCloseTerminalFixture(
    reopened.client,
    reopened.revision!,
    252,
    sessionId,
  );
  reopened.client.close();
  expect(await waitForExit(replacement)).toBe(0);
}, 20_000);

test("private monitor add update pause resume and remove preserve stable IDs", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeShellFixture(
    connected.client,
    connected.revision!,
    250_000,
    {
      cwd: home,
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const firstDefinition = {
    condition: { path_exists: join(home, "later") },
    check_schedule: { interval_ms: 25 },
    notify_schedule: { on_match: {} },
    lifetime: { until_session_end: {} },
  };
  const added = success(await requestAction(
    connected.client,
    connected.revision!,
    251,
    "monitor",
    { session_id: sessionId, operation: { add: firstDefinition } },
  ), "monitor");
  expect(added.monitor_id).toBe("monitor-1");

  await requestAction(connected.client, connected.revision!, 252, "monitor", {
    session_id: sessionId,
    operation: { pause: "monitor-1" },
  });
  let inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    253,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { monitors: Array<{ monitor_id: string; state: string }> };
  expect(inspected.monitors).toEqual([{ monitor_id: "monitor-1", state: "paused" }]);

  await requestAction(connected.client, connected.revision!, 254, "monitor", {
    session_id: sessionId,
    operation: { resume: "monitor-1" },
  });
  const updated = success(await requestAction(
    connected.client,
    connected.revision!,
    255,
    "monitor",
    {
      session_id: sessionId,
      operation: {
        update: {
          monitor_id: "monitor-1",
          definition: {
            condition: { output_contains: "never" },
            notify_schedule: { on_state_change: {} },
            lifetime: { until_session_end: {} },
          },
        },
      },
    },
  ), "monitor");
  expect(updated.monitor_id).toBe("monitor-1");
  inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    256,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as typeof inspected;
  expect(inspected.monitors).toEqual([{ monitor_id: "monitor-1", state: "active" }]);

  await requestAction(connected.client, connected.revision!, 257, "monitor", {
    session_id: sessionId,
    operation: { remove: "monitor-1" },
  });
  inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    258,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as typeof inspected;
  expect(inspected.monitors).toEqual([]);
  const second = success(await requestAction(
    connected.client,
    connected.revision!,
    259,
    "monitor",
    { session_id: sessionId, operation: { add: firstDefinition } },
  ), "monitor");
  expect(second.monitor_id).toBe("monitor-2");
  await requestAction(connected.client, connected.revision!, 260, "monitor", {
    session_id: sessionId,
    operation: { remove: "monitor-2" },
  });
  await requestAction(connected.client, connected.revision!, 261, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 30_000);

const monitorOperationFailureCases = (
  ["add", "update", "pause", "resume", "remove"] as const
).flatMap((operation) => (
  ["allocation", "arming", "persistence"] as const
).map((boundary) => ({ operation, boundary })));

test.each(monitorOperationFailureCases)(
  "monitor $operation is failure-atomic at $boundary",
  async ({ operation, boundary }) => {
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 300, {
      FX_TERMINAL_TEST_FAIL_MONITOR_OPERATION: `${operation}:${boundary}`,
    });
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    const originalDefinition = {
      condition: { output_contains: "original-never" },
      notify_schedule: { on_state_change: {} },
      lifetime: { until_session_end: {} },
    };
    const started = await requestAction(
      connected.client,
      connected.revision!,
      262,
      "start",
      {
        cwd: home,
        command: "sleep 30",
        shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
        backend: "native",
        return_when: { started: {} },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: operation === "add" ? [] : [originalDefinition],
      },
    );
    const sessionId = (
      success(started, "start").session as { session_id: string }
    ).session_id;
    if (operation === "resume") {
      success(await requestAction(
        connected.client,
        connected.revision!,
        263,
        "monitor",
        { session_id: sessionId, operation: { pause: "monitor-1" } },
      ), "monitor");
    }
    const before = success(await requestAction(
      connected.client,
      connected.revision!,
      264,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as {
      session: { active_monitor_count: number };
      monitors: unknown[];
      events: unknown[];
    };
    const failedOperation = operation === "add"
      ? { add: originalDefinition }
      : operation === "update"
      ? {
        update: {
          monitor_id: "monitor-1",
          definition: {
            condition: { output_contains: "replacement-never" },
            notify_schedule: { on_state_change: {} },
            lifetime: { until_session_end: {} },
          },
        },
      }
      : { [operation]: "monitor-1" };
    const failureFrame = await requestAction(
      connected.client,
      connected.revision!,
      265,
      "monitor",
      { session_id: sessionId, operation: failedOperation },
    );
    expect(failure(failureFrame)).toMatchObject({
      action: "monitor",
      code: "invalid_request",
    });
    const after = success(await requestAction(
      connected.client,
      connected.revision!,
      266,
      "inspect",
      { session_id: sessionId },
    ), "inspect") as typeof before;
    expect(after.session.active_monitor_count).toBe(
      before.session.active_monitor_count,
    );
    expect(after.monitors).toEqual(before.monitors);
    expect(after.events).toEqual(before.events);
    await requestAction(connected.client, connected.revision!, 267, "close", {
      session_id: sessionId,
      policy: "force",
    });
    connected.client.close();
    expect(await waitForExit(host)).toBe(0);
  },
  30_000,
);

test("monitor byte ceiling rejects sequential add and update without changing state", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 5_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const largeCommand = "x".repeat(64 * 1024);
  const largeDefinition = {
    condition: { custom_probe: { command: largeCommand, cwd: home } },
    check_schedule: { interval_ms: 24 * 60 * 60 * 1_000 },
    notify_schedule: { on_match: {} },
    lifetime: { until_session_end: {} },
  };
  const smallDefinition = {
    condition: { custom_probe: { command: "false", cwd: home } },
    check_schedule: { interval_ms: 24 * 60 * 60 * 1_000 },
    notify_schedule: { on_match: {} },
    lifetime: { until_session_end: {} },
  };
  const started = await requestAction(
    connected.client,
    connected.revision!,
    274,
    "start",
    {
      cwd: home,
      command: "sleep 30",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [smallDefinition, largeDefinition],
    },
  );
  const sessionId = (
    success(started, "start").session as { session_id: string }
  ).session_id;
  let correlation = 275;
  let rejectedAdd: WireFrame | undefined;
  for (let count = 0; count < 30; count++) {
    const response = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "monitor",
      { session_id: sessionId, operation: { add: largeDefinition } },
    );
    if (failureCode(response) === "capacity_exceeded") {
      rejectedAdd = response;
      break;
    }
    success(response, "monitor");
  }
  expect(rejectedAdd).toBeDefined();
  expect(failure(rejectedAdd!)).toMatchObject({
    action: "monitor",
    code: "capacity_exceeded",
  });
  const beforeUpdate = success(await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "inspect",
    { session_id: sessionId },
  ), "inspect");
  const rejectedUpdate = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "monitor",
    {
      session_id: sessionId,
      operation: {
        update: { monitor_id: "monitor-1", definition: largeDefinition },
      },
    },
  );
  expect(failure(rejectedUpdate)).toMatchObject({
    action: "monitor",
    code: "capacity_exceeded",
  });
  const afterUpdate = success(await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "inspect",
    { session_id: sessionId },
  ), "inspect");
  expect(afterUpdate).toEqual(beforeUpdate);
  await requestAction(connected.client, connected.revision!, correlation++, "close", {
    session_id: sessionId,
    policy: "force",
  });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, 30_000);

test("failed first monitor arming leaves the host idle-owned", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 250, {
    FX_TERMINAL_TEST_FAIL_MONITOR_OPERATION: "add:arming",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    connected.client,
    connected.revision!,
    268_000,
    {
      cwd: home,
      command: "printf arming-fixture-ready; IFS= read -r _; exit 0",
      marker: "arming-fixture-ready",
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const failed = await requestAction(connected.client, connected.revision!, 269, "monitor", {
    session_id: sessionId,
    operation: {
      add: {
        condition: { output_contains: "never" },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      },
    },
  });
  expect(failure(failed)).toMatchObject({
    action: "monitor",
    code: "invalid_request",
  });
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    270,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    session: { active_monitor_count: number };
    monitors: unknown[];
    events: unknown[];
  };
  expect(inspected.session.active_monitor_count).toBe(0);
  expect(inspected.monitors).toEqual([]);
  expect(inspected.events).toEqual([]);
  success(await requestAction(connected.client, connected.revision!, 271, "write", {
    session_id: sessionId,
    payload: { text: "\n" },
  }), "write");
  const exited = success(await requestAction(
    connected.client,
    connected.revision!,
    272,
    "wait",
    {
      session_id: sessionId,
      return_when: { exit: {} },
      safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    },
  ), "wait");
  expect(exited.outcome).toEqual({ exited: 0 });
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("exact signal monitor reports the shell termination once", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 5_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startInteractiveNativeFixture(
    connected.client,
    connected.revision!,
    260_000,
    {
      cwd: home,
      command: "printf signal-fixture-ready; IFS= read -r _",
      marker: "signal-fixture-ready",
      dimensions: { rows: 24, columns: 80 },
      initialMonitors: [{
        condition: { signal: "kill" },
        notify_schedule: { on_match: {} },
        lifetime: { until_session_end: {} },
      }],
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  await requestAction(connected.client, connected.revision!, 261, "signal", {
    session_id: sessionId,
    signal: "kill",
  });
  const waited = success(await requestAction(
    connected.client,
    connected.revision!,
    262,
    "wait",
    {
      session_id: sessionId,
      return_when: { exit: {} },
      safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    },
  ), "wait");
  expect(waited.outcome).toEqual({ signal: 9 });
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    263,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as { events: Array<{ monitor_id: string; reason: string }> };
  expect(inspected.events).toEqual([{
    monitor_id: "monitor-1",
    reason: "matched",
    event_id: expect.any(Number),
    lifecycle: "exited",
    cursor: expect.any(Object),
    created_at_ms: expect.any(Number),
  }]);
  connected.client.close();
  expect(await waitForExit(host)).toBe(0);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("host restart finalizes monitor ownership and queues on-exit delivery", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const firstHost = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  let connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await requestAction(connected.client, connected.revision!, 270, "start", {
    cwd: home,
    command: "sleep 30",
    shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
    backend: "native",
    return_when: { started: {} },
    wait_ceiling_ms: 5_000,
    dimensions: { rows: 24, columns: 80 },
    initial_monitors: [{
      condition: { path_exists: join(home, "never-created") },
      check_schedule: { interval_ms: 25 },
      notify_schedule: { on_exit: {} },
      lifetime: { until_session_end: {} },
    }],
  });
  const sessionId = (success(started, "start").session as { session_id: string }).session_id;
  const firstIdentity = readFileSync(paths.identity, "utf8");
  connected.client.close();
  firstHost.kill("SIGKILL");
  await waitForExit(firstHost);

  const replacement = startHost(home, undefined, 1_000);
  await waitFor(() =>
    existsSync(paths.socket) &&
    existsSync(paths.identity) &&
    readFileSync(paths.identity, "utf8") !== firstIdentity
  );
  connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspected = success(await requestAction(
    connected.client,
    connected.revision!,
    271,
    "inspect",
    { session_id: sessionId },
  ), "inspect") as {
    session: { lifecycle: string; active_monitor_count: number };
    monitors: unknown[];
    events: Array<{ monitor_id: string; reason: string }>;
  };
  expect(inspected.session).toMatchObject({
    lifecycle: "lost",
    active_monitor_count: 0,
  });
  expect(inspected.monitors).toEqual([]);
  expect(inspected.events).toEqual([{
    monitor_id: "monitor-1",
    reason: "session_exit",
    event_id: expect.any(Number),
    lifecycle: "lost",
    cursor: expect.any(Object),
    created_at_ms: expect.any(Number),
  }]);
  connected.client.close();
  expect(await waitForExit(replacement)).toBe(0);
}, 20_000);

test("revoke and close quiesce writes already queued under stale authority", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const writeBarrier = join(home, "write-barrier");
  const host = startHost(home, undefined, 10_000, {
    FX_TERMINAL_TEST_WRITE_DELAY_MS: "180",
    FX_TERMINAL_TEST_WRITE_BARRIER_PATH: writeBarrier,
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  let correlation = 220;

  async function startMarkerSession(prefix: string): Promise<string> {
    const fixtureCorrelation = correlation;
    correlation += 4;
    const started = await startInteractiveNativeFixture(
      connected.client,
      connected.revision!,
      fixtureCorrelation,
      {
        cwd: home,
        command:
          `printf '${prefix}-fixture-ready'; ` +
          `while IFS= read -r line; do ` +
          `[ \"$line\" = allowed ] && : > '${join(home, `${prefix}-allowed`)}'; ` +
          `[ \"$line\" = stale ] && : > '${join(home, `${prefix}-stale`)}'; done`,
        marker: `${prefix}-fixture-ready`,
      },
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    const acquired = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "write",
      { session_id: sessionId, lease: "acquire" },
    );
    expect(success(acquired, "write").accepted_bytes).toBe(0);
    return sessionId;
  }

  const revokedId = await startMarkerSession("revoke");
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.write,
    correlation++,
    { request: { write: withAuthority("write", {
      session_id: revokedId,
      payload: { text: "allowed\n" },
      lease: "use",
    }) } },
    1,
  ));
  await waitFor(() => existsSync(writeBarrier));
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.write,
    correlation++,
    { request: { write: withAuthority("write", {
      session_id: revokedId,
      lease: "revoke",
    }) } },
    1,
  ));
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.write,
    correlation++,
    { request: { write: withAuthority("write", {
      session_id: revokedId,
      payload: { text: "stale\n" },
      lease: "use",
    }) } },
    1,
  ));
  const revokeResponses = [
    await connected.client.read(),
    await connected.client.read(),
    await connected.client.read(),
  ];
  expect(revokeResponses.filter((frame) => {
    const response = (frame.payload as { response?: { success?: { write?: { accepted_bytes: number } } } }).response;
    return (response?.success?.write?.accepted_bytes ?? 0) > 0;
  })).toHaveLength(1);
  expect(revokeResponses.some((frame) => {
    const response = (frame.payload as { response?: { success?: { write?: { accepted_bytes: number } } } }).response;
    return response?.success?.write?.accepted_bytes === 0;
  })).toBe(true);
  expect(revokeResponses.some((frame) => failureCode(frame) === "authority_denied")).toBe(true);
  await waitFor(() => existsSync(join(home, "revoke-allowed")));
  await Bun.sleep(75);
  expect(existsSync(join(home, "revoke-stale"))).toBe(false);

  const closedId = await startMarkerSession("close");
  rmSync(writeBarrier, { force: true });
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.write,
    correlation++,
    { request: { write: withAuthority("write", {
      session_id: closedId,
      payload: { text: "allowed\n" },
      lease: "use",
    }) } },
    1,
  ));
  await waitFor(() => existsSync(writeBarrier));
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.close,
    correlation++,
    { request: { close: withAuthority("close", {
      session_id: closedId,
      policy: "force",
    }) } },
    1,
  ));
  connected.client.send(encodeFrame(
    connected.revision!,
    1,
    actionSubjects.write,
    correlation++,
    { request: { write: withAuthority("write", {
      session_id: closedId,
      payload: { text: "stale\n" },
      lease: "use",
    }) } },
    1,
  ));
  const closeResponses = [
    await connected.client.read(),
    await connected.client.read(),
    await connected.client.read(),
  ];
  const closeFrame = closeResponses.find((frame) => frame.subject === actionSubjects.close)!;
  expect(success(closeFrame, "close").session).toMatchObject({ lifecycle: "closed" });
  const staleFrame = closeResponses.find((frame) =>
    frame.subject === actionSubjects.write && failureCode(frame) === "authority_denied"
  );
  expect(staleFrame).toBeDefined();
  await waitFor(() => existsSync(join(home, "close-allowed")));
  await Bun.sleep(75);
  expect(existsSync(join(home, "close-stale"))).toBe(false);

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 12 + 30_000);

test("private screen snapshots and native cursor replies use the real PTY", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

  const started = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    150_000,
    {
      cwd: home,
      command: "stty raw -echo; printf '\\033[6n'; IFS= read -r -d R reply; stty sane; IFS= read -r line; printf 'reply:%sR input:%s\\n' \"$reply\" \"$line\"",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      returnWhen: { started: {} },
      waitMs: 5_000,
      dimensions: { rows: 9, columns: 37 },
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  let correlation = 151;
  await waitFor(async () => {
    const page = await readSession(
      connected.client,
      connected.revision!,
      correlation++,
      sessionId,
    );
    return page.output.includes("\u001b[6n");
  });
  const write = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "write",
    { session_id: sessionId, payload: { text: "later\n" } },
  );
  expect(success(write, "write").accepted_bytes).toBe(6);
  const waited = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "wait",
    {
      session_id: sessionId,
      return_when: { exit: {} },
      safety_ceiling_ms: 5_000,
    },
  );
  expect(success(waited, "wait").outcome).toEqual({ exited: 0 });
  const raw = await readSession(
    connected.client,
    connected.revision!,
    correlation++,
    sessionId,
  );
  expect(raw.output).toMatch(/reply:\u001b\[[0-9]+;[0-9]+R input:later/);

  const screenFrame = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "screen",
    { session_id: sessionId },
  );
  const screen = success(screenFrame, "screen") as {
    snapshot: {
      dimensions: { rows: number; columns: number };
      cells: Array<{ kind: string; text: string }>;
    };
  };
  expect(screen.snapshot.dimensions).toEqual({ rows: 9, columns: 37 });
  expect(screen.snapshot.cells).toHaveLength(9 * 37);
  expect(screen.snapshot.cells.map((cell) => cell.text).join(""))
    .toContain("reply:");
  for (let index = 0; index < screen.snapshot.cells.length; index += 1) {
    const cell = screen.snapshot.cells[index]!;
    if (cell.kind === "wide") {
      expect(screen.snapshot.cells[index + 1]?.kind).toBe("continuation");
    }
    if (cell.kind === "continuation") {
      expect(screen.snapshot.cells[index - 1]?.kind).toBe("wide");
    }
  }

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000);

test("resized screen checkpoint survives a fresh host without raw reflow", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const oldIdentity = readFileSync(paths.identity, "utf8");
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

  const started = await startCommand(
    connected.client,
    connected.revision!,
    170,
    {
      cwd: home,
      command: "printf abcdef; exec /bin/sh -c 'while :; do sleep 30; done'",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      returnWhen: { match: "abcdef" },
      waitMs: 5_000,
      dimensions: { rows: 2, columns: 4 },
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const resized = await requestAction(
    connected.client,
    connected.revision!,
    171,
    "resize",
    {
      session_id: sessionId,
      dimensions: { rows: 2, columns: 6 },
    },
  );
  expect(success(resized, "resize").dimensions).toEqual({
    rows: 2,
    columns: 6,
  });

  const snapshotRows = (value: unknown): string[] => {
    const snapshot = (value as {
      snapshot: {
        dimensions: { rows: number; columns: number };
        cells: Array<{ kind: string; text: string }>;
      };
    }).snapshot;
    return Array.from({ length: snapshot.dimensions.rows }, (_, row) =>
      snapshot.cells
        .slice(
          row * snapshot.dimensions.columns,
          (row + 1) * snapshot.dimensions.columns,
        )
        .map((cell) => cell.kind === "blank" ? " " : cell.text)
        .join("")
        .trimEnd(),
    );
  };
  const liveScreen = success(
    await requestAction(
      connected.client,
      connected.revision!,
      172,
      "screen",
      { session_id: sessionId },
    ),
    "screen",
  );
  expect(snapshotRows(liveScreen)).toEqual(["abcd", "ef"]);

  host.kill("SIGKILL");
  await waitForExit(host);
  connected.client.close();
  const replacement = startHost(home, undefined, 300);
  await waitFor(
    () =>
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    3_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  const durableScreen = success(
    await requestAction(
      recovered.client,
      recovered.revision!,
      173,
      "screen",
      { session_id: sessionId },
    ),
    "screen",
  );
  expect(snapshotRows(durableScreen)).toEqual(["abcd", "ef"]);
  recovered.client.close();
  expect(await waitForExit(replacement)).toBe(0);
}, 15_000);

test.skipIf(!tmuxAvailable())("private screen text grid matches an actual tmux capture", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const fixture = join(home, "screen-fixture.zsh");
  writeFileSync(
    fixture,
    [
      "printf '\\033[2J\\033[H'",
      "printf '\\033[1;34mfx-grid\\033[0m'",
      "printf '\\033[3;1Hwide: 界 + é'",
      "printf '\\033[5;1Habcdef'",
      "printf '\\033[2D\\033[P'",
      "printf '\\033[7;4Htab\\tstop'",
      "printf '\\033[9;1Hready'",
      "IFS= read -r _",
    ].join("\n"),
  );

  const tmux = await TmuxSession.create({
    cmd: "/bin/zsh -f ./screen-fixture.zsh",
    cwd: home,
    width: 40,
    height: 10,
  });
  try {
    await tmux.waitForText("ready", 5_000);
    const tmuxGrid = (await tmux.capturePaneGrid()).map((row) =>
      row.replaceAll("\t", "  ").trimEnd()
    );

    const paths = hostPaths(home);
    const host = startHost(home, undefined, 10_000);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    let correlation = 175;
    const started = await startNativeCommandFixture(
      connected.client,
      connected.revision!,
      175_000,
      {
        cwd: home,
        command: "exec /bin/zsh -f ./screen-fixture.zsh",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        returnWhen: { started: {} },
        dimensions: { rows: 10, columns: 40 },
      },
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    await waitFor(async () => {
      const page = await readSession(
        connected.client,
        connected.revision!,
        correlation++,
        sessionId,
      );
      return page.output.includes("ready");
    });

    const screen = success(
      await requestAction(
        connected.client,
        connected.revision!,
        correlation++,
        "screen",
        { session_id: sessionId },
      ),
      "screen",
    ) as {
      snapshot: {
        dimensions: { rows: number; columns: number };
        cursor: { row: number; column: number };
        cells: Array<{ kind: string; text: string }>;
      };
    };
    const nativeGrid = Array.from(
      { length: screen.snapshot.dimensions.rows },
      (_, row) => screen.snapshot.cells
        .slice(row * screen.snapshot.dimensions.columns, (row + 1) * screen.snapshot.dimensions.columns)
        .map((cell) => cell.kind === "blank" ? " " : cell.text)
        .join("")
        .trimEnd(),
    );

    expect(screen.snapshot.dimensions).toEqual({ rows: 10, columns: 40 });
    expect(nativeGrid).toEqual(tmuxGrid);
    const tmuxCursor = tmux.cursorPosition();
    expect(screen.snapshot.cursor).toMatchObject({
      row: tmuxCursor.row,
      column: tmuxCursor.col,
    });

    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "close",
      { session_id: sessionId, policy: "force" },
    );
    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  } finally {
    await tmux.kill();
  }
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 30_000);

test("Bash and zsh preserve trusted normal startup and controlled clean startup", async () => {
  const home = makeHome();
  if (existsSync("/bin/zsh")) isolateZshStartupFixture(home);
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000, {
    FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS: "2500",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  let correlation = 200;

  const shells = [
    {
      name: "bash",
      path: "/bin/bash",
      profile: ".bash_profile",
      hostileProfile: ".bash_profile",
      marker: "bash-profile",
    },
    {
      name: "zsh",
      path: "/bin/zsh",
      profile: ".zprofile",
      hostileProfile: ".zlogin",
      marker: "zsh-profile",
    },
  ].filter((shell) => existsSync(shell.path));
  expect(shells.length).toBeGreaterThan(0);

  for (const shell of shells) {
    const profileReady = join(home, `${shell.name}-profile-ready`);
    const commandRan = join(home, `${shell.name}-command-ran`);
    const boundaryMatch = `${shell.name}-boundary-match`;
    writeFileSync(
      join(home, shell.profile),
      [
        `printf '${shell.marker}\\n'`,
        `printf '${boundaryMatch}\\n'`,
        `: > '${profileReady}'`,
        `alias fx_profile_alias="printf '${shell.name}-alias\\\\n'"`,
        `fx_profile_function() { printf '${shell.name}-function\\\\n'; }`,
        "",
      ].join("\n"),
    );
    writeFileSync(
      join(home, shell.hostileProfile),
      "eval() { printf 'forged-eval\\n'; return 42; }\n",
      { flag: "a" },
    );
    const normalInitial = await startCommand(
      connected.client,
      connected.revision!,
      correlation++,
      {
        cwd: home,
        command: [
          "fx_profile_alias",
          "fx_profile_function",
          `printf '${shell.name}-command\\n'`,
          "(exit 19)",
        ].join("; "),
        shell: {
          executable: { path: shell.path, clean_start: false },
        },
        returnWhen: { exit: {} },
      },
    );
    const normal = await finishStartupObservation(
      connected.client,
      connected.revision!,
      correlation++,
      normalInitial,
      "native",
      { exit: {} },
      NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
    );
    expect(normal.outcome).toEqual({ exited: 19 });
    const normalSession = (normal.session as { session_id: string }).session_id;
    const normalRead = await readSession(
      connected.client,
      connected.revision!,
      correlation++,
      normalSession,
    );
    expect(normalRead.output).toContain(shell.marker);
    expect(normalRead.output).toContain(`${shell.name}-alias`);
    expect(normalRead.output).toContain(`${shell.name}-function`);
    expect(normalRead.output).toContain(`${shell.name}-command`);
    expect(normalRead.output).not.toContain("forged-eval");

    rmSync(profileReady, { force: true });
    rmSync(commandRan, { force: true });
    const boundaryStartedAt = Date.now();
    const boundaryCorrelation = correlation++;
    const boundaryRequest = withPersistence({
      cwd: home,
      command:
        `: > '${commandRan}'; sleep 0.15; ` +
        `printf '${boundaryMatch}\\n'; sleep 30`,
      shell: {
        executable: { path: shell.path, clean_start: false },
      },
      backend: "native",
      return_when: { match: boundaryMatch },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    });
    connected.client.send(
      encodeFrame(
        connected.revision!,
        1,
        actionSubjects.start,
        boundaryCorrelation,
        {
          request: {
            start: boundaryRequest,
          },
        },
        1,
      ),
    );
    await waitFor(() => existsSync(profileReady));
    await Bun.sleep(75);
    expect(existsSync(commandRan)).toBe(false);
    const boundaryFrame = await connected.client.read();
    rememberStartAuthority(boundaryFrame, boundaryRequest);
    expect(boundaryFrame.correlation).toBe(boundaryCorrelation);
    const boundary = await finishStartupObservation(
      connected.client,
      connected.revision!,
      correlation++,
      success(boundaryFrame, "start"),
      "native",
      { match: boundaryMatch },
      NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
    );
    expect(boundary.outcome).toEqual({ condition_met: {} });
    expect(Date.now() - boundaryStartedAt).toBeGreaterThanOrEqual(2600);
    expect(existsSync(commandRan)).toBe(true);
    const boundaryId = (boundary.session as { session_id: string }).session_id;
    const boundaryOutput = (
      await readSession(
        connected.client,
        connected.revision!,
        correlation++,
        boundaryId,
      )
    ).output;
    expect(boundaryOutput.match(new RegExp(boundaryMatch, "g"))?.length).toBe(2);
    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "close",
      { session_id: boundaryId, policy: "force" },
    );

    const cleanInitial = await startCommand(
      connected.client,
      connected.revision!,
      correlation++,
      {
        cwd: home,
        command:
          "alias fx_profile_alias >/dev/null 2>&1 && " +
          "printf 'alias-leaked\\n' || printf 'alias-absent\\n'; " +
          "type fx_profile_function >/dev/null 2>&1 && " +
          "printf 'function-leaked\\n' || printf 'function-absent\\n'; " +
          `printf '${shell.name}-clean\\n'; exit 0`,
        shell: {
          executable: { path: shell.path, clean_start: true },
        },
        returnWhen: { exit: {} },
      },
    );
    const clean = await finishStartupObservation(
      connected.client,
      connected.revision!,
      correlation++,
      cleanInitial,
      "native",
      { exit: {} },
      NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
    );
    expect(clean.outcome).toEqual({ exited: 0 });
    const cleanSession = (clean.session as { session_id: string }).session_id;
    const cleanRead = await readSession(
      connected.client,
      connected.revision!,
      correlation++,
      cleanSession,
    );
    expect(cleanRead.output).not.toContain(shell.marker);
    expect(cleanRead.output).toContain("alias-absent");
    expect(cleanRead.output).toContain("function-absent");
    expect(cleanRead.output).not.toContain("alias-leaked");
    expect(cleanRead.output).not.toContain("function-leaked");
    expect(cleanRead.output).toContain(`${shell.name}-clean`);
  }

  const configuredLogin = await startCommand(
    connected.client,
    connected.revision!,
    correlation++,
    {
      cwd: home,
      command: "printf configured-login; exit 0",
      shell: { user_login: {} },
      returnWhen: { exit: {} },
    },
  );
  expect(configuredLogin.outcome).toEqual({ exited: 0 });
  const configuredId = (
    configuredLogin.session as { session_id: string }
  ).session_id;
  expect(
    (
      await readSession(
        connected.client,
        connected.revision!,
        correlation++,
        configuredId,
      )
    ).output,
  ).toContain("configured-login");

  if (existsSync("/bin/zsh")) {
    writeFileSync(
      join(home, ".zprofile"),
      "sleep 0.2\n" +
        "fx_delayed_function() { printf 'delayed-function\\n'; }\n" +
        "printf 'delayed-profile\\n'\n",
    );
    const delayedAt = Date.now();
    const delayed = await startCommand(
      connected.client,
      connected.revision!,
      correlation++,
      {
        cwd: home,
        shell: {
          executable: { path: "/bin/zsh", clean_start: false },
        },
        returnWhen: { started: {} },
      },
    );
    expect(Date.now() - delayedAt).toBeGreaterThanOrEqual(150);
    const delayedId = (delayed.session as { session_id: string }).session_id;
    expect(
      (
        await readSession(
          connected.client,
          connected.revision!,
          correlation++,
          delayedId,
        )
      ).output,
    ).toContain("delayed-profile");
    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "write",
      {
        session_id: delayedId,
        payload: { text: "fx_delayed_function\r" },
      },
    );
    const delayedMatch = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "wait",
      {
        session_id: delayedId,
        return_when: { match: "delayed-function" },
        safety_ceiling_ms: 2_000,
      },
    );
    expect(success(delayedMatch, "wait").outcome).toEqual({
      condition_met: {},
    });
    await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "close",
      { session_id: delayedId, policy: "force" },
    );

    writeFileSync(
      join(home, ".zprofile"),
      "printf '\\001\\000\\000\\000\\000spoofed-ready\\n'; exit 41\n",
    );
    const failedStartup = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "start",
      {
        cwd: home,
        command: "exit 0",
        shell: {
          executable: { path: "/bin/zsh", clean_start: false },
        },
        backend: "native",
        return_when: { exit: {} },
        wait_ceiling_ms: 5_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    );
    expect(failure(failedStartup)).toMatchObject({
      action: "start",
      code: "startup_failed",
    });
    const failedId = (failure(failedStartup) as { session_id: string }).session_id;
    const failedRead = await readSession(
      connected.client,
      connected.revision!,
      correlation++,
      failedId,
    );
    expect(failedRead.output).toContain("spoofed-ready");

    const signaled = await startCommand(
      connected.client,
      connected.revision!,
      correlation++,
      {
        cwd: home,
        command: "exec /bin/sh -c 'kill -SEGV $$'",
        shell: {
          executable: { path: "/bin/zsh", clean_start: true },
        },
        returnWhen: { exit: {} },
      },
    );
    expect(signaled.outcome).toEqual({ signal: 11 });

    const forgedCompletion = await startNativeCommandFixture(
      connected.client,
      connected.revision!,
      correlation,
      {
        cwd: home,
        command:
          "printf '\\004\\000\\000\\000\\000spoofed-completion\\n'; exit 29",
        shell: {
          executable: { path: "/bin/zsh", clean_start: true },
        },
        returnWhen: { exit: {} },
        waitMs: 5_000,
      },
    );
    correlation += 6;
    expect(forgedCompletion.outcome).toEqual({ exited: 29 });
    const forgedId = (
      forgedCompletion.session as { session_id: string }
    ).session_id;
    expect(
      (
        await readSession(
          connected.client,
          connected.revision!,
          correlation++,
          forgedId,
        )
      ).output,
    ).toContain("spoofed-completion");
  }

  const missing = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "start",
    {
      cwd: home,
      shell: {
        executable: {
          path: "/definitely/missing/bash",
          clean_start: true,
        },
      },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 2_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  );
  expect(failure(missing)).toMatchObject({
    action: "start",
    code: "shell_unavailable",
  });

  const unsupported = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "start",
    {
      cwd: home,
      shell: {
        executable: { path: "/bin/fish", clean_start: true },
      },
      backend: "native",
      return_when: { started: {} },
      wait_ceiling_ms: 2_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  );
  expect(failure(unsupported)).toMatchObject({
    action: "start",
    code: "invalid_request",
  });

  const loginProfile = loginShellProfile();
  if (loginProfile !== null) {
    writeFileSync(join(home, loginProfile), "exit 41\n");
    const tmux = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "start",
      {
        cwd: home,
        shell: { user_login: {} },
        backend: "tmux",
        return_when: { started: {} },
        wait_ceiling_ms: 2_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    );
    expect(failure(tmux)).toMatchObject({
      action: "start",
      code: "startup_failed",
    });
  }

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, SHELL_STARTUP_FIXTURE_TEST_TIMEOUT_MS + NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6);

test("writes resize waits cancellation signals and close remain session-scoped", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 200);
  await waitFor(() => existsSync(paths.socket));
  const control = await handshake(paths.socket, { minimum: 4, current: 5 });

  const started = await startNativeCommandFixture(
    control.client,
    control.revision!,
    300_000,
    {
      cwd: home,
      command:
        "exec /bin/sh -c 'trap \"printf term-trap; exit 37\" TERM; trap \"printf winch:; stty size\" WINCH; printf ready; while :; do read line; done'",
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      returnWhen: { match: "ready" },
      waitMs: 5_000,
      dimensions: { rows: 12, columns: 40 },
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  expect(started.outcome).toEqual({ condition_met: {} });
  await Bun.sleep(350);
  expect(existsSync(paths.socket)).toBe(true);
  expect(host.exitCode).toBeNull();

  const unrelated = await handshake(paths.socket, { minimum: 4, current: 5 });
  const ceiling = await requestAction(
    unrelated.client,
    unrelated.revision!,
    299,
    "wait",
    {
      session_id: sessionId,
      return_when: { match: "never-produced-terminal-marker" },
      safety_ceiling_ms: 25,
    },
  );
  expect(success(ceiling, "wait").outcome).toEqual({
    safety_ceiling: {},
  });
  control.client.send(
    encodeFrame(
      control.revision!,
      1,
      actionSubjects.wait,
      301,
      {
        request: {
          wait: withAuthority("wait", {
            session_id: sessionId,
            return_when: { quiet: 20_000 },
            safety_ceiling_ms: 25_000,
          }),
        },
      },
      1,
    ),
  );
  const inspected = await requestAction(
    unrelated.client,
    unrelated.revision!,
    302,
    "inspect",
    { session_id: sessionId },
  );
  expect(success(inspected, "inspect").session).toMatchObject({
    lifecycle: "running",
  });
  control.client.send(
    encodeFrame(control.revision!, 4, 0, 301, { cancel: {} }),
  );
  const cancelled = success(await control.client.read(), "wait");
  expect(cancelled.outcome).toEqual({ cancelled: {} });
  const afterCancel = await requestAction(
    unrelated.client,
    unrelated.revision!,
    300_302,
    "inspect",
    { session_id: sessionId },
  );
  expect(success(afterCancel, "inspect").session).toMatchObject({
    lifecycle: "running",
    attention: { attention: "background", write_lease: "none" },
  });

  control.client.send(
    encodeFrame(control.revision!, 4, 0, 999_999, { cancel: {} }),
  );
  const resized = await requestAction(
    unrelated.client,
    unrelated.revision!,
    303,
    "resize",
    {
      session_id: sessionId,
      dimensions: { rows: 31, columns: 97 },
    },
  );
  expect(success(resized, "resize").dimensions).toEqual({
    rows: 31,
    columns: 97,
  });
  const winch = await requestAction(
    unrelated.client,
    unrelated.revision!,
    304,
    "wait",
    {
      session_id: sessionId,
      return_when: { match: "winch:31 97" },
      safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    },
  );
  expect(success(winch, "wait").outcome).toEqual({ condition_met: {} });

  const signaled = await requestAction(
    unrelated.client,
    unrelated.revision!,
    305,
    "signal",
    { session_id: sessionId, signal: "terminate" },
  );
  expect(success(signaled, "signal").signal).toBe("terminate");
  const waited = await requestAction(
    unrelated.client,
    unrelated.revision!,
    306,
    "wait",
    {
      session_id: sessionId,
      return_when: { exit: {} },
      safety_ceiling_ms: 5_000,
    },
  );
  expect(success(waited, "wait").outcome).toEqual({ exited: 37 });
  const output = await readSession(
    unrelated.client,
    unrelated.revision!,
    307,
    sessionId,
  );
  expect(output.output).toContain("term-trap");

  const closed = await requestAction(
    unrelated.client,
    unrelated.revision!,
    308,
    "close",
    { session_id: sessionId, policy: "graceful" },
  );
  expect(success(closed, "close").session).toMatchObject({
    lifecycle: "closed",
  });

  const gracefulTarget = await startNativeCommandFixture(
    unrelated.client,
    unrelated.revision!,
    309_000,
    {
      cwd: home,
      command:
        "exec /bin/sh -c 'trap \"printf graceful-trap; exit 0\" TERM; printf \"graceful-ready pid:%s\" \"$$\"; while :; do read line; done'",
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      returnWhen: { match: "graceful-ready" },
    },
  );
  const gracefulId = (
    gracefulTarget.session as { session_id: string }
  ).session_id;
  const gracefulBeforeClose = await readSession(
    unrelated.client,
    unrelated.revision!,
    310,
    gracefulId,
  );
  const gracefulPid = Number(gracefulBeforeClose.output.match(/pid:(\d+)/)?.[1]);
  expect(gracefulPid).toBeGreaterThan(0);
  const gracefulClose = await requestAction(
    unrelated.client,
    unrelated.revision!,
    311,
    "close",
    { session_id: gracefulId, policy: "graceful" },
  );
  expect(success(gracefulClose, "close").session).toMatchObject({
    lifecycle: "closed",
  });
  const staleRead = await requestAction(
    unrelated.client,
    unrelated.revision!,
    312,
    "read",
    { session_id: gracefulId, cursor: { segment: 1, offset: 0 } },
  );
  expect(failure(staleRead).code).toBe("authority_denied");
  await waitFor(() => !processExists(gracefulPid));
  expect(directChildPids(host.pid!)).toEqual([]);

  control.client.close();
  unrelated.client.close();
  expect(await waitForExit(host)).toBe(0);
  expect(existsSync(paths.socket)).toBe(false);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 8 + 60_000);

test.skipIf(process.platform !== "linux")(
  "signal reaches a child forked by a non-leader thread",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const proofPath = join(home, "thread-fork.proof");
    const termPath = join(home, "thread-fork.term");
    const fixture = buildThreadForkFixture();
    const host = startHost(home, undefined, 200);
    await waitFor(() => existsSync(paths.socket));
    const control = await handshake(paths.socket, { minimum: 4, current: 5 });
    let rootPid = 0;
    let childPid = 0;

    try {
      const started = await startNativeCommandFixture(
        control.client,
        control.revision!,
        312_900,
        {
          cwd: home,
          command:
            `exec ${JSON.stringify(fixture)} ${JSON.stringify(proofPath)} ` +
            JSON.stringify(termPath),
          shell: { executable: { path: "/bin/zsh", clean_start: true } },
          returnWhen: { match: "thread-fork-ready" },
        },
      );
      const sessionId = (started.session as { session_id: string }).session_id;
      await waitFor(() => existsSync(proofPath));
      const [rootText, workerText, childText] = readFileSync(proofPath, "utf8")
        .trim()
        .split(/\s+/);
      rootPid = Number(rootText);
      const workerTid = Number(workerText);
      childPid = Number(childText);
      const shellPid = Number(durableTerminalRecordFor(home, sessionId).pid);
      expect(rootPid).toBe(shellPid);
      expect(workerTid).toBeGreaterThan(0);
      expect(workerTid).not.toBe(rootPid);
      expect(childPid).toBeGreaterThan(0);
      const workerChildren = readFileSync(
        `/proc/${rootPid}/task/${workerTid}/children`,
        "utf8",
      ).trim().split(/\s+/).filter(Boolean).map(Number);
      const leaderChildren = readFileSync(
        `/proc/${rootPid}/task/${rootPid}/children`,
        "utf8",
      ).trim().split(/\s+/).filter(Boolean).map(Number);
      expect(workerChildren).toContain(childPid);
      expect(leaderChildren).not.toContain(childPid);
      expect(processGroupId(childPid)).not.toBe(processGroupId(rootPid));

      const signaled = await requestAction(
        control.client,
        control.revision!,
        312_901,
        "signal",
        { session_id: sessionId, signal: "terminate" },
      );
      expect(success(signaled, "signal").signal).toBe("terminate");
      await waitFor(
        () => existsSync(termPath) && readFileSync(termPath, "utf8") === "term",
        2_000,
      );
      await waitFor(() => !processExists(childPid), 5_000);
      const waited = await requestAction(
        control.client,
        control.revision!,
        312_902,
        "wait",
        {
          session_id: sessionId,
          return_when: { exit: {} },
          safety_ceiling_ms: 5_000,
        },
      );
      success(waited, "wait");
      const closed = await requestAction(
        control.client,
        control.revision!,
        312_903,
        "close",
        { session_id: sessionId, policy: "force" },
      );
      expect(success(closed, "close").session).toMatchObject({
        lifecycle: "closed",
      });
    } finally {
      for (const pid of [childPid, rootPid]) {
        if (pid <= 0 || !processExists(pid)) continue;
        try {
          process.kill(pid, "SIGKILL");
        } catch {}
      }
      control.client.close();
      if (host.exitCode === null) await waitForExit(host);
    }
  },
  NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3 + 30_000,
);

test("force close reports incomplete refresh descendant and shell delivery", async () => {
  if (!existsSync("/bin/zsh")) return;
  const stages = ["refresh", "outside_group", "shell_group"] as const;
  for (const [index, stage] of stages.entries()) {
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 200, {
      FX_TERMINAL_TEST_FAIL_SIGNAL_STAGE: stage,
    });
    await waitFor(() => existsSync(paths.socket));
    const control = await handshake(paths.socket, { minimum: 4, current: 5 });
    let shellPid = 0;

    try {
      const started = await startNativeCommandFixture(
        control.client,
        control.revision!,
        312_910 + index * 10,
        {
          cwd: home,
          command:
            `printf 'force-close-${stage}-ready\\n'; ` +
            "while :; do sleep 0.05; done",
          shell: { executable: { path: "/bin/zsh", clean_start: true } },
          returnWhen: { match: `force-close-${stage}-ready` },
        },
      );
      const sessionId = (started.session as { session_id: string }).session_id;
      shellPid = Number(durableTerminalRecordFor(home, sessionId).pid);
      const closed = await requestAction(
        control.client,
        control.revision!,
        312_911 + index * 10,
        "close",
        { session_id: sessionId, policy: "force" },
      );
      expect(failure(closed)).toMatchObject({
        action: "close",
        code: "session_lost",
        session_id: sessionId,
        retryable: false,
      });
      expect(durableTerminalRecordFor(home, sessionId)).toMatchObject({
        authority_revoked: true,
        lifecycle: "closed",
      });
      const inspect = await requestAction(
        control.client,
        control.revision!,
        312_912 + index * 10,
        "inspect",
        { session_id: sessionId },
      );
      expect(failure(inspect).code).toBe("authority_denied");
    } finally {
      if (shellPid > 0 && processExists(shellPid)) {
        try {
          process.kill(shellPid, "SIGKILL");
        } catch {}
      }
      control.client.close();
      if (host.exitCode === null) await waitForExit(host);
    }
  }
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 8 + 60_000);

test("signal reaches a background job outside the shell process group", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const proofPath = join(home, "background-signal.proof");
  const termPath = join(home, "background-signal.term");
  const stopPath = join(home, "background-signal.stop");
  const scriptPath = join(home, "background-signal.sh");
  writeFileSync(
    scriptPath,
    `#!/bin/sh
trap 'printf term > ${JSON.stringify(termPath)}; exit 0' TERM
printf '%s %s %s\n' "$$" "$PPID" "$(ps -o pgid= -p $$ | tr -d ' ')" > ${JSON.stringify(proofPath)}
while [ ! -e ${JSON.stringify(stopPath)} ]; do sleep 0.05; done
`,
  );
  chmodSync(scriptPath, 0o700);

  const host = startHost(home, undefined, 200);
  await waitFor(() => existsSync(paths.socket));
  const control = await handshake(paths.socket, { minimum: 4, current: 5 });
  let targetPid = 0;

  try {
    const started = await startNativeCommandFixture(
      control.client,
      control.revision!,
      313_000,
      {
        cwd: home,
        command:
          `${JSON.stringify(scriptPath)} & child=$!; ` +
          `while [ ! -s ${JSON.stringify(proofPath)} ]; do sleep 0.05; done; ` +
          "printf 'background-signal-ready\\n'; wait \"$child\"",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        returnWhen: { match: "background-signal-ready" },
      },
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    const [pidText, parentText, pgidText] = readFileSync(proofPath, "utf8")
      .trim()
      .split(/\s+/);
    targetPid = Number(pidText);
    const targetParentPid = Number(parentText);
    const targetPgid = Number(pgidText);
    const shellPid = Number(durableTerminalRecordFor(home, sessionId).pid);
    expect(targetPid).toBeGreaterThan(0);
    expect(targetParentPid).toBe(shellPid);
    expect(targetPgid).toBe(processGroupId(targetPid));
    expect(targetPgid).not.toBe(processGroupId(shellPid));

    const signaled = await requestAction(
      control.client,
      control.revision!,
      313_010,
      "signal",
      { session_id: sessionId, signal: "terminate" },
    );
    expect(success(signaled, "signal").signal).toBe("terminate");
    await waitFor(
      () => existsSync(termPath) && readFileSync(termPath, "utf8") === "term",
      2_000,
    );
    expect(readFileSync(termPath, "utf8")).toBe("term");
    await waitFor(() => !processExists(targetPid), 5_000);
  } finally {
    writeFileSync(stopPath, "");
    if (targetPid > 0 && processExists(targetPid)) {
      await waitFor(() => !processExists(targetPid), 5_000).catch(() => {
        try {
          process.kill(targetPid, "SIGKILL");
        } catch {}
      });
    }
    control.client.close();
    if (host.exitCode === null) await waitForExit(host);
  }
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3 + 30_000);

test("force close reaches a background job outside the shell process group", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const proofPath = join(home, "background-force-close.proof");
  const stopPath = join(home, "background-force-close.stop");
  const scriptPath = join(home, "background-force-close.sh");
  writeFileSync(
    scriptPath,
    `#!/bin/sh
printf '%s %s %s\n' "$$" "$PPID" "$(ps -o pgid= -p $$ | tr -d ' ')" > ${JSON.stringify(proofPath)}
while [ ! -e ${JSON.stringify(stopPath)} ]; do sleep 0.05; done
`,
  );
  chmodSync(scriptPath, 0o700);

  const host = startHost(home, undefined, 200);
  await waitFor(() => existsSync(paths.socket));
  const control = await handshake(paths.socket, { minimum: 4, current: 5 });
  let shellPid = 0;
  let targetPid = 0;

  try {
    const started = await startNativeCommandFixture(
      control.client,
      control.revision!,
      313_020,
      {
        cwd: home,
        command:
          `${JSON.stringify(scriptPath)} & child=$!; ` +
          `while [ ! -s ${JSON.stringify(proofPath)} ]; do sleep 0.05; done; ` +
          "printf 'background-force-close-ready\\n'; wait \"$child\"",
        shell: { executable: { path: "/bin/zsh", clean_start: true } },
        returnWhen: { match: "background-force-close-ready" },
      },
    );
    const sessionId = (started.session as { session_id: string }).session_id;
    const [pidText, parentText, pgidText] = readFileSync(proofPath, "utf8")
      .trim()
      .split(/\s+/);
    targetPid = Number(pidText);
    const targetParentPid = Number(parentText);
    const targetPgid = Number(pgidText);
    shellPid = Number(durableTerminalRecordFor(home, sessionId).pid);
    expect(targetPid).toBeGreaterThan(0);
    expect(targetParentPid).toBe(shellPid);
    expect(targetPgid).toBe(processGroupId(targetPid));
    expect(targetPgid).not.toBe(processGroupId(shellPid));

    const closed = await requestAction(
      control.client,
      control.revision!,
      313_030,
      "close",
      { session_id: sessionId, policy: "force" },
    );
    expect(success(closed, "close").session).toMatchObject({
      lifecycle: "closed",
    });
    await waitFor(() => !processExists(shellPid), 5_000);
    await waitFor(() => !processExists(targetPid), 5_000);
  } finally {
    writeFileSync(stopPath, "");
    if (targetPid > 0 && processExists(targetPid)) {
      try {
        process.kill(targetPid, "SIGKILL");
      } catch {}
    }
    if (shellPid > 0 && processExists(shellPid)) {
      try {
        process.kill(shellPid, "SIGKILL");
      } catch {}
    }
    control.client.close();
    if (host.exitCode === null) await waitForExit(host);
  }
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3 + 30_000);

test.skipIf(!tmuxAvailable())(
  "malformed close recovery cleans only its tmux owner and preserves a live sibling",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const firstHost = startHost(home, undefined, 30_000);
    const firstStdout = streamText(firstHost.stdout);
    const firstStderr = streamText(firstHost.stderr);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const valid = await startCommand(first.client, first.revision!, 313, {
      cwd: home,
      command:
        "printf 'valid-close-sibling-ready\\n'; while IFS= read -r line; do printf 'valid-close-sibling:%s\\n' \"$line\"; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "valid-close-sibling-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const invalid = await startCommand(first.client, first.revision!, 314, {
      cwd: home,
      command: "printf 'invalid-close-owner-ready\\n'; sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "invalid-close-owner-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const validId = (valid.session as { session_id: string }).session_id;
    const invalidId = (invalid.session as { session_id: string }).session_id;
    const stateDir = join(
      home,
      ".fx",
      "sessions",
      TERMINAL_OWNER_SESSION,
      "terminal",
      "state",
    );
    const recordFor = (sessionId: string) => JSON.parse(readFileSync(
      join(stateDir, `record-${sessionId}.json`),
      "utf8",
    )) as { backend_identity: string };
    const validIdentity = recordFor(validId).backend_identity;
    const invalidIdentity = recordFor(invalidId).backend_identity;
    const tmuxSocket = terminalTransportPaths(home).tmuxSocket;
    const panePidFor = (identity: string) => Number(execFileSync(
      "tmux",
      [
        "-S",
        tmuxSocket,
        "display-message",
        "-p",
        "-t",
        `fx-${identity}`,
        "#{pane_pid}",
      ],
      { encoding: "utf8" },
    ).trim());
    const validPanePid = panePidFor(validIdentity);
    const invalidPanePid = panePidFor(invalidIdentity);
    writeFileSync(
      join(stateDir, `close-transaction-${invalidId}.json`),
      "{",
      { mode: 0o600 },
    );

    const oldIdentity = readFileSync(paths.identity, "utf8");
    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);
    expect(await firstStdout).toBe("");
    expect(await firstStderr).toBe("");
    expect(processExists(validPanePid)).toBe(true);
    expect(processExists(invalidPanePid)).toBe(true);

    const replacement = startHost(home, undefined, 5_000);
    const replacementStdout = streamText(replacement.stdout);
    const replacementStderr = streamText(replacement.stderr);
    await waitFor(() =>
      existsSync(paths.socket) && existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity
    , 8_000);
    const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
    await waitFor(() => !processExists(invalidPanePid), 5_000);
    expect(processExists(validPanePid)).toBe(true);
    const sessionNames = execFileSync(
      "tmux",
      ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
      { encoding: "utf8" },
    ).trim().split("\n");
    expect(sessionNames).toEqual([`fx-${validIdentity}`]);
    expect(existsSync(`/tmp/fx-tmux-capture-${invalidIdentity}.sock`)).toBe(
      false,
    );
    expect(existsSync(`/tmp/fx-tmux-marker-${invalidIdentity}.sock`)).toBe(
      false,
    );
    expect(readdirSync(stateDir)).not.toContain(
      `close-transaction-${invalidId}.json`,
    );

    const listed = success(await requestAction(
      recovered.client,
      recovered.revision!,
      315,
      "list",
      {},
    ), "list") as {
      sessions: Array<{
        session_id: string;
        lifecycle: string;
        active_monitor_count: number;
      }>;
    };
    expect(listed.sessions).toContainEqual(expect.objectContaining({
      session_id: validId,
      lifecycle: "running",
    }));
    expect(listed.sessions).toContainEqual(expect.objectContaining({
      session_id: invalidId,
      lifecycle: "closed",
      active_monitor_count: 0,
    }));
    const invalidInspect = await requestAction(
      recovered.client,
      recovered.revision!,
      316,
      "inspect",
      { session_id: invalidId },
    );
    expect(failure(invalidInspect).code).toBe("authority_denied");
    success(await requestAction(
      recovered.client,
      recovered.revision!,
      317,
      "write",
      { session_id: validId, payload: { text: "still-live\n" } },
    ), "write");
    const waited = success(await requestAction(
      recovered.client,
      recovered.revision!,
      318,
      "wait",
      {
        session_id: validId,
        return_when: { match: "valid-close-sibling:still-live" },
        safety_ceiling_ms: 5_000,
      },
    ), "wait");
    expect(waited.outcome).toEqual({ condition_met: {} });

    success(await requestAction(
      recovered.client,
      recovered.revision!,
      319,
      "close",
      { session_id: validId, policy: "force" },
    ), "close");
    await waitFor(() => !existsSync(tmuxSocket), 5_000);
    recovered.client.close();
    expect(await waitForExit(replacement)).toBe(0);
    expect(await replacementStdout).toBe("");
    expect(await replacementStderr).toBe("");
  },
  30_000,
);

test.skipIf(!tmuxAvailable())(
  "checked cleanup failure wins over incomplete delivery and retains recovery intent",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const firstHost = startHost(home, undefined, 30_000, {
      FX_TERMINAL_TEST_FAIL_TMUX_CLOSE_CLEANUP: "1",
      FX_TERMINAL_TEST_FAIL_SIGNAL_STAGE: "outside_group",
    });
    const firstStdout = streamText(firstHost.stdout);
    const firstStderr = streamText(firstHost.stderr);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const firstIdentity = readFileSync(paths.identity, "utf8");
    const sibling = await startCommand(first.client, first.revision!, 336, {
      cwd: home,
      command:
        "printf 'live-sibling-ready\\n'; while IFS= read -r line; do printf 'live-sibling:%s\\n' \"$line\"; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "live-sibling-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const closing = await startCommand(first.client, first.revision!, 337, {
      cwd: home,
      command: "printf 'live-close-ready\\n'; sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "live-close-ready" },
      waitMs: TMUX_MARKER_IO_DEADLINE_MS + CLEANUP_FINALIZATION_BUDGET_MS,
      startupAttempts: 2,
    });
    const siblingId = (sibling.session as { session_id: string }).session_id;
    const closingId = (closing.session as { session_id: string }).session_id;
    const stateDir = join(
      home,
      ".fx",
      "sessions",
      TERMINAL_OWNER_SESSION,
      "terminal",
      "state",
    );
    const recordFor = (sessionId: string) => JSON.parse(readFileSync(
      join(stateDir, `record-${sessionId}.json`),
      "utf8",
    )) as {
      authority_revoked: boolean;
      backend_identity: string;
      lifecycle: string;
    };
    const siblingIdentity = recordFor(siblingId).backend_identity;
    const closingIdentity = recordFor(closingId).backend_identity;
    const tmuxSocket = terminalTransportPaths(home).tmuxSocket;
    const transactionName = `close-transaction-${closingId}.json`;

    const closeStartedAt = Date.now();
    const failedClose = await requestAction(
      first.client,
      first.revision!,
      338,
      "close",
      { session_id: closingId, policy: "force" },
    );
    expect(Date.now() - closeStartedAt).toBeLessThan(8_000);
    expect(failure(failedClose)).toMatchObject({
      action: "close",
      code: "invalid_request",
    });
    expect(recordFor(closingId)).toMatchObject({
      authority_revoked: true,
      lifecycle: "running",
    });
    expect(readdirSync(stateDir)).toContain(transactionName);
    expect(existsSync(tmuxSocket)).toBe(true);
    const retainedPane = execFileSync(
      "tmux",
      [
        "-S",
        tmuxSocket,
        "display-message",
        "-p",
        "-t",
        `fx-${closingIdentity}`,
        "#{pane_id}|#{pane_dead}",
      ],
      { encoding: "utf8" },
    ).trim();
    expect(retainedPane).toMatch(/^%\d+\|[01]$/);
    execFileSync(
      "tmux",
      ["-S", tmuxSocket, "has-session", "-t", `fx-${siblingIdentity}`],
    );
    success(await requestAction(
      first.client,
      first.revision!,
      339,
      "write",
      { session_id: siblingId, payload: { text: "before-restart\n" } },
    ), "write");
    const beforeRestart = success(await requestAction(
      first.client,
      first.revision!,
      340,
      "wait",
      {
        session_id: siblingId,
        return_when: { match: "live-sibling:before-restart" },
        safety_ceiling_ms: 5_000,
      },
    ), "wait");
    expect(beforeRestart.outcome).toEqual({ condition_met: {} });

    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);
    expect(await firstStdout).toBe("");
    expect(await firstStderr).toBe("");

    const replacement = startHost(home, undefined, 1_000);
    const replacementStdout = streamText(replacement.stdout);
    const replacementStderr = streamText(replacement.stderr);
    await waitFor(
      () => existsSync(paths.socket) && existsSync(paths.identity) &&
        readFileSync(paths.identity, "utf8") !== firstIdentity,
      8_000,
    );
    const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
    expect(readdirSync(stateDir)).not.toContain(transactionName);
    expect(existsSync(tmuxSocket)).toBe(true);
    const names = execFileSync(
      "tmux",
      ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
      { encoding: "utf8" },
    ).trim().split("\n");
    expect(names).toEqual([`fx-${siblingIdentity}`]);
    success(await requestAction(
      recovered.client,
      recovered.revision!,
      341,
      "write",
      { session_id: siblingId, payload: { text: "after-restart\n" } },
    ), "write");
    const afterRestart = success(await requestAction(
      recovered.client,
      recovered.revision!,
      342,
      "wait",
      {
        session_id: siblingId,
        return_when: { match: "live-sibling:after-restart" },
        safety_ceiling_ms: 5_000,
      },
    ), "wait");
    expect(afterRestart.outcome).toEqual({ condition_met: {} });
    success(await requestAction(
      recovered.client,
      recovered.revision!,
      343,
      "close",
      { session_id: siblingId, policy: "force" },
    ), "close");
    await waitFor(() => !existsSync(tmuxSocket), 5_000);
    recovered.client.close();
    expect(await waitForExit(replacement)).toBe(0);
    expect(await replacementStdout).toBe("");
    expect(await replacementStderr).toBe("");
  },
  40_000,
);

test.skipIf(!tmuxAvailable())(
  "checked tmux close recovery retains cleanup intent until a clean retry",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const firstHost = startHost(home, undefined, 30_000, {
      FX_TERMINAL_TEST_INTERRUPT_CLOSE_AFTER_COMMIT: "1",
    });
    const firstStdout = streamText(firstHost.stdout);
    const firstStderr = streamText(firstHost.stderr);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const sibling = await startCommand(first.client, first.revision!, 330, {
      cwd: home,
      command:
        "printf 'checked-sibling-ready\\n'; while IFS= read -r line; do printf 'checked-sibling:%s\\n' \"$line\"; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "checked-sibling-ready" },
      waitMs: 8_000,
    });
    const closing = await startCommand(first.client, first.revision!, 331, {
      cwd: home,
      command: "printf 'checked-close-ready\\n'; sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "checked-close-ready" },
      waitMs: 8_000,
    });
    const siblingId = (sibling.session as { session_id: string }).session_id;
    const closingId = (closing.session as { session_id: string }).session_id;
    const stateDir = join(
      home,
      ".fx",
      "sessions",
      TERMINAL_OWNER_SESSION,
      "terminal",
      "state",
    );
    const recordFor = (sessionId: string) => JSON.parse(readFileSync(
      join(stateDir, `record-${sessionId}.json`),
      "utf8",
    )) as { backend_identity: string; lifecycle: string };
    const siblingIdentity = recordFor(siblingId).backend_identity;
    const closingIdentity = recordFor(closingId).backend_identity;
    const tmuxSocket = terminalTransportPaths(home).tmuxSocket;
    const panePidFor = (identity: string) => Number(execFileSync(
      "tmux",
      [
        "-S",
        tmuxSocket,
        "display-message",
        "-p",
        "-t",
        `fx-${identity}`,
        "#{pane_pid}",
      ],
      { encoding: "utf8" },
    ).trim());
    const siblingPanePid = panePidFor(siblingIdentity);
    const closingPanePid = panePidFor(closingIdentity);
    const transactionName = `close-transaction-${closingId}.json`;

    const interrupted = await requestAction(
      first.client,
      first.revision!,
      332,
      "close",
      { session_id: closingId, policy: "force" },
    );
    expect(failure(interrupted)).toMatchObject({
      action: "close",
      code: "invalid_request",
    });
    expect(recordFor(closingId).lifecycle).toBe("running");
    expect(readdirSync(stateDir)).toContain(transactionName);
    expect(processExists(closingPanePid)).toBe(true);
    expect(processExists(siblingPanePid)).toBe(true);

    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);
    expect(await firstStdout).toBe("");
    expect(await firstStderr).toBe("");

    const failedRecovery = startHost(home, undefined, 30_000, {
      FX_TERMINAL_TEST_FAIL_TMUX_CLOSE_CLEANUP: "1",
    });
    const failedStdout = streamText(failedRecovery.stdout);
    const failedStderr = streamText(failedRecovery.stderr);
    expect(await waitForExit(failedRecovery)).not.toBe(0);
    expect(await failedStdout).toBe("");
    expect(await failedStderr).toBe("");
    expect(recordFor(closingId).lifecycle).toBe("closed");
    expect(readdirSync(stateDir)).toContain(transactionName);
    expect(processExists(closingPanePid)).toBe(true);
    expect(processExists(siblingPanePid)).toBe(true);
    execFileSync(
      "tmux",
      ["-S", tmuxSocket, "has-session", "-t", `fx-${closingIdentity}`],
    );
    execFileSync(
      "tmux",
      ["-S", tmuxSocket, "has-session", "-t", `fx-${siblingIdentity}`],
    );

    const replacement = startHost(home, undefined, 500);
    const replacementStdout = streamText(replacement.stdout);
    const replacementStderr = streamText(replacement.stderr);
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity), 8_000);
    const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
    await waitFor(() => !processExists(closingPanePid), 5_000);
    expect(processExists(siblingPanePid)).toBe(true);
    expect(readdirSync(stateDir)).not.toContain(transactionName);
    execFileSync(
      "tmux",
      ["-S", tmuxSocket, "has-session", "-t", `fx-${siblingIdentity}`],
    );
    const names = execFileSync(
      "tmux",
      ["-S", tmuxSocket, "list-sessions", "-F", "#{session_name}"],
      { encoding: "utf8" },
    ).trim().split("\n");
    expect(names).toEqual([`fx-${siblingIdentity}`]);

    success(await requestAction(
      recovered.client,
      recovered.revision!,
      333,
      "write",
      { session_id: siblingId, payload: { text: "survived\n" } },
    ), "write");
    const waited = success(await requestAction(
      recovered.client,
      recovered.revision!,
      334,
      "wait",
      {
        session_id: siblingId,
        return_when: { match: "checked-sibling:survived" },
        safety_ceiling_ms: 5_000,
      },
    ), "wait");
    expect(waited.outcome).toEqual({ condition_met: {} });
    success(await requestAction(
      recovered.client,
      recovered.revision!,
      335,
      "close",
      { session_id: siblingId, policy: "force" },
    ), "close");
    await waitFor(() => !existsSync(tmuxSocket), 5_000);
    recovered.client.close();
    expect(await waitForExit(replacement)).toBe(0);
    expect(await replacementStdout).toBe("");
    expect(await replacementStderr).toBe("");
  },
  40_000,
);

test(
  "reopened cancellation reports open failure and terminates an abandoned response",
  async () => {
    const error = "InjectedCancellationOpenFailure";
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const firstHost = startHost(home, undefined, 30_000);
    await waitFor(() => existsSync(paths.socket));
    const first = await handshake(paths.socket, { minimum: 4, current: 5 });
    const started = await startCommand(first.client, first.revision!, 334, {
      cwd: home,
      command: "sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
    });
    const sessionId = (started.session as { session_id: string }).session_id;
    const oldIdentity = readFileSync(paths.identity, "utf8");
    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);

    const trace = join(home, `reopened-cancellation-${error}.log`);
    const barrier = join(home, `reopened-cancellation-${error}`);
    const replacement = startHost(home, undefined, 300, {
      FX_TRACE_LOG: trace,
      FX_TRACE_SCOPES: "terminal_host",
      FX_TERMINAL_TEST_ORDER_BARRIER: barrier,
      FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION: "335",
      FX_TERMINAL_TEST_FAIL_CANCELLATION_OPEN: "1",
    });
    await waitFor(() =>
      existsSync(paths.socket) && existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity
    );
    const reopened = await handshake(paths.socket, { minimum: 4, current: 5 });
    reopened.client.send(encodeFrame(
      reopened.revision!,
      1,
      actionSubjects.monitor,
      335,
      { request: { monitor: withAuthority("monitor", {
        session_id: sessionId,
        operation: { add: {
          condition: { output_contains: "never" },
          notify_schedule: { on_match: {} },
          lifetime: { until_session_end: {} },
        } },
      }) } },
      1,
    ));
    await waitFor(() => existsSync(`${barrier}.335.ready`));
    reopened.client.send(encodeFrame(
      reopened.revision!,
      4,
      0,
      335,
      { cancel: {} },
    ));
    await expect(reopened.client.read()).rejects.toThrow("socket closed");
    await waitFor(() => existsSync(trace) && readFileSync(trace, "utf8").includes(
      `cancellation persistence failed correlation=335 session=${sessionId} err=${error}`,
    ));

    const cleanup = await handshake(paths.socket, { minimum: 4, current: 5 });
    success(await requestAction(cleanup.client, cleanup.revision!, 336, "close", {
      session_id: sessionId,
      policy: "force",
    }), "close");
    cleanup.client.close();
    expect(await waitForExit(replacement)).toBe(0);
  },
  25_000,
);

test("interactive writes preserve mappings and large output rotates durable segments", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(
    home,
    undefined,
    NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3,
  );
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

  const interactive = await finishStartupObservation(
    connected.client,
    connected.revision!,
    400_001,
    await startCommand(connected.client, connected.revision!, 400_000, {
      cwd: home,
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      backend: "native",
      returnWhen: { started: {} },
      waitMs: NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
    }),
    "native",
    { started: {} },
    NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2,
  );
  const interactiveId = (
    interactive.session as { session_id: string }
  ).session_id;
  await requestAction(connected.client, connected.revision!, 401, "write", {
    session_id: interactiveId,
    payload: { text: "printf 'text-write force-pid:%s\\\\n' \"$$\"" },
  });
  await requestAction(connected.client, connected.revision!, 402, "write", {
    session_id: interactiveId,
    payload: { keys: ["enter"] },
  });
  await requestAction(connected.client, connected.revision!, 403, "write", {
    session_id: interactiveId,
    payload: { text: "sleep 30" },
  });
  await requestAction(connected.client, connected.revision!, 404, "write", {
    session_id: interactiveId,
    payload: { keys: ["enter"] },
  });
  await Bun.sleep(50);
  const interrupted = await requestAction(
    connected.client,
    connected.revision!,
    405,
    "write",
    {
      session_id: interactiveId,
      payload: { controls: [{ character: 99 }] },
    },
  );
  expect(success(interrupted, "write").accepted_bytes).toBe(1);
  await requestAction(connected.client, connected.revision!, 406, "write", {
    session_id: interactiveId,
    payload: { paste: "printf 'paste-write\\n'\r" },
  });
  const matched = await requestAction(
    connected.client,
    connected.revision!,
    407,
    "wait",
    {
      session_id: interactiveId,
      return_when: { match: "paste-write" },
      safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    },
  );
  expect(success(matched, "wait").outcome).toEqual({ condition_met: {} });
  const interactiveOutput = await readSession(
    connected.client,
    connected.revision!,
    408,
    interactiveId,
  );
  expect(interactiveOutput.output).toContain("text-write");
  expect(interactiveOutput.output).toContain("paste-write");
  const forcePid = Number(
    interactiveOutput.output.match(/force-pid:(\d+)/)?.[1],
  );
  expect(forcePid).toBeGreaterThan(0);
  const forceClosed = await requestAction(
    connected.client,
    connected.revision!,
    409,
    "close",
    {
      session_id: interactiveId,
      policy: "force",
    },
  );
  expect(success(forceClosed, "close").session).toMatchObject({
    lifecycle: "closed",
  });
  await waitFor(() => !processExists(forcePid));
  expect(directChildPids(host.pid!)).toEqual([]);

  const large = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    410_000,
    {
      cwd: home,
      command: "head -c 1100000 /dev/zero | tr '\\\\0' x",
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      returnWhen: { exit: {} },
      waitMs: 15_000,
    },
  );
  expect(large.outcome).toEqual({ exited: 0 });
  const largeId = (large.session as { session_id: string }).session_id;
  let offset = 0;
  let retained = "";
  let largeFacts: Record<string, unknown> | undefined;
  while (true) {
    const page = await readSession(
      connected.client,
      connected.revision!,
      411 + offset,
      largeId,
      offset,
    );
    retained += page.output;
    offset += Buffer.byteLength(page.output);
    largeFacts = page.session;
    const cursor = page.session.output_cursor as { segment: number; offset: number };
    expect(cursor.segment).toBe(1);
    if (offset === cursor.offset) break;
    expect(page.output.length).toBeGreaterThan(0);
  }
  expect(retained).toBe("\0".repeat(1_100_000));
  expect(largeFacts?.raw_gap).toBeNull();

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 10 + 30_000);

test("completed sessions recycle capacity and release every native backend resource", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  let connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const baselineFds = processFdCount(host.pid!);
  let correlation = 450;
  let firstSessionId = "";

  for (let cycle = 0; cycle < 20; cycle++) {
    if (cycle > 0 && cycle % 8 === 0) {
      connected.client.close();
      connected = await handshake(paths.socket, { minimum: 4, current: 5 });
    }
    const started = await startNativeCommandFixture(
      connected.client,
      connected.revision!,
      correlation,
      {
        cwd: home,
        command: `printf 'cycle-${cycle}-pid:%s' "$$"; exit 0`,
        shell: {
          executable: { path: "/bin/zsh", clean_start: true },
        },
        returnWhen: { exit: {} },
      },
    );
    correlation += 6;
    const sessionId = (started.session as { session_id: string }).session_id;
    expect(started.outcome).toEqual({ exited: 0 });
    const output = (
      await readSession(
        connected.client,
        connected.revision!,
        correlation++,
        sessionId,
      )
    ).output;
    const targetPid = Number(
      output.match(new RegExp(`cycle-${cycle}-pid:(\\d+)`))?.[1],
    );
    expect(targetPid).toBeGreaterThan(0);
    if (cycle === 0) {
      firstSessionId = sessionId;
    }
    await waitFor(() => !processExists(targetPid));
    const closed = await requestAction(
      connected.client,
      connected.revision!,
      correlation++,
      "close",
      { session_id: sessionId, policy: "graceful" },
    );
    expect(success(closed, "close").session).toMatchObject({
      lifecycle: "closed",
    });
  }

  await waitFor(() => directChildPids(host.pid!).length === 0);
  await Bun.sleep(50);
  expect(processFdCount(host.pid!)).toBeLessThanOrEqual(baselineFds + 2);
  const historicalList = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "list",
    {},
  );
  expect(
    (success(historicalList, "list").sessions as Array<{
      session_id: string;
      lifecycle: string;
    }>),
  ).toContainEqual(expect.objectContaining({
    session_id: firstSessionId,
    lifecycle: "closed",
  }));

  const historicalRead = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "read",
    { session_id: firstSessionId, cursor: { segment: 1, offset: 0 } },
  );
  expect(failure(historicalRead).code).toBe("authority_denied");
  const historicalInspect = await requestAction(
    connected.client,
    connected.revision!,
    correlation++,
    "inspect",
    { session_id: firstSessionId },
  );
  expect(failure(historicalInspect).code).toBe("authority_denied");

  connected.client.close();
  const previousIdentity = readFileSync(paths.identity, "utf8");
  host.kill("SIGKILL");
  await waitForExit(host);

  const replacement = startHost(home, undefined, 10_000);
  await waitFor(
    () =>
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== previousIdentity,
    3_000,
  );
  const reopened = await handshake(paths.socket, { minimum: 4, current: 5 });
  const reopenedRead = await requestAction(
    reopened.client,
    reopened.revision!,
    correlation++,
    "read",
    { session_id: firstSessionId, cursor: { segment: 1, offset: 0 } },
  );
  expect(failure(reopenedRead).code).toBe("authority_denied");
  const reopenedInspect = await requestAction(
    reopened.client,
    reopened.revision!,
    correlation++,
    "inspect",
    { session_id: firstSessionId },
  );
  expect(failure(reopenedInspect).code).toBe("authority_denied");
  const reopenedList = await requestAction(
    reopened.client,
    reopened.revision!,
    correlation++,
    "list",
    {},
  );
  expect(
    (success(reopenedList, "list").sessions as Array<{
      session_id: string;
      lifecycle: string;
    }>),
  ).toContainEqual(expect.objectContaining({
    session_id: firstSessionId,
    lifecycle: "closed",
  }));
  reopened.client.close();
  replacement.kill("SIGKILL");
  await waitForExit(replacement);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 8 + 120_000);

test("host remains authoritative until natural backend cleanup finishes", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 40, {
    FX_TERMINAL_TEST_BACKEND_CLEANUP_DELAY_MS: "500",
  });
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    480_000,
    {
      cwd: home,
      command: "printf cleanup-running; IFS= read -r _; exit 0",
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      returnWhen: { match: "cleanup-running" },
    },
  );
  expect(started.outcome).toEqual({ condition_met: {} });
  const sessionId = (started.session as { session_id: string }).session_id;
  success(await requestAction(connected.client, connected.revision!, 481, "write", {
    session_id: sessionId,
    payload: { text: "\n" },
  }), "write");
  connected.client.close();

  await Bun.sleep(250);
  expect(host.exitCode).toBeNull();
  expect(existsSync(paths.socket)).toBe(true);
  expect(existsSync(paths.identity)).toBe(true);
  const duringCleanup = await Promise.race([
    handshake(paths.socket, { minimum: 4, current: 5 }),
    Bun.sleep(400).then(() => {
      throw new Error("host stopped accepting during backend cleanup");
    }),
  ]);
  expect(duringCleanup.revision).toBe(5);
  duringCleanup.client.close();

  expect(await waitForExit(host)).toBe(0);
  expect(existsSync(paths.socket)).toBe(false);
  expect(existsSync(paths.identity)).toBe(false);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 30_000);

test("process-token capture failure kills and reaps before returning failure", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const pidFile = join(home, "token-target.pid");
  const host = startHost(
    home,
    undefined,
    NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 4,
    { FX_TERMINAL_FIXTURE_FAIL_PROCESS_TOKEN: "1" },
    buildCurrentClientFixture(),
  );
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const startedAt = Date.now();
  let result: WireFrame | undefined;
  for (let attempt = 0; attempt < 2; attempt++) {
    result = await requestAction(
      connected.client,
      connected.revision!,
      490 + attempt * 10_000,
      "start",
      {
        cwd: home,
        command:
          `printf '%s' "$$" > '${pidFile}'; exec /bin/sleep 30`,
        shell: {
          executable: { path: "/bin/zsh", clean_start: true },
        },
        backend: "native",
        return_when: { exit: {} },
        wait_ceiling_ms: NATIVE_STARTUP_OBSERVATION_BUDGET_MS,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    );
    if (failureCode(result) !== undefined) break;
    const started = success(result, "start");
    expect(started.outcome).toEqual({ safety_ceiling: {} });
    if (attempt === 0) {
      console.error("Retrying process-token failure fixture after startup observation ceiling");
      await forceCloseTerminalFixture(
        connected.client,
        connected.revision!,
        499,
        (started.session as { session_id: string }).session_id,
      );
    }
  }
  expect(result).toBeDefined();
  expect(failure(result!)).toMatchObject({
    action: "start",
    code: "process_identity_unavailable",
  });
  expect(Date.now() - startedAt).toBeLessThan(
    NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 5_000,
  );
  if (existsSync(pidFile)) {
    const targetPid = Number(readFileSync(pidFile, "utf8"));
    expect(targetPid).toBeGreaterThan(0);
    await waitFor(() => !processExists(targetPid));
  }
  await waitFor(() => directChildPids(host.pid!).length === 0);

  connected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 3 + 30_000);

test.skipIf(!tmuxAvailable())(
  "owner catalog keeps every matching session after the first exits and closes",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHost(home, undefined, 10_000);
    await waitFor(() => existsSync(paths.socket));
    const connected = await handshake(paths.socket, { minimum: 4, current: 5 });

    const first = await startInteractiveNativeFixture(
      connected.client,
      connected.revision!,
      490_000,
      {
        cwd: home,
        command: "printf first-catalog-ready; IFS= read -r _; exit 0",
        marker: "first-catalog-ready",
      },
    );
    const second = await startCommand(connected.client, connected.revision!, 491, {
      cwd: home,
      command: "printf second-catalog-ready; sleep 30",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "second-catalog-ready" },
      waitMs: 8_000,
    });
    const firstId = (first.session as { session_id: string }).session_id;
    const secondId = (second.session as { session_id: string }).session_id;

    const bothRunning = success(
      await requestAction(connected.client, connected.revision!, 492, "list", {}),
      "list",
    ).sessions as Array<Record<string, unknown>>;
    expect(bothRunning).toContainEqual(expect.objectContaining({
      session_id: firstId,
      lifecycle: "running",
    }));
    expect(bothRunning).toContainEqual(expect.objectContaining({
      session_id: secondId,
      lifecycle: "running",
    }));

    success(await requestAction(connected.client, connected.revision!, 492_000, "write", {
      session_id: firstId,
      payload: { text: "\n" },
    }), "write");
    const firstExit = success(
      await requestAction(connected.client, connected.revision!, 493, "wait", {
        session_id: firstId,
        return_when: { exit: {} },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    expect(firstExit.outcome).toEqual({ exited: 0 });
    const afterExit = success(
      await requestAction(connected.client, connected.revision!, 494, "list", {}),
      "list",
    ).sessions as Array<Record<string, unknown>>;
    expect(afterExit).toContainEqual(expect.objectContaining({
      session_id: firstId,
      lifecycle: "exited",
    }));
    expect(afterExit).toContainEqual(expect.objectContaining({
      session_id: secondId,
      lifecycle: "running",
    }));

    await requestAction(connected.client, connected.revision!, 495, "close", {
      session_id: firstId,
      policy: "graceful",
    });
    const afterClose = success(
      await requestAction(connected.client, connected.revision!, 496, "list", {}),
      "list",
    ).sessions as Array<Record<string, unknown>>;
    expect(afterClose).toContainEqual(expect.objectContaining({
      session_id: firstId,
      lifecycle: "closed",
    }));
    expect(afterClose).toContainEqual(expect.objectContaining({
      session_id: secondId,
      lifecycle: "running",
    }));

    let filterCorrelation = 497;
    for (const [filters, expectedIds, excludedIds] of [
      [{ lifecycle: "running" }, [secondId], [firstId]],
      [{ backend: "tmux" }, [secondId], [firstId]],
      [{ backend: "native" }, [firstId], [secondId]],
      [{ workspace_root: home }, [firstId, secondId], []],
      [{ task_id: TERMINAL_OWNER_SESSION }, [firstId, secondId], []],
    ] as const) {
      const sessions = success(
        await requestAction(
          connected.client,
          connected.revision!,
          filterCorrelation++,
          "list",
          filters,
        ),
        "list",
      ).sessions as Array<{ session_id: string }>;
      const sessionIds = sessions.map(({ session_id }) => session_id);
      for (const expectedId of expectedIds) {
        expect(sessionIds).toContain(expectedId);
      }
      for (const excludedId of excludedIds) {
        expect(sessionIds).not.toContain(excludedId);
      }
    }

    const validOwnerAuthority = ownerCatalogAuthorityForSession(
      firstId,
      authorityBySession.get(firstId)!,
    );
    const foreignPrincipal = structuredClone(validOwnerAuthority) as {
      principal: { workspace_root: string };
    };
    foreignPrincipal.principal.workspace_root = `${home}-foreign`;
    expect(failure(await requestAction(
      connected.client,
      connected.revision!,
      600,
      "list",
      { owner_authority: foreignPrincipal },
    )).code).toBe("authority_denied");
    const forgedProof = structuredClone(validOwnerAuthority) as {
      proof: { bytes: number[] };
    };
    forgedProof.proof.bytes[0] = 12;
    expect(failure(await requestAction(
      connected.client,
      connected.revision!,
      601,
      "list",
      { owner_authority: forgedProof },
    )).code).toBe("authority_denied");

    await requestAction(connected.client, connected.revision!, 602, "close", {
      session_id: secondId,
      policy: "force",
    });
    connected.client.close();
    host.kill("SIGKILL");
    await waitForExit(host);
  },
  NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 6 + 30_000,
);

test("concurrent sessions survive disconnect and complete waits independently", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket));
  const origin = await handshake(paths.socket, { minimum: 4, current: 5 });

  const first = await startInteractiveNativeFixture(
    origin.client,
    origin.revision!,
    500_000,
    {
      cwd: home,
      command:
        "printf first-ready; IFS= read -r _; printf first-done; IFS= read -r _; exit 0",
      marker: "first-ready",
    },
  );
  const second = await startInteractiveNativeFixture(
    origin.client,
    origin.revision!,
    501_000,
    {
      cwd: home,
      command:
        "printf second-ready; IFS= read -r _; printf second-done; IFS= read -r _; exit 0",
      marker: "second-ready",
    },
  );
  const firstId = (first.session as { session_id: string }).session_id;
  const secondId = (second.session as { session_id: string }).session_id;

  for (const [correlation, sessionId] of [
    [502, firstId],
    [503, secondId],
  ] as const) {
    origin.client.send(
      encodeFrame(
        origin.revision!,
        1,
        actionSubjects.read,
        correlation,
        {
          request: {
            read: withAuthority("read", {
              session_id: sessionId,
              cursor: { segment: 1, offset: 0 },
            }),
          },
        },
        1,
      ),
    );
  }
  const readResponses = [await origin.client.read(), await origin.client.read()];
  expect(new Set(readResponses.map((response) => response.correlation))).toEqual(
    new Set([502, 503]),
  );

  for (const [correlation, sessionId] of [
    [1_500, firstId],
    [1_501, secondId],
  ] as const) {
    const acquired = await requestAction(
      origin.client,
      origin.revision!,
      correlation,
      "write",
      { session_id: sessionId, lease: "acquire" },
    );
    expect(success(acquired, "write").accepted_bytes).toBe(0);
  }

  for (const [correlation, sessionId] of [
    [504, firstId],
    [505, secondId],
  ] as const) {
    origin.client.send(
      encodeFrame(
        origin.revision!,
        1,
        actionSubjects.write,
        correlation,
        {
          request: {
            write: withAuthority("write", {
              session_id: sessionId,
              payload: { text: "\n" },
              lease: "use",
            }),
          },
        },
        1,
      ),
    );
  }
  const writeResponses = [
    await origin.client.read(),
    await origin.client.read(),
  ];
  expect(
    new Set(writeResponses.map((response) => response.correlation)),
  ).toEqual(new Set([504, 505]));
  for (const response of writeResponses) {
    expect(success(response, "write").accepted_bytes).toBe(1);
  }
  origin.client.close();

  const reconnected = await handshake(paths.socket, {
    minimum: 4,
    current: 5,
  });
  const firstInspect = await requestAction(
    reconnected.client,
    reconnected.revision!,
    506,
    "inspect",
    { session_id: firstId },
  );
  expect(success(firstInspect, "inspect").session).toMatchObject({
    lifecycle: "running",
  });

  for (const [correlation, sessionId] of [
    [1_502, firstId],
    [1_503, secondId],
  ] as const) {
    const released = await requestAction(
      reconnected.client,
      reconnected.revision!,
      correlation,
      "write",
      {
        session_id: sessionId,
        payload: { text: "\n" },
        lease: "use",
      },
    );
    expect(success(released, "write").accepted_bytes).toBe(1);
  }

  reconnected.client.send(
    encodeFrame(
      reconnected.revision!,
      1,
      actionSubjects.wait,
      507,
      {
        request: {
          wait: withAuthority("wait", {
            session_id: firstId,
            return_when: { exit: {} },
            safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
          }),
        },
      },
      1,
    ),
  );
  reconnected.client.send(
    encodeFrame(
      reconnected.revision!,
      1,
      actionSubjects.wait,
      508,
      {
        request: {
          wait: withAuthority("wait", {
            session_id: secondId,
            return_when: { exit: {} },
            safety_ceiling_ms: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
          }),
        },
      },
      1,
    ),
  );
  const responses = [
    await reconnected.client.read(),
    await reconnected.client.read(),
  ];
  expect(new Set(responses.map((response) => response.correlation))).toEqual(
    new Set([507, 508]),
  );
  for (const response of responses) {
    expect(success(response, "wait").outcome).toEqual({ exited: 0 });
  }

  const listed = await requestAction(
    reconnected.client,
    reconnected.revision!,
    509,
    "list",
    {},
  );
  const sessionIds = (
    success(listed, "list").sessions as Array<{ session_id: string }>
  ).map((session) => session.session_id);
  expect(sessionIds).toContain(firstId);
  expect(sessionIds).toContain(secondId);

  const screen = await requestAction(
    reconnected.client,
    reconnected.revision!,
    510,
    "screen",
    { session_id: firstId },
  );
  const screenValue = success(screen, "screen") as {
    snapshot: {
      dimensions: { rows: number; columns: number };
      cells: Array<{ kind: string; text: string }>;
    };
  };
  expect(screenValue.snapshot.dimensions).toEqual({ rows: 24, columns: 80 });
  expect(screenValue.snapshot.cells).toHaveLength(24 * 80);
  expect(screenValue.snapshot.cells.map((cell) => cell.text).join(""))
    .toContain("first-ready");
  const monitor = await requestAction(
    reconnected.client,
    reconnected.revision!,
    511,
    "monitor",
    {
      session_id: firstId,
      operation: { pause: "not-implemented" },
    },
  );
  expect(failure(monitor)).toMatchObject({
    action: "monitor",
    code: "invalid_request",
  });

  await requestAction(
    reconnected.client,
    reconnected.revision!,
    512,
    "close",
    { session_id: firstId, policy: "graceful" },
  );
  await requestAction(
    reconnected.client,
    reconnected.revision!,
    513,
    "close",
    { session_id: secondId, policy: "graceful" },
  );
  reconnected.client.close();
  host.kill("SIGKILL");
  await waitForExit(host);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 12 + 30_000);

test("host crash closes the liveness channel and kills the terminal process group", async () => {
  if (!existsSync("/bin/zsh")) return;
  const home = makeHome();
  const paths = hostPaths(home);
  const host = startHost(home, undefined, 10_000);
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const oldIdentity = readFileSync(paths.identity, "utf8");
  const connected = await handshake(paths.socket, { minimum: 4, current: 5 });
  const started = await startNativeCommandFixture(
    connected.client,
    connected.revision!,
    600,
    {
      cwd: home,
      command:
        "exec /bin/sh -c 'sleep 30 & child=$!; printf \"shell-pid:%s descendant-pid:%s\" \"$$\" \"$child\"; while :; do read line; done'",
      shell: {
        executable: { path: "/bin/zsh", clean_start: true },
      },
      returnWhen: { match: "descendant-pid:" },
      waitMs: TERMINAL_OPERATION_OBSERVATION_BUDGET_MS,
    },
  );
  const sessionId = (started.session as { session_id: string }).session_id;
  const output = (
    await readSession(
      connected.client,
      connected.revision!,
      601,
      sessionId,
    )
  ).output;
  const pids = output.match(/shell-pid:(\d+) descendant-pid:(\d+)/);
  expect(pids).not.toBeNull();
  const shellPid = Number(pids![1]);
  const descendantPid = Number(pids![2]);
  expect(processExists(shellPid)).toBe(true);
  expect(processExists(descendantPid)).toBe(true);

  host.kill("SIGKILL");
  await waitForExit(host);
  await waitFor(() => !processExists(shellPid), 3_000);
  await waitFor(() => !processExists(descendantPid), 3_000);
  connected.client.close();

  const replacement = startHost(home, undefined, 1_000);
  await waitFor(
    () =>
      existsSync(paths.identity) &&
      readFileSync(paths.identity, "utf8") !== oldIdentity,
    3_000,
  );
  const recovered = await handshake(paths.socket, { minimum: 4, current: 5 });
  const inspected = await requestAction(
    recovered.client,
    recovered.revision!,
    602,
    "inspect",
    { session_id: sessionId },
  );
  expect(success(inspected, "inspect").session).toMatchObject({
    lifecycle: "lost",
  });
  const durableRead = await readSession(
    recovered.client,
    recovered.revision!,
    603,
    sessionId,
  );
  expect(durableRead.output).toContain("shell-pid:");
  const durableScreen = await requestAction(
    recovered.client,
    recovered.revision!,
    604,
    "screen",
    { session_id: sessionId },
  );
  const recoveredSnapshot = success(durableScreen, "screen") as {
    snapshot: { cells: Array<{ text: string }> };
  };
  expect(recoveredSnapshot.snapshot.cells.map((cell) => cell.text).join(""))
    .toContain("shell-pid:");
  expect(directChildPids(replacement.pid!)).toEqual([]);
  recovered.client.close();
  expect(await waitForExit(replacement)).toBe(0);
  expect(existsSync(paths.socket)).toBe(false);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 2 + 30_000);

test("lazy private client starts once, reconnects, and leaves the host independent", async () => {
  const home = makeHome();
  const paths = hostPaths(home);

  const first = await runClientFixture(home, 700);
  expect(first).toEqual({
    exitCode: 0,
    stdout: '{"kind":"response","correlation":1,"code":"authority_denied"}\n',
    stderr: "",
  });
  await waitFor(() => existsSync(paths.identity));
  const identityBefore = readFileSync(paths.identity, "utf8");
  const hostPid = Number(
    (JSON.parse(identityBefore) as { pid: string }).pid,
  );
  hostPids.push(hostPid);
  expect(() => process.kill(hostPid, 0)).not.toThrow();

  const second = await runClientFixture(home, 700);
  expect(second.exitCode).toBe(0);
  expect(second.stderr).toBe("");
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);
  expect(() => process.kill(hostPid, 0)).not.toThrow();

  await waitFor(() => !existsSync(paths.socket), 2_000);
  expect(existsSync(paths.identity)).toBe(false);
  await waitFor(() => !processExists(hostPid), 2_000);
  expect(() => process.kill(hostPid, 0)).toThrow();
  hostPids.pop();
});

test("official short-lived clients preserve host-wide mutation order and inspect acknowledgement", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const barrier = join(home, "ordered-request");
  const result = await runClientFixture(home, 400, {
    FX_TERMINAL_OUTCOME_FIXTURE: "ordering",
    FX_TERMINAL_TEST_ORDER_BARRIER: barrier,
    FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION: "3",
    FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION_2: "7",
  });

  expect(result).toEqual({
    exitCode: 0,
    stdout: JSON.stringify({
      ordered: true,
      acknowledged: true,
      read_only_concurrent: true,
      cancelled_turn_abandoned: true,
    }) + "\n",
    stderr: "",
  });
  await waitFor(() => !existsSync(paths.identity), 2_000);
}, NATIVE_STARTUP_OBSERVATION_BUDGET_MS * 4 + 30_000);

test("official client retains every reserved outcome through the exact capacity boundary", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const result = await runClientFixture(home, 300, {
    FX_TERMINAL_OUTCOME_FIXTURE: "retention",
  });

  expect(result).toEqual({
    exitCode: 0,
    stdout: JSON.stringify({
      retained: 32,
      consumed: 32,
      boundary_rejected: true,
    }) + "\n",
    stderr: "",
  });
  await waitFor(() => !existsSync(paths.identity), 2_000);
}, 20_000);

test.each([
  "task_allocation",
  "worker_start",
  "result_allocation",
  "operation_execution",
  "response_encoding",
  "response_write",
])("accepted %s failure disconnects once and leaves later mutation progress", async (point) => {
  const home = makeHome();
  const paths = hostPaths(home);
  const result = await runClientFixture(home, 300, {
    FX_TERMINAL_OUTCOME_FIXTURE: "failure",
    FX_TERMINAL_TEST_HOST_FAILURE_POINT: point,
    FX_TERMINAL_TEST_HOST_FAILURE_CORRELATION: "1",
  });

  expect(result).toEqual({
    exitCode: 0,
    stdout: JSON.stringify({
      failure: point,
      first: "disconnected",
      later: "response",
    }) + "\n",
    stderr: "",
  });
  await waitFor(() => !existsSync(paths.identity), 2_000);
}, 15_000);

test("long profile homes use distinct private transport roots and retain durable ownership", async () => {
  const firstHome = makeLongHome(141);
  const secondHome = makeLongHome(142);
  const firstDurable = hostPaths(firstHome);
  const secondDurable = hostPaths(secondHome);
  const firstTransport = terminalTransportPaths(firstHome);
  const secondTransport = terminalTransportPaths(secondHome);

  expect(Buffer.byteLength(firstDurable.socket)).toBe(141);
  expect(Buffer.byteLength(secondDurable.socket)).toBe(142);
  expect(firstTransport.dir).not.toBe(firstDurable.dir);
  expect(secondTransport.dir).not.toBe(secondDurable.dir);
  expect(firstTransport.dir).not.toBe(secondTransport.dir);
  expect(Buffer.byteLength(firstTransport.socket)).toBeLessThan(
    process.platform === "darwin" ? 104 : 108,
  );

  const [first, second] = await Promise.all([
    runClientFixture(firstHome, 900),
    runClientFixture(secondHome, 900),
  ]);
  expect(first).toEqual({
    exitCode: 0,
    stdout: '{"kind":"response","correlation":1,"code":"authority_denied"}\n',
    stderr: "",
  });
  expect(second).toEqual(first);
  await waitFor(() =>
    existsSync(firstTransport.socket) &&
    existsSync(secondTransport.socket) &&
    existsSync(firstDurable.identity) &&
    existsSync(secondDurable.identity)
  );

  expect(existsSync(firstDurable.socket)).toBe(false);
  expect(existsSync(secondDurable.socket)).toBe(false);
  expect(statSync(firstTransport.dir).mode & 0o777).toBe(0o700);
  expect(statSync(firstTransport.socket).mode & 0o777).toBe(0o600);
  expect(readFileSync(firstDurable.identity, "utf8")).not.toBe(
    readFileSync(secondDurable.identity, "utf8"),
  );
  expect(readdirSync(firstTransport.dir).sort()).toEqual(["host.sock"]);
  expect(readdirSync(secondTransport.dir).sort()).toEqual(["host.sock"]);

  const firstIdentity = readFileSync(firstDurable.identity, "utf8");
  const reconnected = await runClientFixture(firstHome, 900);
  expect(reconnected).toEqual(first);
  expect(readFileSync(firstDurable.identity, "utf8")).toBe(firstIdentity);

  await waitFor(() =>
    !existsSync(firstTransport.socket) &&
    !existsSync(secondTransport.socket) &&
    !existsSync(firstDurable.identity) &&
    !existsSync(secondDurable.identity)
  , 3_000);
  expect(existsSync(firstDurable.lock)).toBe(true);
  expect(existsSync(secondDurable.lock)).toBe(true);
  expect(readdirSync(firstTransport.dir)).toEqual([]);
  expect(readdirSync(secondTransport.dir)).toEqual([]);
}, 15_000);

test("long-home transport roots reject symlink and non-private components without mutation", async () => {
  const symlinkHome = makeLongHome(141);
  const symlinkTransport = terminalTransportPaths(symlinkHome);
  const outside = mkdtempSync(join(tmpdir(), "fx-terminal-foreign-runtime-"));
  homes.push(outside);
  writeFileSync(join(outside, "host.sock"), "foreign");
  symlinkSync(outside, symlinkTransport.dir);

  expect(await runClientFixture(symlinkHome, 200)).toEqual({
    exitCode: 0,
    stdout: '{"kind":"disconnected","correlation":1}\n',
    stderr: "",
  });
  expect(readFileSync(join(outside, "host.sock"), "utf8")).toBe("foreign");
  expect(lstatSync(symlinkTransport.dir).isSymbolicLink()).toBe(true);

  const publicHome = makeLongHome(142);
  const publicTransport = terminalTransportPaths(publicHome);
  mkdirSync(publicTransport.dir, { mode: 0o755 });
  chmodSync(publicTransport.dir, 0o755);
  writeFileSync(join(publicTransport.dir, "foreign"), "retain");

  expect(await runClientFixture(publicHome, 200)).toEqual({
    exitCode: 0,
    stdout: '{"kind":"disconnected","correlation":1}\n',
    stderr: "",
  });
  expect(statSync(publicTransport.dir).mode & 0o777).toBe(0o755);
  expect(readFileSync(join(publicTransport.dir, "foreign"), "utf8")).toBe("retain");
  expect(existsSync(hostPaths(publicHome).identity)).toBe(false);
}, 10_000);

test.skipIf(!tmuxAvailable())(
  "long-home tmux survives host restart with transport-only runtime state",
  async () => {
    if (!existsSync("/bin/zsh")) return;
    const home = makeLongHome(141);
    const durable = hostPaths(home);
    const transport = terminalTransportPaths(home);
    const firstHost = startHost(home, undefined, 30_000);
    await waitFor(() => existsSync(transport.socket));
    const first = await handshake(transport.socket, { minimum: 4, current: 5 });
    const started = await startCommand(first.client, first.revision!, 701, {
      cwd: home,
      command:
        "printf 'long-tmux-ready\\n'; while IFS= read -r line; do printf 'long-tmux:%s\\n' \"$line\"; done",
      shell: { executable: { path: "/bin/zsh", clean_start: true } },
      backend: "tmux",
      returnWhen: { match: "long-tmux-ready" },
      waitMs: 8_000,
    });
    const sessionId = (started.session as { session_id: string }).session_id;
    const tmuxSocket = transport.tmuxSocket;
    await waitFor(() => existsSync(tmuxSocket));
    expect(statSync(tmuxSocket).mode & 0o777).toBe(0o600);
    expect(existsSync(join(durable.dir, "tmux.sock"))).toBe(false);
    expect(readdirSync(transport.dir).sort()).toEqual([
      "host.sock",
      "tmux.sock",
    ]);
    expect(
      readdirSync(durable.dir).some((name) => name.endsWith("-manifest.json")),
    ).toBe(true);
    expect(
      readdirSync(durable.dir).some((name) => name.endsWith("-lifecycle.bin")),
    ).toBe(true);

    const firstRead = await readSession(
      first.client,
      first.revision!,
      702,
      sessionId,
    );
    expect(firstRead.output).toContain("long-tmux-ready");
    const oldIdentity = readFileSync(durable.identity, "utf8");
    first.client.close();
    firstHost.kill("SIGKILL");
    await waitForExit(firstHost);
    expect(existsSync(tmuxSocket)).toBe(true);

    const replacement = startHost(home, undefined, 700);
    await waitFor(() =>
      existsSync(transport.socket) &&
      existsSync(durable.identity) &&
      readFileSync(durable.identity, "utf8") !== oldIdentity
    , 8_000);
    const recovered = await handshake(transport.socket, {
      minimum: 4,
      current: 5,
    });
    const inspected = success(
      await requestAction(recovered.client, recovered.revision!, 703, "inspect", {
        session_id: sessionId,
      }),
      "inspect",
    );
    expect(inspected.session).toMatchObject({
      lifecycle: "running",
      backend: "tmux",
    });
    const gapCursor = (inspected.session as {
      raw_gap?: { available_from: { segment: number; offset: number } };
    }).raw_gap?.available_from;
    expect(gapCursor).toBeDefined();
    success(
      await requestAction(recovered.client, recovered.revision!, 704, "write", {
        session_id: sessionId,
        payload: { text: "recovered\n" },
      }),
      "write",
    );
    success(
      await requestAction(recovered.client, recovered.revision!, 705, "wait", {
        session_id: sessionId,
        return_when: { match: "long-tmux:recovered" },
        safety_ceiling_ms: 5_000,
      }),
      "wait",
    );
    const recoveredRead = success(
      await requestAction(recovered.client, recovered.revision!, 706, "read", {
        session_id: sessionId,
        cursor: gapCursor,
      }),
      "read",
    ) as { output: string };
    expect(recoveredRead.output).toContain("long-tmux:recovered");
    success(
      await requestAction(recovered.client, recovered.revision!, 707, "close", {
        session_id: sessionId,
        policy: "force",
      }),
      "close",
    );
    await waitFor(() => !existsSync(tmuxSocket));
    recovered.client.close();
    expect(await waitForExit(replacement)).toBe(0);
    expect(existsSync(transport.socket)).toBe(false);
    expect(existsSync(durable.identity)).toBe(false);
    expect(readdirSync(transport.dir)).toEqual([]);
  },
  30_000,
);

test("fresh private client reloads owner-scoped authority without retaining proof", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const started = await runClientFixture(home, 700, {
    FX_TERMINAL_AUTHORITY_FIXTURE: "start",
  });
  expect(started.exitCode).toBe(0);
  expect(started.stderr).toBe("");
  expect(started.stdout.toLowerCase()).not.toContain("proof");
  expect(started.stdout.toLowerCase()).not.toContain("bytes");
  const startValue = JSON.parse(started.stdout) as {
    session_id: string;
    generation: number;
    minted: boolean;
  };
  expect(startValue).toEqual({
    session_id: expect.any(String),
    generation: 1,
    minted: true,
  });

  await waitFor(() => existsSync(paths.identity));
  const hostPid = Number(
    (JSON.parse(readFileSync(paths.identity, "utf8")) as { pid: string }).pid,
  );
  hostPids.push(hostPid);
  authorityBySession.clear();
  writeLeaseSessions.clear();

  const reloaded = await runClientFixture(home, 700, {
    FX_TERMINAL_AUTHORITY_FIXTURE: "reload",
    FX_TERMINAL_AUTHORITY_SESSION_ID: startValue.session_id,
  });
  expect(reloaded).toEqual({
    exitCode: 0,
    stdout: '{"read":true,"inspect":true,"closed":true}\n',
    stderr: "",
  });
  expect(reloaded.stdout.toLowerCase()).not.toContain("proof");
  expect(reloaded.stdout.toLowerCase()).not.toContain("bytes");
  await waitFor(() => directChildPids(hostPid).length === 0);
  await waitFor(() => !processExists(hostPid), 2_000);
  expect(existsSync(paths.socket)).toBe(false);
  hostPids.pop();
});

test("private client replaces an endpoint only after dead identity and free-lock proof", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const staleHost = startHost(home, { minimum: 4, current: 5 }, 5_000);
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const staleIdentity = readFileSync(paths.identity, "utf8");
  staleHost.kill("SIGKILL");
  await waitForExit(staleHost);
  expect(existsSync(paths.socket)).toBe(true);
  expect(existsSync(paths.identity)).toBe(true);

  const client = await runClientFixture(home, 500);
  expect(client.exitCode).toBe(0);
  expect(client.stderr).toBe("");
  await waitFor(() => existsSync(paths.identity));
  const replacementIdentity = readFileSync(paths.identity, "utf8");
  expect(replacementIdentity).not.toBe(staleIdentity);
  const replacementPid = Number(
    (JSON.parse(replacementIdentity) as { pid: string }).pid,
  );
  hostPids.push(replacementPid);
  expect(() => process.kill(replacementPid, 0)).not.toThrow();

  await waitFor(() => !existsSync(paths.socket), 2_000);
  await waitFor(() => !processExists(replacementPid), 2_000);
  expect(() => process.kill(replacementPid, 0)).toThrow();
  hostPids.pop();
});

test("current client rejects same revision host without complete signal capability before start", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const fixture = protocolFixtureDefinitions.signal_limited;
  const host = startHostWithAdvertisedProtocol(
    home,
    700,
    protocolFixtureEnv(fixture),
  );
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const identityBefore = readFileSync(paths.identity, "utf8");

  const rejected = await runClientFixture(home, 700, {
    FX_TERMINAL_CAPABILITY_FIXTURE: "start",
  });
  expect(rejected).toEqual({
    exitCode: 0,
    stdout: '{"kind":"unavailable","correlation":1,"missing_capabilities":16}\n',
    stderr: "",
  });
  expect(host.exitCode).toBeNull();
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);
  const terminalState = join(
    home,
    ".fx",
    "sessions",
    TERMINAL_OWNER_SESSION,
    "terminal",
    "state",
  );
  expect(
    existsSync(terminalState)
      ? readdirSync(terminalState).filter((name) => name.startsWith("record-"))
      : [],
  ).toEqual([]);

  expect(await waitForExit(host)).toBe(0);
});

test("current client permits graceful close and rejects force close on signal limited host", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const fixture = protocolFixtureDefinitions.signal_limited;
  const host = startHostWithAdvertisedProtocol(
    home,
    1_500,
    protocolFixtureEnv(fixture),
  );
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const identityBefore = readFileSync(paths.identity, "utf8");
  const previousClient = await handshake(
    paths.socket,
    fixture.range,
    fixture.capabilities,
    fixture.range.current,
  );
  const started = success(await requestAction(
    previousClient.client,
    previousClient.revision!,
    451,
    "start",
    {
      cwd: home,
      command: "printf 'authority-reload-ready\\n'; sleep 30",
      shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
      backend: "native",
      return_when: { match: "authority-reload-ready" },
      wait_ceiling_ms: 5_000,
      dimensions: { rows: 24, columns: 80 },
      initial_monitors: [],
    },
  ), "start");
  const sessionId = (started.session as { session_id: string }).session_id;
  previousClient.client.close();

  const forceRejected = await runClientFixture(home, 1_500, {
    FX_TERMINAL_CAPABILITY_FIXTURE: "force_close",
    FX_TERMINAL_AUTHORITY_FIXTURE_COMPAT: "1",
    FX_TERMINAL_AUTHORITY_SESSION_ID: sessionId,
  });
  expect(forceRejected).toEqual({
    exitCode: 0,
    stdout: '{"kind":"unavailable","correlation":1,"missing_capabilities":16}\n',
    stderr: "",
  });
  expect(durableTerminalRecordFor(home, sessionId)).toMatchObject({
    lifecycle: "running",
  });
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);

  const gracefulClosed = await runClientFixture(home, 1_500, {
    FX_TERMINAL_AUTHORITY_FIXTURE: "reload",
    FX_TERMINAL_AUTHORITY_FIXTURE_COMPAT: "1",
    FX_TERMINAL_AUTHORITY_SESSION_ID: sessionId,
  });
  expect(gracefulClosed).toEqual({
    exitCode: 0,
    stdout: '{"read":true,"inspect":true,"closed":true}\n',
    stderr: "",
  });
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);
  expect(await waitForExit(host)).toBe(0);
});

test("protocol fixtures advertise exact evidence and interoperate in both directions", async () => {
  const advertised: Record<string, unknown> = {};
  for (const [name, fixture] of Object.entries(protocolFixtureDefinitions)) {
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHostWithAdvertisedProtocol(
      home,
      300,
      protocolFixtureEnv(fixture),
    );
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
    const connected = await handshake(
      paths.socket,
      fixture.range,
      fixture.capabilities,
      fixture.range.current,
    );
    expect(connected.hostRange, name).toEqual(fixture.range);
    expect(connected.hostCapabilities, name).toBe(fixture.capabilities);
    advertised[name] = {
      range: connected.hostRange,
      capabilities: connected.hostCapabilities,
    };
    connected.client.close();
    expect(await waitForExit(host), name).toBe(0);
  }

  const directionEvidence: Array<Record<string, unknown>> = [];
  {
    const direction = "current client safe action to previous contract host";
    const previous = protocolFixtureDefinitions.previous;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHostWithAdvertisedProtocol(
      home,
      300,
      protocolFixtureEnv(previous),
    );
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
    const hostIdentity = readFileSync(paths.identity, "utf8");
    const inspected = await runClientFixture(home, 300);
    expect(inspected, direction).toEqual({
      exitCode: 0,
      stdout: '{"kind":"response","correlation":1,"code":"authority_denied"}\n',
      stderr: "",
    });
    expect(readFileSync(paths.identity, "utf8"), direction).toBe(hostIdentity);
    expect(await waitForExit(host), direction).toBe(0);
    directionEvidence.push({
      direction,
      client: "active_FX_BIN",
      host: "previous_contract",
      result: "safe_request_passed",
    });
  }

  {
    const direction = "previous contract client to current host";
    const previous = protocolFixtureDefinitions.previous;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHostWithAdvertisedProtocol(home, 700);
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
    const connected = await handshake(
      paths.socket,
      previous.range,
      previous.capabilities,
      previous.range.current,
    );
    expect(connected.revision, direction).toBe(4);
    const started = success(await requestAction(
      connected.client,
      connected.revision!,
      401,
      "start",
      {
        cwd: home,
        command: "printf 'compatibility-ready\\n'; sleep 30",
        shell: { executable: { path: TERMINAL_FIXTURE_SHELL, clean_start: true } },
        backend: "native",
        return_when: { match: "compatibility-ready" },
        wait_ceiling_ms: 5_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: [],
      },
    ), "start");
    const sessionId = (started.session as { session_id: string }).session_id;
    expect(success(await requestAction(
      connected.client,
      connected.revision!,
      402,
      "inspect",
      { session_id: sessionId },
    ), "inspect")).toMatchObject({ session: { session_id: sessionId } });
    success(await requestAction(
      connected.client,
      connected.revision!,
      403,
      "close",
      { session_id: sessionId, policy: "force" },
    ), "close");
    connected.client.close();
    expect(await waitForExit(host), direction).toBe(0);
    directionEvidence.push({
      direction,
      client: "previous_contract",
      host: "active_FX_BIN",
      result: "passed",
    });
  }

  {
    const direction = "current client to incompatible contract host";
    const incompatible = protocolFixtureDefinitions.incompatible;
    const current = protocolFixtureDefinitions.current_checkpoint;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHostWithAdvertisedProtocol(
      home,
      700,
      protocolFixtureEnv(incompatible),
    );
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
    const identityBefore = readFileSync(paths.identity, "utf8");
    const rejected = await runClientFixture(home, 700);
    expect(rejected.exitCode, direction).toBe(0);
    expect(rejected.stderr, direction).toBe("");
    expect(JSON.parse(rejected.stdout), direction).toMatchObject({
      kind: "unavailable",
      incompatibility: {
        reason: "revision_mismatch",
        client_range: current.range,
        host_range: incompatible.range,
      },
    });
    expect(host.exitCode, direction).toBeNull();
    expect(readFileSync(paths.identity, "utf8"), direction).toBe(
      identityBefore,
    );
    expect(await waitForExit(host), direction).toBe(0);
    directionEvidence.push({
      direction,
      result: "structured_rejection_identity_preserved",
    });
  }

  {
    const direction = "incompatible contract client to current host";
    const incompatible = protocolFixtureDefinitions.incompatible;
    const home = makeHome();
    const paths = hostPaths(home);
    const host = startHostWithAdvertisedProtocol(home, 700);
    await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
    const identityBefore = readFileSync(paths.identity, "utf8");
    const connected = await handshake(
      paths.socket,
      incompatible.range,
      incompatible.capabilities,
      incompatible.range.current,
    );
    expect(connected.revision, direction).toBeUndefined();
    expect(connected.hostRange, direction).toEqual(
      protocolFixtureDefinitions.current_checkpoint.range,
    );
    connected.client.close();
    expect(readFileSync(paths.identity, "utf8"), direction).toBe(identityBefore);
    expect(await waitForExit(host), direction).toBe(0);
    directionEvidence.push({
      direction,
      result: "revision_mismatch_identity_preserved",
    });
  }

  console.log("FX_TERMINAL_COMPATIBILITY_EVIDENCE " + JSON.stringify({
    fixtures: advertised,
    directions: directionEvidence,
    active_current: {
      source: "FX_BIN",
      digest: createHash("sha256").update(readFileSync(FX_BIN)).digest("hex"),
    },
  }));
}, 360_000);

test.each([
  {
    name: "new client to previous host",
    hostRange: { minimum: 4, current: 4 },
    clientRange: { minimum: 4, current: 5 },
    revision: 4,
    helloRevision: 4,
  },
  {
    name: "previous client to new host",
    hostRange: { minimum: 4, current: 5 },
    clientRange: { minimum: 4, current: 4 },
    revision: 4,
    helloRevision: 4,
  },
])("$name negotiates the highest shared revision", async ({
  hostRange,
  clientRange,
  revision,
  helloRevision,
}) => {
  const home = makeHome();
  const paths = hostPaths(home);
  const child = startHost(home, hostRange);
  await waitFor(() => existsSync(paths.socket));
  const connected = await handshake(paths.socket, clientRange);
  expect(connected.helloRevision).toBe(helloRevision);
  expect(connected.revision).toBe(revision);
  const response = await requestScreen(connected.client, revision, 88);
  expect(response.revision).toBe(revision);
  expect(response.correlation).toBe(88);
  expect(failure(response).code).toBe("protocol_incompatible");
  connected.client.close();
  expect(await waitForExit(child)).toBe(0);
  expect(await streamText(child.stderr)).toBe("");
});

test("incompatible live host is preserved and never replaced", async () => {
  const home = makeHome();
  const paths = hostPaths(home);
  const child = startHost(home, { minimum: 6, current: 6 }, 500);
  await waitFor(() => existsSync(paths.socket) && existsSync(paths.identity));
  const identityBefore = readFileSync(paths.identity, "utf8");

  const first = await handshake(paths.socket, { minimum: 4, current: 5 });
  expect(first.revision).toBeUndefined();
  expect(first.helloRevision).toBe(5);
  expect(first.hostRange).toEqual({ minimum: 6, current: 6 });
  first.client.close();
  const second = await handshake(paths.socket, { minimum: 4, current: 5 });
  expect(second.revision).toBeUndefined();
  expect(second.helloRevision).toBe(5);
  second.client.close();

  expect(child.exitCode).toBeNull();
  expect(readFileSync(paths.identity, "utf8")).toBe(identityBefore);
  expect(existsSync(paths.socket)).toBe(true);
  expect(await waitForExit(child)).toBe(0);
  expect(await streamText(child.stderr)).toBe("");
});
