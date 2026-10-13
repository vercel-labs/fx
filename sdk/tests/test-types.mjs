#!/usr/bin/env node
// Type-checks libfx's hand-written declarations in sdk/types the way a
// consumer resolves them: through the package's `exports`, under node16 and
// bundler module resolution, against the fixtures in sdk/tests/types. Then
// checks that every entry point declares exactly the values it exports at
// runtime, and that each specifier resolves to its declaration file.
//
// TypeScript comes from sdk/node's pinned devDependency, or from TSC, the path
// to a `typescript/bin/tsc`:
//
//   node sdk/tests/test-types.mjs
//   TSC=/path/to/node_modules/typescript/bin/tsc node sdk/tests/test-types.mjs
//
// The fixtures for Workflow's real World types and a real xterm terminal run
// when sdk/durable and sdk/node have their dependencies installed, and the
// Node.js-only lib check runs when `@types/node` sits beside TypeScript or
// TYPES_NODE names its directory. Set LIBFX_KEEP_TYPES_DIR=1 to keep the
// temporary project.
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const sdkDir = fileURLToPath(new URL("..", import.meta.url));
const fixturesDir = fileURLToPath(new URL("./types/", import.meta.url));

// fx-sdk.js exports these for libfx's own modules; they are not public API.
const wasmInternals = new Set(["coreAnswered", "engineInternals", "journalMarksWanted", "normalizeAgentOptions", "normalizeInstructions", "normalizeModelChoice"]);

// Each specifier as a consumer resolves it, the declaration file it must
// reach, and the module whose runtime exports that file must match. node.cjs
// is built from node.js (sdk/scripts/build-node-cjs.mjs), so the `require`
// entry is checked against node.js.
const entries = [
  { specifier: "libfx", resolution: "node16", mode: "import", types: "types/node.d.ts", runtime: "node.js" },
  { specifier: "libfx", resolution: "node16", mode: "require", types: "types/node.d.cts", runtime: "node.js" },
  { specifier: "libfx", resolution: "bundler", conditions: ["node"], types: "types/node.d.ts", runtime: "node.js" },
  { specifier: "libfx", resolution: "bundler", conditions: [], types: "types/browser.d.ts", runtime: "browser.js" },
  { specifier: "libfx/node", resolution: "node16", mode: "import", types: "types/node.d.ts", runtime: "node.js" },
  { specifier: "libfx/node", resolution: "node16", mode: "require", types: "types/node.d.cts", runtime: "node.js" },
  { specifier: "libfx/browser", resolution: "node16", mode: "import", types: "types/browser.d.ts", runtime: "browser.js" },
  { specifier: "libfx/wasm", resolution: "node16", mode: "import", types: "types/wasm.d.ts", runtime: "fx-sdk.js", hidden: wasmInternals },
  { specifier: "libfx/durable-local", resolution: "node16", mode: "import", types: "types/durable-local.d.ts", runtime: "durable/local.mjs" },
  { specifier: "libfx/durable-vercel", resolution: "node16", mode: "import", types: "types/durable-vercel.d.ts", runtime: "durable/vercel.mjs" },
  { specifier: "libfx/durable-world", resolution: "node16", mode: "import", types: "types/durable-world.d.ts", runtime: "durable/world.mjs" },
  { specifier: "libfx/chatgpt", resolution: "node16", mode: "import", types: "types/chatgpt.d.ts", runtime: "chatgpt-sign-in.js" },
  { specifier: "libfx/grok", resolution: "node16", mode: "import", types: "types/grok.d.ts", runtime: "grok-sign-in.js" },
  { specifier: "libfx/mcp", resolution: "node16", mode: "import", types: "types/mcp.d.ts", runtime: "mcp.js" },
  { specifier: "libfx/skills", resolution: "node16", mode: "import", types: "types/skills.d.ts", runtime: "skills.js" },
  { specifier: "libfx/skills/node", resolution: "node16", mode: "import", types: "types/skills-node.d.ts", runtime: "skills-node.js" },
];

const nodeFixtures = ["agent.mts", "engine.mts", "adapters.mts"];
const failures = [];
const fail = (message) => {
  failures.push(message);
  console.log(`  FAIL ${message}`);
};

// TypeScript.
const tsc = process.env.TSC ? resolve(process.env.TSC) : join(sdkDir, "node/node_modules/typescript/bin/tsc");
const tsLib = join(dirname(tsc), "../lib/typescript.js");
if (!existsSync(tsc) || !existsSync(tsLib)) {
  console.error(`TypeScript was not found at ${tsc}.`);
  console.error("Install sdk/node's pinned devDependency with `npm ci --prefix sdk/node`, or set TSC to the path of a typescript/bin/tsc.");
  process.exit(1);
}
const ts = createRequire(import.meta.url)(tsLib);
console.log(`TypeScript ${ts.version} (${tsc})`);

