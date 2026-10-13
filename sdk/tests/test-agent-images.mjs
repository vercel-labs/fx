#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";
import { createFxEngine as createSharedAgent } from "../fx-sdk.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-images.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
// A real 1x1 PNG, plus a helper that builds a PNG-sniffable payload with an
// exact base64 length for limit probing (the kernel sniffs magic bytes only).
const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
// A different real 1x1 PNG, used as resizeImage output.
const resizedPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR42mNkAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
function pngWithEncodedLength(encodedLength) {
  assert.equal(encodedLength % 4, 0);
  const raw = Buffer.alloc((encodedLength / 4) * 3);
  Buffer.from(pngData, "base64").copy(raw);
  return raw.toString("base64");
}
const catalog = {
  object: "list",
  data: [
    { id: "sdk/vision-model", type: "language", tags: ["tool-use", "vision", "file-input"] },
    { id: "sdk/plain-model", type: "language" },
  ],
};

// Header fixtures exercise type and dimension admission without pixel decoding.
function imageHeader(mimeType, width, height = 1) {
  if (mimeType === "image/png") {
    const bytes = Buffer.from(pngData, "base64");
    bytes.writeUInt32BE(width, 16);
    bytes.writeUInt32BE(height, 20);
    return bytes;
  }
  if (mimeType === "image/jpeg") {
    const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 0, 0, 0, 1, 1]);
    bytes.writeUInt16BE(height, 7);
    bytes.writeUInt16BE(width, 9);
    return bytes;
  }
  if (mimeType === "image/gif") {
    const bytes = Buffer.alloc(10);
    bytes.write("GIF89a");
    bytes.writeUInt16LE(width, 6);
    bytes.writeUInt16LE(height, 8);
    return bytes;
  }
  const bytes = Buffer.alloc(30);
  bytes.write("RIFF");
  bytes.writeUInt32LE(22, 4);
  bytes.write("WEBPVP8X", 8);
  bytes.writeUInt32LE(10, 16);
  bytes.writeUIntLE(width - 1, 24, 3);
  bytes.writeUIntLE(height - 1, 27, 3);
  return bytes;
}

function toolResponse(name, input, id = "image-call") {
  return new Response([
    `data: ${JSON.stringify({ type: "tool-call", toolCallId: id, toolName: name, input })}`,
    'data: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}',
    "data: [DONE]",
    "",
  ].join("\n\n"), { headers: { "content-type": "text/event-stream" } });
}

function mockGateway(respond) {
  const state = { catalogFetches: 0, chatBodies: [] };
  const fetch = async (url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      state.catalogFetches += 1;
      return Response.json(catalog);
    }
    const body = JSON.parse(new TextDecoder().decode(init.body));
    state.chatBodies.push(body);
    const response = respond?.(body, state.chatBodies.length);
    if (response) return response;
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch };
}

const baseOptions = {
  backend,
  apiKey: "sdk-images-test-key",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
};
const createAgent = (gateway, overrides) =>
  createFxEngine({ ...baseOptions, fetch: gateway.fetch, ...overrides });

async function runPrompt(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

function fileParts(body) {
  return body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
}

// An image block reaches an image-capable model as a v4 file part, alongside
// the text and its placeholder.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [
    { type: "text", text: "what is in this image?" },
    { type: "image", data: pngData, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 1);
  const body = gateway.state.chatBodies[0];
  const files = fileParts(body);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  const text = body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
  assert.match(text, /what is in this image\?/);
  await agent.close();
}

// Blob and File use their own media types and share the base64 wire format
// and the kernel's byte-sniffing path on both backends.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: { id: "sdk/vision-model" } });
  const file = new File([Buffer.from(pngData, "base64")], "image.png", { type: "image/png" });
  const result = await runPrompt(agent, [
    { type: "text", text: "describe this file" },
    { type: "image", data: file },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: pngData } },
  ]);
  await agent.close();
}

// Every input form reaches the core as raw bytes beside the ACP frame. The
// session/prompt frame carries only an attachment reference, and the model
// request carries the image once, as base64.
for (const [label, toData] of [
  ["base64", () => pngData],
  ["Uint8Array", (bytes) => new Uint8Array(bytes)],
  ["ArrayBuffer", (bytes) => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)],
  ["Buffer", (bytes) => Buffer.from(bytes)],
]) {
  const gateway = mockGateway();
  const frames = [];
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type === "acp.send" && event.message?.method === "session/prompt") frames.push(event.message);
    },
  });
  const result = await runPrompt(agent, [
    { type: "text", text: `describe this ${label} image` },
    { type: "image", data: toData(Buffer.from(pngData, "base64")), mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn", label);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: pngData } },
  ], label);
  const image = frames[0].params.prompt.find((block) => block.type === "image");
  assert.equal(image.data, undefined, `${label} image bytes must not ride the ACP frame`);
  assert.ok(Number.isInteger(image._meta?.fx?.attachment), `${label} image must reference an attachment`);
  assert.ok(!JSON.stringify(frames[0]).includes(pngData), `${label} frame must not contain base64 image data`);
  await agent.close();
}

// Caller-owned bytes are captured when prompt() returns, on the synchronous
// path and on the asynchronous resizeImage path alike.
for (const resizeImage of [undefined, (image) => image]) {
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model", ...(resizeImage ? { resizeImage } : {}) });
  const bytes = new Uint8Array(Buffer.from(pngData, "base64"));
  const turn = agent.prompt([{ type: "image", data: bytes, mimeType: "image/png" }]);
  bytes.fill(0);
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(fileParts(gateway.state.chatBodies[0])[0].data.data, pngData);
  await agent.close();
}

// resizeImage takes and returns raw bytes. Its output replaces the image, may
// change the media type, and the byte limits apply to it instead of the input.
{
  const gateway = mockGateway();
  const calls = [];
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    async resizeImage({ bytes, mimeType }) {
      calls.push({ type: bytes.constructor.name, length: bytes.byteLength, mimeType });
      return { bytes: Buffer.from(resizedPng, "base64"), mimeType: "image/png" };
    },
  });
  const oversized = new Uint8Array(5 * 1024 * 1024);
  Buffer.from(pngData, "base64").copy(oversized);
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const result = await runPrompt(agent, [
    { type: "text", text: "resize these first" },
    { type: "image", data: new Blob([oversized], { type: "image/png" }) },
    { type: "image", data: jpeg, mimeType: "image/jpeg" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(calls, [
    { type: "Uint8Array", length: oversized.byteLength, mimeType: "image/png" },
    { type: "Uint8Array", length: jpeg.byteLength, mimeType: "image/jpeg" },
  ]);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: resizedPng } },
    { type: "file", mediaType: "image/png", data: { type: "data", data: resizedPng } },
  ]);
  await agent.close();
}

