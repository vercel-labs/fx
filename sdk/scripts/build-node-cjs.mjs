#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const output = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/libfx/node.cjs"));
mkdirSync(dirname(output), { recursive: true });
const result = spawnSync(process.env.BUN_BIN || "bun", [
  "build",
  resolve(repoRoot, "sdk/node.js"),
  "--target=node",
  "--format=cjs",
  "--external=*.node",
  "--define",
  "import.meta.url=__libfxModuleUrl",
  "--banner",
  'var __libfxModuleUrl = require("node:url").pathToFileURL(__filename).href;',
  "--outfile",
  output,
], {
  cwd: repoRoot,
  stdio: "inherit",
});

if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);

// Bun drops comments, and with them the hints in node.js that tell webpack
// and Turbopack to leave its run-time imports to Node (PKG-10). Every
// `import()` in the CommonJS entry is one of those.
const built = readFileSync(output, "utf8");
const imports = built.match(/\bimport\(/g)?.length ?? 0;
const hints = readFileSync(resolve(repoRoot, "sdk/node.js"), "utf8").match(/import\(\/\* webpackIgnore: true \*\/ \/\* turbopackIgnore: true \*\//g)?.length ?? 0;
if (hints === 0 || imports < hints) throw new Error(`node.cjs has ${imports} import() calls for the ${hints} hinted ones in node.js; check the build`);
// Bun replaces `process.env.NODE_ENV` with the mode it builds in. A build
// that fixed it would make every process that loads node.cjs a development
// server, where a new agent replaces another of its name (SEC-2), so the
// entry must still read it when it runs.
if (!/\.NODE_ENV === "development"/.test(built)) throw new Error("node.cjs no longer reads NODE_ENV when it runs; check `development` in node.js");
writeFileSync(output, built.replace(/\bimport\(/g, "import(/* webpackIgnore: true */ /* turbopackIgnore: true */ "));
console.log(`built CommonJS Node entry in ${output}`);
