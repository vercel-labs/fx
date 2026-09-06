#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxTerminal, getBackendInfo } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const coreWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const termWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const temp = await mkdtemp(join(tmpdir(), "libfx-backend-info-"));
const missingAddon = join(temp, "missing.node");
const corruptAddon = join(temp, "corrupt.node");
const missingWasm = join(temp, "missing.wasm");
const corruptWasm = join(temp, "corrupt.wasm");
const replacedWasm = join(temp, "replaced.wasm");
const stableWasm = join(temp, "stable.wasm");
const dependencyAddon = join(temp, "dependency-addon.mjs");
const nonlocalAddon = new URL("file://other-host/tmp/addon.node");
await writeFile(corruptAddon, "not a native addon");
await writeFile(corruptWasm, "not WebAssembly");
await writeFile(replacedWasm, "not WebAssembly");
await writeFile(stableWasm, await readFile(coreWasm));
await writeFile(dependencyAddon, `
  import "./missing-dependency.mjs";
  export const libfxApiVersion = 3;
  export function createCore() { throw new Error("dependency addon factory invoked"); }
`);

const matchingCore = {
  libfxApiVersion: 3,
  createCore() { assert.fail("backend probing must not create a core"); },
};
const matchingTerminal = {
  libfxApiVersion: 2,
  createFxTerminal() { assert.fail("backend probing must not create a terminal"); },
};

