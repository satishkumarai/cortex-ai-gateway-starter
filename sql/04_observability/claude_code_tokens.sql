-- claude_code_tokens.sql
-- Token + model summary for a Claude Code deployment, last 7 days.
-- VERIFIED: this matches the documented example in the gateway
-- observability docs (Fireworks Nexus / Claude Code section).
--
-- Claude Code emits a claude_code.interaction span per user turn and a
-- claude_code.llm_request span per model call. For 'auto' turns the span
-- records the REQUESTED model, not the served model (get that from
-- `nexus claude usage`).
--
-- Live check (Nov 2026): runs cleanly; returns 0 rows until Claude Code
-- traffic with service.name='claude-code' is routed through the gateway.

SELECT
  RECORD_ATTRIBUTES:"gen_ai.request.model"::STRING        AS requested_model,
  COUNT(*)                                                AS turns,
  SUM(RECORD_ATTRIBUTES:"input_tokens"::NUMBER)           AS input_tokens,
  SUM(RECORD_ATTRIBUTES:"output_tokens"::NUMBER)          AS output_tokens,
  ROUND(AVG(RECORD_ATTRIBUTES:"duration_ms"::NUMBER))     AS avg_duration_ms
FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
WHERE RESOURCE_ATTRIBUTES:"service.name"::STRING = 'claude-code'
  AND RECORD_ATTRIBUTES:"span.type"::STRING = 'llm_request'
  AND TIMESTAMP >= DATEADD(day, -7, SYSDATE())
GROUP BY requested_model
ORDER BY turns DESC;
