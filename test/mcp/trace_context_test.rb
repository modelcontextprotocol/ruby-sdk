# frozen_string_literal: true

require "test_helper"

module MCP
  class TraceContextTest < ActiveSupport::TestCase
    test "exposes the W3C Trace Context reserved _meta key names" do
      # The exact un-prefixed names are reserved by SEP-414; renaming any of them
      # would break interoperability with other SDKs.
      assert_equal "traceparent", TraceContext::TRACEPARENT_META_KEY
      assert_equal "tracestate", TraceContext::TRACESTATE_META_KEY
      assert_equal "baggage", TraceContext::BAGGAGE_META_KEY
    end

    test "META_KEYS lists all reserved keys and is frozen" do
      assert_equal ["traceparent", "tracestate", "baggage"], TraceContext::META_KEYS
      assert_predicate TraceContext::META_KEYS, :frozen?
    end
  end
end
