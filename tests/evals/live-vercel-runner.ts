#!/usr/bin/env bun
// AC-33: the shell runner against the real Vercel API. Run by hand, on request, never in CI.
// This file is not a `*.test.ts`, so `bun test` does not find it. tests/AGENTS.md keeps credentialed,
// on-request checks in tests/evals/.
//
//   FX_RUNNER_LIVE=1 FX_LIVE_TEAM_SLUG=<team slug> FX_LIVE_PROJECT_NAME=fx-live-<name> \
//     bun tests/evals/live-vercel-runner.ts
//
// VERCEL_TOKEN is optional. Without it, the token comes from the Vercel CLI login file, found by the
// same rule as fx's own login reader, so no token is needed on a command line.
//
// The project name must start with `fx-live-`. The script deletes only the sandboxes whose names fx
// computes for this checkout and user, and only the ones this run created. It never prints the token,
// team names, or ids; it prints key names and value types only, and the runner's own `fx:` lines.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const FX = resolve("zig-out/bin/fx");
const API = "https://api.vercel.com";
const PROJECT_PREFIX = "fx-live-";

function refuse(message: string): never {
  console.error(`refused: ${message}`);
  process.exit(2);
}

if (process.env.FX_RUNNER_LIVE !== "1") refuse("set FX_RUNNER_LIVE=1; this check creates real Vercel sandboxes");
const teamSlug = process.env.FX_LIVE_TEAM_SLUG;
if (!teamSlug) refuse("set FX_LIVE_TEAM_SLUG to the team slug; there is no default team");
const projectName = process.env.FX_LIVE_PROJECT_NAME;
if (!projectName) refuse("set FX_LIVE_PROJECT_NAME to a project whose name starts with fx-live-");
if (!projectName.startsWith(PROJECT_PREFIX)) refuse(`the project name must start with ${PROJECT_PREFIX}; this check never runs against another project`);
// The login rule of fx (src/core/runner/vercel/credentials.zig): a set VERCEL_TOKEN wins. Otherwise the
// first auth.json that exists decides, and a file that exists but is broken gives no token.
const LOGIN_FILE_MAX_BYTES = 64 * 1024;
const LOGIN_TOKEN_MAX_BYTES = 4 * 1024;
const LOGIN_EXPIRY_MARGIN_S = 60;

function loginFilePaths(): string[] {
  const paths: string[] = [];
  const home = process.env.HOME;
  if (process.platform === "darwin" && home) paths.push(join(home, "Library", "Application Support", "com.vercel.cli", "auth.json"));
  const xdg = process.env.XDG_DATA_HOME;
  if (xdg) paths.push(join(xdg, "com.vercel.cli", "auth.json"));
  if (home) paths.push(join(home, ".local", "share", "com.vercel.cli", "auth.json"));
  return paths;
}

// The token in one login file, or null when the file is broken, expired, or holds no usable token.
// The token itself is never printed.
function tokenInLoginFile(path: string): string | null {
  try {
    const bytes = readFileSync(path);
    if (bytes.length > LOGIN_FILE_MAX_BYTES) return null;
    const root: any = JSON.parse(bytes.toString("utf8"));
    if (typeof root !== "object" || root === null || Array.isArray(root)) return null;
    const token = root.token;
    if (typeof token !== "string" || token.length === 0) return null;
    if (Buffer.byteLength(token) > LOGIN_TOKEN_MAX_BYTES || !/^[\x21-\x7e]+$/.test(token)) return null;
    const expiresAt = root.expiresAt ?? null;
    if (expiresAt !== null && !Number.isInteger(expiresAt)) return null;
    if (expiresAt !== null && expiresAt <= Math.floor(Date.now() / 1000) + LOGIN_EXPIRY_MARGIN_S) return null;
    return token;
  } catch {
    return null;
  }
}

function loginToken(): string | null {
  for (const path of loginFilePaths()) {
    if (existsSync(path)) return tokenInLoginFile(path);
  }
  return null;
}

const token = process.env.VERCEL_TOKEN || loginToken();
if (!token) refuse("no Vercel login: set VERCEL_TOKEN, or log in with the Vercel CLI; the token is never printed");
if (!existsSync(FX)) refuse("build first with `zig build`; this check runs ./zig-out/bin/fx only");

type Answer = { status: number; json: any };

async function api(method: string, path: string, body?: unknown): Promise<Answer> {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: response.status, json };
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

// The top-level key names of a reply or an entry, sorted. Never values, and never the nested keys of an entry.
function keysOf(value: unknown): string {
  return isRecord(value) ? Object.keys(value).sort().join(",") : "not an object";
}

