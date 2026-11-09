// `/status` opens a panel in the footer that shows the open session's id and
// whether it is saved (D90 in tests/tla/session_manager/system-design.md),
// and writes nothing to the transcript. Each scenario drives the real binary
// in a terminal and reads every panel back from the recorded tape through
// fx's own virtual terminal (vt_emulator), then checks what the panel claimed
// against what fx did: the session folders on disk, the exit line, a later
// resume, and the wiring trace's record of each session opened.
// tests/tla/drivers/session/ runs the same shell along the ShellSession model.
import { expect, test } from "bun:test";
import { runFx } from "../evals/eval-helpers";
import { Profile } from "./shell-sessions";
import { closedAsBefore, lastTranscriptRow, panelSession, showsStatusPanel, type StatusReport } from "./info-panel";
import { tmuxAvailable } from "./tmux-helpers";
import { assertSingleFooter } from "./tui-render-assertions";

const TIMEOUT = 120_000;
const SESSION_ID = /^[A-Za-z0-9_-]{12}$/;

function scenario(name: string, body: (profile: Profile) => Promise<void>) {
  test.skipIf(!tmuxAvailable())(name, async () => {
    const profile = new Profile(name.replace(/[^A-Za-z0-9]+/g, "-").slice(0, 32));
    let passed = false;
    try {
      await body(profile);
      passed = true;
    } finally {
      await profile.close(!passed);
    }
  }, TIMEOUT);
}

/// `report`'s panel names session `id` (null: no session), saved or not, on
/// its first line, and closing it left the shell as it was before `/status`
/// was typed, with the composer's footer drawn once: the transcript holds no
/// row of it.
function expectReport(report: StatusReport, id: string | null, saved: boolean) {
  expect(panelSession(report)).toEqual({ id, saved });
  expect(report.labels[0]).toBe("Session");
  // A panel too tall for its terminal shows the rest a ↓ at a time.
  const labels = new Set(report.views.flatMap((view) => view.labels));
  for (const label of ["Model", "Auth", "Permissions", "Workspace", "Turns"]) expect(labels).toContain(label);
  expect(showsStatusPanel(report.closed)).toBe(false);
  if (!closedAsBefore(report)) {
    throw new Error(`the /status panel at tape frame ${report.frame} changed the shell:\n--- before\n${report.before.join("\n")}\n--- closed\n${report.closed.join("\n")}`);
  }
  const failures: string[] = [];
  assertSingleFooter(report.closed, failures, `the grid after the /status panel at tape frame ${report.frame} closed`);
  expect(failures).toEqual([]);
}

scenario("a new session is unsaved until its first prompt, and its id is the one to resume", async (profile) => {
  const shell = await profile.launch();
  const id = shell.current()!;
  expect(id).toMatch(SESSION_ID);
  await shell.status();
  expect(profile.disk()).toEqual({});
  expect(await profile.resumable(id)).toBe(false);

  // The first turn saves the session when it starts, before its answer.
  const turn = await shell.begin("Save this conversation.");
  await shell.status();
  expect(profile.disk()).toEqual({ [id]: 1 });
  await turn.release("FIRST_ANSWER");
  await shell.status();
  expect(await shell.quit()).toBe(id);
  expect(shell.stderrText()).toBe("");

  const [pristine, running, answered] = shell.reports();
  expectReport(pristine!, id, false);
  expect(pristine!.fields.Turns).toBe("0");
  expectReport(running!, id, true);
  expectReport(answered!, id, true);
  expect(answered!.fields.Turns).toBe("1");
  expect(answered!.fields.Workspace).toBe(profile.workspace);

  // The id /status showed opens the session again.
  const again = await profile.launch({ args: ["--resume", panelSession(pristine!).id!] });
  await again.session.waitForText("FIRST_ANSWER", TIMEOUT);
  expect(again.current()).toBe(id);
  await again.status();
  expect(await again.quit()).toBe(id);
  expectReport(again.reports()[0]!, id, true);
  expect(again.stderrText()).toBe("");
});

