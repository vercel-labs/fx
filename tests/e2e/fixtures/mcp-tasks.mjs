// Shared task state machine for both modern transports.
export function taskFixture(mode) {
  let polls = 0;
  let updates = 0;
  let staleInputPolls = 0;
  const taskId = "fixture-task";
  const inputRequests = {
    confirm: {
      method: "elicitation/create",
      params: {
        message: "Confirm the asynchronous operation",
        requestedSchema: {
          type: "object",
          properties: { confirmed: { type: "boolean" } },
          required: ["confirmed"],
          additionalProperties: false,
        },
      },
    },
  };
  return (message) => {
    if (!mode.startsWith("task_")) return null;
    const reply = (result) => ({ jsonrpc: "2.0", id: message.id, result });
    const task = (status, extra = {}) => ({
      resultType: "complete",
      taskId,
      status,
      createdAt: "2026-07-28T00:00:00Z",
      lastUpdatedAt: "2026-07-28T00:00:01Z",
      ttlMs: null,
      pollIntervalMs: polls > 0 ? 60 : 20,
      ...extra,
    });
    if (message.method === "tools/call") {
      if (mode === "task_mrtr" && !message.params?.inputResponses) {
        return reply({ resultType: "input_required", inputRequests, requestState: "before-task" });
      }
      return reply(task(mode === "task_seed_terminal" ? "completed" : "working", {
        resultType: "task",
        ...(mode === "task_long_poll" ? { pollIntervalMs: 60_000 } : {}),
      }));
    }
    if (!message.method.startsWith("tasks/")) return null;
    if (message.params?.taskId !== taskId) throw new Error("Incorrect task handle");
    if (message.method === "tasks/cancel") return reply({ resultType: "complete" });
    if (message.method === "tasks/update") {
      if (updates++) throw new Error("Input presented more than once");
      if (JSON.stringify(message.params.inputResponses) !== JSON.stringify({
        confirm: { action: "accept", content: { confirmed: true } },
      })) throw new Error("Incorrect task input");
      return reply({ resultType: "complete" });
    }
    if (message.method === "tasks/get") {
      polls++;
      if (mode === "task_mismatch") return reply(task("working", { taskId: "other-task" }));
      if (mode === "task_invalid") return reply(task("completed"));
      if (mode === "task_timeout") return reply(task("working"));
      if (mode === "task_input" && (updates === 0 || staleInputPolls++ === 0)) {
        return reply(task("input_required", { inputRequests }));
      }
      if (polls === 1) return reply(task("working"));
      if (mode === "task_failed") return reply(task("failed", { error: { code: -32000, message: "TASK_PROTOCOL_FAILURE", data: { reason: "fixture" } } }));
      if (mode === "task_cancelled") return reply(task("cancelled"));
      return reply(task("completed", {
        result: {
          content: [{ type: "text", text: mode === "task_invalid_content" ? 42 : "ASYNC_TASK_RESULT" }],
          structuredContent: { answer: 42 },
          isError: mode === "task_tool_error",
        },
      }));
    }
    throw new Error(`Unexpected task method ${message.method}`);
  };
}
