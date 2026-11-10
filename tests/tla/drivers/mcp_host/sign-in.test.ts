// SignIn: real sign-ins against the engine models' fake Streamable HTTP server with
// fake OAuth (../mcp/fakes/http.ts): discovery,
// registration, an authorization URL the harness follows itself (no browser),
// the loopback callback, and the code redemption the fake logs. Checked
// against SignIn.tla through SignInTrace.tla.
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetModule } from "../lib/context";
import { BUN, checkAnswers, cliLogin, fixture, fxEnv, probe, redemptions, save, startFake, stdioServer, storePath, waitFor, writeProfile, type Fixture } from "./driver";
import { Shell } from "./shell";
import { checkTrace, type TraceRecord } from "./trace";

const { stdoutFrames } = await targetModule("render-lab/tape.ts");

/** Whether the credential store holds a login for `web`: the model's `saved`. */
function storeHoldsLogin(f: Fixture): boolean {
  return existsSync(storePath(f)) && readFileSync(storePath(f), "utf8").includes("\"name\":\"web\"");
}

/**
 * The model's `check` record for the first request that carried each token the fake
 * issued, and `store`: whether the login is kept. `ended` is when fx exited.
 */
function confirmRecords(f: Fixture, fake: { entries: () => import("./driver").FakeEntry[] }, ended: number, login = 1): TraceRecord[] {
  const answers = checkAnswers(fake.entries());
  return [
    ...answers.map((a) => ({ event: "check", data: { login, result: a.result }, at: Math.min(a.t, ended - 1) })),
  ];
}

const storeRecord = (f: Fixture, ended: number, login = 1): TraceRecord => ({ event: "store", data: { login, saved: storeHoldsLogin(f) }, at: ended });

async function signInScenario(name: string, tamper: boolean, opts: { gate?: Record<string, unknown>; web?: Record<string, unknown> } = {}) {
  const f = fixture(artifacts, name);
  const fake = await startFake(f, {}, opts.gate ?? {});
  writeProfile(f, { web: { type: "http", url: fake.url, ...(opts.web ?? {}) } });
  const records: TraceRecord[] = [];
  const at = () => Date.now();
  try {
    records.push({ event: "login", at: at() });
    const login = await cliLogin(binary, f);
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
    for (const t of tokens) records.push({ event: "redeem", data: { login: 1 }, at: Math.min(t.t, ended - 2) });
    records.push(...confirmRecords(f, fake, ended));
    records.push({ event: code === 0 ? "signed_in" : "failed", data: { login: 1 }, at: ended });
    records.push(storeRecord(f, ended));
    const after = await probe(port);
    records.push({ event: "probe", data: { login: 1, result: after.result }, at: at() });
    save(join(f.base, "login-output.json"), { code, stdout: login.out(), stderr: login.err() });
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
    const verdict = await checkTrace({ module: "SignIn", records, dir: join(f.base, "trace"), constants: { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false, ObsCheckFirst: true } });
    save(join(f.base, "verdict.json"), verdict);
    return { f, code, tokens, verdict, after, stray, out: login.out(), err: login.err(), checks: checkAnswers(fake.entries()), saved: storeHoldsLogin(f) };
  } finally { fake.stop(); }
}

