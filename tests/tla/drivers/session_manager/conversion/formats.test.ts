// D61's converter behaviors through the real binary: older v1 formats,
// `--resume last`, the read-only `fx session`, `fx sessions convert`, the
// unreadable and slow-conversion messages, a crash's orphan child reused,
// and two processes converting one family. Every step that involves a
// request is observed and judged by TLC as in runtime.test.ts.
import { expect } from "bun:test";
import assert from "node:assert/strict";
import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, shellQuote } from "../../lib/context";
import {
  askAnswer, compareContinuations, convertAll, crashAtRename, fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall, familyReplies,
  makePrivate, observer, olderRelease, openVia, plainReplies, requireAccepted, scenario, TmuxSession, waitUntil, type Fixture,
} from "./driver";

// --- older v1 formats ----------------------------------------------------------

// Each format, the last release that wrote it, and that release's command
// tool: v0.3.16 began writing schema 3 (authority.json), v0.0.8 the current
// format. Legacy has no child registry, so only schema 3 has a family.
// v0.3.15 left the profile's folders readable by others (0755). v2 converts
// it as written, while current v1 reads only private profiles, so every v1
// reading of an older format (the observer's reference, the oracle's v1 side)
// runs on a private copy; `private` makes the observed profile itself 0700.
const LEGACY_RUN: [string, object] = ["run_command", { command: "seq 1 200000" }];
const SCHEMA3_RUN: [string, object] = ["terminal", { action: "exec", command: "seq 1 200000", timeout_ms: 600_000 }];
const FORMATS = [
  { name: "a legacy session with a side file", tag: "v0.3.15", family: false, marker: false, private: false, run: LEGACY_RUN },
  { name: "a legacy session with a side file, its folders private", tag: "v0.3.15", family: false, marker: false, private: true, run: LEGACY_RUN },
  { name: "a schema 3 session with a side file", tag: "v0.0.7", family: false, marker: true, private: false, run: SCHEMA3_RUN },
  { name: "a schema 3 family with a child", tag: "v0.0.7", family: true, marker: true, private: false, run: SCHEMA3_RUN },
];

// The older build's replies, with the tools that release had. A plain turn
// runs a command whose output v1 keeps as a side file; a family's parent
// creates the child "helper", waits for it to settle, and answers.
function olderReplies(f: Fixture, [tool, input]: [string, object]) {
  f.setRespond(body => {
    if (body.includes("conv-old-create")) {
      if (body.includes("conv-old-wait")) return fakeGatewayFinalText("CONV_PARENT_DONE");
      const child = /\\"child_id\\":\\"([^\\"]+)\\"/.exec(body)?.[1] ?? "missing-child";
      return fakeGatewayToolCall("conv-old-wait", "subagent", { command: { inspect: { id: child, sections: ["status"], wait: { until: "settled", timeout_ms: 20_000 } } } });
    }
    if (body.includes("Report the conversion marker.")) return fakeGatewayFinalText("CONV_CHILD_ANSWER");
    if (body.includes("CONV_FAMILY")) {
      return fakeGatewayToolCall("conv-old-create", "subagent", { command: { create: { name: "helper", mode: "persistent", prompt: "Report the conversion marker." } } });
    }
    if (body.includes("conv-old-run")) return fakeGatewayFinalText("CONV_FIRST_ANSWER");
    return fakeGatewayToolCall("conv-old-run", tool, input);
  });
}

