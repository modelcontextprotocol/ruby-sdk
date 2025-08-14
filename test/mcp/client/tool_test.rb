# frozen_string_literal: true

require "test_helper"
require "mcp/client/tool"

module MCP
  class Client
    class ToolTest < Minitest::Test
      def setup
        @tool = Tool.new(
          name: "test_tool",
          description: "A test tool",
          input_schema: { "type" => "object", "properties" => { "foo" => { "type" => "string" } } },
        )
      end

      def test_name_returns_name
        assert_equal("test_tool", @tool.name)
      end

      def test_description_returns_description
        assert_equal("A test tool", @tool.description)
      end

      def test_input_schema_returns_input_schema
        assert_equal(
          { "type" => "object", "properties" => { "foo" => { "type" => "string" } } },
          @tool.input_schema,
        )
      end
    end
  end
end
