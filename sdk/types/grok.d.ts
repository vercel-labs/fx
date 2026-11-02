// `libfx/grok` (grok-sign-in.js): sign in with a Grok plan for a Grok agent.
import type { FxProviderCredentials, FxFetch } from "./libfx.cjs";

/** Options every network step accepts. */
export interface GrokRequestOptions {
  /** Replaces the global `fetch` for xAI's sign-in endpoints. */
  fetch?: FxFetch;
  signal?: AbortSignal;
}

/** A sign-in in progress. Keep it on the server: `verifier` is secret. */
export interface GrokSignIn {
  /** Where the user signs in. Afterwards xAI opens an address at `redirectUri` that does not load; the user pastes it back. */
  readonly url: string;
  readonly state: string;
  readonly verifier: string;
  readonly redirectUri: string;
}

/** A device code sign-in in progress. Plain data, so a later request can poll it. */
export interface GrokDeviceSignIn {
  /** Where the user enters `userCode`. */
  readonly verificationUrl: string;
  readonly userCode: string;
  readonly deviceCode: string;
  /** How often to poll, in milliseconds. */
  readonly intervalMs: number;
  /** Milliseconds since the epoch. */
  readonly expiresAt: number;
}

/** The `code` of an error from this module. */
export type GrokSignInErrorCode =
  | "LIBFX_GROK_SIGN_IN_INVALID_ADDRESS"
  | "LIBFX_GROK_SIGN_IN_STATE_MISMATCH"
  | "LIBFX_GROK_SIGN_IN_DENIED"
  | "LIBFX_GROK_SIGN_IN_EXPIRED"
  | "LIBFX_GROK_SIGN_IN_FAILED"
  | "LIBFX_GROK_DEVICE_CODE_UNAVAILABLE"
  | "LIBFX_GROK_DEVICE_CODE_EXPIRED"
  | "LIBFX_GROK_ACCOUNT_UNAVAILABLE"
  | "LIBFX_GROK_ACCOUNT_CHANGED"
  | "LIBFX_GROK_REFRESH_FAILED";

/** Starts a sign-in where the user pastes back the address xAI opens. */
export declare function startSignIn(): Promise<GrokSignIn>;

/** Finishes a sign-in from the pasted address, its query, or either wrapped in quotes or backticks. */
export declare function finishSignIn(signIn: GrokSignIn, address: string, options?: GrokRequestOptions): Promise<FxProviderCredentials>;

/** Starts a device code sign-in. */
export declare function startDeviceSignIn(options?: GrokRequestOptions): Promise<GrokDeviceSignIn>;

/** Checks once: credentials after the user entered the code, otherwise null. */
export declare function pollDeviceSignIn(device: GrokDeviceSignIn, options?: GrokRequestOptions): Promise<FxProviderCredentials | null>;

/** Waits until the user enters the code, polling at xAI's interval. */
export declare function completeDeviceSignIn(device: GrokDeviceSignIn, options?: GrokRequestOptions): Promise<FxProviderCredentials>;

/** Refreshes credentials. Grok agents refresh on their own; this is for hosts. */
export declare function refreshCredentials(credentials: FxProviderCredentials, options?: GrokRequestOptions): Promise<FxProviderCredentials>;
