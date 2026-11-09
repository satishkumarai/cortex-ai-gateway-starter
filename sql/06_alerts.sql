-- 06_alerts.sql
-- Native, consolidated AI Gateway alerting: two alert+procedure pairs.
--   AI_GW_WATCHER_SCHED (hourly)  -> AI_GW_WATCHER(): drift + failure-rate +
--                                    429 checks; emails ONLY on anomaly.
--   AI_GW_DAILY_DIGEST_SCHED      -> AI_GW_DAILY_DIGEST(): 24h digest + 7d
--      (daily 13:00 UTC)           showback, HTML email.
-- Native Snowflake ALERT + SYSTEM$SEND_EMAIL; no automation fire, no
-- --without-read-only. Verified live (JK62811, Nov 2026).
--
-- Prereqs (live in this account):
--   GOVERNANCE.AUDIT.AI_GW_ALERT_LOG table (below)
--   NOTIFICATION INTEGRATION AI_GW_SHOWBACK_EMAIL with a VERIFIED recipient
-- Replace <WAREHOUSE> and <verified-user-email>.

CREATE TABLE IF NOT EXISTS GOVERNANCE.AUDIT.AI_GW_ALERT_LOG (
  EVENT_TS   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  ALERT_NAME STRING,
  DETAIL     VARIANT
);

-- Expected production spec (mirrors config/gateway-spec.production.yaml).
-- The watcher compares the live DESCRIBE output to this. Keep in sync with
-- config/ and ci/check_spec_drift.py.

CREATE OR REPLACE PROCEDURE GOVERNANCE.AUDIT.AI_GW_WATCHER()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  anomalies   NUMBER DEFAULT 0;
  fail_reqs   NUMBER DEFAULT 0;
  fail_total  NUMBER DEFAULT 0;
  fail_models STRING DEFAULT '';
  fail_chips  STRING DEFAULT '';
  throttled   NUMBER DEFAULT 0;
  live_spec   STRING;
  expected    STRING;
  drift       BOOLEAN DEFAULT FALSE;
  detail      STRING;
  subject     STRING;
  body        STRING;
  summary     STRING;
  sev         STRING;
  sev_col     STRING;
  sent        BOOLEAN;
  acct_ctx    STRING;
BEGIN
  -- account/environment context for the email header
  acct_ctx := CURRENT_ACCOUNT_NAME() || ' · ' || CURRENT_REGION()
              || ' · user ' || CURRENT_USER() || ' · role ' || CURRENT_ROLE()
              || ' · wh ' || CURRENT_WAREHOUSE();

  expected := 'schema_version: 1
models:
  - name: claude-sonnet-4-6
  - name: claude-haiku-4-5
  - name: claude-opus-5
