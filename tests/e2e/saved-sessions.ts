// What fx saved in a test's home: the public view a later fx gives, and the
// store's own files for tests about the disk itself.
import { expect } from "bun:test";
import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

/// A saved session as `fx session --id <id> --json` shows it, whatever the
/// store keeps on disk.
export type SavedSession = {
  kind: "session_detail";
  id: string;
  created_at_ms: number;
  updated_at_ms: number;
  history_len: number;
  conversation_language: string;
  history: any[];
};

/// Reads session `id` through the built fx, as a resume would find it.
export async function savedSession(home: string, id: string): Promise<SavedSession> {
  const result = await runFx(["session", "--id", id, "--json"], {
    cwd: home,
    env: { HOME: home, FX_SOUND: "0", FX_AUTO_UPGRADE: "0" },
  });
  if (result.code !== 0) throw new Error(`fx session --id ${id} exited ${result.code}: ${result.stderr}`);
  return JSON.parse(result.stdout);
}

/// The folder holding every saved session.
export function storeRoot(home: string): string {
  return join(home, ".fx", "sessions", "v2");
}

/// One session's folder.
export function sessionDir(home: string, id: string): string {
  return join(storeRoot(home), id);
}

/// Everything a session saved, its log and every blob, as one text: for
/// checking what it kept or never kept, wherever the store put it.
export function savedText(home: string, id: string): string {
  const dir = sessionDir(home, id);
  const blobs = join(dir, "blobs");
  return [readFileSync(join(dir, "log.jsonl"), "utf8"), ...readdirSync(blobs).map((name) => readFileSync(join(blobs, name), "utf8"))].join("\n");
}

export type LogLine = { seq: number; kind: string; type?: string; reason?: string; key?: string };

