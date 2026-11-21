#!/usr/bin/env bun
// A fake of the standalone `sandbox` CLI (4.x) for tests of the default sandbox
// provider (src/core/sandbox/providers/vercel.sh). It runs every sandbox on this
// machine: sandbox NAME's files live in $FAKE_SANDBOX_HOME/fs/NAME, which the
// provider uses through its --remote-base option, and commands run with a
// minimal environment plus the --env values they were given.
//
// Every call appends one JSON line to $FAKE_SANDBOX_HOME/events.jsonl, so a
// test or a driver reads one ordered timeline: create, exec, start, exit,
// timeout, killsent, killed, rm, ls. Drivers append their own events (edit,
// stop, crash) to the same file.
//
// Test controls:
//   FAKE_SANDBOX_FAIL_CREATE=1      create fails
//   FAKE_SANDBOX_KILL_DELAY_MS=N    commands kill takes N ms to land
//   FAKE_SANDBOX_CREATE_DELAY_MS=N  create takes N ms
//
// An exit event that a kill or a removal caused carries `by` ("kill" or "rm").
//
// `fake-sandbox-cli.ts __daemon` runs the detached commands, the way a real
// sandbox runs them away from this machine: a test starts it before fx, so the
// commands are not in fx's process tree and fx's stop cannot reach them except
// through `commands kill`. Without a daemon, each `exec --detach` starts its own
// supervisor process.
import { spawn } from "node:child_process";
import {
  appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, readSync, rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const home = process.env.FAKE_SANDBOX_HOME;
if (!home) {
  console.error("FAKE_SANDBOX_HOME is not set");
  process.exit(2);
}
const fsRoot = join(home, "fs");
const boxes = join(home, "boxes");
const commands = join(home, "commands");
for (const dir of [fsRoot, boxes, commands]) mkdirSync(dir, { recursive: true });

function log(ev: string, fields: Record<string, unknown> = {}) {
  appendFileSync(join(home!, "events.jsonl"), `${JSON.stringify({ ev, ...fields, t: Date.now() })}\n`);
}

function fail(message: string, code = 1): never {
  console.error(`Error: ${message}`);
  process.exit(code);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const valueFlags = new Set([
  "--name", "--scope", "--team", "--project", "--token", "--timeout", "--workdir", "-w", "--env", "-e", "--tag", "-t",
  "--network-policy", "--allowed-domain", "--allowed-cidr", "--denied-cidr", "--name-prefix", "--signal", "--snapshot",
  "-s", "--image", "--vcpus", "--cursor", "--limit", "--sort-by", "--sort-order", "--region", "--expiration",
]);

type Parsed = { flags: Map<string, string[]>; bools: Set<string>; positional: string[]; rest: string[] };

function parse(args: string[]): Parsed {
  const parsed: Parsed = { flags: new Map(), bools: new Set(), positional: [], rest: [] };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--") {
      parsed.rest = args.slice(i + 1);
      break;
    }
    if (valueFlags.has(arg)) {
      const list = parsed.flags.get(arg) ?? [];
      list.push(args[++i] ?? "");
      parsed.flags.set(arg, list);
    } else if (arg.startsWith("-")) {
      parsed.bools.add(arg);
    } else {
      parsed.positional.push(arg);
    }
  }
  return parsed;
}

const flag = (p: Parsed, ...names: string[]) => names.flatMap((n) => p.flags.get(n) ?? []).at(-1);
const flags = (p: Parsed, ...names: string[]) => names.flatMap((n) => p.flags.get(n) ?? []);

function durationMs(text: string | undefined): number | null {
  if (!text) return null;
  const match = /^(\d+)(ms|s|m|h)$/.exec(text);
  if (!match) fail(`bad duration ${text}`);
  return Number(match[1]) * { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[match[2] as "ms" | "s" | "m" | "h"];
}

function box(name: string | undefined): string {
  if (!name || !existsSync(join(boxes, name))) fail(`Sandbox '${name}' not found`);
  return name;
}

function commandEnv(p: Parsed, name: string): Record<string, string> {
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: join(fsRoot, name, "home"),
    LANG: "C.UTF-8",
  };
  for (const pair of flags(p, "--env", "-e")) {
    const at = pair.indexOf("=");
    if (at > 0) env[pair.slice(0, at)] = pair.slice(at + 1);
  }
  return env;
}

const envNames = (p: Parsed) => flags(p, "--env", "-e").map((pair) => pair.split("=")[0]);

function signalCode(code: number | null, signal: NodeJS.Signals | null): number {
  if (code !== null) return code;
  return 128 + ({ SIGTERM: 15, SIGKILL: 9, SIGINT: 2 } as Record<string, number>)[signal ?? "SIGTERM"]!;
}

