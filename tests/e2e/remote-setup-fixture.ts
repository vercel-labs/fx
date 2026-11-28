import { expect } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type FakeVercelApi, type FakeVercelUser, startFakeVercelApi } from "./fixtures/fake-vercel-api";

// The built-in runner's login and in-chat setup, for the sandbox tests.
// fx reads `fakeLoginToken` as VERCEL_TOKEN. While FX_TEST_VERCEL_API_URL is
// honored, fx sends `fakeApiToken` instead of the login (spec AC-30), so the fake
// answers the user check with 200, and any other token with 403.

/** The value fx reads as VERCEL_TOKEN. It is fake, and the fake API refuses it. */
export const fakeLoginToken = "fx-test-login";

/** The token the fake API signs in. fx sends it while its test override is honored. */
export const fakeApiToken = "fx-test-token";

export type SetupProject = { id: string; name: string };
export type SetupTeam = { id: string; slug: string; name: string; projects: SetupProject[] };

export const fakeTeam: SetupTeam = {
  id: "team_fx_test",
  slug: "fx-test-team",
  name: "fx test team",
  projects: [{ id: "prj_fx_test", name: "fx-test-project" }],
};

export const fakeSecondTeam: SetupTeam = {
  id: "team_fx_second",
  slug: "fx-second-team",
  name: "fx second team",
  projects: [{ id: "prj_fx_second", name: "fx-second-project" }],
};

export const fakeUser: FakeVercelUser = {
  id: "user_fx_test",
  username: "fx-test",
  email: "fx-test@example.com",
  defaultTeamId: fakeTeam.id,
};
export const fakeOtherUser: FakeVercelUser = {
  id: "user_fx_other",
  username: "fx-other",
  email: "fx-other@example.com",
  defaultTeamId: fakeTeam.id,
};

export type RemoteSetupFixture = {
  api: FakeVercelApi;
  /** The environment of an fx process: its login, and the fake's loopback URL. */
  env: Record<string, string>;
  /** The config's remote section for one team and project of the fake, for a user. */
  remoteFor(team: SetupTeam, project: SetupProject, userId?: string): Record<string, string>;
  /** The remote section for the first team and its first project. */
  remote: Record<string, string>;
  stop(): void;
};

/** Computes `{fx_home}/sandbox/state/{repoKey}` matching `consent.repoKey`. */
export function repoKeyFor(userId: string, repoRoot: string): string {
  const canonical = realpathSync(repoRoot);
  return createHash("sha256").update(`${userId}\n${canonical}`).digest("hex").slice(0, 16);
}

/** Writes `{home}/.fx/sandbox/state/{repoKey}/consent.json` for a repository and destination. */
export function seedConsent(
  home: string,
  userId: string,
  repoRoot: string,
  teamId: string,
  projectId: string,
): void {
  const key = repoKeyFor(userId, repoRoot);
  const stateDir = join(realpathSync(home), ".fx", "sandbox", "state", key);
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(stateDir, "consent.json"),
    `${JSON.stringify({
      version: 1,
      team_id: teamId,
      project_id: projectId,
      confirmed_at: "2026-11-22T10:00:00Z",
    })}\n`,
    { mode: 0o600 },
  );
}

/** Writes Vercel CLI `auth.json` and optional `config.json` (`currentTeam`) in `home`. */
export function writeCliLoginAndTeam(
  home: string,
  options: { token?: string; currentTeam?: string } = {},
): void {
  const token = options.token ?? fakeLoginToken;
  for (const dir of [
    join(home, ".local", "share", "com.vercel.cli"),
    join(home, "Library", "Application Support", "com.vercel.cli"),
  ]) {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "auth.json"), JSON.stringify({ token }));
    if (options.currentTeam !== undefined) {
      writeFileSync(join(dir, "config.json"), JSON.stringify({ currentTeam: options.currentTeam }));
    }
  }
}

/** Starts a fake Vercel API. Stop it with `stop` when the test ends. */
export function startRemoteSetupFixture(
  options: { teams?: SetupTeam[]; user?: FakeVercelUser; macRoots?: string[]; padding?: { team: number; project: number } } = {},
): RemoteSetupFixture {
  const teams = options.teams ?? [fakeTeam];
  const user = options.user ?? fakeUser;
  const privateRoot = mkdtempSync(join(tmpdir(), "fx-remote-setup-"));
  const api = startFakeVercelApi({
    users: { [fakeApiToken]: user },
    teams: teams.map(({ id, slug, name }) => ({ id, slug, name })),
    projects: Object.fromEntries(teams.map((team) => [team.id, team.projects])),
    privateRoot,
    macRoots: options.macRoots,
    padding: options.padding,
    testToken: fakeApiToken,
  });
  const remoteFor = (team: SetupTeam, project: SetupProject, userId = user.id) => ({
    backend: "vercel",
    team_id: team.id,
    team_slug: team.slug,
    project_id: project.id,
    project_name: project.name,
    user_id: userId,
    confirmed_at: "2026-11-22T10:00:00Z",
  });
  return {
    api,
    env: { VERCEL_TOKEN: fakeLoginToken, FX_TEST_VERCEL_API_URL: api.url },
    remoteFor,
    remote: remoteFor(teams[0]!, teams[0]!.projects[0]!),
    stop() {
      api.stop();
      rmSync(privateRoot, { recursive: true, force: true });
    },
  };
}

/**
 * Checks, once per file, what the fake saw. The fake logs statuses, not
 * headers, so the proof is by status: the user check was answered, every
 * answer was a success (the fake signs in only the test token, so each
 * success carried it), no request was refused, and the login never appears.
 */
export function expectRemoteLoginNeverSent(api: FakeVercelApi): void {
  const userChecks = api.log.filter((entry) => entry.route === "user");
  expect(userChecks.length).toBeGreaterThan(0);
  expect(userChecks.map((entry) => entry.status)).toEqual(userChecks.map(() => 200));
  expect(api.log.filter((entry) => entry.status === 401 || entry.status === 403)).toEqual([]);
  expect(JSON.stringify(api.log)).not.toContain(fakeLoginToken);
}
