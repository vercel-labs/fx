import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import { hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 15_000;
const GLM_MODEL = "zai/glm-5.2-fast";
const GEMINI_MODEL = "google/gemini-2.5-flash";
const IMAGE_PATH = join(REPO_ROOT, "tests/e2e/fixtures/placeholder-logo.png");

type CapturedRequest = {
  body: string;
  headers: Headers;
};

function sseText(text: string) {
  return new Response(
    [
      `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n`,
      `data: ${JSON.stringify({
        type: "finish",
        finishReason: { unified: "stop", raw: "stop" },
        usage: {
          inputTokens: { total: 11 },
          outputTokens: { total: 13 },
        },
      })}\n\n`,
      "data: [DONE]\n\n",
    ].join(""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function sseToolCall(toolName: string, input: object, toolCallId: string) {
  return sseToolCalls([{ toolName, input, toolCallId }]);
}

function sseToolCalls(
  calls: Array<{ toolName: string; input: object; toolCallId: string }>,
) {
  return new Response(
    [
      ...calls.map(
        ({ toolName, input, toolCallId }) =>
          `data: ${JSON.stringify({ type: "tool-call", toolCallId, toolName, input })}\n\n`,
      ),
      `data: ${JSON.stringify({
        type: "finish",
        finishReason: { unified: "tool-calls", raw: "tool-calls" },
      })}\n\n`,
      "data: [DONE]\n\n",
    ].join(""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

const VISION_RESULT = JSON.stringify({
  images: [
    {
      image_id: 1,
      status: "ok",
      summary: "FX logo in a square mark",
      visible_text: ["FX LOGO"],
      details: ["square layout"],
    },
  ],
});

function visionResult(imageId: number, summary: string) {
  return JSON.stringify({
    images: [
      {
        image_id: imageId,
        status: "ok",
        summary,
        visible_text: [`IMAGE ${imageId}`],
        details: ["deterministic fixture"],
      },
    ],
  });
}

function visionBatchResult(imageIds: number[]) {
  return JSON.stringify({
    images: imageIds.map((imageId) => ({
      image_id: imageId,
      status: "ok",
      summary: `summary-${imageId}`,
      visible_text: [],
      details: [],
    })),
  });
}

function filePartCount(body: string) {
  return body.match(/"type":"file"/g)?.length ?? 0;
}

function nativeFileParts(body: string) {
  return promptParts(body).filter(
    (part): part is Record<string, unknown> & { data: string; mediaType: string } =>
      part.type === "file" &&
      typeof part.data === "string" &&
      typeof part.mediaType === "string",
  );
}

function expectVisionResponseFormat(body: string, imageCount: number) {
  const request = JSON.parse(body) as {
    responseFormat?: {
      type?: string;
      name?: string;
      schema?: {
        type?: string;
        required?: string[];
        additionalProperties?: boolean;
        properties?: {
          images?: {
            type?: string;
            minItems?: number;
            maxItems?: number;
            items?: {
              anyOf?: Array<{
                type?: string;
                required?: string[];
                additionalProperties?: boolean;
                properties?: Record<string, unknown>;
              }>;
            };
          };
        };
      };
    };
  };
  expect(request.responseFormat).toMatchObject({
    type: "json",
    name: "fx_vision_evidence",
    schema: {
      type: "object",
      required: ["images"],
      additionalProperties: false,
      properties: {
        images: {
          type: "array",
          minItems: imageCount,
          maxItems: imageCount,
        },
      },
    },
  });

  const alternatives = request.responseFormat?.schema?.properties?.images?.items?.anyOf;
  expect(alternatives).toHaveLength(2);
  expect(alternatives?.[0]).toMatchObject({
    type: "object",
    required: ["image_id", "status", "summary", "visible_text", "details"],
    additionalProperties: false,
    properties: {
      image_id: { type: "integer" },
      status: { type: "string", enum: ["ok"] },
      summary: { type: "string" },
      visible_text: { type: "array", items: { type: "string" } },
      details: { type: "array", items: { type: "string" } },
    },
  });
  expect(alternatives?.[1]).toMatchObject({
    type: "object",
    required: ["image_id", "status", "error"],
    additionalProperties: false,
    properties: {
      image_id: { type: "integer" },
      status: { type: "string", enum: ["failed"] },
      error: { type: "string", enum: ["vision_unavailable"] },
    },
  });
  expect(
    (alternatives?.[0].properties?.image_id as { enum?: unknown } | undefined)?.enum,
  ).toBeUndefined();
  expect(
    (alternatives?.[1].properties?.image_id as { enum?: unknown } | undefined)?.enum,
  ).toBeUndefined();
}

function startImageGateway(
  responses: Response[],
  onChatRequest?: (index: number, body: string) => void,
) {
  const chatRequests: CapturedRequest[] = [];
  let catalogRequests = 0;
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        catalogRequests += 1;
        return Response.json({
          data: [
            {
              id: GEMINI_MODEL,
              type: "language",
              tags: ["vision", "file-input", "tool-use"],
            },
            {
              id: GLM_MODEL,
              type: "language",
              tags: ["tool-use"],
            },
          ],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      chatRequests.push({ body, headers: req.headers });
      onChatRequest?.(chatRequests.length - 1, body);
      return responses.shift() ?? new Response("unexpected request", { status: 500 });
    },
  });

  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    chatRequests,
    get catalogRequests() {
      return catalogRequests;
    },
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-vision-route-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: {} }));
  return { root, home, workspace: realpathSync(workspace) };
}

function createScopedImageFixture(root: ReturnType<typeof createIsolatedRoot>) {
  const nested = join(root.workspace, "assets", "nested");
  const sibling = join(root.workspace, "sibling");
  mkdirSync(nested, { recursive: true });
  mkdirSync(sibling, { recursive: true });
  const imagePath = join(nested, "fixture.png");
  copyFileSync(IMAGE_PATH, imagePath);

  const rootRule = "IMAGE_CONTEXT_ROOT_SENTINEL";
  const nestedRule = "IMAGE_CONTEXT_NESTED_SENTINEL";
  const siblingRule = "IMAGE_CONTEXT_SIBLING_MUST_BE_ABSENT";
  writeFileSync(join(root.workspace, "AGENTS.md"), `${rootRule}\n`);
  writeFileSync(join(nested, "AGENTS.md"), `${nestedRule}\n`);
  writeFileSync(join(sibling, "AGENTS.md"), `${siblingRule}\n`);
  return { imagePath, rootRule, nestedRule, siblingRule };
}

function writeMarkedImage(imagePath: string, marker: string) {
  copyFileSync(IMAGE_PATH, imagePath);
  writeFileSync(
    imagePath,
    Buffer.concat([readFileSync(imagePath), Buffer.from(marker)]),
  );
  return readFileSync(imagePath).toString("base64");
}

function writeLegacyZeroImageSession(
  root: ReturnType<typeof createIsolatedRoot>,
  sessionId: string,
  imagePaths: [string, string, string, string],
) {
  const sessionDir = join(root.home, ".fx", "sessions", sessionId);
  mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(sessionDir, "session.json"),
    JSON.stringify({
      schema_version: 2,
      id: sessionId,
      created_at_ms: 1,
      updated_at_ms: 2,
      workspace_root: root.workspace,
      conversation_language: "en",
      history_len: 4,
      history: [
        {
          kind: "assistant",
          user: {
            text: "Legacy first image: [Image #1]",
            images: [{ path: imagePaths[0], media_type: "image/png" }],
          },
          assistant: "Legacy first answer.",
        },
        {
          kind: "assistant",
          user: {
            text: "Legacy second image: [Image #1]",
            images: [{ path: imagePaths[1], media_type: "image/png" }],
          },
          assistant: "Legacy second answer.",
        },
        {
          kind: "assistant",
          user: {
            text: "Legacy existing image: [Image #3]",
            images: [{ id: 3, path: imagePaths[2], media_type: "image/png" }],
          },
          assistant: "Legacy existing answer.",
        },
        {
          kind: "assistant",
          user: {
            text: "Legacy later image: [Image #9]",
            images: [{ path: imagePaths[3], media_type: "image/png" }],
          },
          assistant: "Legacy later answer.",
        },
      ],
      total_input_tokens: 0,
      total_output_tokens: 0,
    }) + "\n",
    { mode: 0o600 },
  );
}

function expectScopedImageContext(
  body: string,
  fixture: ReturnType<typeof createScopedImageFixture>,
) {
  expect(body).toContain(fixture.rootRule);
  expect(body).toContain(fixture.nestedRule);
  expect(body).not.toContain(fixture.siblingRule);
  expect(body.indexOf(fixture.rootRule)).toBeLessThan(body.indexOf(fixture.nestedRule));
}

function fakeGatewayEnv(
  root: ReturnType<typeof createIsolatedRoot>,
  gateway: ReturnType<typeof startImageGateway>,
  model: string,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-vision-route-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: model,
  };
}

async function expectNonRegularVisionPathFailure(
  root: ReturnType<typeof createIsolatedRoot>,
  relativePath: string,
  recoveryText: string,
) {
  const gateway = startImageGateway([
    sseToolCall(
      "vision",
      { paths: [relativePath], focus: "inspect this path" },
      "vision_non_regular_path",
    ),
    sseText(recoveryText),
  ]);
  const stderrPath = join(root.root, "stderr.log");
  writeFileSync(stderrPath, "");
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: root.workspace,
      env: {
        ...fakeGatewayEnv(root, gateway, GLM_MODEL),
        FX_PERMISSION_MODE: "ask",
        FX_AUTO_UPGRADE: "0",
        NO_COLOR: "1",
      },
      stderrPath,
      width: 140,
      height: 50,
    });
    await session.waitForPane(hasEmptyComposer, TIMEOUT);
    await session.sendText("Inspect the requested path.");
    await session.waitForText(recoveryText, TIMEOUT);
    await session.waitForPane(hasEmptyComposer, TIMEOUT);

    expect(gateway.chatRequests).toHaveLength(2);
    expect(gateway.chatRequests[1]!.body).toContain(
      "Vision paths must reference regular files.",
    );
    expect(gateway.chatRequests[1]!.body).not.toContain('"type":"file"');
    expect(readFileSync(stderrPath, "utf8")).toBe("");

    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
    session = null;
  } finally {
    if (session) await session.kill();
    gateway.stop();
  }
}

