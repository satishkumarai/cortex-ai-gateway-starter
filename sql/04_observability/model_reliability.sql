-- model_reliability.sql
-- Failure rate, latency, and rate-limit pressure by model, last 24h.
-- Attribute names per the docs' span-attribute reference.
--
-- Status semantics (docs):
--   record:"status":"code"   -> STATUS_CODE_OK | STATUS_CODE_ERROR | UNSET
--   http.status_code >= 400  -> failed span (429 = throttled)

SELECT
  record_attributes:"gen_ai.request.model"::string                        AS model,
  COUNT(*)                                                                AS requests,
  COUNT_IF(record:"status":"code"::string = 'STATUS_CODE_ERROR'
           OR TRY_TO_NUMBER(record_attributes:"http.status_code"::string) >= 400) AS failures,
  ROUND(COUNT_IF(record:"status":"code"::string = 'STATUS_CODE_ERROR'
           OR TRY_TO_NUMBER(record_attributes:"http.status_code"::string) >= 400)
        / NULLIF(COUNT(*), 0), 4)                                         AS failure_rate,
  COUNT_IF(TRY_TO_NUMBER(record_attributes:"http.status_code"::string) = 429) AS throttled,
  APPROX_PERCENTILE(
    DATEDIFF('millisecond', start_timestamp, timestamp), 0.95)            AS p95_ms
FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
WHERE timestamp >= DATEADD(hour, -24, SYSDATE())
  AND record_attributes:"gen_ai.operation.name"::string = 'chat'
GROUP BY model
ORDER BY failure_rate DESC;

-- Alerting: wrap this in a Snowflake Alert (see sql/06_alerts.sql).
-- Use this SQL for production alerting rather than the preview
-- Trace analytics tab, whose metrics are documented as approximate.
