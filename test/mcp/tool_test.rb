# frozen_string_literal: true

require "test_helper"

module MCP
  class ToolTest < ActiveSupport::TestCase
    class TestTool < Tool
      tool_name "test_tool"
      description "a test tool for testing"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })
      annotations(
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
        read_only_hint: true,
        title: "Test Tool",
      )
      metadata(
        foo: "bar",
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

    test "#to_h does not have `:title` key when title is omitted" do
      tool = Tool.define(
        name: "mock_tool",
        description: "a mock tool for testing",
      )
      refute tool.to_h.key?(:title)
    end

    test "#to_h includes annotations when present" do
      tool = TestTool
      expected_annotations = {
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
        readOnlyHint: true,
        title: "Test Tool",
      }
      assert_equal expected_annotations, tool.to_h[:annotations]
    end

    test "#to_h includes metadata when present" do
      tool = TestTool
      expected_metadata = {
        foo: "bar",
      }
      assert_equal expected_metadata, tool.to_h[:_meta]
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
      ) do
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
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "Mock Tool", tool.title
      assert_equal "a mock tool for testing", tool.description
      assert_equal tool.input_schema, Tool::InputSchema.new
      assert_equal({ destructiveHint: true, idempotentHint: false, openWorldHint: true, readOnlyHint: true, title: "Mock Tool" }, tool.annotations_value.to_h)
    end

    test ".define allows definition of tools with metadata" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        metadata: { foo: "bar" },
      ) do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "Mock Tool", tool.title
      assert_equal "a mock tool for testing", tool.description
      assert_equal tool.input_schema, Tool::InputSchema.new
      assert_equal({ foo: "bar" }, tool.metadata_value)
    end

    test "Tool class method annotations can be set and retrieved" do
      class AnnotationsTestTool < Tool
        tool_name "annotations_test"
        annotations(
          read_only_hint: true,
          title: "Annotations Test",
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

    test "Tool class method metadata can be set and retrieved" do
      class MetadataTestTool < Tool
        tool_name "annotations_test"
        metadata(foo: "bar")
      end

      tool = MetadataTestTool
      assert_instance_of Hash, tool.metadata_value
      assert_equal "bar", tool.metadata_value[:foo]
    end

    test "Tool class method metadata can be updated" do
      class UpdatableMetadataTool < Tool
        tool_name "updatable_metadata"
      end

      tool = UpdatableMetadataTool
      tool.metadata(foo: "baz")
      assert_equal({ foo: "baz" }, tool.metadata_value)

      tool.metadata(foo: "qux")
      assert_equal({ foo: "qux" }, tool.metadata_value)
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

    test "#to_h includes outputSchema when present" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        output_schema: { properties: { result: { type: "string" } }, required: ["result"] },
      )
      expected = {
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        inputSchema: { type: "object" },
        outputSchema: { type: "object", properties: { result: { type: "string" } }, required: ["result"] },
      }
      assert_equal expected, tool.to_h
    end

    test "#to_h does not include outputSchema when not set" do
      tool = Tool.define(
        name: "mock_tool",
        description: "a mock tool for testing",
      )
      refute tool.to_h.key?(:outputSchema)
    end

    test "output_schema defaults to nil" do
      class NoOutputSchemaTool < Tool; end
      tool = NoOutputSchemaTool
      assert_nil tool.output_schema
    end

    test "accepts output_schema as a hash" do
      class HashOutputSchemaTool < Tool
        output_schema({ properties: { result: { type: "string" } }, required: [:result] })
      end

      tool = HashOutputSchemaTool
      expected = { type: "object", properties: { result: { type: "string" } }, required: ["result"] }
      assert_equal expected, tool.output_schema.to_h
    end

    test "accepts output_schema as an OutputSchema object" do
      class OutputSchemaObjectTool < Tool
        output_schema Tool::OutputSchema.new(properties: { result: { type: "string" } }, required: [:result])
      end

      tool = OutputSchemaObjectTool
      expected = { type: "object", properties: { result: { type: "string" } }, required: ["result"] }
      assert_equal expected, tool.output_schema.to_h
    end

    test "output_schema raises detailed error message for invalid schema" do
      error = assert_raises(ArgumentError) do
        Class.new(MCP::Tool) do
          output_schema(
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

    test "output_schema rejects any $ref in schema" do
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
          output_schema schema_with_ref
        end
      end
      assert_match(/Invalid JSON Schema/, error.message)
    end

    test ".define allows definition of tools with output_schema" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        output_schema: { properties: { result: { type: "string" } }, required: ["result"] },
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "a mock tool for testing", tool.description
      assert_instance_of Tool::OutputSchema, tool.output_schema
      expected_output_schema = { type: "object", properties: { result: { type: "string" } }, required: ["result"] }
      assert_equal expected_output_schema, tool.output_schema.to_h
    end

    class TestToolWithOutputSchema < Tool
      tool_name "test_tool_with_output"
      description "a test tool with output schema"
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })
      output_schema({ properties: { result: { type: "string" }, success: { type: "boolean" } }, required: ["result", "success"] })

      class << self
        def call(message:, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    test "declarative definition of tools with output schema" do
      tool = TestToolWithOutputSchema
      assert_equal "test_tool_with_output", tool.name_value
      assert_equal "a test tool with output schema", tool.description

      expected_input = { type: "object", properties: { message: { type: "string" } }, required: [:message] }
      assert_equal expected_input, tool.input_schema.to_h

      expected_output = { type: "object", properties: { result: { type: "string" }, success: { type: "boolean" } }, required: ["result", "success"] }
      assert_equal expected_output, tool.output_schema.to_h
    end
  end
end