logging:
  enabled: true
  enable_client_telemetry: true
  capture_payload:
    request_response: true
    exclude_tags:
      - GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT';

  EXECUTE IMMEDIATE 'DESCRIBE AI GATEWAY SNOWFLAKE';
  SELECT "specification" INTO :live_spec FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  drift := (TRIM(:live_spec) <> TRIM(:expected));

  SELECT COALESCE(SUM(reqs),0), COUNT(*),  -- total reqs on failing models, # failing models
         COALESCE(LISTAGG(DISTINCT model, ', '), 'none'),
         COALESCE(LISTAGG(DISTINCT '<span style="display:inline-block;background:#fef2f2;border:1px solid #fecaca;color:#991b1b;font-size:11px;font-weight:600;padding:3px 10px;border-radius:999px;margin:2px 4px 2px 0;">' || model || '</span>', ' '), '')
  INTO :fail_total, :fail_reqs, :fail_models, :fail_chips
  FROM (
    SELECT model, COUNT(*) AS reqs,
           COUNT_IF(status_code = 'STATUS_CODE_ERROR' OR http_status >= 400) AS fails
    FROM (
      SELECT record_attributes:"gen_ai.request.model"::string AS model,
             record:"status":"code"::string AS status_code,
             TRY_TO_NUMBER(record_attributes:"http.status_code"::string) AS http_status
      FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
      WHERE timestamp >= DATEADD(hour,-1,SYSDATE())
        AND record_attributes:"gen_ai.operation.name"::string = 'chat'
    )
    GROUP BY model
    HAVING reqs >= 20 AND fails/reqs > 0.10
  );

  SELECT COUNT(*) INTO :throttled
  FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
  WHERE timestamp >= DATEADD(hour,-1,SYSDATE())
    AND TRY_TO_NUMBER(record_attributes:"http.status_code"::string) = 429;

  anomalies := (IFF(:drift,1,0) + IFF(:fail_reqs>0,1,0) + IFF(:throttled>=50,1,0));

  detail := '{"window":"1h","spec_drift":' || :drift::string
            || ',"failing_models":' || :fail_reqs || ',"failing_model_reqs":' || :fail_total
            || ',"failing_model_names":"' || :fail_models || '"'
            || ',"throttled_429":' || :throttled || ',"anomalies":' || :anomalies || '}';
  INSERT INTO GOVERNANCE.AUDIT.AI_GW_ALERT_LOG (ALERT_NAME, DETAIL)
  SELECT 'AI_GW_WATCHER', PARSE_JSON(:detail);

  IF (:anomalies = 0) THEN
    RETURN 'ok (no email)';
  END IF;

  -- plain-English summary + severity
  summary := IFF(:drift,'Gateway spec drifted from the approved configuration. ','')
          || IFF(:fail_reqs>0, :fail_reqs || ' model(s) failing above threshold (' || :fail_models || '). ','')
          || IFF(:throttled>=50, 'Heavy rate limiting in the last hour (' || :throttled || ' HTTP 429s).','');
  sev     := IFF(:anomalies>=2,'HIGH','MEDIUM');
  sev_col := IFF(:anomalies>=2,'#b91c1c','#d97706');

  subject := '[AI Gateway][' || :sev || '] Watcher — ' || :anomalies || ' anomal' || IFF(:anomalies=1,'y','ies')
             || ': ' || IFF(:drift,'drift ','') || IFF(:fail_reqs>0,'failures ','') || IFF(:throttled>=50,'429s','');
  body :=
    '<html><body style="margin:0;padding:32px 16px;background:#f1f5f9;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
    || '<div style="max-width:680px;margin:0 auto;">'
    || '<div style="background:linear-gradient(135deg,#7f1d1d 0%,#b91c1c 100%);color:#fff;padding:24px 28px;border-radius:14px 14px 0 0;">'
    || '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
    || '<td><div style="font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#fecaca;">Snowflake Cortex</div>'
    || '<div style="font-size:22px;font-weight:700;margin-top:4px;">AI Gateway — Anomaly Detected</div></td>'
    || '<td align="right" valign="top"><span style="background:#ffffff;color:'||:sev_col||';font-size:11px;font-weight:700;padding:4px 12px;border-radius:999px;letter-spacing:1px;">'||:sev||'</span></td>'
    || '</tr></table>'
    || '<div style="font-size:13px;color:#fee2e2;margin-top:8px;">'||TO_CHAR(SYSDATE(),'YYYY-MM-DD HH24:MI')||' UTC · watcher (hourly)</div>'
    || '<div style="font-size:11px;color:#fecaca;margin-top:6px;font-family:monospace;">'||:acct_ctx||'</div></div>'
    || '<div style="background:#ffffff;padding:26px 28px;border-radius:0 0 14px 14px;box-shadow:0 1px 3px rgba(0,0,0,0.06);">'
    || '<div style="padding:14px 16px;background:#fef2f2;border-left:4px solid #dc2626;border-radius:6px;font-size:14px;color:#7f1d1d;font-weight:600;">'||:summary||'</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:separate;border-spacing:8px 0;margin-top:16px;"><tr>'
    || '<td width="32%" style="background:#f8fafc;border:1px solid #e2e8f0;border-top:3px solid '||IFF(:drift,'#dc2626','#d1d5db')||';border-radius:10px;padding:14px 10px;" align="center">'
    || '<div style="font-size:20px;font-weight:700;color:'||IFF(:drift,'#dc2626','#6b7280')||';">'||IFF(:drift,'YES','no')||'</div>'
    || '<div style="font-size:10px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;margin-top:2px;">Spec drift</div></td>'
    || '<td width="32%" style="background:#f8fafc;border:1px solid #e2e8f0;border-top:3px solid '||IFF(:fail_reqs>0,'#dc2626','#d1d5db')||';border-radius:10px;padding:14px 10px;" align="center">'
    || '<div style="font-size:20px;font-weight:700;color:'||IFF(:fail_reqs>0,'#dc2626','#6b7280')||';">'||:fail_reqs||'</div>'
    || '<div style="font-size:10px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;margin-top:2px;">Failing models (>10%/hr)</div></td>'
    || '<td width="32%" style="background:#f8fafc;border:1px solid #e2e8f0;border-top:3px solid '||IFF(:throttled>=50,'#dc2626','#d1d5db')||';border-radius:10px;padding:14px 10px;" align="center">'
    || '<div style="font-size:20px;font-weight:700;color:'||IFF(:throttled>=50,'#dc2626','#6b7280')||';">'||:throttled||'</div>'
    || '<div style="font-size:10px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;margin-top:2px;">HTTP 429 (1h)</div></td>'
    || '</tr></table>'
    || IFF(:fail_reqs>0,
       '<div style="margin-top:20px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Failing models</div>'
       ||'<div style="margin-top:8px;">'||:fail_chips||'</div>',
       '')
    || '<div style="margin-top:20px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Raw detail</div>'
    || '<div style="margin-top:8px;padding:12px 16px;background:#0f172a;border-radius:8px;font-family:monospace;font-size:11px;color:#e2e8f0;">'||:detail||'</div>'
    || '<div style="margin-top:20px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Recommended next steps</div>'
    || '<table cellpadding="0" cellspacing="0" style="margin-top:8px;font-size:12px;color:#374151;">'
    || '<tr><td style="padding:4px 10px 4px 0;color:#3b82f6;font-weight:700;">1.</td><td>Open <b>Snowsight → AI Gateway → Observability</b> and filter to the failing model / error spans.</td></tr>'
    || '<tr><td style="padding:4px 10px 4px 0;color:#3b82f6;font-weight:700;">2.</td><td>If drift: re-apply the approved spec via <b>sql/03_apply_spec.sql</b>, then re-run the watcher.</td></tr>'
    || '<tr><td style="padding:4px 10px 4px 0;color:#3b82f6;font-weight:700;">3.</td><td>If throttling: review <b>AI Gateway → Cost</b> and per-user quotas for the noisy identity.</td></tr>'
    || '</table>'
    || '</div>'
    || '<div style="background:#f8fafc;color:#94a3b8;font-size:11px;padding:14px 28px;border-radius:0 0 14px 14px;border-top:1px solid #e2e8f0;">'
    || 'Sent by AI_GW_WATCHER — anomaly-only alerts (spec drift, failure spike, throttling). Full history in GOVERNANCE.AUDIT.AI_GW_ALERT_LOG.</div>'
    || '</div></body></html>';

  CALL SYSTEM$SEND_EMAIL('AI_GW_SHOWBACK_EMAIL','<verified-user-email>', :subject, :body, 'text/html') INTO :sent;
  RETURN 'anomalies=' || :anomalies::string || ' email=' || :sent::string;
