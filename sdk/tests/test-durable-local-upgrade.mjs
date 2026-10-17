#!/usr/bin/env node
// local() on a store an older libfx saved through @workflow/world-local
// 5.0.2, whose layout world-local 5.1 deletes when it opens a directory. The
// fixture is such a store, as libfx 0.0.13-dev.1470 left it.
//
// - DUR-23: the saved session keeps its history: stream(0) replays its turn,
//   and the next prompt reaches the model with the earlier one.
// - DUR-46: an old session id never opens an empty conversation.
// - DUR-78: when a file can't be moved, local() fails before it changes
//   anything, and every file is as it was.
//
//   node --experimental-wasm-jspi sdk/tests/test-durable-local-upgrade.mjs [native|wasm]
import { strict as assert } from "node:assert";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { local } from "../durable/local.mjs";

const engineBackend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = engineBackend === "wasm" ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) : undefined;
const fixture = JSON.parse(await readFile(resolve(scriptDir, "fixtures/world-local-5.0.2-store.json"), "utf8"));
const oldSession = fixture.sessionId;

// The model answers with the user messages it was sent, as JSON.
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const textOf = (message) => (typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join(""));
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "upgrade/model", type: "language", tags: [] }] }));
      return;
    }
    const users = JSON.parse(body).prompt.filter((message) => message.role === "user").map(textOf);
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const frame of [
      { type: "text-delta", id: "answer", delta: JSON.stringify(users) },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ]) response.write(`data: ${JSON.stringify(frame)}\n\n`);
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const { port } = server.address();
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  if (url.hostname === "ai-gateway.vercel.sh") return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  return fetch(input, init);
};
const agentAt = (dir) => createFxAgent({
  backend: engineBackend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "upgrade-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "upgrade/model",
  tools: [],
  durability: local({ dir }),
});

// What world-local prints, so a test can tell it deleted nothing.
const printed = [];
for (const level of ["warn", "error"]) {
  const original = console[level];
  console[level] = (...args) => {
    printed.push(args.map(String).join(" "));
    original(...args);
  };
}

const root = await mkdtemp(join(tmpdir(), "libfx-local-upgrade-"));
const writeFixture = async (dir, skip = () => false) => {
  for (const [path, bytes] of Object.entries(fixture.files)) {
    if (skip(path)) continue;
    await mkdir(dirname(join(dir, path)), { recursive: true });
    await writeFile(join(dir, path), Buffer.from(bytes, "base64"));
  }
};
// Every file under `dir`, by its path, with its bytes.
const filesUnder = async (dir) => Object.fromEntries(await Promise.all((await readdir(dir, { recursive: true, withFileTypes: true }))
  .filter((entry) => entry.isFile())
  .map(async (entry) => {
    const path = join(entry.parentPath, entry.name);
    return [relative(dir, path).split(sep).join("/"), (await readFile(path)).toString("base64")];
  })));
