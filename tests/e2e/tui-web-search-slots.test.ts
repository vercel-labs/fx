// The web search slots in the TUI: a team whose AI Gateway refuses Exa sees
// one notice, the turn answers through the model's own search, and the next
// turn starts at that slot without a second notice.
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, startDynamicFakeGateway, tmuxAvailable } =
  await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const TIMEOUT = 60_000;
const NOTICE = "Web search: exa is not available for this team; using the model's own search.";
const REFUSAL = {
  error: {
    type: "invalid_request_error",
    message:
      "Gateway-executed tool(s) are not available for this team: gateway.exa_search. They send request content to vendor(s) outside this team's permitted provider set (exa). Remove the tool(s) to proceed.",
  },
};

const shellQuote = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;

// The provider tools a request carries, by id.
function providerTools(body: string): string[] {
  const tools = JSON.parse(body).tools;
  if (!Array.isArray(tools)) return [];
  return tools.filter((tool: { type?: string }) => tool.type === "provider").map((tool: { id: string }) => tool.id);
}

describe.skipIf(!tmuxAvailable())("tui: web search slots", () => {
  test(
    "a refused exa slot shows one notice and the turn answers through the model's own search",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-search-slots-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ session_titles: false, permission: { web_search: { "*": "allow" } } }),
      );
      const sent: string[][] = [];
      const gateway = startDynamicFakeGateway((raw) => {
        const tools = providerTools(raw);
        sent.push(tools);
        if (tools.includes("gateway.exa_search")) return Response.json(REFUSAL, { status: 400 });
        return fakeGatewayFinalText(`SLOT_ANSWER_${sent.length}`);
      }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
      const env: Record<string, string> = {
        PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
        TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-search-slots-key",
        FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_TEST_SKIP_ONBOARDING: "1",
        FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      };
      // Do not inherit provider overrides, credentials, shell startup, or dotenv state.
      const command = `/usr/bin/env -i ${Object.entries(env).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)}`;
      const terminal = await TmuxSession.create({
        cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
        width: 120, height: 32, startupWaitMs: 0,
      });
      try {
        await terminal.waitForComposer(20_000);
        await terminal.sendLiteral("what is new in zig");
        await terminal.sendKeys("Enter");
        await terminal.waitForText("SLOT_ANSWER_2", 20_000);
        await terminal.waitForText(NOTICE, 5_000);
        expect(sent).toEqual([["gateway.exa_search"], ["openai.web_search"]]);

        await terminal.waitForComposer(10_000);
        await terminal.sendLiteral("and since then");
        await terminal.sendKeys("Enter");
        const pane = await terminal.waitForText("SLOT_ANSWER_3", 20_000);
        expect(sent[2]).toEqual(["openai.web_search"]);
        expect(pane.split(NOTICE).length - 1).toBe(1);
      } finally {
        await terminal.kill();
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