// A failing or invalid resizeImage rejects only that turn, before the prompt
// is sent, and the agent stays usable.
{
  const gateway = mockGateway();
  let mode;
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    resizeImage({ bytes, mimeType }) {
      if (mode === "throw") throw new Error("resize failed");
      if (mode === "invalid") return { bytes: "not bytes", mimeType };
      if (mode === "oversized") return { bytes: new Uint8Array(4 * 1024 * 1024), mimeType };
      if (mode === "fill") return { bytes: new Uint8Array(3 * 1024 * 1024), mimeType };
      return { bytes, mimeType };
    },
  });
  const image = [{ type: "image", data: pngData, mimeType: "image/png" }];
  // Hook output within the image budgets still counts toward the frame bound.
  mode = "fill";
  await assert.rejects(
    agent.prompt([...image, ...image]).result,
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  mode = "throw";
  await assert.rejects(agent.prompt(image).result, /resize failed/);
  mode = "invalid";
  await assert.rejects(
    agent.prompt(image).result,
    (error) => error instanceof TypeError && /resizeImage must return/.test(error.message),
  );
  mode = "oversized";
  await assert.rejects(
    agent.prompt(image).result,
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.equal(gateway.state.chatBodies.length, 0);
  mode = "keep";
  assert.equal((await runPrompt(agent, image)).stopReason, "end_turn");
  await agent.close();
  await assert.rejects(createAgent(mockGateway(), { resizeImage: "nope" }), /resizeImage must be a function/);
}

// A resizeImage that reuses one output buffer for every image still sends
// each image with the bytes the hook returned for it.
{
  const gateway = mockGateway();
  const scratch = new Uint8Array(4096);
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    resizeImage({ bytes, mimeType }) {
      scratch.set(bytes);
      return { bytes: scratch.subarray(0, bytes.byteLength), mimeType };
    },
  });
  const result = await runPrompt(agent, [
    { type: "image", data: pngData, mimeType: "image/png" },
    { type: "image", data: resizedPng, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]).map((part) => part.data.data), [pngData, resizedPng]);
  await agent.close();
}

// A pure-image prompt is valid; the placeholder keeps the turn non-empty.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [{ type: "image", data: pngData, mimeType: "image/png" }]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(fileParts(gateway.state.chatBodies[0]).length, 1);
  await agent.close();
}

// A model without advertised image input never receives the request; the turn
// fails with the explicit notice instead of crashing or sending the image.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/plain-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A model missing from the catalog cannot confirm image support: same
// explicit failure, still no image bytes on the wire.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/unlisted-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A proxy that refuses the catalog request leaves image support unknown, so
// an image-capable model refuses images. With `modelCatalog`, the same model
// takes the image and the catalog is never requested.
{
  const model = "sdk/proxied-vision-model";
  const refusing = mockGateway();
  const fetch405 = async (url, init = {}) => (String(init.method ?? "GET").toUpperCase() === "GET"
    ? new Response("", { status: 405 })
    : refusing.fetch(url, init));
  const blocked = await createFxEngine({ ...baseOptions, fetch: fetch405, model });
  const refused = blocked.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(refused.result, /Image prompts are unavailable for the selected model/);
  await blocked.close();

  const gateway = mockGateway();
  const modelCatalog = [{ id: model, type: "language", tags: ["tool-use", "vision", "file-input"] }];
  const agent = await createAgent(gateway, { model, modelCatalog });
  const result = await runPrompt(agent, [
    { type: "text", text: "what is in this image?" },
    { type: "image", data: pngData, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.catalogFetches, 0, "the supplied catalog replaces the request");
  assert.equal(fileParts(gateway.state.chatBodies[0]).length, 1);
  await agent.close();

  await assert.rejects(createAgent(mockGateway(), { modelCatalog: [{ name: "no id" }] }), /needs a string id/);
  await assert.rejects(createAgent(mockGateway(), { modelCatalog: "catalog" }), /modelCatalog must be/);
}

// Checkpoint/restore round-trips prompt images inside the checkpoint bound:
// the restored agent re-sends the same bytes on the next turn.
{
  const gateway = mockGateway();
  const first = await createAgent(gateway, { model: "sdk/vision-model" });
  const initial = await runPrompt(first, [
    { type: "text", text: "remember this image" },
    { type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) },
  ]);
  assert.equal(initial.stopReason, "end_turn");
  const checkpoint = await first.checkpoint();
  // More concurrent checkpoints than the native outbound table holds all succeed.
  const concurrent = await Promise.all(Array.from({ length: 16 }, () => first.checkpoint()));
  for (const bytes of concurrent) assert.deepEqual(Buffer.from(bytes), Buffer.from(checkpoint));
  await first.close();
  const stored = Buffer.from(checkpoint);
  assert.ok(stored.includes(Buffer.from(pngData, "base64")), "checkpoint must store the image bytes raw");
  assert.ok(!stored.includes(Buffer.from(pngData)), "checkpoint must not store the image as base64");

  const restored = await createAgent(gateway, { model: "sdk/vision-model", checkpoint });
  const followup = await runPrompt(restored, "describe it again");
  assert.equal(followup.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 2);
  const files = fileParts(gateway.state.chatBodies[1]);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  await restored.close();

  // Oversized and empty restore checkpoints fail with the same errors on both backends.
  await assert.rejects(
    createAgent(mockGateway(), { model: "sdk/vision-model", checkpoint: new Uint8Array(4 * 1024 * 1024 + 1) }),
    (error) => error.message === "libfx checkpoint is too large",
  );
  await assert.rejects(
    createAgent(mockGateway(), { model: "sdk/vision-model", checkpoint: new Uint8Array(0) }),
    (error) => error.message === "Invalid or non-fresh libfx checkpoint",
  );
}

// An idle checkpoint is sent before a later prompt, while one queued behind it
// follows the direct-call rule once that prompt is active.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  await runPrompt(agent, "first");
  const expected = Buffer.from(await agent.checkpoint());
  const idle = agent.checkpoint();
  const queued = agent.checkpoint();
  const turn = agent.prompt("second");
  assert.deepEqual(Buffer.from(await idle), expected);
  await assert.rejects(queued, /cannot checkpoint while a prompt is active/);
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  // The rejected call released its place, so the next call is idle again.
  const afterRejected = agent.checkpoint();
  const third = agent.prompt("third");
  assert.ok((await afterRejected).byteLength > 0);
  for await (const _ of third) {}
  await agent.close();
}