// Lines of a session's stream from `cursor` through its next turn_end.
async function linesThroughTurnEnd(stream) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const lines = [];
  let buffered = "";
  try {
    for (;;) {
      let timer;
      const quiet = new Promise((done) => { timer = setTimeout(() => done({ quiet: true }), 5000); });
      const next = await Promise.race([reader.read(), quiet]);
      clearTimeout(timer);
      if (next.quiet || next.done) return lines;
      buffered += decoder.decode(next.value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        const line = JSON.parse(buffered.slice(0, index));
        buffered = buffered.slice(index + 1);
        lines.push(line);
        if (line.type === "turn_end") return lines;
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
}
async function textOfTurn(turn) {
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  return { text, result: await turn.result };
}
// The old session's turn replays, and a new prompt continues it.
async function assertOldSessionContinues(agent, label) {
  const replay = await linesThroughTurnEnd(agent.session(oldSession).stream(0));
  assert.ok(replay.some((line) => line.type === "turn_start" && line.input === fixture.prompt), `${label}: stream(0) replays the saved turn: ${JSON.stringify(replay.map((line) => line.type))}`);
  assert.equal(replay.at(-1)?.type, "turn_end", `${label}: the saved turn ends`);
  const { text, result } = await textOfTurn(agent.session(oldSession).prompt("history"));
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(JSON.parse(text), [fixture.prompt, "history"], `${label}: the model gets the saved prompt before the new one`);
}
const assertNothingDeleted = (label) => assert.ok(!printed.some((line) => /Deleting local workflow data/.test(line)), `${label}: world-local deleted the store: ${printed.join("\n")}`);
const flatFiles = async (dir) => (await Promise.all(["events", "steps"].map(async (entity) => (await readdir(join(dir, entity), { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
  .map((entry) => `${entity}/${entry.name}`)))).flat();

try {
  // A store only 5.0.2 wrote.
  const oldFiles = Object.keys(fixture.files).filter((path) => /^(events|steps)\//.test(path));
  const upgraded = join(root, "upgraded");
  await writeFixture(upgraded);
  {
    const agent = agentAt(upgraded);
    try {
      await assertOldSessionContinues(agent, "after the upgrade");
      const fresh = await textOfTurn(agent.session().prompt("a new session"));
      assert.equal(fresh.result.stopReason, "end_turn");
    } finally {
      await agent.close();
    }
    assertNothingDeleted("after the upgrade");
    assert.deepEqual(await flatFiles(upgraded), [], "no file is left in the old layout");
    const now = await filesUnder(upgraded);
    for (const path of oldFiles) {
      const [entity, name] = path.split("/");
      assert.equal(now[`${entity}/${oldSession}/${name}`], fixture.files[path], `${path} moved into its run's folder unchanged`);
    }
  }
  console.log("an old store's session keeps its history after the upgrade");

  // The same store with one file in its run's folder already, as a move cut
  // short by a crash leaves it.
  const halfMoved = join(root, "half-moved");
  await writeFixture(halfMoved);
  const moved = oldFiles.find((path) => path.startsWith(`events/${oldSession}-`));
  await mkdir(join(halfMoved, "events", oldSession), { recursive: true });
  await writeFile(join(halfMoved, "events", oldSession, moved.slice("events/".length)), Buffer.from(fixture.files[moved], "base64"));
  {
    const agent = agentAt(halfMoved);
    try {
      await assertOldSessionContinues(agent, "after a move cut short");
    } finally {
      await agent.close();
    }
    assertNothingDeleted("after a move cut short");
    assert.deepEqual(await flatFiles(halfMoved), [], "no file is left in the old layout after a move cut short");
  }
  console.log("a move cut short finishes on the next start");

  // An older libfx wrote the old layout again into a store this libfx had
  // used, as a rollback does: world-local refuses such a mix of layouts, and
  // libfx moves the old files in.
  const rolledBack = join(root, "rolled-back");
  let newSession;
  {
    const agent = agentAt(rolledBack);
    try {
      const turn = agent.session().prompt("written by this libfx");
      newSession = (await turn.accepted).sessionId;
      assert.equal((await textOfTurn(turn)).result.stopReason, "end_turn");
    } finally {
      await agent.close();
    }
  }
  await writeFixture(rolledBack, (path) => path === "version.txt");
  {
    const agent = agentAt(rolledBack);
    try {
      await assertOldSessionContinues(agent, "after a rollback");
      const replay = await linesThroughTurnEnd(agent.session(newSession).stream(0));
      assert.ok(replay.some((line) => line.type === "turn_start" && line.input === "written by this libfx"), "the session this libfx wrote still replays");
    } finally {
      await agent.close();
    }
    assertNothingDeleted("after a rollback");
  }
  console.log("a store an older libfx wrote into again keeps every session");

  // One old file can't move: a different file has its name in the run's
  // folder. local() fails, says so, and leaves every file as it was.
  const blocked = join(root, "blocked");
  await writeFixture(blocked);
  const clash = Object.keys(fixture.files).find((path) => path.startsWith(`steps/${oldSession}-`));
  await mkdir(join(blocked, "steps", oldSession), { recursive: true });
  await writeFile(join(blocked, "steps", oldSession, clash.slice("steps/".length)), "{}\n");
  const before = await filesUnder(blocked);
  {
    const agent = agentAt(blocked);
    try {
      const turn = agent.session(oldSession).prompt("history");
      void turn.result.catch(() => {});
      await assert.rejects(turn.accepted, (error) => {
        assert.equal(error.code, "FX_LOCAL_STORE_LAYOUT");
        assert.match(error.message, /can't be moved into the layout this libfx reads/);
        assert.match(error.message, /Nothing was deleted/);
        assert.ok(error.message.includes(clash), error.message);
        assert.deepEqual(error.files, [clash]);
        return true;
      });
    } finally {
      await agent.close();
    }
  }
  assertNothingDeleted("with a file that can't move");
  assert.deepEqual(await filesUnder(blocked), before, "every file is as it was");
  console.log("a file that can't move stops local() and changes nothing");

  console.log(`local() upgrade tests passed on ${engineBackend}`);
} finally {
  server.close();
  await rm(root, { recursive: true, force: true });
}
