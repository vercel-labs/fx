import { afterEach, describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN, runFx } from "../evals/eval-helpers";
import { processGroupAlive } from "./process-alive";
import { childExited, makeFifo, pidWritten, untilChange, untilWritersGone } from "./hooks-helpers";

// `fx hook`, run against the built binary. Each test has its own HOME, with a profile folder and a
// workspace inside it. The person runs the commands unless a test sets AI_AGENT=fx, so AI_AGENT is
// removed from the inherited environment.

const GUARD_HOOKS = {
  hooks: {
    PreToolUse: [
      {
        matcher: "shell",
        hooks: [{ type: "command", command: "echo 'no rm' >&2; exit 2", id: "guard" }],
      },
    ],
  },
};

const SHELL_INPUT = JSON.stringify({ tool_name: "shell", tool_input: { command: "rm -rf x" } });

let cleanup: string | null = null;

afterEach(() => {
  if (cleanup) cleanupIsolatedTestHome(cleanup);
  cleanup = null;
});

type Root = {
  workspace: string;
  trustFile: string;
  env: Record<string, string | undefined>;
};

function createRoot(hooks: unknown = GUARD_HOOKS): Root {
  const home = realpathSync(createIsolatedTestHome());
  cleanup = home;
  // fx refuses a profile that is the home folder itself, so the profile sits one level below HOME.
  const profile = join(home, "profile");
  const workspace = join(home, "workspace");
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  mkdirSync(join(workspace, ".fx"), { recursive: true });
  writeFileSync(join(profile, "settings.json"), "{}");
  writeFileSync(join(workspace, ".fx", "hooks.json"), JSON.stringify(hooks));
  return {
    workspace,
    trustFile: join(profile, "hooks-trust.json"),
    env: {
      FX_HOME: profile,
      HOME: home,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      AI_AGENT: undefined,
    },
  };
}

function hook(root: Root, args: string[], env: Record<string, string | undefined> = {}) {
  return runFx(args, { cwd: root.workspace, env: { ...root.env, ...env }, timeoutMs: 20_000 });
}

function testArgs(...extra: string[]): string[] {
  return ["hook", "test", "PreToolUse", "--match", "shell", "--input", SHELL_INPUT, ...extra];
}

