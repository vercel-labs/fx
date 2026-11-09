// MixedBuilds: real `fx mcp list --json`, `fx mcp login` (against the fake
// HTTP server with fake OAuth) and `fx mcp logout` runs against a scratch
// HOME (FX_DISABLE_KEYCHAIN=1, so the file backend), with an older build
// beside it played by the harness: it writes credentials-v2.json as builds
// from before version 2 of the document do, version 1 with only its own
// login. Both documents are read back after each step, and the trace is
// checked against MixedBuilds.tla through MixedBuildsTrace.tla.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import { cliLogin, credDir, fixture, fxEnv, olderStorePath, runFx, save, startFake, storePath, waitFor, writeProfile, type Fixture } from "./driver";
import { checkTrace, type TraceRecord } from "./trace";

/** An older build's document: version 1, holding only its own login, as it writes one. */
function olderWrite(f: Fixture, url: string, access: string | null) {
  mkdirSync(credDir(f), { recursive: true, mode: 0o700 });
  const servers = access === null ? [] : [{ name: "web", url, credential: JSON.stringify({ access, refresh: `${access}-refresh`, expires_at_ms: null, token_endpoint: `${new URL(url).origin}/token`, revocation_endpoint: null, resource: url, client_id: "older", client_secret: null, method: "none" }) }];
  const text = JSON.stringify({ version: 1, imported_v1: true, servers });
  writeFileSync(olderStorePath(f), text, { mode: 0o600 });
  return text;
}

function holdsWeb(path: string): boolean {
  if (!existsSync(path)) return false;
  return (JSON.parse(readFileSync(path, "utf8")).servers ?? []).some((s: { name: string }) => s.name === "web");
}

/** Both documents as the model sees them. */
function observe(f: Fixture) {
  let v2kind = "absent";
  if (existsSync(olderStorePath(f))) v2kind = `v${JSON.parse(readFileSync(olderStorePath(f), "utf8")).version}`;
  return { v2kind, v2: holdsWeb(olderStorePath(f)), v3: holdsWeb(storePath(f)) };
}

const bytes = (path: string) => (existsSync(path) ? readFileSync(path, "utf8") : null);

test("an older build beside this one: its login isn't taken, its writes never reach this build's, and this build never writes its store (trace ACCEPTED)", async () => {
  const f = fixture(artifacts, "mixed-builds");
  const fake = await startFake(f);
  writeProfile(f, { web: { type: "http", url: fake.url } });
  const records: TraceRecord[] = [];
  const look = () => {
    const o = observe(f);
    records.push({ event: "observe", data: o, at: Date.now() });
    return o;
  };
  const run = async (cmd: "get" | "logout", args: string[]) => {
    records.push({ event: "run", data: { cmd }, at: Date.now(), note: `fx ${args.join(" ")}` });
    return runFx(binary, f, args, fxEnv(f), 30_000);
  };
  const older = (op: "save" | "remove", access: string | null) => {
    records.push({ event: "older", data: { op }, at: Date.now() });
    return olderWrite(f, fake.url, access);
  };
  try {
    // An older build signed in before the update.
    let olderText = olderWrite(f, fake.url, "older-1");
    expect(look()).toEqual({ v2kind: "v1", v2: true, v3: false });

    // This build starts: the older login isn't taken, and nothing is written.
    const first = await run("get", ["mcp", "list", "--json"]);
    expect(first.code).toBe(0);
    expect(JSON.parse(first.stdout).servers[0].status).not.toBe("signed_in");
    expect(look()).toEqual({ v2kind: "v1", v2: true, v3: false });
    expect(bytes(olderStorePath(f))).toBe(olderText);

    // The older build refreshes and saves its login, as version 1.
    olderText = older("save", "older-2");
    expect(look()).toEqual({ v2kind: "v1", v2: true, v3: false });

    // This build signs in: its login goes to its own store only.
    records.push({ event: "run", data: { cmd: "signin" }, at: Date.now(), note: "fx mcp login --no-browser web" });
    const login = await cliLogin(binary, f);
    const url = await waitFor("the authorization URL", () => /\n\s+(http\S+)\n/.exec(login.out())?.[1], 30_000);
    const redirect = await fetch(url, { redirect: "manual" });
    await fetch(redirect.headers.get("location")!);
    expect(await login.done()).toBe(0);
    expect(login.out()).toContain("Signed in to web.");
    expect(look()).toEqual({ v2kind: "v1", v2: true, v3: true });
    expect(bytes(olderStorePath(f))).toBe(olderText);
    const signedIn = bytes(storePath(f));

    // The older build's login ends, and it removes it as it does, whatever
    // its store holds: this build's login is untouched.
    olderText = older("remove", null);
    expect(look()).toEqual({ v2kind: "v1", v2: false, v3: true });
    expect(bytes(storePath(f))).toBe(signedIn);

    // A new host still finds this build's login.
    const again = await run("get", ["mcp", "list", "--json"]);
    expect(again.code).toBe(0);
    expect(JSON.parse(again.stdout).servers[0].status).toBe("signed_in");
    expect(look()).toEqual({ v2kind: "v1", v2: false, v3: true });

    // Signing out empties this build's store, and leaves the older one alone.
    const out = await run("logout", ["mcp", "logout", "web"]);
    expect(out.stdout).toBe("Signed out of web.\n");
    expect(look()).toEqual({ v2kind: "v1", v2: false, v3: false });
    expect(bytes(olderStorePath(f))).toBe(olderText);

    save(join(f.base, "http-fake-entries.json"), fake.entries());
    const verdict = await checkTrace({ module: "MixedBuilds", records, dir: join(f.base, "trace"), constants: { ObsRevokeOnReplay: false } });
    save(join(f.base, "verdict.json"), verdict);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { fake.stop(); }
}, 180_000);
