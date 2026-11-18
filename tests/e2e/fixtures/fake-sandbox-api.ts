// A fake Vercel Sandbox API for fx's sandbox tests. Each sandbox runs its
// commands on this machine with a clean environment; fx's `remote_root`
// setting keeps their files under one disk folder. It records what fx sent.
//
// The routes and answer shapes follow src/core/sandbox/api.zig, the builders
// and readers fx uses. Every request needs the bearer token and a `slug`
// query, as the real API requires.

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

type Tags = Record<string, string>;

export type FakeRoute =
  | "create"
  | "get"
  | "delete"
  | "list"
  | "cmd"
  | "kill"
  | "wait"
  | "write"
  | "read"
  | "snapshot"
  | "snapshotGet"
  | "stop";

export type FakeSandboxRecords = {
  creates: Array<Record<string, unknown>>;
  deletes: string[];
  commands: Array<{ sandbox: string; command: string; args: string[]; cwd: string; envNames: string[] }>;
  kills: string[];
  writes: Array<{ cwd: string; bytes: number }>;
  reads: string[];
  snapshots: string[];
};

export type FakeSandboxApi = {
  url: string;
  records: FakeSandboxRecords;
  /** Answers the next `times` requests for `route` with `status` and an error body. */
  fail(route: FakeRoute, status: number, times?: number): void;
  addSandbox(name: string, tags: Tags): void;
  sandboxes(): Array<{ name: string; status: string; tags: Tags; session: string }>;
  stop(): void;
};

type SandboxState = { name: string; session: string; tags: Tags; status: string };

type CommandInfo = {
  id: string;
  name: string;
  args: string[];
  cwd: string;
  sessionId: string;
  startedAt: number;
  exitCode: number | null;
};

type CommandState = {
  session: string;
  info: CommandInfo;
  process: ReturnType<typeof Bun.spawn>;
};

type CommandBody = {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  wait?: boolean;
  logs?: boolean;
};

const ROUTES: Array<[string, RegExp, FakeRoute]> = [
  ["POST", /^\/v2\/sandboxes$/, "create"],
  ["GET", /^\/v2\/sandboxes$/, "list"],
  ["GET", /^\/v2\/sandboxes\/snapshots\/([^/]+)$/, "snapshotGet"],
  ["GET", /^\/v2\/sandboxes\/([^/]+)$/, "get"],
  ["DELETE", /^\/v2\/sandboxes\/([^/]+)$/, "delete"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd$/, "cmd"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd\/([^/]+)\/kill$/, "kill"],
  ["GET", /^\/v2\/sandboxes\/sessions\/([^/]+)\/cmd\/([^/]+)$/, "wait"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/fs\/write$/, "write"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/fs\/read$/, "read"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/snapshot$/, "snapshot"],
  ["POST", /^\/v2\/sandboxes\/sessions\/([^/]+)\/stop$/, "stop"],
];

