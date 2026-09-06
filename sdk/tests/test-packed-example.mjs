#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const backend = process.argv[3] || "native";
const format = process.argv[4] || "esm";
if (process.argv[2] !== "--installed") {
  const temp = await mkdtemp(resolve(tmpdir(), "libfx-packed-"));
  function run(command, args, cwd) {
    const result = spawnSync(command, args, { cwd, encoding: "utf8", timeout: 120_000 });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    return result.stdout;
  }
  try {
    const input = resolve(process.argv[2]);
    const consumer = resolve(temp, "consumer");
    await mkdir(consumer);
    await writeFile(resolve(consumer, "package.json"), '{"private":true,"type":"module"}\n');
    const archive = input.endsWith(".tgz") ? input : resolve(temp,
      JSON.parse(run("npm", ["pack", input, "--ignore-scripts", "--pack-destination", temp, "--json"], temp))[0].filename);
    run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", archive], consumer);
    await cp(fileURLToPath(import.meta.url), resolve(consumer, "example.mjs"));
    console.log(run(process.execPath, [...process.execArgv, "example.mjs", "--installed", backend, format], consumer).trim());
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
} else {
  const { createFxAgent } = format === "cjs" ? createRequire(import.meta.url)("libfx") : await import("libfx");
  const { createMcpAdapter } = await import("libfx/mcp");
  const { createSkillsAdapter } = await import("libfx/skills");
  assert.equal(typeof createMcpAdapter, "function");
  assert.equal(typeof createSkillsAdapter, "function");

  let requestedAuthorization;
  let requestedModel;
  const server = createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end('{"object":"list","data":[]}');
        return;
      }
      requestedAuthorization = request.headers.authorization;
      requestedModel = request.headers["ai-language-model-id"];
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end('data: {"type":"text-delta","delta":"packed"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n');
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

  const agent = await createFxAgent({
    backend,
    fetch(input, init) {
      const origin = `http://127.0.0.1:${server.address().port}`;
      const url = init?.method === "GET" ? `${origin}/models` : String(input);
      assert.equal(new URL(url).origin, origin);
      return fetch(url, init);
    },
    apiKey: "packed-key",
    gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
    model: "packed/model",
  });
  try {
    assert.deepEqual(Object.keys(agent).sort(), ["checkpoint", "close", "prompt"]);
    const turn = agent.prompt("hello");
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    assert.equal(text, "packed");
    assert.deepEqual(await turn.result, { stopReason: "end_turn", usage: { inputTokens: 1, outputTokens: 1 } });
    assert.equal(requestedAuthorization, "Bearer packed-key");
    assert.equal(requestedModel, "packed/model");
    assert.ok((await agent.checkpoint()).length > 48);
    await agent.close();
    console.log(`${format} ${backend} packed libfx example passed`);
  } finally {
    await agent.close().catch(() => {});
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}
