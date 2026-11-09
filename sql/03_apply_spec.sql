-- 03_apply_spec.sql
-- Apply the production gateway specification.
-- Run as ACCOUNTADMIN.
--
-- CRITICAL: ALTER AI GATEWAY ... FROM SPECIFICATION replaces the ENTIRE
-- specification. Any field you leave out reverts to its default — it is
-- NOT merged with the previous state. Always:
--   1. Capture current state (DESCRIBE)
--   2. Apply the full versioned spec from config/gateway-spec.production.yaml
--   3. Capture again and diff

USE ROLE ACCOUNTADMIN;

-- Step 1: current state (archive before changing)
DESCRIBE AI GATEWAY SNOWFLAKE;

-- Step 2: apply the full spec.
-- The body below MUST mirror config/gateway-spec.production.yaml exactly.
-- Prefer driving this from CI (see ci/check_spec_drift.py) rather than
-- hand-editing SQL.
ALTER AI GATEWAY SNOWFLAKE FROM SPECIFICATION $$
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
$$;

-- Step 3: verify what the gateway is actually running
DESCRIBE AI GATEWAY SNOWFLAKE;

-- Notes:
-- - ALTER fails if a listed exclude_tag does not exist. Run 02_tags.sql
--   before this script.
-- - If a listed tag is later dropped, it no longer excludes users.