// A checkpoint requested from an event handler while another checkpoint's
// request is being sent waits for it instead of running beside it.
{
  const gateway = mockGateway();
  const nested = [];
  let agent;
  agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type === "acp.send" && event.message.method === "libfx/checkpoint" && nested.length < 8) {
        nested.push(agent.checkpoint());
      }
    },
  });
  await runPrompt(agent, "first");
  const expected = Buffer.from(await agent.checkpoint());
  for (let settled = -1; settled !== nested.length;) {
    settled = nested.length;
    await Promise.all(nested);
  }
  assert.equal(nested.length, 8);
  for (const bytes of await Promise.all(nested)) assert.deepEqual(Buffer.from(bytes), expected);
  await agent.close();
}

// SDK-side limits reject synchronously with typed errors naming the bound,
// before any runtime or network work.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });

  assert.throws(
    () => agent.prompt([{ type: "image", data: "", mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: pngData }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: 42, mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );

  assert.throws(
    () => agent.prompt([{ type: "image", data: new Blob(["untyped"]) }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Blob(["bytes"], { type: "image/png" }), mimeType: "image/jpeg" }]),
    (error) => error instanceof TypeError && /disagrees with Blob.type/.test(error.message),
  );
  for (const sourceRef of ["", null, 42, "\ud800", "\udfff", ...Array.from({ length: 32 }, (_, code) => `source${String.fromCharCode(code)}`), "source\x7f"]) {
    assert.throws(
      () => agent.prompt([{ type: "image", mimeType: "image/png", sourceRef }]),
      (error) => error instanceof TypeError && /sourceRef/.test(error.message),
    );
  }
  for (const sourceRef of ["x".repeat(513), "é".repeat(257), "\u{10000}".repeat(129)]) {
    assert.throws(
      () => agent.prompt([{ type: "image", mimeType: "image/png", sourceRef }]),
      (error) => error instanceof RangeError && /512 byte/.test(error.message),
    );
  }
  assert.throws(() => agent.prompt([{ type: "image", mimeType: "image/png" }]), TypeError);
  assert.throws(() => agent.prompt([{ type: "image", sourceRef: "host:missing-mime" }]), /requires a mimeType/);
  for (const mimeType of ["", null, 42, "x".repeat(129)]) {
    assert.throws(
      () => agent.prompt([{ type: "image", mimeType, sourceRef: "host:malformed-mime" }]),
      (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
    );
  }
  assert.throws(() => agent.prompt([{ type: "image", data: "", mimeType: "image/png", sourceRef: "host:empty-data" }]), /requires base64 data/);
  assert.throws(() => agent.prompt([{ type: "image", data: 42, mimeType: "image/png", sourceRef: "host:bad-data" }]), /requires base64 data/);
  assert.throws(() => agent.prompt([{ type: "image", data: new Blob(["bytes"], { type: "image/png" }), mimeType: "image/jpeg", sourceRef: "host:mismatch" }]), /disagrees with Blob.type/);
  assert.throws(() => agent.prompt(Array.from({ length: 9 }, (_, index) => ({ type: "image", mimeType: "image/png", sourceRef: `host:count-${index}` }))), /more than 8 images/);
  let readOversized = false;
  class OversizedBlob extends Blob {
    get size() { return 1; }
    async arrayBuffer() { readOversized = true; return super.arrayBuffer(); }
  }
  assert.throws(
    () => agent.prompt([{ type: "image", data: new OversizedBlob([Buffer.alloc(4 * 1024 * 1024)], { type: "image/png" }) }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.equal(readOversized, false);
  const budgetBlob = new Blob([Buffer.alloc(3.5 * 1024 * 1024)], { type: "image/png" });
  assert.throws(
    () => agent.prompt(Array.from({ length: 2 }, () => ({ type: "image", data: budgetBlob }))),
    (error) => error instanceof RangeError && /prompt images exceed/.test(error.message),
  );
  // Raw bytes follow the same raw-byte budgets as Blob and base64 input.
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Uint8Array(4 * 1024 * 1024), mimeType: "image/png" }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Uint8Array(0), mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data, bytes, or a Blob/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: Buffer.from(pngData, "base64") }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );

  const overSized = pngWithEncodedLength(5 * 1024 * 1024 + 4);
  assert.throws(
    () => agent.prompt([{ type: "image", data: overSized, mimeType: "image/png" }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );

  const nine = Array.from({ length: 9 }, () => ({ type: "image", data: pngData, mimeType: "image/png" }));
  assert.throws(
    () => agent.prompt(nine),
    (error) => error instanceof RangeError && /more than 8 images/.test(error.message),
  );

  const half = pngWithEncodedLength(Math.floor(4.25 * 1024 * 1024));
  assert.throws(
    () => agent.prompt([
      { type: "image", data: half, mimeType: "image/png" },
      { type: "image", data: half, mimeType: "image/png" },
    ]),
    (error) => error instanceof RangeError && /prompt images exceed/.test(error.message),
  );

  // The model request carries images base64 encoded, so text and encoded
  // images share the 8 MiB frame bound on both backends. Exactly 8 MiB of
  // encoded image data passes the image budgets but not that bound once text
  // and the envelope are added, as base64 or as raw bytes.
  const quarter = pngWithEncodedLength(4 * 1024 * 1024);
  for (const data of [quarter, Buffer.from(quarter, "base64")]) {
    assert.throws(
      () => agent.prompt([
        { type: "text", text: "boundary" },
        { type: "image", data, mimeType: "image/png" },
        { type: "image", data, mimeType: "image/png" },
      ]),
      (error) => error instanceof RangeError && /frame limit/.test(error.message),
    );
  }
  assert.throws(
    () => agent.prompt("x".repeat(9 * 1024 * 1024)),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  let readMixed = false;
  class UnreadBlob extends Blob {
    arrayBuffer() { readMixed = true; return new Promise(() => {}); }
  }
  assert.throws(
    () => agent.prompt([
      { type: "text", text: "x".repeat(9 * 1024 * 1024) },
      { type: "image", data: new UnreadBlob(["bytes"], { type: "image/png" }) },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  assert.equal(readMixed, false);

  // Two Blobs that fill the image budget exactly also fill the frame bound
  // once encoded, so they fail before any Blob read.
  const boundaryBlob = new Blob([Buffer.alloc(3 * 1024 * 1024)], { type: "image/png" });
  assert.throws(
    () => agent.prompt([
      { type: "image", data: boundaryBlob },
      { type: "image", data: boundaryBlob },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );

  class LyingBlob extends Blob {
    get size() { return 1; }
    async arrayBuffer() { return new ArrayBuffer(4 * 1024 * 1024); }
  }
  const actualOverflow = agent.prompt([{ type: "image", data: new LyingBlob(["x"], { type: "image/png" }) }]);
  await assert.rejects(actualOverflow.result, (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message));

  assert.equal(gateway.state.catalogFetches, 0);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// The SDK decodes base64 itself, so non-canonical base64 throws before the
// turn starts. Kernel-side content validation stays authoritative: a sniffed
// media type that contradicts the declaration fails the turn with a typed error
// rather than reaching the model.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  for (const data of ["aGVsbG8", "aGVsbG9=", "aGVs\nbG8=", "aGVsbG8*"]) {
    assert.throws(
      () => agent.prompt([{ type: "image", data, mimeType: "image/png" }]),
      (error) => error instanceof TypeError && /requires canonical base64 data/.test(error.message),
    );
  }
  const jpegBytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");
  const mismatch = agent.prompt([{ type: "image", data: jpegBytes, mimeType: "image/png" }]);
  await assert.rejects(mismatch.result, /Invalid image prompt block/);
  const blobMismatch = agent.prompt([
    { type: "image", data: new Blob([Buffer.from(jpegBytes, "base64")], { type: "image/png" }) },
  ]);
  await assert.rejects(blobMismatch.result, /Invalid image prompt block/);
  for (const mimeType of ["image/svg+xml", "text/plain", "image/png\n"]) {
    const referenceOnly = agent.prompt([{ type: "image", mimeType, sourceRef: "host:unsupported-mime" }]);
    await assert.rejects(referenceOnly.result, /Invalid image prompt block/);
  }
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A Blob read failure rejects only that turn and does not send a partial frame.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class BrokenBlob extends Blob {
    async arrayBuffer() { throw new Error("read failed"); }
  }
  const turn = agent.prompt([{ type: "image", data: new BrokenBlob(["bytes"], { type: "image/png" }) }]);
  await assert.rejects(turn.result, /read failed/);
  class CancelledBlob extends Blob {
    async arrayBuffer() { throw new Error("Cancelled"); }
  }
  const failedRead = agent.prompt([{ type: "image", data: new CancelledBlob(["bytes"], { type: "image/png" }) }]);
  await assert.rejects(failedRead.result, (error) => error.message === "Cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "retry with text")).stopReason, "end_turn");
  await agent.close();
}

// Steering during a Blob read waits for the prompt to reach the core on both
// backends instead of racing ahead of the initial session/prompt.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let finishRead;
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["x"], { type: "image/png" }) }]);
  const steering = turn.steer("focus on the image");
  await Promise.resolve();
  assert.equal(gateway.state.chatBodies.length, 0);
  finishRead(Buffer.from(pngData, "base64"));
  await steering;
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.ok(gateway.state.chatBodies.length >= 1);
  await agent.close();
}

// Cancel or close while Blob.arrayBuffer() is pending: settle promptly, do not
// send a late prompt, and leave the agent available for the next turn.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let finishRead;
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const blob = new SlowBlob([Buffer.from(pngData, "base64")], { type: "image/png" });
  const turn = agent.prompt([{ type: "image", data: blob }]);
  await Promise.resolve();
  const steering = turn.steer("pending guidance");
  turn.cancel();
  await assert.rejects(steering, /no prompt is running/);
  assert.equal((await turn.result).stopReason, "cancelled");
  finishRead(Buffer.from(pngData, "base64"));
  await new Promise((resolveTick) => setImmediate(resolveTick));
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "still usable")).stopReason, "end_turn");
  await agent.close();
}

