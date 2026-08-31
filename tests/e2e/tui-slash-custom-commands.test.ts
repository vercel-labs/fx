import { afterEach, describe, expect, test } from "bun:test";
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
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const TEST_TIMEOUT = 120_000;

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function createFixture(label: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-custom-commands-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const promptsRoot = join(workspace, ".fx", "prompts");
  const stderrPath = join(root, "stderr.log");
  const tracePath = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(promptsRoot, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}\n");
  tempDirs.push(root);
  return { home, promptsRoot, stderrPath, tracePath, workspace };
}

function nestedText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(nestedText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [nestedText(value.text), nestedText(value.value), nestedText(value.content)].join("");
  }
  return "";
}

function gatewayPromptText(body: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  return request.prompt.map((message) => nestedText(message.content)).join("\n");
}

function readTrace(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

describe.skipIf(SKIP)("tui: custom slash commands", () => {
  test(
    "workspace command appears in completion and sends its expanded prompt",
    async () => {
      const fixture = createFixture("happy");
      writeFileSync(
        join(fixture.promptsRoot, "review-pr.md"),
        [
          "---",
          "description: Review a pull request",
          "argument-hint: <number> [focus]",
          "---",
          "CUSTOM_REVIEW number=$1 focus=${2:-general}",
          "CUSTOM_REVIEW arguments=$ARGUMENTS literal=$$",
          "",
        ].join("\n"),
      );

      gateway = startFakeGateway([fakeGatewayFinalText("CUSTOM_REVIEW_COMPLETE")]);
      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "local-fixture-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        },
        stderrPath: fixture.stderrPath,
        width: 260,
        height: 30,
      });
      await session.waitForComposer(10_000);

      await session.sendLiteralText("/review");
      const completion = await session.waitForText(fixture.promptsRoot, 5_000);
      expect(completion).toContain("/review-pr <number> [focus]");
      expect(completion).toContain(`Review a pull request (${fixture.promptsRoot})`);

      await session.sendKeys("C-u");
      await session.sendText("/help");
      await session.waitForText("Commands 38", 5_000);
      await session.sendLiteralText("review-pr");
      const help = await session.waitForText("Commands 1", 5_000);
      expect(help).toContain("/review-pr <number> [focus]");
      expect(help).toContain(fixture.promptsRoot);
      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) => hasEmptyComposer(pane) && !pane.includes("Enter Open"),
        5_000,
      );

      await session.sendText("/review-pr 512 security");
      await session.waitForText("CUSTOM_REVIEW_COMPLETE", 10_000);

      expect(gateway.requests).toHaveLength(1);
      expect(gatewayPromptText(gateway.requests[0]!.body)).toContain(
        "CUSTOM_REVIEW number=512 focus=security\n" +
          "CUSTOM_REVIEW arguments=512 security literal=$",
      );
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );

  test(
    "rejected files are diagnosed while valid custom and builtin commands remain available",
    async () => {
      const fixture = createFixture("rejections");
      writeFileSync(join(fixture.promptsRoot, "help.md"), "CUSTOM_HELP_MUST_NOT_LOAD\n");
      writeFileSync(
        join(fixture.promptsRoot, "malformed.md"),
        "---\ndescription: unterminated frontmatter\nMALFORMED_MUST_NOT_LOAD\n",
      );
      writeFileSync(join(fixture.promptsRoot, "still-works.md"), "VALID_CUSTOM_BODY\n");

      session = await TmuxSession.create({
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: fixture.tracePath,
          FX_TRACE_SCOPES: "commands",
        },
        stderrPath: fixture.stderrPath,
        width: 260,
        height: 30,
      });
      await session.waitForComposer(10_000);

      const trace = readTrace(fixture.tracePath);
      expect(trace).toContain("cause=builtin_collision");
      expect(trace).toContain("command 'help' conflicts with a built-in command");
      expect(trace).toContain("cause=invalid_frontmatter");
      expect(trace).toContain("invalid command frontmatter");

      await session.sendLiteralText("/still");
      const completion = await session.waitForText("/still-works", 5_000);
      expect(completion).toContain(fixture.promptsRoot);
      expect(completion).not.toContain("/malformed");

      await session.sendKeys("C-u");
      await session.sendText("/help");
      const help = await session.waitForText("Enter Open", 5_000);
      expect(help).toContain("/help");
      expect(help).not.toContain("CUSTOM_HELP_MUST_NOT_LOAD");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });

      await session.sendKeys("Escape");
      await session.waitForPane(hasEmptyComposer, 5_000);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
    },
    TEST_TIMEOUT,
  );
});
