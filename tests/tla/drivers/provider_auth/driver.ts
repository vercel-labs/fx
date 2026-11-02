// Runs a target worktree's real credential edge (the authorizer libfx's
// transportFetch calls) through scripted scenarios, recording each event in
// the vocabulary of ProviderAuth's `ev`. Every endpoint is a local fake; the
// fakes follow the model's rules: the issuer rotates refresh tokens and
// refuses spent ones, the provider rejects the host's first token when the
// scenario says so, and userinfo answers with a token's real account.
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Setup } from "./tlc";

export type AuthEvent =
  | { k: "ask"; r: string }
  | { k: "bypass"; r: string }
  | { k: "redeem"; e: string; rt: number; ok: boolean; acct: string }
  | { k: "verify"; e: string; at: number; acct: string }
  | { k: "save"; e: string; at: number }
  | { k: "fail"; e: string; rt: number }
  | { k: "send"; r: string; at: number; status: number };

export const NO_TOKEN = 999;

export interface Run {
  scenario: string;
  setup: Setup;
  events: AuthEvent[];
  outcomes: Record<string, string>;
  /** Anything the driver saw that the model has no event for. */
  anomalies: string[];
}

type Provider = Setup["provider"];

/** Which providers the worktree's SDK has, and how to reach its authorizer. */
export async function loadEdge(worktree: string) {
  const sdk = join(worktree, "sdk");
  if (existsSync(join(sdk, "subscription.js"))) {
    const { createSubscriptionAuthorizer, createCredentialMemory } = await import(join(sdk, "subscription.js"));
    const { codexSubscription } = await import(join(sdk, "chatgpt.js"));
    const { grokSubscription } = await import(join(sdk, "grok.js"));
    const custom = existsSync(join(sdk, "custom-provider.js")) ? await import(join(sdk, "custom-provider.js")) : null;
    return {
      shape: "subscription" as const,
      providers: ["codex", "grok", ...(custom ? ["custom"] : [])] as Provider[],
      /** A memory engines can share, when this worktree has one (the follow-up fix). */
      memory: createCredentialMemory as (() => unknown) | undefined,
      create(provider: Provider, options: { credentials: Function; onCredentials: Function; fetch: Function; memory?: unknown; refreshLock?: Function }, sessionId: () => string | undefined) {
        const specs = provider === "custom"
          ? [custom.customProviderSpec(custom.customProviderDefinition({ name: "local", baseUrl: "https://models.example/v1" }), sessionId)]
          : [codexSubscription, grokSubscription];
        const auth = createSubscriptionAuthorizer(specs, provider === "custom" ? { credentials: options.credentials, fetch: options.fetch } : options);
        return (endpoint: string, hostFetch: Function, input: string, init: RequestInit) => {
          const spec = auth.specFor(endpoint);
          return spec ? { authorized: true, response: auth.fetch(spec, endpoint, hostFetch, input, init) } : { authorized: false, response: hostFetch(input, init) };
        };
      },
    };
  }
  const { createChatgptAuthorizer, isCodexRequest } = await import(join(sdk, "chatgpt.js"));
  // Before #1210 the authorizer took the credentials callback as `chatgpt`.
  const legacy = (await Bun.file(join(sdk, "chatgpt.js")).text()).includes("createChatgptAuthorizer({ chatgpt,");
  return {
    shape: legacy ? ("chatgpt-legacy" as const) : ("chatgpt" as const),
    providers: ["codex"] as Provider[],
    memory: undefined as (() => unknown) | undefined,
    create(_provider: Provider, options: { credentials: Function; onCredentials: Function; fetch: Function }) {
      const auth = createChatgptAuthorizer(legacy
        ? { chatgpt: options.credentials, onCredentials: options.onCredentials, fetch: options.fetch }
        : options);
      return (endpoint: string, hostFetch: Function, input: string, init: RequestInit) =>
        isCodexRequest(endpoint) ? { authorized: true, response: auth.fetch(hostFetch, input, init) } : { authorized: false, response: hostFetch(input, init) };
    },
  };
}

const endpoints: Record<Provider, { provider: string; other: string; token?: string; userinfo?: string }> = {
  codex: { provider: "https://chatgpt.com/backend-api/codex/responses", other: "https://chatgpt.com/backend-api/other", token: "https://auth.openai.com/oauth/token" },
  grok: { provider: "https://cli-chat-proxy.grok.com/v1/responses", other: "https://cli-chat-proxy.grok.com/v1/other", token: "https://auth.x.ai/oauth2/token", userinfo: "https://auth.x.ai/oauth2/userinfo" },
  custom: { provider: "https://models.example/v1/chat/completions", other: "https://models.example/v1/models" },
};

