// Salvage of v1 sessions (D64) through the real binary, judged by TLC against
// tests/tla/session_manager/V1Conversion.tla: `fx session recover` on a v1 id
// answers as today's v1 recover answers, copies the same start into a fresh v2
// session when v1 salvages it, and never changes the v1 session. Each case's
// oracle is today's v1 writer's own recover on a private copy of the profile,
// for sessions in each format a v1 writer left.
import { expect } from "bun:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makePrivate, observer, olderRelease, plainReplies, requireAccepted, scenario, type Answer, type Fixture } from "./driver";

// Each format, and the release that wrote it: none for today's v1 writer.
// v0.3.15 starts a new session when asked to continue one, so its sessions
// have one turn.
const FORMATS = [
  { name: "the current format", tag: null, log: true, resumes: true },
  { name: "schema 3", tag: "v0.0.7", log: true, resumes: true },
  { name: "the legacy format", tag: "v0.3.15", log: false, resumes: false },
];

/// Replaces the `fromEnd`th complete line of the session's v1 event log
/// with one no reader decodes; the lines before it stay valid.
function breakLine(f: Fixture, id: string, fromEnd: number) {
  const path = join(f.v1Root, id, "events.jsonl");
  const lines = readFileSync(path, "utf8").split("\n");
  assert.equal(lines.at(-1), "", "the v1 event log does not end with a newline");
  const at = lines.length - 1 - fromEnd;
  assert(at > 0, "the v1 event log is too short to break");
  lines[at] = '{"broken":';
  writeFileSync(path, lines.join("\n"));
}

/// What `fx session recover --json` answered, from fx's own output.
function recoverAnswer(run: { code: number | null; stdout: string; stderr: string }): { ans: Answer; copy: string | null } {
  let json: any = null;
  try { json = JSON.parse(run.stdout); } catch { /* not JSON */ }
  if (run.code === 0 && typeof json?.recovered_id === "string") return { ans: "recovered", copy: json.recovered_id };
  const text = `${json?.error ?? ""} ${run.stdout} ${run.stderr}`;
  if (/RecoveryNotNeeded|not need/i.test(text)) return { ans: "healthy", copy: null };
  if (/SessionBusy|busy/i.test(text)) return { ans: "busy", copy: null };
  if (/SessionNotFound|not found/i.test(text)) return { ans: "notfound", copy: null };
  return { ans: "unsalvageable", copy: null };
}

/// Today's v1 recover of `id`, on a private copy of the profile: whether v1
/// opens the session, its answer, and when it salvaged, the copy's history.
async function v1Salvage(f: Fixture, id: string) {
  const copy = mkdtempSync(join(f.root, "v1-recover-"));
  try {
    cpSync(f.home, copy, { recursive: true });
    makePrivate(copy);
    const opened = await f.fx(false, ["session", id, "--json"], copy);
    const answer = recoverAnswer(await f.fx(false, ["session", "recover", id, "--json"], copy));
    const shown = answer.copy ? await f.fx(false, ["session", answer.copy, "--json"], copy) : null;
    return { opens: opened.code === 0, ans: answer.ans, history: shown ? JSON.parse(shown.stdout).history : null };
  } finally { rmSync(copy, { recursive: true, force: true }); }
}

/// A session of `prompts`, written by the release `tag` or today's v1 writer.
async function writeSession(f: Fixture, tag: string | null, prompts: string[]) {
  plainReplies(f);
  const bin = tag ? olderRelease(tag) : undefined;
  let id: string | null = null;
  for (const prompt of prompts) {
    const run = await f.fx(false, ["ask", "--json", "--auto", ...(id ? ["--resume-id", id] : []), prompt], f.home, {}, bin);
    assert.equal(run.code, 0, `fx ${tag ?? "v1"} ask failed: ${run.stderr}${run.stdout}`);
    const said = JSON.parse(run.stdout).session_id || readdirSync(f.v1Root).find(n => existsSync(join(f.v1Root, n, "session.json"))) || null;
    assert(!id || said === id, `fx ${tag ?? "v1"} did not continue ${id}, it wrote ${said}`);
    id ??= said;
  }
  assert(id, "the v1 writer left no session");
  return id;
}

/// Salvages `id` with the target and observes it: the answer, the copy as a
/// fresh session, and the v1 session left as it was.
async function salvage(f: Fixture, o: ReturnType<typeof observer>, id: string) {
  const before = f.fingerprint(id);
  const run = await f.fx(true, ["session", "recover", id, "--json"]);
  writeFileSync(join(f.root, "recover.json"), JSON.stringify(run, null, 2));
  const answer = recoverAnswer(run);
  const shown = answer.copy && existsSync(join(f.v2Root, answer.copy, "log.jsonl"))
    ? JSON.parse((await f.fx(true, ["session", answer.copy, "--json"])).stdout).history : null;
  if (answer.copy) o.salvaged(answer.copy, shown?.length ?? 0);
  await o.observe("recover", answer.ans);
  expect(f.fingerprint(id)).toBe(before);
  return { ...answer, history: shown };
}

for (const { name, tag, log, resumes } of FORMATS) {
  const turns = (prompts: string[]) => (resumes ? prompts : prompts.slice(0, 1));
  const label = tag ?? "current";
  const cases = [
    ...(log ? [{ what: "a broken line near the end of its event log", damage: (f: Fixture, id: string) => breakLine(f, id, 1) }] : []),
    { what: "a broken session.json", damage: (f: Fixture, id: string) => writeFileSync(join(f.v1Root, id, "session.json"), "{ not json") },
  ];
  for (const { what, damage } of cases) {
    scenario(`a v1 session in ${name} with ${what} is salvaged as today's v1 salvages it`, async f => {
      const id = await writeSession(f, tag, turns(["CONV_FIRST", "CONV_MORE", "CONV_LAST"]));
      const o = observer(f, id, f.home, tag !== null);
      await o.observe("create");
      damage(f, id);
      const kind = await o.damage(id);
      await o.observe("damage");
      const v1 = await v1Salvage(f, id);
      assert(!v1.opens, "today's v1 still opens the damaged session");
      if (!tag && log && what.startsWith("a broken line")) assert.equal(kind, "salvage", "today's v1 does not salvage this damage");
      const got = await salvage(f, o, id);
      await requireAccepted(o, `salvage-${label}-${kind}`);
      expect(got.ans).toBe(v1.ans);
      expect(JSON.stringify(got.history)).toBe(JSON.stringify(v1.history));
    });
  }

  // Today's v1 says no recovery is needed only in the current format; for
  // an older one it asked for `migrate` first, or copied a schema 3 session
  // and called the copy indeterminate. The session opens as it is, so the
  // new build says no recovery is needed (D64).
  scenario(`salvage of a healthy v1 session in ${name} says no recovery is needed and changes nothing`, async f => {
    const id = await writeSession(f, tag, turns(["CONV_FIRST", "CONV_MORE"]));
    const o = observer(f, id, f.home, tag !== null);
    await o.observe("create");
    const v1 = await v1Salvage(f, id);
    assert(v1.opens, "today's v1 does not open the healthy session");
    if (!tag) expect(v1.ans).toBe("healthy");
    const got = await salvage(f, o, id);
    await requireAccepted(o, `salvage-${label}-healthy`);
    expect(got.ans).toBe("healthy");
  });
}
