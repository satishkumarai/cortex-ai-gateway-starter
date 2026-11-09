-- 01_rbac.sql
-- Default-deny access model for Cortex AI Gateway.
-- Run as ACCOUNTADMIN.
--
-- The gateway is provisioned automatically with USAGE granted to PUBLIC.
-- Step 1 closes that. Do it BEFORE announcing the endpoint: once clients
-- depend on implicit access, every later restriction becomes an outage.

USE ROLE ACCOUNTADMIN;

-- 1. Close the default-open path
REVOKE USAGE ON AI GATEWAY SNOWFLAKE FROM ROLE PUBLIC;

-- 2. Functional roles
CREATE ROLE IF NOT EXISTS AI_GW_USER
  COMMENT = 'May send inference requests through Cortex AI Gateway';
CREATE ROLE IF NOT EXISTS AI_GW_MONITOR
  COMMENT = 'Reads all gateway usage data and every user''s traces';

-- 3. Gateway privileges (path vs oversight are deliberately separate)
GRANT USAGE   ON AI GATEWAY SNOWFLAKE TO ROLE AI_GW_USER;
GRANT MONITOR ON AI GATEWAY SNOWFLAKE TO ROLE AI_GW_MONITOR;

-- 4. Model entitlement is SEPARATE from the gateway path.
--    USAGE on the gateway does not widen model access.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AI_GW_USER;

-- 5. Map team roles onto the functional roles.
--    Adjust to your org's role model.
CREATE ROLE IF NOT EXISTS DATA_ENG_TEAM;
CREATE ROLE IF NOT EXISTS APP_DEV_TEAM;
CREATE ROLE IF NOT EXISTS FINOPS;
CREATE ROLE IF NOT EXISTS SECURITY_OPS;

GRANT ROLE AI_GW_USER    TO ROLE DATA_ENG_TEAM;
GRANT ROLE AI_GW_USER    TO ROLE APP_DEV_TEAM;
GRANT ROLE AI_GW_MONITOR TO ROLE FINOPS;
GRANT ROLE AI_GW_MONITOR TO ROLE SECURITY_OPS;

-- Notes:
-- - A role with USAGE but no MONITOR sees only its own spans in
--   AGENT_TRACE_TABLE. That is the right default for developers.
-- - MONITOR reads every user's traces. Treat it as a data-access grant
--   and keep membership small.
