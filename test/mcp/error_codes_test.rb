# frozen_string_literal: true

require "test_helper"

module MCP
  class ErrorCodesTest < ActiveSupport::TestCase
    test "exposes the SEP-2575 stateless lifecycle error codes" do
      # The exact values are wire vocabulary shared with other SDKs.
      assert_equal(-32021, ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY)
      assert_equal(-32022, ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION)
    end
  end
end
