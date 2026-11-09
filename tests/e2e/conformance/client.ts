import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import {
  createServer,
  request as httpRequest,
  type ClientRequest,
  type IncomingMessage,
  type Server,
} from "node:http";
import { request as httpsRequest } from "node:https";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "../tmux-helpers";

const serverUrl = process.argv[2];
if (!serverUrl) {
  console.error("usage: bun client.ts <server-url>");
  process.exit(2);
}

const scenario = process.env.MCP_CONFORMANCE_SCENARIO ?? "tools_call";
const requestedProtocol = process.env.MCP_CONFORMANCE_PROTOCOL_VERSION;
const supportedProtocols = new Set([
  "2026-07-28",
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
]);
if (requestedProtocol && !supportedProtocols.has(requestedProtocol)) {
  console.error(`unsupported conformance protocol: ${requestedProtocol}`);
  process.exit(2);
}
let configuredServerUrl = serverUrl;
let legacyProbeProxy: LegacyProbeProxy | null = null;
if (requestedProtocol && requestedProtocol !== "2026-07-28") {
  legacyProbeProxy = await startLegacyProbeProxy(serverUrl);
  configuredServerUrl = legacyProbeProxy.url;
}
const scenarioContext = process.env.MCP_CONFORMANCE_CONTEXT
  ? JSON.parse(process.env.MCP_CONFORMANCE_CONTEXT) as {
    name?: string;
    client_id?: string;
    client_secret?: string;
    toolCalls?: Array<{ name: string; arguments: Record<string, unknown> }>;
  }
  : {};
const toolCalls = scenarioContext.toolCalls ?? scenarioToolCalls(scenario);
const permission: Record<string, "allow"> = {};
for (const call of toolCalls) {
  permission[`mcp_conformance_${call.name}`] = "allow";
}

const fxBin = resolve(import.meta.dirname, "../../../zig-out/bin/fx");
const root = mkdtempSync(join(tmpdir(), "fx-mcp-conformance-client-"));
const home = join(root, "home");
const workspace = join(root, "workspace");
mkdirSync(join(home, ".fx", "skills"), { recursive: true, mode: 0o700 });
mkdirSync(workspace, { recursive: true });

writeFileSync(
  join(home, ".fx", "mcp.json"),
  JSON.stringify({
    mcp: {
      conformance: {
        type: "http",
        url: configuredServerUrl,
        enabled: true,
        oauth: {
          client_metadata_url:
            "https://conformance-test.local/client-metadata.json",
          ...(scenarioContext.client_id
            ? { client_id: scenarioContext.client_id }
            : {}),
          ...(scenarioContext.client_secret
            ? { client_secret_env: "FX_MCP_CONFORMANCE_CLIENT_SECRET" }
            : {}),
        },
      },
    },
  }),
);
writeFileSync(
  join(home, ".fx", "settings.json"),
  JSON.stringify({
    permission_mode: "auto",
    permission,
  }),
);

// A scripted model for one ask: a Response can be read only once.
function gatewaySteps() {
  const steps = toolCalls.flatMap((call, index) => {
    const name = `mcp_conformance_${call.name}`;
    return [
      fakeGatewayToolCall(`select_conformance_tool_${index}`, "mcp_select_tool", {
        name,
      }),
      fakeGatewayToolCall(`call_conformance_tool_${index}`, name, call.arguments),
    ];
  });
  if (toolCalls.length === 0) {
    steps.push(fakeGatewayToolCall(
      "search_conformance_server",
      "capability_search",
      { query: "conformance" },
    ));
  }
  steps.push(fakeGatewayFinalText("MCP conformance client finished."));
  return steps;
}

