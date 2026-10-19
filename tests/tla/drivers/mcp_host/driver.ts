// What the mcp-v2-model scenarios share: private fixture folders outside
// every repository, the real fx binary with a scratch HOME, fixture logs,
// the credential files, loopback probes, and evidence files.
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { TraceRecord } from "./trace";

export const FIXTURE = join(import.meta.dirname, "fixtures", "stdio-server.ts");
/** MCP-v2's fake Streamable HTTP server with fake OAuth, used read-only. */
export const HTTP_FAKE = join(import.meta.dirname, "../mcp/fakes/http.ts");
export const BUN = process.execPath;

export interface Fixture { base: string; home: string; workspace: string; control: string; serverLog: string; traceLog: string }

export function fixture(root: string, name: string): Fixture {
  const base = mkdtempSync(join(root, `${name}-`));
  const home = join(base, "home");
  const workspace = join(base, "workspace");
  const control = join(base, "control");
  for (const dir of [join(home, ".fx"), workspace, control]) mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  return { base, home, workspace, control, serverLog: join(base, "servers.jsonl"), traceLog: join(base, "fx-trace.log") };
}

/** fx's environment: scratch HOME, MCP-v2, no Keychain, no browser, no sound, a fake gateway key. */
export function fxEnv(f: Fixture, extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: f.home,
    TMPDIR: process.env.TMPDIR ?? "/tmp",
    FX_MCP_ENGINE: "v2",
    FX_DISABLE_KEYCHAIN: "1",
    FX_NO_OPEN_BROWSER: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TRACE_LOG: f.traceLog,
    AI_GATEWAY_API_KEY: "fake-mcp-v2-model-key",
    ...extra,
  };
}

/** A stdio server entry for mcp.json running the fixture. */
export function stdioServer(f: Fixture, name: string, extra: Record<string, string> = {}) {
  return { command: BUN, args: [FIXTURE], env: { FIXTURE_NAME: name, FIXTURE_LOG: f.serverLog, FIXTURE_CONTROL: f.control, ...extra } };
}

export function writeProfile(f: Fixture, servers: Record<string, unknown>) {
  writeFileSync(join(f.home, ".fx", "mcp.json"), JSON.stringify({ mcpServers: servers }, null, 2), { mode: 0o600 });
}
export function writeProject(f: Fixture, servers: Record<string, unknown>) {
  writeFileSync(join(f.workspace, ".mcp.json"), JSON.stringify({ mcpServers: servers }, null, 2));
}

export interface Ran { args: string[]; code: number; stdout: string; stderr: string; ms: number }

/** Runs the binary once, with an explicit timeout; every run is appended to `runs.jsonl`. */
export async function runFx(binary: string, f: Fixture, args: string[], env: Record<string, string>, timeoutMs = 30_000): Promise<Ran> {
  const started = Date.now();
  const child = Bun.spawn([binary, ...args], { cwd: f.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  clearTimeout(timer);
  const ran = { args, code, stdout, stderr, ms: Date.now() - started };
  appendFileSync(join(f.base, "runs.jsonl"), JSON.stringify(ran) + "\n");
  return ran;
}

export interface ServerEvent { t: number; name: string; pid: number; ev: string; [k: string]: unknown }

export function serverEvents(f: Fixture): ServerEvent[] {
  if (!existsSync(f.serverLog)) return [];
  return readFileSync(f.serverLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as ServerEvent);
}

export async function waitFor<T>(what: string, probe: () => T | undefined | null | false, timeoutMs: number, everyMs = 50): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const got = probe();
    if (got) return got as T;
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs} ms waiting for ${what}`);
    await Bun.sleep(everyMs);
  }
}

/** A GET to a loopback port: "open" when something answered, "closed" when the connection was refused. */
export async function probe(port: number, path = "/favicon.ico"): Promise<{ result: "open" | "closed" | "hang"; status?: number }> {
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, { signal: AbortSignal.timeout(2000) });
    await response.text();
    return { result: "open", status: response.status };
  } catch (error) {
    const text = String((error as { code?: string }).code ?? error);
    if (/ECONNREFUSED|ConnectionRefused|Unable to connect/i.test(text)) return { result: "closed" };
    if (/Timeout|abort/i.test(text)) return { result: "hang" };
    throw error;
  }
}

// ---- credentials ----

export const credDir = (f: Fixture) => join(f.home, ".fx", "mcp-credentials");
export const v2Path = (f: Fixture) => join(credDir(f), "credentials-v2.json");
export const v1Path = (f: Fixture) => join(credDir(f), "credentials.json");
/** The note that v1's logins were taken over. */
export const notePath = (f: Fixture) => join(credDir(f), "v1-imported");

/** A v1 login as v1's store keeps it (mcp_auth_store.zig, its own test's shape). */
export function v1Entry(name: string, url: string) {
  return {
    server_identity: name, token_type: "Bearer", endpoint: url, resource: url, issuer: "http://127.0.0.1:9",
    client_id: "c1", client_secret: null, access_token: `v1-access-${name}`, refresh_token: `v1-refresh-${name}`, scope: "read",
    token_endpoint_auth_method: "none", authorization_endpoint: "http://127.0.0.1:9/authorize",
    token_endpoint: "http://127.0.0.1:9/token", revocation_endpoint: null, expires_at_ms: null,
  };
}

export function writeV1(f: Fixture, entries: object[]) {
  mkdirSync(credDir(f), { recursive: true, mode: 0o700 });
  writeFileSync(v1Path(f), JSON.stringify({ version: 1, credentials: entries }), { mode: 0o600 });
}

/** The documents as the model sees them: the v2 one's kind, entries, and flag; v1's logins. */
export function observeStores(f: Fixture) {
  let kind = "absent", entries: string[] = [], imported = false;
  if (existsSync(v2Path(f))) {
    const text = readFileSync(v2Path(f), "utf8");
    try {
      const doc = JSON.parse(text);
      entries = (doc.servers ?? []).map((s: { name: string }) => s.name).sort();
      imported = doc.imported_v1 === true;
      kind = doc.version === 1 && Array.isArray(doc.servers) ? "ok" : "unreadable";
    } catch { kind = "unreadable"; }
  }
  const v1 = existsSync(v1Path(f)) ? (JSON.parse(readFileSync(v1Path(f), "utf8")).credentials ?? []).map((c: { server_identity: string }) => c.server_identity).sort() : [];
  return { kind, entries, imported, marked: existsSync(notePath(f)), v1 };
}

export function save(path: string, value: unknown) {
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value, null, 2));
}

/** Server log lines as trace records, in time order with the harness's own. */
export function merge(...lists: TraceRecord[][]): TraceRecord[] {
  return lists.flat().map((r, k) => ({ r, k })).sort((a, b) => (a.r.at ?? 0) - (b.r.at ?? 0) || a.k - b.k).map((x) => x.r);
}
