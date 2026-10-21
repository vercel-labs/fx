import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// A repository's own git config can name programs: fsmonitor, hooks, clean
// and smudge filters, diff drivers and the pager. Opening a repository in fx
// must never run them. A control first proves the fixture's programs run
// under plain git; every fx path below must then leave the sentinel log
// empty while still answering from the repository's real contents.

const TIMEOUT = 60_000;
const MODEL = "openai/gpt-5";
const tmuxTest = test.skipIf(!tmuxAvailable());

type Fixture = {
  base: string;
  home: string;
  workspace: string;
  log: string;
};

type Gateway = ReturnType<typeof startFakeGateway>;

const fixtures: Fixture[] = [];
const gateways: Gateway[] = [];
let session: TmuxSession | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const fixture of fixtures.splice(0)) {
    rmSync(fixture.base, { recursive: true, force: true });
  }
});

function git(fixture: Fixture, args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], {
    cwd: fixture.workspace,
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      HOME: fixture.home,
      GIT_CONFIG_NOSYSTEM: "1",
      LC_ALL: "C",
    },
  });
  if (result.exitCode !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString()}`);
  }
  return result.stdout.toString();
}

function sentinelRuns(fixture: Fixture): string[] {
  if (!existsSync(fixture.log)) return [];
  return readFileSync(fixture.log, "utf8").split("\n").filter(Boolean);
}

function poisonedRepository(): Fixture {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "fx-poisoned-repo-")));
  const fixture: Fixture = {
    base,
    home: join(base, "home"),
    workspace: join(base, "workspace"),
    log: join(base, "sentinel.log"),
  };
  fixtures.push(fixture);
  mkdirSync(join(fixture.home, ".fx"), { recursive: true });
  mkdirSync(join(fixture.workspace, "notes"), { recursive: true });
  writeFileSync(
    join(fixture.home, ".fx", "settings.json"),
    JSON.stringify({ auto_upgrade: false }),
  );
  const sentinel = join(base, "sentinel.sh");
  writeFileSync(sentinel, `#!/bin/sh\necho "ran $0 $*" >> '${fixture.log}'\ncat\n`);
  chmodSync(sentinel, 0o755);
  const hooks = join(base, "hooks");
  mkdirSync(hooks);
  for (const hook of ["post-index-change", "pre-commit", "post-checkout"]) {
    writeFileSync(join(hooks, hook), readFileSync(sentinel));
    chmodSync(join(hooks, hook), 0o755);
  }

  git(fixture, ["init", "-q", "--template=", "-b", "main"]);
  writeFileSync(join(fixture.workspace, "alpha-tracked.txt"), "needle tracked one\n");
  writeFileSync(join(fixture.workspace, ".gitattributes"), "*.txt filter=evil diff=evil\n");
  git(fixture, ["add", "-A"]);
  git(fixture, ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "fixture commit"]);
  for (const [key, value] of [
    ["core.fsmonitor", sentinel],
    ["core.hooksPath", hooks],
    ["core.pager", sentinel],
    ["filter.evil.clean", sentinel],
    ["filter.evil.smudge", sentinel],
    ["diff.external", sentinel],
    ["diff.evil.textconv", sentinel],
  ]) git(fixture, ["config", key!, value!]);
  writeFileSync(join(fixture.workspace, "alpha-tracked.txt"), "needle tracked two\n");
  writeFileSync(join(fixture.workspace, "notes", "alpha-untracked.txt"), "needle untracked\n");
  writeFileSync(fixture.log, "");
  return fixture;
}

function fxEnv(fixture: Fixture, gateway: Gateway): Record<string, string> {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "fake-poisoned-repo-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_SOUND: "0",
    NO_COLOR: "1",
  };
}

function toolResult(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const part = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((item) => item.type === "tool-result" && item.toolCallId === toolCallId);
  if (!part) throw new Error(`No tool result for ${toolCallId}`);
  const output = part.output as { value?: unknown };
  return typeof output.value === "string" ? output.value : JSON.stringify(output.value);
}

