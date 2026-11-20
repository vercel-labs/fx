import { describe, expect, test } from "bun:test";
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
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  type FakeGatewayResponse,
} from "./tmux-helpers";

const TIMEOUT = 120_000;
const CONFIGURED_SANDBOX = process.platform === "darwin" ? "os" : "none";

type FxJson = {
  output: string;
  exit_code: number;
  tool_calls: Array<{ name: string; status: string }>;
};

function createIsolatedRoot(prefix: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const external = join(root, "external");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(external, { recursive: true });
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    external: realpathSync(external),
  };
}

function parseFxJson(result: { stdout: string; stderr: string; code: number | null }): FxJson {
  if (result.code !== 0) {
    throw new Error(`fx exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  }
  return JSON.parse(result.stdout.trim()) as FxJson;
}

async function runWithFakeGateway(
  root: ReturnType<typeof createIsolatedRoot>,
  args: string[],
  responses: FakeGatewayResponse[],
  env: Record<string, string> = {},
) {
  const gateway = startFakeGateway(responses);
  try {
    const result = await runFx(args, {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: "fake-file-permission-key",
        VERCEL_OIDC_TOKEN: undefined,
        ...env,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TEST_GATEWAY_CREDITS_URL: undefined,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      timeoutMs: TIMEOUT,
    });
    return { gateway, result };
  } finally {
    gateway.stop();
  }
}

describe("external file permissions", () => {
  test(
    "fx ask --yolo bypasses a configured write denial without a classifier request",
    async () => {
      const root = createIsolatedRoot("fx-yolo-permissions-");
      try {
        const target = join(root.external, "yolo-write.txt");
        const tracePath = join(root.root, "permission-trace.log");
        const settingsPath = join(root.home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            permission_mode: "ask",
            sandbox: CONFIGURED_SANDBOX,
            yolo_acknowledged: false,
            permission: { edit: "deny" },
          }) + "\n",
        );

        const { gateway, result } = await runWithFakeGateway(
          root,
          [
            "ask",
            "--json",
            "--no-save",
            "--yolo",
            `Use only the write_file tool to create ${target} with exactly this content: FX_E2E_YOLO.`,
          ],
          [
            fakeGatewayToolCall("yolo_write_1", "write_file", {
              path: target,
              content: "FX_E2E_YOLO",
            }),
            fakeGatewayFinalText("yolo write complete"),
          ],
          {
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "permission",
          },
        );

        expect(result.stderr).toContain(
          "Full access enabled: fx permission checks disabled",
        );
        const output = parseFxJson(result);
        expect(
          output.tool_calls.some(
            (call) => call.name === "write_file" && call.status === "success",
          ),
        ).toBe(true);
        expect(readFileSync(target, "utf8")).toBe("FX_E2E_YOLO");
        const trace = readFileSync(tracePath, "utf8");
        expect(trace).not.toContain("event=auto_review_start");
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toMatchObject({
          permission_mode: "ask",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: true,
        });
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask reads external paths and exercises classifier and rule-gated writes",
    async () => {
      const root = createIsolatedRoot("fx-file-permissions-");
      try {
        const readTarget = join(root.external, "read-fixture.txt");
        const classifiedTarget = join(root.external, "classified-write.txt");
        const allowedTarget = join(root.external, "allowed-write.txt");
        const tracePath = join(root.root, "permission-trace.log");
        writeFileSync(readTarget, "FX_E2E_EXTERNAL_READ\n");
        writeFileSync(classifiedTarget, "before");
        writeFileSync(join(root.home, ".fx", "settings.json"), "{}");

        const { result: readResult } = await runWithFakeGateway(
          root,
          [
            "ask",
            "--json",
            "--no-save",
            "--auto",
            `Use only the read_file tool to read ${readTarget}, then reply with exactly the file content and nothing else.`,
          ],
          [
            fakeGatewayToolCall("external_read_1", "read_file", { path: readTarget }),
            fakeGatewayFinalText("FX_E2E_EXTERNAL_READ"),
          ],
        );
        const read = parseFxJson(readResult);
        expect(read.tool_calls).toContainEqual({ name: "read_file", status: "success" });
        expect(read.output).toContain("FX_E2E_EXTERNAL_READ");

        const { gateway: classifiedGateway, result: classifiedResult } =
          await runWithFakeGateway(
            root,
            [
              "ask",
              "--json",
              "--no-save",
              "--auto",
              `Use only the write_file tool to overwrite ${classifiedTarget} with exactly this content: FX_E2E_EXTERNAL_CLASSIFIED.`,
            ],
            [
              fakeGatewayToolCall("classified_write_1", "write_file", {
                path: classifiedTarget,
                content: "FX_E2E_EXTERNAL_CLASSIFIED",
              }),
              fakeGatewayFinalText("classified write complete"),
            ],
            {
              FX_TRACE_LOG: tracePath,
              FX_TRACE_SCOPES: "permission",
            },
          );
        const trace = readFileSync(tracePath, "utf-8");
        expect(trace.match(/event=auto_review_start/g)).toHaveLength(1);
        expect(trace.match(/event=auto_review_result/g)).toHaveLength(1);
        expect(trace).toContain("event=auto_review_result tool_name=write_file decision=clear");
        expect(classifiedGateway.classifierRequests).toHaveLength(1);
        const classified = parseFxJson(classifiedResult);
        expect(classified.tool_calls).toContainEqual({ name: "write_file", status: "success" });
        expect(readFileSync(classifiedTarget, "utf-8")).toBe("FX_E2E_EXTERNAL_CLASSIFIED");

        writeFileSync(
          join(root.home, ".fx", "settings.json"),
          JSON.stringify({
            permission: {
              edit: {
                [`${root.external}/**`]: "allow",
              },
            },
          }),
        );

        const { gateway: allowedGateway, result: allowedResult } = await runWithFakeGateway(
          root,
          [
            "ask",
            "--json",
            "--no-save",
            "--auto",
            `Use only the write_file tool to create ${allowedTarget} with exactly this content: FX_E2E_EXTERNAL_ALLOWED.`,
          ],
          [
            fakeGatewayToolCall("allowed_write_1", "write_file", {
              path: allowedTarget,
              content: "FX_E2E_EXTERNAL_ALLOWED",
            }),
            fakeGatewayFinalText("allowed write complete"),
          ],
        );
        const allowed = parseFxJson(allowedResult);
        expect(allowed.tool_calls).toContainEqual({ name: "write_file", status: "success" });
        expect(readFileSync(allowedTarget, "utf-8")).toBe("FX_E2E_EXTERNAL_ALLOWED");
        expect(allowedGateway.classifierRequests).toHaveLength(0);
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe("failed edit hints", () => {
  const SECRET = "FX_E2E_SECRET_VALUE";
  const CONTENT = `[default]\naws_secret_access_key = ${SECRET}\n`;

  /** Runs one edit_file with a wrong old_string on a file in the external folder, and returns the tool results the model gets next. */
  async function failedEditResult(permission: (folder: string) => Record<string, unknown>) {
    const root = createIsolatedRoot("fx-edit-hints-");
    try {
      const target = join(root.external, "credentials");
      writeFileSync(target, CONTENT);
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission: permission(root.external) }),
      );
      const { gateway, result } = await runWithFakeGateway(
        root,
        ["ask", "--json", "--no-save", "--auto", `Rotate the key in ${target}.`],
        [
          fakeGatewayToolCall("rotate_key_1", "edit_file", {
            path: target,
            old_string: "aws_secret_access_key = guess",
            new_string: "aws_secret_access_key = rotated",
          }),
          fakeGatewayFinalText("rotation attempted"),
        ],
      );
      const output = parseFxJson(result);
      expect(output.tool_calls).toContainEqual({ name: "edit_file", status: "error" });
      expect(readFileSync(target, "utf8")).toBe(CONTENT);
      expect(gateway.requests).toHaveLength(2);
      const prompt = JSON.parse(gateway.requests[1]!.body).prompt as Array<{ role: string }>;
      return JSON.stringify(prompt.filter((message) => message.role === "tool"));
    } finally {
      rmSync(root.root, { recursive: true, force: true });
    }
  }

  test(
    "a failed edit of a readable file shows the line it most likely meant",
    async () => {
      const toolResults = await failedEditResult((folder) => ({ edit: { [`${folder}/**`]: "allow" } }));
      expect(toolResults).toContain("the closest match is line 2.");
      expect(toolResults).toContain(`aws_secret_access_key = ${SECRET}`);
    },
    TIMEOUT,
  );

  test(
    "a failed edit of a file a read rule denies keeps the plain message",
    async () => {
      const toolResults = await failedEditResult((folder) => ({
        read: { [`${folder}/**`]: "deny" },
        edit: { [`${folder}/**`]: "allow" },
      }));
      expect(toolResults).toContain("old_string not found in file. Re-read the file");
      expect(toolResults).not.toContain(SECRET);
    },
    TIMEOUT,
  );
});
