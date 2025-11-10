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

    # Server methods and notifications
    ensure_capability_does_not_raise_for Methods::INITIALIZE

    ensure_capability_raises_error_for Methods::PROMPTS_LIST, required_capability_name: "prompts"
    ensure_capability_raises_error_for Methods::PROMPTS_GET, required_capability_name: "prompts"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED, required_capability_name: "prompts"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED,
      required_capability_name: "prompts.listChanged",
      capabilities: { prompts: {} }

    ensure_capability_raises_error_for Methods::RESOURCES_LIST, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_READ, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_TEMPLATES_LIST, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED,
      required_capability_name: "resources.listChanged",
      capabilities: { resources: {} }
    ensure_capability_raises_error_for Methods::RESOURCES_SUBSCRIBE, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_SUBSCRIBE,
      required_capability_name: "resources.subscribe",
      capabilities: { resources: {} }
    ensure_capability_raises_error_for Methods::RESOURCES_UNSUBSCRIBE, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::RESOURCES_UNSUBSCRIBE,
      required_capability_name: "resources.subscribe",
      capabilities: { resources: {} }
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_RESOURCES_UPDATED, required_capability_name: "resources"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_RESOURCES_UPDATED,
      required_capability_name: "resources.subscribe",
      capabilities: { resources: {} }

    ensure_capability_raises_error_for Methods::TOOLS_LIST, required_capability_name: "tools"
    ensure_capability_raises_error_for Methods::TOOLS_CALL, required_capability_name: "tools"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED, required_capability_name: "tools"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED,
      required_capability_name: "tools.listChanged",
      capabilities: { tools: {} }

    ensure_capability_raises_error_for Methods::LOGGING_SET_LEVEL, required_capability_name: "logging"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_MESSAGE, required_capability_name: "logging"

    ensure_capability_raises_error_for Methods::COMPLETION_COMPLETE, required_capability_name: "completions"

    # Client methods and notifications
    ensure_capability_does_not_raise_for Methods::NOTIFICATIONS_INITIALIZED

    ensure_capability_raises_error_for Methods::ROOTS_LIST, required_capability_name: "roots"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_ROOTS_LIST_CHANGED, required_capability_name: "roots"
    ensure_capability_raises_error_for Methods::NOTIFICATIONS_ROOTS_LIST_CHANGED,
      required_capability_name: "roots.listChanged",
      capabilities: { roots: {} }

    ensure_capability_raises_error_for Methods::SAMPLING_CREATE_MESSAGE, required_capability_name: "sampling"

    ensure_capability_raises_error_for Methods::ELICITATION_CREATE, required_capability_name: "elicitation"

    # Methods and notifications of both server and client
    ensure_capability_does_not_raise_for Methods::PING
    ensure_capability_does_not_raise_for Methods::NOTIFICATIONS_PROGRESS
    ensure_capability_does_not_raise_for Methods::NOTIFICATIONS_CANCELLED
  end
end
