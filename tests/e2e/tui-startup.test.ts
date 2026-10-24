import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, HAS_API_KEY } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !HAS_API_KEY;
const SKIP_TMUX = !tmuxAvailable();
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

describe.skipIf(SKIP)("tui: startup and exit", () => {
  test(
    "fx launches and shows prompt",
    async () => {
      session = await TmuxSession.create();
      const pane = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(pane)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "/help opens the command catalog",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/help");
      const pane = await session.waitForText("Commands 39", 5_000);
      expect(pane).toContain("[All]");
      expect(pane).toContain("tab category");
      expect(pane).toContain("enter open");
      expect(pane).toContain("Run /help for commands");
    },
    TIMEOUT,
  );

  test(
    "/quit exits cleanly",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      expect(exited).toBe(true);
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: fresh-session commands", () => {
  test(
    "statusline hides the workspace identity by default",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-default-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace-default-hidden");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      mkdirSync(join(workspace, ".git"), { recursive: true });
      writeFileSync(join(workspace, ".git", "HEAD"), "ref: refs/heads/default-hidden-branch\n");
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).not.toContain("workspace-default-hidden");
        expect(pane).not.toContain("default-hidden-branch");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/help keeps command descriptions close after a wide-to-narrow resize",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-help-columns-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 160,
          height: 40,
        });

        await session.waitForComposer(10_000);
        await session.sendText("/help");
        const wide = await session.waitForPane(
          (pane) => pane.includes("/help") && pane.includes("show available slash commands"),
          5_000,
        );
        const wideHelp = wide.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available slash commands"),
        );
        expect(wideHelp).toBeDefined();
        const wideDescriptionColumn = wideHelp!.indexOf("show available slash commands");
        expect(wideDescriptionColumn).toBe(18);

        await session.resizeWindow(60, 40);
        const narrow = await session.waitForPane(
          (pane) => pane.split("\n").some(
            (line) => line.includes("/help") && line.includes("show available"),
          ),
          5_000,
        );
        const narrowHelp = narrow.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available"),
        );
        expect(narrowHelp).toBeDefined();
        expect(narrowHelp!.indexOf("show available")).toBe(wideDescriptionColumn);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "statusline refreshes the working directory and Git branch",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-")));
      const home = join(root, "home");
      const repository = join(root, "repository");
      const workspace = join(repository, "packages", "status-root");
      const headPath = join(repository, ".git", "HEAD");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(repository, ".git"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(headPath, "ref: refs/heads/initial-branch\n");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({ statusLine: { workspace: true }, fast_mode: false })}\n`,
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const initial = await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("initial-branch"),
          10_000,
        );
        expect(initial).not.toContain("⚡︎");

        writeFileSync(headPath, "ref: refs/heads/refreshed-branch\n");
        await session.resizeWindow(101, 30);
        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("refreshed-branch"),
          5_000,
        );

        writeFileSync(headPath, "0123456789abcdef0123456789abcdef01234567\n");
        await session.resizeWindow(100, 30);
        await session.waitForText("detached:0123456789ab", 5_000);

        await session.resizeWindow(50, 30);
        const narrow = await session.waitForPane(
          (pane) => pane.includes("s-root") && pane.includes("detached"),
          5_000,
        );
        expect(narrow).not.toContain("initial-branch");
        expect(session.isAlive()).toBe(true);

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "restore the launch header without retaining prior output",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-fresh-session-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 120,
          height: 40,
        });

        const initial = await session.waitForText(banner, 10_000);
        expect(initial.split(banner)).toHaveLength(2);

        for (const command of ["/clear", "/reset", "/new"]) {
          await session.sendText("/allowlist");
          await session.waitForText("* allowlist: effective", 5_000);
          await session.sendText(command);
          const pane = await session.waitForPane(
            (value) =>
              value.includes(banner) &&
              !value.includes("* allowlist:") &&
              hasEmptyComposer(value),
            5_000,
          );
          expect(pane.split(banner)).toHaveLength(2);
          expect(session.isAlive()).toBe(true);
        }

        await session.sendText("/clear");
        const repeated = await session.waitForPane(
          (value) => value.includes(banner) && hasEmptyComposer(value),
          5_000,
        );
        expect(repeated.split(banner)).toHaveLength(2);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/new preserves the visible transcript in terminal scrollback",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-scrollback-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");
      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            FX_DEBUG_RECORD_SILENT_BANNER: "1",
          },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        for (let i = 0; i < 8; i++) {
          await session.sendText("/allowlist");
          await session.waitForComposer(5_000);
        }
        const before = await session.captureFullScrollback();
        const lastNotice = before.slice(before.lastIndexOf("* allowlist:"));
        expect(lastNotice).toContain("* allowlist: effective persistent allow rules: (none)");

        await session.sendText("/new");
        await session.waitForPane(
          (pane) => pane.includes(banner) && !pane.includes("* allowlist:") && hasEmptyComposer(pane),
          5_000,
        );
        const after = await session.captureFullScrollback();
        const priorNotice = after.slice(after.lastIndexOf("* allowlist:"), after.lastIndexOf(banner)).trimEnd();
        expect(priorNotice).toBe(lastNotice.split("\n┃")[0]?.trimEnd());
        expect(priorNotice).not.toContain("Commands 1");
        expect(priorNotice).not.toContain("run /login ·");
        expect(await session.capturePane()).not.toContain("* allowlist:");
        const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], { encoding: "utf8" }));
        expect(replay.frame_count).toBeGreaterThan(0);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/new keeps a completed reply in scrollback and starts the next prompt fresh",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-reply-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("FIXTURE_REPLY_OK"));
      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            AI_GATEWAY_API_KEY: "new-fixture-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          stderrPath,
          width: 100,
          height: 24,
        });
        await session.waitForComposer(10_000);
        await session.sendText("first fixture prompt");
        await session.waitForText("FIXTURE_REPLY_OK", 10_000);
        await session.sendText("/new");
        await session.waitForPane((pane) => pane.includes(banner) && hasEmptyComposer(pane), 10_000);
        const history = await session.captureFullScrollback();
        expect(history.lastIndexOf("FIXTURE_REPLY_OK")).toBeLessThan(history.lastIndexOf(banner));
        expect(history).toContain("FIXTURE_REPLY_OK");

        await session.sendText("second fixture prompt");
        await session.waitForText("FIXTURE_REPLY_OK", 10_000);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("second fixture prompt");
        expect(gateway.requests[1].body).not.toContain("first fixture prompt");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/new waits for a resize before moving the old transcript into scrollback",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-resize-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "resize.fxtape");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");
      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            FX_DEBUG_RECORD_SILENT_BANNER: "1",
          },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        // Three local notices, one after another.
        for (const view of ["effective", "local", "user"]) {
          await session.sendText(`/allowlist view ${view}`);
          await session.waitForPane((pane) => pane.includes(`* allowlist: ${view} persistent allow rules`), 5_000);
        }
        const before = await session.captureFullScrollback();
        const expectedNotice = before.slice(before.lastIndexOf("* allowlist: effective")).split("\n┃")[0]?.trimEnd();
        expect(expectedNotice).toContain("* allowlist: user persistent allow rules: (none)");
        session.sendLiteralImmediate("/new");
        await session.resizeWindow(78, 18, 0);
        await Bun.sleep(40);
        session.sendKeysImmediate(["Enter"]);

        await session.waitForPane(
          (pane) => pane.includes(banner) && !pane.includes("* allowlist:") && hasEmptyComposer(pane),
          10_000,
        );
        const history = await session.captureFullScrollback();
        const oldNotice = history.slice(history.lastIndexOf("* allowlist: effective"), history.lastIndexOf(banner));
        let lastIndex = -1;
        for (const field of [
          "* allowlist: effective persistent allow rules: (none)",
          "* allowlist: local persistent allow rules: (none)",
          "* allowlist: user persistent allow rules: (none)",
        ]) {
          const index = oldNotice.indexOf(field);
          expect(index).toBeGreaterThan(lastIndex);
          lastIndex = index;
        }
        expect(oldNotice.replace(/\s+/g, "")).toBe(expectedNotice?.replace(/\s+/g, ""));
        expect(oldNotice).not.toContain("Commands 1");
        expect(oldNotice).not.toContain("run /login ·");
        expect(session.isAlive()).toBe(true);
        await session.sendText("/allowlist");
        await session.waitForPane((pane) => pane.includes("* allowlist: effective persistent allow rules") && hasEmptyComposer(pane), 5_000);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], { encoding: "utf8" }));
        expect(replay.frame_count).toBeGreaterThan(0);
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/quit exits after a fresh-session handoff times out at an invalid terminal size",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-invalid-size-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: { HOME: home, FX_AUTO_UPGRADE: "0", FX_TRACE_LOG: tracePath },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        await session.sendText("/allowlist");
        await session.waitForText("* allowlist: effective persistent allow rules", 5_000);
        session.sendLiteralImmediate("/new");
        await session.resizeWindow(78, 3, 0);
        session.sendKeysImmediate(["Enter"]);

        let trace = "";
        for (let attempt = 0; attempt < 100; attempt++) {
          trace = readFileSync(tracePath, "utf8");
          if (trace.includes("live_session_transition_deferred")) break;
          await Bun.sleep(25);
        }
        expect(trace).toContain("live_session_transition_deferred");
        session.sendLiteralImmediate("/quit");
        session.sendKeysImmediate(["Enter"]);
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(tracePath, "utf8")).toContain("live_session_transition_cancelled reason=resize_timeout");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: MCP startup", () => {
  test(
    "an unresponsive MCP server blocks neither startup nor quitting",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-startup-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });

      let requests = 0;
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          await request.text();
          requests += 1;
          return await new Promise<Response>(() => {});
        },
      });
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            pending: {
              type: "http",
              url: `http://127.0.0.1:${server.port}`,
              enabled: true,
            },
          },
        }),
      );

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
        });
        const pane = await session.waitForComposer(5_000);
        expect(hasEmptyComposer(pane)).toBe(true);
        // After the first frame the shell starts every server in the
        // background; this one never answers. Quitting waits for no server.
        const connectDeadline = Date.now() + 5_000;
        while (requests < 1 && Date.now() < connectDeadline) {
          await Bun.sleep(25);
        }
        expect(requests).toBeGreaterThanOrEqual(1);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        server.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a busy MCP sign-in store doesn't hold up the first frame",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-store-busy-")));
      const home = join(root, "home");
      const store = join(home, ".fx", "mcp-credentials");
      mkdirSync(store, { recursive: true, mode: 0o700 });
      const lock = join(store, "credentials-v3.lock");
      writeFileSync(lock, "", { mode: 0o600 });
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({ mcp: { remote: { type: "http", url: "http://127.0.0.1:9/mcp", enabled: true } } }),
      );
      const tracePath = join(root, "trace.log");
      // Another fx holds the store's lock, so reading the saved logins waits
      // for it, then gives up after 2 s.
      const holder = Bun.spawn(
        ["perl", "-e", 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep $ARGV[1];', lock, "20"],
        { stdout: "pipe" },
      );
      try {
        const { value } = await holder.stdout.getReader().read();
        expect(new TextDecoder().decode(value)).toBe("held\n");
        session = await TmuxSession.create({
          cwd: root,
          env: { HOME: home, FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_TRACE_LOG: tracePath },
        });
        await session.waitForComposer(10_000);
        let trace = "";
        const deadline = Date.now() + 10_000;
        while (Date.now() < deadline) {
          trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
          if (trace.includes("MCP credentials not loaded")) break;
          await Bun.sleep(50);
        }
        const gaveUp = trace.indexOf("MCP credentials not loaded err=LockBusy");
        const firstFrame = trace.indexOf("attempt_end outcome=committed");
        expect(gaveUp).toBeGreaterThan(-1);
        expect(firstFrame).toBeGreaterThan(-1);
        // The first frame is drawn while the saved logins are still being read.
        expect(firstFrame).toBeLessThan(gaveUp);
      } finally {
        holder.kill();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  // Before, the menu waited for the saved logins on the UI thread, so /mcp
  // right after launch froze the shell until they were read.
  test(
    "with the MCP sign-in store busy, /mcp opens before the saved logins are read",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-menu-busy-")));
      const home = join(root, "home");
      const store = join(home, ".fx", "mcp-credentials");
      mkdirSync(store, { recursive: true, mode: 0o700 });
      const lock = join(store, "credentials-v3.lock");
      writeFileSync(lock, "", { mode: 0o600 });
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({ mcp: { remote: { type: "http", url: "http://127.0.0.1:9/mcp", enabled: true } } }),
      );
      const tracePath = join(root, "trace.log");
      const loaded = () => (existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "").includes("MCP credentials not loaded");
      // Another fx holds the store's lock: reading the saved logins waits 2 s for it.
      const holder = Bun.spawn(
        ["perl", "-e", 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep $ARGV[1];', lock, "20"],
        { stdout: "pipe" },
      );
      try {
        const { value } = await holder.stdout.getReader().read();
        expect(new TextDecoder().decode(value)).toBe("held\n");
        session = await TmuxSession.create({
          cwd: root,
          env: { HOME: home, FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_TRACE_LOG: tracePath },
        });
        await session.waitForComposer(10_000);
        expect(loaded()).toBe(false);
        await session.sendText("/mcp");
        await session.waitForText("MCP servers  1", 5_000);
        // Still being read when the menu shows.
        expect(loaded()).toBe(false);
        // Once they're read, the menu goes on working.
        const deadline = Date.now() + 10_000;
        while (!loaded() && Date.now() < deadline) await Bun.sleep(50);
        expect(loaded()).toBe(true);
        await session.sendKeys("Enter");
        await session.waitForText("› Remove        /mcp remove remote", 5_000);
      } finally {
        holder.kill();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: credential onboarding", () => {
  test(
    "/setup opens the inline provider picker columns",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-direct-setup-")));
      session = await TmuxSession.create({
        env: {
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "0",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/setup");
      const picker = await session.waitForPane(
        (pane) =>
          pane.includes("/provider") &&
          pane.includes("vercel") &&
          pane.includes("codex") &&
          pane.includes("grok"),
        TIMEOUT,
      );
      expect(picker).not.toContain("Connections");
      expect(picker).not.toContain("Credential source");

      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => pane.includes("oauth") && pane.includes("api-key"),
        TIMEOUT,
      );

      // No key exists anywhere in this environment, so the api-key leaf skips
      // the which-key column and opens the paste field directly.
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Paste or type a key", TIMEOUT);

      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
    },
    TIMEOUT,
  );

  test(
    "startup shows credential onboarding on the first frame and Escape remains session-only",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-login-onboarding-")));
      const env = {
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        HOME: home,
        USER: "fx-e2e-login-onboarding",
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_NO_OPEN_BROWSER: "1",
        FX_SKIP_ONBOARDING: "0",
      };

      session = await TmuxSession.create({ env });

      const initial = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(initial).toContain("Sign in with Vercel");
      expect(initial).toContain("Add an API key");
      expect(initial).toContain("esc to set up later");
      expect(initial).not.toContain("Change team");
      expect(initial).not.toContain("Switch credential");
      expect(initial).not.toContain("Skip for now");

      await session.sendKeys("Escape");
      const skipped = await session.waitForPane(
        (pane) => !pane.includes("Welcome to fx") && !pane.includes("Sign in with Vercel"),
        TIMEOUT,
      );
      expect(skipped).not.toContain("Add an API key");

      await session.kill();
      session = await TmuxSession.create({ env });
      const restarted = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(restarted).toContain("Sign in with Vercel");
      expect(restarted).toContain("Add an API key");
    },
    60_000,
  );
});

describe.skipIf(SKIP_TMUX)("tui: custom themes", () => {
  async function startThemedSession(
    root: string,
    themeFiles: Record<string, unknown>,
    options: { fxTheme?: string; settingsTheme?: string; colorFgBg: string },
  ): Promise<{ pane: string; escapes: string; stderrPath: string }> {
    const home = join(root, "home");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx", "themes"), { recursive: true });
    for (const [file, contents] of Object.entries(themeFiles)) {
      writeFileSync(join(home, ".fx", "themes", file), JSON.stringify(contents));
    }
    if (options.settingsTheme) {
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ theme: options.settingsTheme }),
      );
    }
    writeFileSync(stderrPath, "");

    session = await TmuxSession.create({
      cwd: root,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_THEME: options.fxTheme,
        COLORFGBG: options.colorFgBg,
        COLORTERM: undefined,
        TERM_PROGRAM: "Apple_Terminal",
      },
      stderrPath,
      width: 100,
      height: 30,
    });
    const pane = await session.waitForComposer(10_000);
    const escapes = await session.capturePaneEscapes();
    return { pane, escapes, stderrPath };
  }

  test(
    "FX_THEME loads a VS Code theme file from ~/.fx/themes",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx", "themes"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "themes", "e2e-accent.json"),
        JSON.stringify({
          name: "E2E Accent",
          colors: { "editor.foreground": "#FF0000" },
        }),
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_THEME: "e2e-accent",
            COLORFGBG: "15;0",
            COLORTERM: undefined,
            TERM_PROGRAM: "Apple_Terminal",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).toContain("Run /help for commands");
        const escapes = await session.capturePaneEscapes();
        // editor.foreground #FF0000 quantizes to xterm-256 color 196 without
        // truecolor (Apple_Terminal), and themes the hint text at startup.
        expect(escapes).toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "pinned theme swaps to its sibling variant on a mismatched terminal",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-swap-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            "e2e-pair-light.json": { name: "Pair Light", type: "light", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        // The light sibling's hint (#00FF00 -> xterm-256 46) applies, not the
        // pinned dark theme's (#0000FF -> 21).
        expect(escapes).toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "pinned theme falls back to the builtin variant when no sibling exists",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-fallback-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal, no e2e-pair-light.json on disk
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-light hint, not the mismatched dark theme's blue.
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a sibling whose declared variant also mismatches falls back to builtin",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-misdeclared-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            // Misdeclared: named -light but says dark, with a green marker.
            "e2e-pair-light.json": { name: "Pair Light", type: "dark", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "settings.json theme applies without FX_THEME",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-settings-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", colorFgBg: "15;0" }, // dark terminal, no FX_THEME
        );
        expect(pane).toContain("Run /help for commands");
        // The configured theme's hint (#FF0000 -> xterm-256 196) applies.
        expect(escapes).toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "FX_THEME wins over the settings.json theme",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-precedence-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", fxTheme: "dark", colorFgBg: "15;0" },
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-dark hint (255), not the configured theme's red.
        expect(escapes).toContain("38;5;255");
        expect(escapes).not.toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "settings-pinned variant ignores live terminal mode flips",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-pin-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {},
          { settingsTheme: "dark", colorFgBg: "15;0" }, // dark terminal, pinned dark
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;255"); // fx-dark hint
        expect(escapes).not.toContain("38;5;235"); // fx-light hint

        // The terminal reports a light-mode change mid-session (DEC 997);
        // a pinned variant must not follow it.
        session!.sendKeysImmediate(["-H", "1b", "5b", "3f", "39", "39", "37", "3b", "32", "6e"]);
        await new Promise((resolve) => setTimeout(resolve, 1500));

        const after = await session!.capturePaneEscapes();
        expect(after).toContain("38;5;255");
        expect(after).not.toContain("38;5;235");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
