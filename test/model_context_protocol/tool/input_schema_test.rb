# frozen_string_literal: true

require "test_helper"

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
        assert_equal [], input_schema.missing_required_arguments({ message: "Hello, world!" })
      end
    end
  end
end
