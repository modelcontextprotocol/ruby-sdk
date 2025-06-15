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
      tool = Tool.define(name: "mock_tool", description: "a mock tool for testing")
      assert_equal tool.to_h, { name: "mock_tool", description: "a mock tool for testing", inputSchema: {} }
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
      assert_equal tool.to_h[:annotations], expected_annotations
    end

    test "#call invokes the tool block and returns the response" do
      tool = TestTool
      response = tool.call(message: "test")
      assert_equal response.content, [{ type: "text", content: "OK" }]
      assert_equal response.is_error, false
    end

    test "allows declarative definition of tools as classes" do
      class MockTool < Tool
        tool_name "my_mock_tool"
        description "a mock tool for testing"
        input_schema({ properties: { message: { type: "string" } }, required: [:message] })
      end

      tool = MockTool
      assert_equal tool.name_value, "my_mock_tool"
      assert_equal tool.description, "a mock tool for testing"
      assert_equal tool.input_schema.to_h,
        { type: "object", properties: { message: { type: "string" } }, required: [:message] }
    end

    test "defaults to class name as tool name" do
      class DefaultNameTool < Tool
      end

      tool = DefaultNameTool

      assert_equal tool.tool_name, "default_name_tool"
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
      tool = Tool.define(name: "mock_tool", description: "a mock tool for testing") do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal tool.name_value, "mock_tool"
      assert_equal tool.description, "a mock tool for testing"
      assert_equal tool.input_schema, nil
    end

    test ".define allows definition of tools with annotations" do
      tool = Tool.define(
        name: "mock_tool",
        description: "a mock tool for testing",
        annotations: {
          title: "Mock Tool",
          read_only_hint: true,
        },
      ) do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal tool.name_value, "mock_tool"
      assert_equal tool.description, "a mock tool for testing"
      assert_equal tool.input_schema, nil
      assert_equal tool.annotations_value.to_h, { title: "Mock Tool", readOnlyHint: true }
    end

    # Tests for Tool::Annotations class
    test "Tool::Annotations initializes with all properties" do
      annotations = Tool::Annotations.new(
        title: "Test Tool",
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
      )

      assert_equal annotations.title, "Test Tool"
      assert_equal annotations.read_only_hint, true
      assert_equal annotations.destructive_hint, false
      assert_equal annotations.idempotent_hint, true
      assert_equal annotations.open_world_hint, false
    end

    test "Tool::Annotations initializes with partial properties" do
      annotations = Tool::Annotations.new(
        title: "Test Tool",
        read_only_hint: true,
      )

      assert_equal annotations.title, "Test Tool"
      assert_equal annotations.read_only_hint, true
      assert_nil annotations.destructive_hint
      assert_nil annotations.idempotent_hint
      assert_nil annotations.open_world_hint
    end

    test "Tool::Annotations#to_h omits nil values" do
      annotations = Tool::Annotations.new(
        title: "Test Tool",
        read_only_hint: true,
      )

      expected = {
        title: "Test Tool",
        readOnlyHint: true,
      }
      assert_equal annotations.to_h, expected
    end

    test "Tool::Annotations#to_h handles all properties" do
      annotations = Tool::Annotations.new(
        title: "Test Tool",
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
      )

      expected = {
        title: "Test Tool",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      }
      assert_equal annotations.to_h, expected
    end

    test "Tool::Annotations#to_h returns empty hash when all values are nil" do
      annotations = Tool::Annotations.new
      assert_empty annotations.to_h
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
      assert_equal tool.annotations_value.title, "Annotations Test"
      assert_equal tool.annotations_value.read_only_hint, true
    end

    test "Tool class method annotations can be updated" do
      class UpdatableAnnotationsTool < Tool
        tool_name "updatable_annotations"
      end

      tool = UpdatableAnnotationsTool
      tool.annotations(title: "Initial")
      assert_equal tool.annotations_value.title, "Initial"

      tool.annotations(title: "Updated")
      assert_equal tool.annotations_value.title, "Updated"
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
      assert_equal response.content, [{ type: "text", content: "OK" }]
      assert_equal response.is_error, false
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
