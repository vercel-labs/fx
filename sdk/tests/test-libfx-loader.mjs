#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { closeSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  createFxAgent,
  createFxTerminal,
  fxSdkApiVersion,
  libfxApiVersion,
  listModels,
} from "../node.js";
import * as browser from "../browser.js";

assert.equal(libfxApiVersion, 2);
assert.equal(fxSdkApiVersion, 2);
assert.equal(browser.libfxApiVersion, 2);
assert.equal(typeof browser.createFxAgent, "function");
assert.equal(typeof browser.createFxTerminal, "function");
assert.equal(typeof browser.listModels, "function");
assert.equal(typeof listModels, "function");

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const realNativeAddon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const dir = await mkdtemp(resolve(tmpdir(), "libfx-loader-"));
const nativePath = resolve(dir, "native.mjs");
await writeFile(nativePath, `
  export const libfxApiVersion = 2;
  export async function createFxTerminal(options) { return { backend: "native-terminal", options }; }
`);
const nativeUrl = pathToFileURL(nativePath);

const highLevelAgentPath = resolve(dir, "high-level-agent.mjs");
await writeFile(highLevelAgentPath, `
  export const libfxApiVersion = 2;
  export function createFxAgent() { throw new Error("high-level createFxAgent invoked"); }
`);

// Complete the fixture directory before a runtime caches its module-resolution entries.
const coreOnlyPath = resolve(dir, "core-only.mjs");
await writeFile(coreOnlyPath, `
  export const libfxApiVersion = 3;
  export function createCore() { throw new Error("unused createCore"); }
`);
const incompatiblePath = resolve(dir, "incompatible.mjs");
await writeFile(incompatiblePath, `
  export const libfxApiVersion = 4;
  export async function createFxAgent() {}
`);
const versionFixtures = [
  ["missing-version", `
    export function createCore() { throw new Error("missing-version createCore invoked"); }
  `],
  ["unequal-version", `
    export const libfxApiVersion = 4;
    export function createCore() { throw new Error("unequal-version createCore invoked"); }
  `],
];
for (const [name, source] of versionFixtures) await writeFile(resolve(dir, `${name}.mjs`), source);
const matchingVersionPath = resolve(dir, "matching-version.mjs");
await writeFile(matchingVersionPath, `
  export const libfxApiVersion = 3;
  export function createCore() {
    const error = new Error("matching-version createCore invoked");
    error.code = "MATCHING_VERSION_INVOKED";
    throw error;
  }
`);
await assert.rejects(
  createFxAgent({
    backend: "native",
    nativeAddon: pathToFileURL(highLevelAgentPath),
    apiKey: "loader-key",
  }),
  (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
    error.message.includes("createCore") &&
    !String(error.cause).includes("high-level createFxAgent invoked"),
);

for (const gatewayChatUrl of [
  "http://attacker.example/chat",
  "https://[redacted]@example.com/chat",
  "https://example.com/chat",
  "file:///tmp/socket",
]) {
  await assert.rejects(
    createFxAgent({ backend: "native", nativeAddon: realNativeAddon, apiKey: "loader-key", gatewayChatUrl }),
    TypeError,
  );
}

await assert.rejects(
  createFxAgent({
    nativeAddon: nativeUrl,
    apiKey: "loader-key",
    env: { FX_MODEL: "legacy/model" },
  }),
  (error) => error instanceof TypeError && error.message.includes("apiKey") && error.message.includes("model"),
);
await assert.rejects(
  browser.createFxAgent({ apiKey: "loader-key", env: { FX_MODEL: "legacy/model" } }),
  (error) => error instanceof TypeError && error.message.includes("apiKey") && error.message.includes("model"),
);
await assert.rejects(
  createFxAgent({ nativeAddon: nativeUrl, apiKey: "loader-key", env: undefined }),
  (error) => error instanceof TypeError && error.message.includes("apiKey") && error.message.includes("model"),
);

for (const [options, errorType, message] of [
  [{}, TypeError, "apiKey"],
  [{ apiKey: "" }, TypeError, "apiKey"],
  [{ apiKey: 1 }, TypeError, "apiKey"],
  [{ apiKey: "loader-key", model: "" }, TypeError, "model"],
  [{ apiKey: "loader-key", model: 1 }, TypeError, "model"],
  [{ apiKey: "x".repeat(65_537) }, RangeError, "65536"],
  [{ apiKey: "loader-key", model: "x".repeat(1_025) }, RangeError, "1024"],
]) {
  await assert.rejects(
    createFxAgent({ backend: "native", nativeAddon: realNativeAddon, ...options }),
    (error) => error instanceof errorType && error.message.includes(message),
  );
}

const terminal = await createFxTerminal({ nativeAddon: nativeUrl, env: { FX_THEME: "dark" }, marker: 2 });
assert.equal(terminal.backend, "native-terminal");
assert.equal(terminal.options.marker, 2);
assert.deepEqual(terminal.options.env, { FX_THEME: "dark" });

const savedSuspending = WebAssembly.Suspending;
const savedPromising = WebAssembly.promising;
try {
  Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: undefined });
  Object.defineProperty(WebAssembly, "promising", { configurable: true, value: undefined });
  await assert.rejects(
    createFxAgent({ nativeAddon: nativeUrl, backend: "wasm", apiKey: "loader-key" }),
    (error) => error?.code === "LIBFX_JSPI_REQUIRED" &&
      error.message.includes("--experimental-wasm-jspi"),
  );
  await assert.rejects(
    createFxAgent({ nativeAddon: realNativeAddon, apiKey: "loader-key", instructions: "x".repeat(65_537) }),
    (error) => error instanceof RangeError && error.message.includes("65536"),
  );
  await assert.rejects(
    createFxAgent({
      nativeAddon: realNativeAddon,
      checkpoint: new Uint8Array([1, 2, 3]),
      apiKey: "loader-checkpoint-key",
    }),
    (error) => error.message.includes("Invalid or non-fresh libfx checkpoint"),
  );
} finally {
  Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: savedSuspending });
  Object.defineProperty(WebAssembly, "promising", { configurable: true, value: savedPromising });
}

