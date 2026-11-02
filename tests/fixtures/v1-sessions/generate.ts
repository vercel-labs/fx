// Rebuilds the v1 session fixtures that the converter's unit tests read
// (src/core/session/session_adapter.zig). Each kind is what the real v0.0.14
// release saved under ~/.fx, made through the conversion driver's release
// builder, fake gateway and recipes:
//
//   cd tests/fixtures/v1-sessions && bun generate.ts
//
// It replaces every <kind>/ folder, a copy of ~/.fx/sessions (v1's sessions)
// and ~/.fx/continue (what -c resumes), and manifest.json, which names each
// kind's session ids, root first, and the workspace they were saved in. Every
// kind is made in the same fixed home, so the paths v1 records stay the same.
// FX_FIXTURE_KINDS=a,b makes only those kinds and keeps the others as they
// are, folders and manifest entries.
process.env.FX_TLA_V1_WRITER ??= "v0.0.14";
process.env.FX_TLA_CASE ??= "v1-fixtures";

import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { shellQuote } from "../../tla/drivers/lib/context";
import {
  Acp, FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall, familyReplies, fixture, plainReplies, rememberInV1, TmuxSession,
  v1Writer, waitUntil, type Fixture,
} from "../../tla/drivers/session_manager/conversion/driver";
import { KINDS as CARRIED } from "../../tla/drivers/session_manager/conversion/recipes";

const out = dirname(new URL(import.meta.url).pathname);
const root = "/tmp/fx-v1-fixtures";

// The v1 sessions in the fixture's home, oldest first.
function sessionIds(f: Fixture): string[] {
  return readdirSync(f.v1Root)
    .filter(name => existsSync(join(f.v1Root, name, "session.json")))
    .map(name => ({ name, created: JSON.parse(readFileSync(join(f.v1Root, name, "session.json"), "utf8")).created_at_ms ?? 0 }))
    .sort((a, b) => a.created - b.created || a.name.localeCompare(b.name))
    .map(entry => entry.name);
}