{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise(() => {}); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
  await agent.close();
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
}

// A Blob can abort the signal synchronously from arrayBuffer(). The turn must
// still settle even when the read promise never resolves.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const controller = new AbortController();
  class AbortingBlob extends Blob {
    arrayBuffer() {
      controller.abort();
      return new Promise(() => {});
    }
  }
  const turn = agent.prompt([
    { type: "image", data: new AbortingBlob(["bytes"], { type: "image/png" }) },
  ], { signal: controller.signal });
  let timer;
  try {
    const result = await Promise.race([
      turn.result,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Blob abort did not settle")), 1500); }),
    ]);
    assert.equal(result.stopReason, "cancelled");
  } finally {
    clearTimeout(timer);
  }
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "usable after abort")).stopReason, "end_turn");
  await agent.close();
}

// Closing from arrayBuffer() must find an initialized turn result and release
// the runtime rather than rejecting before it can close stdin.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let closing;
  class ClosingBlob extends Blob {
    arrayBuffer() {
      closing = agent.close();
      return new Promise(() => {});
    }
  }
  const turn = agent.prompt([{ type: "image", data: new ClosingBlob(["bytes"], { type: "image/png" }) }]);
  await Promise.resolve();
  assert.ok(closing);
  let timer;
  try {
    await Promise.race([
      closing,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("reentrant close did not settle")), 1500); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
}

// A core exit before or just after Blob bytes arrive rejects the turn and
// iterator without submitting a prompt or reporting user cancellation.
for (const timing of ["during-read", "after-read"]) {
  let finishRuntime;
  let finishRead;
  let onLine;
  const sentMethods = [];
  const runtime = {
    exited: new Promise((resolveExit) => { finishRuntime = resolveExit; }),
    setLineHandler(handler) { onLine = handler; },
    write(line) {
      const request = JSON.parse(line);
      sentMethods.push(request.method);
      if (request.method === "initialize" || request.method === "libfx/new") {
        queueMicrotask(() => onLine({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "libfx/new" ? { sessionId: "image-exit-test" } : {},
        }));
      }
    },
    abortHostEffects() {},
    closeStdin() { finishRuntime(0); },
  };
  const controller = new AbortController();
  const agent = await createSharedAgent({
    apiKey: "image-exit-test-key",
    runtimeFactory: async () => runtime,
    onEvent(event) {
      if (event.type === "runtime.exit" && timing === "during-read") controller.abort();
    },
  });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }], { signal: controller.signal });
  const settled = Promise.all([
    assert.rejects(turn.result, /fx-core exited with code 1/),
    assert.rejects(turn[Symbol.asyncIterator]().next(), /fx-core exited with code 1/),
  ]);
  let timer;
  try {
    await Promise.resolve();
    if (timing === "after-read") finishRead(Buffer.from(pngData, "base64"));
    finishRuntime(1);
    await Promise.race([
      settled,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`core exit ${timing} did not settle Blob turn`)), 1500); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
  assert.equal(sentMethods.includes("session/prompt"), false);
  assert.equal(sentMethods.includes("session/cancel"), false);
  await agent.close();
}