scenario("/new and /clear open fresh sessions, and one never prompted leaves nothing to resume", async (profile) => {
  const shell = await profile.launch();
  const first = shell.current()!;
  await shell.status();
  const second = await shell.newSession("/new");
  await shell.status();
  await shell.prompt("Keep the second session.", "SECOND_ANSWER");
  await shell.status();
  const third = await shell.newSession("/clear");
  await shell.status();
  expect(new Set([first, second, third]).size).toBe(3);
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");

  const reports = shell.reports();
  expectReport(reports[0]!, first, false);
  expectReport(reports[1]!, second, false);
  expectReport(reports[2]!, second, true);
  expectReport(reports[3]!, third, false);
  expect(profile.disk()).toEqual({ [second]: 1 });
  expect(await profile.resumable(first)).toBe(false);
  expect(await profile.resumable(second)).toBe(true);
  expect(await profile.resumable(third)).toBe(false);
});

scenario("/resume switches /status to the session picked", async (profile) => {
  const shell = await profile.launch();
  const alpha = shell.current()!;
  await shell.prompt("Alpha session prompt.", "ALPHA_ANSWER");
  const bravo = await shell.newSession("/new");
  await shell.prompt("Bravo session prompt.", "BRAVO_ANSWER");
  const unprompted = await shell.newSession("/new");
  await shell.status();
  expect(await shell.resume("Alpha session")).toBe(alpha);
  await shell.status();
  expect(await shell.resume("Bravo session")).toBe(bravo);
  await shell.status();
  expect(await shell.quit()).toBe(bravo);
  expect(shell.stderrText()).toBe("");

  const reports = shell.reports();
  expectReport(reports[0]!, unprompted, false);
  expectReport(reports[1]!, alpha, true);
  expectReport(reports[2]!, bravo, true);
  expect(profile.disk()).toEqual({ [alpha]: 1, [bravo]: 1 });
});

scenario("a fork before the first prompt is saved from the start, and the exit line names it", async (profile) => {
  const shell = await profile.launch();
  const source = shell.current()!;
  await shell.prompt("Fork source one.", "SOURCE_ONE");
  await shell.prompt("Fork source two.", "SOURCE_TWO");
  const fork = await shell.fork(1);
  expect(fork).not.toBe(source);
  await shell.status();
  expect(profile.disk()).toEqual({ [source]: 2, [fork]: 0 });
  expect(await shell.quit()).toBe(fork);
  expect(shell.stderrText()).toBe("");
  const [report] = shell.reports();
  expectReport(report!, fork, true);
  expect(report!.fields.Turns).toBe("0");

  const again = await profile.launch({ args: ["--resume", fork] });
  expect(again.current()).toBe(fork);
  await again.status();
  expect(await again.quit()).toBe(fork);
  expectReport(again.reports()[0]!, fork, true);
  expect(again.stderrText()).toBe("");
});

scenario("a fork at a later prompt holds the turns before it", async (profile) => {
  const shell = await profile.launch();
  const source = shell.current()!;
  for (const n of ["one", "two", "three"]) await shell.prompt(`Later fork ${n}.`, `LATER_${n.toUpperCase()}`);
  const fork = await shell.fork(1);
  await shell.status();
  expect(profile.disk()).toEqual({ [source]: 3, [fork]: 1 });
  await shell.prompt("A prompt in the fork.", "IN_FORK");
  await shell.status();
  expect(profile.disk()).toEqual({ [source]: 3, [fork]: 2 });
  expect(await shell.quit()).toBe(fork);
  const [forked, prompted] = shell.reports();
  expectReport(forked!, fork, true);
  expect(forked!.fields.Turns).toBe("1");
  expectReport(prompted!, fork, true);
  expect(prompted!.fields.Turns).toBe("2");
});

scenario("a crash keeps every session /status called saved and loses the one it called unsaved", async (profile) => {
  const answered = await profile.launch();
  const kept = answered.current()!;
  await answered.prompt("Survive the crash.", "CRASH_ANSWER");
  await answered.status();
  await answered.crash();
  expectReport(answered.reports()[0]!, kept, true);

  // Saved while its first turn still runs.
  const running = await profile.launch();
  const started = running.current()!;
  await running.begin("Crash while this runs.");
  await running.status();
  await running.crash();
  expectReport(running.reports()[0]!, started, true);

  const unprompted = await profile.launch();
  const lost = unprompted.current()!;
  await unprompted.status();
  await unprompted.crash();
  expectReport(unprompted.reports()[0]!, lost, false);

  expect(profile.disk()).toEqual({ [kept]: 1, [started]: 1 });
  expect(await profile.resumable(kept)).toBe(true);
  expect(await profile.resumable(started)).toBe(true);
  expect(await profile.resumable(lost)).toBe(false);
});

