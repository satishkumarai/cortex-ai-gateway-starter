# Launching a coding agent via Snowflake CLI

`snow ai` launches a locally installed coding agent with model traffic already routed through the gateway, using the endpoint and credential from a Snowflake CLI connection (OAuth or PAT).

```bash
snow ai opencode
```

Pass agent arguments after `--agent-args`:

```bash
snow ai opencode -c <connection> --agent-args -m snowflake-cortex/claude-sonnet-4-6
```

See `snow ai commands` in the Snowflake CLI docs for supported agents and authenticators.

## Manual setup

For an agent `snow ai` doesn't launch, or when configuration must persist outside the CLI:

- Any client that lets you set a custom base URL + bearer token and speaks Chat Completions (`/v1/chat/completions`), Messages (`/v1/messages`), or Responses (`/v1/responses`, preview) can use the gateway.
- Get the base URL from `DESCRIBE AI GATEWAY SNOWFLAKE` — never assemble it by hand (private-connectivity accounts use a different host).
- Send the token as `Authorization: Bearer <token>` (OAuth access token, key-pair JWT, or PAT; short-lived OAuth preferred).
- Send a `traceparent` header (W3C Trace Context) for client spans to join gateway spans under one `trace_id`. Send `x-snowflake-ai-gateway-conversation-id` to group multi-turn conversations.

See `clients/opencode/opencode.json` for a complete manual example including the OTel plugin configuration.
