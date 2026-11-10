// fx under a macOS sandbox that denies reads of the System keychain, as Agent
// Safehouse does. fx must still load trusted roots, from /etc/ssl/cert.pem,
// and keep verifying server certificates; with the public bundle denied too,
// it must fail closed (src/core/shared/tls_roots.zig).
//
// The servers present a self-signed certificate, so fx rejects every
// handshake. A connection with a rejected handshake shows the roots loaded;
// on a build without the fallback fx stops before it connects.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, cleanupIsolatedTestHome, createIsolatedTestHome } from "../evals/eval-helpers";
import { fakeGatewayFinalText, startFakeGateway } from "./tmux-helpers";
import {
  PUBLIC_BUNDLE,
  ROOT_KEYCHAIN,
  SYSTEM_KEYCHAIN,
  denyProfile,
  runSandboxed,
  sandboxAvailable,
  startUntrustedTlsServer,
  type UntrustedTlsServer,
} from "./fixtures/untrusted-tls";

const LOAD_FAILURE = "couldn't load trusted certificates";

describe.skipIf(!sandboxAvailable())("trusted roots under a sandbox that denies the keychain", () => {
  let tls: UntrustedTlsServer;
  let gateway: ReturnType<typeof Bun.serve>;
  let gatewayRequests = 0;
  let root: string;
  let workspace: string;
  let profiles: { system: string; both: string; closed: string };

  beforeAll(async () => {
    tls = await startUntrustedTlsServer();
    // Anything that would reach the AI Gateway lands here instead, and none should.
    gateway = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() { gatewayRequests++; return new Response("{}", { status: 404 }); } });
    root = createIsolatedTestHome();
    workspace = join(root, "workspace");
    mkdirSync(workspace, { recursive: true });
    mkdirSync(join(root, ".fx"), { recursive: true, mode: 0o700 });
    writeFileSync(join(root, ".fx", "settings.json"), JSON.stringify({
      provider: "local",
      auto_upgrade: false,
      permission_mode: "ask",
      providers: {
        local: {
          protocol: "openai-chat-completions",
          base_url: tls.url("/v1"),
          auth: { type: "none" },
          model_metadata: { m1: { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
        },
      },
      models: { local: "m1" },
    }), { mode: 0o600 });
    writeFileSync(join(root, ".fx", "mcp.json"), JSON.stringify({
      mcp: { fixture: { type: "http", url: tls.url("/mcp"), startup_timeout_ms: 3000, operation_timeout_ms: 3000 } },
    }), { mode: 0o600 });
    profiles = {
      system: denyProfile(root, "deny-system-keychain", [SYSTEM_KEYCHAIN]),
      both: denyProfile(root, "deny-both-keychains", [ROOT_KEYCHAIN, SYSTEM_KEYCHAIN]),
      closed: denyProfile(root, "deny-keychain-and-bundle", [SYSTEM_KEYCHAIN, PUBLIC_BUNDLE]),
    };
  });

  afterAll(() => {
    tls?.stop();
    gateway?.stop(true);
    if (root) cleanupIsolatedTestHome(root);
  });

  function env(trace: string): Record<string, string> {
    const gatewayUrl = `http://127.0.0.1:${gateway.port}`;
    return {
      HOME: root,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      TMPDIR: process.env.TMPDIR ?? "/tmp",
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_DOTENV: "1",
      NO_COLOR: "1",
      AI_GATEWAY_API_KEY: "fake-tls-roots-key",
      FX_GATEWAY_BASE_URL: gatewayUrl,
      FX_GATEWAY_CHAT_URL: `${gatewayUrl}/v1/ai/language-model`,
      FX_TEST_GATEWAY_CHAT_URL: `${gatewayUrl}/v1/ai/language-model`,
      FX_TEST_GATEWAY_MODELS_URL: `${gatewayUrl}/v1/models`,
      FX_TRACE_LOG: join(root, trace),
    };
  }

  function traceOf(name: string): string {
    const path = join(root, name);
    return existsSync(path) ? readFileSync(path, "utf8") : "";
  }

  async function askUnder(profile: string, trace: string) {
    const before = { ...tls.counts };
    const run = await runSandboxed(profile, FX_BIN, ["ask", "--provider", "local", "--model", "m1", "--no-save", "hi"], {
      cwd: workspace,
      env: env(trace),
      timeoutMs: 20_000,
      // fx retries a refused handshake, so stop it once the server saw one.
      stopWhen: () => tls.waitFor((c) => c.rejected > before.rejected, 15_000),
    });
    return { run, before, after: { ...tls.counts } };
  }

  for (const [label, key] of [["only the System keychain is", "system"], ["both keychain files are", "both"]] as const) {
    test(`fx ask verifies an https provider when ${label} denied`, async () => {
      const trace = `ask-${key}.log`;
      const { run, before, after } = await askUnder(profiles[key], trace);
      expect(run.stderr).not.toContain(LOAD_FAILURE);
      expect(after.connections).toBeGreaterThan(before.connections);
      expect(after.rejected).toBeGreaterThan(before.rejected);
      expect(after.requests).toBe(before.requests);
      expect(traceOf(trace)).toContain("event=roots_loaded source=public_bundle");
      expect(gatewayRequests).toBe(0);
    }, 30_000);
  }

  test("an https MCP server is reached when the System keychain is denied", async () => {
    const before = { ...tls.counts };
    const run = await runSandboxed(profiles.system, FX_BIN, ["mcp", "show", "fixture"], {
      cwd: workspace,
      env: env("mcp.log"),
      timeoutMs: 20_000,
    });
    expect(run.stdout).toContain("https://127.0.0.1:");
    expect(tls.counts.connections).toBeGreaterThan(before.connections);
    expect(tls.counts.rejected).toBeGreaterThan(before.rejected);
    expect(tls.counts.requests).toBe(before.requests);
    expect(traceOf("mcp.log")).toContain("event=roots_loaded source=public_bundle");
    expect(gatewayRequests).toBe(0);
  }, 30_000);

  test("the gateway provider still answers over its loopback fake under the same sandbox", async () => {
    const answering = startFakeGateway([fakeGatewayFinalText("gateway answered under the sandbox")], {
      models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }],
    });
    try {
      const run = await runSandboxed(profiles.system, FX_BIN, ["ask", "--provider", "gateway", "--model", "openai/gpt-5", "--no-save", "hi"], {
        cwd: workspace,
        env: {
          ...env("gateway.log"),
          FX_GATEWAY_BASE_URL: answering.baseUrl,
          FX_GATEWAY_CHAT_URL: answering.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: answering.chatUrl,
          FX_TEST_GATEWAY_MODELS_URL: `${answering.baseUrl}/coding-agent/v1/models`,
        },
        timeoutMs: 20_000,
      });
      expect(run.code).toBe(0);
      expect(run.stdout).toContain("gateway answered under the sandbox");
      expect(run.stderr).not.toContain(LOAD_FAILURE);
      expect(answering.requestCount()).toBe(1);
    } finally {
      answering.stop();
    }
  }, 30_000);

  test("fx fails closed when the public bundle is denied too", async () => {
    const { run, before, after } = await askUnder(profiles.closed, "closed.log");
    expect(run.stopped).toBe(false);
    expect(run.code).toBe(1);
    expect(run.stderr).toContain(LOAD_FAILURE);
    expect(after.connections).toBe(before.connections);
    expect(gatewayRequests).toBe(0);
  }, 30_000);
});
