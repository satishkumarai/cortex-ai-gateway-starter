"""Anthropic SDK client with OTLP tracing to Cortex AI Gateway.

VERIFIED against the gateway observability docs (Trace Claude requests >
Claude SDK Python; Send client traces to the gateway).

The plain `anthropic` SDK does NOT auto-instrument. The verified pattern is:
  1. Create a manual client span around the call.
  2. Inject its W3C `traceparent` context into the request via
     `extra_headers`, so the gateway server span joins the same trace_id.
  3. Export the client span to the gateway at
     <gateway-endpoint>/telemetry/v1/traces.

Note: per the Trace Analytics docs, client OTLP spans land in the trace table
but are NOT counted in the Snowsight Trace Analytics charts (those cover
gateway-side model/tool spans only). The joined trace_id still lets you
correlate client and server spans in AGENT_TRACE_TABLE.
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   165  100    92  100    73    133    105 --:--:-- --:--:-- --:--:--   239
HTTP/2 400 
content-length: 92
content-type: application/json
date: Mon, 09 Nov 2026 08:16:10 GMT
x-snowflake-request-id: 6edac5a0-a83a-9ce6-93d4-9b65f8cc4be8
server: SF-LB-T1
x-envoy-upstream-service-time: 15
x-content-type-options: nosniff
x-xss-protection: 1; mode=block
expect-ct: enforce, max-age=3600
strict-transport-security: max-age=31536000; includeSubDomains
x-frame-options: deny

{"message":"invalid request parameters: the requested model does not support this endpoint"}%  
Prerequisites:
  * logging.enabled: true and logging.enable_client_telemetry: true in
    the gateway specification.
  * pip install anthropic opentelemetry-sdk \
      opentelemetry-exporter-otlp-proto-http
"""

import os

from anthropic import Anthropic
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.propagate import inject
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

GATEWAY_ENDPOINT = os.environ["SNOWFLAKE_GATEWAY_ENDPOINT"]
PAT = os.environ["SNOWFLAKE_TOKEN"]  # OAuth token, key-pair JWT, or PAT

provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint=f"{GATEWAY_ENDPOINT}/telemetry/v1/traces",
            headers={"Authorization": f"Bearer {PAT}"},
        )
    )
)
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)
client = Anthropic(base_url=GATEWAY_ENDPOINT, auth_token=PAT)

# Manual client span; inject its traceparent into the request headers so the
# gateway's server span shares the same trace_id.
with tracer.start_as_current_span("anthropic.messages.create") as span:
    headers = {}
    inject(headers)  # adds W3C `traceparent` (and `tracestate`) to headers
    message = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1024,
        extra_headers=headers,
        messages=[
            {"role": "user", "content": "How does a snowflake get its unique pattern?"}
        ],
    )
    span.set_attribute("gen_ai.response.model", message.model)

print(message.content)

provider.force_flush()

# Notes:
# - Verify in AGENT_TRACE_TABLE: TWO spans sharing one trace_id — the client
#   span (scope name = this module's tracer) and the gateway server span
#   (scope name 'aigateway/tracing').
# - To record prompts/responses client-side, set them as span attributes; see
#   the SDK options. Gateway-side payload capture additionally requires
#   logging.capture_payload.request_response: true in the spec.
# - x-snowflake-ai-gateway-conversation-id groups turns into a conversation;
#   add it to extra_headers (stable UUID per session) for the Sessions view.
