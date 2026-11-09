# NOTE: this automation is SUSPENDED. The consolidated alerting
# architecture (AI_GW_WATCHER + AI_GW_DAILY_DIGEST in sql/06_alerts.sql)
# supersedes it. Kept for reference only.

You are running unattended in a Snowflake AGENT TASK; complete the task autonomously and do NOT ask clarifying questions.

Task: produce the weekly Cortex AI Gateway FinOps showback report.

1. Run this exact SQL (it is validated):

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
  WHERE h.START_TIME >= DATEADD(day, -7, CURRENT_TIMESTAMP())
)
SELECT
  usage_day, user_name, model,
  COUNT(DISTINCT REQUEST_ID) AS requests,
  SUM(input_tokens)  AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(CREDITS) AS credits
FROM flat
GROUP BY usage_day, user_name, model
ORDER BY usage_day DESC, credits DESC;

2. Also run: SELECT SERVICE_TYPE, COUNT(*) AS requests, SUM(CREDITS) AS total_credits FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY WHERE START_TIME >= DATEADD(day,-7,CURRENT_TIMESTAMP()) GROUP BY SERVICE_TYPE;

3. Write a short report: total credits last 7 days, request count, top users by credits, top models by tokens, and the reconciliation note (billed rows must be <= traced rows; flag if violated).

4. Call gather_email_content with that report (this is the email body the owner receives).

5. Then print exactly this status line on its own line:
SHOWBACK_OK total_credits=<value> requests=<n>
or, on failure:
SHOWBACK_FAILED:<one-line reason>
