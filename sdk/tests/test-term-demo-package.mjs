#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "fx-term-demo-package-"));
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const immutable = [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }];

try {
  const result = spawnSync(process.execPath, [
    resolve(repoRoot, "sdk/scripts/package-term-demo.mjs"),
    temp,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);

  const manifest = JSON.parse(await readFile(join(temp, "manifest.json"), "utf8"));
  const vercel = JSON.parse(await readFile(join(temp, "vercel.json"), "utf8"));
  const html = await readFile(join(temp, "index.html"), "utf8");
  assert.match(html, new RegExp(`from "\\./${manifest.browser.file.replaceAll(".", "\\.")}";`));

  // The page loads browser.js and everything it imports, and nothing else.
  // browser.js imports the engine and the WebAssembly host itself, not the
  // libfx/wasm entry.
  const names = Object.keys(manifest.modules);
  for (const name of ["browser.js", "browser-agent.js", "browser-terminal.js", "engine.js", "xterm.js", "wasm-runtime.js", "wasm-terminal.js", "wasm-module.js", "core-output.js", "tool-observation.js", "durable.js", "fx-harness.js"]) {
    assert.ok(names.includes(name), `the demo package must carry ${name}`);
  }
  assert.ok(!names.includes("fx-sdk.js"), "the demo package must not carry fx-sdk.js");
  const packagedFiles = new Set(Object.values(manifest.modules).map(({ file }) => file));
  const written = (await readdir(temp)).filter((file) => file.endsWith(".js"));
  assert.deepEqual(written.sort(), [...packagedFiles].sort());
  for (const [name, { file, sha256, bytes }] of Object.entries(manifest.modules)) {
    assert.match(file, new RegExp(`^${name.slice(0, -3)}\\.[0-9a-f]{64}\\.js$`));
    const contents = await readFile(join(temp, file));
    assert.equal(digest(contents), sha256, `${file} digest`);
    assert.equal(contents.byteLength, bytes, `${file} size`);
    assert.equal(file, `${name.slice(0, -3)}.${sha256}.js`, `${file} is named by its content`);
    assert.deepEqual(vercel.headers.find(({ source }) => source === `/${file}`)?.headers, immutable, `${file} cache policy`);
    for (const [, specifier] of contents.toString().matchAll(/(?:\bfrom\s*|\bimport\s*\(\s*)"(\.\/[^"]+)"/g)) {
      assert.match(specifier, /^\.\/[a-z0-9-]+\.[0-9a-f]{64}\.js$/, `${file} imports an unhashed ${specifier}`);
      assert.ok(existsSync(join(temp, specifier)), `${file} imports ${specifier}, which the package lacks`);
    }
  }
  for (const key of ["browser", "terminal", "coreOutput", "wasmModule", "toolObservation"]) {
    assert.ok(packagedFiles.has(manifest[key].file), `manifest.${key} names a packaged module`);
  }
  const wasm = await readFile(join(temp, manifest.wasm.file));
  assert.equal(digest(wasm), manifest.wasm.sha256);
  assert.deepEqual(vercel.headers.find(({ source }) => source === `/${manifest.wasm.file}`)?.headers, immutable);
  for (const source of ["/", "/index.html"]) {
    assert.deepEqual(vercel.headers.find((header) => header.source === source)?.headers, [{ key: "Cache-Control", value: "public, max-age=0, must-revalidate" }]);
  }
  console.log(`terminal demo package passed: ${names.length} modules are hashed, complete, rewritten, and immutable`);
} finally {
  await rm(temp, { recursive: true, force: true });
}