// A consumer project whose node_modules/libfx is the sdk directory.
const temp = mkdtempSync(join(tmpdir(), "libfx-types-"));
const srcDir = join(temp, "src");
const modulesDir = join(temp, "node_modules");
mkdirSync(srcDir, { recursive: true });
mkdirSync(modulesDir, { recursive: true });
writeFileSync(join(temp, "package.json"), `${JSON.stringify({ private: true, type: "module" }, null, 2)}\n`);

symlinkSync(sdkDir, join(modulesDir, "libfx"), "dir");

for (const name of readdirSync(fixturesDir)) copyFileSync(join(fixturesDir, name), join(srcDir, name));

// Optional real-library fixtures.
const workflowDir = join(sdkDir, "durable/node_modules/@workflow");
const xtermDir = join(sdkDir, "node/node_modules/@xterm");
const realFixtures = [];
if (["world", "world-local", "world-vercel"].every((name) => existsSync(join(workflowDir, name)))) {
  symlinkSync(workflowDir, join(modulesDir, "@workflow"), "dir");
  realFixtures.push("real-world.mts");
}
if (existsSync(join(xtermDir, "headless"))) {
  symlinkSync(xtermDir, join(modulesDir, "@xterm"), "dir");
  realFixtures.push("real-xterm.mts");
}
const typesNode = process.env.TYPES_NODE ? resolve(process.env.TYPES_NODE) : join(dirname(tsc), "../../@types/node");

// tsc runs.
const strictest = { exactOptionalPropertyTypes: true, noUncheckedIndexedAccess: true, noImplicitOverride: true };
const runs = [
  {
    name: "node16",
    summary: "module node16, strict + exactOptionalPropertyTypes + noUncheckedIndexedAccess, lib es2022 + dom",
    options: { module: "node16", moduleResolution: "node16", ...strictest },
    files: [...nodeFixtures, "browser.mts", "require.cts"],
  },
  {
    name: "bundler-node",
    summary: "moduleResolution bundler, customConditions [\"node\"], strict, lib es2022 + dom",
    options: { module: "esnext", moduleResolution: "bundler", customConditions: ["node"] },
    files: [...nodeFixtures, "browser.mts"],
  },
  {
    name: "bundler",
    summary: "moduleResolution bundler, no custom conditions (the \"default\" condition), strict, lib es2022 + dom",
    options: { module: "esnext", moduleResolution: "bundler" },
    files: ["bundler-default.ts", "browser.mts"],
  },
];
if (existsSync(join(typesNode, "package.json"))) {
  runs.push({
    name: "node16-types-node",
    summary: `module node16, strict, lib es2022 without dom, @types/node ${JSON.parse(readFileSync(join(typesNode, "package.json"), "utf8")).version}`,
    options: { module: "node16", moduleResolution: "node16", lib: ["es2022"], typeRoots: [dirname(typesNode)], types: ["node"] },
    files: [...nodeFixtures, "require.cts"],
  });
} else {
  console.log(`skip node16-types-node: no @types/node at ${typesNode}`);
}
if (realFixtures.length) {
  runs.push({
    name: "node16-real-libraries",
    summary: "module node16, strict, skipLibCheck for the libraries' own declarations",
    options: { module: "node16", moduleResolution: "node16", skipLibCheck: true },
    files: realFixtures,
  });
} else {
  console.log("skip node16-real-libraries: neither sdk/durable nor sdk/node has its dependencies installed");
}

console.log("\ntsc --noEmit --strict");
for (const run of runs) {
  const config = {
    compilerOptions: {
      noEmit: true,
      strict: true,
      skipLibCheck: false,
      target: "es2022",
      lib: ["es2022", "dom"],
      types: [],
      ...run.options,
    },
    files: run.files.map((name) => `./src/${name}`),
  };
  const configPath = join(temp, `tsconfig.${run.name}.json`);
  writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
  const result = spawnSync(process.execPath, [tsc, "-p", configPath, "--pretty", "false"], { cwd: temp, encoding: "utf8" });
  const output = `${result.stdout}${result.stderr}`.trim();
  if (result.status === 0) {
    console.log(`  pass ${run.name}: ${run.files.join(", ")}`);
    console.log(`       ${run.summary}`);
  } else {
    fail(`${run.name} (exit ${result.status ?? result.signal}): ${run.summary}`);
    for (const line of output.split("\n")) console.log(`       ${line.replaceAll(temp, "<project>")}`);
  }
}

// Each specifier must reach its declaration file through the package's exports.
console.log("\nresolution");
const resolutionOptions = (entry) => entry.resolution === "node16"
  ? { module: ts.ModuleKind.Node16, moduleResolution: ts.ModuleResolutionKind.Node16 }
  : { module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, customConditions: entry.conditions };
