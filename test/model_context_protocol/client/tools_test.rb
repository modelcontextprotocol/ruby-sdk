# frozen_string_literal: true

require "test_helper"

module ModelContextProtocol
  module Client
    class ToolsTest < Minitest::Test
      def test_each_iterates_over_tools
        response = {
          "result" => {
            "tools" => [
              { "name" => "tool1", "description" => "First tool" },
              { "name" => "tool2", "description" => "Second tool" },
            ],
          },
        }
        tools = Tools.new(response)

        tool_names = []
        tools.each { |tool| tool_names << tool.name }

        assert_equal(["tool1", "tool2"], tool_names)
      end

      def test_all_returns_array_of_tools
        response = {
          "result" => {
            "tools" => [
              { "name" => "tool1", "description" => "First tool" },
              { "name" => "tool2", "description" => "Second tool" },
            ],
          },
        }
        tools = Tools.new(response)

        all_tools = tools.all
        assert_equal(2, all_tools.length)
        assert(all_tools.all? { |tool| tool.is_a?(Tool) })
        assert_equal(["tool1", "tool2"], all_tools.map(&:name))
      end

      def test_handles_empty_tools_array
        response = { "result" => { "tools" => [] } }
        tools = Tools.new(response)

        assert_equal([], tools.all)
        assert_equal(0, tools.count)
      end

      def test_handles_missing_tools_key
        response = { "result" => {} }
        tools = Tools.new(response)

        assert_equal([], tools.all)
        assert_equal(0, tools.count)
      end

      def test_handles_missing_result_key
        response = {}
        tools = Tools.new(response)

        assert_equal([], tools.all)
        assert_equal(0, tools.count)
      end

      def test_tools_are_initialized_with_correct_payload
        response = {
          "result" => {
            "tools" => [
              {
                "name" => "test_tool",
                "description" => "A test tool",
                "inputSchema" => { "type" => "object" },
              },
            ],
          },
        }
        tools = Tools.new(response)
        tool = tools.all.first

        assert_equal("test_tool", tool.name)
        assert_equal("A test tool", tool.description)
        assert_equal({ "type" => "object" }, tool.input_schema)
      end

      def test_includes_enumerable
        response = { "result" => { "tools" => [] } }
        tools = Tools.new(response)

        assert(tools.respond_to?(:map))
        assert(tools.respond_to?(:select))
        assert(tools.respond_to?(:find))
      end
    end
  end
end