// Queued steering must fail if the prompt write throws or the core exits as
// it accepts the write; neither case may deliver guidance to a dead turn.
for (const failure of ["write", "exit"]) {
  let finishRuntime;
  let onLine;
  let finishRead;
  const sentMethods = [];
  const runtime = {
    exited: new Promise((resolveExit) => { finishRuntime = resolveExit; }),
    setLineHandler(handler) { onLine = handler; },
    write(line) {
      const request = JSON.parse(line);
      sentMethods.push(request.method);
      if (request.method === "session/prompt") {
        if (failure === "write") throw new Error("prompt write failed");
        finishRuntime(1);
        return;
      }
      if (request.method === "initialize" || request.method === "libfx/new") {
        queueMicrotask(() => onLine({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "libfx/new" ? { sessionId: "image-write-test" } : {},
        }));
      }
    },
    steer(text) { sentMethods.push(`steer:${text}`); },
    writeAttachment(id) { sentMethods.push(`attachment:${id}`); },
    discardAttachments() {},
    abortHostEffects() {},
    closeStdin() { finishRuntime(0); },
  };
  const agent = await createSharedAgent({ apiKey: "image-write-test-key", runtimeFactory: async () => runtime });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
  const steering = turn.steer("queued guidance");
  await Promise.resolve();
  finishRead(Buffer.from(pngData, "base64"));
  const expectedError = failure === "write" ? /prompt write failed/ : /fx-core exited with code 1/;
  await assert.rejects(turn.result, expectedError);
  await assert.rejects(steering, expectedError);
  assert.equal(sentMethods.includes("steer:queued guidance"), false);
  await agent.close();
}

// Pre-prompt steering has the same count and byte limits as the core queue.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise(() => {}); }
  }
  for (const [payload, count] of [["x", 64], ["x".repeat(64 * 1024), 16]]) {
    const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
    const queued = Array.from({ length: count }, () => turn.steer(payload).catch((error) => error));
    await assert.rejects(turn.steer(payload), /steering queue is full/);
    turn.cancel();
    const rejected = await Promise.all(queued);
    assert.ok(rejected.every((error) => error instanceof Error && /no prompt is running/.test(error.message)));
    assert.equal((await turn.result).stopReason, "cancelled");
  }
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A pre-aborted Blob prompt must reject steering immediately.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const controller = new AbortController();
  controller.abort();
  const turn = agent.prompt([
    { type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) },
  ], { signal: controller.signal });
  await assert.rejects(turn.steer("late guidance"), /no prompt is running/);
  assert.equal((await turn.result).stopReason, "cancelled");
  await agent.close();
}

// Cancellation from the send event must not let a late prompt through after
// its session/cancel notification.
{
  const gateway = mockGateway();
  let turn;
  let promptSendEvents = 0;
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type !== "acp.send" || event.message?.method !== "session/prompt") return;
      promptSendEvents++;
      turn.cancel();
    },
  });
  turn = agent.prompt([{ type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) }]);
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(promptSendEvents, 1);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

function assertRecovery(body, sourceRefs, files = []) {
  assert.deepEqual(fileParts(body), files);
  const feedback = JSON.stringify(body.prompt);
  assert.match(feedback, /not sent/);
  for (const sourceRef of sourceRefs) assert.ok(feedback.includes(sourceRef), `recovery feedback lost ${sourceRef}`);
}

// Eligible originals, including Blob input and the 8000-pixel boundary, retain
// their bytes. A source reference must not trigger automatic conversion.
const mediaTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
for (const [index, mimeType] of mediaTypes.entries()) {
  const bytes = imageHeader(mimeType, 8000);
  const sourceRef = `host:eligible-${index}`;
  const data = index % 2 === 0 ? new Blob([bytes], { type: mimeType }) : bytes.toString("base64");
  let wire;
  const gateway = mockGateway();
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) { if (event.type === "acp.send" && event.message?.method === "session/prompt") wire = event.message.params.prompt; },
  });
  assert.equal((await runPrompt(agent, [{ type: "image", data, mimeType, sourceRef }])).stopReason, "end_turn");
  assert.equal(wire.length, 1);
  assert.equal(wire[0].type, "image");
  assert.equal(wire[0].mimeType, mimeType);
  assert.equal(wire[0].sourceRef, sourceRef);
  assert.equal(wire[0].data, undefined);
  assert.ok(Number.isSafeInteger(wire[0]._meta?.fx?.attachment) && wire[0]._meta.fx.attachment > 0);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [{ type: "file", mediaType: mimeType, data: { type: "data", data: bytes.toString("base64") } }]);
  assert.equal(gateway.state.chatBodies.length, 1);
  await agent.close();
}

for (const resize of [false, true]) {
  const sourceRef = `host:raw-reference-${resize}`;
  const original = imageHeader("image/png", resize ? 8001 : 2000);
  const prepared = imageHeader("image/png", 2000);
  let resizeCalls = 0;
  let wire;
  const gateway = mockGateway();
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    ...(resize ? { resizeImage({ bytes, mimeType }) {
      resizeCalls++;
      assert.deepEqual(Buffer.from(bytes), original);
      assert.equal(mimeType, "image/png");
      return { bytes: prepared, mimeType };
    } } : {}),
    onEvent(event) { if (event.type === "acp.send" && event.message?.method === "session/prompt") wire = event.message.params.prompt; },
  });
  assert.equal((await runPrompt(agent, [{ type: "image", data: original, mimeType: "image/png", sourceRef }])).stopReason, "end_turn");
  assert.equal(wire[0].sourceRef, sourceRef);
  assert.equal(wire[0].data, undefined);
  assert.ok(Number.isSafeInteger(wire[0]._meta?.fx?.attachment));
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [{ type: "file", mediaType: "image/png", data: { type: "data", data: (resize ? prepared : original).toString("base64") } }]);
  assert.equal(resizeCalls, resize ? 1 : 0);
  await agent.close();
}

{
  const sourceRef = "host:reference-with-resize-hook";
  const gateway = mockGateway();
  let resizeCalls = 0;
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    resizeImage() { resizeCalls++; throw new Error("reference-only input must not invoke resizeImage"); },
  });
  assert.equal((await runPrompt(agent, [{ type: "image", mimeType: "image/png", sourceRef }])).stopReason, "end_turn");
  assertRecovery(gateway.state.chatBodies[0], [sourceRef]);
  assert.equal(resizeCalls, 0);
  await agent.close();
}

