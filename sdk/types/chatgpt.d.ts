// `libfx/chatgpt` (chatgpt-sign-in.js): sign in with ChatGPT for a Codex agent.
import type { FxProviderCredentials, FxFetch } from "./libfx.cjs";

/** Options every network step accepts. */
export interface ChatgptRequestOptions {
  /** Replaces the global `fetch` for OpenAI's sign-in endpoints. */
  fetch?: FxFetch;
  signal?: AbortSignal;
}

/** A sign-in in progress. Keep it on the server: `verifier` is secret. */
export interface ChatgptSignIn {
  /** Where the user signs in. Afterwards OpenAI opens an address at localhost:1455 that does not load; the user pastes it back. */
  readonly url: string;
  readonly state: string;
  readonly verifier: string;
}

/** A device code sign-in in progress. Plain data, so a later request can poll it. */
export interface ChatgptDeviceSignIn {
  /** Where the user enters `userCode`. */
  readonly verificationUrl: string;
  readonly userCode: string;
  readonly deviceAuthId: string;
  /** How often to poll, in milliseconds. */
  readonly intervalMs: number;
  /** Milliseconds since the epoch. */
  readonly expiresAt: number;
}

/** The `code` of an error from this module. */
export type ChatgptSignInErrorCode =
  | "LIBFX_CHATGPT_SIGN_IN_INVALID_ADDRESS"
  | "LIBFX_CHATGPT_SIGN_IN_STATE_MISMATCH"
  | "LIBFX_CHATGPT_SIGN_IN_DENIED"
  | "LIBFX_CHATGPT_SIGN_IN_EXPIRED"
  | "LIBFX_CHATGPT_SIGN_IN_FAILED"
  | "LIBFX_CHATGPT_DEVICE_CODE_UNAVAILABLE"
  | "LIBFX_CHATGPT_DEVICE_CODE_EXPIRED"
  | "LIBFX_CHATGPT_REFRESH_FAILED";

/** Starts a sign-in where the user pastes back the address OpenAI opens. */
export declare function startSignIn(): Promise<ChatgptSignIn>;

/** Finishes a sign-in from the pasted address, its query, or either wrapped in quotes or backticks. */
export declare function finishSignIn(signIn: ChatgptSignIn, address: string, options?: ChatgptRequestOptions): Promise<FxProviderCredentials>;

/** Starts a device code sign-in. The account or workspace must allow device code sign-in. */
export declare function startDeviceSignIn(options?: ChatgptRequestOptions): Promise<ChatgptDeviceSignIn>;

/** Checks once: credentials after the user entered the code, otherwise null. */
export declare function pollDeviceSignIn(device: ChatgptDeviceSignIn, options?: ChatgptRequestOptions): Promise<FxProviderCredentials | null>;

/** Waits until the user enters the code, polling at OpenAI's interval. */
export declare function completeDeviceSignIn(device: ChatgptDeviceSignIn, options?: ChatgptRequestOptions): Promise<FxProviderCredentials>;

/** Refreshes credentials. Codex agents refresh on their own; this is for hosts. */
export declare function refreshCredentials(credentials: FxProviderCredentials, options?: ChatgptRequestOptions): Promise<FxProviderCredentials>;
