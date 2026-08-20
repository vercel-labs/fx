import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
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
import { hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

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
      expect(pane).toContain("General");
      expect(pane).toContain("Enter Open");
      expect(pane).not.toContain("Run /help for commands");
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
        expect(wideHelp!.indexOf("show available slash commands")).toBe(48);

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
        expect(narrowHelp!.indexOf("show available")).toBe(40);
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
      mkdirSync(home, { recursive: true });
      mkdirSync(join(repository, ".git"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(headPath, "ref: refs/heads/initial-branch\n");
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

        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("initial-branch"),
          10_000,
        );

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
          (pane) => pane.includes("s-root") && pane.includes("detached:"),
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
          await session.sendText("/status");
          await session.waitForText("model=", 5_000);
          await session.sendText(command);
          const pane = await session.waitForPane(
            (value) =>
              value.includes(banner) &&
              !value.includes("model=") &&
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
});

describe.skipIf(SKIP_TMUX)("tui: MCP startup", () => {
  test(
    "unresponsive MCP discovery does not block startup or shutdown",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-startup-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });

      let discoveryRequests = 0;
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          const body = await request.text();
          if (body.includes('"method":"server/discover"')) discoveryRequests += 1;
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
        const startupDeadline = Date.now() + 5_000;
        while (discoveryRequests < 1 && Date.now() < startupDeadline) {
          await Bun.sleep(25);
        }
        expect(discoveryRequests).toBe(1);

        await session.sendText("/mcp");
        const summary = await session.waitForText("1 connecting", 5_000);
        expect(summary).toContain("Use /mcp list for details.");
        await session.sendText("/mcp list");
        const status = await session.waitForText("state=connecting", 5_000);
        expect(status).toContain("pending source=profile scope=profile policy=optional");

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
});

describe.skipIf(SKIP_TMUX)("tui: credential onboarding", () => {
  test(
    "/setup opens the four-action setup hub without source rows",
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
      const setup = await session.waitForPane(
        (pane) =>
          pane.includes("Setup") &&
          pane.includes("Sign in with Vercel") &&
          pane.includes("API key") &&
          pane.includes("Change team") &&
          pane.includes("Switch credential"),
        TIMEOUT,
      );
      expect(setup).not.toContain("AI_GATEWAY_API_KEY");
      expect(setup).not.toContain("fx login");
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
      expect(initial).toContain("Esc to set up later");
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