// History, not just the current prompt, determines the pixel limit. Crossing
// twenty images with three seven-image turns withholds all originals at 2000px
// without losing source bytes or refs during later turns and checkpoint restore.
{
  const data = imageHeader("image/jpeg", 3420, 2224).toString("base64");
  const images = Array.from({ length: 21 }, (_, index) => ({ type: "image", data, mimeType: "image/jpeg", sourceRef: `host:history-${String(index + 1).padStart(2, "0")}` }));
  const expectedFile = { type: "file", mediaType: "image/jpeg", data: { type: "data", data } };
  const refs = images.map((image) => image.sourceRef);
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let checkpoint14;
  const assertHistoryRecovery = (body) => {
    assertRecovery(body, refs);
    const notices = body.prompt
      .filter((message) => message.role === "user" && Array.isArray(message.content))
      .flatMap((message) => message.content)
      .filter((part) => part.type === "text")
      .flatMap((part) => part.text.split("\n"))
      .filter((line) => line.includes("not sent"));
    assert.equal(notices.length, 21);
    for (const sourceRef of refs) {
      const notice = notices.find((line) => line.includes(sourceRef));
      assert.ok(notice, `missing history recovery notice for ${sourceRef}`);
      assert.match(notice, /3420x2224/);
      assert.match(notice, /at most 2000 per side/);
    }
  };
  const assertRetainedBytes = (checkpoint) => {
    assert.ok(checkpoint.byteLength < 4 * 1024 * 1024);
    const bytes = Buffer.from(checkpoint);
    const original = Buffer.from(data, "base64");
    let copies = 0;
    for (let offset = 0; (offset = bytes.indexOf(original, offset)) !== -1; offset += original.length) copies++;
    assert.equal(copies, 21);
  };
  for (let turn = 0; turn < 3; turn++) {
    assert.equal((await runPrompt(agent, images.slice(turn * 7, (turn + 1) * 7))).stopReason, "end_turn");
    const body = gateway.state.chatBodies[turn];
    if (turn < 2) assert.deepEqual(fileParts(body), Array.from({ length: (turn + 1) * 7 }, () => expectedFile));
    else assertHistoryRecovery(body);
    if (turn === 1) checkpoint14 = await agent.checkpoint();
  }
  assert.equal((await runPrompt(agent, "refer to the same originals again")).stopReason, "end_turn");
  assertHistoryRecovery(gateway.state.chatBodies[3]);
  const checkpoint21 = await agent.checkpoint();
  assertRetainedBytes(checkpoint21);
  await agent.close();

  const restored21 = await createAgent(gateway, { model: "sdk/vision-model", checkpoint: checkpoint21 });
  assert.deepEqual(await restored21.checkpoint(), checkpoint21);
  assert.equal((await runPrompt(restored21, "recover the retained image references")).stopReason, "end_turn");
  assertHistoryRecovery(gateway.state.chatBodies[4]);
  assertRetainedBytes(await restored21.checkpoint());
  await restored21.close();

  // Below the count boundary, checkpoint restore still re-sends every original
  // unchanged rather than retaining only refs or a prepared derivative.
  const restored14 = await createAgent(gateway, { model: "sdk/vision-model", checkpoint: checkpoint14 });
  assert.equal((await runPrompt(restored14, "inspect the fourteen originals")).stopReason, "end_turn");
  assert.deepEqual(fileParts(gateway.state.chatBodies[5]), Array.from({ length: 14 }, () => expectedFile));
  assert.equal(gateway.state.chatBodies.length, 6);
  await restored14.close();
}

// Oversized originals in every supported format are withheld with a recoverable
// source reference, even when no host tool exists. No synthetic resizer appears.
for (const [index, mimeType] of mediaTypes.entries()) {
  const sourceRef = `host:oversized-${index}`;
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  assert.equal((await runPrompt(agent, [{ type: "image", data: imageHeader(mimeType, 8001).toString("base64"), mimeType, sourceRef }])).stopReason, "end_turn");
  assertRecovery(gateway.state.chatBodies[0], [sourceRef]);
  assert.equal(gateway.state.chatBodies[0].tools?.length ?? 0, 0);
  assert.equal(gateway.state.chatBodies.length, 1);
  await agent.close();
}

// A reference-only prompt stays reference-only on the wire. Per-image overflow
// drops referenced data before reading a Blob, including misleading size getters.
{
  let reads = 0;
  class UnreadOversizedBlob extends Blob {
    get size() { return 1; }
    arrayBuffer() { reads++; throw new Error("oversized original must remain host-owned"); }
  }
  class ActualOversizedBlob extends Blob {
    async arrayBuffer() { return new ArrayBuffer(4 * 1024 * 1024); }
  }
  const cases = [
    { sourceRef: "host:ref-only" },
    { sourceRef: "host:byte-overflow", data: pngWithEncodedLength(5 * 1024 * 1024 + 4) },
    { sourceRef: "host:blob-overflow", data: new UnreadOversizedBlob([Buffer.alloc(4 * 1024 * 1024)], { type: "image/png" }) },
    { sourceRef: "host:actual-overflow", data: new ActualOversizedBlob(["x"], { type: "image/png" }) },
  ];
  for (const image of cases) {
    let wire;
    const gateway = mockGateway();
    const agent = await createAgent(gateway, {
      model: "sdk/vision-model",
      onEvent(event) { if (event.type === "acp.send" && event.message?.method === "session/prompt") wire = event.message.params.prompt; },
    });
    assert.equal((await runPrompt(agent, [{ type: "image", mimeType: "image/png", ...image }])).stopReason, "end_turn");
    assert.deepEqual(wire, [{ type: "image", mimeType: "image/png", sourceRef: image.sourceRef }]);
    assertRecovery(gateway.state.chatBodies[0], [image.sourceRef]);
    await agent.close();
  }
  assert.equal(reads, 0);
}

