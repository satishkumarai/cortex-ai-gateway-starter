-- inspect_turn.sql
-- Open one turn into its spans. Take <trace_id> from turns.sql.
-- VERIFIED against docs (Inspect one turn example).
--
-- Replace <start>, <end>, and <trace_id> before running.
-- <start>/<end> are UTC: the trace table's timestamp is TIMESTAMP_NTZ in
-- UTC. Use SYSDATE() (UTC), not CURRENT_TIMESTAMP(), for relative windows.
-- One row per span — no rollup needed.

SELECT
  trace:"span_id"::string                                          AS span_id,
  record:"name"::string                                            AS span_name,
  record_attributes:"gen_ai.operation.name"::string                AS operation,
  start_timestamp                                                  AS span_start,
  DATEDIFF('millisecond', start_timestamp, timestamp)              AS duration_ms,
  DATEDIFF('millisecond', MIN(start_timestamp) OVER (), start_timestamp) AS offset_ms,
  record:"status":"code"::string                                   AS status,
  TRY_TO_NUMBER(record_attributes:"http.status_code"::string)      AS http_status,
  record_attributes:"gen_ai.request.model"::string                 AS model,
  TRY_TO_NUMBER(record_attributes:"gen_ai.usage.input_tokens"::string)  AS input_tokens,
  TRY_TO_NUMBER(record_attributes:"gen_ai.usage.output_tokens"::string) AS output_tokens
FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
WHERE timestamp >= '<start>'
  AND timestamp <  '<end>'
  AND trace:"trace_id"::string = '<trace_id>'
ORDER BY span_start
LIMIT 2000;

-- To read prompt/response content, add (populated only when payload
-- capture is enabled, and never for exclude-tagged users):
--   record_attributes:"gen_ai.input.messages"      AS input_messages,
--   record_attributes:"gen_ai.output.messages"     AS output_messages,
--   record_attributes:"gen_ai.system_instructions" AS system_instructions
-- These are large — select only when you actually need them.
