// ConfigEdit: the real `fx mcp add`, `remove` and `list --json`, each scenario
// in its own HOME and workspace, over the files the commands edit: the
// profile's ~/.fx/mcp.json and the workspace's .mcp.json. The harness records
// what it saw of each command (its outcome from fx's own words, whether the
// file's bytes changed) and what `list` loads, and checked against
// ConfigEdit.tla. A test named "guard:" holds on the code before the reader
// check. "fault:", "crash:" and "stress:" tests drive the same commands at the
// edges and past normal size, and are not checked by TLC.
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import { fixture, fxEnv, runFx, save, type Fixture, type Ran } from "./driver";
import { checkTrace, type TraceRecord, type Value } from "./trace";

type Cls = "ok" | "bad" | "auth";
type File = "profile" | "project";
const NAMES = ["a", "b", "c"];
const MODEL: Record<string, Value> = { ObsNames: NAMES, ObsClasses: ["ok", "bad", "auth"], ObsChecked: true, ObsKeyScan: "complete", ObsGuardRemove: true, ObsAtomic: true };

const OK_URL = "https://ok.example/mcp";
const BAD_URL = "http://example.com/mcp";
const entryOf = (cls: Cls) => ({
  type: "http",
  url: cls === "bad" ? BAD_URL : OK_URL,
  ...(cls === "auth" ? { headers: { Authorization: "Bearer abc" } } : {}),
});
const argsOf = (cls: Cls) => (cls === "bad" ? [BAD_URL] : cls === "auth" ? [OK_URL, "--header", "Authorization=Bearer abc"] : [OK_URL]);

/** The files before a scenario's first command, as the model describes them. */
interface Spec {
  st: "absent" | "ok" | "broken";
  ent?: Partial<Record<string, Cls>>;
  /** The profile's misspelled servers key: after the real one, after 70 other keys, or holding 64 entries that aren't servers first. */
  typo?: "key" | "last" | "wide";
  both?: boolean;
  /** Over 64 top-level keys, with no misspelled key. */
  big?: boolean;
}

const fillers = (count: number) => Object.fromEntries(Array.from({ length: count }, (_, i) => [`note${i}`, i]));

function documentOf(spec: Spec): Record<string, unknown> {
  const servers = Object.fromEntries(Object.entries(spec.ent ?? {}).map(([name, cls]) => [name, entryOf(cls!)]));
  const doc: Record<string, unknown> = {};
  if (spec.big || spec.typo === "last") Object.assign(doc, fillers(70));
  doc.mcpServers = servers;
  if (spec.both) doc.mcp = {};
  if (spec.typo === "key" || spec.typo === "last") doc.mcp_servers = { z: { command: "x" } };
  if (spec.typo === "wide") doc.servers = { ...Object.fromEntries(Array.from({ length: 64 }, (_, i) => [`n${i}`, i])), real: { command: "y" } };
  return doc;
}

const sha = (path: string) => (existsSync(path) ? createHash("sha256").update(readFileSync(path)).digest("hex") : "absent");

class Scenario {
  readonly f: Fixture;
  readonly records: TraceRecord[] = [];
  readonly paths: Record<File, string>;
  constructor(name: string, profile: Spec, project: Spec) {
    this.f = fixture(artifacts, name);
    this.paths = { profile: join(this.f.home, ".fx", "mcp.json"), project: join(this.f.workspace, ".mcp.json") };
    const model = (file: File, spec: Spec) => ({
      st: spec.st,
      typo: file === "profile" && !!spec.typo,
      both: file === "profile" && !!spec.both,
      big: file === "profile" && (!!spec.big || spec.typo === "last" || spec.typo === "wide"),
      ent: Object.fromEntries(NAMES.map((n) => [n, spec.ent?.[n] ?? "none"])),
    });
    for (const [file, spec] of [["profile", profile], ["project", project]] as const) {
      if (spec.st === "broken") writeFileSync(this.paths[file], "{ nope");
      if (spec.st === "ok") writeFileSync(this.paths[file], JSON.stringify(documentOf(spec)), { mode: file === "profile" ? 0o600 : 0o644 });
    }
    this.records.push({ event: "init", data: { profile: model("profile", profile), project: model("project", project) } });
  }