scenario("a shell that cannot create a session shows none, saves nothing, and prints no exit line", async (profile) => {
  profile.blockStore();
  const shell = await profile.launch();
  expect(shell.current()).toBeNull();
  await shell.status();
  await shell.prompt("A prompt with no session.", "NO_STORE_ANSWER");
  await shell.status();
  await shell.command("/new");
  await shell.status();
  expect(await shell.quit()).toBeNull();
  expect(shell.current()).toBeNull();
  expect(shell.stderrText()).toBe("");
  for (const report of shell.reports()) expectReport(report, null, false);
  expect(profile.disk()).toEqual({});
});

scenario("the panel wraps long values in a narrow terminal and keeps the session id whole", async (profile) => {
  const shell = await profile.launch({ width: 40, height: 40 });
  const id = shell.current()!;
  await shell.status();
  await shell.prompt("Narrow terminal prompt.", "NARROW_ANSWER");
  await shell.status();
  // The exit line is wider than 40 columns, so its command takes a row of its own.
  expect(await shell.quit()).toBe(id);
  expect(shell.stderrText()).toBe("");
  const [unsaved, saved] = shell.reports();
  expectReport(unsaved!, id, false);
  expectReport(saved!, id, true);
  for (const report of [unsaved!, saved!]) {
    expect(report.grid.every((row) => [...row].length <= 40)).toBe(true);
    // The workspace wraps between its folders and still reads back whole.
    const at = report.rows.findIndex((row) => row.startsWith("  Workspace "));
    expect(report.rows[at]!.trimEnd().endsWith("/")).toBe(true);
    expect(report.rows[at + 1]!).toMatch(/^ {3,}\S/);
    expect(report.fields.Workspace).toBe(profile.workspace);
    // The id sits whole on the session line, however its state wraps.
    expect(report.rows[0]!).toContain(id);
  }
});

scenario("a short terminal shows the panel's first lines, and ↓ scrolls it a line at a time to the last", async (profile) => {
  const shell = await profile.launch({ width: 80, height: 14 });
  const id = shell.current()!;
  await shell.status({ scroll: 24 });
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");
  const [report] = shell.reports();
  expectReport(report!, id, false);

  const [first, ...scrolled] = report!.views;
  expect(first!.labels[0]).toBe("Session");
  expect(first!.labels).not.toContain("Build");
  expect(first!.grid.some((row) => row.trimEnd() === "↑↓ scroll     esc close")).toBe(true);
  // The panel scrolls rather than cover the transcript, so the transcript's
  // last row stays in view while it is open.
  const kept = lastTranscriptRow(report!.before);
  for (const view of report!.views) {
    expect(view.grid.map((row) => row.trimEnd())).toContain(kept);
  }
  expect(scrolled.length).toBeGreaterThan(0);
  let previous = first!;
  for (const view of scrolled) {
    // One line further down, as many lines showing.
    expect(view.rows.slice(0, -1)).toEqual(previous.rows.slice(1));
    expect(view.rows.length).toBe(first!.rows.length);
    previous = view;
  }
  // The last line is shown, and ↓ past it paints nothing.
  expect(previous.labels.at(-1)).toBe("Build");
  expect(previous.labels).not.toContain("Session");
  expect(scrolled.length).toBeLessThan(24);
});

test("fx status runs outside any session and shows none", async () => {
  const profile = new Profile("cli-status");
  try {
    const env = { HOME: profile.home, FX_SOUND: "0", FX_AUTO_UPGRADE: "0", AI_GATEWAY_API_KEY: "status-session-fixture" };
    const text = await runFx(["status"], { cwd: profile.workspace, env });
    expect(text.code).toBe(0);
    expect(text.stdout).toContain("[status] history_turns=0\n");
    expect(text.stdout).not.toMatch(/^\[status\] session(_saved)?=/m);
    const json = await runFx(["status", "--json"], { cwd: profile.workspace, env });
    expect(json.code).toBe(0);
    const status = JSON.parse(json.stdout);
    expect(status.kind).toBe("status");
    expect(Object.keys(status).filter((key) => key.startsWith("session") && key !== "session_permission_grants")).toEqual([]);
  } finally {
    await profile.close(false);
  }
});
