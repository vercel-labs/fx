import { afterEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FX_BIN } from '../evals/eval-helpers';

const cleanup: (() => void)[] = [];
afterEach(() => { for (const close of cleanup.splice(0).reverse()) close(); });
const access = 'xoxb-test-private-access';
const refresh = 'xoxe-test-private-refresh';
function fixture() {
  const home = mkdtempSync(join(tmpdir(), 'fx-slack-'));
  cleanup.push(() => rmSync(home, { recursive: true, force: true }));
  let exchange: Record<string, any> = { ok: true, app_id: 'AFX', team: { id: 'TVERCEL' }, bot_user_id: 'WBOT', token_type: 'bot', scope: 'app_mentions:read', authed_user: { id: 'UINSTALLER', access_token: 'user-token-must-not-save' }, access_token: access, refresh_token: refresh, expires_in: 43200 };
  let identity: Record<string, any> = { ok: true, team_id: 'TVERCEL', user_id: 'WBOT', bot_id: 'BBOT' };
  let challenge = '';
  const calls: { path: string; body: URLSearchParams }[] = [];
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/api/slack/install/config') return Response.json({ client_id: '123.456', app_id: 'AFX', team_id: 'TVERCEL', scope: 'app_mentions:read', redirect_uri: 'https://fx.sh/api/slack/oauth/callback' });
    const body = new URLSearchParams(await request.text());
    calls.push({ path, body });
    if (path === '/api/oauth.v2.access') {
      expect(body.get('client_secret')).toBeNull();
      if (body.get('grant_type') === 'refresh_token') {
        expect(body.get('code_verifier')).toBeNull();
      } else {
        expect(body.get('code')).toBe('test-authorization-code');
        expect(body.get('redirect_uri')).toBe('https://fx.sh/api/slack/oauth/callback');
        expect(createHash('sha256').update(body.get('code_verifier')!).digest('base64url')).toBe(challenge);
      }
      return Response.json(exchange);
    }
    if (path === '/api/auth.test') {
      expect(request.headers.get('authorization')).toBe(`Bearer ${exchange.access_token}`);
      return Response.json(identity);
    }
    return new Response('Not found', { status: 404 });
  } });
  cleanup.push(() => server.stop(true));
  const origin = `http://127.0.0.1:${server.port}`;
  const env = { ...process.env, HOME: home, FX_NO_OPEN_BROWSER: '1', FX_E2E_SLACK_ORIGIN: origin, FX_DISABLE_KEYCHAIN: '1', FX_AUTO_UPGRADE: '0', FX_SKIP_ONBOARDING: '1', FX_SOUND: '0', AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined };
  const file = join(home, '.fx/slack/installation.json');
  function spawn(action: string) {
    const proc = Bun.spawn([FX_BIN, 'slack', action, '--json'], { env, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
    cleanup.push(() => { try { proc.kill(); } catch {} });
    let stderr = '';
    const reading = (async () => { for await (const chunk of proc.stderr) stderr += new TextDecoder().decode(chunk); })();
    const stdout = new Response(proc.stdout).text();
    return { proc, get stderr() { return stderr; }, async result() { const code = await proc.exited; await reading; return { code, stdout: await stdout, stderr }; } };
  }
  async function start() {
    const run = spawn('install');
    let url: URL | undefined;
    const until = Date.now() + 10_000;
    while (Date.now() < until) {
      const match = run.stderr.match(/Open on this computer: (\S+)/);
      if (match) { url = new URL(match[1]); break; }
      if (run.proc.exitCode !== null) throw new Error(`fx exited: ${run.stderr}`);
      await Bun.sleep(10);
    }
    if (!url) throw new Error(`No authorization URL: ${run.stderr}`);
    challenge = url.searchParams.get('challenge')!;
    const target = `http://127.0.0.1:${url.searchParams.get('port')}/slack/oauth/callback`;
    const state = url.searchParams.get('state')!;
    const post = (body: string, requestOrigin = origin) => fetch(target, { method: 'POST', headers: { origin: requestOrigin, 'content-type': 'application/x-www-form-urlencoded' }, body });
    return { run, state, post, target };
  }
  async function install() {
    const started = await start();
    const response = await started.post(new URLSearchParams({ state: started.state, code: 'test-authorization-code' }).toString());
    return { response, result: await started.run.result(), ...started };
  }
  return { home, file, calls, spawn, start, install, get exchange() { return exchange; }, set exchange(value) { exchange = value; }, get identity() { return identity; }, set identity(value) { identity = value; } };
}

test('installs through a real loopback POST, validates PKCE, and saves only bot credentials privately', async () => {
  const f = fixture();
  const { result, response } = await f.install();
  expect(result.code).toBe(0);
  expect(response.status).toBe(200);
  expect(result.stderr).not.toContain('error');
  expect(JSON.parse(result.stdout)).toMatchObject({ installed: true, team_id: 'TVERCEL', bot_user_id: 'WBOT' });
  expect(result.stdout + result.stderr + await response.text()).not.toMatch(/xoxb-test|xoxe-test|test-authorization-code/);
  expect(statSync(f.file).mode & 0o777).toBe(0o600);
  expect(statSync(join(f.home, '.fx/slack')).mode & 0o777).toBe(0o700);
  const stored = readFileSync(f.file, 'utf8');
  expect(stored).toContain(access);
  expect(stored).not.toMatch(/user-token-must-not-save|code_verifier|test-authorization-code/);
  const status = await f.spawn('status').result();
  expect(status.code).toBe(0);
  expect(status.stdout).not.toContain(access);
  expect(f.calls).toHaveLength(2);
  expect(existsSync(join(f.home, '.fx/mcp'))).toBe(false);
}, 20000);

test('wrong origin and mismatched state cannot consume the waiting CLI transaction', async () => {
  const f = fixture(), started = await f.start();
  const body = new URLSearchParams({ state: started.state, code: 'test-authorization-code' }).toString();
  expect((await started.post(body, 'https://evil.example')).status).toBe(404);
  expect((await started.post('state=wrong&code=test-authorization-code')).status).toBe(404);
  expect(f.calls).toHaveLength(0);
  expect((await started.post(body)).status).toBe(200);
  expect((await started.run.result()).code).toBe(0);
  await expect(started.post(body)).rejects.toThrow();
  expect(f.calls.filter((r) => r.path.endsWith('oauth.v2.access'))).toHaveLength(1);
}, 20000);

test('denied consent and duplicate callback fields never exchange or save tokens', async () => {
  for (const duplicate of [false, true]) {
    const f = fixture(), started = await f.start();
    const body = duplicate ? `state=${started.state}&state=${started.state}&code=test-authorization-code` : `state=${started.state}&error=access_denied`;
    expect((await started.post(body)).status).toBe(400);
    expect((await started.run.result()).code).not.toBe(0);
    expect(f.calls).toHaveLength(0);
    expect(existsSync(f.file)).toBe(false);
  }
}, 20000);

test('wrong app workspace scope identity and failed exchange never save an installation', async () => {
  for (const override of [{ app_id: 'AWRONG' }, { team: { id: 'TWRONG' } }, { scope: '' }, { scope: 'app_mentions:read,chat:write' }, { bot_user_id: '' }, { token_type: 'user' }, { refresh_token: undefined }, { expires_in: -1 }, { ok: false }]) {
    const f = fixture(); f.exchange = { ...f.exchange, ...override };
    const { result } = await f.install();
    expect(result.code).not.toBe(0);
    expect(existsSync(f.file)).toBe(false);
    expect(result.stderr + result.stdout).not.toMatch(/xoxb-test|xoxe-test/);
  }
  for (const override of [{ bot_id: '' }, { team_id: 'TWRONG' }, { user_id: 'WOTHER' }]) {
    const f = fixture(); f.identity = { ...f.identity, ...override };
    expect((await f.install()).result.code).not.toBe(0);
    expect(existsSync(f.file)).toBe(false);
  }
}, 30000);

test('refresh uses local credentials and accepts omitted metadata only with matching auth.test', async () => {
  const f = fixture(); expect((await f.install()).result.code).toBe(0);
  f.exchange = { ok: true, access_token: 'rotated-access', refresh_token: 'rotated-refresh', expires_in: 43200 };
  const refreshed = await f.spawn('refresh').result();
  expect(refreshed.code).toBe(0);
  expect(f.calls[2].body.get('refresh_token')).toBe(refresh);
  expect(JSON.parse(readFileSync(f.file, 'utf8'))).toMatchObject({ access_token: 'rotated-access', refresh_token: 'rotated-refresh', installed_by: 'UINSTALLER' });
  const before = readFileSync(f.file, 'utf8');
  f.exchange.token_type = 'user';
  expect((await f.spawn('refresh').result()).code).not.toBe(0);
  expect(readFileSync(f.file, 'utf8')).toBe(before);
  delete f.exchange.token_type; f.identity.bot_id = 'BOTHER';
  expect((await f.spawn('refresh').result()).code).not.toBe(0);
  expect(readFileSync(f.file, 'utf8')).toBe(before);
}, 20000);

test('expired refresh credentials and unsafe credential files fail without token exchange', async () => {
  const f = fixture(); await f.install();
  const record = JSON.parse(readFileSync(f.file, 'utf8')); record.refresh_expires_at_ms = 1;
  writeFileSync(f.file, JSON.stringify(record));
  expect((await f.spawn('refresh').result()).code).not.toBe(0);
  expect(f.calls).toHaveLength(2);
  chmodSync(f.file, 0o644);
  expect((await f.spawn('status').result()).code).not.toBe(0);
  rmSync(f.file); symlinkSync('/dev/null', f.file);
  expect((await f.spawn('status').result()).code).not.toBe(0);
}, 20000);

test('concurrent installation cannot acquire the credential lock', async () => {
  const f = fixture(), started = await f.start();
  const other = await f.spawn('install').result();
  expect(other.code).not.toBe(0);
  expect(f.calls).toHaveLength(0);
  await started.post(`state=${started.state}&error=access_denied`);
  await started.run.result();
}, 20000);

test('status reports missing installation without contacting Slack', async () => {
  const f = fixture(); const result = await f.spawn('status').result();
  expect(result.code).toBe(0);
  expect(JSON.parse(result.stdout).installed).toBe(false);
  expect(f.calls).toHaveLength(0);
});
