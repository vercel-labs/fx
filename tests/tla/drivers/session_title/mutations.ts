// Proves the session title checks are not vacuous. Each planted bug in
// mutations.json breaks one guard in the code, and the driver must reject at
// least one run of the binary built with it.
//
// For each mutation the checkout is copied to a scratch folder (without build
// output), the bug is planted by replacing one exact snippet, the copy is
// built, and driver.ts runs the mutation's surfaces against that binary
// (FX_BIN). A mutation is caught when the driver exits 1: some run the design
// model cannot produce.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/session_title/mutations.ts
//   bun tests/tla/drivers/session_title/mutations.ts no-reload history-gate
//
// Exit codes: 0 every mutation caught, 1 one survived, 2 a mutation did not
// apply or a build failed.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc";

type Mutation = { id: string; breaks: string; file: string; find: string; replace: string; only: string };

const mutations = JSON.parse(readFileSync(join(import.meta.dirname, "mutations.json"), "utf8")) as Mutation[];
const wanted = process.argv.slice(2);
const selected = wanted.length ? mutations.filter((mutation) => wanted.includes(mutation.id)) : mutations;

async function run(argv: string[], cwd: string, env: Record<string, string | undefined> = process.env): Promise<{ code: number; output: string }> {
  const proc = Bun.spawn(argv, { cwd, env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { code, output: stdout + stderr };
}

async function main(): Promise<number> {
  const out = outDir("session-title-mutations");
  console.log(`output: ${out}`);
  const results: Array<{ id: string; breaks: string; caught: boolean; detail: string }> = [];
  for (const mutation of selected) {
    const copy = join(out, mutation.id);
    const copied = await run([
      "rsync", "-a", "--exclude", ".zig-cache", "--exclude", "zig-out", "--exclude", "node_modules", "--exclude", ".git",
      `${REPO_ROOT}/`, `${copy}/`,
    ], REPO_ROOT);
    if (copied.code !== 0) {
      console.log(`ERROR ${mutation.id}: copy failed\n${copied.output}`);
      return 2;
    }
    const path = join(copy, mutation.file);
    const source = readFileSync(path, "utf8");
    const at = source.indexOf(mutation.find);
    if (at < 0 || source.indexOf(mutation.find, at + 1) >= 0) {
      console.log(`ERROR ${mutation.id}: the snippet must appear exactly once in ${mutation.file}`);
      return 2;
    }
    writeFileSync(path, source.slice(0, at) + mutation.replace + source.slice(at + mutation.find.length));
    const built = await run(["zig", "build"], copy);
    if (built.code !== 0) {
      console.log(`ERROR ${mutation.id}: build failed\n${built.output.slice(-4000)}`);
      return 2;
    }
    const driver = await run(
      ["bun", join(REPO_ROOT, "tests/tla/drivers/session_title/driver.ts"), "--only", mutation.only, "--jobs", "4"],
      REPO_ROOT,
      { ...process.env, FX_BIN: join(copy, "zig-out", "bin", "fx"), FX_TLA_OUT: join(out, `${mutation.id}-driver`) },
    );
    writeFileSync(join(out, `${mutation.id}-driver.log`), driver.output);
    const summary = /runs \d+: .*/.exec(driver.output)?.[0] ?? `driver exited ${driver.code}`;
    const caught = driver.code === 1;
    results.push({ id: mutation.id, breaks: mutation.breaks, caught, detail: summary });
    console.log(`${caught ? "caught  " : "SURVIVED"} ${mutation.id}: ${mutation.breaks} (${summary})`);
    if (driver.code === 2) {
      console.log(driver.output.slice(-4000));
      return 2;
    }
  }
  writeJson(join(out, "mutations.json"), results);
  return results.every((result) => result.caught) ? 0 : 1;
}

process.exit(await main().catch((error) => {
  console.error(error);
  return 2;
}));
