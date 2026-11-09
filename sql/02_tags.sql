-- 02_tags.sql
-- Payload-capture exclusion tag for Cortex AI Gateway.
-- Run as ACCOUNTADMIN (or a role with CREATE TAG on GOVERNANCE.TAGS).
--
-- Users with this tag set DIRECTLY on them get metadata-only logging
-- even when logging.capture_payload.request_response is true.
-- Excluded: their prompts, model responses, and tool content.
-- Still logged: metadata (user, model, tokens, timing).
--
-- Semantics (per docs):
--   * Only tags set directly on users count — not role or account tags.
--   * The tag's VALUE is irrelevant; presence is what matters.
--   * Setting/unsetting takes effect on the user's NEXT request.
--   * If the gateway can't determine exclusion, it fails closed
--     (payload NOT captured for that request).
--
-- TRUST BOUNDARY: anyone who can APPLY this tag can disable auditing of
-- a user's prompts. Keep it dedicated to this purpose, restrict APPLY to
-- the security team, and audit global APPLY TAG holders.

USE ROLE ACCOUNTADMIN;

CREATE TAG IF NOT EXISTS GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT
  COMMENT = 'Users with this tag get metadata-only AI Gateway logging';

-- Example: exclude an executive / HR / legal user.
-- Replace EXEC_USER with real usernames as needed.
-- ALTER USER EXEC_USER SET TAG GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT = 'true';

-- Restrict who can apply the tag: a dedicated TAG_ADMIN role (delegated
-- to SECURITY_OPS). Do not rely on the global APPLY TAG privilege.
-- IMPLEMENTED in live account (JK62811).
CREATE ROLE IF NOT EXISTS TAG_ADMIN
  COMMENT = 'Owns APPLY on governance tags, incl. AI gateway payload-capture exclusion';
GRANT APPLY ON TAG GOVERNANCE.TAGS.PAYLOAD_CAPTURE_EXEMPT TO ROLE TAG_ADMIN;
GRANT ROLE TAG_ADMIN TO ROLE SECURITY_OPS;

-- NOTE on trace-table classification: gateway traces land in
-- SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS (verified via SHOW EVENT TABLES),
-- which is owned by the SNOWFLAKE application — customers cannot tag or
-- alter retention on it directly. Payload-captured prompts therefore rely
-- on (a) MONITOR privilege discipline, (b) the exclusion tag, and
-- (c) Snowflake-side retention (1 day observed in the events table
-- retention_time). Document this in your data-classification register;
-- do NOT assume you can RETENTION-tune or tag that table yourself.