END;
$$;

CREATE OR REPLACE PROCEDURE GOVERNANCE.AUDIT.AI_GW_DAILY_DIGEST()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  req_ok NUMBER DEFAULT 0; req_fail NUMBER DEFAULT 0; req_total NUMBER DEFAULT 0;
  req_prev NUMBER DEFAULT 0;
  fail_pct NUMBER(5,1) DEFAULT 0;
  dod_pct  STRING DEFAULT 'n/a';
  p50_ms NUMBER DEFAULT 0; p95_ms NUMBER DEFAULT 0;
  in_tokens NUMBER DEFAULT 0; out_tokens NUMBER DEFAULT 0;
  act_users NUMBER DEFAULT 0; act_models NUMBER DEFAULT 0;
  credits NUMBER(38,9) DEFAULT 0; credits7d NUMBER(38,9) DEFAULT 0;
  billed24 NUMBER DEFAULT 0; anomalies24 NUMBER DEFAULT 0;
  live_spec STRING; expected STRING; drift BOOLEAN DEFAULT FALSE;
  model_rows STRING DEFAULT ''; err_rows STRING DEFAULT ''; showback STRING DEFAULT '';
  trend_rows STRING DEFAULT '';
  detail STRING; subject STRING; body STRING; sent BOOLEAN;
  health STRING; health_col STRING; summary STRING; acct_ctx STRING;
