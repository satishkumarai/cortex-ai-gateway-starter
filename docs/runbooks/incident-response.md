# Runbook: AI Gateway incident response

> Alerting architecture (consolidated, live): two native alert+procedure
> pairs — `AI_GW_WATCHER_SCHED` (hourly, emails ONLY on anomaly: spec drift,
> failure-rate spike, or 429 burst) and `AI_GW_DAILY_DIGEST_SCHED` (daily
> 13:00 UTC dashboard email). Both log to `GOVERNANCE.AUDIT.AI_GW_ALERT_LOG`
> and email via `AI_GW_SHOWBACK_EMAIL`. There are no separate threshold
> alerts — the watcher subsumes them.

## A. Gateway or model degradation

**Symptoms:** `AI_GW_WATCHER` anomaly email (failing-models card red, model
names inline), or the daily digest shows a spiking failure rate.

```sql
-- Which model(s) are failing, and how (client vs server)?
SELECT
  record_attributes:"gen_ai.request.model"::string        AS model,
  record:"status":"message"::string                       AS error_class,  -- client_error | server_error
  TRY_TO_NUMBER(record_attributes:"http.status_code"::string) AS http_status,
  COUNT(*) AS n
FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
WHERE timestamp >= DATEADD(hour, -1, SYSDATE())
  AND record_attributes:"gen_ai.operation.name"::string = 'chat'
GROUP BY model, error_class, http_status
ORDER BY n DESC;
```

- **One model failing (5xx):** provider-side. Fail affected workloads over to another model in the allow-list if clients support a fallback model parameter; communicate impact.
- **All models failing:** treat as a platform incident. Check Snowflake service status; clients should retry with backoff.
- **429s concentrated on one identity:** not an outage — see C below.

## B0. PAT returns a bare HTTP 401 (empty body)

VERIFIED in a live account: a programmatic access token works only for a
user **subject to a network policy**. Without one, every gateway call
fails with `HTTP/2 401` and no error body — no traces, no usage rows.

Fix:

```sql
CREATE NETWORK POLICY IF NOT EXISTS AI_GW_PAT_NP ALLOWED_IP_LIST = ('<client-cidr>');
ALTER USER <user> SET NETWORK_POLICY = AI_GW_PAT_NP;
```

Create PATs with `ALTER USER <u> ADD PROGRAMMATIC ACCESS TOKEN <name> DAYS_TO_EXPIRY = n`
(`EXPIRES_IN_DAYS` is rejected for PATs). Prefer short expiries and tight
CIDRs; delete test PATs after use.

## B. A user or agent reports "the gateway rejected my request"

Outcome semantics from the docs, **annotated with live-drill findings**:

| HTTP | Outcome | Meaning | Traced? | First check |
|---|---|---|---|---|
| 401/403 | Policy denied | No access, quota block, or **model not in allow-list** | **No span, no billing row** (edge rejection — verified) | `SHOW GRANTS`; spec model list; quota state |
| 400 other | Invalid request | Malformed payload (e.g. bad param type) | **Yes** — `STATUS_CODE_ERROR`, parse error in `record.status.message` (verified) | Client request shape |
| 429 | Throttled | Rate limit | Expected yes | Rate-limit metrics; that identity's volume |
| 499 | Cancelled | Client cancelled | Expected yes | Client timeout config |
| 5xx | Server failure | Gateway/provider error | Expected yes | Section A |

**Verified gotchas:**

- **Denied requests are invisible to `AGENT_TRACE_TABLE`.** Trace-based
  failure alerts only see *served* failures. To audit attempted use of
  blocked models, use gateway access logs / query history, not traces.
- **`max_tokens: 0` is NOT an error.** Provider returns 200 with
  `stop_reason: max_tokens` and 0 output tokens — a client bug zeroing
  output looks healthy in reliability metrics. Monitor output-token
  distribution, not just status codes.
- **Alert action target must exist before first fire.** If the THEN
  statement's table is missing, the fire fails silently into alert
  history. Create log tables in the same deployment script as the alerts
  (ours: `sql/06_alerts.sql` creates `GOVERNANCE.AUDIT.AI_GW_ALERT_LOG`
  first). Prove the path with `EXECUTE ALERT GOVERNANCE.AUDIT.AI_GW_WATCHER_SCHED`
  or a direct `CALL GOVERNANCE.AUDIT.AI_GW_WATCHER()` (returns `ok (no email)`
  when clean).