for (const { name, tag, family, marker, private: hidden, run: command } of FORMATS) {
  scenario(`${name}, written by fx ${tag}, converts and the model sees the same`, async f => {
    const older = olderRelease(tag);
    olderReplies(f, command);
    const run = await f.fx(false, ["ask", "--json", "--auto", family ? "CONV_FAMILY" : "CONV_FIRST"], f.home, { FX_PERMISSION_MODE: "auto" }, older);
    assert.equal(run.code, 0, `fx ${tag} ask failed: ${run.stderr}${run.stdout}`);
    const ids = readdirSync(f.v1Root).filter(n => existsSync(join(f.v1Root, n, "session.json")));
    const id: string = JSON.parse(run.stdout).session_id ?? ids[0];
    const dir = join(f.v1Root, id);
    assert.equal(existsSync(join(dir, "authority.json")), marker, `fx ${tag} did not write the expected format: ${readdirSync(dir).join(", ")}`);
    // Legacy keeps a large result in tool-results/, schema 3 a command replay in logs/commands/.
    const sides = ["tool-results", "logs/commands"].filter(sub => existsSync(join(dir, sub)));
    assert(family ? ids.length > 1 : sides.length > 0, `fx ${tag} wrote no ${family ? "child" : "side file"}: ${ids.join(", ")}`);
    if (hidden) makePrivate(f.home);
    const o = observer(f, id, f.home, true);
    await o.observe("create");
    assert(!family || o.childId, `the observer found no child of the fx ${tag} family`);
    const snapshot = join(f.root, "snapshot");
    cpSync(f.home, snapshot, { recursive: true });
    await o.observe("list");
    plainReplies(f);
    await o.observe("open", await openVia(f, id, "ask"));
    await o.observe("list");
    Object.assign(o.content, await compareContinuations(f, snapshot, id, family, false, true, true));
    const label = `older-${tag}-${family ? "family" : "plain"}`;
    await requireAccepted(o, label);

    // Planted: one byte of a v2 blob the observer matched to v1's body is
    // changed, so the copy shows a body v1 never had; it must match no v1
    // version and TLC must refuse it. The blob is restored afterwards.
    const [blob] = o.matchedBlobs;
    assert(blob, "the observer matched no v2 blob to a v1 result body");
    const bytes = readFileSync(blob);
    chmodSync(blob, 0o600);
    try {
      bytes[bytes.length - 1] ^= 1;
      writeFileSync(blob, bytes);
      const planted = await o.observe("list");
      expect(planted.base[id]).toBe(-1);
      expect((await o.check(`${label}-planted`)).verdict).toBe("REJECTED");
    } finally {
      bytes[bytes.length - 1] ^= 1;
      writeFileSync(blob, bytes);
      chmodSync(blob, 0o400);
    }
  });
}

// --- a legacy reply over v1's event limit ---------------------------------------

// A reply over the 64 MiB one v1 event holds, which the real v0.3.15 writer
// keeps in session.json. Today's v1 cannot migrate the session, so it can
// neither open nor salvage it, and the new build refuses it with the reason
// and changes nothing (clause 5). No released writer leaves a legacy session
// over v1's 256 MiB automatic limit that v1 could migrate: legacy releases
// read at most 512 KiB to continue a session.
scenario("a legacy reply over the 64 MiB an event holds is refused with the reason and left as it was, as v1 cannot migrate it", async f => {
  const piece = "L".repeat(64 * 1024);
  f.setRespond(() => fakeGatewaySse([
    ...Array.from({ length: 70 * 16 }, () => ({ type: "text-delta", id: "answer_1", delta: piece })),
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } } },
  ]));
  const run = await f.fx(false, ["ask", "--json", "--auto", "CONV_FIRST"], f.home, {}, olderRelease("v0.3.15"));
  assert.equal(run.code, 0, `fx v0.3.15 ask failed: ${run.stderr}${run.stdout.slice(0, 300)}`);
  const id: string = JSON.parse(run.stdout).session_id;
  plainReplies(f);
  const premise = join(f.root, "v1-premise");
  cpSync(f.home, premise, { recursive: true });
  makePrivate(premise);
  const migrated = await f.fx(false, ["session", "migrate", id, "--allow-large", "--json"], premise);
  rmSync(premise, { recursive: true, force: true });
  assert.notEqual(migrated.code, 0, "today's v1 migrates the session, so the new build must open it");
  // v1's migration of it fails, so it is read without migrating.
  const o = observer(f, id, f.home, false);
  await o.observe("create");
  expect(await o.damage(id)).toBe("lost");
  await o.observe("damage");
  const before = f.fingerprint(id);
  await o.observe("open", await openVia(f, id, "ask"));
  expect(f.said).toMatch(/session\.json turn 1 has a field the current format can't keep/);
  expect(f.fingerprint(id)).toBe(before);
  await requireAccepted(o, "large-reply");
});

// --- a prompt that is not UTF-8 ---------------------------------------------------