// Aggregate image budgets and the complete ACP envelope both fall back to refs.
// A mixed prompt preserves the unreferenced image, not an arbitrarily wider limit.
{
  let reads = 0;
  class UnreadBlob extends Blob {
    arrayBuffer() { reads++; throw new Error("aggregate-overflow Blob must not be read"); }
  }
  const half = pngWithEncodedLength(4.25 * 1024 * 1024);
  const quarter = pngWithEncodedLength(4 * 1024 * 1024);
  const blob = new UnreadBlob([Buffer.alloc(3.5 * 1024 * 1024)], { type: "image/png" });
  const cases = [
    [ { data: half, sourceRef: "host:aggregate-1" }, { data: half, sourceRef: "host:aggregate-2" } ],
    [ { data: quarter, sourceRef: "host:envelope-1" }, { data: quarter, sourceRef: "host:envelope-2" } ],
    [ { data: blob, sourceRef: "host:blob-frame-1" }, { data: blob, sourceRef: "host:blob-frame-2" } ],
    [ { data: half }, { data: half, sourceRef: "host:mixed" } ],
  ];
  for (const images of cases) {
    let wire;
    const gateway = mockGateway();
    const agent = await createAgent(gateway, {
      model: "sdk/vision-model",
      onEvent(event) { if (event.type === "acp.send" && event.message?.method === "session/prompt") wire = event.message.params.prompt; },
    });
    assert.equal((await runPrompt(agent, images.map((image) => ({ type: "image", mimeType: "image/png", ...image })))).stopReason, "end_turn");
    for (const [index, image] of images.entries()) {
      if (image.sourceRef) assert.deepEqual(wire[index], { type: "image", mimeType: "image/png", sourceRef: image.sourceRef });
      else {
        assert.equal(wire[index].data, undefined);
        assert.ok(Number.isSafeInteger(wire[index]._meta?.fx?.attachment) && wire[index]._meta.fx.attachment > 0);
      }
    }
    const files = images.filter((image) => !image.sourceRef).map((image) => ({ type: "file", mediaType: "image/png", data: { type: "data", data: image.data } }));
    assertRecovery(gateway.state.chatBodies[0], images.flatMap((image) => image.sourceRef ? [image.sourceRef] : []), files);
    await agent.close();
  }
  assert.equal(reads, 0);
}

// Refs count toward the existing eight-image bound; 512 UTF-8 bytes of valid
// metadata (including surrogate pairs and a BOM) are preserved exactly.
{
  let wire;
  const gateway = mockGateway();
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) { if (event.type === "acp.send" && event.message?.method === "session/prompt") wire = event.message.params.prompt; },
  });
  const refs = ["x".repeat(512), "é".repeat(256), "\u{10000}".repeat(128), "\ufeffsource", ...Array.from({ length: 4 }, (_, index) => `host:ref-${index}`)];
  const images = refs.map((sourceRef) => ({ type: "image", mimeType: "image/png", sourceRef }));
  assert.equal((await runPrompt(agent, images)).stopReason, "end_turn");
  assert.deepEqual(wire, images);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), []);
  await agent.close();
}

// Checkpoints retain both reference-only and dimension-withheld originals. A
// restored host receives the same refs without any SDK-owned source store.
{
  const refs = ["host:checkpoint-ref", "host:checkpoint-original"];
  const gateway = mockGateway();
  const first = await createAgent(gateway, { model: "sdk/vision-model" });
  await runPrompt(first, [
    { type: "image", mimeType: "image/png", sourceRef: refs[0] },
    { type: "image", data: imageHeader("image/png", 8001).toString("base64"), mimeType: "image/png", sourceRef: refs[1] },
  ]);
  const checkpoint = await first.checkpoint();
  await first.close();
  const restored = await createAgent(gateway, { model: "sdk/vision-model", checkpoint });
  assert.equal((await runPrompt(restored, "recover the saved originals")).stopReason, "end_turn");
  assertRecovery(gateway.state.chatBodies[1], refs);
  assert.equal(gateway.state.chatBodies.length, 2);
  await restored.close();
}

// Existing host execute() tools recover a referenced original. The host, not
// libfx, creates the smaller bytes. Tool refs also survive checkpoint/restore.
{
  const sourceRef = "host:tool-original";
  const prepared = imageHeader("image/png", 2000).toString("base64");
  const calls = [];
  const gateway = mockGateway((body, step) => {
    if (step === 1) return toolResponse("load_image", { sourceRef }, "original");
    if (step === 2) {
      assertRecovery(body, [sourceRef]);
      return toolResponse("prepare_image", { sourceRef }, "prepared");
    }
    assert.ok(step === 3 || step === 4);
    assertRecovery(body, [sourceRef], [{ type: "file", mediaType: "image/png", data: { type: "data", data: prepared } }]);
  });
  const tool = (name, execute) => ({ name, description: name, inputSchema: { type: "object", properties: { sourceRef: { type: "string" } }, required: ["sourceRef"] }, execute });
  const tools = [
    tool("load_image", (input, { signal }) => {
      assert.deepEqual(input, { sourceRef });
      assert.equal(signal.aborted, false);
      calls.push("load_image");
      return { type: "libfx.tool-result", text: "Original is host-owned", images: [{ type: "image", mimeType: "image/png", sourceRef }] };
    }),
    tool("prepare_image", (input, { signal }) => {
      assert.deepEqual(input, { sourceRef });
      assert.equal(signal.aborted, false);
      calls.push("prepare_image");
      return { type: "libfx.tool-result", text: "Host prepared a smaller copy", images: [{ type: "image", data: prepared, mimeType: "image/png", sourceRef }] };
    }),
  ];
  const agent = await createAgent(gateway, { model: "sdk/vision-model", tools });
  assert.equal((await runPrompt(agent, "load and inspect the host image")).stopReason, "end_turn");
  assert.deepEqual(calls, ["load_image", "prepare_image"]);
  assert.deepEqual(gateway.state.chatBodies[0].tools.map((item) => item.name).sort(), ["load_image", "prepare_image"]);
  const checkpoint = await agent.checkpoint();
  await agent.close();
  const restored = await createAgent(gateway, { model: "sdk/vision-model", tools, checkpoint });
  assert.equal((await runPrompt(restored, "use the saved image refs")).stopReason, "end_turn");
  assert.deepEqual(calls, ["load_image", "prepare_image"]);
  await restored.close();
}

