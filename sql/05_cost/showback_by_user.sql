-- showback_by_user.sql
-- Chargeback/showback from SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY.
-- Readable with MONITOR on the gateway.
--
-- VERIFIED against a live account (JK62811, Nov 2026):
--   * Top-level columns: START_TIME, GATEWAY_ID, GATEWAY_NAME, USER_ID,
--     SERVICE_TYPE (e.g. 'AI_INFERENCE'), REQUEST_ID, OPERATION_DETAILS,
--     CREDITS, CREDITS_GRANULAR, METADATA.
--   * OPERATION_DETAILS and CREDITS_GRANULAR are objects KEYED BY MODEL
--     NAME: {"<model>": {"input_tokens": N, "output_tokens": N}, ...}.
--     Flatten them to get per-model rows.
--   * METADATA currently carries {"role_id": N}.
--   * USER_ID joins to SNOWFLAKE.ACCOUNT_USAGE.USERS.USER_ID for names.
--   * REQUEST_ID equals the x-snowflake-request-id response header —
--     the end-to-end join key from client to billing record.
--   * CREDITS is per-request total: if a request spans multiple models
--     (agent turns), CREDITS repeats per flattened row — dedupe by
--     REQUEST_ID when summing credits, sum tokens per flattened row.
--   * Token keys are ABSENT (not zero) when a request produces no tokens
--     of that kind — verified: a max_tokens:0 request's OPERATION_DETAILS
--     has no "output_tokens" key at all, and failed (4xx) requests produce
--     no billing row. Always COALESCE token values to 0.

-- Daily spend by user and model. Two-level aggregation:
-- tokens sum per (day,user,model) over flattened rows; credits dedupe to
-- one row per REQUEST_ID first, because CREDITS is per-request and repeats
-- across models in multi-model requests.
WITH flat AS (
  SELECT
    DATE_TRUNC('day', h.START_TIME)              AS usage_day,
    u.NAME                                       AS user_name,
    f.KEY                                        AS model,
    COALESCE(f.VALUE:"input_tokens"::number, 0)  AS input_tokens,
    COALESCE(f.VALUE:"output_tokens"::number, 0) AS output_tokens,
    h.REQUEST_ID,
    h.CREDITS
  FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY h
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
    ON u.USER_ID = h.USER_ID
  , LATERAL FLATTEN(input => h.OPERATION_DETAILS) f
  WHERE h.START_TIME >= DATEADD(day, -30, CURRENT_TIMESTAMP())
)
SELECT
  usage_day,
  user_name,
  model,
  COUNT(DISTINCT REQUEST_ID)                     AS requests,
  SUM(input_tokens)                              AS input_tokens,
  SUM(output_tokens)                             AS output_tokens,
  -- per-request credits attributed to each model touched; totals reconcile
  -- only when requests are single-model (verified shape in this account)
  SUM(CREDITS)                                   AS credits
FROM flat
GROUP BY usage_day, user_name, model
ORDER BY usage_day DESC, credits DESC;

-- Top spenders this month (FinOps review)
SELECT
  u.NAME                                         AS user_name,
  SUM(h.CREDITS)                                 AS credits,
  COUNT(*)                                       AS requests
FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY h
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
  ON u.USER_ID = h.USER_ID
WHERE h.START_TIME >= DATE_TRUNC('month', CURRENT_TIMESTAMP())
GROUP BY u.NAME
ORDER BY credits DESC
LIMIT 50;

-- Correlate a client-side request to its billing record:
--   SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY
--   WHERE REQUEST_ID = '<x-snowflake-request-id from the HTTP response>';

-- Spending controls (choose per need):
--
-- | Control                | Scope               | Enforcement                | Latency              |
-- |------------------------|---------------------|----------------------------|----------------------|
-- | Shared resource budget | User pool (by tag)  | Notification + procedures  | up to ~6.5 h (1 h LL)|
-- | Per-user quota         | Individual          | Built-in blocking          | within minutes       |
-- | REVOKE USAGE           | Role                | Immediate                  | immediate            |
--
-- Budgets are periodic, so a loop can overshoot for hours. Use per-user
-- quotas as the backstop for anything that can burn money in a loop.
--
-- VERIFIED LIMITATION (JK62811, Nov 2026): CREATE BUDGET / SHOW BUDGETS are
-- unsupported in this account edition, and no quota system functions exist
-- in ACCOUNT_USAGE. Team budgets and per-user quotas are configured through
-- the Snowsight AI Gateway > Cost UI (see docs "Add the AI Gateway"), not
-- SQL. The cutoff procedure below is still the SQL-side enforcement point;
-- wire it to a budget in the UI where the feature is available.
