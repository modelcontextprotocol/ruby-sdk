# frozen_string_literal: true

require "test_helper"

module MCP
  class ProtocolDeprecationsTest < ActiveSupport::TestCase
    test "roots, sampling, and logging are deprecated in 2026-07-28 and later" do
      refute ProtocolDeprecations.deprecated_roots_sampling_logging?(nil)
      refute ProtocolDeprecations.deprecated_roots_sampling_logging?("2025-11-25")
      assert ProtocolDeprecations.deprecated_roots_sampling_logging?("2026-07-28")
      assert ProtocolDeprecations.deprecated_roots_sampling_logging?("2027-01-01")
    end
  end
end
