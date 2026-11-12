# Custom endpoint captures

Replies recorded from a real local model server, so tests can replay them against the parsers for custom model connections without a network. They show the shapes a server sends, which a hand-written fake can get wrong.

Recorded from Ollama 0.33.3 on loopback with `qwen2.5:0.5b` (text) and `qwen2.5:1.5b` (tool calls), using `curl -N`. The bodies are unedited.

| File | Request | Reply |
| --- | --- | --- |
| `models.json` | `GET /v1/models` | The model list: ids only, no limits or capabilities |
| `chat-text.sse` | `POST /v1/chat/completions`, `stream_options.include_usage` | Text, then usage with `prompt_tokens_details.cached_tokens` in a final chunk with no choices |
| `chat-tool-call.sse` | The same, with one function tool | One tool call, `finish_reason: "tool_calls"` |
| `chat-length.sse` | The same, `max_tokens: 5` | Cut short, `finish_reason: "length"` |
| `chat-max-completion-tokens-ignored.sse` | The same, `max_completion_tokens: 5` and no `max_tokens` | Not cut short: this server ignores the field |
| `chat-json-schema.sse` | The same, `response_format` of type `json_schema` | JSON text that matches the schema |
| `chat-effort-rejected.json` | The same, `reasoning_effort: "low"` on a model that does not think | HTTP 400 |
| `chat-unknown-model.json` | The same, a model the server does not have | HTTP 404 |
| `responses-text.sse` | `POST /v1/responses` | Text, then `response.completed` with `input_tokens_details.cached_tokens` and `output_tokens_details.reasoning_tokens` |
| `responses-tool-call.sse` | The same, with one function tool | One function call |
| `responses-unknown-model.json` | The same, a model the server does not have | HTTP 404 |
| `messages-text.sse` | `POST /v1/messages` | Text, then `message_delta` usage with `cache_read_input_tokens` |
| `messages-tool-call.sse` | The same, with one tool | One `tool_use` block, `stop_reason: "tool_use"` |
| `messages-unknown-model.json` | The same, a model the server does not have | HTTP 404 |
