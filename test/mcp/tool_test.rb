# frozen_string_literal: true

require "test_helper"

module MCP
  class ToolTest < ActiveSupport::TestCase
    class TestTool < Tool
      tool_name "test_tool"
      description "a test tool for testing"
      icons [Icon.new(mime_type: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light")]
      input_schema({ properties: { message: { type: "string" } }, required: ["message"] })
      annotations(
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
        read_only_hint: true,
        title: "Test Tool",
      )
      meta(
        foo: "bar",
      )

      class << self
        def call(message:, server_context: nil)
          Tool::Response.new([{ type: "text", content: "OK" }])
        end
      end
    end

    test "#to_h returns a hash including name, description, icons, and inputSchema" do
      expected = {
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        inputSchema: { type: "object" },
      }
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light")],
      )

      assert_equal(expected, tool.to_h)
    end

    test "#to_h does not have `:title` key when title is omitted" do
      tool = Tool.define(
        name: "mock_tool",
        description: "a mock tool for testing",
      )
      refute tool.to_h.key?(:title)
    end

    test "#to_h does not have `:icons` key when icons is empty" do
      tool = Tool.define(
        name: "tool_without_icons",
        description: "a tool without icons",
      )

      refute tool.to_h.key?(:icons)
    end

    test "#to_h does not have `:icons` key when icons is nil" do
      tool = Tool.define(
        name: "tool_without_icons",
        description: "a tool without icons",
        icons: nil,
      )

      refute tool.to_h.key?(:icons)
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

    test "#to_h includes meta when present" do
      tool = TestTool
      expected_meta = {
        foo: "bar",
      }
      assert_equal expected_meta, tool.to_h[:_meta]
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
        input_schema({ properties: { message: { type: "string" } }, required: ["message"] })
      end

      tool = MockTool
      assert_equal "my_mock_tool",  tool.name_value
      assert_equal "a mock tool for testing", tool.description
      assert_equal({ type: "object", properties: { message: { type: "string" } }, required: ["message"] }, tool.input_schema.to_h)
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
        input_schema InputSchema.new(properties: { message: { type: "string" } }, required: ["message"])
      end

      tool = InputSchemaTool

      expected = { type: "object", properties: { message: { type: "string" } }, required: ["message"] }
      assert_equal expected, tool.input_schema.to_h
    end

    test "raises detailed error message for invalid schema" do
      error = assert_raises(ArgumentError) do
        Class.new(MCP::Tool) do
          input_schema(
            properties: {
              count: { type: "integer", minimum: "not a number" },
            },
            required: ["count"],
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

    test ".define allows definition of tools with meta" do
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        meta: { foo: "bar" },
      ) do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal "mock_tool", tool.name_value
      assert_equal "Mock Tool", tool.title
      assert_equal "a mock tool for testing", tool.description
      assert_equal tool.input_schema, Tool::InputSchema.new
      assert_equal({ foo: "bar" }, tool.meta_value)
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

    test "Tool class method meta can be set and retrieved" do
      class MetaTestTool < Tool
        tool_name "meta_test"
        meta(foo: "bar")
      end

      tool = MetaTestTool
      assert_instance_of Hash, tool.meta_value
      assert_equal "bar", tool.meta_value[:foo]
    end

    test "Tool class method meta can be updated" do
      class UpdatableMetaTool < Tool
        tool_name "updatable_meta"
      end

      tool = UpdatableMetaTool
      tool.meta(foo: "baz")
      assert_equal({ foo: "baz" }, tool.meta_value)

      tool.meta(foo: "qux")
      assert_equal({ foo: "qux" }, tool.meta_value)
    end

    test "#call with Sorbet typed tools invokes the tool block and returns the response" do
      skip "sorbet-static-and-runtime requires Ruby 3.0+." if RUBY_VERSION < "3.0"

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
      expected = {
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        icons: [{ mimeType: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light" }],
        inputSchema: { type: "object" },
        outputSchema: { type: "object", properties: { result: { type: "string" } }, required: ["result"] },
      }
      tool = Tool.define(
        name: "mock_tool",
        title: "Mock Tool",
        description: "a mock tool for testing",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48", "96x96"], src: "https://example.com", theme: "light")],
        output_schema: { properties: { result: { type: "string" } }, required: ["result"] },
      )

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
        output_schema({ properties: { result: { type: "string" } }, required: ["result"] })
      end

      tool = HashOutputSchemaTool
      expected = { type: "object", properties: { result: { type: "string" } }, required: ["result"] }
      assert_equal expected, tool.output_schema.to_h
    end

    test "accepts output_schema as an OutputSchema object" do
      class OutputSchemaObjectTool < Tool
        output_schema Tool::OutputSchema.new(properties: { result: { type: "string" } }, required: ["result"])
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
            required: ["count"],
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

      expected_input = { type: "object", properties: { message: { type: "string" } }, required: ["message"] }
      assert_equal expected_input, tool.input_schema.to_h

      expected_output = { type: "object", properties: { result: { type: "string" }, success: { type: "boolean" } }, required: ["result", "success"] }
      assert_equal expected_output, tool.output_schema.to_h
    end

    test "accepts valid tool names" do
      assert Tool.define(name: "getUser")
      assert Tool.define(name: "DATA_EXPORT_v2")
      assert Tool.define(name: "admin.tools.list")
      assert Tool.define(name: "a" * 128)
    end

    test "raises an error when tool name is empty in class definition" do
      error = assert_raises(ArgumentError) do
        class EmptyTitleNameTool < Tool
          tool_name ""
        end
      end
      assert_equal("Tool names should be between 1 and 128 characters in length (inclusive).", error.message)
    end

    test "allows nil tool name in class definition" do
      assert_nothing_raised do
        class EmptyTitleNameTool < Tool
          tool_name nil
        end
      end
    end

    test "raises an error when tool name is empty" do
      error = assert_raises(ArgumentError) { Tool.define(name: "") }
      assert_equal("Tool names should be between 1 and 128 characters in length (inclusive).", error.message)
    end

    test "raises an error when tool name exceeds 128 characters" do
      error = assert_raises(ArgumentError) { Tool.define(name: "a" * 129) }
      assert_equal("Tool names should be between 1 and 128 characters in length (inclusive).", error.message)
    end

    test "raises an error when tool name includes invalid characters (e.g., spaces)" do
      error = assert_raises(ArgumentError) { Tool.define(name: "foo bar") }
      assert_equal(<<~MESSAGE, error.message)
        Tool names only allowed characters: uppercase and lowercase ASCII letters (A-Z, a-z), digits (0-9), underscore (_), hyphen (-), and dot (.).
      MESSAGE
    end
  end
end