- **Trace timestamps are UTC `TIMESTAMP_NTZ`.** Verified: `AGENT_TRACE_TABLE`
  `timestamp` is NTZ in UTC, while `CURRENT_TIMESTAMP()` follows the session
  timezone. In a non-UTC session, `timestamp >= DATEADD(hour,-1,CURRENT_TIMESTAMP())`
  silently widens the window by the UTC offset (8h in Pacific). Always use
  `SYSDATE()` for trace-table windows. `AI_GATEWAY_USAGE_HISTORY.START_TIME`
  is `TIMESTAMP_LTZ` and is safe with `CURRENT_TIMESTAMP()`.
- **Failed spans carry NULL token counts.** Verified: 400 spans record
  NULL input/output tokens. Any token-sum or cost-per-error analysis must
  `COALESCE(..., 0)` or failed rows vanish from totals.
- **Rejected requests are free.** Verified: billing shows 2 served
  requests while traces show 4 spans — malformed/denied traffic generates
  no credits. Reconciling spans vs `AI_GATEWAY_USAGE_HISTORY` row counts
  is a quick sanity check: billed ≤ traced.

**Unknown model:** the requested model isn't in the spec's model list (`gen_ai.request.model` records `unknown` when it can't be resolved). Either a typo, or the model needs an allow-list PR — do not casually add `'*'`.

**Endpoint↔model mismatch is distinct from allow-list denial.** Verified
2026-11-09: an allow-listed Claude model on `/v1/chat/completions` returns
**400** `the requested model does not support this endpoint` (traced, with
`x-snowflake-request-id`), whereas a non-allow-listed model returns an
**LB-level 401** (empty body, no span, no request-id). Claude models are
served only on `/v1/messages`; `/v1/chat/completions` and `/v1/responses`
serve OpenAI/Gemini/etc.

**Client OTLP spans DO land and join the gateway trace.** Verified
2026-11-09: with a manual client span + W3C `traceparent` injected via
`extra_headers` (see `clients/python/anthropic_sdk_otel.py`), the client
span (scope `__main__` / the instrumentor) and the gateway server span
(scope `aigateway/tracing`) share one `trace_id` in `AGENT_TRACE_TABLE`.
Note: per the Trace Analytics docs, client OTLP spans are stored but NOT
counted in the Snowsight Trace Analytics charts (those cover gateway-side
model/tool spans only).

## C. Runaway agent loop

**Symptoms:** one identity's token usage spiking; quota blocks them; FinOps flags spend.

```sql
-- What is the identity doing? Long sessions and repeated tool calls
-- are the signature of a loop.
SELECT resource_attributes:"user"::string AS user_name,
       COUNT(*) AS spans,
       SUM(TRY_TO_NUMBER(record_attributes:"gen_ai.usage.input_tokens"::string))  AS in_tok,
       SUM(TRY_TO_NUMBER(record_attributes:"gen_ai.usage.output_tokens"::string)) AS out_tok
FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
WHERE timestamp >= DATEADD(hour, -6, SYSDATE())
GROUP BY user_name
ORDER BY in_tok + out_tok DESC
LIMIT 20;
```

1. Quota blocks within minutes — confirm it did. If not quota-protected, revoke `USAGE` for that user/role as the immediate control.
2. Open the turns: `sql/04_observability/turns.sql` filtered to the user, then `inspect_turn.sql` on the longest trace.
3. If payload capture is on, inspect `gen_ai.input.messages` of the first span in the loop to find the triggering prompt. If the user is exclude-tagged, work from metadata (span counts, repeated tool names).
4. Fix the agent (loop guard, max iterations, tool error handling) before restoring access.

## D. Suspected sensitive data in the trace table

1. The trace table contains full prompts/responses **only** for requests made while `capture_payload.request_response` was true, for non-excluded users. Scope the exposure with that.
2. Restrict access immediately (review grants on the event table; `MONITOR` on the gateway also exposes traces).
3. Apply the exclusion tag to affected users to stop further capture, then decide retention/deletion per your data policy.
4. Review who holds `APPLY` on `GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT` and the global `APPLY TAG` privilege — exclusion is an audit override and must stay tightly held.

## E. Spec drift detected

See `docs/runbooks/spec-drift.md`.
