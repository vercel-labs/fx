// fx doctor through the built binary: each check against a local stand-in
// that works, fails, or hangs on purpose.
import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { writeChatGptLogin, writeGrokLogin } from "./usage-fakes";
import { createConfiguredProviderFixture } from "./fixtures/chat-completions";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const MODEL = "fake/doctor-model";
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const TIMEOUT = 40_000;

const cleanups: Array<() => void> = [];
afterEach(() => {
  while (cleanups.length) cleanups.pop()!();
});

type Root = { root: string; home: string; workspace: string; bin: string };

function makeRoot(): Root {
  const root = createIsolatedTestHome();
  cleanups.push(() => cleanupIsolatedTestHome(root));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const bin = join(root, "bin");
  for (const dir of [join(home, ".fx"), workspace, bin]) mkdirSync(dir, { recursive: true, mode: 0o700 });
  return { root, home, workspace, bin };
}

/** A gateway that serves the models list, with `answer` deciding each reply. */
function gateway(answer: (req: Request) => Response | Promise<Response>) {
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    fetch(req) {
      if (new URL(req.url).pathname !== "/coding-agent/v1/models") return new Response("not found", { status: 404 });
      return answer(req);
    },
  });
  cleanups.push(() => server.stop(true));
  const base = `http://127.0.0.1:${server.port}`;
  return { FX_GATEWAY_BASE_URL: base, FX_TEST_GATEWAY_MODELS_URL: `${base}/coding-agent/v1/models` };
}

const models = (ids: string[]) => Response.json({ data: ids.map((id) => ({ id, type: "language", tags: ["tool-use"] })) });
const acceptingGateway = () => gateway(() => models([MODEL]));

/**
 * Only the parent's locale and temp folder pass through, so no credential in
 * it, such as GH_TOKEN, GITHUB_TOKEN, or AI_GATEWAY_API_KEY, reaches doctor or
 * its children. PATH is the test's own bin folder alone, so a gh or fx the
 * machine has never runs; fixtures name every other tool by its full path.
 */
const PASSED_ENV = ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"];

function env(r: Root, extra: Record<string, string | undefined> = {}): Record<string, string> {
  const merged: Record<string, string | undefined> = {
    ...Object.fromEntries(PASSED_ENV.map((k) => [k, process.env[k]])),
    HOME: r.home,
    PATH: r.bin,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_MODEL: MODEL,
    ...extra,
  };
  return Object.fromEntries(Object.entries(merged).filter(([, v]) => v !== undefined)) as Record<string, string>;
}

/** The warn and fail lines in text output that no `fix:` line follows. */
function problemsWithoutFix(stdout: string): string[] {
  const lines = stdout.split("\n");
  return lines.filter((line, i) => /^\[(warn|fail)\] /.test(line) && !(lines[i + 1] ?? "").startsWith("  fix: "));
}

async function doctor(r: Root, environment: Record<string, string>, args: string[] = [], cwd = r.workspace) {
  const started = performance.now();
  const proc = Bun.spawn([FX_BIN, "doctor", ...args], { env: environment, cwd, stdout: "pipe", stderr: "pipe" });
  const killer = setTimeout(() => proc.kill("SIGKILL"), 30_000);
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(killer);
  // Every problem doctor reports comes with a fix, in text and in JSON.
  if (code === 0 || code === 1) {
    if (args.includes("--json")) {
      const unfixed = JSON.parse(stdout).checks.filter((check: any) => check.status !== "ok" && !check.fix);
      expect(unfixed).toEqual([]);
    } else {
      expect(problemsWithoutFix(stdout)).toEqual([]);
    }
  }
  return { stdout, stderr, code, ms: performance.now() - started };
}

/** Processes whose command line contains `marker`. */
function running(marker: string): string {
  return spawnSync("/usr/bin/pgrep", ["-f", marker]).stdout.toString().trim();
}

/** An fx login with no team, which loads only the public model list. */
function writeTeamlessFxLogin(home: string) {
  writeFileSync(join(home, ".fx", "auth.json"), JSON.stringify({
    version: 1, issuer: "https://vercel.com", client_id: "test-client", access_token: "doctor-teamless-token",
    refresh_token: "doctor-refresh", expires_at_ms: Date.now() + 3_600_000, scope: "openid", token_type: "Bearer",
  }) + "\n", { mode: 0o600 });
}

function writeScript(path: string, body: string) {
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
}

