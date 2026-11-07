// A TLS server whose self-signed certificate no trust store holds, and a way
// to run fx under a macOS sandbox that denies reads of chosen files.
//
// The server counts what reaches it: TCP connections, handshakes the client
// gave up on, and bytes of a request after a finished handshake. fx must
// reject its certificate, so a connection with a rejected handshake proves
// fx loaded trusted roots and still verifies, and a request proves it did not.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:tls";

export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
/// The two files std's macOS scan reads, in its order.
export const ROOT_KEYCHAIN = "/System/Library/Keychains/SystemRootCertificates.keychain";
export const SYSTEM_KEYCHAIN = "/Library/Keychains/System.keychain";
/// /etc/ssl/cert.pem as the sandbox sees it: /etc links to /private/etc.
export const PUBLIC_BUNDLE = "/private/etc/ssl/cert.pem";

function openssl(): string | null {
  for (const candidate of ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/// macOS with sandbox-exec and openssl, which these checks need.
export function sandboxAvailable(): boolean {
  return process.platform === "darwin" && existsSync(SANDBOX_EXEC) && openssl() !== null;
}

/// Writes a sandbox profile that allows everything but reading `denied`.
export function denyProfile(dir: string, name: string, denied: string[]): string {
  const rules = denied.map((path) => `(deny file-read-data (literal ${JSON.stringify(path)}))`);
  const path = join(dir, `${name}.sb`);
  writeFileSync(path, ["(version 1)", "(allow default)", ...rules, ""].join("\n"));
  return path;
}

export type TlsCounts = { connections: number; rejected: number; requests: number };

export type UntrustedTlsServer = {
  port: number;
  url: (path: string) => string;
  counts: TlsCounts;
  /// Resolves true once `check` holds, false after `ms`.
  waitFor: (check: (counts: TlsCounts) => boolean, ms: number) => Promise<boolean>;
  stop: () => void;
};

export async function startUntrustedTlsServer(): Promise<UntrustedTlsServer> {
  const tool = openssl();
  if (!tool) throw new Error("openssl is required for the untrusted TLS fixture");
  const dir = mkdtempSync(join(tmpdir(), "fx-untrusted-tls-"));
  const key = join(dir, "key.pem");
  const cert = join(dir, "cert.pem");
  const made = spawnSync(tool, [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
    "-days", "1", "-subj", "/CN=127.0.0.1",
  ], { stdio: "pipe" });
  if (made.status !== 0) throw new Error(`openssl failed: ${made.stderr}`);
  const counts: TlsCounts = { connections: 0, rejected: 0, requests: 0 };
  const server = createServer({ key: readFileSync(key), cert: readFileSync(cert) }, (socket) => {
    socket.on("data", () => {
      counts.requests++;
      socket.destroy();
    });
    socket.on("error", () => {});
  });
  server.on("connection", () => { counts.connections++; });
  server.on("tlsClientError", () => { counts.rejected++; });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const port = (server.address() as { port: number }).port;
  return {
    port,
    url: (path) => `https://127.0.0.1:${port}${path}`,
    counts,
    async waitFor(check, ms) {
      const deadline = Date.now() + ms;
      while (Date.now() < deadline) {
        if (check(counts)) return true;
        await Bun.sleep(25);
      }
      return check(counts);
    },
    stop() {
      server.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export type SandboxedRun = { code: number | null; stdout: string; stderr: string; stopped: boolean };

/// Runs `bin args` under `profile` with exactly `env`. When `stopWhen`
/// resolves true first, the process is killed and the run counts as stopped.
export async function runSandboxed(
  profile: string,
  bin: string,
  args: string[],
  options: { cwd: string; env: Record<string, string>; timeoutMs: number; stopWhen?: () => Promise<boolean> },
): Promise<SandboxedRun> {
  const child = Bun.spawn([SANDBOX_EXEC, "-f", profile, bin, ...args], {
    cwd: options.cwd,
    env: options.env,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  let stopped = false;
  const timer = setTimeout(() => child.kill(9), options.timeoutMs);
  if (options.stopWhen) {
    void options.stopWhen().then((stop) => {
      if (stop && child.exitCode === null) {
        stopped = true;
        child.kill(15);
      }
    });
  }
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  clearTimeout(timer);
  return { code, stdout, stderr, stopped };
}
