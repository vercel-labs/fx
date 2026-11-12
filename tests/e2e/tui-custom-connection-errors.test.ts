import { describe, expect, test } from "bun:test";
import { createConfiguredProviderFixture as fixture } from "./fixtures/chat-completions";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

// The TUI reports a custom connection's wrong settings the way `fx ask` does:
// the file, the setting's path, and what to do
// (`tests/e2e/configured-providers.test.ts` covers the other surfaces).
describe("TUI custom connection errors", () => {
  test.skipIf(!tmuxAvailable())("startup with a refused setting names the setting and what to do", async () => {
    const f = fixture();
    let tui: TmuxSession | null = null;
    try {
      const models = f.settings.providers.local.model_metadata as Record<string, any>;
      models["local-model"].request = { messages: [] };
      f.save();
      tui = await TmuxSession.create({ cwd: f.workspace, env: f.env, width: 160, height: 20, remainOnExit: true });
      // fx exits before it draws; tmux's own exit line then scrolls the
      // message above the visible screen, so read the whole scrollback.
      const message = "fx: ~/.fx/settings.json: providers.local.model_metadata.local-model.request.messages: fx writes this field itself; remove it";
      const deadline = Date.now() + 15000;
      let screen = "";
      while (Date.now() < deadline && !(screen.includes(message) && screen.includes("Pane is dead"))) {
        await Bun.sleep(100);
        screen = await tui.captureFullScrollback();
      }
      expect(screen).toContain(message);
      expect(screen).toContain("Pane is dead (status 1");
      expect(f.requests).toHaveLength(0);
    } finally {
      await tui?.kill();
      f.close();
    }
  }, 30000);

  test.skipIf(!tmuxAvailable())("a request whose header variable is unset names the header, the connection, and the variable", async () => {
    const f = fixture();
    let tui: TmuxSession | null = null;
    try {
      f.settings.providers.local.headers = { "X-Org": { env: "FX_PROBE_ORG" } };
      f.save();
      tui = await TmuxSession.create({ cwd: f.workspace, env: f.env, width: 200, height: 30 });
      await tui.waitForComposer(15000);
      await tui.sendText("hello");
      await tui.sendKeys("Enter");
      await tui.waitForText("the header X-Org of connection local reads FX_PROBE_ORG, which is not set", 20000);
      expect(f.requests).toHaveLength(0);
    } finally {
      await tui?.kill();
      f.close();
    }
  }, 40000);

  // Opening a saved session in the TUI checks its connection before the
  // first frame; a changed or removed one stops fx with what to do.
  test.skipIf(!tmuxAvailable()).each([
    ["changed its protocol", (f: ReturnType<typeof fixture>) => { f.settings.providers.local.protocol = "anthropic-messages"; },
      "fx: This session's custom connection changed in ~/.fx/settings.json after the session was saved: its protocol, base_url, or auth. Change it back, or start a new session."],
    ["was removed", (f: ReturnType<typeof fixture>) => {
      delete (f.settings.providers as Record<string, unknown>).local;
      (f.settings as Record<string, unknown>).provider = "remote";
    }, "fx: This session's custom connection is no longer in ~/.fx/settings.json. Add it back, or start a new session."],
  ] as const)("resume: a session whose connection %s says so before the first frame", async (_name, edit, message) => {
    const f = fixture();
    let tui: TmuxSession | null = null;
    try {
      const first = await runFx(["ask", "--json", "first turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      edit(f);
      f.save();
      tui = await TmuxSession.create({ cmd: `${FX_BIN} --resume ${session}`, cwd: f.workspace, env: f.env, width: 200, height: 20, remainOnExit: true });
      const deadline = Date.now() + 15000;
      let screen = "";
      while (Date.now() < deadline && !(screen.includes(message) && screen.includes("Pane is dead"))) {
        await Bun.sleep(100);
        screen = await tui.captureFullScrollback();
      }
      expect(screen).toContain(message);
      expect(screen).toContain("Pane is dead (status 1");
      expect(f.requests).toHaveLength(1);
    } finally {
      await tui?.kill();
      f.close();
    }
  }, 40000);

  test.skipIf(!tmuxAvailable())("resume: /resume names a session's changed connection", async () => {
    const f = fixture();
    let tui: TmuxSession | null = null;
    try {
      const first = await runFx(["ask", "--json", "first turn"], { cwd: f.workspace, env: f.env, timeoutMs: 15000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      f.settings.providers.local.protocol = "anthropic-messages";
      f.save();
      tui = await TmuxSession.create({ cwd: f.workspace, env: f.env, width: 220, height: 30 });
      await tui.waitForComposer(15000);
      await tui.sendText("/resume");
      // The only saved session is selected, so Enter opens it.
      await tui.sendKeys("Enter");
      await tui.waitForText("This session's custom connection changed in ~/.fx/settings.json after the session was saved", 15000);
      expect(f.requests).toHaveLength(1);
    } finally {
      await tui?.kill();
      f.close();
    }
  }, 50000);

  test.skipIf(!tmuxAvailable())("a connection changed during a session says so on the next turn, without offering a retry", async () => {
    const f = fixture();
    let tui: TmuxSession | null = null;
    try {
      tui = await TmuxSession.create({ cwd: f.workspace, env: f.env, width: 220, height: 30 });
      await tui.waitForComposer(15000);
      await tui.sendText("first turn");
      await tui.sendKeys("Enter");
      await tui.waitForText("local reply", 15000);
      f.settings.providers.local.protocol = "anthropic-messages";
      f.save();
      await tui.sendText("second turn");
      await tui.sendKeys("Enter");
      const screen = await tui.waitForText("This session's custom connection changed in ~/.fx/settings.json after the session was saved", 15000);
      expect(screen).not.toContain("press enter to retry");
      expect(f.requests).toHaveLength(1);
    } finally {
      await tui?.kill();
      f.close();
    }
  }, 50000);
});