// fx signs in through the browser with fx mcp login. For the auth scenarios
// this browser follows the authorization URL's redirects back to fx's
// loopback callback, as a user approving it would. On Linux fx opens a
// browser only when a display is set, so these scenarios also set DISPLAY.
const authScenario = scenario.startsWith("auth/");
const fakeBin = join(root, "bin");
if (authScenario) {
  mkdirSync(fakeBin, { recursive: true });
  const opener =
    '#!/bin/sh\nnohup curl --location --silent --show-error "$1" >/dev/null 2>&1 &\nexit 0\n';
  for (const name of ["open", "xdg-open"]) {
    writeFileSync(join(fakeBin, name), opener, { mode: 0o755 });
  }
}
const fxEnv = {
  ...process.env,
  HOME: home,
  PATH: authScenario ? `${fakeBin}:${process.env.PATH ?? ""}` : process.env.PATH,
  ...(authScenario ? { DISPLAY: process.env.DISPLAY || ":0" } : {}),
  AI_GATEWAY_API_KEY: "mcp-conformance-placeholder",
  VERCEL_OIDC_TOKEN: "",
  FX_AUTO_UPGRADE: "0",
  FX_DISABLE_KEYCHAIN: "1",
  ...(scenarioContext.client_secret
    ? {
        FX_MCP_CONFORMANCE_CLIENT_SECRET:
          scenarioContext.client_secret,
      }
    : {}),
  FX_MODEL: FAKE_GATEWAY_MODEL,
  FX_TEST_SKIP_ONBOARDING: "1",
  FX_SOUND: "0",
  NO_COLOR: "1",
};

async function runFx(args: string[], extraEnv: Record<string, string> = {}) {
  const child = Bun.spawn([fxBin, ...args], {
    cwd: workspace,
    env: { ...fxEnv, ...extraEnv },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  return { stdout, stderr, exitCode };
}

// Each ask gets its own scripted model.
async function ask() {
  const gateway = startFakeGateway(gatewaySteps());
  try {
    const result = await runFx(
      [
        "ask",
        "--json",
        "--auto",
        "--no-save",
        "Call the conformance add_numbers MCP tool with a=2 and b=3.",
      ],
      { FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl },
    );
    // What fx told the model: a call ended because the server needs a
    // login. The --json result carries only each call's status.
    const needsLogin = gateway.requests.some((r) => r.body.includes("needs a login"));
    return { ...result, needsLogin };
  } finally {
    gateway.stop();
  }
}

// A server that asks questions needs a client that can take them, and a
// headless fx ask declares none: such scenarios run through fx acp, as an ACP
// client that takes form questions and answers each with its defaults.
const asksQuestions = scenario === "sep-2322-client-request-state";

async function askOverAcp() {
  const gateway = startFakeGateway(gatewaySteps());
  const child = Bun.spawn([fxBin, "acp"], {
    cwd: workspace,
    env: { ...fxEnv, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "inherit",
  });
  const send = (message: object) => {
    child.stdin.write(`${JSON.stringify(message)}\n`);
    child.stdin.flush();
  };
  const waiting = new Map<number, (message: any) => void>();
  let nextId = 1;
  const request = (method: string, params: object) =>
    new Promise<any>((resolve) => {
      const id = nextId++;
      waiting.set(id, resolve);
      send({ jsonrpc: "2.0", id, method, params });
    });
  const reading = (async () => {
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of child.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      for (let end = buffer.indexOf("\n"); end >= 0; end = buffer.indexOf("\n")) {
        const line = buffer.slice(0, end).trim();
        buffer = buffer.slice(end + 1);
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.method === undefined) {
          waiting.get(message.id)?.(message);
          waiting.delete(message.id);
        } else if (message.method === "elicitation/create" && message.id !== undefined) {
          send({ jsonrpc: "2.0", id: message.id, result: { action: "accept", content: formDefaults(message.params?.requestedSchema) } });
        } else if (message.method === "session/request_permission" && message.id !== undefined) {
          send({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "selected", optionId: "allow_once" } } });
        }
      }
    }
  })();
  try {
    await request("initialize", { protocolVersion: 1, clientCapabilities: { elicitation: { form: {} } } });
    // An ACP client names its session's servers.
    const created = await request("session/new", {
      cwd: workspace,
      mcpServers: [{ type: "http", name: "conformance", url: configuredServerUrl, headers: [] }],
    });
    const sessionId = created.result.sessionId;
    await request("session/set_mode", { sessionId, modeId: "auto" });
    const prompted = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "Call the conformance MCP tools." }],
    });
    return { exitCode: prompted.error === undefined ? 0 : 1, needsLogin: false };
  } finally {
    child.stdin.end();
    child.kill();
    await child.exited;
    await reading.catch(() => {});
    gateway.stop();
  }
}