await assert.rejects(
  createFxTerminal({ nativeAddon: pathToFileURL(coreOnlyPath), backend: "native" }),
  (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
    error.message.includes("createFxTerminal"),
);

await assert.rejects(
  createFxAgent({ nativeAddon: pathToFileURL(incompatiblePath), backend: "native", apiKey: "loader-key" }),
  (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
    error.message.includes("incompatible"),
);

for (const [name] of versionFixtures) {
  const modulePath = resolve(dir, `${name}.mjs`);
  await assert.rejects(
    createFxAgent({ nativeAddon: pathToFileURL(modulePath), backend: "native", apiKey: "loader-key" }),
    (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
      error.message.includes("incompatible") &&
      !String(error.cause).includes("createCore invoked"),
    `${name} low-level addon must fail before createCore invocation`,
  );
}

await assert.rejects(
  createFxAgent({ nativeAddon: pathToFileURL(matchingVersionPath), backend: "native", apiKey: "loader-key" }),
  (error) => error?.code === "MATCHING_VERSION_INVOKED",
  "matching v3 low-level addon must reach createCore",
);

const addon = createRequire(import.meta.url)(realNativeAddon);
let failedCore;
let failedCoreDestroyed = false;
const brokenReaderAddon = {
  ...addon,
  createCore(options) { return failedCore = addon.createCore(options); },
  takeCoreReadyFd(core) {
    const fd = addon.takeCoreReadyFd(core);
    closeSync(fd);
    return fd;
  },
  destroyCore(core) {
    failedCoreDestroyed = true;
    return addon.destroyCore(core);
  },
};
try {
  await assert.rejects(createFxAgent({ backend: "native", nativeAddon: brokenReaderAddon, apiKey: "loader-key" }));
  assert.ok(failedCoreDestroyed, "failed readiness adoption must still destroy the native runtime");
} finally {
  if (failedCore) addon.destroyCore(failedCore);
}

console.log("libfx loader passed: browser exports, native preference, fallback diagnostics, semantic errors, strict low-level API validation, and failed-start cleanup");
