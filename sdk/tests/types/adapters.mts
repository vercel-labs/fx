// The MCP and skills adapters, as the README combines them with an agent.
import { createFxAgent, type FxProviderCredentials } from "libfx";
import {
  completeDeviceSignIn,
  finishSignIn,
  pollDeviceSignIn,
  refreshCredentials,
  startDeviceSignIn,
  startSignIn,
  type ChatgptDeviceSignIn,
  type ChatgptSignIn,
  type ChatgptSignInErrorCode,
} from "libfx/chatgpt";
import * as grok from "libfx/grok";
import type { GrokDeviceSignIn, GrokSignIn, GrokSignInErrorCode } from "libfx/grok";
import { createMcpAdapter, type McpAdapter, type McpClient } from "libfx/mcp";
import { createSkillsAdapter, type SkillRecord } from "libfx/skills";
import { createSkillsAdapter as createSkillsAdapterFromNode, loadSkillFile, type LoadedSkill } from "libfx/skills/node";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const apiKey: string;
declare const model: string;

// Shaped like the MCP TypeScript SDK v1 `Client`.
const client = {
  async listTools(params?: { cursor?: string }) {
    return { tools: [{ name: "search_issues", description: "Search issues.", inputSchema: { type: "object" as const, properties: {} } }], nextCursor: params?.cursor };
  },
  async callTool(params: { name: string; arguments?: Record<string, unknown> }, resultSchema?: object, options?: { signal?: AbortSignal; timeout?: number }) {
    return { content: [{ type: "text", text: `${params.name} ${String(resultSchema)} ${String(options?.timeout)}` }], isError: false };
  },
  async readResource(params: { uri: string }) {
    return { contents: [{ uri: params.uri, text: "Use the issue template." }] };
  },
  async getPrompt(params: { name: string; arguments?: Record<string, string> }) {
    return { messages: [{ role: "user", content: { type: "text", text: params.name } }] };
  },
  async close() {},
};

export async function mcp(): Promise<void> {
  const adapter = await createMcpAdapter(client, {
    prefix: "github_",
    resources: ["repo://instructions"],
    prompts: ["review", { name: "triage", arguments: { label: "bug" } }],
  });
  assertType<Equal<typeof adapter, McpAdapter>>();

  const agent = createFxAgent({
    apiKey,
    model,
    tools: adapter.tools,
    instructions: adapter.instructions,
  });

  await agent.close();
  await adapter.close();

  const minimal: McpClient = { listTools: async () => [], callTool: async () => ({ content: [] }) };
  await createMcpAdapter(minimal);
  // @ts-expect-error an MCP client needs callTool()
  await createMcpAdapter({ listTools: async () => [] });
}

export async function skills(): Promise<void> {
  const record = await loadSkillFile("./skills/review/SKILL.md");
  assertType<Equal<typeof record, LoadedSkill>>();
  assertType<Equal<typeof record.description, string>>();
  const skills = createSkillsAdapter([record]);
  const agent = createFxAgent({ apiKey, model, ...skills });
  await agent.close();

  const records: SkillRecord[] = [
    { name: "release", instructions: "Write release notes.", description: "Release notes", resources: [{ uri: "doc://style", text: "Be brief." }] },
  ];
  createSkillsAdapterFromNode(records);
  await loadSkillFile("./SKILL.md", { readFile: async () => "---\nname: x\n---\nBody", resources: [], tools: [] });

  // @ts-expect-error a skill record needs instructions
  createSkillsAdapter([{ name: "review" }]);
}

// Sign in with ChatGPT on a website: start in one request, finish in another.
declare const sessionStore: { put(value: ChatgptSignIn): void; take(): ChatgptSignIn };
export async function chatgptSignIn(pastedAddress: string): Promise<FxProviderCredentials> {
  const signIn = await startSignIn();
  sessionStore.put(signIn);
  const credentials = await finishSignIn(sessionStore.take(), pastedAddress);
  // @ts-expect-error finishSignIn() needs the sign-in startSignIn() returned
  await finishSignIn({ url: signIn.url }, pastedAddress);
  const device: ChatgptDeviceSignIn = await startDeviceSignIn();
  const polled: FxProviderCredentials | null = await pollDeviceSignIn(device);
  const waited: FxProviderCredentials = await completeDeviceSignIn(device, { signal: AbortSignal.timeout(900_000) });
  const code: ChatgptSignInErrorCode = "LIBFX_CHATGPT_SIGN_IN_EXPIRED";
  void polled; void waited; void code;
  return refreshCredentials(credentials);
}

// Sign in with a Grok plan: device code first, the pasted address as a fallback.
declare const grokStore: { put(value: GrokSignIn | GrokDeviceSignIn): void };
export async function grokSignIn(pastedAddress: string): Promise<FxProviderCredentials> {
  const device: GrokDeviceSignIn = await grok.startDeviceSignIn();
  grokStore.put(device);
  const polled: FxProviderCredentials | null = await grok.pollDeviceSignIn(device);
  const viaDevice: FxProviderCredentials = await grok.completeDeviceSignIn(device, { signal: AbortSignal.timeout(1_800_000) });
  const signIn: GrokSignIn = await grok.startSignIn();
  const redirect: string = signIn.redirectUri;
  const viaAddress = await grok.finishSignIn(signIn, pastedAddress);
  // @ts-expect-error finishSignIn() needs the sign-in startSignIn() returned
  await grok.finishSignIn({ url: signIn.url, state: signIn.state, verifier: signIn.verifier }, pastedAddress);
  const code: GrokSignInErrorCode = "LIBFX_GROK_ACCOUNT_CHANGED";
  void polled; void viaDevice; void redirect; void code;
  return grok.refreshCredentials(viaAddress);
}