// Rich host results share the existing data/count/frame limits. Referenced
// overflow falls back to metadata; no-ref and malformed results remain errors.
{
  const image = (data, sourceRef) => ({ type: "image", mimeType: "image/png", ...(data === undefined ? {} : { data }), ...(sourceRef === undefined ? {} : { sourceRef }) });
  const large = pngWithEncodedLength(5 * 1024 * 1024 + 4);
  const half = pngWithEncodedLength(4.25 * 1024 * 1024);
  const quarter = pngWithEncodedLength(4 * 1024 * 1024);
  const cases = [
    { images: [image(large, "host:tool-bytes")], refs: ["host:tool-bytes"] },
    { images: [image(half, "host:tool-frame-1"), image(half, "host:tool-frame-2")], refs: ["host:tool-frame-1", "host:tool-frame-2"] },
    { images: [image(quarter, "host:tool-envelope-1"), image(quarter, "host:tool-envelope-2")], refs: ["host:tool-envelope-1", "host:tool-envelope-2"] },
    { images: [image(large)], error: /invalid tool image/ },
    { images: [image(half), image(half)], error: /tool images exceed the result limit/ },
    { images: [image(quarter), image(quarter)], error: /typed tool result exceeds the result limit/ },
    { images: [image(undefined)], error: /invalid tool image/ },
    ...["", "host\x00bad", "é".repeat(257), "\ud800"].map((sourceRef) => ({ images: [image(undefined, sourceRef)], error: /sourceRef/ })),
    { images: Array.from({ length: 9 }, () => image(undefined, "host:ninth")), error: /invalid typed tool result/ },
  ];
  for (const scenario of cases) {
    const gateway = mockGateway((body, step) => {
      if (step === 1) return toolResponse("load_image", {});
      assert.equal(step, 2);
      if (scenario.error) {
        assert.match(JSON.stringify(body.prompt), scenario.error);
        assert.deepEqual(fileParts(body), []);
      } else assertRecovery(body, scenario.refs);
    });
    const agent = await createAgent(gateway, {
      model: "sdk/vision-model",
      tools: [{ name: "load_image", description: "Load the host image", inputSchema: { type: "object" }, execute: () => ({ type: "libfx.tool-result", text: "host image", images: scenario.images }) }],
    });
    assert.equal((await runPrompt(agent, "load the image")).stopReason, "end_turn");
    assert.equal(gateway.state.chatBodies.length, 2);
    await agent.close();
  }
}

// Rich JSON may fit its own result bound but overflow after ACP string escaping.
// At that last boundary, references survive instead of becoming a generic error.
for (const referenced of [true, false]) {
  const images = [{ type: "image", data: pngWithEncodedLength(4096), mimeType: "image/png", ...(referenced ? { sourceRef: "host:outer-frame" } : {}) }];
  const text = "x".repeat(8 * 1024 * 1024 - encoded.encode(JSON.stringify({ text: "", images })).length - 32);
  const content = JSON.stringify({ text, images });
  assert.ok(encoded.encode(content).length < 8 * 1024 * 1024);
  assert.ok(encoded.encode(JSON.stringify({ jsonrpc: "2.0", id: "outer-image", result: { content, isError: false, contentType: "rich" } })).length + 1 > 8 * 1024 * 1024);
  let finishRuntime;
  let onLine;
  let promptId;
  let toolResult;
  const runtime = {
    exited: new Promise((resolveExit) => { finishRuntime = resolveExit; }),
    setLineHandler(handler) { onLine = handler; },
    write(line) {
      const request = JSON.parse(line);
      if (request.method === "session/prompt") {
        promptId = request.id;
        queueMicrotask(() => onLine({ jsonrpc: "2.0", id: "outer-image", method: "libfx/tool_call", params: { sessionId: "outer-frame", name: "load_image", input: {} } }));
      } else if (request.id === "outer-image") {
        toolResult = request.result;
        assert.ok(encoded.encode(line).length <= 8 * 1024 * 1024);
        queueMicrotask(() => onLine({ jsonrpc: "2.0", id: promptId, result: { stopReason: "end_turn" } }));
      } else {
        queueMicrotask(() => onLine({ jsonrpc: "2.0", id: request.id, result: request.method === "libfx/new" ? { sessionId: "outer-frame" } : {} }));
      }
    },
    abortHostEffects() {},
    closeStdin() { finishRuntime(0); },
  };
  const agent = await createSharedAgent({
    apiKey: "outer-frame-test-key",
    runtimeFactory: async () => runtime,
    tools: [{ name: "load_image", description: "Load a host image", inputSchema: { type: "object" }, execute: () => ({ type: "libfx.tool-result", text, images }) }],
  });
  assert.equal((await runPrompt(agent, "load the image")).stopReason, "end_turn");
  if (referenced) {
    assert.equal(toolResult.isError, false);
    assert.equal(toolResult.contentType, "rich");
    assert.deepEqual(JSON.parse(toolResult.content).images, [{ type: "image", mimeType: "image/png", sourceRef: "host:outer-frame" }]);
  } else {
    assert.equal(toolResult.isError, true);
    assert.equal(toolResult.content, "Host tool result exceeded the response frame limit");
  }
  await agent.close();
}

// A failed recovery tool remains an observable tool error; the withheld source
// never leaks as an image file and no hidden fallback executor is substituted.
{
  const sourceRef = "host:failed-recovery";
  const gateway = mockGateway((body, step) => {
    assertRecovery(body, [sourceRef]);
    if (step === 1) return toolResponse("prepare_image", { sourceRef });
    assert.equal(step, 2);
    assert.match(JSON.stringify(body.prompt), /host preparation failed/);
  });
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    tools: [{ name: "prepare_image", description: "Prepare a host image", inputSchema: { type: "object" }, execute() { throw new Error("host preparation failed"); } }],
  });
  assert.equal((await runPrompt(agent, [{ type: "image", mimeType: "image/png", sourceRef }])).stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 2);
  await agent.close();
}

// Cancellation reaches the host recovery signal, ignores a late rich result,
// and leaves the agent usable without a follow-up model request for that turn.
{
  const sourceRef = "host:cancel-recovery";
  let started;
  let finish;
  let signal;
  const executing = new Promise((resolveStarted) => { started = resolveStarted; });
  const gateway = mockGateway((body, step) => {
    if (step === 1) {
      assertRecovery(body, [sourceRef]);
      return toolResponse("prepare_image", { sourceRef });
    }
  });
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    tools: [{ name: "prepare_image", description: "Prepare a host image", inputSchema: { type: "object" }, execute(input, context) {
      assert.deepEqual(input, { sourceRef });
      signal = context.signal;
      started();
      return new Promise((resolveResult) => { finish = resolveResult; });
    } }],
  });
  const turn = agent.prompt([{ type: "image", mimeType: "image/png", sourceRef }]);
  const drain = (async () => { for await (const _ of turn) {} })();
  await executing;
  turn.cancel();
  assert.equal(signal.aborted, true);
  assert.equal((await turn.result).stopReason, "cancelled");
  await drain;
  finish({ type: "libfx.tool-result", text: "late image", images: [{ type: "image", data: pngData, mimeType: "image/png", sourceRef }] });
  await new Promise((resolveTick) => setImmediate(resolveTick));
  assert.equal(gateway.state.chatBodies.length, 1);
  assert.equal((await runPrompt(agent, "usable after image recovery cancellation")).stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 2);
  assert.deepEqual(fileParts(gateway.state.chatBodies[1]), []);
  await agent.close();
}

console.log(`${backend} agent image prompts passed`);