async function create(p: Parsed) {
  const name = flag(p, "--name") ?? `sbx-${Math.random().toString(16).slice(2, 10)}`;
  console.error("- Creating sandbox...");
  await sleep(Number(process.env.FAKE_SANDBOX_CREATE_DELAY_MS ?? "0"));
  if (process.env.FAKE_SANDBOX_FAIL_CREATE === "1") {
    log("createfail", { name });
    fail("the fake was told to fail create");
  }
  if (existsSync(join(boxes, name))) {
    fail(`A sandbox with the name '${name}' already exists for this project. Use GET /sandboxes/:name to resume it or delete it first.`);
  }
  mkdirSync(join(boxes, name), { recursive: true });
  mkdirSync(join(fsRoot, name, "home"), { recursive: true });
  const meta = {
    persistent: !p.bools.has("--non-persistent"),
    network: flag(p, "--network-policy") ?? (flags(p, "--allowed-domain").length ? "custom" : "allow-all"),
    allowed: flags(p, "--allowed-domain"),
    tags: flags(p, "--tag", "-t"),
  };
  writeFileSync(join(boxes, name, "meta.json"), JSON.stringify(meta));
  log("create", { name, ...meta });
  console.error(`✅ Sandbox ${name} created.`);
  console.log(name);
}

async function exec(p: Parsed) {
  const name = box(p.positional[0]);
  if (p.rest.length === 0) fail("No value provided for command");
  const cwd = flag(p, "--workdir", "-w") ?? join(fsRoot, name);
  if (!existsSync(cwd)) fail(`no such directory ${cwd}`);
  const env = commandEnv(p, name);
  const timeoutMs = durationMs(flag(p, "--timeout"));
  if (p.bools.has("--detach")) {
    const id = `cmd_${Math.random().toString(16).slice(2, 14)}`;
    mkdirSync(join(commands, id), { recursive: true });
    writeFileSync(join(commands, id, "spec.json"), JSON.stringify({ name, argv: p.rest, cwd, env, timeoutMs }));
    log("start", { name, id, env: envNames(p), argv: p.rest });
    if (!daemonAlive()) {
      const supervisor = spawn(process.execPath, [import.meta.filename, "__supervise", id], {
        detached: true, stdio: "ignore", env: { ...process.env },
      });
      supervisor.unref();
    }
    console.log(id);
    return;
  }
  log("exec", { name, stdin: p.bools.has("--stdin"), env: envNames(p), argv: p.rest });
  console.error(`$ ${p.rest.join(" ")}`);
  const child = spawn(p.rest[0], p.rest.slice(1), {
    cwd, env, stdio: [p.bools.has("--stdin") ? "inherit" : "ignore", "inherit", "inherit"],
  });
  let timer: Timer | undefined;
  if (timeoutMs !== null) timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
  const code = await new Promise<number>((resolve) => child.on("close", (c, s) => resolve(signalCode(c, s))));
  if (timer) clearTimeout(timer);
  process.exit(code);
}

function daemonAlive(): boolean {
  const file = join(home!, "daemon.pid");
  if (!existsSync(file)) return false;
  try {
    process.kill(Number(readFileSync(join(home!, "daemon.pid"), "utf8")), 0);
    return true;
  } catch {
    return false;
  }
}

async function daemon() {
  writeFileSync(join(home!, "daemon.pid"), String(process.pid));
  const running = new Set<string>();
  for (;;) {
    for (const id of readdirSync(commands)) {
      if (running.has(id) || !existsSync(join(commands, id, "spec.json")) || existsSync(join(commands, id, "claimed"))) continue;
      writeFileSync(join(commands, id, "claimed"), "");
      running.add(id);
      void runCommand(id);
    }
    await sleep(10);
  }
}

async function supervise(id: string) {
  await runCommand(id);
  process.exit(0);
}

async function runCommand(id: string) {
  const dir = join(commands, id);
  const spec = JSON.parse(readFileSync(join(dir, "spec.json"), "utf8"));
  const out = openSync(join(dir, "stdout"), "a");
  const err = openSync(join(dir, "stderr"), "a");
  const child = spawn(spec.argv[0], spec.argv.slice(1), { cwd: spec.cwd, env: spec.env, stdio: ["ignore", out, err], detached: true });
  writeFileSync(join(dir, "pid"), String(child.pid));
  let timedOut = false;
  const timer = spec.timeoutMs === null ? undefined : setTimeout(() => {
    timedOut = true;
    try { process.kill(-child.pid!, "SIGKILL"); } catch {}
  }, spec.timeoutMs);
  const code = await new Promise<number>((resolve) => child.on("close", (c, s) => resolve(signalCode(c, s))));
  if (timer) clearTimeout(timer);
  const by = existsSync(join(dir, "killed-by")) ? readFileSync(join(dir, "killed-by"), "utf8") : undefined;
  log(timedOut ? "timeout" : "exit", { name: spec.name, id, code, ...(by ? { by } : {}) });
  writeFileSync(join(dir, "exit"), String(code));
  closeSync(out);
  closeSync(err);
}

