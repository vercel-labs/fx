#!/usr/bin/env node
// Checks the sizes of the packages libfx publishes against
// package-size-budgets.json. The budgets start about 10% above the sizes they
// were set at; raise one only for a change that has to grow the package, and
// say so in the change.
//
// It also checks how each native addon was compiled (addNapiArtifact in
// build.zig): each one leaves out unwind tables, which a budget's headroom
// would not catch, and keeps frame pointers, which Apple's ABI requires.
//
// It also checks that each native addon leaves out fx's built-in tools, which
// libfx agents never run (builtin_tools in build.zig). Their code would add
// about 0.8 MB to an addon, less than a budget's headroom.
//
//   node sdk/tests/test-package-size.mjs <libfx.tgz> --native-dir <dir> [--print]
//
// --print prints the measured sizes as budgets JSON instead of checking them.
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { nativeDirArgument, nativeTarballs } from "./native-package.mjs";

const tarball = resolve(process.argv[2] ?? "");
const nativeDir = nativeDirArgument();
assert.ok(nativeDir, "usage: test-package-size.mjs <libfx.tgz> --native-dir <dir> [--print]");
const budgets = JSON.parse(await readFile(new URL("./package-size-budgets.json", import.meta.url), "utf8"));

async function unpackedBytes(dir) {
  let total = 0;
  for (const entry of await readdir(dir, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) total += (await stat(join(entry.parentPath, entry.name))).size;
  }
  return total;
}

// The package as npm would unpack it, measured from the tarball itself.
async function measurePackage(path) {
  const dir = await mkdtemp(resolve(tmpdir(), "libfx-size-"));
  const untar = spawnSync("tar", ["-xzf", path, "-C", dir, "--strip-components=1"]);
  assert.equal(untar.status, 0, String(untar.stderr));
  return { dir, packed: (await stat(path)).size, unpacked: await unpackedBytes(dir) };
}

const measured = {};
const libfx = await measurePackage(tarball);
try {
  measured.libfx = { packed: libfx.packed, unpacked: libfx.unpacked };
  // The .wasm files as a deployment carries them, and the JavaScript every
  // agent loads, compressed as a browser downloads it.
  for (const file of ["fx-core.wasm", "fx-term.wasm"]) measured[file] = { bytes: (await stat(join(libfx.dir, file))).size };
  for (const file of ["engine.js", "wasm-runtime.js", "fx-sdk.js"]) {
    measured[file] = { gzip: gzipSync(await readFile(join(libfx.dir, file)), { level: 9 }).length };
  }
} finally {
  await rm(libfx.dir, { recursive: true, force: true });
}
// Functions that point the frame pointer at their frame record: on arm64,
// `add x29, sp, #imm` (or `mov x29, sp`); on x86-64, `push rbp; mov rbp, rsp`.
// An addon built with frame pointers has about 5,000, and one built without
// them a few hundred at most.
function frameRecordSetups(addon, packageName) {
  let count = 0;
  if (packageName.includes("arm64")) {
    for (let i = 0; i + 4 <= addon.length; i += 4) if (((addon.readUInt32LE(i) & 0xffc003ff) >>> 0) === 0x910003fd) count++;
  } else {
    const setup = Buffer.from([0x55, 0x48, 0x89, 0xe5]);
    for (let i = addon.indexOf(setup); i !== -1; i = addon.indexOf(setup, i + 1)) count++;
  }
  return count;
}
const miscompiled = [];
// Descriptions of three built-in tools. Each must still be in fx's source, so
// the check can't pass only because a description was reworded.
const toolSource = await readFile(new URL("../../src/builtins/tools.zig", import.meta.url), "utf8");
const toolDescriptions = [
  "Fetch a public http(s) URL the user named and return its text",
  "Run a shell command. Each call starts a new shell",
  "Read more of a truncated tool result by its handle",
];
for (const text of toolDescriptions) {
  assert.ok(toolSource.includes(text), `src/builtins/tools.zig no longer contains "${text}"; use another built-in tool's description`);
}
const withTools = [];
for (const [name, path] of Object.entries(nativeTarballs(nativeDir))) {
  const platform = await measurePackage(path);
  measured[name] = { packed: platform.packed, unpacked: platform.unpacked };
  const addon = await readFile(join(platform.dir, "libfx.node"));
  // .eh_frame on Linux, __eh_frame and __unwind_info on macOS.
  for (const section of ["eh_frame", "__unwind_info"]) if (addon.includes(section)) miscompiled.push(`${name}: has ${section}`);
  const frames = frameRecordSetups(addon, name);
  if (frames < 1000) miscompiled.push(`${name}: only ${frames} functions set up a frame record`);
  for (const text of toolDescriptions) if (addon.includes(text)) withTools.push(`${name}: "${text}"`);
  await rm(platform.dir, { recursive: true, force: true });
}
assert.deepEqual(miscompiled, [], `a native addon was built with the wrong code generation settings; see addNapiArtifact in build.zig:\n${miscompiled.join("\n")}`);
assert.deepEqual(withTools, [], `a native addon contains fx's built-in tools; build it with builtin_tools false:\n${withTools.join("\n")}`);

if (process.argv.includes("--print")) {
  console.log(JSON.stringify(measured, null, 2));
  process.exit(0);
}

const over = [];
for (const [name, sizes] of Object.entries(measured)) {
  const budget = budgets[name];
  assert.ok(budget, `package-size-budgets.json has no budget for ${name}`);
  for (const [metric, bytes] of Object.entries(sizes)) {
    assert.ok(budget[metric], `package-size-budgets.json has no ${metric} budget for ${name}`);
    const line = `${name} ${metric}: ${bytes} of ${budget[metric]} bytes (${Math.round(100 * bytes / budget[metric])}%)`;
    console.log(line);
    if (bytes > budget[metric]) over.push(line);
  }
}
assert.deepEqual(over, [], `over budget. A .wasm over its budget may have skipped sdk/scripts/optimize-wasm.mjs:\n${over.join("\n")}`);
console.log(`Package sizes passed: ${Object.keys(measured).length} files and packages within their budgets, every native addon has the expected code generation settings, and none contains fx's built-in tools`);
