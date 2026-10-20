#!/usr/bin/env bun
// Drives a session's UI stream on world-local along paths of the TLC state
// graph of UiStream.tla's local-takeover config, and checks after every step
// that the stream is in a state the model allows.
//
//   bun tests/tla/drivers/drive-uistream.mjs [--walks N] [--seed S] [--world-local <module>]
//
// Each walk keeps one session in a new folder and opens three Worlds over
// it, as three processes would: worker A's, worker B's and a reader's. They
// are the world-local libfx bundles, which this bundles first as packaging
// does, or with --world-local the createWorld() of the module named, such as
// world-local 5.1.1 from sdk/durable/node_modules. A worker writes each line
// through its agent's log of the session, as libfx's UI writer does, and the
// reader follows the stream through its own, from the start. Every chunk's
// landing waits at the file system call that puts the chunk in the stream
// until the walk lands it, so a write is on its way until then and a frozen
// worker's stays so; whatever the code does on its own before that call, such
// as naming the chunk, it does at once. A take is the next line the live
// reader gets. After each step the stream as a replay reads it and the lines
// the live reader took must be the model's.
//
// `tests/tla/sdk/check.sh` writes graphs/ui-local-takeover.dot from
// UiStream-local-takeover.cfg.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import fsp, { mkdtemp, readFile, rm } from "node:fs/promises";
import * as nodeModule from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createDurableAgentFactory } from "../../../sdk/durable.js";
import { world } from "../../../sdk/durable/world.mjs";
import { loadGraph, walkGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const walks = Number(option("walks", 40));
let seed = Number(option("seed", 1));
const worldLocal = option("world-local", null);
const verbose = args.includes("--verbose");
const here = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(here, "../../..");
const config = await readFile(resolve(here, "../sdk/UiStream-local-takeover.cfg"), "utf8");
if (!/^\s*Placement = "land"$/m.test(config)) throw new Error("UiStream-local-takeover.cfg must place a chunk where it lands");
const stepTimeoutMs = 5000;
const decoder = new TextDecoder();
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const within = (promise, what) => {
  let timer;
  return Promise.race([promise, new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error(`${what} took over ${stepTimeoutMs} ms`)), stepTimeoutMs); })]).finally(() => clearTimeout(timer));
};

// The World each role opens.
const scratch = [];
let open;
let label;
if (worldLocal) {
  const { createWorld } = await import(pathToFileURL(resolve(worldLocal)).href);
  open = (dir) => createWorld({ dataDir: dir, recoverActiveRuns: false });
  label = `world-local at ${worldLocal}`;
} else {
  const bundle = await mkdtemp(join(tmpdir(), "libfx-uistream-bundle-"));
  scratch.push(bundle);
  const bundled = spawnSync(process.execPath, [join(repoRoot, "sdk/scripts/bundle-durable.mjs"), bundle], { stdio: "inherit" });
  if (bundled.status !== 0) throw new Error("bundling the durability modules failed");
  const { local } = await import(pathToFileURL(join(bundle, "durable/local.mjs")).href);
  open = (dir) => local({ dir }).world();
  label = "libfx's bundled world-local";
}

// Each line is `{ line: "A1" }`, writer and number. A chunk lands when
// world-local renames it into place (5.1.1) or links it there (libfx's
// bundle); the first such call for a line waits for its gate.
const gates = new Map();
const isChunk = (path) => /[\\/]streams[\\/]chunks[\\/]/.test(String(path)) && /^chnk_[^\\/]*\.bin$/.test(String(path).split(/[\\/]/).at(-1));
const lineOf = (path) => {
  try {
    return JSON.parse(decoder.decode(readFileSync(path).subarray(1))).line ?? null;
  } catch {
    return null;
  }
};
for (const key of ["rename", "link"]) {
  const original = fsp[key];
  fsp[key] = async function (from, to, ...rest) {
    const gate = isChunk(to) ? gates.get(lineOf(from)) : undefined;
    if (gate && !gate.passed) {
      gate.passed = true;
      gate.reach();
      await gate.released;
    }
    return original.call(this, from, to, ...rest);
  };
}
nodeModule.syncBuiltinESMExports?.();

const createAgent = createDurableAgentFactory({
  harness: () => ({ open() { throw new Error("the driver runs no turn"); } }),
  defaultDurability: async () => { throw new Error("each agent here names its World"); },
  name: "createStreamDriveAgent",
});
const internals = Symbol.for("libfx.durableInternals");
// Landings of A's after B wrote, and after the reader had one of B's lines.
const late = { landed: 0, passed: 0 };

