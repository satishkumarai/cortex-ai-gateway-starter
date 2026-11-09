-- turns.sql
-- Roll up trace spans into one row per turn (trace_id).
-- VERIFIED against docs (List turns example).
--
-- Covers client-exported spans as well as the gateway's own. Add
--   scope:"name"::string = 'aigateway/tracing'
-- to see only what the gateway recorded.
--
-- Replace <start> and <end> before running.
-- <start>/<end> are UTC: the trace table's timestamp is TIMESTAMP_NTZ in
-- UTC. Use SYSDATE() (UTC), not CURRENT_TIMESTAMP(), for relative windows.

WITH ev AS (
  SELECT
    trace:"trace_id"::string                                      AS trace_id,
    trace:"span_id"::string                                       AS span_id,
    record_attributes:"gen_ai.request.model"::string              AS model,
    record_attributes:"gen_ai.input.messages"::string             AS llm_input,
    record_attributes:"gen_ai.conversation.id"::string            AS conversation_id,
    resource_attributes:"user"::string                            AS user_name,
    TRY_TO_NUMBER(record_attributes:"http.status_code"::string)   AS http_status,
    start_timestamp,
    timestamp
  FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
  WHERE timestamp >= '<start>'
    AND timestamp <  '<end>'
)
SELECT
  trace_id,
  MIN(start_timestamp)                                            AS started_at,
  DATEDIFF('millisecond', MIN(start_timestamp), MAX(timestamp))   AS duration_ms,
  COUNT(*)                                                        AS span_count,
  MAX(user_name)                                                  AS user_name,
  MIN_BY(model, IFF(model IS NULL, NULL, timestamp))              AS model,
  COUNT(DISTINCT model)                                           AS model_count,
  MAX(conversation_id)                                            AS conversation_id,
  MIN_BY(llm_input, IFF(llm_input IS NULL, NULL, timestamp))      AS first_input,
  IFF(COUNT_IF(http_status >= 400) = 0, 'SUCCESS', 'FAILURE')     AS status
FROM ev
GROUP BY trace_id
ORDER BY started_at DESC
LIMIT 10000;
