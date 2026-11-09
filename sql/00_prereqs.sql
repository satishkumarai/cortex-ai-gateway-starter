-- 00_prereqs.sql
-- Governance database and schema used by tags, procedures, and audit tables.
-- Run as ACCOUNTADMIN (or a role with CREATE DATABASE).

CREATE DATABASE IF NOT EXISTS GOVERNANCE
  COMMENT = 'Governance objects for Cortex AI Gateway: tags, audit, cutoffs';

CREATE SCHEMA IF NOT EXISTS GOVERNANCE.TAGS
  COMMENT = 'Tags controlling AI Gateway payload-capture exclusion';

CREATE SCHEMA IF NOT EXISTS GOVERNANCE.AUDIT
  COMMENT = 'Audit trail for gateway access revocations and spec changes';

-- Records every budget-triggered or manual gateway cutoff. Written by
-- sql/05_cost/budget_cutoff_procedure.sql.
CREATE TABLE IF NOT EXISTS GOVERNANCE.AUDIT.AI_GW_CUTOFF_LOG (
  EVENT_TS        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  TARGET_ROLE     STRING        NOT NULL,
  ACTION          STRING        NOT NULL,  -- REVOKE | GRANT
  REASON          STRING,
  PERFORMED_BY    STRING        DEFAULT CURRENT_USER()
);
