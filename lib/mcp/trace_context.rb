# frozen_string_literal: true

module MCP
  # Reserved `_meta` keys for W3C Trace Context propagation, per SEP-414.
  #
  # The MCP spec reserves the un-prefixed `_meta` keys `traceparent`, `tracestate`, and `baggage`
  # (an explicit exception to the reverse-DNS prefix rule for `_meta` keys) so that clients and
  # servers can propagate distributed-tracing context across MCP requests.
  # The SDK guarantees these keys pass through incoming request `_meta` untouched; tool, prompt,
  # and resource handlers can read them from `server_context[:_meta]` and bridge them to a tracing
  # system such as the `opentelemetry-ruby` gems. The SDK itself does not depend on OpenTelemetry.
  #
  # - https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414
  # - https://www.w3.org/TR/trace-context/
  # - https://www.w3.org/TR/baggage/
  module TraceContext
    TRACEPARENT_META_KEY = "traceparent"
    TRACESTATE_META_KEY = "tracestate"
    BAGGAGE_META_KEY = "baggage"

    META_KEYS = [TRACEPARENT_META_KEY, TRACESTATE_META_KEY, BAGGAGE_META_KEY].freeze
  end
end