BEGIN
  acct_ctx := CURRENT_ACCOUNT_NAME() || ' · ' || CURRENT_REGION()
              || ' · user ' || CURRENT_USER() || ' · role ' || CURRENT_ROLE()
              || ' · wh ' || CURRENT_WAREHOUSE();
  SELECT
    COUNT_IF(ts_bucket='cur'), COUNT_IF(ts_bucket='prev'),
    COUNT_IF(ts_bucket='cur' AND http_status BETWEEN 200 AND 399),
    COUNT_IF(ts_bucket='cur' AND http_status >= 400),
    COALESCE(ROUND(APPROX_PERCENTILE(IFF(ts_bucket='cur',dur_ms,NULL),0.5)),0),
    COALESCE(ROUND(APPROX_PERCENTILE(IFF(ts_bucket='cur',dur_ms,NULL),0.95)),0),
    COALESCE(SUM(IFF(ts_bucket='cur',in_tok,0)),0),
    COALESCE(SUM(IFF(ts_bucket='cur',out_tok,0)),0),
    COUNT(DISTINCT IFF(ts_bucket='cur',user_name,NULL)),
    COUNT(DISTINCT IFF(ts_bucket='cur',model,NULL))
  INTO :req_total,:req_prev,:req_ok,:req_fail,:p50_ms,:p95_ms,:in_tokens,:out_tokens,:act_users,:act_models
  FROM (
    SELECT IFF(timestamp >= DATEADD(hour,-24,SYSDATE()),'cur','prev') AS ts_bucket,
           TRY_TO_NUMBER(record_attributes:"http.status_code"::string) AS http_status,
           DATEDIFF('millisecond', start_timestamp, timestamp) AS dur_ms,
           TRY_TO_NUMBER(record_attributes:"gen_ai.usage.input_tokens"::string) AS in_tok,
           TRY_TO_NUMBER(record_attributes:"gen_ai.usage.output_tokens"::string) AS out_tok,
           resource_attributes:"user"::string AS user_name,
           record_attributes:"gen_ai.request.model"::string AS model
    FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
    WHERE timestamp >= DATEADD(hour,-48,SYSDATE())
      AND record_attributes:"gen_ai.operation.name"::string = 'chat'
  );
  fail_pct := IFF(:req_total>0, ROUND(:req_fail*100.0/:req_total,1), 0);
  dod_pct  := IFF(:req_prev>0, (ROUND((:req_total-:req_prev)*100.0/:req_prev,0))::string || '%', 'n/a');

  SELECT COALESCE(SUM(CREDITS),0), COUNT(*) INTO :credits,:billed24
  FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY WHERE START_TIME >= DATEADD(hour,-24,CURRENT_TIMESTAMP());
  SELECT COALESCE(SUM(CREDITS),0) INTO :credits7d
  FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY WHERE START_TIME >= DATEADD(day,-7,CURRENT_TIMESTAMP());

  SELECT COUNT(*) INTO :anomalies24
  FROM GOVERNANCE.AUDIT.AI_GW_ALERT_LOG
  WHERE ALERT_NAME='AI_GW_WATCHER' AND EVENT_TS >= DATEADD(hour,-24,CURRENT_TIMESTAMP())
    AND DETAIL:anomalies::number > 0;

  expected := 'schema_version: 1