// Each property's default, else a value its type allows.
function formDefaults(schema: any): Record<string, unknown> {
  const content: Record<string, unknown> = {};
  for (const [key, property] of Object.entries<any>(schema?.properties ?? {})) {
    if (property.default !== undefined) content[key] = property.default;
    else if (Array.isArray(property.enum)) content[key] = property.enum[0];
    else if (property.type === "boolean") content[key] = true;
    else if (property.type === "number" || property.type === "integer") content[key] = property.minimum ?? 0;
    else if (property.type === "string") content[key] = "x".repeat(property.minLength ?? 0);
  }
  return content;
}

try {
  if (authScenario) await runFx(["mcp", "login", "conformance"]);
  let result = asksQuestions ? await askOverAcp() : await ask();
  // A server that asks for more scope at call time: sign in again once,
  // then ask once more.
  if (authScenario && result.needsLogin) {
    await runFx(["mcp", "login", "conformance"]);
    result = await ask();
  }
  process.exitCode = result.exitCode;
} finally {
  await legacyProbeProxy?.stop();
  rmSync(root, { recursive: true, force: true });
}

function scenarioToolCalls(
  name: string,
): Array<{ name: string; arguments: Record<string, unknown> }> {
  switch (name) {
    case "tools_call":
      return [{ name: "add_numbers", arguments: { a: 2, b: 3 } }];
    case "http-standard-headers":
      return [{ name: "test_headers", arguments: {} }];
    case "http-invalid-tool-headers":
      return [{ name: "valid_tool", arguments: { region: "us-west1" } }];
    case "sse-retry":
      return [{ name: "test_reconnection", arguments: {} }];
    case "sep-2322-client-request-state":
      return [
        { name: "test_mrtr_echo_state", arguments: {} },
        { name: "test_mrtr_unrelated", arguments: {} },
        { name: "test_mrtr_no_state", arguments: {} },
        { name: "test_mrtr_no_result_type", arguments: {} },
      ];
    default:
      return name.startsWith("auth/")
        ? [{ name: "test-tool", arguments: {} }]
        : [];
  }
}

type LegacyProbeProxy = {
  url: string;
  stop: () => Promise<void>;
};

async function startLegacyProbeProxy(
  targetUrl: string,
): Promise<LegacyProbeProxy> {
  const target = new URL(targetUrl);
  const upstreamRequests = new Set<ClientRequest>();
  const upstreamResponses = new Set<IncomingMessage>();
  const server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    request.on("end", () => {
      const body = Buffer.concat(chunks);
      if (request.method === "POST" && body.length > 0) {
        try {
          const payload = JSON.parse(body.toString("utf8")) as {
            method?: unknown;
          };
          if (payload.method === "server/discover") {
            response.writeHead(404);
            response.end();
            return;
          }
        } catch {
          // Let the conformance server report malformed payloads.
        }
      }

      const forward = target.protocol === "https:" ? httpsRequest : httpRequest;
      const upstream = forward(target, {
        method: request.method,
        headers: {
          ...request.headers,
          host: target.host,
        },
      }, (upstreamResponse) => {
        upstreamResponses.add(upstreamResponse);
        upstreamResponse.on(
          "close",
          () => upstreamResponses.delete(upstreamResponse),
        );
        response.on("close", () => upstreamResponse.destroy());
        response.writeHead(
          upstreamResponse.statusCode ?? 502,
          upstreamResponse.headers,
        );
        upstreamResponse.pipe(response);
      });
      upstreamRequests.add(upstream);
      upstream.on("close", () => upstreamRequests.delete(upstream));
      upstream.on("error", (error) => {
        if (!response.headersSent) response.writeHead(502);
        response.end(error.message);
      });
      upstream.end(body);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    await closeServer(server);
    throw new Error("legacy conformance proxy did not bind a TCP port");
  }
  return {
    url: `http://127.0.0.1:${address.port}`,
    stop: async () => {
      for (const request of upstreamRequests) request.destroy();
      for (const response of upstreamResponses) response.destroy();
      await closeServer(server);
    },
  };
}

async function closeServer(server: Server): Promise<void> {
  await new Promise<void>((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  });
}
