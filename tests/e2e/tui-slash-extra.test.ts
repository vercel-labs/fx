import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  HAS_API_KEY,
} from "../evals/eval-helpers";
import { readTrace } from "./tui-render-assertions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !HAS_API_KEY;
const TIMEOUT = 30_000;
const LONG_TIMEOUT = 120_000;
const TRACE_SCOPES = "agent,worker,gateway,tool,permission,history,interrupt,prompt";
const CLIPBOARD_PROGRAM = process.platform === "darwin"
  ? "pbcopy"
  : process.platform === "linux"
    ? "xclip"
    : null;

let session: TmuxSession | null = null;

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

async function launchAndWait(): Promise<TmuxSession> {
  const s = await TmuxSession.create();
  await s.waitForComposer(10_000);
  return s;
}

describe.skipIf(!tmuxAvailable())("tui: skills command recovery", () => {
  test(
    "invalid /skills create name reports an inline error and preserves the session",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-invalid-skill-name-"));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);

      try {
        session = await TmuxSession.create({
          cwd: root,
          stderrPath,
          env: { HOME: home },
          width: 100,
          height: 28,
        });
        await session.waitForComposer(10_000);

        await session.sendText("/skills create ../escape-attempt");
        const rejected = await session.waitForText("Invalid skill name.", 5_000);
        expect(rejected).toContain(
          "Use a single directory name without '/' or '\\'.",
        );
        expect(session.isAlive()).toBe(true);
        expect(hasEmptyComposer(rejected)).toBe(true);
        expect(existsSync(join(home, ".fx", "escape-attempt"))).toBe(false);

        await session.sendText("/skills path");
        const recovered = await session.waitForText("fx managed install root:", 5_000);
        expect(hasEmptyComposer(recovered)).toBe(true);
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

function startFakeCreditsGateway() {
  const requests: Array<{
    method: string;
    path: string;
    authorizationMatchesExpected: boolean;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      requests.push({
        method: request.method,
        path: new URL(request.url).pathname,
        authorizationMatchesExpected:
          request.headers.get("authorization") ===
          "Bearer credits-fake-key",
      });
      return Response.json(
        { error: { code: "credit_card_required", message: "Buy credits to use AI Gateway." } },
        { status: 403 },
      );
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}/v1/credits`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

describe.skipIf(!tmuxAvailable())("tui: credits slash command", () => {
  test(
    "/credits shows actionable Gateway denial and returns to prompt",
    async () => {
      const gateway = startFakeCreditsGateway();
      const home = createIsolatedTestHome();
      try {
        session = await TmuxSession.create({
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "credits-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_E2E_GATEWAY_CREDITS_URL: gateway.url,
          },
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);

        await session.sendText("/credits");
        await session.waitForText("Buy credits to use AI Gateway.", 10_000);
        await session.waitForComposer(10_000);

        const scrollback = await session.captureFullScrollback();
        expect(gateway.requests).toEqual([{
          method: "GET",
          path: "/v1/credits",
          authorizationMatchesExpected: true,
        }]);
        expect(scrollback).toContain("API access denied");
        expect(scrollback).toContain("HTTP 403");
        expect(scrollback).toContain("Buy credits to use AI Gateway.");
        expect(hasEmptyComposer(scrollback)).toBe(true);
      } finally {
        gateway.stop();
        try {
          if (session) {
            await session.kill();
            session = null;
          }
        } finally {
          cleanupIsolatedTestHome(home);
        }
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(!tmuxAvailable() || CLIPBOARD_PROGRAM === null)("tui: clipboard host", () => {
  test(
    "/copy sends exact reply bytes to the host clipboard and reports process failure",
    async () => {
      if (CLIPBOARD_PROGRAM === null) throw new Error("unsupported clipboard platform");

      const workDir = mkdtempSync(join(tmpdir(), "fx-clipboard-host-"));
      const homeDir = join(workDir, "home");
      const binDir = join(workDir, "bin");
      const capturePath = join(workDir, "clipboard.txt");
      const stderrPath = join(workDir, "stderr.log");
      const clipboardPath = join(binDir, CLIPBOARD_PROGRAM);
      mkdirSync(homeDir);
      mkdirSync(binDir);
      writeFileSync(clipboardPath, "#!/bin/sh\ncat > \"$FX_TEST_CLIPBOARD_CAPTURE\"\n");
      chmodSync(clipboardPath, 0o755);

      const reply = "clipboard host sentinel\nsecond line";
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(reply));
      try {
        session = await TmuxSession.create({
          cwd: workDir,
          stderrPath,
          env: {
            HOME: homeDir,
            AI_GATEWAY_API_KEY: "clipboard-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_TEST_CLIPBOARD_CAPTURE: capturePath,
            PATH: `${binDir}:${process.env.PATH ?? ""}`,
          },
        });
        await session.waitForComposer(10_000);

        await session.sendText("reply for clipboard");
        await session.waitForText("clipboard host sentinel", 10_000);
        await session.waitForComposer(10_000);
        await session.sendText("/copy");
        await session.waitForText("Copied to clipboard.", 5_000);

        expect(readFileSync(capturePath, "utf8")).toBe(reply);

        writeFileSync(clipboardPath, "#!/bin/sh\nexit 23\n");
        await session.sendText("/copy");
        await session.waitForText("Failed to copy to clipboard.", 5_000);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
        rmSync(workDir, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(!tmuxAvailable())("tui: active session transitions", () => {
  test(
    "active /clear cancels a fake Gateway turn and accepts a follow-up prompt",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-active-clear-"));
      const homeDir = mkdtempSync(join(tmpdir(), "fx-active-clear-home-"));
      const stderrPath = join(workDir, "stderr.log");
      let requestCount = 0;
      const gateway = startDynamicFakeGateway(() => {
        requestCount += 1;
        if (requestCount > 1) return fakeGatewayFinalText("NATIVE_FOLLOWUP_OK");
        return new Promise<Response>(() => {});
      });

      try {
        session = await TmuxSession.create({
          cwd: workDir,
          stderrPath,
          env: {
            HOME: homeDir,
            AI_GATEWAY_API_KEY: "active-clear-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);

        await session.sendText("start an active turn");
        await session.waitForText("Thinking", 10_000);
        await session.sendText("/clear");
        await session.waitForComposer(10_000);

        await session.sendText("complete the follow-up");
        await session.waitForText("NATIVE_FOLLOWUP_OK", 10_000);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("complete the follow-up");
        expect(gateway.requests[1].body).not.toContain("start an active turn");
        expect(session.isAlive()).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
        rmSync(workDir, { recursive: true, force: true });
        rmSync(homeDir, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP)("tui: extra slash commands", () => {
  test(
    "/clear clears the screen",
    async () => {
      session = await launchAndWait();
      const before = await session.capturePane();
      await session.sendText("/clear");
      await new Promise((r) => setTimeout(r, 500));
      const after = await session.capturePane();
      expect(after.trim().length).toBeLessThanOrEqual(before.trim().length);
    },
    TIMEOUT,
  );

  test(
    "/clear resets projected history before the next prompt",
    async () => {
      const workDir = mkdtempSync(join(tmpdir(), "fx-row03-clear-"));
      const homeDir = mkdtempSync(join(tmpdir(), "fx-row03-clear-home-"));
      const tracePath = join(workDir, "trace.log");
      mkdirSync(join(homeDir, ".fx"), { recursive: true });
      writeFileSync(
        join(homeDir, ".fx", "settings.json"),
        JSON.stringify({ permission: { ask_user_question: "deny" } }),
      );
      const gateway = startDynamicFakeGateway(() =>
        fakeGatewayFinalText("pineapple fixture response")
      );

      try {
        session = await TmuxSession.create({
          cwd: workDir,
          env: {
            HOME: homeDir,
            AI_GATEWAY_API_KEY: "clear-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_TRACE_SCOPES: TRACE_SCOPES,
            FX_TRACE_LOG: tracePath,
          },
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);

        await session.sendText("Reply exactly: pineapple noted. Do not use tools or ask questions.");
        await waitForTraceCount(tracePath, "event=prompt_finish", 1, 90_000);

        await session.sendText("/clear");
        await session.waitForComposer(10_000);

        await session.sendText("what word did I ask you to remember?");
        await waitForTraceCount(tracePath, "event=projection_start", 2, 90_000);
        const trace = await waitForTraceCount(tracePath, "event=projection_end", 2, 90_000);

        const projectionStarts = trace
          .split("\n")
          .filter((line) => line.includes("event=projection_start"));
        const postClearStart = projectionStarts[projectionStarts.length - 1];
        expect(postClearStart).toContain("history_turns=0");
        expect(postClearStart).toContain("history_turn_kinds=none");

        const projectionEnds = trace
          .split("\n")
          .filter((line) => line.includes("event=projection_end"));
        const postClearEnd = projectionEnds[projectionEnds.length - 1];
        expect(postClearEnd).toContain("history_turns=0");
        expect(postClearEnd).toContain("added_gateway_messages=0");
        expect(postClearEnd).toContain("projected_message_roles=none");
        expect(gateway.requests).toHaveLength(2);
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
        rmSync(workDir, { recursive: true, force: true });
        rmSync(homeDir, { recursive: true, force: true });
      }
    },
    LONG_TIMEOUT,
  );

  test(
    "/new resets to a fresh prompt",
    async () => {
      session = await launchAndWait();
      await session.sendText("/new");
      await new Promise((r) => setTimeout(r, 500));
      const pane = await session.waitForComposer(5_000);
      expect(hasEmptyComposer(pane)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "/stats shows session statistics",
    async () => {
      session = await launchAndWait();
      await session.sendText("/stats");
      const pane = await session.waitForText(/stats|token|turn|step/i, 5_000);
      expect(pane.toLowerCase()).toMatch(/stats|token|turn|step/);
    },
    TIMEOUT,
  );

  test(
    "/usage and /cost open the same compact local usage dashboard",
    async () => {
      const home = mkdtempSync(join(tmpdir(), "fx-usage-empty-home-"));
      session = await TmuxSession.create({ env: { HOME: home } });
      await session.waitForComposer(10_000);
      await session.sendText("/cost");
      const pane = await session.waitForText(
        /Tracking has not started/,
        5_000,
      );
      expect(pane).toContain("Usage · 30 days");
      expect(pane).not.toMatch(/^● Usage/m);
      expect(pane).toContain("←→ Scope");
      expect(pane).toContain("R Refresh");
      expect(pane).toContain("Esc Close");
      await session.sendKeys("Escape");
      await session.waitForComposer(5_000);
      await session.sendText("/usage");
      const aliasPane = await session.waitForText(
        /Tracking has not started/,
        5_000,
      );
      expect(aliasPane).toContain("Usage · 30 days");
    },
    TIMEOUT,
  );

  test(
    "/credits shows credit info",
    async () => {
      session = await launchAndWait();
      await session.sendText("/credits");
      const pane = await session.waitForText(/credit|balance|error|failed/i, 10_000);
      expect(pane.length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );

  test(
    "/mcp shows MCP status",
    async () => {
      session = await launchAndWait();
      await session.sendText("/mcp");
      const pane = await session.waitForText(/mcp|server|no|configured/i, 5_000);
      expect(pane.toLowerCase()).toMatch(/mcp|server|no|configured/);
    },
    TIMEOUT,
  );

  test(
    "/skills opens the skills menu",
    async () => {
      session = await launchAndWait();
      await session.sendText("/skills");
      const pane = await session.waitForText(/Skills [0-9]+|No skills available|All [0-9]+/i, 5_000);
      expect(pane).not.toContain("Visible skills (");
    },
    TIMEOUT,
  );

  test(
    "/alias shows alias list",
    async () => {
      session = await launchAndWait();
      await session.sendText("/alias");
      const pane = await session.waitForText(/alias|no|none|defined/i, 5_000);
      expect(pane.toLowerCase()).toMatch(/alias|no|none|defined/);
    },
    TIMEOUT,
  );

  test(
    "/copy handles empty history gracefully",
    async () => {
      session = await launchAndWait();
      await session.sendText("/copy");
      const pane = await session.waitForText(/copy|copied|nothing|empty|clipboard/i, 5_000);
      expect(pane.length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );
});

async function waitForTraceCount(
  path: string,
  needle: string,
  minCount: number,
  timeoutMs: number,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = readTrace(path);
    if (countOccurrences(trace, needle) >= minCount) return trace;
    await sleep(500);
  }
  throw new Error(
    `Timed out waiting for ${minCount} trace markers ${needle}.\nTrace contents:\n${readTrace(path)}`,
  );
}

function countOccurrences(value: string, needle: string): number {
  let count = 0;
  let offset = 0;
  while (true) {
    const next = value.indexOf(needle, offset);
    if (next < 0) return count;
    count += 1;
    offset = next + needle.length;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
