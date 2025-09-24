# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class OutputSchemaTest < ActiveSupport::TestCase
      test "to_h returns a hash representation of the output schema" do
        output_schema = OutputSchema.new(properties: { result: { type: "string" } }, required: [:result])
        assert_equal(
          { type: "object", properties: { result: { type: "string" } }, required: ["result"] },
          output_schema.to_h,
        )
      end

      test "validate_result validates result against the schema" do
        output_schema = OutputSchema.new(properties: { result: { type: "string" } }, required: [:result])
        assert_nothing_raised do
          output_schema.validate_result({ result: "success" })
        end
      end

      test "validate_result raises error for invalid result" do
        output_schema = OutputSchema.new(properties: { result: { type: "string" } }, required: [:result])
        assert_raises(OutputSchema::ValidationError) do
          output_schema.validate_result({ result: 123 })
        end
      end

      test "validate_result raises error for missing required field" do
        output_schema = OutputSchema.new(properties: { result: { type: "string" } }, required: [:result])
        assert_raises(OutputSchema::ValidationError) do
          output_schema.validate_result({})
        end
      end

      test "valid schema initialization" do
        schema = OutputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        assert_equal({ type: "object", properties: { foo: { type: "string" } }, required: ["foo"] }, schema.to_h)
      end

      test "invalid schema raises argument error" do
        assert_raises(ArgumentError) do
          OutputSchema.new(properties: { foo: { type: "invalid_type" } }, required: [:foo])
        end
      end

      test "schema without required arguments is valid" do
        assert_nothing_raised do
          OutputSchema.new(properties: { foo: { type: "string" } })
        end
      end

      test "unexpected errors bubble up from validate_result" do
        schema = OutputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])

        JSON::Validator.stub(:fully_validate, ->(*) { raise "unexpected error" }) do
          assert_raises(RuntimeError) do
            schema.validate_result({ foo: "bar" })
          end
        end
      end

      test "rejects schemas with $ref references" do
        assert_raises(ArgumentError) do
          OutputSchema.new(properties: { foo: { "$ref" => "#/definitions/bar" } }, required: [:foo])
        end
      end

      test "rejects schemas with symbol $ref references" do
        assert_raises(ArgumentError) do
          OutputSchema.new(properties: { foo: { :$ref => "#/definitions/bar" } }, required: [:foo])
        end
      end

      test "== compares two output schemas with the same properties and required fields" do
        schema1 = OutputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        schema2 = OutputSchema.new(properties: { foo: { type: "string" } }, required: [:foo])
        assert_equal schema1, schema2

        schema3 = OutputSchema.new(properties: { bar: { type: "string" } }, required: [:bar])
        refute_equal schema1, schema3

        schema4 = OutputSchema.new(properties: { foo: { type: "string" } }, required: [:bar])
        refute_equal schema1, schema4

        schema5 = OutputSchema.new(properties: { bar: { type: "string" } }, required: [:foo])
        refute_equal schema1, schema5
      end

      test "empty schema is valid" do
        schema = OutputSchema.new
        assert_equal({ type: "object" }, schema.to_h)
      end

      test "validates complex nested schemas" do
        schema = OutputSchema.new(
          properties: {
            data: {
              type: "object",
              properties: {
                items: { type: "array", items: { type: "string" } },
                count: { type: "integer", minimum: 0 },
              },
              required: ["items"],
            },
          },
          required: [:data],
        )

        valid_result = {
          data: {
            items: ["item1", "item2"],
            count: 2,
          },
        }

        assert_nothing_raised do
          schema.validate_result(valid_result)
        end

        invalid_result = {
          data: {
            items: [123, 456], # Should be strings
            count: 2,
          },
        }

        assert_raises(OutputSchema::ValidationError) do
          schema.validate_result(invalid_result)
        end
      end

      test "allow to declare array schemas" do
        schema = OutputSchema.new({
          type: "array",
          items: {
            properties: { foo: { type: "string" } },
            required: [:foo],
          },
        })
        assert_equal(
          {
            type: "array",
            items: {
              properties: { foo: { type: "string" } },
              required: ["foo"],
            },
          },
          schema.to_h,
        )
      end
    end
  end
end
