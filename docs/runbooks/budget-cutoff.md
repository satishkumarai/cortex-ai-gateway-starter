# Runbook: Budget cutoff fired

> NOTE (edition limitation, verified): `CREATE BUDGET` is unsupported in this
> account edition — shared budgets and per-user quotas are configured in
> **Snowsight → AI Gateway → Cost**, not SQL. This runbook applies where
> budgets are available; the `AI_GW_CUTOFF` procedure is deployed and tested,
> ready to be wired to a budget action where supported.

**Trigger:** a shared resource budget crossed its threshold and called `GOVERNANCE.AUDIT.AI_GW_CUTOFF(<team_role>, 'REVOKE', ...)`, or a page reports a team suddenly unable to reach the gateway.

**Two things to know about how budgets enforce:**

- **A budget's spending limit is notification-only — it does not block on its
  own.** Per the docs, the limit "is used for alerting and notification
  purposes only." The actual cutoff is what *your* stored procedure does:
  the budget fires the action at the threshold, and `AI_GW_CUTOFF` performs
  the `REVOKE`. No proc wired → notification only, no cutoff.
- **Shared budgets tag *users*, not the object.** Scope is a *user pool by
  tag*: you create a tag, associate it with the budget via `SET_USER_TAGS`,
  and apply it to individual users; Snowflake tracks credit per tagged user
  group independently. (Plain *custom* budgets are the opposite attribution
  model — they tag the *object*.) `SET_USER_TAGS` requires the `APPLYBUDGET`
  privilege.

## Confirm what happened

```sql
-- Did the cutoff procedure run?
SELECT * FROM GOVERNANCE.AUDIT.AI_GW_CUTOFF_LOG
ORDER BY EVENT_TS DESC LIMIT 20;

-- What does the team's spend look like? (verified schema: USER_ID +
-- model-keyed OPERATION_DETAILS object; join USERS for names)
SELECT u.NAME AS user_name, f.KEY AS model,
       SUM(h.CREDITS) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY h
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
, LATERAL FLATTEN(input => h.OPERATION_DETAILS) f
WHERE h.START_TIME >= DATEADD(day, -1, CURRENT_TIMESTAMP())
GROUP BY user_name, model
ORDER BY credits DESC;
```

Remember: budget evaluation is **periodic** — the refresh interval is **up to 6.5 hours by default**, reducible to **1 hour** ("low latency budget," ~12× the compute cost) via `SET_REFRESH_TIER` or the Snowsight "Enable low latency budget" toggle. Spend can exceed the threshold substantially before the action runs. If you need spend to stop in minutes, that's what per-user quotas are for.

## Decide

- **Legitimate burst** (month-end processing, planned eval run): re-grant and raise the budget. Both actions, not just the re-grant — otherwise it fires again next cycle.
- **Runaway loop** (one identity burning tokens): do NOT re-grant the whole team. Set a per-user quota on that identity; investigate the loop in the trace table (`docs/runbooks/incident-response.md`).
- **Misconfigured budget** (wrong threshold, wrong tag scope): fix the budget first, then re-grant.

## Re-grant

```sql
CALL GOVERNANCE.AUDIT.AI_GW_CUTOFF('<TEAM_ROLE>', 'GRANT',
     'reason + approver + ticket');
```

Verify:

```sql
SHOW GRANTS OF ROLE AI_GW_USER;  -- team role present
SELECT * FROM GOVERNANCE.AUDIT.AI_GW_CUTOFF_LOG
ORDER BY EVENT_TS DESC LIMIT 1;   -- GRANT row logged
```

## Follow-ups (every time)

- File a ticket with: team, credits at cutoff, top user/model, root cause, action taken.
- If thresholds fire more than once per quarter for the same team, the budget is wrong — resize it from history rather than repeatedly re-granting.
