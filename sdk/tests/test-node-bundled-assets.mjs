#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { cp, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxAgent, getBackendInfo } from "../node.js";

const root = await mkdtemp(join(tmpdir(), "libfx bundled assets "));
const media = join(root, "static", "media");
const originalBase = Object.getOwnPropertyDescriptor(globalThis, "__webpack_base_uri__");
const originalPublicPath = Object.getOwnPropertyDescriptor(globalThis, "__webpack_public_path__");

// Match webpack's RelativeUrlRuntimeModule, including its misleading prototype.
function relativeUrl(href) {
  return Object.create(URL.prototype, {
    href: { value: href },
    pathname: { value: href.replace(/[?#].*/, "") },
    protocol: { value: "" },
    origin: { value: "" },
  });
}

try {
  await mkdir(media, { recursive: true });
  const nativeName = `libfx.${process.platform}-${process.arch}.fixture.node`;
  await cp(new URL("../../zig-out/lib/libfx.node", import.meta.url), join(media, nativeName));
  for (const surface of ["core", "term"]) {
    await cp(new URL(`../../zig-out/bin/fx-${surface}.wasm`, import.meta.url), join(media, `fx-${surface}.fixture.wasm`));
  }
  globalThis.__webpack_base_uri__ = pathToFileURL(`${root}/`).href;
  for (const publicPath of ["/_next/", "https://cdn.example.test/assets/"]) {
    globalThis.__webpack_public_path__ = publicPath;
    const nativeAddon = relativeUrl(`${publicPath}static/media/${nativeName}`);
    assert.ok(nativeAddon instanceof URL);
    assert.throws(() => fileURLToPath(nativeAddon), { code: "ERR_INVALID_ARG_TYPE" });
    assert.equal((await getBackendInfo({ backend: "native", nativeAddon })).backend, "native");
    const agent = await createFxAgent({ backend: "native", nativeAddon, apiKey: "fixture-key" });
    try { assert.ok((await agent.checkpoint()).length > 48); }
    finally { await agent.close(); }
    for (const [surface, artifact] of [["agent", "core"], ["terminal", "term"]]) {
      const wasm = relativeUrl(`${publicPath}static/media/fx-${artifact}.fixture.wasm`);
      const info = await getBackendInfo({ backend: "wasm", surface, wasm });
      assert.equal(info.backend, "wasm-jspi", JSON.stringify(info));
    }
    const missing = await getBackendInfo({ backend: "native", nativeAddon: relativeUrl(`${publicPath}static/media/missing.node`) });
    assert.equal(missing.attempts[0].reason.code, "LIBFX_NATIVE_ARTIFACT_MISSING");
  }
  const path = join(media, nativeName);
  for (const nativeAddon of [path, pathToFileURL(path)]) {
    assert.equal((await getBackendInfo({ backend: "native", nativeAddon })).backend, "native");
  }
  const unmapped = await getBackendInfo({ backend: "native", nativeAddon: relativeUrl("/different/asset.node") });
  assert.equal(unmapped.backend, "unavailable");
  assert.equal(unmapped.attempts[0].reason.code, "LIBFX_NATIVE_LOAD_FAILED");
  delete globalThis.__webpack_base_uri__;
  const unavailable = await getBackendInfo({ backend: "native", nativeAddon: relativeUrl("https://cdn.example.test/assets/static/media/asset.node") });
  assert.equal(unavailable.backend, "unavailable");
} finally {
  for (const [name, descriptor] of [["__webpack_base_uri__", originalBase], ["__webpack_public_path__", originalPublicPath]]) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete globalThis[name];
  }
  await rm(root, { recursive: true, force: true });
}
console.log("Bundled assets passed: webpack URLs, native startup, core and terminal Wasm, public prefixes, missing files, and ordinary Node paths");
