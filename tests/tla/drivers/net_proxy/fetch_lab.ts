// Builds and runs lab_fetch.zig, which calls web_fetch's real `http_fetch.fetch`
// with a resolver that admits two public addresses, behind a local proxy this
// file starts (tests/e2e/fixtures/net-proxy/proxy.ts). binary.ts has TLC check
// what a run showed against tests/tla/net_proxy/NetProxyCallers.tla.
//
// A run of the built fx cannot do this: web_fetch admits the addresses its host
// resolves to, so a host with two of them needs DNS. The lab swaps only the
// resolver; the dial, the CONNECT, the tunnel, the TLS start, and the sentence
// are the real ones.
//
// Everything is local: the proxy is on loopback and never forwards the public
// addresses CONNECT names, the one tunnel it opens leads to a loopback server that
// stays silent, the lab gets a temporary HOME and FX_HOME and an explicit
// environment with a single proxy variable, and FX_SOUND=0.
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startConnectProxy } from "../../../e2e/fixtures/net-proxy/proxy";
import { REPO_ROOT, TLA_ROOT } from "../lib/tlc";

/** What the proxy does, in the lab's two addresses: 93.184.216.34 first, then 93.184.216.35. */
export type LabScenario =
  /** Refuses the first address (502), opens a tunnel for the second, which stays silent. */
  | "two_addresses"
  /** Refuses both addresses (502). */
  | "both_refused"
  /** Answers CONNECT with bytes that are not HTTP. */
  | "not_http";

export type LabRound = { round: number; error: string | null; shown: string | null; ms: number };
export type LabRun = { rounds: LabRound[]; connects: string[]; code: number | null; stderr: string };

/** A copy of src/ outside the repository, where the lab is built and planted bugs go. */
export function copySource(root: string): string {
  const src = join(root, "src");
  cpSync(join(REPO_ROOT, "src"), src, { recursive: true });
  return src;
}

/** Builds the lab in a copy of src/ and returns its path; exits 2 when the build fails. */
export function buildFetchLab(src: string, root: string, name: string): string {
  writeFileSync(join(src, "_lab_fetch.zig"), readFileSync(join(TLA_ROOT, "drivers", "net_proxy", "lab_fetch.zig")));
  const bin = join(root, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", `-Mroot=${join(src, "_lab_fetch.zig")}`, "--name", name, `-femit-bin=${bin}`,
      "--cache-dir", join(root, ".zig-cache")],
    { cwd: root, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) {
    console.error(`building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
    process.exit(2);
  }
  return bin;
}

/** Plants `planted` in place of `target` in a file of the copy for one call of `use`, then puts the file back. */
export async function withPlantedBug<T>(src: string, file: string, target: string, planted: string, use: () => Promise<T>): Promise<T> {
  const path = join(src, file);
  const original = readFileSync(path, "utf8");
  if (original.split(target).length !== 2) {
    console.error(`self-check: the target ${JSON.stringify(target)} is not in ${file} exactly once`);
    process.exit(2);
  }
  writeFileSync(path, original.replace(target, planted));
  try {
    return await use();
  } finally {
    writeFileSync(path, original);
  }
}

/** The environment of the lab: one proxy variable and nothing that reaches past the machine. */
function labEnvironment(home: string, proxyUrl: string): Record<string, string> {
  return {
    HOME: home,
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    TMPDIR: process.env.TMPDIR ?? "/tmp",
    FX_HOME: join(home, ".fx"),
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    HTTPS_PROXY: proxyUrl,
  };
}

/** Runs the lab for `rounds` fetches of `deadlineMs` each, with `openFiles` open files allowed. */
export async function runFetchLab(bin: string, scenario: LabScenario, rounds: number, deadlineMs: number, openFiles: number): Promise<LabRun> {
  // The second address's tunnel leads here: a server that takes a connection and never speaks.
  const sockets = new Set<net.Socket>();
  const silent = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => socket.destroy());
  });
  await new Promise<void>(resolve => silent.listen(0, "127.0.0.1", resolve));
  const silentPort = (silent.address() as net.AddressInfo).port;
  const proxy = await startConnectProxy(
    scenario === "two_addresses" ? { routes: { "93.184.216.35:443": silentPort } }
      : scenario === "both_refused" ? { status: 502 }
      : { garbage: true },
  );
  try {
    const home = mkdtempSync(join(tmpdir(), "fx-net-proxy-fetch-lab-"));
    const child = Bun.spawn([bin, String(rounds), String(deadlineMs), String(openFiles)], {
      cwd: home, env: labEnvironment(home, proxy.url()), stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(), rounds * (deadlineMs + 1500) + 30_000);
    const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    const code = await child.exited;
    clearTimeout(timer);
    const parsed: LabRound[] = [];
    for (const line of stdout.split("\n")) if (line.trim()) parsed.push(JSON.parse(line));
    return { rounds: parsed, connects: proxy.log.map(entry => entry.requestLine), code: child.signalCode ? null : code, stderr: stderr.slice(-300) };
  } finally {
    proxy.close();
    for (const socket of sockets) socket.destroy();
    silent.close();
  }
}