  run = (args: string[]): Promise<Ran> => runFx(binary, this.f, args, fxEnv(this.f), 60_000);

  async add(file: File, name: string, cls: Cls) {
    const before = sha(this.paths[file]);
    const ran = await this.run(["mcp", "add", "--no-login", ...(file === "project" ? ["--project"] : []), name, ...argsOf(cls)]);
    const outcome = ran.stdout.startsWith("Added ") ? "added" : ran.stderr.startsWith("Couldn't add ") ? "refused" : `unexpected: ${ran.stdout}${ran.stderr}`;
    expect(outcome === "added" ? ran.code === 0 : ran.code === 1).toBe(true);
    this.records.push({ event: "add", data: { file, name, class: cls, outcome, same: sha(this.paths[file]) === before } });
    return ran;
  }

  async remove(file: File, name: string) {
    const before = sha(this.paths[file]);
    const ran = await this.run(["mcp", "remove", file === "project" ? "--project" : "--global", name]);
    const outcome = ran.stdout.startsWith("Removed ") ? "removed" : ran.stderr.startsWith("Couldn't remove ") ? "refused" : ran.stderr.startsWith("No MCP server named ") ? "missing" : `unexpected: ${ran.stdout}${ran.stderr}`;
    expect(outcome === "removed" ? ran.code === 0 : ran.code === 1).toBe(true);
    this.records.push({ event: "remove", data: { file, name, outcome, same: sha(this.paths[file]) === before } });
    return ran;
  }

  async list(file: File) {
    const ran = await this.run(["mcp", "list", "--json"]);
    expect(ran.code).toBe(0);
    const servers = JSON.parse(ran.stdout).servers as { name: string; source: string }[];
    const loaded = servers.filter((s) => s.source === file && NAMES.includes(s.name)).map((s) => s.name).sort();
    this.records.push({ event: "list", data: { file, loaded } });
    return loaded;
  }

  /** The harness edits a file itself, as an editor would, without fx's lock. */
  tamper(kind: string, file: File, name = "a", cls: Cls = "ok") {
    const path = this.paths[file];
    // Only the kinds that edit a document read it; the others replace the file.
    const replaces = ["breaks", "repairs", "deletes"].includes(kind);
    const doc = !replaces && existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>) : {};
    const write = () => writeFileSync(path, JSON.stringify(doc));
    switch (kind) {
      case "typo_appears": doc.mcp_servers = { z: { command: "x" } }; write(); break;
      case "typo_fixed": for (const key of ["mcp_servers", "servers"]) delete doc[key]; write(); break;
      case "grows": Object.assign(doc, fillers(70)); write(); break;
      case "both_appear": doc.mcp = {}; write(); break;
      case "both_merged": delete doc.mcp; write(); break;
      case "hand": ((doc.mcpServers ??= {}) as Record<string, unknown>)[name] = entryOf(cls); write(); break;
      case "breaks": writeFileSync(path, "{ nope"); break;
      case "repairs": writeFileSync(path, "{}"); break;
      case "deletes": rmSync(path, { force: true }); break;
      default: throw new Error(`no tamper ${kind}`);
    }
    this.records.push({ event: "tamper", data: { kind, file, name, class: cls } });
  }

  async verify(): Promise<void> {
    const verdict = await checkTrace({ module: "ConfigEdit", records: this.records, dir: join(this.f.base, "trace"), constants: MODEL });
    save(join(this.f.base, "verdict.json"), verdict);
    expect(verdict.verdict).toBe("ACCEPTED");
  }
}

let pathFault: string | null = null;
/** tests/tla/drivers/lib/path-fault.c, built once per run: fails every rename inside a folder, and records each hit. */
function pathFaultLibrary(): string {
  if (pathFault) return pathFault;
  const library = join(artifacts, "path-fault.dylib");
  const built = Bun.spawnSync(["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", join(import.meta.dirname, "../lib/path-fault.c"), "-o", library]);
  if (built.exitCode !== 0) throw new Error(`building the path fault failed: ${built.stderr.toString()}`);
  return (pathFault = library);
}

