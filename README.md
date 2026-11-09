# Cortex AI Gateway — Production Starter Kit

A production-grade reference implementation for running **Snowflake Cortex AI Gateway** as your organization's single, governed endpoint for AI inference, observability, cost management, and MCP tool access.

> Cortex AI Gateway is where you govern how AI clients in your organization reach the models and systems they act on. Each account has a single gateway object, named `SNOWFLAKE`, provisioned automatically.

## What this repo gives you

| Area | What's included |
|---|---|
| Access control | Default-deny RBAC (`USAGE` / `MONITOR` / `CORTEX_USER` separation) |
| Gateway configuration | Spec-as-code (explicit model allow-list, logging, payload exclusion tags) |
| Observability | Verified SQL against `AGENT_TRACE_TABLE` (turns, spans, reliability, tokens) |
| Cost management | Showback queries, budget-triggered cutoff procedure (budgets are UI-only in some editions) |
| Alerting | Consolidated native alerts: hourly anomaly watcher + daily dashboard digest, HTML email via notification integration |
| Client onboarding | Anthropic SDK with OTLP tracing, OpenCode config, `snow ai` CLI patterns |
| Operations | Runbooks for spec drift, budget cutoff, incident response |
| CI | YAML validation + spec drift detection |
| Documentation | Architecture decision records, phased implementation plan, Medium article |

## Repository layout

```
├── config/            # Gateway specifications (production + sandbox)
├── sql/               # Runnable, ordered SQL scripts (00 → 06)
├── clients/           # SDK and coding-agent configurations
├── ci/                # Spec validation and drift detection
├── docs/
│   ├── architecture.md          # Before/after, trust boundaries, ADRs
│   ├── implementation-plan.md   # Phased production rollout
│   ├── runbooks/                # Spec drift, budget cutoff, incident response
│   └── medium/                  # Publish-ready Medium article
├── .github/           # PR template + validation workflow
└── Makefile           # lint / validate entry points
```

## Quickstart

**Prerequisites:** `ACCOUNTADMIN` (or a role delegated to administer the gateway), and the gateway endpoint from `DESCRIBE AI GATEWAY SNOWFLAKE`.

```bash
# 1. Close the default-open gateway (USAGE is granted to PUBLIC by default)
snow sql -f sql/01_rbac.sql

# 2. Create the payload-exclusion tag
snow sql -f sql/02_tags.sql

# 3. Review and apply the production spec (edit config/ first)
snow sql -f sql/03_apply_spec.sql

# 4. Verify what the gateway is actually running
snow sql -q "DESCRIBE AI GATEWAY SNOWFLAKE;"
```

Then onboard your first client: see [`clients/`](clients/) for the Anthropic SDK with OTLP tracing, OpenCode, and `snow ai` examples.

## Verified in a live account

All SQL, YAML, and client configurations are grounded in the published Cortex AI Gateway documentation — and the core of this kit was **executed in a live account** (Nov 2026): spec apply + DESCRIBE round-trip, default-deny grants, PAT auth (incl. the network-policy requirement and `DAYS_TO_EXPIRY` syntax), a real Messages-API call, trace-table and usage-view verification (incl. the actual `AI_GATEWAY_USAGE_HISTORY` schema with model-keyed OBJECTs), a full failure drill (denied/malformed/token-limit), exclusion-tag payload suppression, a budget-cutoff drill, and consolidated native alerting (hourly anomaly watcher + daily dashboard digest) with HTML email delivery — all proven end to end. Remaining `VERIFY:` markers call out edition-gated features (budget/quota SQL) and region-specific model availability. No fabricated syntax, metrics, or benchmarks.

## Alerting architecture (live)

| Object | Cadence | Behavior |
|---|---|---|
| `AI_GW_WATCHER_SCHED` → `AI_GW_WATCHER()` | Hourly | Checks spec drift, failure-rate spike, HTTP 429 burst. Emails **only on anomaly** (red dashboard card). Logs every run. |
| `AI_GW_DAILY_DIGEST_SCHED` → `AI_GW_DAILY_DIGEST()` | Daily 13:00 UTC | Dashboard email: KPIs, 7-day trend chart, per-model latency, top errors, showback, drift/reconciliation status. |

Both use `GOVERNANCE.AUDIT.AI_GW_ALERT_LOG` + `AI_GW_SHOWBACK_EMAIL` (notification integration). No separate threshold alerts, no automation fires, no `--without-read-only`.

## Important caveats

- `ALTER AI GATEWAY ... FROM SPECIFICATION` **replaces the entire spec**. Never hand-patch; always apply the full versioned spec from `config/`.
- `USAGE` on the gateway does **not** grant model access. A request still needs `SNOWFLAKE.CORTEX_USER` or model-level controls. The gateway governs the path, not the entitlement.
- Enabling `capture_payload.request_response` stores every prompt and response in an event table in your account. Treat that table as sensitive data with retention and access controls.
- MCP Tools is **preview** and available in AWS commercial regions only.

## License

Apache 2.0 — see [LICENSE](LICENSE).