/** A git repository at the workspace, with `origin` at `url` when given. */
function gitRepo(r: Root, url: string | null = "https://github.com/example/repo.git") {
  expect(spawnSync("/usr/bin/git", ["init", "-q", r.workspace]).status).toBe(0);
  if (url) expect(spawnSync("/usr/bin/git", ["-C", r.workspace, "remote", "add", "origin", url]).status).toBe(0);
}

describe("fx doctor provider", () => {
  test("a refused key fails even when the public model list loads", async () => {
    const r = makeRoot();
    const g = gateway((req) => req.headers.get("authorization") ? new Response("unauthorized", { status: 401 }) : models([MODEL]));
    const result = await doctor(r, env(r, { ...g, AI_GATEWAY_API_KEY: "doctor-refused-key" }));
    expect(result.stdout).toMatch(/^\[fail\] auth: /m);
    expect(result.stdout).toContain("fx login");
    expect(result.stdout).not.toContain("doctor-refused-key");
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("a gateway error, a rate limit, and an unreadable answer each say what happened", async () => {
    const cases: Array<[() => Response, number, RegExp, string]> = [
      [() => new Response("boom", { status: 500 }), 1, /^\[fail\] provider: AI Gateway answered the check with an error$/m, "run fx doctor again later"],
      [() => new Response("slow down", { status: 429 }), 0, /^\[warn\] provider: AI Gateway rate-limited the check/m, "run fx doctor again in a minute"],
      [() => new Response("not json", { status: 200, headers: { "content-type": "application/json" } }), 1, /^\[fail\] provider: AI Gateway sent a model list fx cannot read$/m, "run fx doctor again later"],
    ];
    for (const [answer, code, line, fix] of cases) {
      const r = makeRoot();
      const result = await doctor(r, env(r, { ...gateway(answer), AI_GATEWAY_API_KEY: "doctor-key" }));
      expect(result.code).toBe(code);
      expect(result.stdout).toMatch(line);
      expect(result.stdout).toContain(`  fix: ${fix}`);
      expect(result.stdout).toMatch(/^\[warn\] auth: .*the provider did not confirm it$/m);
    }
  }, 60_000);

  test("ChatGPT and Grok logins are checked against their own model lists", async () => {
    const codexModel = (slug: string) => ({ slug, visibility: "list", supported_in_api: true, priority: 1, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 });
    const grokModel = (id: string) => ({ id, model: id, api_backend: "responses", context_window: 1000000, supports_reasoning_effort: false, reasoning_efforts: [] });
    const providers = [
      { id: "codex", label: "ChatGPT", model: "gpt-5.4-mini", login: writeChatGptLogin, list: (m: string) => Response.json({ models: [codexModel(m), codexModel("gpt-5.6-luna")] }), urls: (b: string) => ({ FX_TEST_OPENAI_CODEX_MODELS_URL: `${b}/coding-agent/v1/models` }) },
      { id: "grok", label: "Grok", model: "grok-4.20", login: writeGrokLogin, list: (m: string) => Response.json({ data: [grokModel(m)] }), urls: (b: string) => ({ FX_TEST_XAI_GROK_MODELS_URL: `${b}/coding-agent/v1/models`, FX_TEST_XAI_GROK_MODALITIES_URL: `${b}/modalities` }) },
    ];
    // ChatGPT's list must carry the permission reviewer's model to load.
    for (const p of providers) {
      for (const [answer, code, line] of [
        [() => p.list(p.model), 0, new RegExp(`^\\[ok\\] model: ${p.model}`, "m")],
        [() => p.list("some-other-model"), 1, new RegExp(`^\\[fail\\] model: ${p.model} `, "m")],
        [() => Response.json({ error: "no" }, { status: 401 }), 1, new RegExp(`^\\[fail\\] auth: ${p.label} refused the credential$`, "m")],
      ] as Array<[() => Response, number, RegExp]>) {
        const r = makeRoot();
        p.login(r.home);
        const base = gateway(answer).FX_GATEWAY_BASE_URL;
        const result = await doctor(r, env(r, { FX_PROVIDER: p.id, FX_MODEL: p.model, ...p.urls(base) }));
        expect(result.stdout).toMatch(line);
        expect(result.stdout).not.toMatch(/^\[fail\] (provider|startup):/m);
        expect(result.code).toBe(code);
      }
    }
  }, 60_000);

  test("a model the provider does not list fails", async () => {
    const r = makeRoot();
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_MODEL: "nope/missing" }));
    expect(result.stdout).toMatch(/^\[ok\] auth: /m);
    expect(result.stdout).toMatch(/^\[fail\] model: .*nope\/missing/m);
    expect(result.stdout).toContain("fx models");
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("a gateway that never answers fails inside the time limit", async () => {
    const r = makeRoot();
    const g = gateway(() => new Promise<Response>(() => {}));
    const result = await doctor(r, env(r, { ...g, AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "1000" }));
    expect(result.ms).toBeLessThan(4_000);
    expect(result.stdout).toMatch(/^\[fail\] provider: could not reach AI Gateway in 1 s$/m);
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("an answer just inside the deadline counts and one just past it does not", async () => {
    const early = makeRoot();
    const fast = gateway(async () => {
      await Bun.sleep(200);
      return models([MODEL]);
    });
    const inside = await doctor(early, env(early, { ...fast, AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "1500" }));
    expect(inside.stdout).toMatch(/^\[ok\] auth: /m);
    expect(inside.stdout).toMatch(/^\[ok\] model: /m);

    const late = makeRoot();
    const slow = gateway(async () => {
      await Bun.sleep(2_500);
      return models([MODEL]);
    });
    const past = await doctor(late, env(late, { ...slow, AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "1000" }));
    expect(past.stdout).toMatch(/^\[fail\] provider: .*could not reach/m);
    expect(past.stdout).not.toMatch(/^\[ok\] auth: /m);
  }, TIMEOUT);

  test("a public list does not confirm the credential, and a team-less fx login is told to pick a team", async () => {
    const r = makeRoot();
    writeTeamlessFxLogin(r.home);
    let authorized = 0;
    let anonymous = 0;
    const g = gateway((req) => {
      if (req.headers.get("authorization")) authorized += 1;
      else anonymous += 1;
      return models([MODEL]);
    });
    const result = await doctor(r, env(r, g));
    expect(authorized).toBe(0);
    expect(anonymous).toBe(1);
    expect(result.stdout).not.toContain("accepted the credential");
    expect(result.stdout).toMatch(/^\[warn\] auth: AI Gateway sent only its public model list, so the credential is not confirmed\n  fix: fx teams$/m);
    expect(result.stdout).not.toContain("doctor-teamless-token");
  }, TIMEOUT);

  test("a configured provider is not asked, so nothing claims it accepted the credential", async () => {
    const f = createConfiguredProviderFixture();
    cleanups.push(() => f.close());
    f.settings.provider = "remote";
    f.save();
    const r: Root = { root: f.home, home: f.home, workspace: f.workspace, bin: join(f.home, "bin") };
    mkdirSync(r.bin, { mode: 0o700 });
    const result = await doctor(r, env(r, { FX_MODEL: undefined, FX_TEST_PROVIDER_TOKEN: "wrong-token" }));
    expect(f.requests).toEqual([]);
    expect(result.stdout).not.toContain("accepted the credential");
    expect(result.stdout).not.toMatch(/^\[\w+\] (provider|model): /m);
    expect(result.stdout).toMatch(/^\[ok\] auth: /m);
  }, TIMEOUT);

  test("with no credential the auth check fails without any request", async () => {
    const r = makeRoot();
    let hits = 0;
    const g = gateway(() => {
      hits += 1;
      return models([MODEL]);
    });
    const result = await doctor(r, env(r, { ...g }));
    expect(result.stdout).toMatch(/^\[fail\] auth: /m);
    expect(result.stdout).toContain("fx login");
    expect(hits).toBe(0);
    expect(result.code).toBe(1);
  }, TIMEOUT);
});

describe("fx doctor exit code and output", () => {
  test("warnings alone exit 0", async () => {
    const r = makeRoot();
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(result.stdout).not.toMatch(/^\[fail\]/m);
    expect(result.stdout).toMatch(/^\[warn\] /m);
    expect(result.code).toBe(0);
  }, TIMEOUT);

  test("--json carries the version, each fix, and the same exit code", async () => {
    const r = makeRoot();
    const result = await doctor(r, env(r, { ...acceptingGateway() }), ["--json"]);
    const json = JSON.parse(result.stdout);
    expect(typeof json.version).toBe("string");
    const auth = json.checks.find((check: any) => check.name === "auth");
    expect(auth.status).toBe("fail");
    expect(auth.fix).toContain("fx login");
    expect(json.fail_count).toBeGreaterThan(0);
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("--help names --fix and a bad flag still exits 2, named as the flag that is wrong", async () => {
    const r = makeRoot();
    const help = await doctor(r, env(r), ["--help"]);
    expect(help.stdout).toContain("--fix");
    const bad = await doctor(r, env(r), ["--nope"]);
    expect(bad.code).toBe(2);
    const afterFix = await doctor(r, env(r), ["--fix", "--bogus"]);
    expect(afterFix.code).toBe(2);
    expect(afterFix.stderr).toContain("fx doctor: unknown flag --bogus");
    expect(afterFix.stderr).not.toContain("unknown flag --fix");
    const json = await doctor(r, env(r), ["--json", "--fix", "--bogus"]);
    expect(json.code).toBe(2);
    expect(JSON.parse(json.stdout).error).toBe("unknown flag --bogus");
  }, TIMEOUT);
});

describe("fx doctor local checks", () => {
  test("a malformed settings file fails with its path, and a bad env value says what fx uses", async () => {
    const r = makeRoot();
    writeFileSync(join(r.home, ".fx", "settings.json"), "{not json");
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_PERMISSION_MODE: "garbage", FX_MAX_AGENT_STEPS: "abc" }));
    expect(result.stdout).toMatch(/^\[fail\] config: .*settings\.json/m);
    expect(result.stdout).not.toMatch(/no config files found/);
    expect(result.stdout).toMatch(/^\[warn\] env: FX_PERMISSION_MODE=garbage .*auto/m);
    expect(result.stdout).toMatch(/^\[warn\] env: FX_MAX_AGENT_STEPS=abc /m);
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("git is found from a repository subfolder and missing outside one", async () => {
    const r = makeRoot();
    expect(spawnSync("/usr/bin/git", ["init", "-q", r.workspace]).status).toBe(0);
    const sub = join(r.workspace, "src", "deep");
    mkdirSync(sub, { recursive: true });
    const inside = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }), [], sub);
    expect(inside.stdout).toMatch(/^\[ok\] git: /m);

    const outside = makeRoot();
    const away = await doctor(outside, env(outside, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(away.stdout).toMatch(/^\[warn\] git: /m);
  }, TIMEOUT);

  test("gh repo view's exit code says whether gh can use the repository, and gh runs only inside one", async () => {
    const outside = makeRoot();
    const away = await doctor(outside, env(outside, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(away.stdout).not.toMatch(/^\[(ok|warn|fail)\] gh: /m);

    const missing = makeRoot();
    gitRepo(missing);
    const none = await doctor(missing, env(missing, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(none.stdout).toContain("[warn] gh: GitHub CLI not found on PATH; fx pr --create and fx issue --create need it\n  fix: install gh from https://cli.github.com\n");

    // gh's own exit codes (gh help exit-codes): 4 when the command needs a sign-in.
    const cases: Array<[number, string]> = [
      [0, "[ok] gh: gh can use this repository\n"],
      [4, "[warn] gh: gh is not signed in for this repository\n  fix: gh auth login\n"],
      [1, "[warn] gh: gh could not use this repository\n  fix: run gh repo view to see why\n"],
    ];
    for (const [code, line] of cases) {
      const r = makeRoot();
      gitRepo(r);
      writeScript(join(r.bin, "gh"), `exit ${code}`);
      const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
      expect(result.stdout).toContain(line);
      expect(result.code).toBe(0);
    }

    // gh's own child holds nothing doctor waits for, and dies with it.
    const hanging = makeRoot();
    gitRepo(hanging);
    const marker = "sleep 57.6543";
    writeScript(join(hanging.bin, "gh"), `/bin/${marker}\nexit 0`);
    const hung = await doctor(hanging, env(hanging, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "1000" }));
    expect(hung.ms).toBeLessThan(2_500);
    expect(hung.stdout).toContain("[warn] gh: gh repo view did not answer in 1 s\n  fix: run gh repo view to see why\n");
    expect(running(marker)).toBe("");
  }, TIMEOUT);

  test("gh resolves the repository itself, gets the person's GH_HOST with prompts and update checks off, and nothing it prints reaches doctor's output", async () => {
    const secret = "SECRET-TOKEN-1677";
    for (const url of [`https://user:${secret}@github.com/org/repo.git`, `https://user:${secret}@[::1]:8443/org/repo.git`]) {
      const r = makeRoot();
      gitRepo(r, url);
      const log = join(r.root, "gh.log");
      // Like gh, it prints the remote it read, here with its token, on both
      // streams.
      writeScript(join(r.bin, "gh"), [
        `{ echo "args=$*"; echo "cwd=$(/bin/pwd -P)"; echo "prompt=$GH_PROMPT_DISABLED"; echo "notifier=$GH_NO_UPDATE_NOTIFIER"; echo "host=$GH_HOST"; } > '${log}'`,
        `echo '{"url":"${url}"}'`,
        `echo "could not resolve ${url}" >&2`,
        "exit 1",
      ].join("\n"));
      const trace = join(r.root, "trace.log");
      const e = env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", GH_HOST: "ghe.example.com", FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "doctor" });
      const text = await doctor(r, e);
      expect(text.stdout).toContain("[warn] gh: gh could not use this repository\n");
      const json = await doctor(r, e, ["--json"]);
      for (const out of [text.stdout, text.stderr, json.stdout, json.stderr, readFileSync(trace, "utf8")]) expect(out).not.toContain(secret);
      const workspace = realpathSync(r.workspace);
      expect(readFileSync(log, "utf8")).toBe(`args=repo view --json url\ncwd=${workspace}\nprompt=1\nnotifier=1\nhost=ghe.example.com\n`);
    }
  }, TIMEOUT);

  test("a signal that ends doctor also ends the checks it started", async () => {
    const markers = { SIGINT: "sleep 56.1234", SIGTERM: "sleep 56.4321", SIGHUP: "sleep 56.5555" } as const;
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
      const r = makeRoot();
      gitRepo(r);
      const marker = markers[signal];
      writeScript(join(r.bin, "gh"), `/bin/${marker}\nexit 0`);
      const proc = Bun.spawn([FX_BIN, "doctor"], { env: env(r, { FX_TEST_DOCTOR_DEADLINE_MS: "20000" }), cwd: r.workspace, stdout: "ignore", stderr: "ignore" });
      const started = performance.now();
      while (running(marker) === "" && performance.now() - started < 10_000) await Bun.sleep(50);
      expect(running(marker)).not.toBe("");
      proc.kill(signal);
      await proc.exited;
      expect(proc.signalCode).toBe(signal);
      const stopped = performance.now();
      while (running(marker) !== "" && performance.now() - stopped < 2_000) await Bun.sleep(50);
      expect(running(marker)).toBe("");
    }
  }, TIMEOUT);

  test("install shows the version and warns about another fx on PATH", async () => {
    const r = makeRoot();
    writeScript(join(r.bin, "fx"), "exit 0");
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(result.stdout).toMatch(/^\[ok\] install: fx \S+ at /m);
    expect(result.stdout).toMatch(new RegExp(`^\\[warn\\] install: .*${r.bin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/fx`, "m"));
  }, TIMEOUT);

  test("a skill file that does not load shows with its path", async () => {
    const r = makeRoot();
    const skill = join(r.workspace, ".agents", "skills", "broken");
    mkdirSync(skill, { recursive: true });
    writeFileSync(join(skill, "SKILL.md"), "---\nname: not a safe name/../x\n---\nbody\n");
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(result.stdout).toMatch(/^\[warn\] skills: .*broken/m);
  }, TIMEOUT);
});

describe("fx doctor MCP", () => {
  test("each server gets its own line, a hanging one fails in time, and an unapproved one never starts", async () => {
    const r = makeRoot();
    const hang = Bun.serve({ hostname: "127.0.0.1", port: 0, idleTimeout: 0, fetch: () => new Promise<Response>(() => {}) });
    cleanups.push(() => hang.stop(true));
    const marker = join(r.root, "project-server-started");
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({
      mcp: {
        ready1: { command: [process.execPath, MODERN_FIXTURE] },
        hang1: { type: "http", url: `http://127.0.0.1:${hang.port}/mcp`, startup_timeout_ms: 60_000 },
      },
    }));
    writeFileSync(join(r.workspace, ".mcp.json"), JSON.stringify({
      mcpServers: { project: { command: "/bin/sh", args: ["-c", `: > '${marker}'; /bin/sleep 30`] } },
    }));
    const trace = join(r.root, "trace.log");
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "3000", FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "doctor" }));
    expect(result.ms).toBeLessThan(6_000);
    // Doctor itself starts a check only for an approved server.
    const started = readFileSync(trace, "utf8");
    expect(started).toContain("starting check ready1");
    expect(started).not.toContain("starting check project");
    expect(result.stdout).toMatch(/^\[ok\] mcp: ready1\b/m);
    expect(result.stdout).toMatch(/^\[fail\] mcp: hang1 .*did not start/m);
    expect(result.stdout).toMatch(/^\[warn\] mcp: project .*approv/m);
    await Bun.sleep(300);
    expect(existsSync(marker)).toBe(false);
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("each server's row in the report says what doctor found for it", async () => {
    const r = makeRoot();
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({
      mcp: {
        ready1: { command: [process.execPath, MODERN_FIXTURE] },
        broken: { command: ["/bin/sh", "-c", "exit 0"] },
      },
    }));
    writeFileSync(join(r.workspace, ".mcp.json"), JSON.stringify({ mcpServers: { project: { command: "/bin/sh", args: ["-c", "exit 0"] } } }));
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "3000" }), ["--json"]);
    const report = JSON.parse(result.stdout);
    expect(report.mcp.connection_check).toBe("checked");
    const row = (name: string) => report.mcp.servers.find((s: any) => s.name === name);
    expect([row("ready1").connection, row("ready1").authentication]).toEqual(["ready", "ok"]);
    expect([row("broken").connection, row("broken").authentication]).toEqual(["failed", "not_checked"]);
    // An unapproved server gets no child, so doctor did not check it.
    expect([row("project").connection, row("project").authentication]).toEqual(["not_checked", "not_checked"]);
    expect(report.checks.find((c: any) => c.name === "mcp" && c.detail.startsWith("ready1")).status).toBe("ok");
    expect(report.checks.find((c: any) => c.name === "mcp" && c.detail.startsWith("broken")).status).toBe("fail");
  }, TIMEOUT);

  test("a server whose name starts with a dash is not checked, and says why and how to fix it", async () => {
    const r = makeRoot();
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({
      mcp: {
        "--help": { command: [process.execPath, MODERN_FIXTURE] },
        "-x": { command: [process.execPath, MODERN_FIXTURE] },
        "-s": { type: "sse", url: "https://mcp.invalid.example/rpc" },
        "-h": { type: "http", url: "https://mcp.invalid.example/mcp", bearer_token_env: "NOPE_TOKEN_1677" },
        normal: { command: [process.execPath, MODERN_FIXTURE] },
      },
    }));
    // A project server waits for approval, which `fx mcp approve -w` cannot give.
    writeFileSync(join(r.workspace, ".mcp.json"), JSON.stringify({ mcpServers: { "-w": { command: "/bin/sh", args: ["-c", "exit 0"] } } }));
    const trace = join(r.root, "trace.log");
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "3000", FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "doctor" }));
    for (const name of ["--help", "-x"]) {
      expect(result.stdout).toContain(`[warn] mcp: ${name} was not checked: fx mcp show reads a name that starts with "-" as an option\n  fix: rename the server in ~/.fx/mcp.json so its name does not start with "-"\n`);
      expect(readFileSync(trace, "utf8")).not.toContain(`starting check ${name}`);
    }
    expect(result.stdout).toContain('[warn] mcp: -s uses a transport fx does not support\n  fix: rename the server in ~/.fx/mcp.json so its name does not start with "-"\n');
    // Also in a state whose fix would otherwise name the variable to set.
    expect(result.stdout).toContain('[fail] mcp: -h needs NOPE_TOKEN_1677\n  fix: rename the server in ~/.fx/mcp.json so its name does not start with "-"\n');
    expect(result.stdout).toContain('[warn] mcp: -w is waiting for approval\n  fix: rename the server in .mcp.json so its name does not start with "-"\n');
    expect(result.stdout).not.toMatch(/fix: fx mcp \w+ -/);
    expect(result.stdout).toMatch(/^\[ok\] mcp: normal ready, 1 tool$/m);
    expect(result.code).toBe(1);
  }, TIMEOUT);

  test("a fix line passes a server name from .mcp.json to a shell as one word, and runs as written", async () => {
    const r = makeRoot();
    const marker = join(r.root, "pwned");
    const names = [`x; touch '${marker}' #`, `$(touch '${marker}2')`, "it's `id`", "two words"];
    writeFileSync(join(r.workspace, ".mcp.json"), JSON.stringify({
      mcpServers: Object.fromEntries(names.map((name) => [name, { command: "/bin/sh", args: ["-c", "exit 0"] }])),
    }));
    const result = await doctor(r, env(r));
    const fixes = result.stdout.split("\n").filter((line) => line.startsWith("  fix: fx mcp approve ")).map((line) => line.slice("  fix: ".length));
    expect(fixes).toHaveLength(names.length);
    // A stand-in fx records the words a shell hands it.
    const fake = join(r.root, "fake-bin");
    mkdirSync(fake);
    const argsLog = join(r.root, "args.log");
    writeScript(join(fake, "fx"), `for a in "$@"; do printf '[%s]' "$a"; done >> '${argsLog}'; echo >> '${argsLog}'`);
    for (const fix of fixes) expect(spawnSync("/bin/sh", ["-c", fix], { env: { PATH: `${fake}:/usr/bin:/bin` } }).status).toBe(0);
    expect(existsSync(marker) || existsSync(`${marker}2`)).toBe(false);
    const got = readFileSync(argsLog, "utf8").trim().split("\n").sort();
    expect(got).toEqual(names.map((name) => `[mcp][approve][${name}]`).sort());

    // The real fx approves each one from the same line.
    const real = join(r.root, "real-bin");
    mkdirSync(real);
    symlinkSync(FX_BIN, join(real, "fx"));
    for (const fix of fixes) {
      expect(spawnSync("/bin/sh", ["-c", fix], { cwd: r.workspace, env: env(r, { PATH: `${real}:/usr/bin:/bin` }) }).status).toBe(0);
    }
    expect(existsSync(marker) || existsSync(`${marker}2`)).toBe(false);
    const after = await doctor(r, env(r));
    expect(after.stdout).not.toContain("is waiting for approval");
  }, TIMEOUT);

  test("SIGINT or SIGTERM while doctor starts its checks leaves no check and no server running", async () => {
    const r = makeRoot();
    // Names and a server line unique to this run, so no other fx on the
    // machine matches them.
    const run = `${process.pid}${Date.now() % 100_000}`;
    const check = `mcp show sig${run}_`;
    const server = `sleep 55.${run}`;
    const mcp: Record<string, unknown> = {};
    // Servers that ignore SIGTERM, so only doctor's kill of each check with
    // everything it started ends them at once.
    for (let i = 0; i < 50; i++) mcp[`sig${run}_${i}`] = { command: ["/bin/sh", "-c", `trap '' TERM; exec /bin/${server}`] };
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp }));
    cleanups.push(() => {
      spawnSync("/usr/bin/pkill", ["-KILL", "-f", server]);
      spawnSync("/usr/bin/pkill", ["-KILL", "-f", check]);
    });
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
      for (const delay of [0, 10, 40]) {
        const proc = Bun.spawn([FX_BIN, "doctor"], { env: env(r, { FX_TEST_DOCTOR_DEADLINE_MS: "30000" }), cwd: r.workspace, stdout: "ignore", stderr: "ignore" });
        const started = performance.now();
        while (running(check) === "" && performance.now() - started < 10_000) await Bun.sleep(1);
        if (delay > 0) await Bun.sleep(delay);
        proc.kill(signal);
        await proc.exited;
        expect(proc.signalCode).toBe(signal);
        expect(running(check)).toBe("");
        await Bun.sleep(3_000);
        expect(running(server)).toBe("");
      }
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("on a terminal, doctor says on stderr which checks it waits for, and not with --json", async () => {
    const r = makeRoot();
    const hang = Bun.serve({ hostname: "127.0.0.1", port: 0, idleTimeout: 0, fetch: () => new Promise<Response>(() => {}) });
    cleanups.push(() => hang.stop(true));
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp: { slow: { type: "http", url: `http://127.0.0.1:${hang.port}/mcp` } } }));
    for (const args of ["", " --json"]) {
      // The word after doctor ends marks the end of its output, which a
      // narrow pane can wrap.
      const cmd = `/bin/sh -c ${JSON.stringify(`${JSON.stringify(FX_BIN)} doctor${args}; echo DOCTOR-ENDED`)}`;
      const session = await TmuxSession.create({ cmd, cwd: r.workspace, env: env(r, { FX_TEST_DOCTOR_DEADLINE_MS: "2000" }), remainOnExit: true });
      try {
        await session.waitForText("DOCTOR-ENDED", 15_000);
        const screen = await session.captureFullScrollback();
        if (args) expect(screen).not.toContain("checking ");
        else expect(screen).toContain("checking 1 MCP server (up to 2 s)...");
      } finally {
        await session.kill();
      }
    }
  }, TIMEOUT);

  test("a project .mcp.json that skips servers fails with a fix, as ~/.fx/mcp.json does", async () => {
    const unreadable = makeRoot();
    writeFileSync(join(unreadable.workspace, ".mcp.json"), "{not json\n");
    const whole = await doctor(unreadable, env(unreadable, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(whole.stdout).toContain("[fail] mcp_config: .mcp.json server 'unknown' was skipped: invalid_json.\n  fix: fix .mcp.json, then run fx doctor again\n");
    expect(whole.code).toBe(1);

    const oneBad = makeRoot();
    writeFileSync(join(oneBad.workspace, ".mcp.json"), JSON.stringify({ mcpServers: { odd: { type: "weird", url: "x" }, docs: { command: "/bin/sh", args: ["-c", "exit 0"] } } }));
    const entry = await doctor(oneBad, env(oneBad, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(entry.stdout).toContain("[fail] mcp_config: .mcp.json server 'odd' was skipped: its \"type\" isn't valid.\n  fix: fix .mcp.json, then run fx doctor again\n");
    expect(entry.stdout).toMatch(/^\[warn\] mcp: docs is waiting for approval$/m);
    expect(entry.code).toBe(1);
  }, TIMEOUT);

  test("servers doctor could not start before its deadline each get a line that says so", async () => {
    const r = makeRoot();
    // More servers than doctor checks at once (16 at most). A check of one
    // never ends on its own, so no slot frees before the 1 ms deadline, and
    // the servers past the cap are never started.
    const names = Array.from({ length: 20 }, (_, i) => `late${i}`);
    const mcp: Record<string, unknown> = {};
    for (const name of names) mcp[name] = { command: "/bin/sh", args: ["-c", `: > '${join(r.root, name)}'; /bin/sleep 30`] };
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp }));
    const result = await doctor(r, env(r, { FX_TEST_DOCTOR_DEADLINE_MS: "1" }));
    expect(result.code).toBe(1);
    const notChecked = names.filter((name) => {
      expect(result.stdout).toMatch(new RegExp(`^\\[fail\\] mcp: ${name} (was not checked: doctor reached its 1 s limit before it could start the check|did not start in 1 s)\\n  fix: fx mcp show ${name}$`, "m"));
      return result.stdout.includes(`[fail] mcp: ${name} was not checked`);
    });
    expect(notChecked.length).toBeGreaterThanOrEqual(names.length - 16);
    for (const name of notChecked) expect(existsSync(join(r.root, name))).toBe(false);
    spawnSync("/usr/bin/pkill", ["-KILL", "-f", `${r.root}/late`]);
  }, TIMEOUT);

  test("with more servers than doctor checks at once, each is checked as a slot frees", async () => {
    const r = makeRoot();
    const mcp: Record<string, unknown> = {};
    for (let i = 0; i < 24; i++) mcp[`queued${i}`] = { command: [process.execPath, MODERN_FIXTURE] };
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp }));
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "30000" }));
    expect((result.stdout.match(/^\[ok\] mcp: queued\d+ ready, 1 tool$/gm) ?? []).length).toBe(24);
    expect(result.code).toBe(0);
  }, TIMEOUT);

  test("a healthy server with thousands of tools is ready, however long its answer", async () => {
    const r = makeRoot();
    const server = join(r.root, "many-tools.mjs");
    writeFileSync(server, [
      'import { createInterface } from "node:readline";',
      'const tools = Array.from({ length: 3000 }, (_, i) => ({ name: `tool_${i}`, description: "d".repeat(120), inputSchema: { type: "object", properties: {} } }));',
      'createInterface({ input: process.stdin }).on("line", (line) => {',
      '  const m = JSON.parse(line);',
      '  if (m.id === undefined) return;',
      '  const result = m.method === "initialize" ? { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "many", version: "1" } } : m.method === "tools/list" ? { tools } : {};',
      '  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result }) + "\\n");',
      '});',
    ].join("\n"));
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp: { many: { command: [process.execPath, server] } } }));
    const e = env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" });
    const shown = spawnSync(FX_BIN, ["mcp", "show", "many", "--json"], { env: e, cwd: r.workspace });
    expect(shown.status).toBe(0);
    expect(shown.stdout.length).toBeGreaterThan(64 * 1024);
    const result = await doctor(r, e);
    expect(result.stdout).toMatch(/^\[ok\] mcp: many ready, 3000 tools$/m);
  }, TIMEOUT);

  test("no MCP servers configured adds no MCP line", async () => {
    const r = makeRoot();
    const result = await doctor(r, env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(result.stdout).not.toMatch(/^\[(ok|warn|fail)\] mcp: /m);
  }, TIMEOUT);
});

describe("fx doctor cleanup", () => {
  test("old side folders are listed without --fix and removed only with it", async () => {
    const r = makeRoot();
    const files = join(r.home, ".fx", "session-files");
    const old = join(files, "OldOrphan0001");
    const young = join(files, "NewOrphan0002");
    for (const dir of [old, young]) mkdirSync(dir, { recursive: true, mode: 0o700 });
    const twoDaysAgo = (Date.now() - 2 * 24 * 3600 * 1000) / 1000;
    utimesSync(old, twoDaysAgo, twoDaysAgo);
    const e = env(r, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" });

    const look = await doctor(r, e);
    expect(look.stdout).toContain("fx doctor --fix");
    expect(existsSync(old)).toBe(true);

    const fix = await doctor(r, e, ["--fix"]);
    expect(fix.stdout).toMatch(/removed 1 /);
    expect(existsSync(old)).toBe(false);
    expect(existsSync(young)).toBe(true);
  }, TIMEOUT);
});