// The one real such session, a test leftover a schema 3 build wrote, with its
// paths changed to /Users/example at their lengths and its state's hash redone.
// v1 shows it but can neither continue nor salvage it, so the new build shows
// it, refuses every open with the reason, and changes nothing (D66).
const NOT_UTF8 = "1784738825843-1784738825843707000-d16deab4f376c347";
scenario("a schema 3 session whose prompt is not UTF-8 is shown, refused with the reason, and left as v1 leaves it", async f => {
  mkdirSync(f.v1Root, { recursive: true });
  cpSync(join(import.meta.dir, "fixtures", NOT_UTF8), join(f.v1Root, NOT_UTF8), { recursive: true });
  makePrivate(f.home);
  // v1's migration refuses this session, which is why v1 cannot continue
  // it; v1 shows it as it is, so it is read without migrating.
  const o = observer(f, NOT_UTF8, f.home, false);
  await o.observe("create");
  expect(await o.damage(NOT_UTF8)).toBe("lost");
  await o.observe("damage");
  const v1Shown = await f.fx(false, ["session", NOT_UTF8, "--json"]);
  assert.equal(v1Shown.code, 0, `v1 no longer shows the session: ${v1Shown.stdout}`);
  const copy = join(f.root, "v1-continue");
  cpSync(f.home, copy, { recursive: true });
  const v1Continued = await f.fx(false, ["ask", "--json", "--auto", "--resume-id", NOT_UTF8, "CONV_NEXT"], copy);
  assert.notEqual(v1Continued.code, 0, "v1 continues the session, so the new build must too");
  const before = f.fingerprint(NOT_UTF8);
  const shown = await f.fx(true, ["session", NOT_UTF8, "--json"]);
  expect(shown.code).toBe(0);
  expect(JSON.parse(shown.stdout).history).toEqual(JSON.parse(v1Shown.stdout).history);
  for (const via of ["ask", "acp", "app"] as const) {
    await o.observe("open", await openVia(f, NOT_UTF8, via));
    expect(f.said).toMatch(/events\.jsonl turn 1 has a prompt that is not valid UTF-8/);
  }
  expect(f.fingerprint(NOT_UTF8)).toBe(before);
  await requireAccepted(o, "not-utf8");
});

// --- --resume last ----------------------------------------------------------------

// The session `--resume last` opened, by its id: fx ask's own JSON, or which
// session's first prompt the app shows as resumed.
async function resumeLast(f: Fixture, host: "ask" | "app", ids: { v1: string; v2: string }): Promise<string | null> {
  if (host === "ask") {
    const run = await f.fx(true, ["ask", "--json", "--auto", "--resume", "last", "CONV_NEXT"]);
    return run.code === 0 ? JSON.parse(run.stdout).session_id : null;
  }
  const app = await TmuxSession.create({ cmd: `${shellQuote(binary)} --resume last`, cwd: f.workspace, env: f.env(true), width: 120, height: 40 });
  f.apps.add(app);
  try {
    if (!(await waitUntil(async () => (await app.captureFullScrollback()).includes("session resumed"), 15_000))) return null;
    const screen = await app.captureFullScrollback();
    await app.sendText("CONV_NEXT");
    assert(await waitUntil(async () => (await app.captureFullScrollback()).includes("CONV_NEXT_ANSWER"), 15_000), "the resumed app never answered");
    await app.sendText("/quit");
    await app.waitForSessionEnd(10_000);
    return screen.includes("CONV_V2_FIRST") ? ids.v2 : screen.includes("CONV_FIRST") ? ids.v1 : null;
  } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
}

for (const host of ["ask", "app"] as const) {
  for (const newer of ["v1", "v2"] as const) {
    scenario(`--resume last in ${host} opens the newer session, here the ${newer} one`, async f => {
      plainReplies(f);
      const v1 = (await f.v1Ask(["CONV_FIRST"])).session_id;
      const o = observer(f, v1);
      await o.observe("create");
      await Bun.sleep(1_100);
      const created = await f.fx(true, ["ask", "--json", "--auto", "CONV_V2_FIRST"]);
      assert.equal(created.code, 0, `v2 ask failed: ${created.stderr}${created.stdout}`);
      const v2: string = JSON.parse(created.stdout).session_id;
      o.fresh(v2);
      await o.observe("fresh");
      if (newer === "v1") {
        await Bun.sleep(1_100);
        await f.v1Ask(["--resume-id", v1, "CONV_MORE"]);
        await o.observe("write");
      }
      const opened = await resumeLast(f, host, { v1, v2 });
      expect(opened, `--resume last opened ${opened}, not the newer ${newer} session`).toBe(newer === "v1" ? v1 : v2);
      if (newer === "v1") {
        await o.observe("open", "opened");
      } else {
        // Opening the v2 session is no request on the v1 root; the root is
        // then opened by id, the request TLC needs.
        await o.observe("fresh");
        await o.observe("open", await openVia(f, v1, "ask"));
      }
      await requireAccepted(o, `resume-last-${host}-${newer}`);
    });
  }
}

// --- fx session, read only ----------------------------------------------------

