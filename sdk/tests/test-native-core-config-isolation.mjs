#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const marker = "LIBFX_EXPLICIT_HOST_INSTRUCTIONS";
const workspaceMarker = "LIBFX_WORKSPACE_CONTEXT_MUST_NOT_LOAD";
const originalCwd = process.cwd();
const processWorkspace = await mkdtemp(join(tmpdir(), "libfx-process-workspace-"));
const runtimeHome = await mkdtemp(join(tmpdir(), "libfx-runtime-home-"));
const runtimeWorkspace = await mkdtemp(join(tmpdir(), "libfx-runtime-workspace-"));
const projectMcpMarker = join(runtimeWorkspace, "project-mcp-launched");
await writeFile(join(processWorkspace, ".fx.json"), `${JSON.stringify({ context: false })}\n`);
await writeFile(join(runtimeWorkspace, ".fx.json"), `${JSON.stringify({ context: true })}\n`);
await writeFile(join(runtimeWorkspace, "AGENTS.md"), `# Context\n\n${workspaceMarker}\n`);
await writeFile(join(runtimeWorkspace, ".mcp.json"), `${JSON.stringify({
  mcpServers: {
    forbidden: {
      command: "/bin/sh",
      args: ["-c", `printf launched > '${projectMcpMarker}'`],
    },
  },
})}\n`);

let requestBody = "";
let unexpectedRequests = 0;
const server = createServer((request, response) => {
  if (request.method !== "POST") {
    unexpectedRequests++;
    request.resume();
    response.writeHead(404).end();
    return;
  }
  request.setEncoding("utf8");
  request.on("data", (chunk) => { requestBody += chunk; });
  request.on("end", () => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write('data: {"type":"text-delta","delta":"isolated"}\n\n');
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const previousGatewayBase = process.env.FX_GATEWAY_BASE_URL;
process.env.FX_GATEWAY_BASE_URL = `http://127.0.0.1:${port}`;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));

let agent;
try {
  process.chdir(processWorkspace);
  agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    fetch(input, init) {
      if (init.method === "GET") {
        assert.equal(input, "https://ai-gateway.vercel.sh/coding-agent/v1/models");
        return Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] });
      }
      assert.equal(init.method, "POST");
      assert.equal(input, `http://127.0.0.1:${port}/chat`);
      return fetch(input, init);
    },
    home: runtimeHome,
    workspaceRoot: runtimeWorkspace,
    instructions: marker,
    apiKey: "native-core-config-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "native/test-model",
  });
  await assert.rejects(
    access(projectMcpMarker),
    (error) => error?.code === "ENOENT",
    "native addon host must not start workspace MCP",
  );
  const turn = agent.prompt("read the explicit workspace context");
  for await (const _ of turn) {}
  await turn.result;
  assert.match(requestBody, new RegExp(marker), "native startup omitted explicit host instructions");
  assert.doesNotMatch(requestBody, new RegExp(workspaceMarker), "minimal kernel scanned workspace context");
  await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  assert.equal(await agent.close(), undefined);
  assert.equal(unexpectedRequests, 0, "kernel must not perform native billing lookups outside host fetch");
  console.log("native config isolation passed: explicit instructions, no workspace scan, and no native billing lookup");
} finally {
  await agent?.close();
  if (previousGatewayBase === undefined) delete process.env.FX_GATEWAY_BASE_URL;
  else process.env.FX_GATEWAY_BASE_URL = previousGatewayBase;
  process.chdir(originalCwd);
  server.closeAllConnections();
  server.close();
  await Promise.all([
    rm(processWorkspace, { recursive: true, force: true }),
    rm(runtimeHome, { recursive: true, force: true }),
    rm(runtimeWorkspace, { recursive: true, force: true }),
  ]);
}