async function expectChangedCanonicalVisionPathFailure(
  root: ReturnType<typeof createIsolatedRoot>,
  recoveryText: string,
  replaceTarget: (targetPath: string) => void,
  forbiddenPayload?: string,
  additionalHiddenPaths: string[] = [],
) {
  const targetPath = join(root.workspace, "target-a.png");
  const approvedPath = join(root.workspace, "approved.png");
  writeMarkedImage(targetPath, "TMUX_APPROVED_TARGET_A");
  symlinkSync(targetPath, approvedPath);
  writeFileSync(
    join(root.home, ".fx", "settings.json"),
    JSON.stringify({ permission_mode: "ask", permission: {} }),
  );
  const gateway = startImageGateway([
    sseToolCall(
      "vision",
      { paths: ["approved.png"], focus: "inspect the approved image path" },
      "vision_changed_canonical_path",
    ),
    sseText(recoveryText),
  ]);
  const stderrPath = join(root.root, "stderr.log");
  writeFileSync(stderrPath, "");
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: root.workspace,
      env: {
        ...fakeGatewayEnv(root, gateway, GLM_MODEL),
        FX_PERMISSION_MODE: "ask",
        FX_AUTO_UPGRADE: "0",
        NO_COLOR: "1",
      },
      stderrPath,
      width: 140,
      height: 50,
    });
    await session.waitForPane(hasEmptyComposer, TIMEOUT);
    await session.sendText("Inspect the approved image path.");
    await session.waitForText("Would you like to allow this action?", TIMEOUT);
    await session.waitForText(targetPath, TIMEOUT);

    replaceTarget(targetPath);
    await session.sendKeys("1");
    await session.sendKeys("Enter");
    await session.waitForText(recoveryText, TIMEOUT);
    await session.waitForPane(hasEmptyComposer, TIMEOUT);

    expect(gateway.chatRequests).toHaveLength(2);
    expect(gateway.chatRequests[1]!.body).not.toContain('"type":"file"');
    if (forbiddenPayload) {
      expect(gateway.chatRequests[1]!.body).not.toContain(forbiddenPayload);
    }
    expect(gateway.chatRequests[1]!.body).toContain(
      "Vision could not load an approved image path",
    );
    for (const request of gateway.chatRequests) {
      expect(request.body).not.toContain(targetPath);
      expect(request.body).not.toContain(approvedPath);
      for (const path of additionalHiddenPaths) {
        expect(request.body).not.toContain(path);
      }
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");

    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
    session = null;
  } finally {
    if (session) await session.kill();
    gateway.stop();
  }
}

function parseFxJson(result: Awaited<ReturnType<typeof runFx>>) {
  expect(result.code).toBe(0);
  return JSON.parse(result.stdout.trim()) as {
    output: string;
    exit_code: number;
    model: string;
    session_id: string;
    tool_calls: Array<{ name: string; status: string }>;
  };
}

function parseFxErrorJson(result: Awaited<ReturnType<typeof runFx>>) {
  expect(result.code).toBe(1);
  return JSON.parse(result.stdout.trim()) as {
    output: string;
    exit_code: number;
    error: string;
  };
}

function textFromContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => {
      if (!part || typeof part !== "object") return "";
      const value = part as Record<string, unknown>;
      return value.type === "text" && typeof value.text === "string" ? value.text : "";
    })
    .join("\n");
}

function lastUserText(body: string): string {
  const parsed = JSON.parse(body) as { prompt: Array<{ role?: string; content?: unknown }> };
  const users = parsed.prompt.filter((entry) => entry.role === "user");
  expect(users.length).toBeGreaterThan(0);
  return textFromContent(users[users.length - 1].content);
}

function promptParts(body: string): Array<Record<string, unknown>> {
  const parsed = JSON.parse(body) as { prompt: Array<{ content?: unknown }> };
  return parsed.prompt.flatMap((message) =>
    Array.isArray(message.content)
      ? message.content.filter(
          (part): part is Record<string, unknown> => !!part && typeof part === "object",
        )
      : [],
  );
}

function toolResultText(body: string, toolCallId: string): string {
  const result = promptParts(body).find(
    (part) => part.type === "tool-result" && part.toolCallId === toolCallId,
  );
  expect(result).toBeDefined();
  const output = result?.output as Record<string, unknown> | undefined;
  expect(typeof output?.value).toBe("string");
  return output?.value as string;
}

