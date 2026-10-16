// SignIn: real sign-ins against MCP-v2's fake Streamable HTTP server with
// fake OAuth (../mcp/fakes/http.ts): discovery,
// registration, an authorization URL the harness follows itself (no browser),
// the loopback callback, and the code redemption the fake logs. Checked
// against SignIn.tla through SignInTrace.tla.
import { expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import { BUN, HTTP_FAKE, fixture, fxEnv, probe, save, stdioServer, waitFor, writeProfile, type Fixture } from "./driver";
import { Shell } from "./shell";
import { checkTrace, type TraceRecord } from "./trace";

const MODERN = "2026-07-28";
const RULES = [
  { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
  { method: "tools/list", result: { resultType: "complete", tools: [{ name: "echo", inputSchema: { type: "object" } }] } },
];

async function startFake(f: Fixture, server: Record<string, unknown> = {}) {
  if (!existsSync(HTTP_FAKE)) throw new Error(`harness: MCP-v2's fake HTTP server is missing at ${HTTP_FAKE}`);
  const rules = join(f.base, "rules.json"), auth = join(f.base, "auth.json"), log = join(f.base, "http-fake.jsonl");
  writeFileSync(rules, JSON.stringify(RULES));
  writeFileSync(auth, JSON.stringify({ servers: [server], challengeScope: "mcp:read" }));
  const child = Bun.spawn([BUN, HTTP_FAKE, "--script", rules, "--log", log, "--auth", auth], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const reader = child.stdout.getReader();
  let text = "";
  const deadline = Date.now() + 10_000;
  while (!text.includes("\n") && Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    text += new TextDecoder().decode(value);
  }
  const port = JSON.parse(text.split("\n")[0]!).listening as number;
  const entries = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []) as { t: number; dir?: string; path?: string; form?: Record<string, string>; json?: { redirect_uris?: string[] } }[];
  return { url: `http://127.0.0.1:${port}/mcp`, entries, stop: () => child.kill() };
}

const redemptions = (entries: ReturnType<Awaited<ReturnType<typeof startFake>>["entries"]>) =>
  entries.filter((e) => e.dir === "auth" && e.path?.endsWith("/token") && e.form?.grant_type === "authorization_code");

/** `fx mcp login --no-browser web` with stdin left open, its output read as it comes. */
async function cliLogin(f: Fixture) {
  const child = Bun.spawn([binary, "mcp", "login", "--no-browser", "web"], { cwd: f.workspace, env: fxEnv(f), stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  let out = "", err = "";
  void (async () => { for await (const c of child.stdout) out += new TextDecoder().decode(c); })();
  void (async () => { for await (const c of child.stderr) err += new TextDecoder().decode(c); })();
  const killer = setTimeout(() => child.kill("SIGKILL"), 60_000);
  return {
    child, out: () => out, err: () => err,
    async done() { const code = await child.exited; clearTimeout(killer); await Bun.sleep(50); return code; },
  };
}

async function signInScenario(name: string, tamper: boolean) {
  const f = fixture(artifacts, name);
  const fake = await startFake(f);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  const records: TraceRecord[] = [];
  const at = () => Date.now();
  try {
    records.push({ event: "login", at: at() });
    const login = await cliLogin(f);
    const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
    records.push({ event: "authorize", data: { login: 1 }, at: at(), note: url });
    const authorize = new URL(url);
    const port = Number(new URL(authorize.searchParams.get("redirect_uri")!).port);
    const before = await probe(port);
    expect(before).toEqual({ result: "open", status: 404 });
    records.push({ event: "probe", data: { login: 1, result: "open" }, at: at() });
    // A form posted to the loopback listener (not a bridged sign-in) is refused, and the wait goes on.
    records.push({ event: "callback", data: { login: 1, state: 0, kind: "form_foreign" }, at: at() });
    const form = await fetch(`http://127.0.0.1:${port}/callback`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "code=x&state=y" });
    expect(form.status).toBe(404);
    const redirect = await fetch(url, { redirect: "manual" });
    const location = new URL(redirect.headers.get("location")!);
    const state = location.searchParams.get("state");
    expect(state).toBe(authorize.searchParams.get("state"));
    let stray: { status: number; open: string } | undefined;
    if (tamper) {
      // A return with a state fx never made gets a 404 and the wait goes on.
      const wrong = new URL(location.toString());
      wrong.searchParams.set("state", "not-the-state-fx-made");
      records.push({ event: "callback", data: { login: 1, state: 0, kind: "get" }, at: at() });
      const reply = await fetch(wrong.toString(), { signal: AbortSignal.timeout(10_000) });
      await reply.text();
      const still = await probe(port);
      records.push({ event: "probe", data: { login: 1, result: still.result }, at: at() });
      stray = { status: reply.status, open: still.result };
      save(join(f.base, "stray.json"), { location: wrong.toString(), ...stray });
    }
    // Recorded when sent: fx answers the page and redeems before this fetch returns.
    records.push({ event: "callback", data: { login: 1, state: 1, kind: "get" }, at: at() });
    const back = await fetch(location.toString());
    save(join(f.base, "callback.json"), { location: location.toString(), status: back.status, body: (await back.text()).slice(0, 400) });
    const code = await login.done();
    const ended = at();
    const tokens = redemptions(fake.entries());
    for (const t of tokens) records.push({ event: "redeem", data: { login: 1 }, at: Math.min(t.t, ended - 1) });
    records.push({ event: code === 0 ? "signed_in" : "failed", data: { login: 1 }, at: ended });
    const after = await probe(port);
    records.push({ event: "probe", data: { login: 1, result: after.result }, at: at() });
    save(join(f.base, "login-output.json"), { code, stdout: login.out(), stderr: login.err() });
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
    const verdict = await checkTrace({ module: "SignIn", records, dir: join(f.base, "trace"), constants: { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false } });
    save(join(f.base, "verdict.json"), verdict);
    return { f, code, tokens, verdict, after, stray, out: login.out(), err: login.err() };
  } finally { fake.stop(); }
}

test("control: a sign-in redeems the code of the callback whose state matches, then its listener closes (trace ACCEPTED)", async () => {
  const r = await signInScenario("signin-ok", false);
  expect(r.code).toBe(0);
  expect(r.out).toContain("Signed in to web.");
  expect(r.tokens.length).toBe(1);
  expect(r.after.result).toBe("closed");
  expect(readFileSync(join(r.f.home, ".fx", "mcp-credentials", "credentials-v2.json"), "utf8")).toContain("\"name\":\"web\"");
  expect(r.verdict.verdict).toBe("ACCEPTED");
}, 120_000);

// Fixed. Before the fix a return with a state fx never made ended the
// sign-in ("Couldn't sign in to web"), so anything that could reach the port
// could cancel it. It fails that way on the code before.
test("contract: a return whose state isn't the live sign-in's gets a 404 and the sign-in goes on; its own return still signs in (trace ACCEPTED)", async () => {
  const r = await signInScenario("signin-wrong-state", true);
  expect(r.stray).toEqual({ status: 404, open: "open" });
  expect(r.code).toBe(0);
  expect(r.out).toContain("Signed in to web.");
  // Only the sign-in's own code is redeemed.
  expect(r.tokens.length).toBe(1);
  expect(r.after.result).toBe("closed");
  expect(r.verdict.verdict).toBe("ACCEPTED");
}, 120_000);

// Fixed. A return whose iss names another authorization server is
// never redeemed; before the fix fx called it "the sign-in page returned an
// error". It fails that way on the code before.
test("contract: a return naming another issuer redeems nothing, and fx says the answer wasn't for this sign-in", async () => {
  const f = fixture(artifacts, "signin-wrong-iss");
  const fake = await startFake(f, { iss: "wrong" });
  writeProfile(f, { web: { type: "http", url: fake.url } });
  try {
    const login = await cliLogin(f);
    const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
    const redirect = await fetch(url, { redirect: "manual" });
    const location = new URL(redirect.headers.get("location")!);
    expect(location.searchParams.get("iss")).toBe("https://evil.example.com");
    const back = await fetch(location.toString());
    save(join(f.base, "callback.json"), { location: location.toString(), status: back.status, body: (await back.text()).slice(0, 400) });
    const code = await login.done();
    save(join(f.base, "login-output.json"), { code, stdout: login.out(), stderr: login.err() });
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    expect(code).toBe(1);
    expect(login.err()).toContain("Couldn't sign in to web");
    expect(login.err()).toContain("the answer that came back wasn't for this sign-in");
    expect(login.err()).not.toContain("the sign-in page returned an error");
    expect(redemptions(fake.entries())).toEqual([]);
  } finally { fake.stop(); }
}, 120_000);

// A pasted address goes to the sign-in without
// the listener's state check. One with a state fx never made is never
// redeemed; before the fix fx called it "the sign-in page returned an error".
test("contract: a pasted return with a state fx never made redeems nothing, and fx says the answer wasn't for this sign-in", async () => {
  const f = fixture(artifacts, "signin-pasted-wrong-state");
  const fake = await startFake(f);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  try {
    const login = await cliLogin(f);
    const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
    const redirect = await fetch(url, { redirect: "manual" });
    const wrong = new URL(redirect.headers.get("location")!);
    wrong.searchParams.set("state", "not-the-state-fx-made");
    login.child.stdin.write(`${wrong.toString()}\n`);
    login.child.stdin.flush();
    const code = await login.done();
    save(join(f.base, "login-output.json"), { pasted: wrong.toString(), code, stdout: login.out(), stderr: login.err() });
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    expect(code).toBe(1);
    expect(login.err()).toContain("Couldn't sign in to web");
    expect(login.err()).toContain("the answer that came back wasn't for this sign-in");
    expect(login.err()).not.toContain("the sign-in page returned an error");
    expect(redemptions(fake.entries())).toEqual([]);
  } finally { fake.stop(); }
}, 120_000);

// Fixed by stopping the sign-in and saying so. Before the fix this
// case was a finding: the shell kept saying "Signing in" and the trace broke
// IndicatorImpliesListener. It fails that way on the code before.
test("contract: a reload during a sign-in closes its listener, and the shell stops saying \"Signing in\" and says why (trace ACCEPTED)", async () => {
  const f = fixture(artifacts, "signin-reload");
  const fake = await startFake(f);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  const shell = new Shell(f);
  const records: TraceRecord[] = [];
  try {
    await shell.start();
    records.push({ event: "login", at: Date.now() });
    await shell.tui.sendText("/mcp login web");
    await shell.tui.waitForText("Sign in to web in your browser", 20_000);
    records.push({ event: "authorize", data: { login: 1 }, at: Date.now() });
    const signing = await shell.status({ k: "signing" }, 10_000);
    expect(signing?.k).toBe("signing");
    records.push({ event: "status", data: { signing: true }, at: Date.now() });
    const registered = await waitFor("the registration's redirect URI", () => fake.entries().find((e) => e.path?.endsWith("/register"))?.json?.redirect_uris?.[0], 10_000);
    const port = Number(new URL(registered).port);
    expect((await probe(port)).result).toBe("open");
    records.push({ event: "probe", data: { login: 1, result: "open" }, at: Date.now() });
    records.push({ event: "reload", at: Date.now() });
    await shell.tui.sendText(`/mcp add other -- ${BUN} ${stdioServer(f, "other").args[0]}`);
    await shell.tui.waitForText("Added other", 10_000);
    let after = await probe(port);
    for (let k = 0; k < 30 && after.result === "open"; k++) { await Bun.sleep(100); after = await probe(port); }
    records.push({ event: "probe", data: { login: 1, result: after.result }, at: Date.now() });
    await Bun.sleep(3_000);
    const still = await shell.status(null, 5_000);
    records.push({ event: "status", data: { signing: still?.k === "signing" }, at: Date.now(), note: JSON.stringify(still) });
    save(join(f.base, "after-reload.json"), { probe: after, status: still });
    const verdict = await checkTrace({ module: "SignIn", records, dir: join(f.base, "trace"), constants: { ObsMaxLogins: 1, ObsMaxHosts: 2, ObsMaxLeases: 1, ObsBridge: false } });
    save(join(f.base, "verdict.json"), verdict);
    expect(after.result).toBe("closed");
    expect(still?.k).not.toBe("signing");
    expect(await shell.tui.captureFullScrollback()).toContain("Couldn't sign in to web: the MCP config changed before the browser came back; run /mcp login web again.");
    expect(verdict.verdict).toBe("ACCEPTED");
    await shell.quit();
  } finally {
    await shell.stop();
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    fake.stop();
  }
}, 150_000);
