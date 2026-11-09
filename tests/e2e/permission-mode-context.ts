import { expect } from "bun:test";

const permissionModeContext = {
  ask: "Runtime context: permission mode is ask. Sensitive tool calls may need user approval unless configured rules or session grants decide them.",
  auto: "Runtime context: permission mode is auto. fx sends each action that rules and grants leave unresolved to a safety reviewer. A clear result allows only that exact action. A caution or unavailable review holds only that action and returns advice without ending the turn. Cautions are reused for this turn, so choose a materially different safe action or explain why no safe path remains.",
  yolo: "Runtime context: permission mode is full access; fx permission policy is off. Argument validation, limits, and operating-system permissions still apply.",
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
}