test("control: a sign-in redeems the code of the callback whose state matches, then its listener closes (trace ACCEPTED)", async () => {
  const r = await signInScenario("signin-ok", false);
  expect(r.code).toBe(0);
  expect(r.out).toContain("Signed in to web.");
  expect(r.tokens.length).toBe(1);
  expect(r.after.result).toBe("closed");
  expect(readFileSync(join(r.f.home, ".fx", "mcp-credentials", "credentials-v3.json"), "utf8")).toContain("\"name\":\"web\"");
  // Signed in only after the server took a request with the new token.
  expect(r.checks.map((c) => c.result)).toEqual(["accept"]);
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
    const login = await cliLogin(binary, f);
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
    const login = await cliLogin(binary, f);
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

// Fixed. Before the fix a second `/mcp login` closed the first one's
// listener, the port the browser comes back to, while the engine kept the
// first flow and ignored the second, so no return could finish the sign-in
// (SignIn.tla FlowHasListener). On the code before it fails here: the second
// `/mcp login` never shows an address.
test("contract: a login asked for again while one waits is that login: the same address, its port stays open, and its return signs in (trace ACCEPTED)", async () => {
  const f = fixture(artifacts, "signin-again");
  const fake = await startFake(f);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  const shell = new Shell(f);
  const records: TraceRecord[] = [];
  const tapePath = join(f.base, "shell.fxtape");
  // Once the transcript has linked a sign-in page n + 1 times, the addresses
  // those links open, each once: a repaint writes a link again.
  const addresses = async (n: number) => {
    const deadline = Date.now() + 20_000;
    for (;;) {
      const shown = (await shell.tui.captureFullScrollback()).match(/Didn't open\? Open the sign-in page\./g)?.length ?? 0;
      if (shown > n) {
        const written = Buffer.concat(stdoutFrames(tapePath).map((frame: { payload: Uint8Array }) => frame.payload)).toString("utf8");
        return [...new Set([...written.matchAll(/\x1b\]8;id=fx-mcp-sign-in;([^\x1b]+)\x1b\\/g)].map((m) => m[1]!))];
      }
      if (Date.now() > deadline) throw new Error(`timed out waiting for sign-in link ${n + 1}`);
      await Bun.sleep(100);
    }
  };
  try {
    await shell.start({ FX_RECORD: tapePath }, 400);
    records.push({ event: "login", at: Date.now() });
    await shell.tui.sendText("/mcp login web");
    const [first] = await addresses(0);
    expect(first).toBeTruthy();
    records.push({ event: "authorize", data: { login: 1 }, at: Date.now(), note: first });
    const signing = await shell.status({ k: "signing" }, 10_000);
    expect(signing?.k).toBe("signing");
    records.push({ event: "status", data: { signing: true }, at: Date.now() });
    const port = Number(new URL(new URL(first).searchParams.get("redirect_uri")!).port);
    expect((await probe(port)).result).toBe("open");
    records.push({ event: "probe", data: { login: 1, result: "open" }, at: Date.now() });

    records.push({ event: "login", at: Date.now() });
    await shell.tui.sendText("/mcp login web");
    // The second login links the first one's address, and no other.
    expect(await addresses(1)).toEqual([first]);
    const still = await probe(port);
    records.push({ event: "probe", data: { login: 1, result: still.result }, at: Date.now() });

    const redirect = await fetch(first, { redirect: "manual" });
    const location = new URL(redirect.headers.get("location")!);
    records.push({ event: "callback", data: { login: 1, state: 1, kind: "get" }, at: Date.now() });
    const back = await fetch(location.toString(), { signal: AbortSignal.timeout(10_000) }).catch((e) => ({ status: 0, text: async () => String(e) }));
    save(join(f.base, "callback.json"), { location: location.toString(), status: back.status, body: (await back.text()).slice(0, 400) });
    await shell.tui.waitForText("Signed in to web.", 20_000);
    const ended = Date.now();
    const tokens = redemptions(fake.entries());
    for (const t of tokens) records.push({ event: "redeem", data: { login: 1 }, at: Math.min(t.t, ended - 2) });
    records.push(...confirmRecords(f, fake, ended));
    records.push({ event: "signed_in", data: { login: 1 }, at: ended });
    records.push(storeRecord(f, ended));
    const after = await probe(port);
    records.push({ event: "probe", data: { login: 1, result: after.result }, at: Date.now() });
    records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
    const verdict = await checkTrace({ module: "SignIn", records, dir: join(f.base, "trace"), constants: { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false, ObsCheckFirst: true } });
    save(join(f.base, "verdict.json"), verdict);
    expect(still.result).toBe("open");
    expect(back.status).toBe(200);
    expect(tokens.length).toBe(1);
    // The second request started nothing: one client, registered once.
    expect(fake.entries().filter((e) => e.path?.endsWith("/register")).length).toBe(1);
    expect(after.result).toBe("closed");
    expect(verdict.verdict).toBe("ACCEPTED");
    await shell.quit();
  } finally {
    await shell.stop();
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    fake.stop();
  }
}, 150_000);

// A reload applies in place, so a change that leaves the server alone leaves
// its sign-in going; one that removes the server ends it and says so, and the
// shell never keeps saying "Signing in" without a listener
// (IndicatorImpliesListener). Before the in-place reload, any change ended it.
test("contract: a reload that leaves a server alone keeps its sign-in going, and removing the server closes its listener and says why (trace ACCEPTED)", async () => {
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

    records.push({ event: "reload", data: { server: "kept" }, at: Date.now() });
    await shell.tui.sendText(`/mcp add other -- ${BUN} ${stdioServer(f, "other").args[0]}`);
    await shell.tui.waitForText("Added other", 10_000);
    await Bun.sleep(1_000);
    const kept = await probe(port);
    records.push({ event: "probe", data: { login: 1, result: kept.result }, at: Date.now() });
    const going = await shell.status(null, 5_000);
    records.push({ event: "status", data: { signing: going?.k === "signing" }, at: Date.now(), note: JSON.stringify(going) });

    records.push({ event: "reload", data: { server: "dropped" }, at: Date.now() });
    await shell.tui.sendText("/mcp remove web");
    await shell.tui.waitForText("Removed web", 10_000);
    let after = await probe(port);
    // A probe the closing listener drops is no answer either way: probe again.
    for (let k = 0; k < 30 && (after.result === "open" || after.result === "reset"); k++) { await Bun.sleep(100); after = await probe(port); }
    records.push({ event: "probe", data: { login: 1, result: after.result }, at: Date.now() });
    await Bun.sleep(3_000);
    const still = await shell.status(null, 5_000);
    records.push({ event: "status", data: { signing: still?.k === "signing" }, at: Date.now(), note: JSON.stringify(still) });
    save(join(f.base, "after-reload.json"), { kept, going, probe: after, status: still });
    const verdict = await checkTrace({ module: "SignIn", records, dir: join(f.base, "trace"), constants: { ObsMaxLogins: 1, ObsMaxHosts: 2, ObsMaxLeases: 1, ObsBridge: false, ObsCheckFirst: true } });
    save(join(f.base, "verdict.json"), verdict);
    expect(kept.result).toBe("open");
    expect(going?.k).toBe("signing");
    expect(after.result).toBe("closed");
    expect(still?.k).not.toBe("signing");
    expect(await shell.tui.captureFullScrollback()).toContain("Couldn't sign in to web: the MCP config changed before the browser came back.");
    expect(verdict.verdict).toBe("ACCEPTED");
    await shell.quit();
  } finally {
    await shell.stop();
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    fake.stop();
  }
}, 150_000);

// ---- The server's answer to the new login decides the sign-in (SignIn.tla CheckFirst) ----
//
// The ClickState report: the sign-in said "Signed in" and every request after it got
// 401 invalid_token, because the server refused the login's token. Before the fix
// each of these fails: fx reports the sign-in as it came out of the token exchange.

const REFUSE = { refuseTokens: { error: "invalid_token", description: "No authorization provided" } };

test("contract: a server that refuses the new login ends the sign-in with its error, exit 1, and the login is never saved (trace ACCEPTED)", async () => {
  const r = await signInScenario("signin-refused", false, { gate: REFUSE });
  expect(r.checks.map((c) => c.result)).toEqual(["refuse"]);
  expect(r.out).not.toContain("Signed in");
  expect(r.err).toContain("Couldn't sign in to web: web refused the new login (invalid_token: No authorization provided).");
  expect(r.code).toBe(1);
  // A refused token is never written, so no other fx process can take it (NeverTakeRefused).
  expect(r.saved).toBe(false);
  expect(r.tokens.length).toBe(1);
  expect(r.verdict.verdict).toBe("ACCEPTED");
}, 120_000);

test("contract: a challenge that names no error still ends the sign-in as a refusal, in words that hold no server text", async () => {
  const r = await signInScenario("signin-refused-garbage", false, { gate: { tokenFault: "garbage" } });
  expect(r.checks.map((c) => c.result)).toEqual(["refuse"]);
  expect(r.out).not.toContain("Signed in");
  expect(r.err).toContain("Couldn't sign in to web: web refused the new login.");
  expect(r.code).toBe(1);
  expect(r.saved).toBe(false);
  expect(r.verdict.verdict).toBe("ACCEPTED");
}, 120_000);

for (const fault of ["500", "drop"] as const) {
  test(`contract: a check request that fails (${fault}) keeps the login and says it couldn't check, exit 0 (trace ACCEPTED)`, async () => {
    const r = await signInScenario(`signin-check-${fault}`, false, { gate: { tokenFault: fault } });
    expect(r.checks.map((c) => c.result)).toEqual(["fail"]);
    expect(r.out).toContain("Signed in to web, but fx couldn't reach it to check the login.");
    expect(r.code).toBe(0);
    expect(r.saved).toBe(true);
    expect(r.verdict.verdict).toBe("ACCEPTED");
  }, 120_000);
}

test("contract: a check request that gets no answer ends at the server's timeout, with the login kept and the note, exit 0 (trace ACCEPTED)", async () => {
  // operation_timeout_ms and startup_timeout_ms accept 1 ms and up, so the real timeout path runs in seconds.
  const r = await signInScenario("signin-check-hang", false, { gate: { tokenFault: "hang" }, web: { startup_timeout_ms: 1500, operation_timeout_ms: 1500 } });
  expect(r.checks.map((c) => c.result)).toEqual(["fail"]);
  expect(r.out).toContain("Signed in to web, but fx couldn't reach it to check the login.");
  expect(r.code).toBe(0);
  expect(r.saved).toBe(true);
  expect(r.verdict.verdict).toBe("ACCEPTED");
}, 120_000);

// The login is kept only once the server has answered, so fx killed while the check
// request is in flight leaves nothing saved: the next start needs a login, with no
// reason, as for any server never signed in to.
test("crash recovery: fx killed while the check request is in flight leaves no saved login, and the server needs a login", async () => {
  const f = fixture(artifacts, "signin-killed-mid-check");
  const fake = await startFake(f, {}, { tokenFault: "hang" });
  writeProfile(f, { web: { type: "http", url: fake.url } });
  try {
    const login = await cliLogin(binary, f);
    const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
    const redirect = await fetch(url, { redirect: "manual" });
    await (await fetch(new URL(redirect.headers.get("location")!).toString())).text();
    // The check request reached the server and hangs there.
    await waitFor("the check request", () => fake.entries().find((e) => e.dir === "gate" && e.token), 30_000);
    login.child.kill("SIGKILL");
    await login.child.exited;
    save(join(f.base, "http-fake-entries.json"), fake.entries());
    expect(storeHoldsLogin(f)).toBe(false);
    expect(login.out()).not.toContain("Signed in");
    const show = Bun.spawnSync([binary, "mcp", "show", "web", "--json"], { cwd: f.workspace, env: { ...fxEnv(f) }, stdout: "pipe", stderr: "pipe" });
    const shown = JSON.parse(new TextDecoder().decode(show.stdout));
    expect(shown.status).toBe("needs_login");
    expect(shown.error ?? null).toBeNull();
  } finally { fake.stop(); }
}, 120_000);

// Stress: the same refusing server, sign-in after sign-in. None is reported as signed in
// or left saved, and each costs one exchange and one check. FX_TLA_SIGNIN_STRESS sets the count.
test("stress: repeated sign-ins to a server that refuses every login never report one or save one", async () => {
  const rounds = Number(process.env.FX_TLA_SIGNIN_STRESS ?? 6);
  const f = fixture(artifacts, "signin-refused-stress");
  const fake = await startFake(f, {}, REFUSE);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  try {
    for (let n = 1; n <= rounds; n++) {
      const login = await cliLogin(binary, f);
      const url = await waitFor(`the authorization URL (round ${n})`, () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
      const redirect = await fetch(url, { redirect: "manual" });
      await (await fetch(new URL(redirect.headers.get("location")!).toString())).text();
      const code = await login.done();
      expect({ n, code, out: login.out().includes("Signed in"), err: login.err().includes("web refused the new login (invalid_token: No authorization provided).") }).toEqual({ n, code: 1, out: false, err: true });
      expect(storeHoldsLogin(f)).toBe(false);
    }
    expect(redemptions(fake.entries()).length).toBe(rounds);
    expect(checkAnswers(fake.entries()).map((c) => c.result)).toEqual(Array(rounds).fill("refuse"));
  } finally { fake.stop(); }
}, 600_000);

// The trace check itself, with no fx run: a sign-in that waits for the server's answer
// is a behavior of SignIn.tla (CheckFirst), and each of fx before the fix, a refused login
// that is kept, and a refused login that is reported as signed in is not.
describe("the trace check holds SignIn.tla's check rules", () => {
  const start: TraceRecord[] = [
    { event: "login" },
    { event: "authorize", data: { login: 1 } },
    { event: "callback", data: { login: 1, state: 1, kind: "get" } },
    { event: "redeem", data: { login: 1 } },
  ];
  const constants = { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false, ObsCheckFirst: true };
  const verdictOf = async (name: string, tail: TraceRecord[]) =>
    (await checkTrace({ module: "SignIn", records: [...start, ...tail], dir: join(fixture(artifacts, `trace-${name}`).base, "trace"), constants })).verdict;
  const check = (result: string): TraceRecord => ({ event: "check", data: { login: 1, result } });
  const store = (saved: boolean): TraceRecord => ({ event: "store", data: { login: 1, saved } });
  const ended = (event: string): TraceRecord => ({ event, data: { login: 1 } });

  test("an accepted check, then signed in, with the login kept", async () => {
    expect(await verdictOf("accept", [check("accept"), ended("signed_in"), store(true)])).toBe("ACCEPTED");
  }, 120_000);
  test("a check that fails, then signed in with a note, with the login kept", async () => {
    expect(await verdictOf("fail", [check("fail"), ended("signed_in"), store(true)])).toBe("ACCEPTED");
  }, 120_000);
  test("a refused check, then the sign-in fails, with nothing kept", async () => {
    expect(await verdictOf("refuse", [check("refuse"), ended("failed"), store(false)])).toBe("ACCEPTED");
  }, 120_000);
  test("signed in with no check before it is not a behavior (fx before the fix)", async () => {
    expect(await verdictOf("no-check", [ended("signed_in"), store(true)])).toBe("REJECTED");
  }, 120_000);
  test("a refused login that is kept is not a behavior", async () => {
    expect(await verdictOf("kept", [check("refuse"), ended("failed"), store(true)])).toBe("REJECTED");
  }, 120_000);
  test("a refused login that is reported as signed in is not a behavior", async () => {
    expect(await verdictOf("reported", [check("refuse"), ended("signed_in"), store(false)])).toBe("REJECTED");
  }, 120_000);
  test("an accepted login that is not kept is not a behavior", async () => {
    expect(await verdictOf("lost", [check("accept"), ended("signed_in"), store(false)])).toBe("REJECTED");
  }, 120_000);
});
