----------------------------- MODULE MCAcpSpeed -----------------------------
(* Model-checking constants: the same three catalog shapes the runtime    *)
(* driver serves from its fake Gateway.                                   *)
EXTENDS AcpSpeed

MCModels == {"openai/gpt-6-astra", "openai/gpt-5.6-priority", "anthropic/claude-plain"}
MCSupFast == {"openai/gpt-6-astra", "openai/gpt-5.6-priority"}
MCSupUltra == {"openai/gpt-6-astra"}
=============================================================================