// Starts fx with the test's profile and workspace, without waiting for it, so a test can signal fx while it runs.
// `ignoreInt` starts fx through `sh`, which ignores SIGINT before it runs fx, as a shell does for a background job.
function startFx(root: Root, args: string[], options: { ignoreInt?: boolean } = {}): ChildProcess {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries({ ...process.env, ...root.env, NO_COLOR: "1", FX_SOUND: "0" })) {
    if (value !== undefined) env[key] = value;
  }
  if (options.ignoreInt) {
    return nodeSpawn("/bin/sh", ["-c", 'trap "" INT; exec "$0" "$@"', FX_BIN, ...args], {
      cwd: root.workspace,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
  }
  return nodeSpawn(FX_BIN, args, { cwd: root.workspace, env, stdio: ["ignore", "pipe", "pipe"] });
}

// The number of lines in a file, or 0 while the file does not exist.
function lineCount(path: string): number {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((line) => line.length > 0).length : 0;
}

const statusRow = (id: string, status: string) => new RegExp(`^${id}\\s+PreToolUse\\s+shell\\s+${status}\\s`, "m");

describe("fx hook", () => {
  test("list shows the waiting hook and the trust hint, in text and in JSON", async () => {
    const root = createRoot();

    const text = await hook(root, ["hook", "list"]);
    expect(text.code).toBe(0);
    expect(text.stdout).toMatch(statusRow("guard", "waiting"));
    expect(text.stdout).toContain("1 hook: 0 trusted, 1 waiting for trust. Run fx hook trust guard to trust one.");

    const listed = await hook(root, ["hook", "list", "--json"]);
    expect(listed.code).toBe(0);
    const doc = JSON.parse(listed.stdout);
    expect(doc.kind).toBe("hook_list");
    expect(doc.hooks).toEqual([
      expect.objectContaining({
        id: "guard",
        event: "PreToolUse",
        matcher: "shell",
        status: "waiting",
        command: "echo 'no rm' >&2; exit 2",
      }),
    ]);
    expect(doc.problems).toEqual([]);

    const alias = await hook(root, ["hooks", "ls", "--json"]);
    expect(alias.code).toBe(0);
    expect(alias.stdout).toBe(listed.stdout);
  });

  test("show gives one hook with its named files, and an unknown id fails", async () => {
    const root = createRoot();

    const shown = await hook(root, ["hook", "show", "guard", "--json"]);
    expect(shown.code).toBe(0);
    const doc = JSON.parse(shown.stdout);
    expect(doc.kind).toBe("hook_show");
    expect(doc.hook).toEqual(
      expect.objectContaining({ id: "guard", status: "waiting", type: "command", timeout_seconds: 60 }),
    );
    expect(doc.hook.named_files).toEqual([]);
    expect(doc.hook.named_files_dropped).toBe(0);

    const missing = await hook(root, ["hook", "show", "nope", "--json"]);
    expect(missing.code).toBe(1);
    expect(JSON.parse(missing.stdout)).toMatchObject({ kind: "hook_show", code: "UnknownHook" });

    const missingText = await hook(root, ["hook", "show", "nope"]);
    expect(missingText.code).toBe(1);
    expect(missingText.stdout + missingText.stderr).toContain('No hook with id "nope" for this workspace.');
  });

  test("trust makes the hook trusted, and the trust file is private", async () => {
    const root = createRoot();

    const trusted = await hook(root, ["hook", "trust", "guard"]);
    expect(trusted.code).toBe(0);
    expect(trusted.stdout).toContain("Trusted hook guard. Saved to ");

    const listed = await hook(root, ["hook", "list"]);
    expect(listed.stdout).toMatch(statusRow("guard", "trusted"));
    expect(statSync(root.trustFile).mode & 0o777).toBe(0o600);
  });

  test("disable stops the hook, and enable lets it run again", async () => {
    const root = createRoot();
    expect((await hook(root, ["hook", "trust", "guard"])).code).toBe(0);

    const disabled = await hook(root, ["hook", "disable", "guard", "--json"]);
    expect(disabled.code).toBe(0);
    expect(JSON.parse(disabled.stdout)).toMatchObject({ kind: "hook_state", id: "guard", disabled: true });
    expect((await hook(root, ["hook", "list"])).stdout).toMatch(statusRow("guard", "disabled"));

    const enabled = await hook(root, ["hook", "enable", "guard", "--json"]);
    expect(enabled.code).toBe(0);
    expect(JSON.parse(enabled.stdout)).toMatchObject({ kind: "hook_state", id: "guard", disabled: false });
    expect((await hook(root, ["hook", "list"])).stdout).toMatch(statusRow("guard", "trusted"));
  });

  test("fx's own agent cannot trust or disable a hook, but it can enable one", async () => {
    const root = createRoot();
    const agent = { AI_AGENT: "fx" };

    for (const words of [
      ["hook", "trust", "guard", "--json"],
      ["hook", "disable", "guard", "--json"],
    ]) {
      const refused = await hook(root, words, agent);
      expect(refused.code).toBe(1);
      expect(JSON.parse(refused.stdout)).toMatchObject({ code: "TrustNeedsPerson" });
    }
    expect(existsSync(root.trustFile)).toBe(false);

    const enabled = await hook(root, ["hook", "enable", "guard"], agent);
    expect(enabled.code).toBe(0);
    expect(enabled.stdout).toContain("Enabled hook guard for this workspace.");
  });

  test("fx's own agent runs only trusted hooks in fx hook test, and counts the waiting ones it skips", async () => {
    const root = createRoot();

    const agent = await hook(root, testArgs("--json"), { AI_AGENT: "fx" });
    expect(agent.code).toBe(0);
    expect(JSON.parse(agent.stdout)).toMatchObject({ kind: "hook_test", ran: 0, skipped_waiting: 1 });

    const agentText = await hook(root, testArgs(), { AI_AGENT: "fx" });
    expect(agentText.code).toBe(0);
    expect(agentText.stdout).toContain("Skipped 1 waiting hook: fx's own agent runs only trusted hooks.");

    // A person's run still runs the waiting hook, so nothing is skipped.
    const person = await hook(root, testArgs("--json"));
    expect(person.code).toBe(0);
    expect(JSON.parse(person.stdout)).toMatchObject({ ran: 1, decision: "deny", skipped_waiting: 0 });

    // Once a person trusts the hook, fx's own agent runs it too.
    const trusted = await hook(root, ["hook", "trust", "guard"]);
    expect(trusted.code).toBe(0);
    const agentTrusted = await hook(root, testArgs("--json"), { AI_AGENT: "fx" });
    expect(agentTrusted.code).toBe(0);
    expect(JSON.parse(agentTrusted.stdout)).toMatchObject({ ran: 1, decision: "deny", skipped_waiting: 0 });
  });

  test("test runs the matching hook and shows its deny, and an unmatched value runs nothing", async () => {
    const root = createRoot();

    const denied = await hook(root, testArgs("--json"));
    expect(denied.code).toBe(0);
    expect(JSON.parse(denied.stdout)).toMatchObject({
      kind: "hook_test",
      event: "PreToolUse",
      ran: 1,
      decision: "deny",
      reason: "no rm",
      decided_by: "guard",
    });

    const unmatched = await hook(root, ["hook", "test", "PreToolUse", "--match", "read_file", "--json"]);
    expect(unmatched.code).toBe(0);
    expect(JSON.parse(unmatched.stdout)).toMatchObject({ kind: "hook_test", ran: 0 });

    const unknown = await hook(root, ["hook", "test", "TurnEnd"]);
    expect(unknown.code).toBe(2);
    const message = unknown.stdout + unknown.stderr;
    expect(message).toContain('unknown event "TurnEnd"');
    expect(message.split("The events are:")[1] ?? "").not.toContain("TurnEnd");
  });

  test("log shows the runs, and --limit keeps only the newest", async () => {
    const root = createRoot();
    for (let run = 0; run < 2; run++) {
      expect((await hook(root, testArgs("--json"))).code).toBe(0);
    }

    const log = await hook(root, ["hook", "log", "--json"]);
    expect(log.code).toBe(0);
    const doc = JSON.parse(log.stdout);
    expect(doc.kind).toBe("hook_log");
    expect(doc.entries).toHaveLength(2);
    for (const entry of doc.entries) {
      expect(entry).toMatchObject({ event: "PreToolUse", ran: 1, decision: "deny", decided_by: "guard" });
    }

    const limited = JSON.parse((await hook(root, ["hook", "log", "--limit", "1", "--json"])).stdout);
    expect(limited.entries).toHaveLength(1);
  });

  test("a trust file that others can write stops every hook", async () => {
    const root = createRoot();
    expect((await hook(root, ["hook", "trust", "guard"])).code).toBe(0);
    chmodSync(root.trustFile, 0o664);

    const listed = await hook(root, ["hook", "list", "--json"]);
    expect(listed.code).toBe(0);
    const doc = JSON.parse(listed.stdout);
    expect(doc.trust_refused).toBe(true);
    expect(doc.problems.length).toBeGreaterThan(0);

    const ran = JSON.parse((await hook(root, testArgs("--json"))).stdout);
    expect(ran).toMatchObject({ ran: 0, trust_refused: true });

    const trust = await hook(root, ["hook", "trust", "guard", "--json"]);
    expect(trust.code).toBe(1);
    expect(JSON.parse(trust.stdout)).toMatchObject({ code: "TrustFileRefused" });
  });

  test("a hook file with an unknown event is reported as a problem", async () => {
    const root = createRoot({ hooks: { Nope: [{ hooks: [{ type: "command", command: "true" }] }] } });

    const listed = await hook(root, ["hook", "list", "--json"]);
    expect(listed.code).toBe(0);
    const doc = JSON.parse(listed.stdout);
    expect(doc.hooks).toEqual([]);
    expect(doc.problems).toHaveLength(1);
    expect(doc.problems[0]).toMatchObject({ where: "hooks.Nope", message: 'unknown event "Nope"' });
    expect(doc.problems[0].file.endsWith(join(".fx", "hooks.json"))).toBe(true);

    const text = await hook(root, ["hook", "list"]);
    expect(text.stdout).toContain('unknown event "Nope"');
  });

  test("fx hook --help lists every subcommand", async () => {
    const root = createRoot();

    const help = await hook(root, ["hook", "--help"]);
    expect(help.code).toBe(0);
    const lines = help.stdout.split("\n");
    const subcommands: Array<[string, string]> = [
      ["list", "List the hooks for this workspace and whether each runs"],
      ["show ID", "Show one hook: its event, matcher, command, file, and trust"],
      ["trust ID", "Trust a hook so it runs; --all trusts every hook waiting for trust"],
      ["enable ID", "Let a disabled hook run again in this workspace"],
      ["disable ID", "Stop a hook from running in this workspace"],
      ["test EVENT", "Run the hooks for an event on a sample input and show what they answered; the hook commands really run"],
      ["log", "Show the most recent hook runs: the event, how many hooks ran, and what they decided"],
    ];
    for (const [usage, description] of subcommands) {
      expect(lines.some((line) => line.includes(usage) && line.includes(description))).toBe(true);
    }

    const alias = await hook(root, ["hooks", "--help"]);
    expect(alias.code).toBe(0);
    expect(alias.stdout).toBe(help.stdout);
  });

  test("a hook file that is not valid JSON is a problem, and the other files still load", async () => {
    const root = createRoot();
    writeFileSync(
      profileFile(root, "hooks.json"),
      JSON.stringify({ hooks: { PreToolUse: [{ matcher: "shell", hooks: [{ type: "command", id: "p1", command: "true" }] }] } }),
    );
    writeFileSync(join(root.workspace, ".fx", "hooks.json"), "{not json");

    const listed = await hook(root, ["hook", "list", "--json"]);
    expect(listed.code).toBe(0);
    const doc = JSON.parse(listed.stdout);
    expect(doc.hooks.map((entry: { id: string }) => entry.id)).toEqual(["p1"]);
    expect(doc.problems).toHaveLength(1);
    expect(doc.problems[0].file.endsWith(join(".fx", "hooks.json"))).toBe(true);
    expect(doc.problems[0].message).toBe("not valid JSON: SyntaxError");
  });

  test("an id used twice is skipped in the later file", async () => {
    const root = createRoot({
      hooks: { PreToolUse: [{ matcher: "shell", hooks: [{ type: "command", id: "dup", command: "echo project >&2; exit 2" }] }] },
    });
    const profileHooks = profileFile(root, "hooks.json");
    writeFileSync(
      profileHooks,
      JSON.stringify({
        hooks: { PreToolUse: [{ matcher: "shell", hooks: [{ type: "command", id: "dup", command: "echo profile >&2; exit 2" }] }] },
      }),
    );

    const listed = await hook(root, ["hook", "list", "--json"]);
    expect(listed.code).toBe(0);
    const doc = JSON.parse(listed.stdout);
    // The profile file is read first, so its `dup` is the one that runs.
    expect(doc.hooks).toHaveLength(1);
    expect(doc.hooks[0]).toMatchObject({ id: "dup", command: "echo profile >&2; exit 2" });
    expect(doc.problems).toHaveLength(1);
    expect(doc.problems[0].file.endsWith(join(".fx", "hooks.json"))).toBe(true);
    expect(doc.problems[0].message).toBe(`id "dup" is also used in ${profileHooks}; this hook is skipped`);
  });

  test("a failing hook set to block makes a deny", async () => {
    const root = createRoot({
      hooks: {
        PreToolUse: [
          {
            matcher: "shell",
            hooks: [{ type: "command", id: "blocker", command: "echo boom >&2; exit 1", on_failure: "block" }],
          },
        ],
      },
    });

    const ran = await hook(root, testArgs("--json"));
    expect(ran.code).toBe(0);
    const doc = JSON.parse(ran.stdout);
    expect(doc).toMatchObject({ kind: "hook_test", ran: 1, decision: "deny", decided_by: "blocker" });
    expect(doc.reason).toBe("blocker failed and is set to block on failure: exited with code 1: boom");
  });

  test("show lists the files a command names, and a change to one makes the hook wait again", async () => {
    const root = createRoot({
      hooks: { PreToolUse: [{ matcher: "shell", hooks: [{ type: "command", id: "check", command: "sh ./scripts/check.sh" }] }] },
    });
    const script = join(root.workspace, "scripts", "check.sh");
    mkdirSync(join(root.workspace, "scripts"), { recursive: true });
    writeFileSync(script, "echo ok\n");

    const shown = await hook(root, ["hook", "show", "check", "--json"]);
    expect(shown.code).toBe(0);
    const doc = JSON.parse(shown.stdout);
    expect(doc.hook.named_files).toEqual([script]);
    expect(doc.hook.named_files_dropped).toBe(0);

    expect((await hook(root, ["hook", "trust", "check"])).code).toBe(0);
    expect((await hook(root, ["hook", "list"])).stdout).toMatch(statusRow("check", "trusted"));

    // The trust covers the script's content: a change to it makes the hook wait for trust again.
    writeFileSync(script, "echo changed\n");
    expect((await hook(root, ["hook", "list"])).stdout).toMatch(statusRow("check", "waiting"));
  });

  test(
    "SIGINT to fx hook test ends fx and the hook's process group",
    async () => {
      const root = createRoot();
      const pidFile = join(root.workspace, "hook.pid");
      const fifo = join(root.workspace, "hook.fifo");
      makeFifo(fifo);
      writeFileSync(
        join(root.workspace, ".fx", "hooks.json"),
        JSON.stringify({
          hooks: {
            PreToolUse: [
              {
                matcher: "shell",
                hooks: [{ type: "command", id: "sleepy", command: `exec 3> '${fifo}'; echo $$ > '${pidFile}'; exec sleep 30`, timeout: 60 }],
              },
            ],
          },
        }),
      );
      expect((await hook(root, ["hook", "trust", "sleepy"])).code).toBe(0);

      // The hook writes its pid before it sleeps, and it holds the FIFO open until its last process exits.
      const hookGone = untilWritersGone(fifo);
      const child = startFx(root, testArgs());
      const fxExited = childExited(child);
      try {
        await untilChange(root.workspace, () => pidWritten(pidFile));
        const pid = Number(readFileSync(pidFile, "utf8").trim());
        expect(processGroupAlive(pid)).toBe(true);

        child.kill("SIGINT");
        expect(await fxExited).toBe(true);
        // Each process the hook started holds the FIFO open, so end of file means all have exited (a group check races the exit).
        expect(await hookGone).toBe(true);
      } finally {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      }
    },
    60_000,
  );

  // A shell starts a background job with SIGINT ignored, and fx keeps that setting: a SIGINT does not stop the
  // hook. The hook appends a line while it runs, so the test waits for those lines, not for a fixed delay.
  test(
    "a SIGINT that fx starts ignored leaves the hook running; SIGTERM then ends fx and the hook's process group",
    async () => {
      const root = createRoot();
      const pidFile = join(root.workspace, "hook.pid");
      const beatFile = join(root.workspace, "hook.beat");
      const fifo = join(root.workspace, "hook.fifo");
      makeFifo(fifo);
      writeFileSync(
        join(root.workspace, ".fx", "hooks.json"),
        JSON.stringify({
          hooks: {
            PreToolUse: [
              {
                matcher: "shell",
                hooks: [
                  {
                    type: "command",
                    id: "beating",
                    command: `exec 3> '${fifo}'; echo $$ > '${pidFile}'; while :; do echo beat >> '${beatFile}'; sleep 0.05; done`,
                    timeout: 60,
                  },
                ],
              },
            ],
          },
        }),
      );

      const hookGone = untilWritersGone(fifo);
      const child = startFx(root, testArgs(), { ignoreInt: true });
      const fxExited = childExited(child);
      try {
        await untilChange(root.workspace, () => pidWritten(pidFile));
        const pid = Number(readFileSync(pidFile, "utf8").trim());
        await untilChange(root.workspace, () => lineCount(beatFile) >= 1);

        const beats = lineCount(beatFile);
        child.kill("SIGINT");
        // The hook keeps beating after the SIGINT, so fx neither stopped the hook nor exited.
        await untilChange(root.workspace, () => lineCount(beatFile) >= beats + 3);
        expect(child.exitCode).toBeNull();
        expect(child.signalCode).toBeNull();
        expect(processGroupAlive(pid)).toBe(true);

        child.kill("SIGTERM");
        expect(await fxExited).toBe(true);
        // Each process the hook started holds the FIFO open, so end of file means all have exited (a group check races the exit).
        expect(await hookGone).toBe(true);
      } finally {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      }
    },
    60_000,
  );
});

// The profile folder's file of a name, such as hooks.json.
function profileFile(root: Root, name: string): string {
  return join(root.env.FX_HOME as string, name);
}
