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

      def test_output_schema_returns_nil_when_not_provided
        assert_nil(@tool.output_schema)
      end

      def test_output_schema_returns_output_schema_when_provided
        tool_with_output = Tool.new(
          name: "test_tool_with_output",
          description: "A test tool with output schema",
          input_schema: { "type" => "object", "properties" => { "foo" => { "type" => "string" } } },
          output_schema: { "type" => "object", "properties" => { "result" => { "type" => "string" } } },
        )

        assert_equal(
          { "type" => "object", "properties" => { "result" => { "type" => "string" } } },
          tool_with_output.output_schema,
        )
      end

      def test_initialization_with_all_parameters
        tool = Tool.new(
          name: "full_tool",
          description: "A tool with all parameters",
          input_schema: { "type" => "object" },
          output_schema: { "type" => "object", "properties" => { "status" => { "type" => "boolean" } } },
        )

        assert_equal("full_tool", tool.name)
        assert_equal("A tool with all parameters", tool.description)
        assert_equal({ "type" => "object" }, tool.input_schema)
        assert_equal({ "type" => "object", "properties" => { "status" => { "type" => "boolean" } } }, tool.output_schema)
      end
    end
  end
end
