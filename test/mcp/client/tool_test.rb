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

      def test_annotations_returns_nil_when_not_provided
        assert_nil(@tool.annotations)
      end

      def test_title_icons_execution_and_meta_return_nil_when_not_provided
        assert_nil(@tool.title)
        assert_nil(@tool.icons)
        assert_nil(@tool.execution)
        assert_nil(@tool.meta)
      end

      def test_annotations_returns_annotations_when_provided
        tool_with_annotations = Tool.new(
          name: "test_tool_with_annotations",
          description: "A test tool with annotations",
          input_schema: { "type" => "object" },
          annotations: { "readOnlyHint" => true, "title" => "Test Tool" },
        )

        assert_equal(
          { "readOnlyHint" => true, "title" => "Test Tool" },
          tool_with_annotations.annotations,
        )
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
          title: "Full Tool",
          description: "A tool with all parameters",
          input_schema: { "type" => "object" },
          output_schema: { "type" => "object", "properties" => { "status" => { "type" => "boolean" } } },
          annotations: { "readOnlyHint" => true },
          icons: [{ "src" => "https://example.com/tool.png", "mimeType" => "image/png" }],
          execution: { "taskSupport" => "optional" },
          meta: { "ui" => { "resourceUri" => "ui://shop/plans" } },
        )

        assert_equal("full_tool", tool.name)
        assert_equal("Full Tool", tool.title)
        assert_equal("A tool with all parameters", tool.description)
        assert_equal({ "type" => "object" }, tool.input_schema)
        assert_equal({ "type" => "object", "properties" => { "status" => { "type" => "boolean" } } }, tool.output_schema)
        assert_equal({ "readOnlyHint" => true }, tool.annotations)
        assert_equal([{ "src" => "https://example.com/tool.png", "mimeType" => "image/png" }], tool.icons)
        assert_equal({ "taskSupport" => "optional" }, tool.execution)
        assert_equal({ "ui" => { "resourceUri" => "ui://shop/plans" } }, tool.meta)
      end
    end
  end
end