scenario("fx session shows an unconverted v1 session read-only, as v1 reads it", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  await f.v1Ask(["--resume-id", id, "CONV_MORE"]);
  const o = observer(f, id);
  await o.observe("create");
  const v1 = await f.fx(false, ["session", id, "--json"]);
  const v2 = await f.fx(true, ["session", id, "--json"]);
  writeFileSync(join(f.root, "session-detail.json"), JSON.stringify({ v1: v1.stdout, v2: v2.stdout, v2Stderr: v2.stderr }, null, 2));
  await o.observe("list");
  expect(v2.code, `fx session in v2 failed: ${v2.stderr}${v2.stdout}`).toBe(0);
  expect(JSON.parse(v2.stdout).history).toEqual(JSON.parse(v1.stdout).history);
  await o.observe("open", await openVia(f, id, "ask"));
  await requireAccepted(o, "session-read-only");
});

// --- fx sessions convert ----------------------------------------------------------

scenario("fx sessions convert converts a family, skips a busy and an unreadable session, and says so", async f => {
  familyReplies(f);
  const family = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  plainReplies(f);
  const busy = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const damaged = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const roots = [family, busy, damaged];
  const o = Object.fromEntries(roots.map(id => [id, observer(f, id)]));
  for (const id of roots) { o[id].others(roots.filter(other => other !== id)); await o[id].observe("create"); }
  assert(o[family].childId, "the v1 family has no child to convert");
  writeFileSync(join(f.v1Root, damaged, "session.json"), "{ not json");
  await o[damaged].damage(damaged);
  await o[damaged].observe("damage");
  f.setRespond(body => body.includes("CONV_HOLD")
    ? new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(": held\n\n")); } }), { headers: { "content-type": "text/event-stream" } })
    : fakeGatewayFinalText("CONV_NEXT_ANSWER"));
  const holder = f.start(false, ["ask", "--json", "--auto", "--resume-id", busy, "CONV_HOLD"], 120_000);
  assert(await waitUntil(() => f.gateway.requests.some((r: any) => r.body.includes("CONV_HOLD")), 15_000),
    "Owned fault boundary not reached: the older build never sent its held request");
  o[busy].hold([busy]);
  await o[busy].observe("hold");

  // JSON first: it converts the family; the text run after it has nothing
  // left to convert and skips the same two.
  const json = await convertAll(f, true);
  for (const id of roots) await o[id].observe("all", json.answer(id));
  const text = await convertAll(f, false);
  for (const id of roots) await o[id].observe("all", text.answer(id));
  holder.child.kill("SIGKILL");
  await holder.finished;

  const report = JSON.parse(json.run.stdout);
  expect(json.run.code).toBe(1);
  expect({ converted: report.converted, busy: report.busy, unreadable: report.unreadable }).toEqual({ converted: 1, busy: 1, unreadable: 1 });
  const skips = Object.fromEntries(report.skipped.map((s: any) => [s.id, s]));
  expect(skips[busy]?.error).toBe("SessionBusy");
  expect(skips[damaged]?.error).toBe("InvalidSessionFormat");
  expect(text.run.code).toBe(1);
  const [counts, ...lines] = text.run.stdout.trimEnd().split("\n");
  expect(counts).toBe("converted 0, busy 1, unreadable 1");
  expect(lines.sort()).toEqual([`${busy}: busy, open in another fx`, `${damaged}: unreadable: ${skips[damaged].reason}`].sort());
  expect(skips[damaged]?.reason).toMatch(/session\.json \S/);
  for (const id of roots) await requireAccepted(o[id], `convert-all-${id === family ? "family" : id === busy ? "busy" : "unreadable"}`);
});

// --- why a damaged session can't be converted -------------------------------------

scenario("a damaged session's error names the file and the reason in fx ask, ACP and the app", async f => {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  writeFileSync(join(f.v1Root, id, "session.json"), "{ not json");
  await o.damage(id);
  await o.observe("damage");
  const said: Record<string, string> = {};
  for (const via of ["ask", "acp", "app"] as const) {
    await o.observe("open", await openVia(f, id, via));
    said[via] = f.said;
  }
  writeFileSync(join(f.root, "damaged-errors.json"), JSON.stringify(said, null, 2));
  const named = (text: string) => ({ file: /session\.json \S/.test(text), code: text.includes("InvalidSessionFormat") });
  const all = { file: true, code: true };
  expect(Object.fromEntries(Object.entries(said).map(([via, text]) => [via, named(text)]))).toEqual({ ask: all, acp: all, app: all });
  await requireAccepted(o, "damaged-errors");
});

// --- the slow-conversion notice ---------------------------------------------

const NOTICE = "Converting this session from the previous session format";