// The runner's own `fx:` lines. Only those are printed, so no other stderr text reaches the output.
function fxLines(text: string): string {
  return text
    .split("\n")
    .filter((line) => line.startsWith("fx:"))
    .join("\n");
}

const user = await api("GET", "/v2/user");
if (user.status !== 200 || typeof user.json?.user?.id !== "string") refuse(`the login did not return a user (HTTP ${user.status})`);
const userId: string = user.json.user.id;
const team = await api("GET", `/v2/teams/${encodeURIComponent(teamSlug)}`);
if (team.status !== 200 || typeof team.json?.id !== "string") refuse(`team ${teamSlug} was not found (HTTP ${team.status})`);
const teamId: string = team.json.id;
const project = await api("GET", `/v9/projects/${encodeURIComponent(projectName)}?teamId=${encodeURIComponent(teamId)}`);
if (project.status !== 200 || typeof project.json?.id !== "string") refuse(`project ${projectName} was not found (HTTP ${project.status})`);
const projectId: string = project.json.id;

const digest = createHash("sha256").update(token).digest("hex");
const hostKey = createHash("sha256").update(`${userId}\n${hostname()}`).digest("hex").slice(0, 8);
const isolatedPrefix = `fx-iso-${hostKey}-`;

// Resolved once: $TMPDIR is a link on macOS (/var is /private/var), and the runner refuses a link in its state path (N1).
const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-live-")));
const repo = join(home, "repo");
mkdirSync(repo);
writeFileSync(join(repo, "README.md"), "live\n");
const git = (args: string[]) => Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "ignore", stderr: "ignore" });
git(["init", "-q"]);
git(["add", "-A"]);
git(["-c", "user.name=live", "-c", "user.email=live@example.com", "commit", "-qm", "live"]);
const root = realpathSync(repo);
const repoKey = createHash("sha256").update(`${userId}\n${root}`).digest("hex").slice(0, 16);
const remoteName = `fx-${repoKey}`;
const stateDir = join(home, "state", repoKey);
mkdirSync(stateDir, { recursive: true });

const childEnv: Record<string, string | undefined> = { ...process.env, VERCEL_TOKEN: token, FX_SOUND: "0" };
delete childEnv.FX_TEST_VERCEL_API_URL;

function runnerArgs(mode: "remote" | "isolated", vcpus: number, extra: string[], command: string): string[] {
  return [
    "__fx_runner__", "run",
    "--contract", "1", "--mode", mode,
    "--root", root, "--cwd", root, "--state", stateDir,
    "--team", teamId, "--project", projectId, "--token-sha256", digest,
    "--team-slug", teamSlug!, "--project-name", projectName!, "--user-id", userId,
    "--grace-ms", "5000", "--timeout-ms", "600000", "--vcpus", String(vcpus),
    ...extra, "--", command,
  ];
}

async function runOnce(args: string[], stopAfterMs?: number, env: Record<string, string | undefined> = childEnv) {
  const started = Date.now();
  const child = Bun.spawn([FX, ...args], { cwd: root, env, stdout: "pipe", stderr: "pipe" });
  const timer = stopAfterMs === undefined ? undefined : setTimeout(() => child.kill("SIGTERM"), stopAfterMs);
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (timer) clearTimeout(timer);
  return { code, stdout, stderr, elapsedMs: Date.now() - started };
}

async function sandboxNames(): Promise<Set<string> | null> {
  const listing = await api("GET", `/v2/sandboxes?project=${projectId}&teamId=${teamId}`);
  if (listing.status !== 200 || !Array.isArray(listing.json?.sandboxes)) return null;
  return new Set<string>(listing.json.sandboxes.map((item: { name: string }) => item.name));
}

function sandboxInfo(): Record<string, any> {
  const path = join(stateDir, "sandbox.json");
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
}

const results: Array<{ item: string; status: "PASS" | "FAIL"; evidence: string }> = [];
// On a failure, the runner's own `fx:` lines are printed under the item, so the cause shows next to it.
function record(item: string, pass: boolean, evidence: string, runnerStderr = "") {
  const status = pass ? "PASS" : "FAIL";
  results.push({ item, status, evidence });
  console.log(`${status} ${item}: ${evidence}`);
  const lines = pass ? "" : fxLines(runnerStderr);
  if (lines) console.log(lines);
}

