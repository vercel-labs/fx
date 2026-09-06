export const benchmarkInstructions =
  "You are a friendly greeter. When the user says hello, greet them back warmly in one short sentence.";
export const benchmarkPrompt = "hello world";

export function sampleStats(values) {
  if (!values.length || values.some((value) => !Number.isFinite(value) || value < 0)) {
    throw new TypeError("benchmark samples must be nonempty, finite, and nonnegative");
  }
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = (fraction) => sorted[Math.ceil(sorted.length * fraction) - 1];
  return {
    count: sorted.length,
    mean: sorted.reduce((sum, value) => sum + value, 0) / sorted.length,
    p50: percentile(0.5),
    p95: percentile(0.95),
    ...(sorted.length >= 100 ? { p99: percentile(0.99) } : {}),
    max: sorted.at(-1),
  };
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
export const benchmarkInstructionsBytes = encoder.encode(benchmarkInstructions).length;

function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => typeof part?.text === "string" ? part.text : "")
    .filter(Boolean)
    .join("");
}

export function requestMetrics(body) {
  const text = typeof body === "string" ? body : decoder.decode(body);
  const payload = JSON.parse(text);
  const systemSections = [];
  if (typeof payload.instructions === "string") systemSections.push(payload.instructions);
  const messages = payload.prompt ?? payload.messages ?? payload.input;
  if (Array.isArray(messages)) {
    for (const message of messages) {
      if (message?.role === "system" || message?.role === "developer") {
        const content = contentText(message.content);
        if (content) systemSections.push(content);
      }
    }
  }
  return {
    request_bytes: encoder.encode(text).length,
    system_context_bytes: systemSections.reduce(
      (total, section) => total + encoder.encode(section).length,
      0,
    ),
  };
}
