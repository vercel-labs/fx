import { expect } from "bun:test";

const permissionModeContext = {
  ask: "Runtime context: permission mode is ask. Sensitive tool calls may require user approval unless configured rules or session grants already decide them. Tool admission remains authoritative.",
  auto: "Runtime context: permission mode is auto. After configured rules, session grants, and deterministic safe-tool authority, fx sends each unresolved action to a narrow safety reviewer. A clear result authorizes only that exact action. A caution or unavailable result holds only that action and returns advice without opening a permission screen, disabling tools, or ending the turn. Exact cautions are reused for this turn; choose a materially different safe action or explain why no safe path remains. Tool admission and exact live revalidation remain authoritative.",
  yolo: "Runtime context: permission mode is full access. fx permission policy is disabled. Tool lookup, argument validation, execution authority, cancellation, limits, operating-system permissions, and remote authentication remain authoritative.",
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