async function harness() {
  const problems = [];
  const dir = await mkdtemp(join(tmpdir(), "libfx-uistream-"));
  const roles = {};
  for (const role of ["A", "B", "R"]) {
    const instance = open(dir);
    await instance.start?.();
    roles[role] = { instance, agent: createAgent({ durability: world(instance, { name: "drive" }) }) };
  }
  const sessionId = await roles.A.agent.newSessionId();
  for (const role of Object.values(roles)) role.log = await role.agent[internals].openLog(sessionId);
  const uiStream = `${sessionId.replace(/^wrun_/, "strm_")}_user_bGliZngtdWk`;
  const pushed = { A: [], B: [] };
  const counts = { A: 0, B: 0 };
  const writes = { A: null, B: null };
  const taken = [];
  // The reader follows the stream from the start; each line it gets waits
  // here until a take.
  const arrived = [];
  let wake = null;
  const reader = roles.R.log.ui.read(0).getReader();
  const following = (async () => {
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ done: true }));
      if (done) return;
      for (const text of decoder.decode(value).split("\n").filter(Boolean)) arrived.push(JSON.parse(text).line);
      wake?.();
    }
  })();

  async function perform(act) {
    const [name, w, n] = act;
    switch (name) {
      case "Push":
        counts[w] += 1;
        pushed[w].push(`${w}${counts[w]}`);
        return;
      case "Write": {
        const line = pushed[w].shift();
        let reach;
        const reached = new Promise((done) => { reach = done; });
        let release;
        const released = new Promise((done) => { release = done; });
        gates.set(line, { reach, released, passed: false });
        const write = roles[w].log.ui.write([JSON.stringify({ line })]);
        writes[w] = { line, release, done: write };
        write.catch((error) => problems.push(`the write of ${line} failed: ${error?.message ?? error}`));
        // The write is on its way once its chunk waits to land.
        await within(Promise.race([reached, write]), `the write of ${line} reaching its landing`);
        return;
      }
      case "Land": {
        const write = writes[w];
        if (write?.line !== `${w}${n}`) throw new Error(`the model lands ${w}${n}, but ${w} has ${write?.line ?? "nothing"} on its way`);
        if (w === "A" && counts.B > 0 && pushed.B.length < counts.B) late.landed += 1;
        if (w === "A" && taken.some((line) => line.startsWith("B"))) late.passed += 1;
        write.release();
        await within(write.done, `the write of ${write.line}`);
        writes[w] = null;
        return;
      }
      case "Take": {
        const until = Date.now() + stepTimeoutMs;
        while (arrived.length === 0 && Date.now() < until) await Promise.race([new Promise((done) => { wake = done; }), sleep(50)]);
        if (arrived.length === 0) throw new Error("the live reader got no line");
        taken.push(arrived.shift());
        return;
      }
      // A freeze leaves A's write held, and a wake lets the walk land it.
      case "Freeze":
      case "Wake":
        return;
      default: throw new Error(`the driver cannot take ${name}`);
    }
  }

  async function settle() {
    const page = await roles.R.instance.streams.getChunks(sessionId, uiStream, { limit: 100 });
    const replay = page.data.map((chunk) => JSON.parse(decoder.decode(chunk.data)).line);
    for (const [index, line] of taken.entries()) {
      if (replay[index] !== line) problems.push(`the live reader's line ${index + 1} is ${line}, and a replay's is ${replay[index] ?? "missing"}`);
    }
    return { live: [...taken], replay };
  }

  async function close() {
    for (const write of Object.values(writes)) write?.release();
    await Promise.allSettled(Object.values(writes).map((write) => write?.done));
    await reader.cancel().catch(() => {});
    await following;
    for (const role of Object.values(roles)) {
      await role.agent.close().catch(() => {});
      await role.instance.close?.().catch(() => {});
    }
    gates.clear();
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }

  return { perform, settle, close, problems };
}

// ---------------------------------------------------------------------------
// Walks.

const graph = await loadGraph(resolve(here, "../sdk/graphs", "ui-local-takeover.dot"));
const labelOf = (chunk) => `${chunk.w}${chunk.n}`;
// The chunk's place is where it landed, so a replay reads them in landing order.
const view = (state) => JSON.stringify({ live: state.live.map(labelOf), replay: state.lands.map(labelOf) });
let result;
try {
  result = await walkGraph({
    graph,
    walks,
    random,
    verbose,
    // The code names a chunk on its own, again when another chunk took the
    // name it chose.
    autoActs: new Set(["Name"]),
    view,
    nameOf: (act) => act[0],
    sameAct: (a, b) => JSON.stringify(a) === JSON.stringify(b),
    label: (act) => `${act[0]}(${act.slice(1).join(",")})`,
    open: () => harness(),
  });
} finally {
  for (const dir of scratch) await rm(dir, { recursive: true, force: true }).catch(() => {});
}
if (!process.exitCode) console.log(`ok uistream: ${walks} walks, ${result.steps} steps matched the model; ${result.covered} of ${result.totalEdges} edges covered; A landed after B wrote ${late.landed} times, after the reader had B's line ${late.passed} times (${label})`);
process.exit(process.exitCode ?? 0);
