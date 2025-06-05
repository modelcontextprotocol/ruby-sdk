# frozen_string_literal: true

require "test_helper"
require "mcp/tool/input_schema"

module MCP
  class Tool
    class InputSchemaTest < ActiveSupport::TestCase
      test "required arguments are converted to symbols" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: ["message"])
        assert_equal [:message], input_schema.required
      end

      test "to_h returns a hash representation of the input schema" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
        assert_equal(
          { type: "object", properties: { message: { type: "string" } }, required: [:message] },
          input_schema.to_h,
        )
      end

      test "missing_required_arguments returns an array of missing required arguments" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
        assert_equal [:message], input_schema.missing_required_arguments({})
      end

      test "missing_required_arguments returns an empty array if no required arguments are missing" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
        assert_empty input_schema.missing_required_arguments({ message: "Hello, world!" })
      end

      test "valid schema initialization" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        assert_equal({ type: "object", properties: { foo: { type: "string" } }, required: [:foo] }, schema.to_h)
      end

      test "invalid schema raises argument error" do
        assert_raises(ArgumentError) do
          InputSchema.new(properties: { foo: { type: "invalid_type" } }, required: [:foo])
        end
      end

      test "validate arguments with valid data" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        assert_nil(schema.validate_arguments({ foo: "bar" }))
      end

      test "validate arguments with invalid data" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        assert_raises(InputSchema::ValidationError) do
          schema.validate_arguments({ foo: 123 })
        end
      end
    end
  end
end
