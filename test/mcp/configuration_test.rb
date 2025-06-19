# frozen_string_literal: true

require "test_helper"

module MCP
  class ConfigurationTest < ActiveSupport::TestCase
    test "initializes with a default no-op exception reporter" do
      config = Configuration.new
      assert_respond_to config, :exception_reporter

      # The default reporter should be callable but do nothing
      exception = StandardError.new("test error")
      server_context = { test: "context" }

      # Should not raise any errors
      config.exception_reporter.call(exception, server_context)
    end

    test "allows setting a custom exception reporter" do
      config = Configuration.new
      reported_exception = nil
      reported_context = nil

      config.exception_reporter = ->(exception, server_context) do
        reported_exception = exception
        reported_context = server_context
      end

      test_exception = StandardError.new("test error")
      test_context = { foo: "bar" }

      config.exception_reporter.call(test_exception, test_context)

      assert_equal test_exception, reported_exception
      assert_equal test_context, reported_context
    end

    test "initializes with default protocol version" do
      config = Configuration.new
      assert_equal Configuration::DEFAULT_PROTOCOL_VERSION, config.protocol_version
    end

    test "allows setting a custom protocol version" do
      config = Configuration.new
      custom_version = "2025-03-27"
      config.protocol_version = custom_version
      assert_equal custom_version, config.protocol_version
    end

    test "merges protocol version from other configuration" do
      config1 = Configuration.new(protocol_version: "2025-03-27")
      config2 = Configuration.new(protocol_version: "2025-03-28")
      config3 = Configuration.new

      merged = config1.merge(config2)
      assert_equal "2025-03-28", merged.protocol_version

      merged = config1.merge(config3)
      assert_equal "2025-03-27", merged.protocol_version

      merged = config3.merge(config1)
      assert_equal "2025-03-27", merged.protocol_version
    end

    test "defaults validate_tool_call_arguments to true" do
      config = Configuration.new
      assert config.validate_tool_call_arguments
    end

    test "can set validate_tool_call_arguments to false" do
      config = Configuration.new(validate_tool_call_arguments: false)
      refute config.validate_tool_call_arguments
    end

    test "validate_tool_call_arguments? returns false when set" do
      config = Configuration.new(validate_tool_call_arguments: false)
      refute config.validate_tool_call_arguments?
    end

    test "validate_tool_call_arguments? returns true when not set" do
      config = Configuration.new
      assert config.validate_tool_call_arguments?
    end

    test "merge preserves validate_tool_call_arguments from other config" do
      config1 = Configuration.new(validate_tool_call_arguments: false)
      config2 = Configuration.new
      merged = config1.merge(config2)
      assert merged.validate_tool_call_arguments?
    end

    test "merge preserves validate_tool_call_arguments from self when other not set" do
      config1 = Configuration.new(validate_tool_call_arguments: false)
      config2 = Configuration.new
      merged = config2.merge(config1)
      refute merged.validate_tool_call_arguments
    end

    test "raises ArgumentError when validate_tool_call_arguments is not a boolean" do
      assert_raises(ArgumentError) do
        Configuration.new(validate_tool_call_arguments: "true")
      end
    end
  end
end