// A reply that never finishes, for a turn the user cancels while it runs.
function stalledReply(): Response {
  const encoder = new TextEncoder();
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: "CONV_PARTIAL" })}\n\n`));
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

// The smallest PNG: one transparent pixel.
const pixel = Buffer.from("89504e470d0a1a0a0000000d4948445200000001000000010806000000" +
  "1f15c4890000000d49444154789c6360000002000154a24f5f0000000049454e44ae426082", "hex");

// Each kind: how v0.0.14 makes it, with the gateway's models when they are
// not the driver's. The ids come back root first.
type Kind = (f: Fixture) => Promise<string[]>;
const KINDS: Record<string, Kind | { models: object[]; make: Kind }> = {
  // Three roots of one turn each.
  plain: async f => {
    plainReplies(f);
    for (const n of [1, 2, 3]) await f.v1Ask([`CONV_FIRST ${n}`]);
    return sessionIds(f);
  },
  // A finished turn, then one the user cancels while its reply streams.
  cancelled: async f => {
    plainReplies(f);
    const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
    f.setRespond(body => (body.includes("CONV_MORE") ? stalledReply() : fakeGatewayFinalText("CONV_FIRST_ANSWER")));
    const app = await TmuxSession.create({ cmd: `${shellQuote(v1Writer())} --resume ${shellQuote(id)}`, cwd: f.workspace, env: f.env(false), width: 120, height: 40 });
    f.apps.add(app);
    try {
      await app.waitForComposer(15_000);
      await app.sendText("CONV_MORE");
      await app.waitForText("Generating", 15_000);
      await app.sendKeys("Escape");
      await app.waitForComposer(15_000);
      await app.sendText("/quit");
      await app.waitForSessionEnd(10_000);
    } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
    const events = readFileSync(join(f.v1Root, id, "events.jsonl"), "utf8");
    assert(events.includes("CONV_MORE") && events.includes("cancelled"), "v1 logged no cancelled turn");
    return [id];
  },
  // A root whose two turns each delegate to another child.
  family: async f => {
    familyReplies(f);
    const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
    f.setRespond(body => {
      if (body.includes("CONV_SECOND")) {
        if (body.includes("CONV_CHILD_ANSWER_2")) return fakeGatewayFinalText("CONV_PARENT_DONE_2");
        return fakeGatewayToolCall("conv-delegate-2", "subagent", { request: { action: "message", agent: "second", message: "Report the second marker." } });
      }
      if (body.includes("Report the second marker.")) return fakeGatewayFinalText("CONV_CHILD_ANSWER_2");
      return fakeGatewayFinalText("CONV_NEXT_ANSWER");
    });
    await f.v1Ask(["--resume-id", id, "CONV_SECOND"]);
    const ids = sessionIds(f);
    assert(ids.length === 3, `the v1 family has ${ids.length} sessions, not a root and two children`);
    return [id, ...ids.filter(other => other !== id)];
  },
  // A prompt with an image, which v1 keeps under images/. A model without
  // image input must look through the vision tool first.
  image: async f => {
    f.setRespond(body => {
      if (body.includes("conv-vision")) return fakeGatewayFinalText("CONV_FIRST_ANSWER");
      if (body.includes("CONV_FOCUS")) return fakeGatewayFinalText("CONV_IMAGE_SEEN");
      return fakeGatewayToolCall("conv-vision", "vision", { image_ids: [1], focus: "CONV_FOCUS" });
    });
    writeFileSync(join(f.workspace, "shot.png"), pixel);
    const id = (await f.v1Ask(["--image", join(f.workspace, "shot.png"), "CONV_FIRST look"])).session_id;
    assert(existsSync(join(f.v1Root, id, "images")), "v1 kept no prompt image");
    return [id];
  },
  // One prompt with twenty images, ids 1 to 20, which v1 keeps under
  // images/. A model with image input reads them without the vision tool.
  "many-images": {
    models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use", "vision", "file-input"] }],
    make: async f => {
      f.setRespond(() => fakeGatewayFinalText("CONV_IMAGES_SEEN"));
      const args = Array.from({ length: 20 }, (_, index) => {
        const path = join(f.workspace, `shot-${index + 1}.png`);
        writeFileSync(path, pixel);
        return ["--image", path];
      }).flat();
      const id = (await f.v1Ask([...args, "CONV_FIRST look at all"])).session_id;
      assert(readdirSync(join(f.v1Root, id, "images")).length === 20, "v1 kept fewer than twenty prompt images");
      return [id];
    },
  },
  // Two roots: the app last opened the first, which -c resumes, and the
  // second was saved after that, so it is the newest.
  remembered: async f => {
    plainReplies(f);
    const first = (await f.v1Ask(["CONV_FIRST remembered"])).session_id;
    await rememberInV1(f, first);
    const newest = (await f.v1Ask(["CONV_FIRST newest"])).session_id;
    return [first, newest];
  },
  // An ACP session that was never prompted.
  empty: async f => {
    const client = await Acp.start(f, false);
    try {
      const created = await client.request("session/new", { cwd: f.workspace, mcpServers: [] });
      assert(!created.error, `v1 ACP session/new failed: ${JSON.stringify(created.error)}`);
    } finally { client.close(); }
    await waitUntil(() => sessionIds(f).length === 1, 5_000);
    return sessionIds(f);
  },
  ...Object.fromEntries(["rules", "acp", "terminal"].map(kind => [kind, async (f: Fixture) => [(await CARRIED[kind].make(f)).id]])),
  // As the driver's `unfinished`: an open turn with its unfinished reply in
  // recovery.json, since compacting inside a turn logs the turn so far. A
  // small window lets a short reply compact.
  unfinished: {
    models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 16_000, max_tokens: 2_048 }],
    make: async f => {
      plainReplies(f);
      const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
      f.setRespond(body => {
        const request = JSON.parse(body);
        if (request.toolChoice?.type === "none" && request.tools?.length === 0) return fakeGatewayFinalText("CONV_SUMMARY");
        if (body.includes("<compacted_conversation>")) {
          return fakeGatewaySse([
            { type: "text-delta", id: "answer_1", delta: "CONV_PARTIAL_REPLY" },
            { type: "error", error: { code: "gateway_stream_timeout", message: "stream exceeded maximum duration" } },
            { type: "finish", finishReason: { unified: "error", raw: "gateway_stream_timeout" } },
          ]);
        }
        return fakeGatewaySse([
          { type: "text-delta", id: "answer_1", delta: "older narrative alpha beta gamma delta\n".repeat(2_000) },
          { type: "tool-call", toolCallId: "conv-stall-run", toolName: "shell", input: { request: { action: "run", command: "echo CONV_STALL_TOOL" } } },
          { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
        ]);
      });
      const stalled = f.start(false, ["ask", "--json", "--resume-id", id, "CONV_STALL"]);
      const recovery = join(f.v1Root, id, "recovery.json");
      const reached = await waitUntil(() => existsSync(recovery) && readFileSync(recovery, "utf8").includes("CONV_PARTIAL_REPLY"), 20_000);
      stalled.child.kill("SIGKILL");
      await stalled.finished;
      assert(reached && readFileSync(join(f.v1Root, id, "events.jsonl"), "utf8").includes("context_checkpoint"),
        "no open v1 turn with its unfinished reply in recovery.json");
      return [id];
    },
  },
  // As the driver's `side`, smaller: a command output past the 64 KiB inline
  // limit, its result in tool-results/ and its full output in logs/commands/.
  side: async f => {
    f.setRespond(body => (body.includes("conv-long-run")
      ? fakeGatewayFinalText("CONV_CALLS_DONE")
      : fakeGatewayToolCall("conv-long-run", "shell", { request: { action: "run", command: "seq 1 20000", yield_time_ms: 30_000 } })));
    const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
    for (const dir of ["tool-results", "logs/commands"]) {
      assert(readdirSync(join(f.v1Root, id, dir)).length === 1, `v1 kept no side file in ${dir}`);
    }
    return [id];
  },
};

const only = process.env.FX_FIXTURE_KINDS?.split(",").filter(Boolean);
const manifest: { writer: string; workspace: string; kinds: Record<string, string[]> } = only
  ? JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"))
  : { writer: process.env.FX_TLA_V1_WRITER, workspace: "", kinds: {} };
assert(manifest.writer === process.env.FX_TLA_V1_WRITER, `the other kinds were made by ${manifest.writer}`);
for (const name of only ?? []) assert(name in KINDS, `no fixture kind ${name}`);
for (const [kind, entry] of Object.entries(KINDS)) {
  if (only && !only.includes(kind)) continue;
  const { models, make } = typeof entry === "function" ? { models: undefined, make: entry } : entry;
  const f = fixture(kind, root, models);
  try {
    const ids = await make(f);
    const target = join(out, kind);
    rmSync(target, { recursive: true, force: true });
    mkdirSync(target);
    cpSync(f.v1Root, join(target, "sessions"), { recursive: true, filter: source => source !== join(f.v1Root, "v2") });
    const remembered = join(f.home, ".fx/continue");
    if (existsSync(remembered)) cpSync(remembered, join(target, "continue"), { recursive: true });
    manifest.kinds[kind] = ids;
    const workspace = realpathSync(f.workspace);
    assert(!only || manifest.workspace === workspace, `kind ${kind} was saved in ${workspace}, the others in ${manifest.workspace}`);
    manifest.workspace = workspace;
    console.log(`${kind}: ${ids.join(" ")}`);
  } finally { await f.finish(); }
}
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
rmSync(root, { recursive: true, force: true });
process.exit(0);