describe("poisoned repository", () => {
  test("plain git runs the fixture's programs", () => {
    const fixture = poisonedRepository();
    git(fixture, ["status", "--short"]);
    expect(sentinelRuns(fixture).length).toBeGreaterThan(0);
  });

  tmuxTest(
    "interactive startup and @ completion run none of the repository's programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway([], { classifierResponses: [] });
      gateways.push(gateway);
      const stderrPath = join(fixture.base, "stderr.log");
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: fxEnv(fixture, gateway),
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendLiteral("@alpha");
      await session.waitForPane(
        (pane) => pane.includes("alpha-tracked.txt") && pane.includes("alpha-untracked.txt"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;

      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.requests).toHaveLength(0);
    },
    TIMEOUT,
  );

  test(
    "glob, grep and auto-run git status answer without running the repository's programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway([
        fakeGatewayToolCall("glob", "glob_files", { pattern: "**/alpha-*.txt" }),
        fakeGatewayToolCall("grep", "grep_files", { pattern: "needle" }),
        fakeGatewayToolCall("status", "shell", {
          request: { action: "run", command: "git status --short", profile: "clean", yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      // `fx ask` reports each tool's activity on stderr.
      expect(result.stderr).toContain("Running git status --short");
      expect(result.stderr).not.toMatch(/panic|error/i);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(0);

      const bodies = gateway.requests.map((request: { body: string }) => request.body);
      const glob = toolResult(bodies[1]!, "glob");
      expect(glob).toContain("alpha-tracked.txt");
      expect(glob).toContain("notes/alpha-untracked.txt");
      const grep = toolResult(bodies[2]!, "grep");
      expect(grep).toContain("needle tracked two");
      expect(grep).toContain("needle untracked");
      const status = toolResult(bodies[3]!, "status");
      expect(status).toContain("M alpha-tracked.txt");
      expect(status).toContain("?? notes/");
    },
    TIMEOUT,
  );

  test(
    "auto mode holds a git command whose repository config fx cannot read",
    async () => {
      const fixture = poisonedRepository();
      // fx reads repository config only through regular files, so an include
      // that is a symlink leaves the config unread and safe git refuses.
      writeFileSync(join(fixture.base, "real.inc"), `[core]\n\tfsmonitor = ${join(fixture.base, "sentinel.sh")}\n`);
      symlinkSync(join(fixture.base, "real.inc"), join(fixture.workspace, ".git", "linked.inc"));
      git(fixture, ["config", "include.path", "linked.inc"]);
      const gateway = startFakeGateway([
        fakeGatewayToolCall("status", "shell", {
          request: { action: "run", command: "git status --short", profile: "clean", yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      expect(result.stderr).not.toMatch(/panic/i);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(0);
      const bodies = gateway.requests.map((request: { body: string }) => request.body);
      expect(toolResult(bodies[1]!, "status")).toContain("fx did not run this git command");
    },
    TIMEOUT,
  );

  test(
    "a git command in the default shell profile runs no repository program",
    async () => {
      const fixture = poisonedRepository();
      // The default `user` profile is the one the shell tool uses unless the
      // model asks for `clean`, and it is the profile a poisoned repository
      // must not reach either: fx runs these commands through safe git, and
      // refuses the shapes it cannot.
      const gateway = startFakeGateway([
        fakeGatewayToolCall("status-default", "shell", {
          request: { action: "run", command: "git status --short", yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("status-ignored", "shell", {
          request: { action: "run", command: "git status --short --ignored", yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("log-default", "shell", {
          request: { action: "run", command: "git log --oneline -n 2", yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("fetch", "shell", {
          request: { action: "run", command: "git fetch origin", yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      expect(result.stderr).not.toMatch(/panic|error/i);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(0);

      const bodies = gateway.requests.map((request: { body: string }) => request.body);
      expect(toolResult(bodies[1]!, "status-default")).toContain("M alpha-tracked.txt");
      expect(toolResult(bodies[2]!, "status-ignored")).toContain("M alpha-tracked.txt");
      expect(toolResult(bodies[3]!, "log-default")).toContain("fixture commit");
      expect(toolResult(bodies[4]!, "fetch")).toContain("fx did not run this git command");
    },
    TIMEOUT,
  );

  test(
    "a missing object does not make fx lazy fetch a repository's transport program",
    async () => {
      const fixture = poisonedRepository();
      // A partial clone fetches a missing object from its promisor remote on
      // demand, and that fetch starts the transport program the remote's
      // config names. `git show` reaches for a blob.
      const blob = git(fixture, ["rev-parse", "HEAD:alpha-tracked.txt"]).trim();
      rmSync(join(fixture.workspace, ".git", "objects", blob.slice(0, 2), blob.slice(2)), { force: true });
      const transport = join(fixture.base, "transport.sh");
      writeFileSync(transport, `#!/bin/sh\necho "ran $0 $*" >> '${fixture.log}'\nexit 0\n`);
      chmodSync(transport, 0o755);
      for (const [key, value] of [
        ["remote.origin.url", "file:///fixture-origin"],
        ["remote.origin.promisor", "true"],
        ["remote.origin.partialclonefilter", "blob:none"],
        ["remote.origin.uploadpack", transport],
        ["remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
      ]) git(fixture, ["config", key!, value!]);

      // The control proves the route is live: plain git starts the program.
      // The control run is expected to fail, because the transport program
      // does not speak the upload-pack protocol.
      writeFileSync(fixture.log, "");
      Bun.spawnSync(["git", "show", "HEAD"], {
        cwd: fixture.workspace,
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin",
          HOME: fixture.home,
          GIT_CONFIG_NOSYSTEM: "1",
          LC_ALL: "C",
        },
      });
      expect(sentinelRuns(fixture).length).toBeGreaterThan(0);

      // Start the fx run from an empty log, so the assertion below measures
      // only what fx did.
      writeFileSync(fixture.log, "");

      // Written another way, the same inspection goes to review and runs in
      // the shell, where the agent environment stops the lazy fetch.
      const gateway = startFakeGateway([
        fakeGatewayToolCall("show", "shell", {
          request: { action: "run", command: "git show HEAD", yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("show-reworded", "shell", {
          request: { action: "run", command: "cd notes && git show HEAD", yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "a repository format cannot make git show run a signature verifier",
    async () => {
      const fixture = poisonedRepository();
      const verifierLog = join(fixture.base, "verifier.log");
      const verifierRuns = () =>
        existsSync(verifierLog) ? readFileSync(verifierLog, "utf8").split("\n").filter(Boolean) : [];

      // A commit that carries a signature header, so git actually asks the
      // verifier instead of answering "no signature" on its own.
      const tree = git(fixture, ["rev-parse", "HEAD^{tree}"]).trim();
      const parent = git(fixture, ["rev-parse", "HEAD"]).trim();
      const body = [
        `tree ${tree}`,
        `parent ${parent}`,
        "author fixture <fixture@example.invalid> 1700000000 +0000",
        "committer fixture <fixture@example.invalid> 1700000000 +0000",
        "gpgsig -----BEGIN PGP SIGNATURE-----",
        " ",
        " iQEcBAABAgAGBQJfaketoken",
        " -----END PGP SIGNATURE-----",
        "",
        "signed-looking commit",
        "",
      ].join("\n");
      const hashed = Bun.spawnSync(
        ["/bin/sh", "-c", `printf '%s' '${body}' | git hash-object -t commit -w --stdin`],
        {
          cwd: fixture.workspace,
          env: {
            PATH: process.env.PATH ?? "/usr/bin:/bin",
            HOME: fixture.home,
            GIT_CONFIG_NOSYSTEM: "1",
            LC_ALL: "C",
          },
        },
      );
      const signed = hashed.stdout.toString().trim();
      expect(signed).toMatch(/^[0-9a-f]{40}$/);

      const verifier = join(fixture.base, "verifier.sh");
      writeFileSync(verifier, `#!/bin/sh\necho "ran $0 $*" >> '${verifierLog}'\nexit 1\n`);
      chmodSync(verifier, 0o755);
      // `%G?` asks for verification, so git runs the configured verifier.
      git(fixture, ["config", "format.pretty", "%G?"]);
      git(fixture, ["config", "gpg.program", verifier]);

      // The control proves the route is live: plain git starts the verifier.
      rmSync(verifierLog, { force: true });
      Bun.spawnSync(["git", "show", signed], {
        cwd: fixture.workspace,
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin",
          HOME: fixture.home,
          GIT_CONFIG_NOSYSTEM: "1",
          LC_ALL: "C",
        },
      });
      expect(verifierRuns().length).toBeGreaterThan(0);

      rmSync(verifierLog, { force: true });
      // Written another way, or with a format that asks for the check itself,
      // the inspection goes to review and runs in the shell, where the agent
      // environment sets the format aside and empties the verifier.
      const gateway = startFakeGateway([
        fakeGatewayToolCall("show", "shell", {
          request: { action: "run", command: `git show ${signed}`, yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("show-reworded", "shell", {
          request: { action: "run", command: `cd notes && git show ${signed}`, yield_time_ms: 30_000 },
        }),
        fakeGatewayToolCall("log-signature", "shell", {
          request: { action: "run", command: `git log -1 --format='%G? %s' ${signed}`, yield_time_ms: 30_000 },
        }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      expect(verifierRuns()).toEqual([]);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(2);
      const last = gateway.requests[gateway.requests.length - 1]!.body;
      expect(toolResult(last, "show-reworded")).toContain("signed-looking commit");
      expect(toolResult(last, "log-signature")).toContain("signed-looking commit");
    },
    TIMEOUT,
  );

  test(
    "git written another way, or in a terminal session, runs no repository program",
    async () => {
      const fixture = poisonedRepository();
      // None of these is a shape safe git runs directly, so each goes to
      // review and then runs in the shell, where the agent environment turns
      // off the repository's programs for every git it starts.
      const run = (id: string, command: string, extra: Record<string, unknown> = {}) =>
        fakeGatewayToolCall(id, "shell", {
          request: { action: "run", command, yield_time_ms: 30_000, ...extra },
        });
      const gateway = startFakeGateway([
        run("cd-status", "cd notes && git status --short"),
        run("dash-c-status", "git -C notes status --short"),
        run("chain", "git status --short && git diff --stat"),
        run("log-patch", "git log -p -n 1"),
        run("blame", "git blame alpha-tracked.txt"),
        run("tty-status", "git status --short", { tty: true }),
        fakeGatewayFinalText("inspection complete"),
      ]);
      gateways.push(gateway);

      // A terminal session needs a saved session; HOME is the fixture's own.
      const result = await runFx(
        ["ask", "--quiet", "--json", "Inspect the repository."],
        { cwd: fixture.workspace, env: fxEnv(fixture, gateway), timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      expect(result.stderr).not.toMatch(/panic|error/i);
      expect(sentinelRuns(fixture)).toEqual([]);
      expect(gateway.classifierRequests).toHaveLength(6);

      const last = gateway.requests[gateway.requests.length - 1]!.body;
      expect(toolResult(last, "cd-status")).toContain("alpha-tracked.txt");
      expect(toolResult(last, "dash-c-status")).toContain("alpha-tracked.txt");
      expect(toolResult(last, "chain")).toContain("alpha-tracked.txt");
      expect(toolResult(last, "log-patch")).toContain("+needle tracked one");
      expect(toolResult(last, "blame")).toContain("needle tracked two");
      expect(toolResult(last, "tty-status")).toContain("alpha-tracked.txt");
    },
    TIMEOUT,
  );

  test(
    "fx pr snapshots the repository without running its programs",
    async () => {
      const fixture = poisonedRepository();
      const gateway = startFakeGateway(
        [fakeGatewayFinalText("Draft title\n\n## Summary\n\n- Draft")],
        { classifierResponses: [] },
      );
      gateways.push(gateway);

      const result = await runFx(["pr"], {
        cwd: fixture.workspace,
        env: fxEnv(fixture, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(result.code, result.stderr).toBe(0);
      expect(sentinelRuns(fixture)).toEqual([]);
      const prompt = gateway.requests[0]?.body ?? "";
      for (const expected of ["Branch: main", "M alpha-tracked.txt", "fixture commit", "alpha-tracked.txt |"]) {
        expect(prompt).toContain(expected);
      }
    },
    TIMEOUT,
  );
});

// Dotfile managers often make `~/.gitconfig` a symlink. Files the user's own
// excludes file ignores must stay out of glob and grep through it, as in git.
describe("user git config through a symlink", () => {
  test(
    "glob and grep honor an excludes file named by a symlinked ~/.gitconfig",
    async () => {
      const base = realpathSync(mkdtempSync(join(tmpdir(), "fx-linked-gitconfig-")));
      const fixture: Fixture = { base, home: join(base, "home"), workspace: join(base, "workspace"), log: join(base, "unused.log") };
      fixtures.push(fixture);
      mkdirSync(join(fixture.home, ".fx"), { recursive: true });
      mkdirSync(join(fixture.home, "dotfiles"));
      mkdirSync(fixture.workspace);
      writeFileSync(join(fixture.home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false }));
      writeFileSync(join(fixture.home, "dotfiles", "ignore"), "*.secret\n");
      writeFileSync(join(fixture.home, "dotfiles", "gitconfig"), "[core]\n\texcludesFile = ~/dotfiles/ignore\n");
      symlinkSync(join(fixture.home, "dotfiles", "gitconfig"), join(fixture.home, ".gitconfig"));
      git(fixture, ["init", "-q", "--template=", "-b", "main"]);
      writeFileSync(join(fixture.workspace, "public.txt"), "needle public\n");
      writeFileSync(join(fixture.workspace, "api.secret"), "needle hidden\n");
      expect(git(fixture, ["ls-files", "-co", "--exclude-standard"]).trim()).toBe("public.txt");

      const gateway = startFakeGateway([
        fakeGatewayToolCall("glob", "glob_files", { pattern: "**/*" }),
        fakeGatewayToolCall("grep", "grep_files", { pattern: "needle" }),
        fakeGatewayFinalText("inspection complete"),
      ], { classifierResponses: [] });
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect the repository."],
        { cwd: fixture.workspace, env: { ...fxEnv(fixture, gateway), GIT_CONFIG_NOSYSTEM: "1" }, timeoutMs: TIMEOUT },
      );
      expect(result.code, result.stderr).toBe(0);
      const bodies = gateway.requests.map((request: { body: string }) => request.body);
      const glob = toolResult(bodies[1]!, "glob");
      expect(glob).toContain("public.txt");
      expect(glob).not.toContain("api.secret");
      const grep = toolResult(bodies[2]!, "grep");
      expect(grep).toContain("needle public");
      expect(grep).not.toContain("needle hidden");
    },
    TIMEOUT,
  );
});
