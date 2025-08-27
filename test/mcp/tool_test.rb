# typed: true
# frozen_string_literal: true

require "test_helper"

module MCP
  class ToolTest < ActiveSupport::TestCase
    class TestTool < Tool
      tool_name "test_tool"
      description "a test tool for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })
      annotations(
        title: "Test Tool",
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
      )

      class << self
        def call(message:, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    test "#to_h returns a hash with name, description, and inputSchema" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
      )
      assert_equal({ name: "mock_tool", title: "Mock Tool", description: "a mock tool for testing", inputSchema: { type: "object" } }, tool.to_h)
    end

    test "#to_h includes annotations when present" do
      tool = TestTool
      expected_annotations = {
        title: "Test Tool",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      }
      assert_equal expected_annotations, tool.to_h[:annotations]
    end

    test "#call invokes the tool block and returns the response" do
      tool = TestTool
      response = tool.call(message: "test")
      assert_equal [{ type: "text", content: "OK" }], response.content
      refute response.error?
    end

    test "allows declarative definition of tools as classes" do
      class MockTool < Tool
        tool_name "my_mock_tool"
        description "a mock tool for testing"
        input_schema({ properties: { message: { type: "string" } }, required: [:message] })
      end

      tool = MockTool
      assert_equal "my_mock_tool",  tool.name_value
      assert_equal "a mock tool for testing", tool.description
      assert_equal({ type: "object", properties: { message: { type: "string" } }, required: [:message] }, tool.input_schema.to_h)
    end

    test "defaults to class name as tool name" do
      class DefaultNameTool < Tool
      end

      tool = DefaultNameTool

      assert_equal "default_name_tool", tool.tool_name
    end

    test "input schema defaults to an empty hash" do
      class NoInputSchemaTool < Tool; end

      tool = NoInputSchemaTool

      expected = { type: "object" }
      assert_equal expected, tool.input_schema.to_h
    end

    test "accepts input schema as an InputSchema object" do
      class InputSchemaTool < Tool
        input_schema InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
      end

      tool = InputSchemaTool

      expected = { type: "object", properties: { message: { type: "string" } }, required: [:message] }
      assert_equal expected, tool.input_schema.to_h
    end

    test "raises detailed error message for invalid schema" do
      error = assert_raises(ArgumentError) do
        Class.new(MCP::Tool) do
          input_schema(
            properties: {
              count: { type: "integer", minimum: "not a number" },
            },
            required: [:count],
          )
        end
      end

      assert_includes error.message, "Invalid JSON Schema"
      assert_includes error.message, "#/properties/count/minimum"
      assert_includes error.message, "string did not match the following type: number"
    end

    test ".define allows definition of simple tools with a block" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
      ) do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "a mock tool for testing", tool.description
      assert_equal Tool::InputSchema.new, tool.input_schema
    end

    test ".define allows definition of tools with annotations" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        annotations: {
          read_only_hint: true,
          title: "Mock Tool",
        },
      ) do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "Mock Tool", tool.title
      assert_equal "a mock tool for testing", tool.description
      assert_equal tool.input_schema, Tool::InputSchema.new
      assert_equal({ readOnlyHint: true, title: "Mock Tool" }, tool.annotations_value.to_h)
    end

    test "Tool class method annotations can be set and retrieved" do
      class AnnotationsTestTool < Tool
        tool_name "annotations_test"
        annotations(
          title: "Annotations Test",
          read_only_hint: true,
        )
      end

      tool = AnnotationsTestTool
      assert_instance_of Tool::Annotations, tool.annotations_value
      assert_equal "Annotations Test", tool.annotations_value.title
      assert tool.annotations_value.read_only_hint
    end

    test "Tool class method annotations can be updated" do
      class UpdatableAnnotationsTool < Tool
        tool_name "updatable_annotations"
      end

      tool = UpdatableAnnotationsTool
      tool.annotations(title: "Initial")
      assert_equal "Initial", tool.annotations_value.title

      tool.annotations(title: "Updated")
      assert_equal "Updated", tool.annotations_value.title
    end

    test "#call with Sorbet typed tools invokes the tool block and returns the response" do
      class TypedTestTool < Tool
        tool_name "test_tool"
        description "a test tool for testing"
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

        class << self
          extend T::Sig

          sig { params(message: String, server_context: T.nilable(T.untyped)).returns(Tool::Response) }
          def call(message:, server_context: nil)
            Tool::Response.new([{ type: "text", content: "OK" }])
          end
        end
      end

      tool = TypedTestTool
      response = tool.call(message: "test")
      assert_equal [{ type: "text", content: "OK" }], response.content
      refute response.error?
    end

    class TestToolWithoutServerContext < Tool
      tool_name "test_tool_without_server_context"
      description "a test tool for testing without server context"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })

      class << self
        def call(message:)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    class TestToolWithoutRequired < Tool
      tool_name "test_tool_without_required"
      description "a test tool for testing without required server context"

      class << self
        def call(message, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    test "tool call without server context" do
      tool = TestToolWithoutServerContext
      response = tool.call(message: "test")
      assert_equal [{ type: "text", content: "OK" }], response.content
    end

    test "tool call with server context and without required" do
      tool = TestToolWithoutRequired
      response = tool.call("test", server_context: { foo: "bar" })
      assert_equal [{ type: "text", content: "OK" }], response.content
    end

    test "input_schema rejects any $ref in schema" do
      schema_with_ref = {
        properties: {
          foo: { "$ref" => "#/definitions/bar" },
        },
        required: ["foo"],
        definitions: {
          bar: { type: "string" },
        },
      }
      error = assert_raises(ArgumentError) do
        Class.new(MCP::Tool) do
          input_schema schema_with_ref
        end
      end
      assert_match(/Invalid JSON Schema/, error.message)
    end
  end
end