const NONE: Spec = { st: "absent" };
const EMPTY: Spec = { st: "ok" };

test("guard: entries the reader loads go in and out of clean files, and a name already there is refused", async () => {
  const s = new Scenario("config-edit-clean", EMPTY, NONE);
  await s.add("profile", "a", "ok");
  await s.list("profile");
  await s.add("profile", "a", "ok");
  await s.add("project", "c", "auth");
  await s.list("project");
  await s.remove("profile", "a");
  await s.remove("profile", "a");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("guard: a profile that isn't JSON, or has both keys, refuses an add and finds nothing to remove, until it is fixed", async () => {
  const s = new Scenario("config-edit-unreadable", { st: "broken" }, EMPTY);
  await s.add("profile", "a", "ok");
  await s.remove("profile", "a");
  s.tamper("repairs", "profile");
  await s.add("profile", "a", "ok");
  s.tamper("both_appear", "profile");
  await s.add("profile", "b", "ok");
  await s.remove("profile", "a");
  s.tamper("both_merged", "profile");
  await s.add("profile", "b", "ok");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("guard: an entry the reader skips, already in the file, doesn't stop an add, and a big profile without a misspelled key is edited", async () => {
  const s = new Scenario("config-edit-hand", { st: "ok", ent: { a: "bad" } }, NONE);
  await s.list("profile");
  s.tamper("grows", "profile");
  await s.add("profile", "b", "ok");
  await s.list("profile");
  await s.remove("profile", "a");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("the profile refuses an entry the reader skips and one only .mcp.json loads; .mcp.json refuses only the first", async () => {
  const s = new Scenario("config-edit-refuses", NONE, NONE);
  await s.add("profile", "a", "bad");
  await s.add("profile", "b", "auth");
  await s.add("profile", "c", "ok");
  await s.list("profile");
  await s.add("project", "a", "bad");
  await s.add("project", "b", "auth");
  await s.list("project");
  await s.verify();
}, 240_000);

test("a profile whose servers key looks misspelled is never rewritten by add or remove, and .mcp.json is not affected", async () => {
  const s = new Scenario("config-edit-typo", { st: "ok", ent: { a: "ok" }, typo: "key" }, EMPTY);
  await s.add("profile", "b", "ok");
  await s.remove("profile", "a");
  await s.add("project", "b", "ok");
  s.tamper("typo_fixed", "profile");
  await s.add("profile", "b", "ok");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("a misspelled key that appears between two commands, with no lock taken, is found by the next one", async () => {
  const s = new Scenario("config-edit-typo-between", { st: "ok", ent: { a: "ok" } }, NONE);
  await s.add("profile", "b", "ok");
  s.tamper("typo_appears", "profile");
  await s.add("profile", "c", "ok");
  await s.remove("profile", "b");
  s.tamper("typo_fixed", "profile");
  await s.remove("profile", "b");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("a misspelled key after 70 others is found, though fx's load scan gives up on that file", async () => {
  const s = new Scenario("config-edit-typo-last", { st: "ok", ent: { a: "ok" }, typo: "last" }, NONE);
  await s.add("profile", "b", "ok");
  await s.remove("profile", "a");
  s.tamper("typo_fixed", "profile");
  await s.add("profile", "b", "ok");
  await s.list("profile");
  await s.verify();
}, 240_000);

test("a misspelled key whose first 64 entries aren't servers is found", async () => {
  const s = new Scenario("config-edit-typo-wide", { st: "ok", ent: { a: "ok" }, typo: "wide" }, NONE);
  await s.add("profile", "b", "ok");
  await s.remove("profile", "a");
  s.tamper("typo_fixed", "profile");
  await s.add("profile", "b", "ok");
  await s.list("profile");
  await s.verify();
}, 240_000);

// ---- edges ----

test("fault: add and remove fail cleanly when the project folder is read-only, or the file is past the read limit", async () => {
  const s = new Scenario("config-edit-fault", { st: "ok", ent: { a: "ok" } }, { st: "ok", ent: { a: "ok" } });
  const before = sha(s.paths.project);

  // The workspace folder is read-only: the project file can't be replaced. (fx makes ~/.fx private again itself, so only .mcp.json shows this.)
  chmodSync(s.f.workspace, 0o500);
  try {
    const add = await s.run(["mcp", "add", "--no-login", "--project", "web", OK_URL]);
    expect(add.code).toBe(1);
    expect(add.stderr).toStartWith("Couldn't add web to .mcp.json: ");
    const remove = await s.run(["mcp", "remove", "--project", "a"]);
    expect(remove.code).toBe(1);
    expect(remove.stderr).toStartWith("Couldn't remove a from .mcp.json: ");
  } finally {
    chmodSync(s.f.workspace, 0o700);
  }
  expect(sha(s.paths.project)).toBe(before);

  // A profile past the 1 MiB read limit is refused by name, not rewritten.
  writeFileSync(s.paths.profile, JSON.stringify({ mcpServers: {}, pad: "x".repeat(1_100_000) }));
  const large = sha(s.paths.profile);
  const tooBig = await s.run(["mcp", "add", "--no-login", "web", OK_URL]);
  expect(tooBig.code).toBe(1);
  expect(tooBig.stderr).toStartWith("Couldn't add web to ~/.fx/mcp.json: ");
  expect(sha(s.paths.profile)).toBe(large);
}, 240_000);

// The shim is built with macOS calls (F_GETPATH, renameatx_np), so this runs on macOS only; CI's TLA job is Linux.
test.skipIf(process.platform !== "darwin")("fault: a write the system refuses leaves the profile as it was, and an entry the reader skips never reaches the write", async () => {
  const s = new Scenario("config-edit-refused-write", { st: "ok", ent: { a: "ok" } }, NONE);
  const folder = realpathSync(join(s.f.home, ".fx"));
  const arm = join(s.f.base, "armed");
  const record = join(s.f.base, "hits.txt");
  writeFileSync(arm, "armed");
  const env = { ...fxEnv(s.f), DYLD_INSERT_LIBRARIES: pathFaultLibrary(), FX_PATH_FAULT_MODE: "refuse", FX_PATH_FAULT_ARM: arm, FX_PATH_FAULT_RECORD: record, FX_PATH_FAULT_TARGETS: folder };
  const hits = () => (existsSync(record) ? readFileSync(record, "utf8").split("\n").filter(Boolean).length : 0);
  const before = sha(s.paths.profile);

  const refused = await runFx(binary, s.f, ["mcp", "add", "--no-login", "web", OK_URL], env, 60_000);
  expect(refused.code).toBe(1);
  expect(refused.stderr).toStartWith("Couldn't add web to ~/.fx/mcp.json: ");
  expect(sha(s.paths.profile)).toBe(before);
  const reached = hits();
  expect(reached).toBeGreaterThan(0);

  // An entry the reader skips is refused before the write, so the system's refusal is never reached.
  const skipped = await runFx(binary, s.f, ["mcp", "add", "--no-login", "web2", BAD_URL], env, 60_000);
  expect(skipped.code).toBe(1);
  expect(sha(s.paths.profile)).toBe(before);
  expect(hits()).toBe(reached);
}, 240_000);

test("fault: twenty fx processes adding at once each keep their entry, and the entries the reader would skip are never written", async () => {
  const s = new Scenario("config-edit-parallel", EMPTY, NONE);
  const names = Array.from({ length: 20 }, (_, i) => `p${i}`);
  const ran = await Promise.all(names.map((name) => s.run(["mcp", "add", "--no-login", name, ...argsOf("ok")])));
  expect(ran.map((r) => r.code)).toEqual(names.map(() => 0));
  const saved = Object.keys(JSON.parse(readFileSync(s.paths.profile, "utf8")).mcpServers).sort();
  expect(saved).toEqual([...names].sort());

  // Half of them are entries the reader skips: those are refused, whatever the order the processes take the lock in.
  const mixed = await Promise.all(names.map((name, i) => s.run(["mcp", "add", "--no-login", `m${i}`, ...argsOf(i % 2 === 0 ? "ok" : "bad")])));
  const after = Object.keys(JSON.parse(readFileSync(s.paths.profile, "utf8")).mcpServers);
  expect(after.filter((n) => n.startsWith("m") && Number(n.slice(1)) % 2 === 1)).toEqual([]);
  expect(mixed.filter((r, i) => i % 2 === 0).map((r) => r.code)).toEqual(names.filter((_, i) => i % 2 === 0).map(() => 0));
  save(join(s.f.base, "parallel.json"), mixed.map((r) => ({ code: r.code, ms: r.ms })));
}, 240_000);

test("crash: a kill at any moment of an add leaves the profile as it was or as the add made it, and the next fx takes the lock", async () => {
  const s = new Scenario("config-edit-crash", { st: "ok", ent: { a: "ok" } }, NONE);
  // Seeded, so a failure replays: the kill delays come from this generator.
  let state = 20261110;
  const next = () => ((state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 2 ** 32);
  const log: { i: number; cls: string; delayMs: number; exited: number | null }[] = [];
  let kills = 0;
  for (let i = 0; i < 40; i++) {
    const cls: Cls = i % 2 === 0 ? "ok" : "bad";
    const before = readFileSync(s.paths.profile, "utf8");
    const child = Bun.spawn([binary, "mcp", "add", "--no-login", `k${i}`, ...argsOf(cls)], { cwd: s.f.workspace, env: fxEnv(s.f), stdin: "ignore", stdout: "ignore", stderr: "ignore" });
    const delayMs = Math.floor(next() * 120);
    await Bun.sleep(delayMs);
    child.kill("SIGKILL");
    const code = await child.exited;
    if (code !== 0) kills += 1;
    log.push({ i, cls, delayMs, exited: code });
    const text = readFileSync(s.paths.profile, "utf8");
    const doc = JSON.parse(text) as { mcpServers: Record<string, unknown> };
    const names = Object.keys(doc.mcpServers);
    // Whole file: the old bytes, or the old entries and this one.
    if (text !== before) expect(names.filter((n) => n !== `k${i}` && !before.includes(`"${n}"`))).toEqual([]);
    // An entry the reader skips is never there, killed or not.
    expect(names.filter((n) => n.startsWith("k") && Number(n.slice(1)) % 2 === 1)).toEqual([]);
  }
  save(join(s.f.base, "kills.json"), { seed: 20261110, kills, log });
  const next1 = await s.run(["mcp", "add", "--no-login", "after", OK_URL]);
  expect(next1.code).toBe(0);
  expect(Object.keys(JSON.parse(readFileSync(s.paths.profile, "utf8")).mcpServers)).toContain("after");
}, 600_000);

test("stress: add and remove on a profile with 1,000 servers stay fast, and the profile keeps every server", async () => {
  const servers = Object.fromEntries(Array.from({ length: 1000 }, (_, i) => [`s${i}`, { type: "http", url: `https://s${i}.example/mcp` }]));
  const s = new Scenario("config-edit-stress", NONE, NONE);
  mkdirSync(join(s.f.home, ".fx"), { recursive: true });
  writeFileSync(s.paths.profile, JSON.stringify({ mcpServers: servers }), { mode: 0o600 });
  const timings: Record<string, number> = {};
  const add = await s.run(["mcp", "add", "--no-login", "new", OK_URL]);
  timings.add_ms = add.ms;
  expect(add.code).toBe(0);
  const refused = await s.run(["mcp", "add", "--no-login", "bad", BAD_URL]);
  timings.refused_add_ms = refused.ms;
  const remove = await s.run(["mcp", "remove", "--global", "s500"]);
  timings.remove_ms = remove.ms;
  expect(remove.code).toBe(0);
  const list = await s.run(["mcp", "list", "--json"]);
  timings.list_ms = list.ms;
  const names = (JSON.parse(list.stdout).servers as { name: string }[]).map((x) => x.name);
  expect(names.length).toBe(1000);
  expect(names).toContain("new");
  expect(names).not.toContain("s500");
  save(join(s.f.base, "timings.json"), timings);
  console.log(`STRESS servers=1000 ${Object.entries(timings).map(([k, v]) => `${k}=${v}`).join(" ")}`);
  // Parsing the file a few times per command must stay far inside a second or two on a busy machine.
  for (const [what, ms] of Object.entries(timings)) expect({ what, ok: ms < 8000 }).toEqual({ what, ok: true });
}, 240_000);
