import { createHash } from 'node:crypto';
import { classify } from './classifier.mjs';

export function eligibleModels(policy, requirements = {}) {
  return policy.models.filter(m =>
    m.enabled !== false &&
    (!requirements.allowedModels || requirements.allowedModels.includes(m.id)) &&
    (!requirements.tools || m.tools === true) &&
    (!requirements.vision || m.vision === true) &&
    (!requirements.contextTokens || m.contextWindow >= requirements.contextTokens));
}

export function selectModel(classification, policy, requirements = {}) {
  const eligible = eligibleModels(policy, requirements);
  const ids = new Set(eligible.map(m => m.id));
  if (!ids.size) throw new Error('No eligible model satisfies the request');
  if (requirements.explicitModel) {
    if (!ids.has(requirements.explicitModel)) throw new Error('Explicit model is not eligible');
    return { model: requirements.explicitModel, reason: 'explicit_model' };
  }
  const fallback = ids.has(policy.defaultModel) ? policy.defaultModel : null;
  if (!fallback) throw new Error('Configured fallback is not eligible');
  if (!classification) return { model: fallback, reason: 'classifier_unavailable' };
  const c = classification.taskClass;
  if (!c || c.probability < policy.minTaskClassProbability || classification.family.probability < policy.minFamilyProbability) {
    return { model: fallback, reason: 'uncertain' };
  }
  const familyPolicy = policy.familyTaskClassModels?.[classification.family.label];
  const candidate = familyPolicy?.[c.label] ?? policy.taskClassModels[c.label];
  return ids.has(candidate) ? { model: candidate, reason: `family_${classification.family.label}_task_${c.label}` } : { model: fallback, reason: 'candidate_ineligible' };
}

export async function route(prompt, policy, requirements = {}, options = {}) {
  // Validate hard constraints before spending money on the classifier.
  const initial = selectModel(null, policy, requirements);
  const policyHash = createHash('sha256').update(JSON.stringify(policy)).digest('hex');
  if (requirements.explicitModel) return { ...initial, classification: null, policyHash };
  let classification = null;
  let error = null;
  try { classification = await (options.classify ?? classify)(prompt, { ...options, routing: true }); }
  catch (e) { error = e.name === 'TimeoutError' ? 'classifier_timeout' : 'classifier_error'; }
  return { ...selectModel(classification, policy, requirements), classification, error, policyHash };
}