describe("Vision route fake Gateway", () => {
  test(
    "fx ask rejects missing images before Gateway startup in text and JSON modes",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([]);
      const missingPath = join(root.workspace, "missing-image.png");
      try {
        const textResult = await runFx(
          ["ask", "--no-save", "--image", missingPath, "Describe the image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(textResult.code).toBe(1);
        expect(textResult.stdout).toBe("");
        expect(textResult.stderr).toContain(missingPath);
        expect(textResult.stderr).toContain("image file not found");

        const jsonResult = await runFx(
          ["ask", "--json", "--no-save", "--image", missingPath, "Describe the image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxErrorJson(jsonResult);
        expect(json.output).toBe("");
        expect(json.error).toContain("FileNotFound");
        expect(json.error).toContain(missingPath);
        expect(jsonResult.stderr).toBe("");
        expect(gateway.catalogRequests).toBe(0);
        expect(gateway.chatRequests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "oversized images are rejected once before Gateway startup and the TUI stays alive",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([]);
      const oversizedPath = join(root.workspace, "oversized.png");
      writeFileSync(oversizedPath, Buffer.from("\x89PNG\r\n\x1a\n"));
      truncateSync(oversizedPath, 20 * 1024 * 1024 + 1);
      const notice = "image exceeds the 20 MiB limit";
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        const cliResult = await runFx(
          ["ask", "--no-save", "--image", oversizedPath, "Describe the image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(cliResult.code).toBe(1);
        expect(cliResult.stdout).toBe("");
        expect(cliResult.stderr).toContain(notice);
        expect(cliResult.stderr.split(notice)).toHaveLength(2);
        expect(gateway.catalogRequests).toBe(0);
        expect(gateway.chatRequests).toHaveLength(0);

        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 120,
          height: 40,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText(`/image ${oversizedPath}`);
        await session.waitForText(notice, TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        const scrollback = await session.captureFullScrollback();
        expect(scrollback.split(notice)).toHaveLength(2);
        expect(scrollback).not.toContain("attached image: oversized.png");
        expect(gateway.catalogRequests).toBe(1);
        expect(gateway.chatRequests).toHaveLength(0);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "fx ask gates GLM images through Vision without leaking paths",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "describe the image" }, "vision_1"),
        sseText(VISION_RESULT),
        sseText("GLM final image answer"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.exit_code).toBe(0);
        expect(json.output).toContain("GLM final image answer");
        expect(gateway.catalogRequests).toBe(1);
        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[0].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        expect(gateway.chatRequests[0].body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[0].body).toContain('"name":"vision"');
        expect(gateway.chatRequests[0].body).toContain("[Image #1]");
        expect(gateway.chatRequests[0].body).not.toContain('"type":"file"');
        expectScopedImageContext(gateway.chatRequests[0].body, fixture);
        expect(gateway.chatRequests[1].body).toContain('"type":"file"');
        expect(gateway.chatRequests[1].body).not.toContain(fixture.rootRule);
        expect(gateway.chatRequests[1].body).not.toContain(fixture.nestedRule);
        expect(gateway.chatRequests[2].body).toContain("FX LOGO");
        expect(gateway.chatRequests[2].body).not.toContain('"type":"file"');
        expectScopedImageContext(gateway.chatRequests[2].body, fixture);
        const finalUserText = lastUserText(gateway.chatRequests[2].body);
        expect(finalUserText).not.toContain(fixture.imagePath);
        expect(finalUserText).not.toContain(root.home);
        expect(finalUserText).not.toContain(root.workspace);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask recovers when the model rejects the post-Vision prompt as assistant prefill",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const prefillRejection = new Response(
        JSON.stringify({
          error: {
            message:
              "AI_APICallError: This model does not support assistant message prefill. " +
              "The conversation must end with a user message.",
          },
        }),
        { status: 400, headers: { "content-type": "application/json" } },
      );
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { image_ids: [1], focus: "describe the image" },
          "vision_prefill_recovery",
        ),
        sseText(VISION_RESULT),
        prefillRejection,
        sseText("Recovered final image answer"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.exit_code).toBe(0);
        expect(json.output).toContain("Recovered final image answer");
        expect(gateway.chatRequests).toHaveLength(4);

        const rejectedPrompt = JSON.parse(gateway.chatRequests[2].body).prompt;
        expect(rejectedPrompt.at(-1)).toMatchObject({ role: "tool" });
        const retryPrompt = JSON.parse(gateway.chatRequests[3].body).prompt;
        expect(retryPrompt.at(-1)).toMatchObject({ role: "user" });
        expect(JSON.stringify(retryPrompt.at(-1))).toContain(
          "Continue from the preceding tool result.",
        );
        expect(result.stderr).toBe("Inspecting images\n");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask executes path-source Vision and cleans transient snapshots without failure telemetry",
    async () => {
      const root = createIsolatedRoot();
      const imagePath = join(root.workspace, "path-source.png");
      const tracePath = join(root.root, "trace.log");
      const snapshotsBefore = readdirSync("/tmp")
        .filter((name) => name.startsWith("fx-image-snapshots-"))
        .sort();
      writeMarkedImage(imagePath, "HEADLESS_PATH_SOURCE");
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { paths: ["path-source.png"], focus: "inspect the supplied path" },
          "vision_path_source",
        ),
        sseText(visionResult(1, "path-source evidence")),
        sseText("Path-source final answer"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "Inspect the image at path=path-source.png.",
          ],
          {
            cwd: root.workspace,
            env: {
              ...fakeGatewayEnv(root, gateway, GLM_MODEL),
              FX_TRACE_LOG: tracePath,
              FX_TRACE_SCOPES: "images",
            },
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("Path-source final answer");
        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[0]!.body).toContain('"name":"vision"');
        expect(gateway.chatRequests[0]!.body).toContain('"paths":{"type":"array"');
        expect(gateway.chatRequests[1]!.body).toContain('"type":"file"');
        expect(gateway.chatRequests[1]!.body).not.toContain(imagePath);
        expect(gateway.chatRequests[2]!.body).toContain("path-source evidence");
        expect(gateway.chatRequests[2]!.body).not.toContain(imagePath);
        expect(readFileSync(tracePath, "utf8")).not.toContain("snapshot_cleanup_failed");
        expect(
          readdirSync("/tmp")
            .filter((name) => name.startsWith("fx-image-snapshots-"))
            .sort(),
        ).toEqual(snapshotsBefore);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "source replacement deletion and symlink retarget do not change captured Vision bytes",
    async () => {
      const cases: Array<{
        name: string;
        prepare: (root: ReturnType<typeof createIsolatedRoot>) => {
          imageArg: string;
          payloadA: string;
          payloadB?: string;
          mutate: () => void;
          paths: string[];
        };
      }> = [
        {
          name: "replace",
          prepare(root) {
            const imagePath = join(root.workspace, "replace.png");
            const payloadA = writeMarkedImage(imagePath, "SOURCE_REPLACE_A");
            const replacementPath = join(root.workspace, "replacement.png");
            const payloadB = writeMarkedImage(replacementPath, "SOURCE_REPLACE_B");
            return {
              imageArg: imagePath,
              payloadA,
              payloadB,
              paths: [imagePath, replacementPath],
              mutate: () => writeFileSync(imagePath, readFileSync(replacementPath)),
            };
          },
        },
        {
          name: "delete",
          prepare(root) {
            const imagePath = join(root.workspace, "delete.png");
            const payloadA = writeMarkedImage(imagePath, "SOURCE_DELETE_A");
            return {
              imageArg: imagePath,
              payloadA,
              paths: [imagePath],
              mutate: () => rmSync(imagePath, { force: true }),
            };
          },
        },
        {
          name: "symlink",
          prepare(root) {
            const targetA = join(root.workspace, "target-a.png");
            const targetB = join(root.workspace, "target-b.png");
            const linkPath = join(root.workspace, "linked.png");
            const payloadA = writeMarkedImage(targetA, "SOURCE_SYMLINK_A");
            const payloadB = writeMarkedImage(targetB, "SOURCE_SYMLINK_B");
            symlinkSync(targetA, linkPath);
            return {
              imageArg: linkPath,
              payloadA,
              payloadB,
              paths: [targetA, targetB, linkPath],
              mutate: () => {
                rmSync(linkPath, { force: true });
                symlinkSync(targetB, linkPath);
              },
            };
          },
        },
      ];

      for (const entry of cases) {
        const root = createIsolatedRoot();
        const fixture = entry.prepare(root);
        let mutated = false;
        const gateway = startImageGateway(
          [
            sseToolCall("vision", { image_ids: [1], focus: entry.name }, `vision_${entry.name}`),
            sseText(VISION_RESULT),
            sseText(`final ${entry.name}`),
          ],
          (index) => {
            if (index === 0 && !mutated) {
              mutated = true;
              fixture.mutate();
            }
          },
        );
        try {
          const result = await runFx(
            [
              "ask",
              "--json",
              "--auto",
              "--no-save",
              "--no-color",
              "--image",
              fixture.imageArg,
              `Inspect ${entry.name}.`,
            ],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, GLM_MODEL),
              timeoutMs: TIMEOUT,
            },
          );

          const json = parseFxJson(result);
          expect(json.output).toContain(`final ${entry.name}`);
          expect(gateway.chatRequests).toHaveLength(3);
          expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
          expect(gateway.chatRequests[1].body).toContain(fixture.payloadA);
          if (fixture.payloadB) expect(gateway.chatRequests[1].body).not.toContain(fixture.payloadB);
          for (const request of gateway.chatRequests) {
            for (const imagePath of fixture.paths) expect(request.body).not.toContain(imagePath);
            expect(request.body).not.toContain("data:image");
            expect(request.body).not.toContain("fx-image-snapshots");
            expect(request.body).not.toContain(".fx/sessions");
          }
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "required Vision rejects read_file and remains required before normal Vision recovery",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const forbiddenPath = join(root.workspace, "must-not-read.txt");
      const forbiddenContents = "FORBIDDEN_REQUIRED_VISION_READ_SENTINEL";
      writeFileSync(forbiddenPath, forbiddenContents);
      const gateway = startImageGateway([
        sseToolCall("read_file", { path: forbiddenPath }, "read_before_vision"),
        sseToolCall("vision", { image_ids: [1], focus: "inspect" }, "vision_after_rejection"),
        sseText(VISION_RESULT),
        sseText("Recovered after required Vision rejection"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("Recovered after required Vision rejection");
        expect(json.tool_calls).toContainEqual({ name: "read_file", status: "error" });
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(gateway.chatRequests).toHaveLength(4);
        expect(gateway.chatRequests[0].body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[1].body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[1].body).toContain("read_before_vision");
        expect(gateway.chatRequests[1].body).toContain(
          "Only Vision can be called while attached images are pending.",
        );
        expect(gateway.chatRequests[1].body).not.toContain(forbiddenContents);
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(1);
        expect(gateway.chatRequests[3].body).toContain("FX LOGO");
        expect(gateway.chatRequests[3].body).not.toContain(forbiddenContents);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask preserves native image parts for Gemini",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const gateway = startImageGateway([sseText("Gemini native image answer")]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.exit_code).toBe(0);
        expect(json.output).toContain("Gemini native image answer");
        expect(gateway.catalogRequests).toBe(1);
        expect(gateway.chatRequests).toHaveLength(1);
        expect(gateway.chatRequests[0].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[0].body).toContain('"type":"file"');
        expectScopedImageContext(gateway.chatRequests[0].body, fixture);
        expect(gateway.chatRequests[0].body).not.toContain(fixture.imagePath);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask normalizes encoded-oversized native images on macOS and rejects elsewhere",
    async () => {
      const root = createIsolatedRoot();
      const oversizedPath = join(root.workspace, "encoded-oversized.png");
      copyFileSync(IMAGE_PATH, oversizedPath);
      truncateSync(oversizedPath, (5 * 1024 * 1024 * 3) / 4 + 1);
      const notice = "Unable to prepare this image for upload. Use a smaller image.";
      const gateway = startImageGateway(
        process.platform === "darwin" ? [sseText("Normalized native image answer")] : [],
      );
      try {
        if (process.platform === "darwin") {
          const result = await runFx(
            [
              "ask",
              "--json",
              "--no-save",
              "--no-color",
              "--image",
              oversizedPath,
              "Describe the attached image.",
            ],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
              timeoutMs: TIMEOUT,
            },
          );

          const json = parseFxJson(result);
          expect(json.output).toContain("Normalized native image answer");
          expect(json.tool_calls).toHaveLength(0);
          expect(result.stderr).toBe("");
          expect(gateway.chatRequests).toHaveLength(1);
          const parts = nativeFileParts(gateway.chatRequests[0]!.body);
          expect(parts).toHaveLength(1);
          expect(parts[0]!.mediaType).toBe("image/jpeg");
          expect(parts[0]!.data.length).toBeLessThanOrEqual(5 * 1024 * 1024);
          return;
        }

        const textResult = await runFx(
          ["ask", "--no-save", "--image", oversizedPath, "Describe the image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(textResult.code).toBe(1);
        expect(textResult.stdout).toBe("");
        expect(textResult.stderr).toContain(notice);

        const jsonResult = await runFx(
          ["ask", "--json", "--no-save", "--image", oversizedPath, "Describe the image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const errorJson = parseFxErrorJson(jsonResult);
        expect(errorJson.error).toBe("ImagePreparationFailed");
        expect(jsonResult.stderr).toBe("");
        expect(gateway.chatRequests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "saved native ID rejection recovers immediately and is filtered after resume",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect" }, "native_vision"),
        sseText("Gemini recovered after rejected Vision"),
        sseText("Gemini continued without historical Vision evidence"),
      ]);
      try {
        const first = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const firstJson = parseFxJson(first);
        expect(firstJson.session_id.length).toBeGreaterThan(0);
        expect(firstJson.output).toContain("Gemini recovered after rejected Vision");
        expect(firstJson.tool_calls).toContainEqual({ name: "vision", status: "error" });
        expect(first.stderr).not.toContain("Inspecting images");
        expect(first.stderr).not.toContain("Vision is unavailable right now");
        expect(gateway.chatRequests).toHaveLength(2);
        expect(gateway.chatRequests[0].body).toContain('"name":"vision"');
        expect(gateway.chatRequests[0].body).toContain('"paths":{"type":"array"');
        expect(gateway.chatRequests[0].body).not.toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[0].body).toContain('"type":"file"');

        const recoveryRequest = gateway.chatRequests[1];
        const recoveryParts = promptParts(recoveryRequest.body);
        expect(recoveryParts).toContainEqual(
          expect.objectContaining({
            type: "tool-call",
            toolCallId: "native_vision",
            toolName: "vision",
          }),
        );
        const rejectionResult = recoveryParts.find(
          (part) => part.type === "tool-result" && part.toolCallId === "native_vision",
        );
        expect(rejectionResult?.toolName).toBe("vision");
        const rejectionOutput = (rejectionResult?.output as { value?: unknown } | undefined)?.value;
        expect(typeof rejectionOutput).toBe("string");
        expect(JSON.parse(rejectionOutput as string)).toMatchObject({
          error: {
            type: "tool_execution_failed",
            tool_name: "vision",
            message: "Vision is unavailable for this request.",
          },
        });
        expect(rejectionOutput as string).not.toContain(fixture.imagePath);
        expect(filePartCount(recoveryRequest.body)).toBe(1);

        const resumed = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            firstJson.session_id,
            "Continue with the saved native image context.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const resumedJson = parseFxJson(resumed);
        expect(resumedJson.session_id).toBe(firstJson.session_id);
        expect(resumedJson.output).toContain(
          "Gemini continued without historical Vision evidence",
        );
        expect(resumedJson.tool_calls).toHaveLength(0);

        expect(gateway.chatRequests).toHaveLength(3);
        const resumedRequest = gateway.chatRequests[2];
        expect(filePartCount(resumedRequest.body)).toBe(1);
        expect(resumedRequest.body).toContain('"name":"vision"');
        expect(resumedRequest.body).toContain('"paths":{"type":"array"');
        expect(resumedRequest.body).not.toContain('"toolChoice":{"type":"required"}');
        expect(resumedRequest.body).not.toContain('"toolName":"vision"');
        expect(resumedRequest.body).not.toContain("native_vision");
        expect(resumedRequest.body).not.toContain("Vision is unavailable for this request.");
        for (const request of gateway.chatRequests) {
          expect(request.headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
          expect(request.body).not.toContain(fixture.imagePath);
        }
        const resumedUserText = lastUserText(resumedRequest.body);
        expect(resumedUserText).not.toContain(fixture.imagePath);
        expect(resumedUserText).not.toContain(root.home);
        expect(resumedUserText).not.toContain(root.workspace);

        const detail = await runFx(
          ["session", "--id", firstJson.session_id, "--json"],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(detail.code).toBe(0);
        expect(detail.stderr).toBe("");
        const persisted = JSON.stringify(JSON.parse(detail.stdout));
        expect(persisted).toContain("native_vision");
        expect(persisted).toContain("Vision is unavailable for this request.");
        expect(gateway.chatRequests).toHaveLength(3);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "missing or corrupted owned snapshots fail without a Vision provider request",
    async () => {
      const cases = [
        {
          name: "deleted",
          damage(snapshotPath: string) {
            rmSync(snapshotPath, { force: true });
          },
        },
        {
          name: "corrupted",
          damage(snapshotPath: string) {
            writeFileSync(snapshotPath, Buffer.from("not the captured image"));
          },
        },
      ];

      for (const entry of cases) {
        const root = createIsolatedRoot();
        const imagePath = join(root.workspace, `${entry.name}.png`);
        const imagePayload = writeMarkedImage(
          imagePath,
          `OWNED_${entry.name.toUpperCase()}_A`,
        );
        const gateway = startImageGateway([
          sseText(`saved ${entry.name}`),
          sseToolCall("vision", { image_ids: [1], focus: entry.name }, `vision_${entry.name}`),
          sseText(`final ${entry.name}`),
        ]);
        try {
          const saved = await runFx(
            [
              "ask",
              "--json",
              "--auto",
              "--no-color",
              "--image",
              imagePath,
              `Save ${entry.name} image.`,
            ],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
              timeoutMs: TIMEOUT,
            },
          );
          const savedJson = parseFxJson(saved);
          expect(savedJson.output).toContain(`saved ${entry.name}`);
          expect(gateway.chatRequests).toHaveLength(1);

          const imageDir = join(root.home, ".fx", "sessions", savedJson.session_id, "images");
          const snapshotNames = readdirSync(imageDir).filter((name) => name.endsWith(".bin"));
          expect(snapshotNames).toHaveLength(1);
          entry.damage(join(imageDir, snapshotNames[0]));

          const reread = await runFx(
            [
              "ask",
              "--json",
              "--auto",
              "--no-color",
              "--resume-id",
              savedJson.session_id,
              `Reread ${entry.name} image.`,
            ],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, GLM_MODEL),
              timeoutMs: TIMEOUT,
            },
          );
          const rereadJson = parseFxJson(reread);
          expect(rereadJson.output).toContain(`final ${entry.name}`);
          expect(rereadJson.tool_calls).toContainEqual({ name: "vision", status: "error" });
          expect(gateway.chatRequests).toHaveLength(3);
          expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
          expect(gateway.chatRequests[1].body).toContain('"name":"vision"');
          expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
          const resultText = toolResultText(
            gateway.chatRequests[2].body,
            `vision_${entry.name}`,
          );
          expect(resultText).toContain('"code":"image_unavailable"');
          expect(resultText).toContain('"retryable":false');
          expect(resultText).toContain(
            "do not retry the same snapshot unchanged",
          );
          expect(resultText).not.toContain("provider_response_invalid");
          expect(gateway.chatRequests[2].body).not.toContain("Vision is unavailable right now");
          expect(gateway.chatRequests[2].body).not.toContain(imageDir);
          expect(gateway.chatRequests[2].body).not.toContain(imagePath);
          expect(gateway.chatRequests[2].body).not.toContain(imagePayload);
          expect(gateway.chatRequests[2].body).not.toContain("data:image");
          expect(
            gateway.chatRequests.some(
              (request, index) =>
                index > 0 && request.headers.get("ai-language-model-id") === GEMINI_MODEL,
            ),
          ).toBe(false);
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask applies image_adapter_output_bytes to Vision provider capture",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "describe the image" }, "vision_bound"),
        sseText(VISION_RESULT),
        sseText("bounded Vision answer"),
      ]);
      try {
        const result = await runFx(
          [
            "--context-limit",
            "image_adapter_output_bytes=64",
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("bounded Vision answer");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "error" });
        expect(result.stderr).toBe("Inspecting images\n");
        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        const resultText = toolResultText(gateway.chatRequests[2].body, "vision_bound");
        expect(resultText).toContain('"code":"output_limit_exceeded"');
        expect(resultText).toContain('"retryable":true');
        expect(resultText).toContain("narrower focus or fewer images");
        expect(resultText).not.toContain("provider_response_invalid");
        expect(
          gateway.chatRequests.filter(
            (request) => request.headers.get("ai-language-model-id") === GEMINI_MODEL,
          ),
        ).toHaveLength(1);
        expect(gateway.chatRequests[2].body).not.toContain(
          '"toolChoice":{"type":"required"}',
        );
        expect(gateway.chatRequests[2].body).not.toContain(
          "Tip: This model doesn’t support OCR",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "text-only GLM ask skips image capability and Vision IO",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([sseText("text only answer")]);
      try {
        const result = await runFx(
          ["ask", "--json", "--no-save", "--no-color", "Reply exactly OK."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.exit_code).toBe(0);
        expect(json.output).toContain("text only answer");
        expect(gateway.catalogRequests).toBe(0);
        expect(gateway.chatRequests).toHaveLength(1);
        expect(gateway.chatRequests[0].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        expect(gateway.chatRequests[0].body).not.toContain('"type":"file"');
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "Vision outage is an ordinary failed tool result with the exact notice",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "describe the image" }, "vision_outage"),
        new Response("vision unavailable", { status: 502 }),
        new Response("vision unavailable", { status: 502 }),
        new Response("vision unavailable", { status: 502 }),
        sseText("Vision unavailable final answer"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--no-save",
            "--no-color",
            "--image",
            IMAGE_PATH,
            "Describe the attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("Vision unavailable final answer");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "error" });
        expect(result.stderr).toContain("Inspecting images\n");
        expect(result.stderr).toContain(
          "Tip: This model doesn’t support OCR, and Vision is unavailable right now. Try switching to a vision-capable model.",
        );
        expect(gateway.catalogRequests).toBe(1);
        expect(gateway.chatRequests.length).toBeGreaterThanOrEqual(3);
        expect(gateway.chatRequests[0].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        const providerRequests = gateway.chatRequests.slice(1, -1);
        for (const request of providerRequests) {
          expect(request.headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
          expect(request.body).toContain('"type":"file"');
        }
        expect(gateway.chatRequests.at(-1)?.headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        const resultText = toolResultText(
          gateway.chatRequests.at(-1)!.body,
          "vision_outage",
        );
        expect(resultText).toContain('"code":"vision_unavailable"');
        expect(resultText).toContain('"retryable":true');
        expect(resultText).toContain("Retry later, change model or strategy");
        expect(gateway.chatRequests.at(-1)?.body).toContain(
          "None of the requested images were read by Vision.",
        );
        expect(gateway.chatRequests.at(-1)?.body).not.toContain(
          '"toolChoice":{"type":"required"}',
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "cold resume rebases image ids and preserves authority across both model-switch directions",
    async () => {
      const root = createIsolatedRoot();
      const fixture = createScopedImageFixture(root);
      const secondImagePath = join(root.workspace, "second.png");
      copyFileSync(IMAGE_PATH, secondImagePath);
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "first image" }, "vision_first"),
        sseText(visionResult(1, "first image evidence")),
        sseText("text route completed"),
        sseText("native route completed"),
        sseToolCall("vision", { image_ids: [2], focus: "reread second image" }, "vision_second"),
        sseText(visionResult(2, "second image evidence")),
        sseText("historical reread completed"),
      ]);
      try {
        const first = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--image",
            fixture.imagePath,
            "Inspect the first image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const firstJson = parseFxJson(first);
        expect(firstJson.session_id.length).toBeGreaterThan(0);
        expect(firstJson.tool_calls).toContainEqual({ name: "vision", status: "success" });

        const native = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            firstJson.session_id,
            "--image",
            secondImagePath,
            "Inspect the new image natively.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const nativeJson = parseFxJson(native);
        expect(nativeJson.session_id).toBe(firstJson.session_id);
        expect(nativeJson.output).toContain("native route completed");
        expect(nativeJson.tool_calls).toHaveLength(0);

        const reread = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            firstJson.session_id,
            "Reread only the second historical image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const rereadJson = parseFxJson(reread);
        expect(rereadJson.session_id).toBe(firstJson.session_id);
        expect(rereadJson.output).toContain("historical reread completed");
        expect(rereadJson.tool_calls).toContainEqual({ name: "vision", status: "success" });

        expect(gateway.chatRequests).toHaveLength(7);
        expect(gateway.chatRequests[0].body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[0].body).toContain("[Image #1]");
        expect(gateway.chatRequests[3].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[3].body).toContain('"name":"vision"');
        expect(gateway.chatRequests[3].body).toContain('"paths":{"type":"array"');
        expect(gateway.chatRequests[3].body).not.toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[3].body).not.toContain('"toolName":"vision"');
        expect(gateway.chatRequests[3].body).not.toContain("first image evidence");
        expect(gateway.chatRequests[3].body).toContain('"type":"file"');
        expect(gateway.chatRequests[4].headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        expect(gateway.chatRequests[4].body).toContain('"name":"vision"');
        expect(gateway.chatRequests[4].body).not.toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[4].body).toContain("[Image #1]");
        expect(gateway.chatRequests[4].body).toContain("[Image #2]");
        expect(gateway.chatRequests[4].body).not.toContain('"type":"file"');
        expect(gateway.chatRequests[4].body).not.toContain(fixture.imagePath);
        expect(gateway.chatRequests[4].body).not.toContain(secondImagePath);
        expect(gateway.chatRequests[5].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[5].body).toContain('"type":"file"');
        expect(gateway.chatRequests[6].body).toContain("second image evidence");
        expect(gateway.chatRequests[6].body).not.toContain('"type":"file"');

        const detail = await runFx(
          ["session", "--id", firstJson.session_id, "--json"],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(detail.code).toBe(0);
        expect(detail.stderr).toBe("");
        const persisted = JSON.stringify(JSON.parse(detail.stdout));
        expect(persisted).toContain('"name":"vision"');
        expect(persisted).toContain("first image evidence");
        expect(persisted).toContain("second image evidence");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "legacy zero image ids repair through durable resume and remain readable after model switch",
    async () => {
      const root = createIsolatedRoot();
      const legacyPaths = [
        "legacy-first.png",
        "legacy-second.png",
        "legacy-valid-three.png",
        "legacy-nine.png",
      ].map((name) => join(root.workspace, name)) as [string, string, string, string];
      for (const imagePath of legacyPaths) copyFileSync(IMAGE_PATH, imagePath);
      writeFileSync(
        legacyPaths[0],
        Buffer.concat([readFileSync(legacyPaths[0]), Buffer.from("legacy-first-image")]),
      );
      writeFileSync(
        legacyPaths[1],
        Buffer.concat([readFileSync(legacyPaths[1]), Buffer.from("legacy-second-image")]),
      );
      const firstPayload = readFileSync(legacyPaths[0]).toString("base64");
      const secondPayload = readFileSync(legacyPaths[1]).toString("base64");
      const newImagePath = join(root.workspace, "new-image.png");
      copyFileSync(IMAGE_PATH, newImagePath);
      const sessionId = "legacy-zero-image-ids";
      writeLegacyZeroImageSession(root, sessionId, legacyPaths);

      const gateway = startImageGateway([
        sseText("legacy native replay completed"),
        sseToolCall("vision", { image_ids: [2], focus: "reread second repaired legacy image" }, "vision_legacy"),
        sseText(visionResult(2, "second repaired legacy evidence")),
        sseText("legacy text reread completed"),
      ]);
      try {
        const native = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            sessionId,
            "--image",
            newImagePath,
            "Replay the legacy images and inspect the new image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const nativeJson = parseFxJson(native);
        expect(nativeJson.session_id).toBe(sessionId);
        expect(nativeJson.output).toContain("legacy native replay completed");
        expect(nativeJson.tool_calls).toHaveLength(0);
        expect(gateway.chatRequests).toHaveLength(1);
        expect(gateway.chatRequests[0].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[0].body).toContain('"name":"vision"');
        expect(gateway.chatRequests[0].body).toContain('"paths":{"type":"array"');
        expect(gateway.chatRequests[0].body).not.toContain('"toolChoice":{"type":"required"}');
        expect(filePartCount(gateway.chatRequests[0].body)).toBe(5);
        expect(gateway.chatRequests[0].body).toContain("Legacy first image: [Image #1]");
        expect(gateway.chatRequests[0].body).toContain("Legacy second image: [Image #2]");
        expect(gateway.chatRequests[0].body).toContain(firstPayload);
        expect(gateway.chatRequests[0].body).toContain(secondPayload);

        const detail = await runFx(
          ["session", "--id", sessionId, "--json"],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        expect(detail.code).toBe(0);
        expect(detail.stderr).toBe("");
        const persisted = JSON.stringify(JSON.parse(detail.stdout));
        expect(persisted).toContain("Legacy first image: [Image #1]");
        expect(persisted).toContain("Legacy second image: [Image #2]");

        const reread = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            sessionId,
            "Reread only the second repaired legacy image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const rereadJson = parseFxJson(reread);
        expect(rereadJson.session_id).toBe(sessionId);
        expect(rereadJson.output).toContain("legacy text reread completed");
        expect(rereadJson.tool_calls).toContainEqual({ name: "vision", status: "success" });

        expect(gateway.chatRequests).toHaveLength(4);
        const textRequest = gateway.chatRequests[1];
        expect(textRequest.headers.get("ai-language-model-id")).toBe(GLM_MODEL);
        expect(textRequest.body).toContain('"name":"vision"');
        expect(textRequest.body).toContain("[Image #1]");
        expect(textRequest.body).toContain("[Image #2]");
        expect(textRequest.body).toContain("[Image #3]");
        expect(textRequest.body).toContain("[Image #9]");
        expect(textRequest.body).toContain("[Image #10]");
        expect(filePartCount(textRequest.body)).toBe(0);
        for (const imagePath of [...legacyPaths, newImagePath]) {
          expect(textRequest.body).not.toContain(imagePath);
        }
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(1);
        expect(gateway.chatRequests[2].body).toContain(secondPayload);
        expect(gateway.chatRequests[2].body).not.toContain(firstPayload);
        expect(gateway.chatRequests[3].body).toContain("second repaired legacy evidence");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "empty successful Vision provider output is invalid and permits one recovery request",
    async () => {
      const root = createIsolatedRoot();
      // The empty response is served twice because a structurally invalid successful
      // response earns one internal retry before Vision reports the failure.
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect" }, "vision_empty"),
        sseText(JSON.stringify({ images: [] })),
        sseText(JSON.stringify({ images: [] })),
        sseText("recovered after invalid Vision result"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            "--image",
            IMAGE_PATH,
            "Inspect the image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("recovered after invalid Vision result");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "error" });
        expect(result.stderr).toBe("Inspecting images\n");
        expect(gateway.chatRequests).toHaveLength(4);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].body).toBe(gateway.chatRequests[1].body);
        const resultText = toolResultText(gateway.chatRequests[3].body, "vision_empty");
        expect(resultText).toContain('"code":"provider_response_invalid"');
        expect(resultText).toContain('"retryable":true');
        expect(resultText).toContain("Try a later explicit Vision call");
        expect(resultText).not.toContain("missing_provider_record");
        expect(gateway.chatRequests[3].body).not.toContain("Vision is unavailable right now");
        expect(gateway.chatRequests[3].body).not.toContain(
          "None of the requested images were read by Vision.",
        );
        expect(gateway.chatRequests[3].body).not.toContain(
          '"toolChoice":{"type":"required"}',
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "malformed Vision provider output retries once before reporting parser failure",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect" }, "vision_malformed"),
        sseText("not json at all"),
        sseText("still not json"),
        sseText("recovered after malformed Vision result"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            "--image",
            IMAGE_PATH,
            "Inspect the image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("recovered after malformed Vision result");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "error" });
        expect(gateway.chatRequests).toHaveLength(4);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].body).toBe(gateway.chatRequests[1].body);
        const resultText = toolResultText(
          gateway.chatRequests[3].body,
          "vision_malformed",
        );
        expect(resultText).toContain('"code":"provider_response_invalid"');
        expect(resultText).toContain('"retryable":true');
        expect(resultText).not.toContain("missing_provider_record");
        expect(gateway.chatRequests[3].body).not.toContain(
          '"toolChoice":{"type":"required"}',
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "one malformed Vision provider response is retried and recovers the same image",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect" }, "vision_retry"),
        sseText("not json at all"),
        sseText(VISION_RESULT),
        sseText("recovered without re-uploading the image"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            "--image",
            IMAGE_PATH,
            "Inspect the image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("recovered without re-uploading the image");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(result.stderr).toBe("Inspecting images\n");
        expect(gateway.chatRequests).toHaveLength(4);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(gateway.chatRequests[2].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(filePartCount(gateway.chatRequests[1].body)).toBe(1);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(1);
        expectVisionResponseFormat(gateway.chatRequests[1].body, 1);
        expectVisionResponseFormat(gateway.chatRequests[2].body, 1);
        expect(gateway.chatRequests[1].body).not.toContain("Return only strict JSON");
        expect(gateway.chatRequests[1].body).not.toContain("Do not wrap the JSON");
        expect(JSON.parse(gateway.chatRequests[0].body).responseFormat).toBeUndefined();
        expect(JSON.parse(gateway.chatRequests[3].body).responseFormat).toBeUndefined();
        // Byte-identical retry payload: same verified snapshot, ids, focus, and batch.
        expect(gateway.chatRequests[2].body).toBe(gateway.chatRequests[1].body);
        expect(gateway.chatRequests[3].body).toContain("FX LOGO");
        expect(gateway.chatRequests[3].body).not.toContain("provider_response_invalid");
        expect(gateway.chatRequests[3].body).not.toContain("missing_provider_record");
        expect(gateway.chatRequests[3].body).not.toContain(IMAGE_PATH);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "one-of-two provider omission preserves evidence without retrying the batch",
    async () => {
      const root = createIsolatedRoot();
      const imagePaths = [1, 2].map((id) => {
        const imagePath = join(root.workspace, `omission-${id}.png`);
        copyFileSync(IMAGE_PATH, imagePath);
        return imagePath;
      });
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { image_ids: [1, 2], focus: "inspect both" },
          "vision_provider_omission",
        ),
        sseText(visionResult(1, "retained provider evidence")),
        sseText("continued with retained provider evidence"),
      ]);
      try {
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            "--image",
            imagePaths[0],
            "--image",
            imagePaths[1],
            "Inspect both images.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("continued with retained provider evidence");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[1].headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        expect(filePartCount(gateway.chatRequests[1].body)).toBe(2);
        expectVisionResponseFormat(gateway.chatRequests[1].body, 2);
        const visionResult = JSON.parse(
          toolResultText(gateway.chatRequests[2].body, "vision_provider_omission"),
        ) as {
          images: Array<{
            image_id: number;
            status: string;
            summary?: string;
            error?: { code?: string };
          }>;
        };
        expect(visionResult.images).toHaveLength(2);
        expect(visionResult.images[0]).toMatchObject({
          image_id: 1,
          status: "ok",
          summary: "retained provider evidence",
        });
        expect(visionResult.images[1]).toMatchObject({
          image_id: 2,
          status: "failed",
          error: { code: "missing_provider_record" },
        });
        expect(
          visionResult.images.filter(
            (image) => image.error?.code === "missing_provider_record",
          ),
        ).toHaveLength(1);
        for (const imagePath of imagePaths) {
          expect(gateway.chatRequests[2].body).not.toContain(imagePath);
        }
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "one corrupt image does not block its healthy sibling from Vision",
    async () => {
      const root = createIsolatedRoot();
      const imagePaths = [1, 2].map((id) => {
        const path = join(root.workspace, `partial-${id}.png`);
        copyFileSync(IMAGE_PATH, path);
        return path;
      });
      const gateway = startImageGateway([
        sseText("saved partial images"),
        sseToolCall("vision", { image_ids: [1, 2], focus: "inspect both" }, "vision_partial"),
        sseText(visionBatchResult([2])),
        sseText("mixed-result recovery completed"),
      ]);
      try {
        const saved = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--image",
            imagePaths[0],
            "--image",
            imagePaths[1],
            "Save both images.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const savedJson = parseFxJson(saved);
        const imageDir = join(root.home, ".fx", "sessions", savedJson.session_id, "images");
        const firstSnapshot = readdirSync(imageDir).find((name) => name.startsWith("image-1-"));
        expect(firstSnapshot).toBeDefined();
        writeFileSync(join(imageDir, firstSnapshot!), "corrupt");

        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            savedJson.session_id,
            "Inspect both saved images.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("mixed-result recovery completed");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(gateway.chatRequests).toHaveLength(4);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(1);
        expect(gateway.chatRequests[2].body).toContain("image_id=2");
        expect(gateway.chatRequests[2].body).not.toContain("image_id=1");
        const visionResult = JSON.parse(
          toolResultText(gateway.chatRequests[3].body, "vision_partial"),
        ) as {
          images: Array<{
            image_id: number;
            status: string;
            summary?: string;
            error?: { code?: string };
          }>;
        };
        expect(visionResult.images.map((image) => image.image_id)).toEqual([1, 2]);
        expect(visionResult.images[0]).toMatchObject({
          image_id: 1,
          status: "failed",
          error: { code: "image_unavailable" },
        });
        expect(visionResult.images[1]).toMatchObject({
          image_id: 2,
          status: "ok",
          summary: "summary-2",
        });
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "one corrupt first-batch image keeps twenty-image provider batches at seven eight four",
    async () => {
      const root = createIsolatedRoot();
      const imagePaths = Array.from({ length: 20 }, (_, index) => {
        const imagePath = join(root.workspace, `partial-twenty-${index + 1}.png`);
        copyFileSync(IMAGE_PATH, imagePath);
        return imagePath;
      });
      const allIds = Array.from({ length: 20 }, (_, index) => index + 1);
      const gateway = startImageGateway([
        sseText("saved twenty images"),
        sseToolCall("vision", { image_ids: allIds, focus: "inspect all" }, "vision_partial_twenty"),
        sseText(visionBatchResult(allIds.slice(1, 8))),
        sseText(visionBatchResult(allIds.slice(8, 16))),
        sseText(visionBatchResult(allIds.slice(16))),
        sseText("twenty-image mixed-result recovery completed"),
      ]);
      try {
        const imageArgs = imagePaths.flatMap((imagePath) => ["--image", imagePath]);
        const saved = await runFx(
          ["ask", "--json", "--auto", "--no-color", ...imageArgs, "Save every image."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GEMINI_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const savedJson = parseFxJson(saved);
        const imageDir = join(root.home, ".fx", "sessions", savedJson.session_id, "images");
        const firstSnapshot = readdirSync(imageDir).find((name) => name.startsWith("image-1-"));
        expect(firstSnapshot).toBeDefined();
        writeFileSync(join(imageDir, firstSnapshot!), "corrupt");

        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-color",
            "--resume-id",
            savedJson.session_id,
            "Inspect all saved images.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("twenty-image mixed-result recovery completed");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(gateway.chatRequests).toHaveLength(6);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(7);
        expect(filePartCount(gateway.chatRequests[3].body)).toBe(8);
        expect(filePartCount(gateway.chatRequests[4].body)).toBe(4);
        expect(gateway.chatRequests[2].body).not.toContain("image_id=1");
        expect(gateway.chatRequests[2].body).toContain("image_id=8");
        expect(gateway.chatRequests[3].body).toContain("image_id=9");
        expect(gateway.chatRequests[4].body).toContain("image_id=17");
        const visionResult = JSON.parse(
          toolResultText(gateway.chatRequests[5].body, "vision_partial_twenty"),
        ) as {
          images: Array<{
            image_id: number;
            status: string;
            summary?: string;
            error?: { code?: string };
          }>;
        };
        expect(visionResult.images.map((image) => image.image_id)).toEqual(allIds);
        expect(visionResult.images[0]).toMatchObject({
          image_id: 1,
          status: "failed",
          error: { code: "image_unavailable" },
        });
        expect(visionResult.images.slice(1).every((image) => image.status === "ok")).toBe(
          true,
        );
        expect(visionResult.images[19]).toMatchObject({
          image_id: 20,
          summary: "summary-20",
        });
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "twenty text-only images use sequential Vision provider batches of eight eight and four",
    async () => {
      const root = createIsolatedRoot();
      const imagePaths = Array.from({ length: 20 }, (_, index) => {
        const imagePath = join(root.workspace, `image-${index + 1}.png`);
        copyFileSync(IMAGE_PATH, imagePath);
        return imagePath;
      });
      const allIds = Array.from({ length: 20 }, (_, index) => index + 1);
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: allIds, focus: "inspect all images" }, "vision_twenty"),
        sseText(visionBatchResult(allIds.slice(0, 8))),
        sseText(visionBatchResult(allIds.slice(8, 16))),
        sseText(visionBatchResult(allIds.slice(16))),
        sseText("twenty image answer"),
      ]);
      try {
        const imageArgs = imagePaths.flatMap((imagePath) => ["--image", imagePath]);
        const result = await runFx(
          [
            "ask",
            "--json",
            "--auto",
            "--no-save",
            "--no-color",
            ...imageArgs,
            "Inspect every attached image.",
          ],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, GLM_MODEL),
            timeoutMs: TIMEOUT,
          },
        );
        const json = parseFxJson(result);
        expect(json.output).toContain("twenty image answer");
        expect(json.tool_calls).toContainEqual({ name: "vision", status: "success" });
        expect(gateway.chatRequests).toHaveLength(5);
        expect(gateway.chatRequests[0].body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[0].body).toContain("[Image #20]");
        expect(filePartCount(gateway.chatRequests[0].body)).toBe(0);
        expect(filePartCount(gateway.chatRequests[1].body)).toBe(8);
        expect(filePartCount(gateway.chatRequests[2].body)).toBe(8);
        expect(filePartCount(gateway.chatRequests[3].body)).toBe(4);
        for (const request of gateway.chatRequests.slice(1, 4)) {
          expect(request.headers.get("ai-language-model-id")).toBe(GEMINI_MODEL);
        }
        const finalBody = gateway.chatRequests[4].body;
        expect(finalBody.indexOf("summary-1")).toBeLessThan(finalBody.indexOf("summary-20"));
        expect(filePartCount(finalBody)).toBe(0);
        for (const imagePath of imagePaths) expect(finalBody).not.toContain(imagePath);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux @ home image path attaches and completes the Vision flow",
    async () => {
      const root = createIsolatedRoot();
      const desktop = join(root.home, "Desktop");
      mkdirSync(desktop, { recursive: true });
      const imagePath = join(desktop, "test.png");
      writeMarkedImage(imagePath, "TMUX_AT_HOME_IMAGE");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect test image" }, "vision_at_home"),
        sseText(visionResult(1, "@ home image evidence")),
        sseText("@ home image flow complete"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendLiteral("@~/Desktop/test.png");
        await session.waitForText("~/Desktop/test.png", TIMEOUT);
        await session.sendKeys("Tab");
        await session.sendLiteral(" look at this image");
        await session.sendKeys("Enter");

        await session.waitForText("Would you like to allow this action?", TIMEOUT);
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("@ home image flow complete", TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[0]!.body).toContain("[Image #1]");
        expect(gateway.chatRequests[0]!.body).toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[1]!.body).toContain('"type":"file"');
        expect(gateway.chatRequests[2]!.body).toContain("@ home image evidence");
        for (const request of gateway.chatRequests) {
          expect(request.body).not.toContain(imagePath);
          expect(request.body).not.toContain("~/Desktop/test.png");
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux preserves unresolved image-looking paths as prompt text",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startImageGateway([sseText("unresolved path remained prompt text")]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        const prompt = "Explain why ~other/test.png is not a supported home path.";
        await session.sendText(prompt);
        await session.waitForText("unresolved path remained prompt text", TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(1);
        expect(lastUserText(gateway.chatRequests[0]!.body)).toBe(prompt);
        expect(filePartCount(gateway.chatRequests[0]!.body)).toBe(0);
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision approval names the canonical image",
    async () => {
      const root = createIsolatedRoot();
      const desktop = join(root.home, "Desktop");
      mkdirSync(desktop, { recursive: true });
      const imagePath = join(desktop, "test.png");
      writeMarkedImage(imagePath, "TMUX_PATH_SOURCE_APPROVAL");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { paths: ["~/Desktop/test.png"], focus: "inspect the approved image path" },
          "vision_path_approval",
        ),
        sseText(visionResult(1, "approved path evidence")),
        sseText("path approval flow complete"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText("Inspect the requested Desktop image.");
        await session.waitForText("Would you like to allow this action?", TIMEOUT);
        await session.waitForText(imagePath, TIMEOUT);
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("path approval flow complete", TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[0]!.body).toContain('"paths":{"type":"array"');
        expect(gateway.chatRequests[0]!.body).not.toContain('"toolChoice":{"type":"required"}');
        expect(gateway.chatRequests[1]!.body).toContain('"type":"file"');
        expect(gateway.chatRequests[2]!.body).toContain("approved path evidence");
        for (const request of gateway.chatRequests) {
          expect(request.body).not.toContain(imagePath);
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision accepts hard-linked regular images",
    async () => {
      const root = createIsolatedRoot();
      const sourcePath = join(root.workspace, "source.png");
      const approvedPath = join(root.workspace, "approved.png");
      const payload = writeMarkedImage(sourcePath, "TMUX_HARD_LINKED_IMAGE");
      linkSync(sourcePath, approvedPath);
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { paths: ["approved.png"], focus: "inspect the hard-linked image" },
          "vision_hard_linked_path",
        ),
        sseText(visionResult(1, "hard-linked image evidence")),
        sseText("hard-linked image flow complete"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText("Inspect the hard-linked image path.");
        await session.waitForText("Would you like to allow this action?", TIMEOUT);
        await session.waitForText(approvedPath, TIMEOUT);
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("hard-linked image flow complete", TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(3);
        expect(filePartCount(gateway.chatRequests[1]!.body)).toBe(1);
        expect(gateway.chatRequests[1]!.body).toContain(payload);
        expect(gateway.chatRequests[2]!.body).toContain("hard-linked image evidence");
        for (const request of gateway.chatRequests) {
          expect(request.body).not.toContain(sourcePath);
          expect(request.body).not.toContain(approvedPath);
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision executes the canonical target approved by the user",
    async () => {
      const root = createIsolatedRoot();
      const targetA = join(root.workspace, "target-a.png");
      const targetB = join(root.workspace, "target-b.png");
      const approvedPath = join(root.workspace, "approved.png");
      const payloadA = writeMarkedImage(targetA, "TMUX_APPROVED_TARGET_A");
      const payloadB = writeMarkedImage(targetB, "TMUX_RETARGETED_TARGET_B");
      symlinkSync(targetA, approvedPath);
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const gateway = startImageGateway([
        sseToolCall(
          "vision",
          { paths: ["approved.png"], focus: "inspect the approved image path" },
          "vision_bound_path",
        ),
        sseText(visionResult(1, "bound path evidence")),
        sseText("bound path flow complete"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText("Inspect the approved image path.");
        await session.waitForText("Would you like to allow this action?", TIMEOUT);
        await session.waitForText(targetA, TIMEOUT);

        rmSync(approvedPath);
        symlinkSync(targetB, approvedPath);
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("bound path flow complete", TIMEOUT);
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(3);
        expect(gateway.chatRequests[1]!.body).toContain(payloadA);
        expect(gateway.chatRequests[1]!.body).not.toContain(payloadB);
        for (const request of gateway.chatRequests) {
          expect(request.body).not.toContain(targetA);
          expect(request.body).not.toContain(targetB);
          expect(request.body).not.toContain(approvedPath);
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision rejects regular-file replacement of the approved canonical target",
    async () => {
      const root = createIsolatedRoot();
      const targetB = join(root.workspace, "target-b.png");
      const payloadB = writeMarkedImage(targetB, "TMUX_REPLACEMENT_TARGET_B");
      try {
        await expectChangedCanonicalVisionPathFailure(
          root,
          "canonical regular-file replacement handled",
          (targetPath) => renameSync(targetB, targetPath),
          payloadB,
          [targetB],
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision rejects symlink replacement of the approved canonical target",
    async () => {
      const root = createIsolatedRoot();
      const targetB = join(root.workspace, "target-b.png");
      const payloadB = writeMarkedImage(targetB, "TMUX_SUBSTITUTED_TARGET_B");
      try {
        await expectChangedCanonicalVisionPathFailure(
          root,
          "canonical symlink replacement handled",
          (targetPath) => {
            rmSync(targetPath);
            symlinkSync(targetB, targetPath);
          },
          payloadB,
          [targetB],
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision rejects FIFO replacement of the approved canonical target",
    async () => {
      const root = createIsolatedRoot();
      try {
        await expectChangedCanonicalVisionPathFailure(
          root,
          "canonical FIFO replacement handled",
          (targetPath) => {
            rmSync(targetPath);
            expect(spawnSync("mkfifo", [targetPath]).status).toBe(0);
          },
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision returns directory failures to the model",
    async () => {
      const root = createIsolatedRoot();
      try {
        await expectNonRegularVisionPathFailure(
          root,
          ".",
          "directory path failure returned to model",
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision returns FIFO failures without waiting for a peer",
    async () => {
      const root = createIsolatedRoot();
      const fifoPath = join(root.workspace, "image.fifo");
      try {
        expect(spawnSync("mkfifo", [fifoPath]).status).toBe(0);
        await expectNonRegularVisionPathFailure(
          root,
          "image.fifo",
          "FIFO path failure returned to model",
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux path-source Vision returns Unix socket failures to the model",
    async () => {
      const root = createIsolatedRoot();
      const socketPath = join(root.workspace, "image.socket");
      const socketServer = createServer();
      try {
        await new Promise<void>((resolve, reject) => {
          socketServer.once("error", reject);
          socketServer.listen(socketPath, () => {
            socketServer.off("error", reject);
            resolve();
          });
        });
        await expectNonRegularVisionPathFailure(
          root,
          "image.socket",
          "Unix socket path failure returned to model",
        );
      } finally {
        if (socketServer.listening) {
          await new Promise<void>((resolve) => socketServer.close(() => resolve()));
        }
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux preserves typed permission feedback across a text-only Vision step",
    async () => {
      const root = createIsolatedRoot();
      const imagePath = join(root.workspace, "feedback.png");
      writeMarkedImage(imagePath, "TMUX_PERMISSION_FEEDBACK");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const feedback = "Do not modify any more files.";
      const rootRequest = "Inspect the image, then continue carefully.";
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect feedback image" }, "vision_feedback"),
        sseText(visionResult(1, "permission feedback image evidence")),
        sseText("permission feedback preserved"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText(`/image ${imagePath}`);
        await session.waitForText("attached image: feedback.png", TIMEOUT);
        await session.sendText(rootRequest);
        await session.waitForText("Would you like to allow this action?", TIMEOUT);
        await session.sendKeys("Tab");
        await session.waitForText("Yes, and tell fx what to do next", TIMEOUT);
        await session.sendLiteralText(feedback);
        await session.waitForText(`Yes, ${feedback}`, TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("permission feedback preserved", TIMEOUT);

        expect(gateway.chatRequests).toHaveLength(3);
        const selectedFollowup = gateway.chatRequests[2].body;
        expect(lastUserText(selectedFollowup)).toBe(feedback);
        expect(selectedFollowup.split("<available_images>")).toHaveLength(2);
        expect(selectedFollowup).toContain(rootRequest);
        expect(selectedFollowup).not.toContain(imagePath);

        const sessionsRoot = join(root.home, ".fx", "sessions");
        const sessionIds = readdirSync(sessionsRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory() && entry.name !== "latest")
          .map((entry) => entry.name);
        expect(sessionIds).toHaveLength(1);
        const events = readFileSync(
          join(sessionsRoot, sessionIds[0]!, "events.jsonl"),
          "utf8",
        );
        expect(events).toContain(feedback);
        expect(events).not.toContain("<available_images>");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "tmux shows ordinary Vision approval activity failure and exact outage tip",
    async () => {
      const root = createIsolatedRoot();
      const firstImagePath = join(root.workspace, "first.png");
      const secondImagePath = join(root.workspace, "second.png");
      const firstPayload = writeMarkedImage(firstImagePath, "TMUX_PERMISSION_A");
      const firstMutatedPath = join(root.workspace, "first-mutated.png");
      const firstMutatedPayload = writeMarkedImage(firstMutatedPath, "TMUX_PERMISSION_B");
      writeMarkedImage(secondImagePath, "TMUX_OUTAGE_A");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: {} }),
      );
      const gateway = startImageGateway([
        sseToolCall("vision", { image_ids: [1], focus: "inspect first" }, "vision_tmux_ok"),
        sseText(visionResult(1, "tmux image evidence")),
        sseText("tmux Vision completed"),
        sseToolCall("vision", { image_ids: [2], focus: "inspect second" }, "vision_tmux_outage"),
        new Response("vision unavailable", { status: 502 }),
        new Response("vision unavailable", { status: 502 }),
        new Response("vision unavailable", { status: 502 }),
        sseText("tmux outage continued"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: root.workspace,
          env: {
            ...fakeGatewayEnv(root, gateway, GLM_MODEL),
            FX_PERMISSION_MODE: "ask",
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          stderrPath,
          width: 140,
          height: 50,
        });
        await session.waitForPane(hasEmptyComposer, TIMEOUT);

        await session.sendText(`/image ${firstImagePath}`);
        await session.waitForText("attached image: first.png", TIMEOUT);
        await session.sendText("Inspect the first attached image.");
        const firstApproval = await session.waitForText(
          "Would you like to allow this action?",
          TIMEOUT,
        );
        expect(firstApproval).toContain("Inspecting images");
        writeFileSync(firstImagePath, readFileSync(firstMutatedPath));
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("tmux Vision completed", TIMEOUT);

        await session.sendText(`/image ${secondImagePath}`);
        await session.waitForText("attached image: second.png", TIMEOUT);
        await session.sendText("Inspect the second attached image.");
        const secondApproval = await session.waitForText(
          "Would you like to allow this action?",
          TIMEOUT,
        );
        expect(secondApproval).toContain("Inspecting images");
        await session.sendKeys("1");
        await session.sendKeys("Enter");
        await session.waitForText("tmux outage continued", TIMEOUT);

        const scrollback = await session.captureFullScrollback();
        expect(scrollback).toContain("Inspected images");
        expect(scrollback).toContain("Failed images: Vision is unavailable right now");
        expect(scrollback).toContain(
          "Tip: This model doesn’t support OCR, and Vision is unavailable right now. Try switching to a vision-capable model.",
        );
        const outageResult = toolResultText(
          gateway.chatRequests.at(-1)!.body,
          "vision_tmux_outage",
        );
        expect(outageResult).toContain('"code":"vision_unavailable"');
        expect(outageResult).toContain("Retry later, change model or strategy");
        expect(gateway.chatRequests[1].body).toContain(firstPayload);
        expect(gateway.chatRequests[1].body).not.toContain(firstMutatedPayload);
        for (const request of gateway.chatRequests) {
          expect(request.body).not.toContain(firstImagePath);
          expect(request.body).not.toContain(firstMutatedPath);
          expect(request.body).not.toContain(secondImagePath);
          expect(request.body).not.toContain("data:image");
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    30_000,
  );
});
