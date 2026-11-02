// Shared helpers for the Bun drivers under tests/tla/drivers/: find TLC and
// Java the same way tests/tla/lib/tlc.sh does, run TLC on a model in a
// scratch folder, and locate the fx binary under test.
//
// TLC comes from TLA2TOOLS_JAR or ~/.local/share/tla/tla2tools.jar. Java comes
// from JAVA_HOME, Homebrew's OpenJDK, or PATH. The binary is FX_BIN, or
// zig-out/bin/fx in this checkout. Output goes to FX_TLA_OUT, or a fresh folder
// under the system temp directory.
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const REPO_ROOT = resolve(import.meta.dirname, "../../../..");
export const TLA_ROOT = join(REPO_ROOT, "tests", "tla");

export function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function sha256Text(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

/// The fx binary under test. Throws when it has not been built.
export function fxBin(): string {
  const bin = process.env.FX_BIN ?? join(REPO_ROOT, "zig-out", "bin", "fx");
  if (!existsSync(bin)) throw new Error(`missing ${bin}; run zig build first or set FX_BIN`);
  return bin;
}

/// A new private output folder for one driver run, made by mkdtemp directly
/// in FX_TLA_OUT or the system temp folder, so another user cannot plant a
/// file or link where output will be written. The caller owns its contents.
export function outDir(name: string): string {
  const base = process.env.FX_TLA_OUT;
  if (base) mkdirSync(base, { recursive: true });
  return mkdtempSync(join(base ?? tmpdir(), `fx-tla-${name}-${utcStamp()}-`));
}

export type Toolchain = { java: string; javaVersion: string; jar: string; jarSha256: string };

let toolchain: Toolchain | null = null;

export function tlcToolchain(): Toolchain {
  if (toolchain) return toolchain;
  const jar = process.env.TLA2TOOLS_JAR ?? join(homedir(), ".local", "share", "tla", "tla2tools.jar");
  if (!existsSync(jar)) throw new Error(`tla2tools.jar not found at ${jar} (set TLA2TOOLS_JAR)`);
  const which = Bun.spawnSync(["sh", "-c", "command -v java"], { stdout: "pipe" });
  const candidates = [
    process.env.JAVA_HOME ? join(process.env.JAVA_HOME, "bin", "java") : "",
    "/opt/homebrew/opt/openjdk/bin/java",
    "/usr/local/opt/openjdk/bin/java",
    new TextDecoder().decode(which.stdout).trim(),
  ];
  for (const java of candidates) {
    if (!java || !existsSync(java)) continue;
    // /usr/bin/java on macOS is a stub that fails -version without a runtime.
    const probe = Bun.spawnSync([java, "-version"], { stdout: "pipe", stderr: "pipe" });
    if (probe.exitCode !== 0) continue;
    const javaVersion = new TextDecoder().decode(probe.stderr).split("\n")[0]?.trim() ?? "";
    toolchain = { java, javaVersion, jar, jarSha256: sha256File(jar) };
    return toolchain;
  }
  throw new Error("no working Java runtime (set JAVA_HOME or brew install openjdk)");
}

export type TlcRun = {
  exitCode: number;
  output: string;
  violated: string | null;
  distinctStates: number | null;
  depth: number | null;
  argv: string[];
  durationMs: number;
};

/// Runs TLC on `module` with `cfg` from `dir`, after copying `specs` from
/// `specDir` into it, so each run keeps the exact files it checked. TLC's
/// output is also written to `dir/tlc.log`.
export async function runTlc(
  dir: string,
  module: string,
  cfg: string,
  specs: string[],
  specDir: string,
  extraArgs: string[] = [],
): Promise<TlcRun> {
  const { java, jar } = tlcToolchain();
  mkdirSync(dir, { recursive: true });
  for (const name of specs) copyFileSync(join(specDir, name), join(dir, name));
  // A private java.io.tmpdir per run: TLC unpacks its standard modules there,
  // and concurrent runs sharing one folder can lose them.
  const javaTmp = join(dir, ".tlc-tmp");
  mkdirSync(javaTmp, { recursive: true });
  const argv = [
    java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${javaTmp}`, "-cp", jar, "tlc2.TLC",
    "-config", cfg, "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-cleanup", "-nowarning",
    ...extraArgs, module,
  ];
  const started = performance.now();
  const proc = Bun.spawn(argv, { cwd: dir, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const output = stdout + (stderr ? `\n[stderr]\n${stderr}` : "");
  writeFileSync(join(dir, "tlc.log"), output);
  const violated = /Error: (?:Invariant|Action property) (\w+) is violated/.exec(output)?.[1] ?? null;
  const distinct = /(\d+) distinct states found/.exec(output)?.[1];
  const depth = /The depth of the complete state graph search is (\d+)/.exec(output)?.[1];
  return {
    exitCode,
    output,
    violated,
    distinctStates: distinct ? Number(distinct) : null,
    depth: depth ? Number(depth) : null,
    argv,
    durationMs: Math.round(performance.now() - started),
  };
}

export function writeJson(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

export function utcStamp(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
}
