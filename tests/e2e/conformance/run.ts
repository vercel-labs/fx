import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const protocolVersion = "2026-07-28";
const runnerVersion = "0.2.0-alpha.10";
const runnerRevision = "a9896553900a2ef61787b57adfcbbe936a8ab1f9";
const packageRoot = import.meta.dirname;
const runnerRoot = join(
  packageRoot,
  "node_modules",
  "@modelcontextprotocol",
  "conformance",
);
const installedPackage = JSON.parse(
  readFileSync(join(runnerRoot, "package.json"), "utf8"),
) as { version?: string };
if (installedPackage.version !== runnerVersion) {
  throw new Error(
    `expected @modelcontextprotocol/conformance ${runnerVersion}, found ${installedPackage.version ?? "unknown"}`,
  );
}

const runner = join(runnerRoot, "dist", "index.js");
const client = resolve(packageRoot, "client.ts");
const baseline = resolve(packageRoot, "expected-failures.yml");
const fxBin = resolve(packageRoot, "../../../zig-out/bin/fx");
if (!existsSync(fxBin)) {
  throw new Error(
    `missing freshly built fx binary at ${fxBin}; run FX_SOUND=0 zig build from the repository root`,
  );
}
const resultRoot = mkdtempSync(join(tmpdir(), "fx-mcp-conformance-results-"));
console.log(
  `MCP conformance ${protocolVersion}, runner ${runnerVersion} (${runnerRevision})`,
);

try {
  const modernExitCode = await runClient([
    "--suite",
    "all",
    "--spec-version",
    protocolVersion,
    "--expected-failures",
    baseline,
  ]);
  if (modernExitCode !== 0) {
    process.exitCode = modernExitCode;
  } else {
    for (const scenario of ["initialize", "tools_call", "sse-retry"]) {
      console.log(`MCP conformance 2025-11-25: ${scenario}`);
      const exitCode = await runClient([
        "--scenario",
        scenario,
        "--spec-version",
        "2025-11-25",
      ]);
      if (exitCode !== 0) {
        process.exitCode = exitCode;
        break;
      }
    }
  }
} finally {
  rmSync(resultRoot, { recursive: true, force: true });
}

async function runClient(args: string[]): Promise<number> {
  const child = Bun.spawn(
    [
      "node",
      runner,
      "client",
      "--command",
      `bun ${JSON.stringify(client)}`,
      ...args,
      "--timeout",
      "30000",
    ],
    {
      cwd: resultRoot,
      stdout: "inherit",
      stderr: "inherit",
    },
  );
  return child.exited;
}