try {
  for (const options of [null, [], 1, { surface: "browser" }, { backend: "other" }, { nativeAddon: true }]) {
    await assert.rejects(getBackendInfo(options), TypeError);
  }

  assert.deepEqual(await getBackendInfo({ backend: "native", nativeAddon: matchingCore }), {
    surface: "agent",
    backend: "native",
    attempts: [{ backend: "native", available: true, reason: null }],
  });

  assert.equal((await getBackendInfo({
    surface: "terminal",
    backend: "native",
    nativeAddon: matchingTerminal,
  })).backend, "native");

  assert.deepEqual(await getBackendInfo({ surface: "terminal", backend: "native", nativeAddon: matchingCore }), {
    surface: "terminal",
    backend: "unavailable",
    attempts: [{
      backend: "native",
      available: false,
      reason: {
        code: "LIBFX_NATIVE_SURFACE_MISSING",
        message: "native addon does not provide createFxTerminal()",
      },
    }],
  });

  const incompatible = await getBackendInfo({
    backend: "native",
    nativeAddon: { libfxApiVersion: 2, createCore() { assert.fail("must validate before calling createCore"); } },
  });
  assert.equal(incompatible.backend, "unavailable");
  assert.equal(incompatible.attempts[0].reason.code, "LIBFX_NATIVE_API_MISMATCH");
  assert.match(incompatible.attempts[0].reason.message, /expected API version 3/);

  const disabled = await getBackendInfo({ backend: "native", nativeAddon: false });
  assert.equal(disabled.backend, "unavailable");
  assert.equal(disabled.attempts[0].reason.code, "LIBFX_NATIVE_DISABLED");

  const missing = await getBackendInfo({ backend: "native", nativeAddon: missingAddon });
  assert.equal(missing.backend, "unavailable");
  assert.equal(missing.attempts[0].reason.code, "LIBFX_NATIVE_ARTIFACT_MISSING");
  assert.equal(missing.attempts[0].reason.causeCode, "MODULE_NOT_FOUND");
  await assert.rejects(
    createFxAgent({ backend: "native", nativeAddon: missingAddon, apiKey: "missing-override-key" }),
    (error) => error?.code === "MODULE_NOT_FOUND",
  );

  const dependencyFailure = await getBackendInfo({ backend: "native", nativeAddon: dependencyAddon });
  assert.equal(dependencyFailure.backend, "unavailable");
  assert.equal(dependencyFailure.attempts[0].reason.code, "LIBFX_NATIVE_LOAD_FAILED");
  assert.equal(dependencyFailure.attempts[0].reason.causeCode, "ERR_MODULE_NOT_FOUND");
  await assert.rejects(
    createFxAgent({ backend: "native", nativeAddon: dependencyAddon, apiKey: "dependency-override-key" }),
    (error) => error?.code === "ERR_MODULE_NOT_FOUND",
  );

  const defaultMissing = await getBackendInfo({ backend: "native" });
  assert.equal(defaultMissing.backend, "unavailable");
  assert.equal(defaultMissing.attempts[0].reason.code, "LIBFX_NATIVE_ARTIFACT_MISSING");
  assert.equal(defaultMissing.attempts[0].reason.causeCode, "ENOENT");
  await assert.rejects(
    createFxAgent({ backend: "native", apiKey: "missing-default-key" }),
    (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE",
  );
  await assert.rejects(
    createFxTerminal({ backend: "native" }),
    (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE",
  );

  const corrupt = await getBackendInfo({ backend: "native", nativeAddon: corruptAddon });
  assert.equal(corrupt.backend, "unavailable");
  assert.equal(corrupt.attempts[0].reason.code, "LIBFX_NATIVE_LOAD_FAILED");
  assert.equal(corrupt.attempts[0].reason.causeCode, "ERR_DLOPEN_FAILED");
  assert.doesNotThrow(() => JSON.stringify(corrupt));
  assert.equal(corrupt.attempts[0].reason instanceof Error, false);

  const nonlocal = await getBackendInfo({ backend: "native", nativeAddon: nonlocalAddon });
  assert.equal(nonlocal.backend, "unavailable");
  assert.equal(nonlocal.attempts[0].reason.code, "LIBFX_NATIVE_LOAD_FAILED");
  assert.equal(nonlocal.attempts[0].reason.causeCode, "ERR_INVALID_FILE_URL_HOST");
  await assert.rejects(
    createFxAgent({ backend: "native", nativeAddon: nonlocalAddon, apiKey: "nonlocal-key" }),
    (error) => error?.code === "ERR_INVALID_FILE_URL_HOST",
  );

  const savedSuspending = WebAssembly.Suspending;
  const savedPromising = WebAssembly.promising;
  try {
    Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: undefined });
    Object.defineProperty(WebAssembly, "promising", { configurable: true, value: undefined });
    assert.deepEqual(await getBackendInfo({ backend: "wasm" }), {
      surface: "agent",
      backend: "unavailable",
      attempts: [{
        backend: "wasm-jspi",
        available: false,
        reason: {
          code: "LIBFX_JSPI_UNAVAILABLE",
          message: "WebAssembly backend requires JavaScript Promise Integration (JSPI)",
        },
      }],
    });
    await assert.rejects(
      createFxAgent({ backend: "auto", nativeAddon: nonlocalAddon, apiKey: "nonlocal-key" }),
      (error) => error?.code === "LIBFX_JSPI_REQUIRED" && error.cause?.code === "ERR_INVALID_FILE_URL_HOST",
    );
  } finally {
    Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: savedSuspending });
    Object.defineProperty(WebAssembly, "promising", { configurable: true, value: savedPromising });
  }

  const nonlocalFallback = await createFxAgent({
    backend: "auto",
    nativeAddon: nonlocalAddon,
    wasm: coreWasm,
    apiKey: "nonlocal-fallback-key",
  });
  const nonlocalCheckpoint = await nonlocalFallback.checkpoint();
  await nonlocalFallback.close();
  assert.ok(nonlocalCheckpoint.length > 0, "auto mode must fall back after a nonlocal addon URL fails");

  const missingWasmInfo = await getBackendInfo({ backend: "wasm", wasm: missingWasm });
  assert.equal(missingWasmInfo.backend, "unavailable");
  assert.equal(missingWasmInfo.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");
  assert.equal(missingWasmInfo.attempts[0].reason.causeCode, "ENOENT");

  const corruptWasmInfo = await getBackendInfo({ backend: "wasm", wasm: corruptWasm });
  assert.equal(corruptWasmInfo.backend, "unavailable");
  assert.equal(corruptWasmInfo.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");

  const firstFileProbe = await getBackendInfo({ backend: "wasm", wasm: replacedWasm });
  assert.equal(firstFileProbe.backend, "unavailable");
  await writeFile(replacedWasm, await readFile(coreWasm));
  const secondFileProbe = await getBackendInfo({ backend: "wasm", wasm: replacedWasm });
  assert.equal(secondFileProbe.backend, "wasm-jspi", "replaced Wasm file must be read again after compile failure");
  const replacedAgent = await createFxAgent({ backend: "wasm", wasm: replacedWasm, apiKey: "probe-retry-key" });
  const replacedCheckpoint = await replacedAgent.checkpoint();
  await replacedAgent.close();
  assert.ok(replacedCheckpoint.length > 0, "factory must reuse the valid replacement after the failed probe");

  const stableCompileDescriptor = Object.getOwnPropertyDescriptor(WebAssembly, "compile");
  const stableRealCompile = WebAssembly.compile.bind(WebAssembly);
  let stableCompileCalls = 0;
  Object.defineProperty(WebAssembly, "compile", {
    ...stableCompileDescriptor,
    configurable: true,
    value: async (bytes) => {
      stableCompileCalls += 1;
      return stableRealCompile(bytes);
    },
  });
  try {
    assert.equal((await getBackendInfo({ backend: "wasm", wasm: stableWasm })).backend, "wasm-jspi");
    await assert.rejects(
      createFxAgent({
        backend: "wasm",
        wasm: stableWasm,
        apiKey: "stable-cache-key",
        checkpoint: new Uint8Array([1, 2, 3]),
      }),
      /Invalid or non-fresh libfx checkpoint/,
    );
    assert.equal((await getBackendInfo({ backend: "wasm", wasm: stableWasm })).backend, "wasm-jspi");
    const stableAgent = await createFxAgent({ backend: "wasm", wasm: stableWasm, apiKey: "stable-cache-key" });
    await stableAgent.close();
    assert.equal(stableCompileCalls, 1, "downstream factory errors must retain a successful compiled module");
  } finally {
    Object.defineProperty(WebAssembly, "compile", stableCompileDescriptor);
  }

  const automatic = await getBackendInfo({ backend: "auto", nativeAddon: false, wasm: coreWasm });
  assert.equal(automatic.backend, "wasm-jspi");
  assert.deepEqual(automatic.attempts.map(({ backend, available }) => ({ backend, available })), [
    { backend: "native", available: false },
    { backend: "wasm-jspi", available: true },
  ]);
  assert.equal(automatic.attempts[0].reason.code, "LIBFX_NATIVE_DISABLED");
  assert.equal(automatic.attempts[1].reason, null);

  const terminalWasm = await getBackendInfo({ surface: "terminal", backend: "wasm", wasm: termWasm });
  assert.equal(terminalWasm.surface, "terminal");
  assert.equal(terminalWasm.backend, "wasm-jspi");

  const remoteBytes = await readFile(coreWasm);
  const server = createServer((request, response) => {
    response.writeHead(200, { "content-type": "application/wasm" });
    response.end(remoteBytes);
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const remoteUrl = new URL(`http://127.0.0.1:${server.address().port}/fx-core.wasm`);
  try {
    const remote = await getBackendInfo({ backend: "wasm", wasm: remoteUrl });
    assert.equal(remote.backend, "wasm-jspi");
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
  }
  const networkFailure = await getBackendInfo({
    backend: "wasm",
    wasm: new URL("unavailable.wasm", remoteUrl),
  });
  assert.equal(networkFailure.backend, "unavailable");
  assert.equal(networkFailure.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");

  const compileDescriptor = Object.getOwnPropertyDescriptor(WebAssembly, "compile");
  const realCompile = WebAssembly.compile.bind(WebAssembly);
  const retryBytes = new Uint8Array(await readFile(coreWasm));
  let compileCalls = 0;
  Object.defineProperty(WebAssembly, "compile", {
    ...compileDescriptor,
    configurable: true,
    value: async (bytes) => {
      compileCalls += 1;
      if (compileCalls === 1) throw new Error("injected probe compilation failure");
      return realCompile(bytes);
    },
  });
  try {
    const first = await getBackendInfo({ backend: "wasm", wasm: retryBytes });
    assert.equal(first.backend, "unavailable");
    assert.equal(first.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");
    const second = await getBackendInfo({ backend: "wasm", wasm: retryBytes });
    assert.equal(second.backend, "wasm-jspi");
    assert.equal(compileCalls, 2, "failed compilation must be evicted so probing can retry");
  } finally {
    Object.defineProperty(WebAssembly, "compile", compileDescriptor);
  }

  console.log("backend info passed: side-effect-free selection, structured reasons, and retryable Wasm probes");
} finally {
  await rm(temp, { recursive: true, force: true });
}