for (const entry of entries) {
  const label = entryLabel(entry);
  const containing = join(srcDir, entry.mode === "require" ? "probe.cts" : "probe.mts");
  const mode = entry.resolution === "node16" ? (entry.mode === "require" ? ts.ModuleKind.CommonJS : ts.ModuleKind.ESNext) : undefined;
  const resolved = ts.resolveModuleName(entry.specifier, containing, resolutionOptions(entry), ts.sys, undefined, undefined, mode).resolvedModule;
  const expected = realpathSync(join(sdkDir, entry.types));
  const actual = resolved ? realpathSync(resolved.resolvedFileName) : null;
  if (actual === expected) console.log(`  ok   ${label} -> ${entry.types}`);
  else fail(`${label} resolved to ${actual ? relative(sdkDir, actual) : "nothing"}, expected ${entry.types}`);
}

// Each declaration file must declare exactly its runtime module's values.
console.log("\ndrift (declared values vs runtime exports)");
const declarationFiles = [...new Set(entries.map((entry) => realpathSync(join(sdkDir, entry.types))))];
const program = ts.createProgram(declarationFiles, {
  module: ts.ModuleKind.Node16,
  moduleResolution: ts.ModuleResolutionKind.Node16,
  target: ts.ScriptTarget.ES2022,
  lib: ["lib.es2022.d.ts", "lib.dom.d.ts"],
  types: [],
  noEmit: true,
});
const checker = program.getTypeChecker();
const checked = new Set();
for (const entry of entries) {
  const key = `${entry.types}\0${entry.runtime}`;
  if (checked.has(key)) continue;
  checked.add(key);
  const label = `${entry.types} vs ${entry.runtime}`;
  let runtime;
  try {
    runtime = Object.keys(await import(pathToFileURL(join(sdkDir, entry.runtime)).href)).filter((name) => !entry.hidden?.has(name)).sort();
  } catch (error) {
    fail(`${label}: could not import ${entry.runtime}: ${error?.message ?? error}${entry.runtime.startsWith("durable/") ? " (run `npm ci --prefix sdk/durable`)" : ""}`);
    continue;
  }
  const declared = declaredValues(realpathSync(join(sdkDir, entry.types)));
  const missing = runtime.filter((name) => !declared.includes(name));
  const extra = declared.filter((name) => !runtime.includes(name));
  if (missing.length === 0 && extra.length === 0) {
    console.log(`  ok   ${label}: ${runtime.length} values match${entry.hidden ? ` (internal, not declared: ${[...entry.hidden].sort().join(", ")})` : ""}`);
    console.log(`       ${runtime.join(", ")}`);
  } else {
    fail(`${label}:${missing.length ? ` exported but not declared: ${missing.join(", ")};` : ""}${extra.length ? ` declared but not exported: ${extra.join(", ")}` : ""}`);
  }
}

if (failures.length === 0 && !process.env.LIBFX_KEEP_TYPES_DIR) rmSync(temp, { recursive: true, force: true });
else console.log(`\nproject kept at ${temp}`);
console.log(failures.length ? `\n${failures.length} check(s) failed` : "\nall type checks passed");
// The durability modules load Workflow's Worlds, which may hold handles open.
process.exit(failures.length ? 1 : 0);

function entryLabel(entry) {
  const how = entry.resolution === "node16" ? `node16 ${entry.mode}` : `bundler${entry.conditions.length ? ` +${entry.conditions.join(",")}` : ""}`;
  return `${entry.specifier} (${how})`;
}

// The value exports of a declaration file, through re-exports, without the
// names re-exported only as types.
function declaredValues(file) {
  const source = program.getSourceFile(file);
  const moduleSymbol = source && checker.getSymbolAtLocation(source);
  if (!moduleSymbol) throw new Error(`${file} is not a module`);
  const names = [];
  for (const symbol of checker.getExportsOfModule(moduleSymbol)) {
    let current = symbol;
    let typeOnly = false;
    for (let depth = 0; current.flags & ts.SymbolFlags.Alias && depth < 32; depth += 1) {
      if (current.declarations?.some(isTypeOnlyDeclaration)) {
        typeOnly = true;
        break;
      }
      const next = checker.getImmediateAliasedSymbol(current);
      if (!next || next === current) break;
      current = next;
    }
    if (!typeOnly && (current.flags & ts.SymbolFlags.Value) !== 0) names.push(symbol.name);
  }
  return names.sort();
}

function isTypeOnlyDeclaration(declaration) {
  if (ts.isExportSpecifier(declaration) || ts.isImportSpecifier(declaration)) {
    return declaration.isTypeOnly || declaration.parent.parent.isTypeOnly;
  }
  if (ts.isImportClause(declaration) || ts.isImportEqualsDeclaration(declaration)) return declaration.isTypeOnly;
  if (ts.isNamespaceImport(declaration)) return declaration.parent.isTypeOnly;
  return false;
}