function jsonAnswer(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

function errorAnswer(code: string, message: string, status: number): Response {
  return jsonAnswer({ error: { code, message } }, status);
}

function matchRoute(method: string, path: string): { route: FakeRoute; params: string[] } | undefined {
  for (const [verb, pattern, route] of ROUTES) {
    if (verb !== method) continue;
    const match = pattern.exec(path);
    if (match) return { route, params: match.slice(1).map((part) => decodeURIComponent(part)) };
  }
  return undefined;
}

export function startFakeSandboxApi(options: { token: string; diskRoot: string }): FakeSandboxApi {
  const { token, diskRoot } = options;
  // A command's HOME is a folder under the disk root, never the developer's home.
  const home = join(diskRoot, "home");
  mkdirSync(home, { recursive: true });

  const records: FakeSandboxRecords = {
    creates: [],
    deletes: [],
    commands: [],
    kills: [],
    writes: [],
    reads: [],
    snapshots: [],
  };
  const byName = new Map<string, SandboxState>();
  const bySession = new Map<string, SandboxState>();
  const commands = new Map<string, CommandState>();
  const snapshots = new Set<string>();
  const failures = new Map<FakeRoute, { status: number; remaining: number }>();
  let sessionCount = 0;
  let commandCount = 0;
  let snapshotCount = 0;

  function register(name: string, tags: Tags): SandboxState {
    const sandbox: SandboxState = { name, session: `sbx_${++sessionCount}`, tags, status: "running" };
    byName.set(name, sandbox);
    bySession.set(sandbox.session, sandbox);
    return sandbox;
  }

  function view(sandbox: SandboxState) {
    return { name: sandbox.name, currentSessionId: sandbox.session, status: sandbox.status, tags: sandbox.tags };
  }

  function takeFailure(route: FakeRoute): number | undefined {
    const entry = failures.get(route);
    if (!entry || entry.remaining === 0) return undefined;
    entry.remaining -= 1;
    return entry.status;
  }

  // The ND-JSON answer of a waited command: the command first, then each
  // output chunk as it arrives, then the command again with its exit code.
  function streamOf(state: CommandState): ReadableStream<Uint8Array> {
    const encoder = new TextEncoder();
    let closed = false;
    return new ReadableStream<Uint8Array>({
      async start(controller) {
        const send = (value: unknown) => {
          if (!closed) controller.enqueue(encoder.encode(`${JSON.stringify(value)}\n`));
        };
        const pump = async (source: ReadableStream<Uint8Array>, stream: "stdout" | "stderr") => {
          const reader = source.getReader();
          const decoder = new TextDecoder();
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            const data = decoder.decode(value, { stream: true });
            if (data.length > 0) send({ data, stream });
          }
          const tail = decoder.decode();
          if (tail.length > 0) send({ data: tail, stream });
        };
        send({ command: { ...state.info } });
        await Promise.all([
          pump(state.process.stdout as ReadableStream<Uint8Array>, "stdout"),
          pump(state.process.stderr as ReadableStream<Uint8Array>, "stderr"),
        ]);
        state.info.exitCode = await state.process.exited;
        send({ command: { ...state.info } });
        closed = true;
        controller.close();
      },
      cancel() {
        // The client went away. The command keeps running until its sandbox is deleted or the fake stops.
        closed = true;
      },
    });
  }

  async function runCommand(sandbox: SandboxState, body: CommandBody): Promise<Response> {
    const args = body.args ?? [];
    const cwd = body.cwd ?? home;
    records.commands.push({
      sandbox: sandbox.name,
      command: body.command,
      args,
      cwd,
      envNames: Object.keys(body.env ?? {}),
    });
    // Only this list of names reaches the command, never this process's other variables.
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "",
      HOME: home,
      LANG: "C.UTF-8",
      ...(body.env ?? {}),
    };
    let child: ReturnType<typeof Bun.spawn>;
    try {
      child = Bun.spawn([body.command, ...args], { cwd, env, stdout: "pipe", stderr: "pipe" });
    } catch (error) {
      return errorAnswer("spawn_failed", `fake: ${String(error)}`, 422);
    }
    commandCount += 1;
    const info: CommandInfo = {
      id: `cmd_${commandCount}`,
      name: body.command,
      args,
      cwd,
      sessionId: sandbox.session,
      startedAt: Date.now(),
      exitCode: null,
    };
    const state: CommandState = { session: sandbox.session, info, process: child };
    commands.set(info.id, state);
    if (!body.wait) return jsonAnswer({ command: { ...info } });
    if (body.logs === false) {
      info.exitCode = await child.exited;
      return jsonAnswer({ command: { ...info } });
    }
    return new Response(streamOf(state), { headers: { "content-type": "application/x-ndjson" } });
  }

  async function handle(route: FakeRoute, params: string[], request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (route) {
      case "create": {
        const body = (await request.json()) as { name: string; tags?: Tags };
        if (byName.has(body.name)) return errorAnswer("conflict", "fake: a sandbox with this name exists", 409);
        return jsonAnswer({ sandbox: view(register(body.name, body.tags ?? {})) });
      }
      case "list": {
        const tag = url.searchParams.get("tags");
        const colon = tag?.indexOf(":") ?? -1;
        const key = tag === null ? undefined : colon < 0 ? tag : tag.slice(0, colon);
        const value = tag === null || colon < 0 ? undefined : tag.slice(colon + 1);
        const matching = [...byName.values()].filter((sandbox) => {
          if (key === undefined) return true;
          if (!(key in sandbox.tags)) return false;
          return value === undefined || sandbox.tags[key] === value;
        });
        return jsonAnswer({
          sandboxes: matching.map((sandbox) => ({ name: sandbox.name, status: sandbox.status, tags: sandbox.tags })),
          pagination: { count: matching.length, next: null },
        });
      }
      case "get": {
        const sandbox = byName.get(params[0]!);
        if (!sandbox) return errorAnswer("not_found", "fake: sandbox not found", 404);
        return jsonAnswer({ sandbox: view(sandbox) });
      }
      case "delete": {
        const sandbox = byName.get(params[0]!);
        if (!sandbox) return errorAnswer("not_found", "fake: sandbox not found", 404);
        for (const state of commands.values()) {
          if (state.session !== sandbox.session) continue;
          try {
            state.process.kill(15);
          } catch {
            // The command already exited.
          }
        }
        byName.delete(sandbox.name);
        bySession.delete(sandbox.session);
        records.deletes.push(sandbox.name);
        return jsonAnswer({});
      }
      case "cmd": {
        const sandbox = bySession.get(params[0]!);
        if (!sandbox) return errorAnswer("not_found", "fake: session not found", 404);
        return runCommand(sandbox, (await request.json()) as CommandBody);
      }
      case "kill": {
        const state = commands.get(params[1]!);
        if (!state || state.session !== params[0]) return errorAnswer("not_found", "fake: command not found", 404);
        const body = (await request.json().catch(() => ({}))) as { signal?: number };
        records.kills.push(params[1]!);
        try {
          state.process.kill(body.signal ?? 15);
        } catch {
          // The command already exited.
        }
        return jsonAnswer({ command: { ...state.info } });
      }
      case "wait": {
        const state = commands.get(params[1]!);
        if (!state || state.session !== params[0]) return errorAnswer("not_found", "fake: command not found", 404);
        state.info.exitCode = await state.process.exited;
        return jsonAnswer({ command: { ...state.info } });
      }
      case "write": {
        if (!bySession.has(params[0]!)) return errorAnswer("not_found", "fake: session not found", 404);
        const cwd = request.headers.get("x-cwd");
        if (!cwd) return errorAnswer("bad_request", "fake: x-cwd header required", 400);
        const bytes = new Uint8Array(await request.arrayBuffer());
        mkdirSync(cwd, { recursive: true });
        const tar = Bun.spawn(["tar", "-xzf", "-", "-C", cwd], { stdin: bytes, stdout: "ignore", stderr: "pipe" });
        const code = await tar.exited;
        if (code !== 0) return errorAnswer("extract_failed", `fake: tar exited ${code}`, 500);
        records.writes.push({ cwd, bytes: bytes.byteLength });
        return jsonAnswer({});
      }
      case "read": {
        if (!bySession.has(params[0]!)) return errorAnswer("not_found", "fake: session not found", 404);
        const body = (await request.json()) as { path: string };
        if (!existsSync(body.path)) return errorAnswer("not_found", "fake: file not found", 404);
        let bytes: Buffer;
        try {
          bytes = readFileSync(body.path);
        } catch {
          return errorAnswer("not_found", "fake: file not found", 404);
        }
        records.reads.push(body.path);
        return new Response(bytes, { headers: { "content-type": "application/octet-stream" } });
      }
      case "snapshot": {
        if (!bySession.has(params[0]!)) return errorAnswer("not_found", "fake: session not found", 404);
        snapshotCount += 1;
        const id = `snap_${snapshotCount}`;
        snapshots.add(id);
        records.snapshots.push(id);
        return jsonAnswer({ snapshot: { id } }, 201);
      }
      case "snapshotGet": {
        if (!snapshots.has(params[0]!)) return errorAnswer("not_found", "fake: snapshot not found", 404);
        return jsonAnswer({ snapshot: { id: params[0] } });
      }
      case "stop": {
        const sandbox = bySession.get(params[0]!);
        if (!sandbox) return errorAnswer("not_found", "fake: session not found", 404);
        sandbox.status = "stopped";
        return jsonAnswer({});
      }
    }
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (request.headers.get("authorization") !== `Bearer ${token}` || !url.searchParams.get("slug")) {
        return errorAnswer("forbidden", "fake: a bearer token and a team slug are required", 403);
      }
      const matched = matchRoute(request.method, url.pathname);
      if (!matched) return errorAnswer("not_found", "fake: no such route", 404);
      // Every create fx sends is recorded, including one the fake then refuses.
      if (matched.route === "create") records.creates.push((await request.clone().json()) as Record<string, unknown>);
      const failure = takeFailure(matched.route);
      if (failure !== undefined) return errorAnswer("fake", "fake failure", failure);
      return handle(matched.route, matched.params, request);
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    records,
    fail(route, status, times = 1) {
      failures.set(route, { status, remaining: times });
    },
    addSandbox(name, tags) {
      register(name, tags);
    },
    sandboxes() {
      return [...byName.values()].map((sandbox) => ({
        name: sandbox.name,
        status: sandbox.status,
        tags: sandbox.tags,
        session: sandbox.session,
      }));
    },
    stop() {
      for (const state of commands.values()) {
        try {
          state.process.kill(15);
        } catch {
          // The command already exited.
        }
      }
      server.stop(true);
    },
  };
}
