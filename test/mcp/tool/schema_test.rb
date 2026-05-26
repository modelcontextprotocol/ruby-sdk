# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class InputSchemaTest < ActiveSupport::TestCase
      test "initializes with a schema and validates it by default" do
        valid_schema = {
          type: "object",
          properties: {
            message: { type: "string" },
          },
          required: ["message"],
        }
        assert_nothing_raised do
          InputSchema.new(valid_schema)
        end
      end

      test "initializes with a schema and skips validation when validate is false" do
        assert_nothing_raised do
          InputSchema.new("invalid", false)
        end
      end
    end
  end
end