models:
  - name: claude-sonnet-4-6
  - name: claude-haiku-4-5
  - name: claude-opus-5
logging:
  enabled: true
  enable_client_telemetry: true
  capture_payload:
    request_response: true
    exclude_tags:
      - GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT';
  EXECUTE IMMEDIATE 'DESCRIBE AI GATEWAY SNOWFLAKE';
  SELECT "specification" INTO :live_spec FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  drift := (TRIM(:live_spec) <> TRIM(:expected));

  -- health status + plain-English summary
  health := IFF(:drift OR :anomalies24>0, 'ACTION', IFF(:req_fail>0,'ATTENTION','HEALTHY'));
  health_col := IFF(:health='ACTION','#b91c1c', IFF(:health='ATTENTION','#d97706','#059669'));
  summary := 'Last 24h: '||:req_total||' requests ('||:fail_pct||'% failed), '
             ||:act_users||' user(s), '||:act_models||' model(s), '||:credits||' credits. '
             ||IFF(:drift,'Spec drift detected — re-apply the approved spec. ',
                  IFF(:anomalies24>0,:anomalies24||' watcher anomaly/ies fired — see inbox. ',
                     IFF(:req_fail>0,:req_fail||' failed request(s) to review. ','All checks nominal.')));

  -- 7-day request trend (bar chart as table cells)
  SELECT COALESCE(LISTAGG(row_html,''),'<tr><td colspan="3" style="padding:8px 14px;color:#9ca3af;font-size:12px;">No traffic</td></tr>') INTO :trend_rows
  FROM (
    SELECT '<tr>'
      ||'<td style="padding:8px 14px;font-size:11px;color:#64748b;border-top:1px solid #f3f4f6;white-space:nowrap;">'||day_lbl||'</td>'
      ||'<td style="padding:8px 14px;border-top:1px solid #f3f4f6;" width="70%">'
      ||  '<div style="background:#3b82f6;height:14px;border-radius:3px;width:'||bar_pct||'%;min-width:2px;"></div></td>'
      ||'<td style="padding:8px 14px;font-size:11px;color:#111827;border-top:1px solid #f3f4f6;" align="right">'||reqs||IFF(fails>0,' <span style="color:#dc2626;">('||fails||'f)</span>','')||'</td>'
      ||'</tr>' AS row_html
    FROM (
      SELECT TO_CHAR(DATE_TRUNC('day', start_timestamp),'Dy DD Mon') AS day_lbl,
             COUNT(*) AS reqs,
             COUNT_IF(TRY_TO_NUMBER(record_attributes:"http.status_code"::string) >= 400) AS fails,
             ROUND(COUNT(*) * 100.0 / NULLIF(MAX(COUNT(*)) OVER(),0), 0) AS bar_pct
      FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
      WHERE start_timestamp >= DATEADD(day,-7,SYSDATE())
        AND record_attributes:"gen_ai.operation.name"::string = 'chat'
      GROUP BY DATE_TRUNC('day', start_timestamp), day_lbl
      ORDER BY DATE_TRUNC('day', start_timestamp)
    )
  );

  SELECT COALESCE(LISTAGG(row_html,''),'<tr><td colspan="4" style="padding:6px 12px;color:#6b7280;">No traffic</td></tr>') INTO :model_rows
  FROM (
    SELECT '<tr><td style="padding:6px 12px;">'||model||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||reqs||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||p50||' ms</td>'
      ||'<td style="padding:6px 12px;" align="right">'||p95||' ms</td></tr>' AS row_html
    FROM (
      SELECT model, COUNT(*) AS reqs,
             ROUND(APPROX_PERCENTILE(dur_ms,0.5)) AS p50,
             ROUND(APPROX_PERCENTILE(dur_ms,0.95)) AS p95
      FROM (
        SELECT record_attributes:"gen_ai.request.model"::string AS model,
               DATEDIFF('millisecond', start_timestamp, timestamp) AS dur_ms
        FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
        WHERE timestamp >= DATEADD(hour,-24,SYSDATE())
          AND record_attributes:"gen_ai.operation.name"::string = 'chat'
      ) GROUP BY model ORDER BY reqs DESC LIMIT 10
    )
  );

  SELECT COALESCE(LISTAGG(row_html,''),'<tr><td colspan="3" style="padding:6px 12px;color:#6b7280;">None</td></tr>') INTO :err_rows
  FROM (
    SELECT '<tr><td style="padding:6px 12px;font-family:monospace;font-size:11px;">'||msg||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||http_status||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||n||'</td></tr>' AS row_html
    FROM (
      SELECT COALESCE(LEFT(record:"status":"message"::string,80),'(no message)') AS msg,
             TRY_TO_NUMBER(record_attributes:"http.status_code"::string) AS http_status,
             COUNT(*) AS n
      FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))
      WHERE timestamp >= DATEADD(day,-7,SYSDATE())
        AND record_attributes:"gen_ai.operation.name"::string = 'chat'
        AND TRY_TO_NUMBER(record_attributes:"http.status_code"::string) >= 400
      GROUP BY msg, http_status ORDER BY n DESC LIMIT 8
    )
  );

  SELECT COALESCE(LISTAGG(row_html,''),'<tr><td colspan="5" style="padding:6px 12px;color:#6b7280;">No billable usage</td></tr>') INTO :showback
  FROM (
    SELECT '<tr><td style="padding:6px 12px;">'||user_name||'</td>'
      ||'<td style="padding:6px 12px;">'||model||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||reqs||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||i||'/'||o||'</td>'
      ||'<td style="padding:6px 12px;" align="right">'||c||'</td></tr>' AS row_html
    FROM (
      SELECT user_name, model, COUNT(DISTINCT REQUEST_ID) AS reqs,
             SUM(in_t) AS i, SUM(out_t) AS o, SUM(CREDITS) AS c
      FROM (
        SELECT u.NAME AS user_name, f.KEY AS model,
               COALESCE(f.VALUE:"input_tokens"::number,0) AS in_t,
               COALESCE(f.VALUE:"output_tokens"::number,0) AS out_t,
               h.REQUEST_ID, h.CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.AI_GATEWAY_USAGE_HISTORY h
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
        , LATERAL FLATTEN(input => h.OPERATION_DETAILS) f
        WHERE h.START_TIME >= DATEADD(day,-7,CURRENT_TIMESTAMP())
      ) GROUP BY user_name, model ORDER BY c DESC LIMIT 10
    )
  );

  detail := '{"window":"24h","requests_ok":'||:req_ok||',"requests_failed":'||:req_fail
            ||',"credits":'||:credits||',"spec_drift":'||:drift::string||',"anomalies_24h":'||:anomalies24||'}';
  INSERT INTO GOVERNANCE.AUDIT.AI_GW_ALERT_LOG (ALERT_NAME, DETAIL)
  SELECT 'AI_GW_DAILY_DIGEST', PARSE_JSON(:detail);

  subject := '[AI Gateway]['||:health||'] Daily digest — '||:req_ok||' ok / '||:req_fail||' failed · '||:credits||' cr';

  body :=
    '<html><body style="margin:0;padding:32px 16px;background:#f1f5f9;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
    || '<div style="max-width:760px;margin:0 auto;">'
    || '<div style="background:linear-gradient(135deg,#0f172a 0%,#1e3a5f 100%);color:#fff;padding:24px 28px;border-radius:14px 14px 0 0;">'
    || '<table width="100%" cellpadding="0" cellspacing="0"><tr>'
    || '<td><div style="font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#93c5fd;">Snowflake Cortex</div>'
    || '<div style="font-size:22px;font-weight:700;margin-top:4px;">AI Gateway — Daily Digest</div></td>'
    || '<td align="right" valign="top"><span style="background:#ffffff;color:'||:health_col||';font-size:11px;font-weight:700;padding:4px 12px;border-radius:999px;letter-spacing:1px;">'||:health||'</span></td>'
    || '</tr></table>'
    || '<div style="font-size:13px;color:#cbd5e1;margin-top:8px;">'||TO_CHAR(SYSDATE(),'YYYY-MM-DD')||' UTC · Last 24 hours</div>'
    || '<div style="font-size:11px;color:#93c5fd;margin-top:6px;font-family:monospace;">'||:acct_ctx||'</div></div>'
    || '<div style="background:#ffffff;padding:26px 28px;border-radius:0 0 14px 14px;box-shadow:0 1px 3px rgba(0,0,0,0.06);">'
    || '<div style="padding:14px 16px;background:'||IFF(:health='HEALTHY','#f0fdf4;border-left:4px solid #059669;color:#166534;',IFF(:health='ATTENTION','#fffbeb;border-left:4px solid #d97706;color:#92400e;','#fef2f2;border-left:4px solid #dc2626;color:#991b1b;'))||'border-radius:6px;font-size:14px;font-weight:600;">'||:summary||'</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:separate;border-spacing:8px 0;margin-top:16px;"><tr>'
    || '<td width="19%" style="padding:10px;border:1px solid #e5e7eb;border-radius:8px;" align="center"><div style="font-size:22px;font-weight:bold;">'||:req_total||'</div><div style="font-size:10px;color:#6b7280;">Requests · DoD '||:dod_pct||'</div></td>'
    || '<td width="2%"></td>'
    || '<td width="19%" style="padding:10px;border:1px solid #e5e7eb;border-radius:8px;" align="center"><div style="font-size:22px;font-weight:bold;color:'||IFF(:req_fail>0,'#dc2626','#059669')||';">'||:fail_pct||'%</div><div style="font-size:10px;color:#6b7280;">Failure rate</div></td>'
    || '<td width="2%"></td>'
    || '<td width="19%" style="padding:10px;border:1px solid #e5e7eb;border-radius:8px;" align="center"><div style="font-size:22px;font-weight:bold;">'||:p50_ms||'ms</div><div style="font-size:10px;color:#6b7280;">p50 latency</div></td>'
    || '<td width="2%"></td>'
    || '<td width="19%" style="padding:10px;border:1px solid #e5e7eb;border-radius:8px;" align="center"><div style="font-size:22px;font-weight:bold;">'||:act_users||'/'||:act_models||'</div><div style="font-size:10px;color:#6b7280;">Users / models</div></td>'
    || '<td width="2%"></td>'
    || '<td width="19%" style="padding:10px;border:1px solid #e5e7eb;border-radius:8px;" align="center"><div style="font-size:22px;font-weight:bold;">'||:credits||'</div><div style="font-size:10px;color:#6b7280;">Credits (24h)</div></td>'
    || '</tr></table>'
    || '<div style="margin-top:16px;padding:10px 14px;border-radius:8px;font-size:12px;'
    || IFF(:drift,'background:#fef2f2;color:#991b1b;','background:#f0fdf4;color:#166534;')||'">'
    || 'Spec drift: <b>'||IFF(:drift,'DETECTED','none')||'</b>'
    || ' &nbsp;·&nbsp; Watcher anomalies (24h): <b>'||:anomalies24||'</b>'
    || ' &nbsp;·&nbsp; Billed vs traced (24h): <b>'||:billed24||' / '||:req_ok||'</b>'
    || ' &nbsp;·&nbsp; Tokens in/out: <b>'||:in_tokens||' / '||:out_tokens||'</b></div>'
    || '<div style="margin-top:22px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Requests trend · last 7 days</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin-top:8px;border:1px solid #f3f4f6;border-radius:8px;overflow:hidden;">'
    || :trend_rows || '</table>'
    || '<div style="margin-top:22px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Latency by model · 24h</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin-top:8px;border:1px solid #f3f4f6;border-radius:8px;overflow:hidden;">'
    || '<tr style="background:#f8fafc;"><th align="left" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Model</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Reqs</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">p50</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">p95</th></tr>'
    || :model_rows || '</table>'
    || '<div style="margin-top:22px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Top errors · 7d</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin-top:8px;border:1px solid #f3f4f6;border-radius:8px;overflow:hidden;">'
    || '<tr style="background:#f8fafc;"><th align="left" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Error</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">HTTP</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Count</th></tr>'
    || :err_rows || '</table>'
    || '<div style="margin-top:22px;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:1px;">Showback · last 7 days by user / model</div>'
    || '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin-top:8px;border:1px solid #f3f4f6;border-radius:8px;overflow:hidden;">'
    || '<tr style="background:#f8fafc;"><th align="left" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">User</th><th align="left" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Model</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Reqs</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Tokens in/out</th><th align="right" style="padding:10px 14px;font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;">Credits</th></tr>'
    || :showback || '</table>'
    || '<div style="margin-top:16px;font-size:12px;color:#64748b;">Credits (7d) total: <b>'||:credits7d||'</b></div>'
    || '</div>'
    || '<div style="background:#f8fafc;color:#94a3b8;font-size:11px;padding:14px 28px;border-radius:0 0 14px 14px;border-top:1px solid #e2e8f0;">'
    || 'Hourly anomaly checks run via AI_GW_WATCHER (emails only on issues). Drill down in Snowsight: <b>AI Gateway → Cost</b> for spend, <b>AI Gateway → Observability</b> for traces.</div>'
    || '</div></body></html>';

  CALL SYSTEM$SEND_EMAIL('AI_GW_SHOWBACK_EMAIL','<verified-user-email>', :subject, :body, 'text/html') INTO :sent;
  RETURN 'digest sent=' || :sent::string;
