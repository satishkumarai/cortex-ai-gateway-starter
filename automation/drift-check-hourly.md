# NOTE: this automation is SUSPENDED. Spec drift is now detected natively
# by the hourly AI_GW_WATCHER alert (sql/06_alerts.sql). Kept for reference.

You are running unattended in a Snowflake AGENT TASK; complete the task autonomously and do NOT ask clarifying questions.

Task: detect drift between the live Cortex AI Gateway spec and the expected production spec.

1. Run this SQL: DESCRIBE AI GATEWAY SNOWFLAKE;
   Read the specification column from the result.

2. Compare it semantically (field-by-field, ignore whitespace/ordering) to this expected spec:

schema_version: 1
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
      - GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT

3. As your final message, report: whether the live spec matches, and if it DRIFTED, show the exact fields that differ and note that someone may have edited the gateway outside the Git-managed spec.

4. Then print exactly this status line on its own line:
DRIFT_CHECK_OK drift=<yes|no>
or, on failure:
DRIFT_CHECK_FAILED:<one-line reason>
