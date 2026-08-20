import { expect } from "bun:test";

const permissionModeContext = {
  ask: "Runtime context: permission mode is ask. Sensitive tool calls may require user approval unless configured rules or session grants already decide them. Tool admission remains authoritative.",
  auto: "Runtime context: permission mode is auto. After configured rules, session grants, and deterministic safe-tool authority, fx reviews each unresolved sensitive tool call once. An automatic non-allow returns a failed tool result for replanning. Choose a materially different safe action, or when that result contains approval_request_id call ask_user_question with that exact ID to enter fx's real permission screen. Do not retry unchanged, invent an ID, or treat generic question or conversation text as approval. Three consecutive all-blocked response groups end in one bounded tools-disabled response; any successful tool resets that count. Tool admission and exact live revalidation remain authoritative.",
  yolo: "Runtime context: permission mode is yolo. Fx permission policy and sandboxing are disabled. Tool lookup, argument validation, execution authority, cancellation, limits, operating-system permissions, and remote authentication remain authoritative.",
} as const;

export function expectPermissionModeContext(
  body: string,
  mode: keyof typeof permissionModeContext,
) {
  const request = JSON.parse(body) as {
    prompt: Array<{ role?: string; content?: unknown }>;
  };
  const messages = request.prompt.map((message) => ({
    role: message.role,
    text: typeof message.content === "string" ? message.content : "",
  }));
  const expected = permissionModeContext[mode];
  const matching = messages.filter((message) => message.text === expected);

  expect(matching).toHaveLength(1);
  for (const [candidateMode, context] of Object.entries(permissionModeContext)) {
    if (candidateMode === mode) continue;
    expect(messages.some((message) => message.text === context)).toBe(false);
  }
  expect(matching[0]!.role).toBe("system");
  const modeIndex = messages.findIndex((message) => message.text === expected);
  expect(
    messages[modeIndex + 1]?.text.startsWith(
      "Runtime context: shell commands run ",
    ),
  ).toBe(true);
}
