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
const conformanceEnv = {
  ...process.env,
  FX_MCP_PROTOCOL_VERSION: requestedProtocol ?? "2026-07-28",
};
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
if (scenario === "sep-2322-client-request-state") {
  const repoRoot = resolve(import.meta.dirname, "../../..");
  const child = Bun.spawn(
    [
      "zig",
      "build",
      "run-mcp-stdio-dispatcher-e2e",
      "--",
      "runtime-http-mrtr",
      configuredServerUrl,
    ],
    {
      cwd: repoRoot,
      env: conformanceEnv,
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  await legacyProbeProxy?.stop();
  process.exit(exitCode);
}
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

const gatewaySteps = toolCalls.flatMap((call, index) => {
  const name = `mcp_conformance_${call.name}`;
  return [
    fakeGatewayToolCall(`select_conformance_tool_${index}`, "mcp_select_tool", {
      name,
    }),
    fakeGatewayToolCall(`call_conformance_tool_${index}`, name, call.arguments),
  ];
});
if (toolCalls.length === 0) {
  gatewaySteps.push(fakeGatewayToolCall(
    "search_conformance_server",
    "capability_search",
    { query: "conformance" },
  ));
}
gatewaySteps.push(fakeGatewayFinalText("MCP conformance client finished."));
const gateway = startFakeGateway(gatewaySteps);

try {
  const child = Bun.spawn(
    [
      fxBin,
      "ask",
      "--json",
      "--auto",
      "--no-save",
      "Call the conformance add_numbers MCP tool with a=2 and b=3.",
    ],
    {
      cwd: workspace,
      env: {
        ...conformanceEnv,
        HOME: home,
        AI_GATEWAY_API_KEY: "mcp-conformance-placeholder",
        VERCEL_OIDC_TOKEN: "",
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_E2E_MCP_AUTH_AUTOMATE: "1",
        ...(scenarioContext.client_secret
          ? {
              FX_MCP_CONFORMANCE_CLIENT_SECRET:
                scenarioContext.client_secret,
            }
          : {}),
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  process.exitCode = exitCode;
} finally {
  gateway.stop();
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