// What the host showed of the notice: fx ask's stderr, ACP agent text
// updates, or the app's screen.
function notices(f: Fixture, via: "ask" | "acp" | "app") {
  if (via === "ask") return f.runs.at(-1)!.stderr;
  if (via === "app") return f.said;
  return JSON.stringify(JSON.parse(f.said).updates.filter((u: any) => u.sessionUpdate === "agent_message_chunk"));
}

for (const via of ["ask", "acp", "app"] as const) {
  scenario(`a conversion held 400 ms at its publish shows the slow notice in ${via}`, async f => {
    plainReplies(f);
    const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
    const o = observer(f, id);
    await o.observe("create");
    const fault = f.faultPaths("pause", [f.stagingPath(id)], 400);
    let answer;
    try { answer = await openVia(f, id, via); } finally { fault.stop(); }
    const shown = notices(f, via);
    writeFileSync(join(f.root, "notice.json"), JSON.stringify({ reached: fault.reached(), answer, shown }, null, 2));
    assert(fault.reached(), `Owned fault boundary not reached: the ${via} open never renamed the staged copy`);
    await o.observe("open", answer);
    expect(shown, `${via} showed no slow notice`).toContain(NOTICE);
    await requireAccepted(o, `slow-${via}`);
  });

  scenario(`control: a fast conversion in ${via} shows no slow notice`, async f => {
    plainReplies(f);
    const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
    const o = observer(f, id);
    await o.observe("create");
    const answer = await openVia(f, id, via);
    const shown = notices(f, via);
    writeFileSync(join(f.root, "notice.json"), JSON.stringify({ answer, shown }, null, 2));
    await o.observe("open", answer);
    expect(answer).toBe("opened");
    expect(shown).not.toContain(NOTICE);
    await requireAccepted(o, `fast-${via}`);
  });
}

// --- a crash's orphan child, changed since, reused ----------------------------------

scenario("a crash's published child is reused after an older build changed it, and its v1 folder stays", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  const child = o.childId;
  assert(child, "the v1 family has no child to convert");
  await crashAtRename(f, o, id, f.stagingPath(id));
  assert(existsSync(join(f.v2Root, child, "log.jsonl")) && !existsSync(join(f.v2Root, id, "log.jsonl")),
    "Owned fault boundary not reached: the crash did not leave the child published and the root unpublished");
  // The older build continues the parent, which messages the same child.
  f.setRespond(body => {
    if (body.includes("CONV_AGAIN")) {
      if (body.includes("CONV_CHILD_AGAIN")) return fakeGatewayFinalText("CONV_PARENT_AGAIN");
      return fakeGatewayToolCall("conv-again", "subagent", { request: { action: "message", agent: "helper", message: "Report it again." } });
    }
    return fakeGatewayFinalText(body.includes("Report it again.") ? "CONV_CHILD_AGAIN" : "CONV_NEXT_ANSWER");
  });
  const before = f.fingerprint(child);
  await f.v1Ask(["--resume-id", id, "CONV_AGAIN"]);
  assert.notEqual(f.fingerprint(child), before, "the older build did not change the child's v1 session");
  await o.observe("write");
  plainReplies(f);
  await o.observe("open", await openVia(f, id, "ask"));
  expect(existsSync(join(f.v1Root, child)), "the changed child's v1 folder was deleted").toBe(true);
  expect(existsSync(join(f.v1Root, id)), "the root's v1 folder stayed").toBe(false);
  await requireAccepted(o, "orphan-reused");
});

// --- two converters -----------------------------------------------------------------

scenario("two processes opening one v1 family at once convert it once", async f => {
  familyReplies(f);
  const id = (await f.v1Ask(["CONV_FAMILY"])).session_id;
  const o = observer(f, id);
  await o.observe("create");
  assert(o.childId, "the v1 family has no child to convert");
  // The first converter waits 300 ms at its root's publish holding the
  // family's locks, so the second meets them taken.
  const fault = f.faultPaths("pause", [f.stagingPath(id)], 300);
  const args = ["ask", "--json", "--auto", "--resume-id", id, "CONV_NEXT"];
  const [first, second] = [f.start(true, args), f.start(true, args)];
  const runs = await Promise.all([first.finished, second.finished]);
  fault.stop();
  const hits = fault.hits();
  writeFileSync(join(f.root, "open2.json"), JSON.stringify({ hits, runs: runs.map(r => ({ code: r.code, stdout: r.stdout, stderr: r.stderr })) }, null, 2));
  assert(hits.length > 0, "Owned fault boundary not reached: neither process published the root");
  await o.observe("open2", askAnswer(runs[0], id), false, askAnswer(runs[1], id));
  expect(hits.length, "both processes published the root").toBe(1);
  await requireAccepted(o, "open2");
});
