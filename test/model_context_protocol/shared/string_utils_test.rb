# frozen_string_literal: true

require "test_helper"

module ModelContextProtocol
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
  end
end
