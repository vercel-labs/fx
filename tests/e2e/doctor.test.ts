// fx doctor through the built binary: each check against a local stand-in
// that works, fails, or hangs on purpose.
import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { writeChatGptLogin, writeGrokLogin } from "./usage-fakes";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";

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

function env(r: Root, extra: Record<string, string | undefined> = {}): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (k.startsWith("FX_") || k.startsWith("AI_GATEWAY_") || k === "VERCEL_OIDC_TOKEN") continue;
    out[k] = v;
  }
  const merged: Record<string, string | undefined> = {
    ...out,
    HOME: r.home,
    PATH: `${r.bin}:/usr/bin:/bin`,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_MODEL: MODEL,
    ...extra,
  };
  return Object.fromEntries(Object.entries(merged).filter(([, v]) => v !== undefined)) as Record<string, string>;
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
  return { stdout, stderr, code, ms: performance.now() - started };
}

function writeScript(path: string, body: string) {
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
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

  test("--help names --fix and a bad flag still exits 2", async () => {
    const r = makeRoot();
    const help = await doctor(r, env(r), ["--help"]);
    expect(help.stdout).toContain("--fix");
    const bad = await doctor(r, env(r), ["--nope"]);
    expect(bad.code).toBe(2);
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

  test("gh missing, signed out, and hanging are each a warning with a fix inside a repository", async () => {
    const repo = (r: Root) => expect(spawnSync("/usr/bin/git", ["init", "-q", r.workspace]).status).toBe(0);
    const outside = makeRoot();
    const away = await doctor(outside, env(outside, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(away.stdout).not.toMatch(/^\[(ok|warn|fail)\] gh: /m);

    const missing = makeRoot();
    repo(missing);
    const none = await doctor(missing, env(missing, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(none.stdout).toMatch(/^\[warn\] gh: .*not found/m);

    const signedOut = makeRoot();
    repo(signedOut);
    writeScript(join(signedOut.bin, "gh"), 'echo "You are not logged into any GitHub hosts." >&2; exit 1');
    const out = await doctor(signedOut, env(signedOut, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key" }));
    expect(out.stdout).toMatch(/^\[warn\] gh: .*not signed in/m);
    expect(out.stdout).toContain("gh auth login");

    const hanging = makeRoot();
    repo(hanging);
    writeScript(join(hanging.bin, "gh"), "sleep 60");
    const hung = await doctor(hanging, env(hanging, { ...acceptingGateway(), AI_GATEWAY_API_KEY: "doctor-key", FX_TEST_DOCTOR_DEADLINE_MS: "1000" }));
    expect(hung.ms).toBeLessThan(4_000);
    expect(hung.stdout).toMatch(/^\[warn\] gh: .*did not answer/m);
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
      mcpServers: { project: { command: "/bin/sh", args: ["-c", `: > '${marker}'; sleep 30`] } },
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

  test("servers doctor could not start before its deadline each get a line that says so", async () => {
    const r = makeRoot();
    const marker = join(r.root, "late-server-started");
    const late = { command: "/bin/sh", args: ["-c", `: > '${marker}'; sleep 30`] };
    writeFileSync(join(r.home, ".fx", "mcp.json"), JSON.stringify({ mcp: { late1: late, late2: late } }));
    // A 1 ms deadline passes while doctor loads its MCP host, before any child.
    const result = await doctor(r, env(r, { FX_TEST_DOCTOR_DEADLINE_MS: "1" }));
    expect(result.code).toBe(1);
    for (const name of ["late1", "late2"]) {
      expect(result.stdout).toMatch(new RegExp(`^\\[fail\\] mcp: ${name} was not checked: doctor reached its .* limit`, "m"));
      expect(result.stdout).toContain(`  fix: fx mcp show ${name}`);
    }
    expect(existsSync(marker)).toBe(false);
  });

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
