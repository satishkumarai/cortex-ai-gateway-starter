# Production Implementation Plan

Phased rollout of Cortex AI Gateway from zero to enforced production governance. Each phase has exit criteria and a rollback path. No phase depends on preview features (trace analytics, MCP Tools).

---

## Phase 0 — Baseline and access lockdown

**Goal:** close the default-open gateway before anyone depends on it.

| Step | Action | Reference |
|---|---|---|
| 0.1 | Inventory current AI usage: provider keys in secret stores, team tokens, notebook users | Internal audit |
| 0.2 | Create governance objects | `sql/00_prereqs.sql` |
| 0.3 | Revoke `PUBLIC`, create functional roles, map team roles | `sql/01_rbac.sql` |
| 0.4 | Get the endpoint; record it in your internal docs | `DESCRIBE AI GATEWAY SNOWFLAKE;` |

**Exit criteria:** `SHOW GRANTS ON AI GATEWAY SNOWFLAKE` shows no `PUBLIC` grant; functional roles exist and are mapped.

**Rollback:** re-grant `USAGE` to `PUBLIC` if a hard dependency surfaces (treat as an incident; find the client and onboard it properly).

---

## Phase 1 — Gateway on, metadata-only logging

**Goal:** traffic flows through the gateway; traces record metadata (user, model, tokens, timing); no prompt content yet.

| Step | Action | Reference |
|---|---|---|
| 1.1 | Create the exclusion tag (needed before any payload capture later) | `sql/02_tags.sql` |
| 1.2 | Apply spec with `request_response: false` and explicit model list | `config/`, `sql/03_apply_spec.sql` (edit body) |
| 1.3 | Verify with `DESCRIBE`; set up drift check | `ci/check_spec_drift.py` |
| 1.4 | Onboard ONE pilot team's coding agents | `clients/snow-cli.md` |
| 1.5 | Compare pilot spend/latency against their previous direct-key usage | `sql/05_cost/showback_by_user.sql` |

**Exit criteria:** pilot team's requests appear in `AGENT_TRACE_TABLE` with correct user attribution; no prompt content stored; drift check green.

**Rollback:** pilot team reverts to direct keys while you fix issues (gateway is additive at this stage).

---

## Phase 2 — Full client migration

**Goal:** all teams' agents, SDKs, and apps route through the gateway; old provider keys revoked.

| Step | Action | Reference |
|---|---|---|
| 2.1 | Roll out team by team (agents via `snow ai` or manual config) | `clients/` |
| 2.2 | Enable OTLP export for clients that support it | `clients/python/anthropic_sdk_otel.py`, `clients/opencode/` |
| 2.3 | Verify trace-context propagation (`traceparent`) joins client and gateway spans | `sql/04_observability/inspect_turn.sql` |
| 2.4 | Revoke legacy provider API keys from secret stores | Cloud provider consoles |
| 2.5 | Stand up showback reporting for FinOps | `sql/05_cost/showback_by_user.sql` |

**Exit criteria:** no active provider keys outside the gateway; 100% of known AI clients attributed in usage history; FinOps consuming weekly showback.

**Rollback:** per-client — point an individual client back at its provider key if the gateway blocks a critical workflow (log as incident).

---

## Phase 3 — Enforcement

**Goal:** spend limits and alerting that act, not just report.

| Step | Action | Reference |
|---|---|---|
| 3.1 | Create shared resource budgets per team (scoped by user tag) — **edition-gated:** `CREATE BUDGET` is unsupported in some editions; configure in Snowsight → AI Gateway → Cost | Cost management docs |
| 3.2 | Deploy and test the cutoff procedure against ONE team in a drill | `sql/05_cost/budget_cutoff_procedure.sql` |
| 3.3 | Wire budget thresholds to the procedure | Snowsight Cost UI (budgets are UI-configured, not SQL, in this edition) |
| 3.4 | Set per-user quotas, sized from observed history; separate service-user quotas from human quotas | Snowsight Cost UI |
| 3.5 | Deploy consolidated alerting: hourly anomaly watcher + daily dashboard digest | `sql/06_alerts.sql` |
| 3.6 | Write the re-grant runbook before the first real threshold fires | `docs/runbooks/budget-cutoff.md` |

**Exit criteria:** drill proves revoke → audit log → re-grant works end to end; watcher fires on synthetic drift/failure; digest renders; budgets/quotas configured via UI where the edition supports them.

**Rollback:** remove budget actions (keep notifications); suspend alerts.

---

## Phase 4 — Payload capture (optional, deliberate)

**Goal:** full prompt/response capture for the teams and use cases that justify it.

**Do this only after:** trace table is classified as sensitive, access is restricted, retention is set, and the exclusion tag process is agreed with security/legal.

| Step | Action |
|---|---|
| 4.1 | Decide per-population capture policy with security/legal |
| 4.2 | Apply exclusion tag to the agreed population |
| 4.3 | Spec PR enabling `request_response: true` with `exclude_tags` |
| 4.4 | Validate: tagged users produce metadata-only rows; others produce full rows |
| 4.5 | Re-baseline storage costs (payload capture increases event-table volume) |

**Exit criteria:** capture behaves per policy; exclusion verified with a test user; storage cost reviewed.

**Rollback:** spec PR setting `request_response: false` — takes effect immediately for new requests.

---

## Phase 5 — MCP Tools (preview — plan, don't bet on it)

Available in AWS commercial regions only. Only `ACCOUNTADMIN` can administer servers today.

1. Enable one read-heavy server (e.g. GitHub) with a **tool allowlist limited to read-only tools** — unconfigured servers default to all tools.
2. Grant `SNOWFLAKE$OPS.MCP$USER` to the relevant account roles for client discovery.
3. Review provider consent policies before enabling OAuth servers.
4. Audit tool-call activity in `AGENT_TRACE_TABLE` / Tools Activity tab.
5. Reassess when Tools reaches GA in your region/cloud.

---

## Standing operations

- **Hourly:** spec drift check (`ci/check_spec_drift.py`)
- **Weekly:** showback review with FinOps; failure-rate trends
- **Monthly:** quota sizing review; model allow-list review (new models onboarded via PR)
- **Quarterly:** trace-table retention review; access review of `AI_GW_MONITOR` and tag `APPLY` holders
