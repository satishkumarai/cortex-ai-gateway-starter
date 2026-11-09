# Contributing

## Ground rules

1. **Never invent syntax.** Every SQL statement, spec field, and client configuration must be verifiable against current Snowflake documentation. If it cannot be verified, mark it with a `VERIFY:` comment explaining what to confirm and where.
2. **No fabricated metrics.** Do not add benchmark numbers, cost figures, or performance claims that were not measured. Describe effects qualitatively or cite the source.
3. **Spec changes go through review.** `config/gateway-spec.production.yaml` is production state. Changes require a PR, YAML validation in CI, and a `DESCRIBE` diff plan in the PR description.
4. **SQL must be runnable top-to-bottom.** Scripts are idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`) and ordered. Do not rely on hidden session state.
5. **Secrets never enter the repo.** Tokens come from environment variables or the Snowflake CLI connection context.

## Pull request process

- Run `make validate` before opening a PR.
- CI runs YAML lint and spec validation on every PR.
- For spec changes, include the output of `DESCRIBE AI GATEWAY SNOWFLAKE` (current) and the expected diff in the PR body.
