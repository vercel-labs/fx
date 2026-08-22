import { afterEach, expect, test } from "bun:test";
import {
  chmodSync,
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
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function executable(path: string, source: string): string {
  writeFileSync(path, source, { mode: 0o700 });
  chmodSync(path, 0o700);
  return path;
}

test(
  "native ask runs configured lifecycle hooks with structured payloads",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-hooks-e2e-")));
    roots.push(root);
    const home = join(root, "home");
    const fxDir = join(home, ".fx");
    const workspace = join(root, "workspace");
    const hookDir = join(root, "hooks");
    mkdirSync(fxDir, { recursive: true, mode: 0o700 });
    chmodSync(fxDir, 0o700);
    mkdirSync(workspace);
    mkdirSync(hookDir);

    const preCapture = join(root, "pre.json");
    const stopCapture = join(root, "stop.json");
    const postCapture = join(root, "post.json");
    const secretCapture = join(root, "secret.txt");
    const preHook = executable(
      join(hookDir, "pre-hook"),
      `#!/bin/sh
cat > ${JSON.stringify(preCapture)}
printf '%s' "\${AI_GATEWAY_API_KEY-unset}" > ${JSON.stringify(secretCapture)}
printf '%s\n' '{"action":"rewrite","arguments":{"action":"exec","command":"printf HOOK_REWRITTEN","profile":"clean"}}'
`,
    );
    const stopHook = executable(
      join(hookDir, "stop-hook"),
      `#!/bin/sh
cat > ${JSON.stringify(stopCapture)}
printf '%s\n' '{"action":"allow"}'
`,
    );
    const postHook = executable(
      join(hookDir, "post-hook"),
      `#!/bin/sh
cat > ${JSON.stringify(postCapture)}
`,
    );

    writeFileSync(
      join(fxDir, "settings.json"),
      JSON.stringify({
        permission_mode: "yolo",
        yolo_acknowledged: true,
        hooks: {
          PreToolUse: [{ command: [preHook], timeout_ms: 2_000 }],
          Stop: [{ command: [stopHook], timeout_ms: 2_000 }],
          PostTurnEnd: [{ command: [postHook], timeout_ms: 2_000 }],
        },
      }) + "\n",
      { mode: 0o600 },
    );

    const gateway = startFakeGateway([
      fakeGatewayToolCall("hooked_terminal", "terminal", {
        action: "exec",
        command: "printf ORIGINAL_COMMAND",
        profile: "clean",
      }),
      (body) => {
        expect(body).toContain("HOOK_REWRITTEN");
        expect(body).not.toContain("ORIGINAL_COMMAND");
        return fakeGatewayFinalText("HOOK_TURN_COMPLETE");
      },
    ]);
    gateways.push(gateway);

    const result = await runFx(
      ["ask", "--quiet", "--json", "--no-save", "Exercise lifecycle hooks."],
      {
        cwd: realpathSync(workspace),
        timeoutMs: 15_000,
        env: {
          HOME: realpathSync(home),
          AI_GATEWAY_API_KEY: "must-not-reach-hook",
          VERCEL_OIDC_TOKEN: undefined,
          FX_DISABLE_KEYCHAIN: "1",
          FX_AUTO_UPGRADE: "0",
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
      },
    );

    expect(result.code).toBe(0);
    expect(result.timedOut).toBe(false);
    expect(result.stderr).toContain("HOOK_REWRITTEN");
    expect(result.stderr).not.toContain("ORIGINAL_COMMAND");
    expect(JSON.parse(result.stdout)).toMatchObject({
      exit_code: 0,
      output: "HOOK_TURN_COMPLETE",
    });
    expect(readFileSync(secretCapture, "utf8")).toBe("unset");

    const pre = JSON.parse(readFileSync(preCapture, "utf8"));
    expect(pre).toMatchObject({
      schema_version: 1,
      event: "PreToolUse",
      invocation: {
        scope: "ask",
        workspace_root: realpathSync(workspace),
      },
      payload: {
        call_id: "hooked_terminal",
        tool_name: "terminal",
        arguments: { command: "printf ORIGINAL_COMMAND" },
      },
    });

    const stop = JSON.parse(readFileSync(stopCapture, "utf8"));
    expect(stop).toMatchObject({
      schema_version: 1,
      event: "Stop",
      payload: {
        assistant_text: "HOOK_TURN_COMPLETE",
        provider_disposition: "completed",
        can_continue: true,
      },
    });

    expect(existsSync(postCapture)).toBe(true);
    const post = JSON.parse(readFileSync(postCapture, "utf8"));
    expect(post).toMatchObject({
      schema_version: 1,
      event: "PostTurnEnd",
      payload: {
        outcome: "completed",
        provider_disposition: null,
      },
    });
  },
  20_000,
);