async function teamPages(): Promise<{ pass: boolean; evidence: string }> {
  const first = await api("GET", "/v2/teams?limit=1");
  if (first.status !== 200) return { pass: false, evidence: `page 1 HTTP ${first.status}` };
  const next = first.json?.pagination?.next;
  if (next === null || next === undefined) {
    return { pass: false, evidence: `page 1 has no pagination.next, so no second page exists; the account needs at least two teams` };
  }
  const second = await api("GET", `/v2/teams?limit=1&until=${encodeURIComponent(String(next))}`);
  if (second.status !== 200) return { pass: false, evidence: `page 2 HTTP ${second.status}` };
  const parses = (page: Answer) =>
    Array.isArray(page.json?.teams) &&
    page.json.teams.length >= 1 &&
    page.json.teams.every((item: any) => typeof item?.id === "string" && typeof item?.slug === "string" && typeof item?.name === "string") &&
    typeof page.json?.pagination === "object";
  const ok = parses(first) && parses(second);
  return {
    pass: ok,
    evidence: `page 1 keys ${keysOf(first.json)}; page 2 keys ${keysOf(second.json)}; team entry keys ${keysOf(first.json.teams[0])}; parse ${ok ? "ok" : "failed"}`,
  };
}

const initial = await sandboxNames();
try {
  // Item 0: a fake token gets 403 from Vercel, so no account is used. The run must refuse with N11 (V13).
  // N11 does not print Vercel's body; the body reading is covered by the unit and E2E tests.
  const probeToken = "vca_probe";
  const probeState = join(home, "state", createHash("sha256").update("live-probe").digest("hex").slice(0, 16));
  mkdirSync(probeState, { recursive: true });
  const probe = await runOnce(
    [
      "__fx_runner__", "run",
      "--contract", "1", "--mode", "remote",
      "--root", root, "--cwd", root, "--state", probeState,
      "--team", "team_probe", "--project", "prj_probe", "--token-sha256", createHash("sha256").update(probeToken).digest("hex"),
      "--team-slug", "probe", "--project-name", "fx-live-probe", "--user-id", "user_probe",
      "--grace-ms", "5000", "--timeout-ms", "60000", "--vcpus", "2",
      "--", "echo probe",
    ],
    undefined,
    { ...childEnv, VERCEL_TOKEN: probeToken },
  );
  const n11 = probe.stderr.includes("fx: did not run: Vercel rejected the login (403). Run `vercel whoami` or `vercel login`.");
  record(
    "0 a login Vercel rejects over TLS is refused with N11",
    probe.code === 125 && n11,
    `exit ${probe.code}; ${n11 ? "the N11 line came back for HTTP 403" : "the N11 line is missing"}`,
    probe.stderr,
  );

  const pages = await teamPages();
  record("1 setup discovery with a second teams page", pages.pass, pages.evidence);

  const create = await runOnce(runnerArgs("remote", 4, [], "echo live-create"));
  const namedRight = sandboxInfo().name === remoteName;
  record(
    "2 create",
    create.code === 0 && create.stdout.includes("live-create") && namedRight,
    `exit ${create.code}; output ${create.stdout.includes("live-create") ? "arrived" : "is missing"}; sandbox.json name ${namedRight ? "matches" : "does not match"} the key fx computes`,
    create.stderr,
  );

  const beforeStop = sandboxInfo().session_id;
  if (typeof beforeStop !== "string") {
    record("3 stop and resume", false, "sandbox.json has no session_id to stop");
  } else {
    const stop = await api("POST", `/v2/sandboxes/sessions/${encodeURIComponent(beforeStop)}/stop?teamId=${teamId}`);
    const resumed = await runOnce(runnerArgs("remote", 4, [], "echo live-resume"));
    const afterSession = sandboxInfo().session_id;
    record(
      "3 stop and resume",
      stop.status >= 200 && stop.status < 300 && resumed.code === 0 && resumed.stdout.includes("live-resume") && afterSession !== beforeStop,
      `stop HTTP ${stop.status}; the run after it exit ${resumed.code}; a new session id is ${afterSession !== beforeStop ? "in" : "not in"} sandbox.json`,
      resumed.stderr,
    );
  }

  const kill = await runOnce(runnerArgs("remote", 4, [], "sleep 120"), 8000);
  record("4 command kill", kill.code === 143, `exit ${kill.code} after SIGTERM to the runner (143 expected)`, kill.stderr);

  const quiet = await runOnce(runnerArgs("remote", 4, [], "sleep 350; echo after-idle"));
  record(
    "5 reattach after an idle close",
    quiet.code === 0 && quiet.stdout.includes("after-idle") && quiet.elapsedMs >= 340_000,
    `exit ${quiet.code} after ${Math.round(quiet.elapsedMs / 1000)} s; output ${quiet.stdout.includes("after-idle") ? "arrived" : "is missing"}`,
    quiet.stderr,
  );

  const currentSession = sandboxInfo().session_id;
  if (typeof currentSession !== "string") {
    record("6 extend-timeout", false, "sandbox.json has no session_id to extend");
  } else {
    const extend = await api("POST", `/v2/sandboxes/sessions/${encodeURIComponent(currentSession)}/extend-timeout?teamId=${teamId}`, { duration: 1800000 });
    // A key list is a floor, not an exact match. The check fails when a key fx reads (the session's id, startedAt
    // and timeout, as sandbox.zig reads them) or a key the fake serves is missing from the real answer. Keys the real
    // answer has beyond those are information only, so a new Vercel field never fails a release check. Names only.
    const needTop = ["session"];
    const fakeSessionKeys = ["architecture", "createdAt", "cwd", "id", "interactivePort", "memory", "projectId", "region", "requestedAt", "runtime", "sourceSandboxName", "sourceSnapshotId", "startedAt", "status", "timeout", "updatedAt", "vcpus", "workloadType"];
    const needSession = [...new Set([...fakeSessionKeys, "id", "startedAt", "timeout"])];
    const realTop = isRecord(extend.json) ? Object.keys(extend.json) : null;
    const realSession = realTop !== null && isRecord(extend.json.session) ? Object.keys(extend.json.session) : null;
    const absent = (real: string[] | null, need: string[]) => (real === null ? need : need.filter((key) => !real.includes(key)));
    const extra = (real: string[] | null, need: string[]) => (real === null ? [] : real.filter((key) => !need.includes(key)));
    const named = (keys: string[]) => (keys.length === 0 ? "none" : keys.join(","));
    const missingTop = absent(realTop, needTop);
    const missingSession = absent(realSession, needSession);
    record(
      "6 extend-timeout",
      extend.status === 200 && missingTop.length === 0 && missingSession.length === 0,
      `HTTP ${extend.status}; missing top-level keys ${named(missingTop)}; missing session keys ${named(missingSession)}; extra top-level keys (information) ${named(extra(realTop, needTop))}; extra session keys (information) ${named(extra(realSession, needSession))}`,
    );
  }

  const before = await sandboxNames();
  const isolated = await runOnce(runnerArgs("isolated", 4, ["--profile", "media", "--network", "deny-all"], "echo iso-live"));
  const after = await sandboxNames();
  const leftovers = after && before ? [...after].filter((name) => !before.has(name) && name.startsWith(isolatedPrefix)) : null;
  record(
    "7 isolated create and delete",
    isolated.code === 0 && isolated.stdout.includes("iso-live") && leftovers?.length === 0,
    `exit ${isolated.code}; isolated sandboxes left after the run: ${leftovers === null ? "listing failed" : leftovers.length}`,
    isolated.stderr,
  );

  const first = await runOnce(runnerArgs("remote", 8, ["--bring-back", "out"], "mkdir -p out && echo first > out/live.txt"));
  const second = await runOnce(runnerArgs("remote", 4, ["--bring-back", "out"], "mkdir -p out && echo second > out/live.txt"));
  const brought = existsSync(join(root, "out", "live.txt")) ? readFileSync(join(root, "out", "live.txt"), "utf8") : "missing";
  const size = sandboxInfo().vcpus;
  record(
    "8 vcpus 8, then PATCH to 4, with a bring-back",
    first.code === 0 && second.code === 0 && brought === "second\n" && size === 4,
    `exits ${first.code} and ${second.code}; brought back ${brought === "second\n" ? "the second run's file" : "a different file or none"}; sandbox.json vcpus ${String(size)}`,
    `${first.stderr}${second.stderr}`,
  );
} finally {
  const now = await sandboxNames();
  if (initial === null || now === null) {
    console.log("cleanup: the project listing failed, so no sandbox was deleted; check the project by hand");
  } else {
    const mine = (name: string) => name === remoteName || name.startsWith(isolatedPrefix);
    for (const name of [...now].filter((item) => !initial.has(item) && mine(item))) {
      const deleted = await api("DELETE", `/v2/sandboxes/${encodeURIComponent(name)}?projectId=${projectId}&teamId=${teamId}`);
      console.log(`deleted ${name}: HTTP ${deleted.status}`);
    }
    const others = [...now].filter((item) => !initial.has(item) && !mine(item)).length;
    console.log(`cleanup: ${others} new sandbox(es) in the project are not fx's names for this run and were left alone`);
  }
  rmSync(home, { recursive: true, force: true });
}

const failed = results.filter((result) => result.status === "FAIL");
console.log(`summary: ${results.length - failed.length} pass, ${failed.length} fail`);
process.exit(failed.length === 0 ? 0 : 1);
