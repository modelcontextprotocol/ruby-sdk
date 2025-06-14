# typed: strict
# frozen_string_literal: true

require "test_helper"

module MCP
  class MethodsTest < ActiveSupport::TestCase
    class << self
      def ensure_capability_raises_error_for(method, required_capability_name:, capabilities: {})
        test("ensure_capability! for #{method} raises an error if #{required_capability_name} capability is not present") do
          error = assert_raises(Methods::MissingRequiredCapabilityError) do
            Methods.ensure_capability!(method, capabilities)
          end
          assert_equal("Server does not support #{required_capability_name} (required for #{method})", error.message)
        end
      end

      def ensure_capability_does_not_raise_for(method, capabilities: {})
        test("ensure_capability! does not raise for #{method}") do
          assert_nothing_raised { Methods.ensure_capability!(method, capabilities) }
        end
      end
    end

    # Tools capability tests
    ensure_capability_raises_error_for Methods::TOOLS_LIST, required_capability_name: "tools"
    ensure_capability_raises_error_for Methods::TOOLS_CALL, required_capability_name: "tools"

    # Sampling capability tests
    ensure_capability_raises_error_for Methods::SAMPLING_CREATE_MESSAGE, required_capability_name: "sampling"

    # Completions capability tests
    ensure_capability_raises_error_for Methods::COMPLETION_COMPLETE, required_capability_name: "completions"

    # Logging capability tests
    ensure_capability_raises_error_for Methods::LOGGING_SET_LEVEL, required_capability_name: "logging"

    # Prompts capability tests
    ensure_capability_raises_error_for Methods::PROMPTS_GET, required_capability_name: "prompts"
    ensure_capability_raises_error_for Methods::PROMPTS_LIST, required_capability_name: "prompts"

    # Resources capability tests
    ensure_capability_raises_error_for Methods::RESOURCES_LIST, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_TEMPLATES_LIST, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_READ, required_capability_name: "resources"

    # Resources subscribe capability tests
    ensure_capability_raises_error_for Methods::RESOURCES_SUBSCRIBE,
      required_capability_name: "resources_subscribe",
      capabilities: { resources: {} }

    # Methods that don't require capabilities
    ensure_capability_does_not_raise_for Methods::PING
    ensure_capability_does_not_raise_for Methods::INITIALIZE
  end
end
