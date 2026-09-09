import { createHash } from "node:crypto";

// The projection accepts this frame, but the core rejects its zero runtime ID.
// This exercises cleanup after runtime/session creation, not option rejection.
export function invalidJournalOptions() {
  const inputJson = JSON.stringify({ text: "bootstrap cleanup", images: [] });
  const body = {
    v: 1, kind: "turn_start", namespace: "cleanup-session", turnId: "cleanup-turn",
    userMessageId: "cleanup-user", requestId: "cleanup-request", model: "cleanup/model",
    runtimeTurnId: "0", inputJson,
    inputHash: createHash("sha256").update(inputJson).digest("hex"),
  };
  const bytes = new TextEncoder().encode(JSON.stringify(body));
  const hash = createHash("sha256").update("1\nturn_start\n").update(bytes).digest("hex");
  return {
    journal: [{ seq: 1, kind: "turn_start", bytes, hash }],
    onEntry() { throw new Error("Restore attempted a persistence write"); },
  };
}
