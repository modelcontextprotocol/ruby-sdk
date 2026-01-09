# frozen_string_literal: true

require "test_helper"
require "timeout"

module MCP
  class StringUtilsTest < Minitest::Test
    def test_handle_from_class_name_returns_the_class_name_without_the_module_for_a_class_without_a_module
      assert_equal("test", StringUtils.handle_from_class_name("Test"))
      assert_equal("test_class", StringUtils.handle_from_class_name("TestClass"))
    end

    def test_handle_from_class_name_returns_the_class_name_without_the_module_for_a_class_with_a_single_parent_module
      assert_equal("test", StringUtils.handle_from_class_name("Module::Test"))
      assert_equal("test_class", StringUtils.handle_from_class_name("Module::TestClass"))
    end

    def test_handle_from_class_name_returns_the_class_name_without_the_module_for_a_class_with_multiple_parent_modules
      assert_equal("test", StringUtils.handle_from_class_name("Module::Submodule::Test"))
      assert_equal("test_class", StringUtils.handle_from_class_name("Module::Submodule::TestClass"))
    end

    def test_handle_from_class_name_does_not_cause_redos
      # A long string of uppercase letters followed by a non-lowercase character
      # would trigger catastrophic backtracking with the vulnerable regex patterns.
      malicious_input = "A" * 50_000 + "!"

      result = nil
      Timeout.timeout(1) do
        result = StringUtils.handle_from_class_name(malicious_input)
      end

      assert_equal("a" * 50_000 + "!", result)
    end
  end
end
