# Runbook: Gateway spec drift

**Trigger:** an `AI_GW_WATCHER` anomaly email (spec-drift card red, "Spec drift: DETECTED"), `ci/check_spec_drift.py` exits non-zero, or the daily digest shows drift. The hourly `AI_GW_WATCHER_SCHED` alert runs `DESCRIBE AI GATEWAY SNOWFLAKE` and compares to the expected spec — this is the live drift detector (it replaced the earlier standalone drift-check automation).

Spec drift means the live gateway no longer matches `config/gateway-spec.production.yaml`. Because `ALTER ... FROM SPECIFICATION` replaces the **entire** spec, a partial hand edit silently reverts every omitted field to its default — the classic case is losing `capture_payload` settings.

## 1. Get both versions

```sql
DESCRIBE AI GATEWAY SNOWFLAKE;   -- live
```

The expected state is `config/gateway-spec.production.yaml` in Git.

## 2. Find who changed it

```sql
-- Who ran ALTER AI GATEWAY recently?
SELECT query_text, user_name, role_name, start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type = 'ALTER'
  AND UPPER(query_text) LIKE '%AI GATEWAY%'
  AND start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

(Adjust the filter to the exact query type string if needed — `VERIFY` in your account.)

## 3. Decide: adopt or revert

- **The live change was intentional** (emergency model addition during an incident): PR it into `config/` so Git becomes truth again. Include the incident ticket in the PR.
- **The live change was accidental or unreviewed:** re-apply the versioned spec.

## 4. Re-apply (if reverting)

Use `sql/03_apply_spec.sql`, which applies the full spec from `config/` and verifies with `DESCRIBE` afterwards. Do not try to "patch back" individual fields — full replacement is the only safe operation.

## 5. Confirm

```bash
python3 ci/check_spec_drift.py --expected config/gateway-spec.production.yaml
# expect: OK: live gateway spec matches versioned spec
```

## Prevention

- All spec changes via PR → CI validation → apply job. No console/SQL hand edits.
- Schedule the drift check (hourly) rather than relying on PR discipline alone.
- Keep the apply script's inline spec body generated from `config/` rather than maintained as a second copy.
