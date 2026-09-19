export const EVALUATION_URL = 'https://ai-gateway.vercel.sh/v4/ai/evaluation-model';

/** Uses the same documented wire contract as GatewayEvaluationModel in vercel/ai. */
export async function evaluate(state, questions, options = {}) {
  const dedicated = process.env.FX_JEV_GATEWAY_API_KEY;
  const credential = options.apiKey ?? dedicated ?? process.env.AI_GATEWAY_API_KEY ?? process.env.VERCEL_OIDC_TOKEN;
  if (!credential) throw new Error('Missing evaluation credential.');
  const teamId = options.teamId ?? (options.apiKey === undefined && dedicated !== undefined ? process.env.FX_JEV_GATEWAY_TEAM : undefined);
  const started = performance.now();
  const response = await (options.fetch ?? fetch)(EVALUATION_URL, {
    method: 'POST', redirect: 'error',
    signal: options.signal ?? AbortSignal.timeout(options.timeoutMs ?? 15000),
    headers: {
      authorization: `Bearer ${credential}`, 'content-type': 'application/json',
      'ai-gateway-protocol-version': '0.0.1',
      'ai-evaluation-model-specification-version': '4', 'ai-model-id': 'typesafe-ai/jev',
      ...(teamId ? { 'x-vercel-ai-gateway-team': teamId } : {}),
    },
    body: JSON.stringify({ state, questions, providerOptions: { gateway: { zeroDataRetention: true } } }),
  });
  if (!response.ok) {
    // Provider bodies may echo prompts or credentials; retain only status/trace ID.
    throw new Error(`Gateway evaluation failed: HTTP ${response.status}; request=${response.headers.get('x-vercel-id') ?? 'unknown'}`);
  }
  if (!response.body) throw new Error('Empty evaluation response');
  const reader = response.body.getReader();
  const chunks = []; let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 2_000_000) { await reader.cancel(); throw new Error('Evaluation response too large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!data.answers || typeof data.answers !== 'object') throw new Error('Missing evaluation answers');
  return { ...data, elapsedMs: performance.now() - started };
}

export function choice(answer, allowed) {
  if (answer?.type !== 'choice' || !allowed.includes(answer.choice)) throw new Error('Invalid choice answer');
  const probabilities = answer.probabilities;
  if (!probabilities || Object.keys(probabilities).some(k => !allowed.includes(k))) throw new Error('Invalid probability labels');
  if (allowed.some(k => !Number.isFinite(probabilities[k]) || probabilities[k] < 0 || probabilities[k] > 1)) throw new Error('Invalid probabilities');
  const total = Object.values(probabilities).reduce((a, b) => a + b, 0);
  if (Math.abs(total - 1) > 0.03) throw new Error('Probabilities do not sum to one');
  return { label: answer.choice, probability: probabilities[answer.choice], probabilities };
}
