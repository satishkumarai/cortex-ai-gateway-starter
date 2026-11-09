-- budget_cutoff_procedure.sql
-- Stored procedure called by a shared resource budget at threshold to
-- revoke a team role's gateway access.
--
-- NOTE (edition-gated): shared budgets / per-user quotas are configured in
-- the Snowsight AI Gateway > Cost UI (CREATE BUDGET is unsupported in this
-- account edition). Wire this procedure as the budget's action there.
-- The procedure itself is deployed and drill-tested.
--
-- Design:
--  * Validates the target role against an allow-list before dynamic SQL.
--  * Revokes ROLE AI_GW_USER (the path), leaving model entitlements and
--    the team role itself untouched.
--  * Logs every action to GOVERNANCE.AUDIT.AI_GW_CUTOFF_LOG.
--  * Idempotent: re-running a revoke is a no-op.

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE PROCEDURE GOVERNANCE.AUDIT.AI_GW_CUTOFF(
  TEAM_ROLE STRING,
  ACTION    STRING,   -- 'REVOKE' or 'GRANT'
  REASON    STRING
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  ALLOWED_ROLES ARRAY := ['DATA_ENG_TEAM', 'APP_DEV_TEAM'];
  UPPER_ROLE    STRING := UPPER(:TEAM_ROLE);
  UPPER_ACTION  STRING := UPPER(:ACTION);
BEGIN
  IF (NOT ARRAY_CONTAINS(UPPER_ROLE::VARIANT, :ALLOWED_ROLES)) THEN
    RETURN 'REFUSED: role ' || :UPPER_ROLE || ' is not in the cutoff allow-list';
  END IF;

  IF (UPPER_ACTION NOT IN ('REVOKE', 'GRANT')) THEN
    RETURN 'REFUSED: action must be REVOKE or GRANT';
  END IF;

  -- Plain identifier concatenation is safe here: UPPER_ROLE passed the
  -- allow-list check above. IDENTIFIER() is avoided deliberately — inside
  -- EXECUTE IMMEDIATE's string expression it does not behave as an
  -- identifier binder.
  EXECUTE IMMEDIATE
    UPPER_ACTION || ' ROLE AI_GW_USER ' ||
    IFF(UPPER_ACTION = 'REVOKE', 'FROM', 'TO') ||
    ' ROLE "' || UPPER_ROLE || '"';

  INSERT INTO GOVERNANCE.AUDIT.AI_GW_CUTOFF_LOG (TARGET_ROLE, ACTION, REASON)
  VALUES (:UPPER_ROLE, :UPPER_ACTION, :REASON);

  RETURN UPPER_ACTION || ' AI_GW_USER for ' || :UPPER_ROLE;
END;
$$;

-- Companion: re-grant runbook.
-- When a team's budget resets or an exception is approved:
--   CALL GOVERNANCE.AUDIT.AI_GW_CUTOFF('DATA_ENG_TEAM', 'GRANT', 'budget reset 2026-11');
-- Write this runbook BEFORE the first threshold fires.