/// Every complete line of a session's log. A line fx is still appending is
/// left out, so a test may read the log while fx runs.
function readLog(home: string, id: string): LogLine[] {
  const text = readFileSync(join(sessionDir(home, id), "log.jsonl"), "utf8");
  return text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

/// Every line of a session's log. A streamed turn always matches its
/// commit, so no turn is ever superseded.
export function logLines(home: string, id: string): LogLine[] {
  const lines = readLog(home, id);
  expect(lines.filter((line) => line.type === "superseded")).toEqual([]);
  return lines;
}

/// Every saved session's id, children included.
export function savedSessionIds(home: string): string[] {
  return readdirSync(storeRoot(home)).filter((name) => !name.startsWith(".") && !name.startsWith("index"));
}

/// The id of the one saved session.
export function onlySessionId(home: string): string {
  const ids = savedSessionIds(home);
  expect(ids.length).toBe(1);
  return ids[0]!;
}

/// Saved root sessions: a child's folder sits beside its parent's, and its
/// log's first line names its role.
export function rootSessionIds(home: string): string[] {
  return savedSessionIds(home).filter((id) => {
    const first = readFileSync(join(sessionDir(home, id), "log.jsonl"), "utf8").split("\n", 1)[0]!;
    return JSON.parse(first).role !== "child";
  });
}

/// The parent's lines about its children, with fx's data parsed.
export function childLines(home: string, id: string): any[] {
  return (readLog(home, id) as any[])
    .filter((line) => line.kind === "child_spawned" || line.kind === "child_finished")
    .map((line) => ({ ...line, data: typeof line.data === "string" ? JSON.parse(line.data) : line.data }));
}

/// The newest work a parent's log records for its only child: the spawn,
/// and its finish once there is one.
export function childWork(home: string, parent: string) {
  const lines = childLines(home, parent);
  const spawned = lines.filter((line) => line.kind === "child_spawned");
  const current = spawned.at(-1);
  const finished = current ? lines.find((line) => line.kind === "child_finished" && line.work_id === current.work_id) : undefined;
  return { spawns: spawned.length, child: current?.child, work: current?.work_id, outcome: finished?.outcome ?? null };
}

/// The blob of the compactor record `name` (D50): the newest
/// `compaction_records` line names the blob mapping record names to blobs.
export function compactionRecordPath(home: string, id: string, name: string): string | undefined {
  const line = (readLog(home, id) as any[]).filter((l) => l.kind === "set" && l.key === "compaction_records").at(-1);
  if (!line) return undefined;
  expect(line.blobs).toContain(line.value.map);
  const blobs = join(sessionDir(home, id), "blobs");
  const hash = JSON.parse(readFileSync(join(blobs, line.value.map), "utf8"))[name];
  return hash ? join(blobs, hash) : undefined;
}

/// The command replays session `id` kept: each is one of its blobs, named in
/// the session by its handle, `fx-command-replay-<run>-<hash>.bin` (D44, D91).
/// A handle from before D91 has no run id.
export function commandReplays(home: string, id: string): { name: string; path: string }[] {
  const names = [...new Set(savedText(home, id).match(commandReplayHandles) ?? [])];
  return names.map((name) => ({ name, path: join(sessionDir(home, id), "blobs", commandReplayHash(name)) }));
}

const commandReplayHandles = /fx-command-replay-(?:[0-9a-f]{12}-)?[0-9a-f]{64}\.bin/g;

/// The hash of the blob a command replay handle names, which comes last.
export function commandReplayHash(handle: string): string {
  return /([0-9a-f]{64})\.bin$/.exec(handle)![1]!;
}

/// Every tool call a saved history holds, finished or left open by an
/// interrupted turn, by id.
export function savedToolCallIds(history: any[]): string[] {
  return history.flatMap((turn) => [
    ...(turn.execution?.tool_steps ?? []).flatMap((step: any) => (step.tool_calls ?? []).map((call: any) => call.id)),
    ...(turn.tool_call ? [turn.tool_call.id] : []),
  ]);
}

/// Every tool result a saved history holds, in order.
export function savedToolResults(history: any[]): any[] {
  return history.flatMap((turn) => (turn.execution?.tool_steps ?? []).flatMap((step: any) => step.tool_results ?? []));
}

const V1_FIXTURES = join(import.meta.dirname, "..", "fixtures", "v1-sessions");

/// Copies the first `count` sessions an older fx (v0.0.14) saved for fixture
/// `kind` (`tests/fixtures/v1-sessions/generate.ts`) into `home`'s `~/.fx`,
/// private as that release left them, and returns their ids. With
/// `workspace`, each copy is saved there instead, so the latest session of
/// that workspace can be resumed.
export function copyV1Fixture(home: string, kind: string, count = 1, workspace?: string): string[] {
  const manifest = JSON.parse(readFileSync(join(V1_FIXTURES, "manifest.json"), "utf8"));
  const ids: string[] = manifest.kinds[kind].slice(0, count);
  expect(ids).toHaveLength(count);
  const sessions = join(home, ".fx", "sessions");
  mkdirSync(sessions, { recursive: true, mode: 0o700 });
  for (const id of ids) {
    const to = join(sessions, id);
    cpSync(join(V1_FIXTURES, kind, "sessions", id), to, { recursive: true });
    const privatize = (path: string) => {
      if (statSync(path).isDirectory()) {
        chmodSync(path, 0o700);
        for (const name of readdirSync(path)) privatize(join(path, name));
      } else chmodSync(path, 0o600);
    };
    if (workspace) {
      const metadata = join(to, "session.json");
      writeFileSync(metadata, JSON.stringify({ ...JSON.parse(readFileSync(metadata, "utf8")), workspace_root: workspace }));
    }
    privatize(to);
    // The log gets the time v1 left on it, its session.json's: v1 lists a
    // session by the later of the two, and a copy's own time would order
    // the copies by when they were made.
    const log = join(to, "events.jsonl");
    const saved = JSON.parse(readFileSync(join(to, "session.json"), "utf8")).updated_at_ms;
    if (typeof saved === "number" && existsSync(log)) utimesSync(log, saved / 1000, saved / 1000);
  }
  return ids;
}

/// What `fx ask` writes first when converting a session an older fx saved
/// takes over 150 ms (`slow_conversion_text` in
/// `src/core/session/session_adapter.zig`). A busy runner can make any
/// conversion that slow.
const SLOW_CONVERSION_NOTICE = "fx ask: Converting this session from the previous session format…\n";

/// `stderr` from an `fx ask` that opened a copied v1 session, without the one
/// slow-conversion notice it may start with.
export function withoutConversionNotice(stderr: string): string {
  return stderr.startsWith(SLOW_CONVERSION_NOTICE) ? stderr.slice(SLOW_CONVERSION_NOTICE.length) : stderr;
}