END;
$$;

CREATE OR REPLACE ALERT GOVERNANCE.AUDIT.AI_GW_WATCHER_SCHED
  WAREHOUSE = <WAREHOUSE>
  SCHEDULE = '60 MINUTE'
  IF (EXISTS (SELECT 1))
  THEN CALL GOVERNANCE.AUDIT.AI_GW_WATCHER();

CREATE OR REPLACE ALERT GOVERNANCE.AUDIT.AI_GW_DAILY_DIGEST_SCHED
  WAREHOUSE = <WAREHOUSE>
  SCHEDULE = 'USING CRON 0 13 * * * UTC'
  IF (EXISTS (SELECT 1))
  THEN CALL GOVERNANCE.AUDIT.AI_GW_DAILY_DIGEST();

-- Who may run the procedures on demand (CALL ...). Procedures run EXECUTE AS
-- OWNER, so the caller needs only USAGE on the database, schema and procedure.
-- CREATE OR REPLACE PROCEDURE drops existing grants, so keep these AFTER the
-- procedure DDL and re-run them on every deploy. Replace <CALLER_ROLE>
-- (live account: ACCOUNTADMIN; least-privilege option: AI_GW_MONITOR).
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE <CALLER_ROLE>;
GRANT USAGE ON SCHEMA GOVERNANCE.AUDIT TO ROLE <CALLER_ROLE>;
GRANT USAGE ON PROCEDURE GOVERNANCE.AUDIT.AI_GW_WATCHER() TO ROLE <CALLER_ROLE>;
GRANT USAGE ON PROCEDURE GOVERNANCE.AUDIT.AI_GW_DAILY_DIGEST() TO ROLE <CALLER_ROLE>;

-- Both armed in the live account. To pause:
--   ALTER ALERT GOVERNANCE.AUDIT.AI_GW_WATCHER_SCHED SUSPEND;
--   ALTER ALERT GOVERNANCE.AUDIT.AI_GW_DAILY_DIGEST_SCHED SUSPEND;
