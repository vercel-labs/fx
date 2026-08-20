#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const marker = "LIBFX_EXPLICIT_WORKSPACE_CONTEXT";
const originalCwd = process.cwd();
const processWorkspace = await mkdtemp(join(tmpdir(), "libfx-process-workspace-"));
const runtimeHome = await mkdtemp(join(tmpdir(), "libfx-runtime-home-"));
const runtimeWorkspace = await mkdtemp(join(tmpdir(), "libfx-runtime-workspace-"));
await writeFile(join(processWorkspace, ".fx.json"), `${JSON.stringify({ context: false })}\n`);
await writeFile(join(runtimeWorkspace, ".fx.json"), `${JSON.stringify({ context: true })}\n`);
await writeFile(join(runtimeWorkspace, "AGENTS.md"), `# Context\n\n${marker}\n`);
await mkdir(join(runtimeHome, ".fx"));
await writeFile(join(runtimeHome, ".fx", "settings.json"), `${JSON.stringify({
  connections: {
    selected: "vercel",
    profiles: [{
      id: "vercel",
      display_name: "Vercel AI Gateway",
      adapter_id: "vercel_ai_gateway",
      endpoint: "https://ai-gateway.vercel.sh/v3/ai/language-model",
      protocol: "vercel_ai_gateway",
      credential_ref: "fx_login",
      remembered_model: "native/test-model",
      internal_models: {},
    }],
  },
})}\n`);

let requestBody = "";
let requestAuthorization = "";
const server = createServer((request, response) => {
  requestAuthorization = request.headers.authorization ?? "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { requestBody += chunk; });
  request.on("end", () => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write('data: {"type":"text-delta","delta":"isolated"}\n\n');
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));

try {
  process.chdir(processWorkspace);
  const agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    home: runtimeHome,
    workspaceRoot: runtimeWorkspace,
    env: {
      AI_GATEWAY_API_KEY: "native-core-config-key",
      FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${port}/chat`,
      FX_MODEL: "native/test-model",
    },
  });
  const session = await agent.createSession();
  const turn = session.prompt("read the explicit workspace context");
  await turn.result;
  assert.match(requestBody, new RegExp(marker), "native startup must load context policy from workspaceRoot, not process.cwd()" );
  assert.equal(requestAuthorization, "Bearer native-core-config-key", "native adapter auth must prefer the injected credential over the saved source backend");
  await session.close();
  assert.equal(await agent.close(), 0);
  console.log("native config isolation passed: explicit home and workspace own startup state");
} finally {
  process.chdir(originalCwd);
  server.closeAllConnections();
  server.close();
  await Promise.all([
    rm(processWorkspace, { recursive: true, force: true }),
    rm(runtimeHome, { recursive: true, force: true }),
    rm(runtimeWorkspace, { recursive: true, force: true }),
  ]);
}
