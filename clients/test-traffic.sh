#!/usr/bin/env bash
# test-traffic.sh — generate smoke-test traffic through Cortex AI Gateway.
#
# Run from any machine that can reach your account host (NOT the Snowsight
# sandbox — its egress proxy blocks direct HTTPS to the account host).
#
# Prereq: a PAT. NOTE: a PAT works only for a user SUBJECT TO A NETWORK
# POLICY — without one you get a bare HTTP 401 with an empty body.
#   ALTER USER <user> ADD PROGRAMMATIC ACCESS TOKEN ai_gw_test DAYS_TO_EXPIRY = 1;
#   CREATE NETWORK POLICY IF NOT EXISTS AI_GW_PAT_NP ALLOWED_IP_LIST = ('<your-cidr>');
#   ALTER USER <user> SET NETWORK_POLICY = AI_GW_PAT_NP;
#
# Verified: DAYS_TO_EXPIRY is the correct property (EXPIRES_IN_DAYS is not
# valid for PROGRAMMATIC_ACCESS_TOKEN in this release).
#
# Usage:  SNOWFLAKE_TOKEN=<pat> ./test-traffic.sh

set -euo pipefail

GW="${GW_ENDPOINT:-https://<account-host>/api/v2/aigateways/snowflake}"
TOKEN="${SNOWFLAKE_TOKEN:?export SNOWFLAKE_TOKEN first}"

echo "== 3 successful Messages-API calls (model must be in the spec allow-list) =="
for i in 1 2 3; do
  curl -sS -X POST "$GW/v1/messages" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"claude-haiku-4-5\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong $i\"}]}"
  echo
done

echo "== 1 deliberate failure: Claude on Chat Completions (endpoint mismatch -> traced 400) =="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hi"}]}'

echo "Done. Verify in Snowflake:"
echo "  SELECT * FROM TABLE(AGENT_TRACE_TABLE('SNOWFLAKE'))"
echo "    WHERE timestamp >= DATEADD(hour,-1,SYSDATE());"