const part = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
const lifetime = (fresh: boolean) => (fresh ? 10 * 24 * 3600 * 1000 : 60 * 1000);

/** Token n as each provider carries it. */
function accessToken(provider: Provider, n: number, acct: string, fresh: boolean): string {
  if (provider === "codex") {
    const exp = Math.floor((Date.now() + lifetime(fresh)) / 1000);
    return `${part({ alg: "none" })}.${part({ exp, "https://api.openai.com/auth": { chatgpt_account_id: `acct-${acct}` }, n })}.sig`;
  }
  return provider === "grok" ? `at-${n}` : `sk-${n}`;
}

function tokenNumber(provider: Provider, token: string | null | undefined): number {
  if (!token) return NO_TOKEN;
  const raw = token.replace(/^Bearer /, "");
  if (provider === "codex") {
    try { return JSON.parse(Buffer.from(raw.split(".")[1]!, "base64url").toString()).n; } catch { return -1; }
  }
  const m = /^(?:at|sk)-(\d+)$/.exec(raw);
  return m ? Number(m[1]) : -1;
}

function hostCredentials(provider: Provider, n: number, acct: string, fresh: boolean) {
  if (provider === "custom") return { apiKey: accessToken(provider, n, acct, fresh) };
  const accessTokenValue = accessToken(provider, n, acct, fresh);
  return provider === "codex"
    ? { accessToken: accessTokenValue, refreshToken: `rt-${n}` }
    : { accessToken: accessTokenValue, refreshToken: `rt-${n}`, accountId: `acct-${acct}`, expiresAt: Date.now() + lifetime(fresh) };
}

const bodyText = (init: RequestInit = {}) =>
  init.body === undefined || init.body === null ? "" : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body as Uint8Array);

/** A gate a scenario opens to let a held response through. */
function gate() {
  let open!: () => void;
  const opened = new Promise<void>((resolve) => { open = resolve; });
  return { opened, open };
}

export interface World {
  /** Starts request `r` (in `setup.requests`); resolves to its outcome. */
  send(r: string): Promise<string>;
  /** Holds the provider's answer to `r` until `release(r)`. */
  hold(r: string): void;
  release(r: string): void;
  /** Resolves once `r`'s request has reached the provider. */
  arrived(r: string): Promise<void>;
}

/**
 * Runs `script` against fresh fakes and one real authorizer per engine.
 * `accounts` lists the account each successful redemption issues, in order.
 */
