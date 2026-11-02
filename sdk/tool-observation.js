// Observations of host-owned effects. Helpers call the effect exactly once,
// preserve its value/error, and never await an instrumentation callback.
export function toolObservation(scope, callId, hooks, emit, signal) {
  const report = (error) => {
    try {
      Promise.resolve(hooks.onError?.(error)).catch(() => {});
    } catch {}
  };
  let next = 0;
  const id = () => `host:${scope.executionId}:${callId}:${++next}`;
  const publish = (type, data, content = {}) =>
    emit({
      ...scope,
      type,
      data,
      timestamp: Date.now(),
      contentCaptured: hooks.captureContent === true,
      contentTruncated: content.truncated === true,
    });
  const capture = () => {
    let remaining = 64 * 1024;
    return {
      truncated: false,
      text(value) {
        if (hooks.captureContent !== true || value == null) return undefined;
        value = String(value);
        let prefix = value.slice(0, remaining);
        if (prefix.length && /[\uD800-\uDBFF]/.test(prefix.at(-1))) prefix = prefix.slice(0, -1);
        const bytes = new TextEncoder().encode(prefix);
        let end = Math.min(bytes.length, remaining);
        while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
        remaining -= end;
        this.truncated ||= prefix.length < value.length || end < bytes.length;
        return new TextDecoder().decode(bytes.subarray(0, end));
      },
    };
  };
  function terminal(end) {
    let ended = false;
    const finish = (...args) => {
      if (ended) return;
      ended = true;
      signal.removeEventListener("abort", abort);
      try {
        end(...args);
      } catch (error) {
        report(error);
      }
    };
    const abort = () => finish("cancelled", undefined);
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
    return finish;
  }
  return {
    async wait(request, run) {
      if (
        !request ||
        !["approval", "question", "mcp_form", "mcp_url"].includes(request.kind) ||
        typeof run !== "function"
      )
        throw new TypeError("wait needs an input request and an effect");
      if (signal.aborted) return run();
      const requestId = id();
      const content = capture();
      content.truncated ||=
        (request.questions?.length ?? 0) > 128 ||
        (request.questions ?? [])
          .slice(0, 128)
          .some((question) => (question.options?.length ?? 0) > 128);
      publish(
        "wait.start",
        {
          requestId,
          kind: request.kind,
          callId,
          externalId: request.externalId ?? null,
          server: request.server ?? null,
          schemaJson: content.text(request.schemaJson),
          prompt: content.text(request.prompt),
          questionCount: request.questions?.length ?? 0,
          ...(hooks.captureContent === true
            ? {
                questions: (request.questions ?? []).slice(0, 128).map((question) => ({
                  question: content.text(question.question),
                  options: (question.options ?? []).slice(0, 128).map((option) => ({
                    label: content.text(option.label),
                    description: content.text(option.description),
                  })),
                })),
              }
            : {}),
        },
        content,
      );
      const finish = terminal((outcome, result, error) => {
        const content = capture();
        content.truncated ||= (result?.answers?.length ?? 0) > 128;
        publish(
          "wait.end",
          {
            requestId,
            outcome,
            error: error?.name ?? null,
            ...(hooks.captureContent === true
              ? {
                  answers: (result?.answers ?? [])
                    .slice(0, 128)
                    .map((answer) => content.text(answer)),
                }
              : {}),
          },
          content,
        );
      });
      try {
        const result = await run();
        let outcome = "accepted";
        try {
          outcome = result?.outcome ?? outcome;
        } catch (error) {
          report(error);
        }
        finish(outcome, result);
        return result;
      } catch (error) {
        finish(
          signal.aborted || error?.name === "AbortError"
            ? "cancelled"
            : error?.name === "TimeoutError"
              ? "timed_out"
              : "failed",
          undefined,
          error,
        );
        throw error;
      }
    },
    async mcp(identity, run) {
      if (signal.aborted) return run({ correlationId: identity.correlationId });
      const operationId = id();
      publish("mcp.start", {
        operationId,
        callId,
        server: identity.server ?? null,
        tool: identity.tool,
        transport: null,
      });
      if (identity.correlationId !== undefined)
        publish("mcp.request", {
          operationId,
          requestId: identity.correlationId,
          requestIdKind: "correlation",
        });
      const finish = terminal((status, error) =>
        publish("mcp.end", { operationId, status, error: error?.name ?? null }),
      );
      try {
        const result = await run({ correlationId: identity.correlationId });
        let status = "unknown";
        try {
          status = result?.isError ? "failure" : "success";
        } catch (error) {
          report(error);
        }
        finish(status);
        return result;
      } catch (error) {
        finish(signal.aborted || error?.name === "AbortError" ? "cancelled" : "failure", error);
        throw error;
      }
    },
    childHooks() {
      return {
        ...hooks,
        parent: {
          rootSessionId: scope.rootSessionId,
          sessionId: scope.sessionId,
          turnId: scope.turnId,
          callId,
        },
      };
    },
  };
}
