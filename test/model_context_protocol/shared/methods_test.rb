# typed: strict
# frozen_string_literal: true

require "test_helper"

module ModelContextProtocol
  class MethodsTest < ActiveSupport::TestCase
    test "ensure_capability! for tools/list method raises an error if tools capability is not present" do
      error = assert_raises(Methods::MissingRequiredCapabilityError) do
        Methods.ensure_capability!(Methods::TOOLS_LIST, {})
      end
      assert_equal "Server does not support tools (required for tools/list)", error.message
    end

    test "ensure_capability! for sampling/createMessage raises an error if sampling capability is not present" do
      error = assert_raises(Methods::MissingRequiredCapabilityError) do
        Methods.ensure_capability!(Methods::SAMPLING_CREATE_MESSAGE, {})
      end
      assert_equal "Server does not support sampling (required for sampling/createMessage)", error.message
    end

    test "ensure_capability! for completion/complete raises an error if completions capability is not present" do
      error = assert_raises(Methods::MissingRequiredCapabilityError) do
        Methods.ensure_capability!(Methods::COMPLETION_COMPLETE, {})
      end
      assert_equal "Server does not support completions (required for completion/complete)", error.message
    end

    test "ensure_capability! for logging/setLevel raises an error if logging capability is not present" do
      error = assert_raises(Methods::MissingRequiredCapabilityError) do
        Methods.ensure_capability!(Methods::LOGGING_SET_LEVEL, {})
      end
      assert_equal "Server does not support logging (required for logging/setLevel)", error.message
    end

    test "ensure_capability! for prompts/get and prompts/list raise an error if prompts capability is not present" do
      [Methods::PROMPTS_GET, Methods::PROMPTS_LIST].each do |method|
        error = assert_raises(Methods::MissingRequiredCapabilityError) do
          Methods.ensure_capability!(method, {})
        end
        assert_equal "Server does not support prompts (required for #{method})", error.message
      end
    end

    test "ensure_capability! for resources/list, resources/templates/list, resources/read raise an error if resources capability is not present" do
      [Methods::RESOURCES_LIST, Methods::RESOURCES_TEMPLATES_LIST, Methods::RESOURCES_READ].each do |method|
        error = assert_raises(Methods::MissingRequiredCapabilityError) do
          Methods.ensure_capability!(method, {})
        end
        assert_equal "Server does not support resources (required for #{method})", error.message
      end
    end

    test "ensure_capability! for tools/call and tools/list raise an error if tools capability is not present" do
      [Methods::TOOLS_CALL, Methods::TOOLS_LIST].each do |method|
        error = assert_raises(Methods::MissingRequiredCapabilityError) do
          Methods.ensure_capability!(method, {})
        end
        assert_equal "Server does not support tools (required for #{method})", error.message
      end
    end

    test "ensure_capability! for resources/subscribe raises an error if resources subscribe capability is not present" do
      error = assert_raises(Methods::MissingRequiredCapabilityError) do
        Methods.ensure_capability!(Methods::RESOURCES_SUBSCRIBE, { resources: {} })
      end
      assert_equal "Server does not support resources_subscribe (required for resources/subscribe)", error.message
    end

    test "ensure_capability! does not raise for ping and initialize methods" do
      assert_nothing_raised { Methods.ensure_capability!(Methods::PING, {}) }
      assert_nothing_raised { Methods.ensure_capability!(Methods::INITIALIZE, {}) }
    end
  end
end