export async function runScenario(
  worktree: string,
  scenario: string,
  setup: Setup,
  script: (world: World) => Promise<void>,
  options: { accounts?: string[] } = {},
): Promise<Run> {
  const edge = await loadEdge(worktree);
  if (!edge.providers.includes(setup.provider)) throw new Error(`${setup.provider} is not in this worktree`);
  const { provider } = setup;
  const events: AuthEvent[] = [];
  const anomalies: string[] = [];
  const outcomes: Record<string, string> = {};
  const accounts = [...(options.accounts ?? [])];
  const spent = new Set<number>();
  const acctOf = new Map<number, string>([[0, "A"]]);
  let issued = 0;
  let host = hostCredentials(provider, 0, "A", !setup.expiring);
  let calling: string | undefined;
  const holds = new Map<string, ReturnType<typeof gate>>();
  const arrivals = new Map<string, ReturnType<typeof gate>>();
  const arrival = (r: string) => { if (!arrivals.has(r)) arrivals.set(r, gate()); return arrivals.get(r)!; };
  // The redemption a failing refresh task ran, per engine, until its failure is recorded.
  const failing = new Map<string, number>();
  const ep = endpoints[provider];

  const authorizers = new Map<string, ReturnType<typeof edge.create>>();
  if (setup.sharedMemory && !edge.memory) throw new Error("this worktree has no shared credential memory");
  const shared = setup.sharedMemory ? edge.memory!() : undefined;
  // One lock for every engine, as servers sharing a host lock would have.
  let held: Promise<unknown> = Promise.resolve();
  const refreshLock = (_info: unknown, refresh: () => Promise<void>) => {
    const run = held.then(refresh);
    held = run.catch(() => {});
    return run;
  };
  for (const engine of new Set(setup.requests.map((r) => r.engine))) {
    const fetch = async (input: string | URL | Request, init: RequestInit = {}) => {
      const url = String((input as Request)?.url ?? input);
      if (url === ep.token) {
        const body = bodyText(init);
        const raw = provider === "codex" ? JSON.parse(body).refresh_token : new URLSearchParams(body).get("refresh_token");
        const rt = Number(/^rt-(\d+)$/.exec(String(raw))?.[1] ?? -1);
        if (spent.has(rt) || rt < 0 || rt > issued) {
          events.push({ k: "redeem", e: engine, rt, ok: false, acct: "none" });
          failing.set(engine, rt);
          return Response.json({ error: "invalid_grant", error_description: "refresh token already used" }, { status: 400 });
        }
        spent.add(rt);
        issued += 1;
        const acct = accounts.shift() ?? "A";
        acctOf.set(issued, acct);
        events.push({ k: "redeem", e: engine, rt, ok: true, acct });
        if (provider === "grok") failing.set(engine, rt);
        return Response.json({ access_token: accessToken(provider, issued, acct, true), refresh_token: `rt-${issued}`, expires_in: lifetime(true) / 1000, token_type: "Bearer" });
      }
      if (url === ep.userinfo) {
        const at = tokenNumber(provider, new Headers(init.headers).get("authorization"));
        const acct = acctOf.get(at) ?? "none";
        events.push({ k: "verify", e: engine, at, acct });
        // The task fails if the account changed; otherwise it goes on to save.
        if (acct === "A") failing.delete(engine);
        return Response.json({ sub: `acct-${acct}`, email: "user@example.com" });
      }
      anomalies.push(`authorizer fetched ${url}`);
      return new Response("unexpected", { status: 599 });
    };
    const credentials = () => {
      if (!calling) anomalies.push("credentials() ran outside a request");
      events.push({ k: "ask", r: calling ?? "?" });
      return host;
    };
    const onCredentials = (next: any) => {
      const at = tokenNumber(provider, next.accessToken);
      events.push({ k: "save", e: engine, at });
      failing.delete(engine);
      host = next;
    };
    authorizers.set(engine, edge.create(provider, { credentials, onCredentials, fetch, ...(shared ? { memory: shared } : {}), ...(setup.lock ? { refreshLock } : {}) }, () => calling));
  }

  const providerFetch = async (input: string, init: RequestInit = {}) => {
    const url = new URL(input);
    const r = url.searchParams.get("r")!;
    arrival(r).open();
    await holds.get(r)?.opened;
    const at = tokenNumber(provider, new Headers(init.headers).get("authorization"));
    const status = at === 0 && setup.rejecting ? 401 : 200;
    events.push({ k: "send", r, at, status });
    return new Response(status === 200 ? "ok" : JSON.stringify({ error: "rejected" }), { status });
  };

  const world: World = {
    async send(r) {
      const request = setup.requests.find((q) => q.id === r)!;
      const endpoint = request.url === "provider" ? ep.provider : ep.other;
      const route = authorizers.get(request.engine)!;
      calling = r;
      const { authorized, response } = route(endpoint, providerFetch, `${endpoint}?r=${r}`, { method: "POST", headers: { "content-type": "application/json" } });
      calling = undefined;
      if (!authorized) events.push({ k: "bypass", r });
      try {
        const answered = await response;
        outcomes[r] = `status ${answered.status}`;
      } catch (error) {
        const rt = failing.get(request.engine);
        if (rt !== undefined) {
          events.push({ k: "fail", e: request.engine, rt });
          failing.delete(request.engine);
        }
        outcomes[r] = `error ${(error as Error)?.message ?? error}`;
      }
      return outcomes[r]!;
    },
    hold(r) { holds.set(r, gate()); },
    release(r) { holds.get(r)?.open(); },
    arrived(r) { return arrival(r).opened; },
  };
  await script(world);
  // `bypass` is recorded after the call returns; the model records it on entry.
  for (let n = 0; n < events.length; n++) {
    const event = events[n]!;
    if (event.k !== "bypass") continue;
    const sendAt = events.findIndex((x, m) => m < n && x.k === "send" && x.r === event.r);
    if (sendAt >= 0) { events.splice(n, 1); events.splice(sendAt, 0, event); }
  }
  return { scenario, setup, events, outcomes, anomalies };
}

/** The observed run as a TLA+ module, with the model's constants fixed. */
export function observedModule(run: Run, constants: string): string {
  const val = (v: unknown) => (typeof v === "string" ? `"${v.replace(/[^a-z0-9_-]/gi, "")}"` : typeof v === "boolean" ? (v ? "TRUE" : "FALSE") : String(v));
  const record = (event: AuthEvent) => `[${Object.entries(event).map(([key, value]) => `${key} |-> ${val(value)}`).join(", ")}]`;
  return [
    "---- MODULE AuthObserved ----",
    `(* Generated from a real run: ${run.scenario}. *)`,
    constants,
    `Observed == << ${run.events.map(record).join(",\n  ")} >>`,
    "====",
    "",
  ].join("\n");
}
