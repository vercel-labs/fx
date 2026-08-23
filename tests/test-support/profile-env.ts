import { existsSync } from "node:fs";
import { join } from "node:path";

export const XDG_ENV_KEYS = [
  "XDG_CONFIG_HOME",
  "XDG_STATE_HOME",
  "XDG_DATA_HOME",
] as const;

export function xdgEnvForHome(
  home: string | undefined,
): Record<string, string | undefined> {
  if (!home) {
    return Object.fromEntries(XDG_ENV_KEYS.map((key) => [key, undefined]));
  }
  return {
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_STATE_HOME: join(home, ".local", "state"),
    XDG_DATA_HOME: join(home, ".local", "share"),
  };
}

export function fxProfileRoots(
  home: string,
): { config: string; state: string; data: string } {
  const legacy = join(home, ".fx");
  if (process.platform !== "linux" || existsSync(legacy)) {
    return { config: legacy, state: legacy, data: legacy };
  }
  return {
    config: join(home, ".config", "fx"),
    state: join(home, ".local", "state", "fx"),
    data: join(home, ".local", "share", "fx"),
  };
}
