// A custom provider for libfx agents: any server that speaks OpenAI Chat
// Completions, such as a local model server or a router. The engine sends its
// requests through the host's fetch without credentials; when the host has an
// API key, this module adds it at the fetch edge, to that provider's chat URL
// only. The key never enters the engine or a session's saved records.

import { tokenString } from "./subscription.js";

const encoder = new TextEncoder();
const reservedNames = new Set(["gateway", "codex", "grok"]);
const namePattern = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
const providerFields = new Set(["name", "baseUrl", "models", "modelDefaults", "titleModel", "visionModel"]);
// libfx option names to the CLI's settings names, which the engine parses.
const modelFields = {
  contextWindow: "context_window",
  maxOutputTokens: "max_output_tokens",
  supportsToolUse: "supports_tool_use",
  supportsVision: "supports_vision",
  outputLimitField: "output_limit_field",
  request: "request",
  reasoningEfforts: "reasoning_efforts",
};
const outputLimitFields = new Set(["max_tokens", "max_completion_tokens"]);

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function chatUrlOf(baseUrl) {
  if (typeof baseUrl !== "string") throw new TypeError("provider.baseUrl must be a string");
  let url;
  try {
    url = new URL(`${baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl}/chat/completions`);
  } catch {
    throw new TypeError("provider.baseUrl must be an absolute URL");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new TypeError("provider.baseUrl must not carry credentials, a query or a fragment");
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopbackHosts.has(url.hostname))) {
    throw new TypeError("provider.baseUrl must use https, or http on localhost");
  }
  // The same form the fetch edge compares requests in.
  return `${url.origin}${url.pathname}`;
}

// The engine's limits (configured_provider.zig), checked here so both engines
// report a mistake the same way.
const maxModels = 256;
const maxModelIdBytes = 1024;
const maxLimit = 2 ** 32 - 1;

function validModelId(id) {
  return typeof id === "string" && id.length > 0 && id.trim() === id && !/[\u0000-\u001f\u007f]/.test(id) && encoder.encode(id).length <= maxModelIdBytes;
}

// One model's fields, or the provider's defaults for every model, in the
// settings' names. `where` names it in a message.
function modelEntry(model, where) {
  if (!isPlainObject(model)) throw new TypeError(`${where} must be an object`);
  const entry = {};
  for (const [field, value] of Object.entries(model)) {
    const name = modelFields[field];
    if (name === undefined) throw new TypeError(`${where} has unknown field ${field}`);
    if (field === "contextWindow" || field === "maxOutputTokens") {
      if (!(Number.isInteger(value) && value > 0 && value <= maxLimit)) throw new TypeError(`${where}.${field} must be a positive integer`);
    } else if (field === "outputLimitField") {
      if (!outputLimitFields.has(value)) throw new TypeError(`${where}.outputLimitField must be "max_tokens" or "max_completion_tokens"`);
    } else if (field === "request") {
      // The engine refuses a field it writes itself, such as messages.
      if (!isPlainObject(value)) throw new TypeError(`${where}.request must be an object of request fields`);
    } else if (field === "reasoningEfforts") {
      if (!isPlainObject(value) || !Object.values(value).every(isPlainObject)) {
        throw new TypeError(`${where}.reasoningEfforts must map each effort level to an object of request fields`);
      }
    } else if (typeof value !== "boolean") {
      throw new TypeError(`${where}.${field} must be a boolean`);
    }
    entry[name] = value;
  }
  if (model.contextWindow !== undefined && model.maxOutputTokens !== undefined && model.maxOutputTokens >= model.contextWindow) {
    throw new RangeError(`${where}.maxOutputTokens must be less than contextWindow`);
  }
  return entry;
}

function modelMetadata(models) {
  if (!isPlainObject(models)) throw new TypeError("provider.models must be an object keyed by model id");
  const entries = Object.entries(models);
  if (entries.length > maxModels) throw new RangeError(`provider.models lists more than ${maxModels} models`);
  const metadata = {};
  for (const [id, model] of entries) {
    if (!validModelId(id)) throw new TypeError(`provider.models has an invalid model id "${id}"`);
    metadata[id] = modelEntry(model, `provider.models["${id}"]`);
  }
  return metadata;
}

function helperModel(value, field) {
  if (value === undefined) return {};
  if (!validModelId(value)) throw new TypeError(`provider.${field} must be a model id`);
  return { [field === "titleModel" ? "title_model" : "vision_model"]: value };
}

/**
 * Checks a custom provider `{ name, baseUrl, models?, modelDefaults?,
 * titleModel?, visionModel? }` and returns its name,
 * the chat URL its key may go to, and the settings-style JSON the engine
 * parses. The engine applies the CLI's complete rules; these checks only catch
 * mistakes early with a clearer message.
 */
export function customProviderDefinition(provider) {
  if (!isPlainObject(provider)) throw new TypeError("a custom provider must be an object { name, baseUrl, models? }");
  for (const field of Object.keys(provider)) {
    if (!providerFields.has(field)) throw new TypeError(`a custom provider has unknown field ${field}`);
  }
  const { name, baseUrl, models, modelDefaults, titleModel, visionModel } = provider;
  if (typeof name !== "string" || !namePattern.test(name) || reservedNames.has(name.toLowerCase())) {
    throw new TypeError("provider.name must be a letter followed by letters, digits, _ or -, at most 64 characters, and not gateway, codex or grok");
  }
  const chatUrl = chatUrlOf(baseUrl);
  const definition = {
    protocol: "openai-chat-completions",
    base_url: baseUrl,
    // The host adds the key, so the engine's copy has none.
    auth: { type: "none" },
    ...helperModel(titleModel, "titleModel"),
    ...helperModel(visionModel, "visionModel"),
    ...(modelDefaults === undefined ? {} : { model_defaults: modelEntry(modelDefaults, "provider.modelDefaults") }),
    ...(models === undefined ? {} : { model_metadata: modelMetadata(models) }),
  };
  return { name, chatUrl, json: JSON.stringify({ [name]: definition }) };
}

/**
 * The custom provider's spec for `createSubscriptionAuthorizer()`: the host's
 * API key as a bearer token, on the provider's chat URL only. `sessionId()`
 * names the agent's session. A key has no refresh token, so it is never
 * refreshed, and a rejected request returns as it is.
 */
export function customProviderSpec({ name, chatUrl }, sessionId) {
  return {
    provider: name,
    matches: (endpoint) => endpoint === chatUrl,
    sessionId: () => sessionId(),
    normalize(value) {
      if (!isPlainObject(value)) throw new TypeError("credentials() must return { apiKey } for a custom provider");
      return { accessToken: tokenString(value.apiKey, "apiKey", true, `provider "${name}"`) };
    },
    authorize(headers, _endpoint, credentials) {
      headers.set("authorization", `Bearer ${credentials.accessToken}`);
    },
  };
}
