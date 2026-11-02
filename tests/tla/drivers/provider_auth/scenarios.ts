// Scenarios that drive the real credential edge through the interleavings
// ProviderAuth models. Each names the model setup it runs under, so its trace
// replays against exactly those constants.
import type { Setup } from "./tlc";
import type { World } from "./driver";

type Provider = Setup["provider"];

export interface Scenario {
  name: string;
  setup: Setup;
  script: (world: World) => Promise<void>;
  accounts?: string[];
  /** The property verdicts this trace must reach; omitted ones must hold. */
  expect?: Record<string, "VIOLATED">;
}

const base = { expiring: false, rejecting: false, foreignRefresh: false, checkAccount: true, scopeAll: false, noSingleFlight: false };
const one = (url: "provider" | "other" = "provider") => [{ id: "r1", engine: "e1", url }];
const sameEngine = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e1", url: "provider" as const }];
const twoEngines = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e2", url: "provider" as const }];
const withOther = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e1", url: "other" as const }];

const alone = async (world: World) => { await world.send("r1"); };
const together = async (world: World) => { await Promise.all([world.send("r1"), world.send("r2")]); };
const inTurn = async (world: World) => { await world.send("r1"); await world.send("r2"); };

/** r2 leaves with the rejected token, and its 401 comes back only after r1's refresh saved. */
const lateRejection = async (world: World) => {
  world.hold("r2");
  const second = world.send("r2");
  await world.arrived("r2");
  await world.send("r1");
  world.release("r2");
  await second;
};

export function scenarios(provider: Provider): Scenario[] {
  if (provider === "custom") {
    return [
      { name: "custom-key-on-chat-url", setup: { ...base, provider, requests: one() }, script: alone },
      { name: "custom-other-url-bypasses", setup: { ...base, provider, requests: withOther }, script: inTurn },
      { name: "custom-rejected-key-not-refreshed", setup: { ...base, provider, requests: one(), rejecting: true }, script: alone },
      { name: "custom-two-sessions", setup: { ...base, provider, requests: twoEngines, rejecting: true }, script: together },
    ];
  }
  const list: Scenario[] = [
    { name: `${provider}-fresh`, setup: { ...base, provider, requests: one() }, script: alone },
    { name: `${provider}-expiring-refreshes-first`, setup: { ...base, provider, requests: one(), expiring: true }, script: alone },
    { name: `${provider}-rejected-refreshes-once`, setup: { ...base, provider, requests: one(), rejecting: true }, script: alone },
    { name: `${provider}-other-url-bypasses`, setup: { ...base, provider, requests: withOther, expiring: true }, script: inTurn },
    { name: `${provider}-one-session-shares-refresh`, setup: { ...base, provider, requests: sameEngine, expiring: true }, script: together },
    { name: `${provider}-one-session-after-save`, setup: { ...base, provider, requests: sameEngine, expiring: true }, script: inTurn },
    {
      name: `${provider}-two-sessions-near-expiry`, setup: { ...base, provider, requests: twoEngines, expiring: true }, script: together,
      expect: { NoRefreshReuse: "VIOLATED" },
    },
    {
      name: `${provider}-late-rejection-after-refresh`, setup: { ...base, provider, requests: sameEngine, rejecting: true }, script: lateRejection,
      expect: { NoRefreshReuse: "VIOLATED" },
    },
  ];
  if (provider === "grok") {
    list.push({
      name: "grok-refresh-for-another-account", setup: { ...base, provider, requests: one(), expiring: true, foreignRefresh: true },
      script: alone, accounts: ["B"],
    });
  }
  return list;
}