function command(p: Parsed): { name: string; id: string; dir: string } {
  const name = box(p.positional[0]);
  const id = p.positional[1];
  const dir = join(commands, id ?? "missing");
  if (!id || !existsSync(join(dir, "spec.json"))) fail(`command ${id} not found`);
  return { name, id, dir };
}

async function logs(p: Parsed) {
  const { dir } = command(p);
  const offsets = { stdout: 0, stderr: 0 };
  const drain = (stream: "stdout" | "stderr") => {
    const file = join(dir, stream);
    if (!existsSync(file)) return;
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(65536);
    for (;;) {
      const n = readSync(fd, buf, 0, buf.length, offsets[stream]);
      if (n <= 0) break;
      offsets[stream] += n;
      (stream === "stdout" ? process.stdout : process.stderr).write(buf.subarray(0, n));
    }
    closeSync(fd);
  };
  for (;;) {
    const done = existsSync(join(dir, "exit"));
    drain("stdout");
    drain("stderr");
    if (done) return;
    await sleep(20);
  }
}

async function wait(p: Parsed) {
  const { id, dir } = command(p);
  while (!existsSync(join(dir, "exit"))) await sleep(20);
  const code = Number(readFileSync(join(dir, "exit"), "utf8"));
  console.error(`Command ${id} exited with ${code}.`);
  process.exit(code);
}

async function kill(p: Parsed) {
  const { name, id, dir } = command(p);
  log("killsent", { name, id });
  await sleep(Number(process.env.FAKE_SANDBOX_KILL_DELAY_MS ?? "0"));
  const signal = (flag(p, "--signal") ?? "SIGTERM") as NodeJS.Signals;
  if (!existsSync(join(dir, "exit")) && existsSync(join(dir, "pid"))) {
    writeFileSync(join(dir, "killed-by"), "kill");
    try { process.kill(-Number(readFileSync(join(dir, "pid"), "utf8")), signal); } catch {}
  }
  log("killed", { name, id });
  console.error(`Sent ${signal} to command ${id}.`);
}

function killBoxCommands(name: string) {
  for (const id of readdirSync(commands)) {
    const dir = join(commands, id);
    if (existsSync(join(dir, "exit")) || !existsSync(join(dir, "pid"))) continue;
    const spec = JSON.parse(readFileSync(join(dir, "spec.json"), "utf8"));
    if (spec.name !== name) continue;
    writeFileSync(join(dir, "killed-by"), "rm");
    try { process.kill(-Number(readFileSync(join(dir, "pid"), "utf8")), "SIGKILL"); } catch {}
  }
}

async function main() {
  const [sub, ...args] = process.argv.slice(2);
  if (sub === "__supervise") return supervise(args[0]);
  if (sub === "__daemon") return daemon();
  if (sub === "commands") {
    const [what, ...rest] = args;
    const p = parse(rest);
    if (what === "logs") return logs(p);
    if (what === "wait") return wait(p);
    if (what === "kill") return kill(p);
    fail(`unknown commands subcommand ${what}`, 2);
  }
  const p = parse(args);
  switch (sub) {
    case "create": return create(p);
    case "exec": return exec(p);
    case "ls":
    case "list": {
      const prefix = flag(p, "--name-prefix") ?? "";
      console.error("- Fetching sandboxes...");
      console.log("NAME   STATUS");
      for (const name of readdirSync(boxes).sort()) if (name.startsWith(prefix)) console.log(`${name}   running`);
      log("ls", { prefix });
      return;
    }
    case "rm":
    case "remove": {
      let missing = false;
      for (const name of p.positional) {
        if (!existsSync(join(boxes, name))) { missing = true; continue; }
        killBoxCommands(name);
        rmSync(join(boxes, name), { recursive: true, force: true });
        rmSync(join(fsRoot, name), { recursive: true, force: true });
        log("rm", { name });
      }
      if (missing) fail("Sandbox not found");
      return;
    }
    case "stop":
      log("stop", { names: p.positional });
      return;
    default:
      fail(`the fake does not implement '${sub}'`, 2);
  }
}

await main();
