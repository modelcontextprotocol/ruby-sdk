# typed: true
# frozen_string_literal: true

require "test_helper"

module MCP
  class ToolTest < ActiveSupport::TestCase
    TestTool = Tool.define(
      name: "test_tool",
      description: "a test tool for testing",
      input_schema: { properties: { message: { type: "string" } }, required: ["message"] },
      annotations: {
        title: "Test Tool",
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false,
      },
    ) do
      Tool::Response.new([{ type: "text", content: "OK" }])
    end

    test "#to_h returns a hash with name, description, and inputSchema" do
      tool = Tool.define(name: "mock_tool", description: "a mock tool for testing") {}
      assert_equal tool.to_h, { name: "mock_tool", description: "a mock tool for testing" }
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
      response = tool.call({ message: "test" }, server_context: {})
      assert_equal response.content, [{ type: "text", content: "OK" }]
      assert_equal response.is_error, false
    end

    test "allows definition of tools with input schema" do
      tool = Tool.define(
        name: "my_mock_tool",
        description: "a mock tool for testing",
        input_schema: { properties: { message: { type: "string" } }, required: [:message] },
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal tool.name, "my_mock_tool"
      assert_equal tool.description, "a mock tool for testing"
      assert_equal tool.input_schema.to_h,
        { type: "object", properties: { message: { type: "string" } }, required: [:message] }
    end

    test "accepts input schema as an InputSchema object" do
      input_schema = Tool::InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
      tool = Tool.define(
        name: "input_schema_tool",
        description: "a test tool",
        input_schema: input_schema,
      ) do
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      expected = { type: "object", properties: { message: { type: "string" } }, required: [:message] }
      assert_equal expected, tool.input_schema.to_h
    end

    test ".define allows definition of simple tools with a block" do
      tool = Tool.define(name: "mock_tool", description: "a mock tool for testing") do |_|
        Tool::Response.new([{ type: "text", content: "OK" }])
      end

      assert_equal tool.name, "mock_tool"
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

      assert_equal tool.name, "mock_tool"
      assert_equal tool.description, "a mock tool for testing"
      assert_equal tool.input_schema, nil
      assert_equal tool.annotations.to_h, { title: "Mock Tool", readOnlyHint: true }
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
  end
end
