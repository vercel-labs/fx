// The `monitor` tool in the terminal UI: a command the agent starts once, whose
// output reaches it as messages from the command, with no model call while the
// command is quiet. The fake gateway scripts the model; the commands are real.
import { expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { processAlive } from "./process-alive";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall, startUpgradeServer, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
// A poller that records its pid and prints one line a second.
const POLLER = "echo $$ > pid.txt; i=0; while true; do i=$((i+1)); echo tick-$i; sleep 1; done";

function scenario(name: string, body: (profile: Profile) => Promise<void>, bin: string = FX_BIN) {
  test.skipIf(!tmuxAvailable())(name, async () => {
    const profile = new Profile(name.replace(/[^A-Za-z0-9]+/g, "-").slice(0, 32), bin);
    let passed = false;
    try {
      await body(profile);
      passed = true;
    } finally {
      await profile.close(!passed);
    }
  }, TIMEOUT);
}

const TRACED = { FX_TRACE_SCOPES: "wiring,monitor" };

/// The monitor trace lines fx wrote that say `what`, such as `event=event`.
function monitorTrace(profile: Profile, what: string): string[] {
  if (!existsSync(profile.wiring)) return [];
  return readFileSync(profile.wiring, "utf8").split("\n").filter((line) => line.includes("[monitor]") && line.includes(what));
}

/// The requests the model got that carry a monitor's message. A later
/// request holds the earlier messages too, so this counts requests, not events.
function monitorRequests(profile: Profile): string[] {
  return profile.gateway.requests.map((request) => request.body).filter((body) => body.includes('\\"source\\":\\"monitor\\"'));
}

scenario("a monitor's output wakes an idle agent, at most once every ten seconds, and stop ends it", async (profile) => {
  profile.script("Watch the poller.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: POLLER, label: "poll" }),
    () => fakeGatewayFinalText("WATCHING_STARTED"),
    () => fakeGatewayFinalText("SAW_FIRST_EVENT"),
    () => fakeGatewayFinalText("SAW_SECOND_EVENT"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Watch the poller.");
  await shell.session.waitForText("WATCHING_STARTED", 30_000);
  // No one typed again: the first line starts a turn by itself.
  const firstAt = Date.now();
  await shell.session.waitForText("SAW_FIRST_EVENT", 30_000);
  expect(monitorTrace(profile, "event=event")).toHaveLength(1);
  expect(monitorTrace(profile, "event=start id=shell-1")).toHaveLength(1);
  expect(monitorRequests(profile)[0]).toContain("tick-1");
  // The model reads it as a monitor's event, not a subagent's message, and the
  // screen shows it like a subagent's: from the monitor's label.
  expect(monitorRequests(profile)[0]).toContain("Monitor event (untrusted command output");
  expect(monitorRequests(profile)[0]).not.toContain("Subagent message");
  expect(await shell.session.capturePane()).toContain("from poll");
  // The next event waits out the gap and holds what came meanwhile.
  await shell.session.waitForText("SAW_SECOND_EVENT", 40_000);
  expect(Date.now() - firstAt).toBeGreaterThanOrEqual(9_000);
  const second = monitorRequests(profile)[1]!;
  expect(second).toContain("tick-6");

  // list and stop go through the same tool.
  const pid = Number(readFileSync(join(profile.workspace, "pid.txt"), "utf8").trim());
  expect(processAlive(pid)).toBe(true);
  profile.script("Stop the poller.", [
    () => fakeGatewayToolCall("m2", "monitor", { action: "list" }),
    () => fakeGatewayToolCall("m3", "monitor", { action: "stop", id: "shell-1" }),
    () => fakeGatewayFinalText("POLLER_STOPPED"),
  ]);
  const seen = monitorTrace(profile, "event=event").length;
  await shell.session.sendText("Stop the poller.");
  await shell.session.waitForText("POLLER_STOPPED", 30_000);
  expect(processAlive(pid)).toBe(false);
  // Stopping it sent no end event of its own.
  expect(monitorTrace(profile, "event=event")).toHaveLength(seen);
  expect(monitorTrace(profile, "event=stop id=shell-1 reason=agent_stop")).toHaveLength(1);
  expect(shell.stderrText()).toBe("");
});

scenario("a quiet monitor costs no model request, and a command that ends sends one last event", async (profile) => {
  profile.script("Wait for the job.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: "echo started; sleep 5; echo done; exit 3", label: "job" }),
    () => fakeGatewayFinalText("JOB_STARTED"),
    () => fakeGatewayFinalText("SAW_STARTED"),
    () => fakeGatewayFinalText("SAW_END"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Wait for the job.");
  await shell.session.waitForText("SAW_STARTED", 30_000);
  const quietFrom = profile.gateway.requests.length;
  await shell.session.waitForText("SAW_END", 30_000);
  // The command was quiet for four seconds: the only request since is the end's.
  expect(profile.gateway.requests.length).toBe(quietFrom + 1);
  const last = monitorRequests(profile).at(-1)!;
  expect(last).toContain("done");
  expect(last).toContain("exited with code 3");
  expect(monitorTrace(profile, "event=stop id=shell-1 reason=command_ended")).toHaveLength(1);
});

scenario("a monitor that repeats its last words wakes no one", async (profile) => {
  profile.script("Watch the heartbeat.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: "echo alive; sleep 12; echo alive; sleep 12; echo alive; sleep 1; echo finished", label: "beat" }),
    () => fakeGatewayFinalText("BEAT_STARTED"),
    () => fakeGatewayFinalText("SAW_ALIVE"),
    () => fakeGatewayFinalText("SAW_FINISHED"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Watch the heartbeat.");
  await shell.session.waitForText("SAW_FINISHED", 60_000);
  // The second and third "alive" were the same as the first: two events in all.
  expect(monitorTrace(profile, "event=event")).toHaveLength(2);
  expect(monitorTrace(profile, "reason=repeat")).toHaveLength(2);
  expect(monitorRequests(profile).at(-1)).toContain("finished");
});

/// Waits until `done` holds.
async function waitFor(done: () => boolean, what: string, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (!done()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(50);
  }
}

// A command that records its pid and prints nothing.
const QUIET = "echo $$ > pid.txt; sleep 600";

function recordPath(profile: Profile, id: string): string {
  return join(profile.home, ".fx", "monitors", `${id}.json`);
}

function pidOf(profile: Profile): number {
  return Number(readFileSync(join(profile.workspace, "pid.txt"), "utf8").trim());
}

scenario("a crash leaves the monitors for the agent to start again, and a normal quit leaves none", async (profile) => {
  profile.script("Watch the quiet job.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: QUIET, label: "quiet" }),
    () => fakeGatewayFinalText("QUIET_STARTED"),
  ]);
  const first = await profile.launch({ env: TRACED });
  await first.session.sendText("Watch the quiet job.");
  await first.session.waitForText("QUIET_STARTED", 30_000);
  const id = first.current()!;
  await waitFor(() => existsSync(recordPath(profile, id)), "the monitor record");
  const record = JSON.parse(readFileSync(recordPath(profile, id), "utf8"));
  expect(record.monitors).toEqual([{ label: "quiet", command: QUIET }]);
  const oldPid = pidOf(profile);
  await first.crash();
  // Nothing of a killed fx can stop its command, so the test does. The
  // terminal's hang-up may have ended it already.
  try {
    process.kill(oldPid, "SIGKILL");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }

  // The resumed session tells the agent, which starts the command again.
  profile.script("these monitors ended with it", [
    () => fakeGatewayToolCall("m2", "monitor", { action: "start", command: QUIET, label: "quiet" }),
    () => fakeGatewayFinalText("QUIET_RESTARTED"),
  ]);
  const second = await profile.launch({ args: ["--resume", id], env: TRACED });
  await second.session.waitForText("QUIET_RESTARTED", 30_000);
  expect(await second.session.capturePane()).toContain("monitors ended when fx restarted");
  const restarted = profile.gateway.requests.map((request) => request.body).find((body) => body.includes("these monitors ended with it"))!;
  expect(restarted).toContain("sleep 600");
  expect(monitorTrace(profile, "event=restart_noted count=1")).toHaveLength(1);
  const newPid = pidOf(profile);
  expect(newPid).not.toBe(oldPid);
  expect(processAlive(newPid)).toBe(true);

  // A quit the user chose ends the command and removes the record.
  await second.quit();
  expect(existsSync(recordPath(profile, id))).toBe(false);
  expect(processAlive(newPid)).toBe(false);
});

scenario("a monitor start asks like a shell run, and a refused start runs nothing", async (profile) => {
  profile.script("Watch the job.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: QUIET, label: "job" }),
    () => fakeGatewayFinalText("START_REFUSED"),
  ]);
  profile.script("Try the job again.", [
    () => fakeGatewayToolCall("m2", "monitor", { action: "start", command: QUIET, label: "job" }),
    () => fakeGatewayFinalText("START_ALLOWED"),
  ]);
  const shell = await profile.launch({ env: { ...TRACED, FX_PERMISSION_MODE: "ask" } });
  await shell.session.sendText("Watch the job.");
  const pane = await shell.session.waitForText("Would you like to run the following command?", 30_000);
  // The prompt shows the command, as it does for the shell tool.
  expect(pane).toContain(QUIET);
  await shell.session.sendKeys("3");
  await shell.session.waitForText("START_REFUSED", 30_000);
  expect(existsSync(join(profile.workspace, "pid.txt"))).toBe(false);
  expect(monitorTrace(profile, "event=start")).toHaveLength(0);

  await shell.session.sendText("Try the job again.");
  await shell.session.waitForText("Would you like to run the following command?", 30_000);
  await shell.session.sendKeys("1");
  await shell.session.waitForText("START_ALLOWED", 30_000);
  expect(processAlive(pidOf(profile))).toBe(true);
  expect(monitorTrace(profile, "event=start id=shell-1")).toHaveLength(1);
  await shell.quit();
  expect(processAlive(pidOf(profile))).toBe(false);
});

scenario("a new conversation stops the monitors of the old one and removes their record", async (profile) => {
  profile.script("Watch the quiet job.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: QUIET, label: "quiet" }),
    () => fakeGatewayFinalText("QUIET_STARTED"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Watch the quiet job.");
  await shell.session.waitForText("QUIET_STARTED", 30_000);
  const id = shell.current()!;
  await waitFor(() => existsSync(recordPath(profile, id)), "the monitor record");
  const pid = pidOf(profile);
  expect(processAlive(pid)).toBe(true);
  await shell.newSession("/new");
  await waitFor(() => monitorTrace(profile, "event=session_changed count=1").length === 1, "the monitor to be stopped");
  await waitFor(() => !processAlive(pid), "the command to end");
  await waitFor(() => !existsSync(recordPath(profile, id)), "the record to go");
  expect(await shell.session.capturePane()).toContain("monitors of the earlier conversation were stopped");
});

scenario("a blocked agent gets the newest twenty events, a count of the rest, and a file with everything", async (profile) => {
  const fast = "echo $$ > pid.txt; i=0; while true; do i=$((i+1)); echo tick-$i; sleep 0.1; done";
  profile.script("Watch the fast poller.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: fast, label: "fast" }),
    () => fakeGatewayFinalText("FAST_STARTED"),
    () => fakeGatewayFinalText("SAW_FIRST_FAST"),
  ]);
  profile.script("Now block on a prompt.", [
    () => fakeGatewayToolCall("b1", "shell", { action: "run", command: "echo unblocked" }),
    () => fakeGatewayFinalText("BLOCK_DONE"),
    () => fakeGatewayFinalText("SAW_DIGEST"),
  ]);
  const shell = await profile.launch({ env: { ...TRACED, FX_PERMISSION_MODE: "ask", FX_TEST_MONITOR_GAP_MS: "200" } });
  await shell.session.sendText("Watch the fast poller.");
  await shell.session.waitForText("Would you like to run the following command?", 30_000);
  await shell.session.sendKeys("1");
  await shell.session.waitForText("SAW_FIRST_FAST", 30_000);
  const pid = pidOf(profile);

  // The agent blocks on an approval, and the monitor keeps printing.
  await shell.session.sendText("Now block on a prompt.");
  await shell.session.waitForText("Would you like to run the following command?", 30_000);
  await waitFor(() => monitorTrace(profile, "event=held").length >= 30, "thirty events to be made while the agent is blocked", 40_000);
  const dropped = monitorTrace(profile, "event=held").map((line) => Number(/dropped_before=(\d+)/.exec(line)![1]));
  // Only the newest twenty wait, and the older ones are counted.
  expect(Math.max(...dropped)).toBeGreaterThanOrEqual(5);

  await shell.session.sendKeys("1");
  await shell.session.waitForText("SAW_DIGEST", 40_000);
  const digest = monitorTrace(profile, "event=event").find((line) => /events=\d+ dropped=[1-9]/.test(line))!;
  expect(digest).toBeDefined();
  const body = profile.gateway.requests.map((request) => request.body).find((text) => text.includes("earlier events dropped"))!;
  const count = Number(/\+(\d+) earlier events dropped/.exec(body)![1]);
  expect(count).toBeGreaterThanOrEqual(5);
  // The message names the file, and the file holds what the events dropped.
  const file = /output_file\\":\\"([^"\\]+\.log)/.exec(body)![1]!;
  const logged = readFileSync(file, "utf8").split("\n").filter(Boolean);
  expect(logged[0]).toBe("tick-1");
  expect(logged.length).toBeGreaterThan(count + 20);
  expect(statSync(file).mode & 0o077).toBe(0);
  process.kill(pid, "SIGKILL");
});

scenario("a stream that spans several event windows leaves every line in the file", async (profile) => {
  // Thirty kilobytes a second for fourteen seconds, past the ten second gap
  // between events. The entry keeps only 64 KiB of output not yet read, so a
  // file written once per event would lose most of the second window.
  const stream = "echo $$ > pid.txt; for i in $(seq 1 14); do printf 'burst-%02d ' $i; head -c 30000 /dev/zero | tr '\\0' x; echo; sleep 1; done";
  profile.script("Watch the stream.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: stream, label: "stream" }),
    () => fakeGatewayFinalText("STREAM_STARTED"),
    () => fakeGatewayFinalText("SAW_FIRST_WINDOW"),
    () => fakeGatewayFinalText("SAW_SECOND_WINDOW"),
    () => fakeGatewayFinalText("SAW_STREAM_END"),
    () => fakeGatewayFinalText("SAW_STREAM_EXTRA"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Watch the stream.");
  await shell.session.waitForText("STREAM_STARTED", 30_000);
  await waitFor(() => monitorTrace(profile, "event=stop id=shell-1 reason=command_ended").length === 1, "the stream to end and its last event to post", 60_000);
  const body = monitorRequests(profile)[0]!;
  const file = /output_file\\":\\"([^"\\]+\.log)/.exec(body)![1]!;
  const logged = readFileSync(file, "utf8");
  for (let index = 1; index <= 14; index++) expect(logged).toContain(`burst-${String(index).padStart(2, "0")} `);
  expect(logged).not.toContain("bytes truncated");
  expect(statSync(file).size).toBeGreaterThanOrEqual(14 * 30_000);
  // Nothing rolled over: the whole stream is under the 4 MiB the file keeps.
  expect(existsSync(`${file}.1`)).toBe(false);
});

scenario("the shell tool refuses to read or stop a monitor's command", async (profile) => {
  profile.script("Watch the quiet job.", [
    () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: QUIET, label: "quiet" }),
    () => fakeGatewayFinalText("QUIET_STARTED"),
  ]);
  profile.script("Poke the monitor with the shell.", [
    () => fakeGatewayToolCall("p1", "shell", { action: "interact", session_id: "shell-1", yield_time_ms: 1000 }),
    () => fakeGatewayToolCall("p2", "shell", { action: "stop", session_id: "shell-1" }),
    () => fakeGatewayFinalText("POKED"),
  ]);
  const shell = await profile.launch({ env: TRACED });
  await shell.session.sendText("Watch the quiet job.");
  await shell.session.waitForText("QUIET_STARTED", 30_000);
  const pid = pidOf(profile);
  await shell.session.sendText("Poke the monitor with the shell.");
  await shell.session.waitForText("POKED", 30_000);
  const last = profile.gateway.requests.at(-1)!.body;
  expect(last.match(/is a monitor/g)?.length).toBe(2);
  // Neither call touched the command, and the monitor is still listed.
  expect(processAlive(pid)).toBe(true);
  expect(monitorTrace(profile, "event=stop")).toHaveLength(0);
});

const UPGRADE_TIMEOUT = 120_000;

test.skipIf(!tmuxAvailable())("Ctrl+G ends the monitors, and the restarted fx tells the agent to start them again", async () => {
  // An installed copy that the fake upgrade replaces with a wrapper around the built fx.
  const installDir = realpathSync(mkdtempSync(join(tmpdir(), "fx-monitor-install-")));
  const installedFx = join(installDir, "fx");
  copyFileSync(FX_BIN, installedFx);
  chmodSync(installedFx, 0o755);
  const profile = new Profile("upgrade-ctrl-g", installedFx);
  const argvLog = join(profile.root, "upgrade-argv.log");
  const release = startUpgradeServer(profile.root, argvLog, { revision: "1111111111111111111111111111111111111111" });
  let passed = false;
  try {
    profile.settings({ update_channel: "dev" });
    profile.script("Watch the quiet job.", [
      () => fakeGatewayToolCall("m1", "monitor", { action: "start", command: QUIET, label: "quiet" }),
      () => fakeGatewayFinalText("QUIET_STARTED"),
    ]);
    profile.script("these monitors ended with it", [() => fakeGatewayFinalText("RESTART_NOTED")]);
    const shell = await profile.launch({
      env: { ...TRACED, FX_AUTO_UPGRADE: "1", FX_TEST_UPGRADE_BASE_URL: release.baseUrl, FX_TEST_UPGRADE_CHECK_INTERVAL_MS: "200" },
    });
    await shell.session.sendText("Watch the quiet job.");
    await shell.session.waitForText("QUIET_STARTED", 30_000);
    const id = shell.current()!;
    await waitFor(() => existsSync(recordPath(profile, id)), "the monitor record");
    const oldPid = pidOf(profile);
    await shell.session.waitForText("update ready: ctrl+g to reload", UPGRADE_TIMEOUT);
    await shell.session.sendHexBytes(["07"]);
    // The agent hears about it in the restarted fx, with no prompt typed.
    await shell.session.waitForText("RESTART_NOTED", UPGRADE_TIMEOUT);
    expect(readFileSync(argvLog, "utf8")).toContain("--upgrade-relaunch");
    // The restart killed the command: fx does not leave one running.
    expect(processAlive(oldPid)).toBe(false);
    expect(monitorTrace(profile, "event=restart_noted count=1")).toHaveLength(1);
    passed = true;
  } finally {
    release.stop();
    await profile.close(!passed);
    rmSync(installDir, { recursive: true, force: true });
  }
}, UPGRADE_TIMEOUT * 2);
