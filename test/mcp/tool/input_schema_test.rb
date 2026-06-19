# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class InputSchemaTest < ActiveSupport::TestCase
      test "required arguments are converted to strings" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: [:message])
        assert_equal ["message"], input_schema.to_h[:required]
      end

      test "to_h returns a hash representation of the input schema" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: ["message"])
        assert_equal(
          {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            type: "object",
            properties: { message: { type: "string" } },
            required: ["message"],
          },
          input_schema.to_h,
        )
      end

      test "to_h returns a hash representation of the input schema with additionalProperties set to false" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: ["message"], additionalProperties: false)
        assert_equal(
          {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            type: "object",
            properties: { message: { type: "string" } },
            required: ["message"],
            additionalProperties: false,
          },
          input_schema.to_h,
        )
      end

      test "to_h preserves user-supplied $schema dialect" do
        input_schema = InputSchema.new(
          "$schema": "https://json-schema.org/draft/2019-09/schema",
          properties: { message: { type: "string" } },
        )
        assert_equal "https://json-schema.org/draft/2019-09/schema", input_schema.to_h[:"$schema"]
      end

      test "validate_arguments works when user supplies a 2020-12 $schema" do
        input_schema = InputSchema.new(
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          properties: { foo: { type: "string" } },
          required: ["foo"],
        )
        assert_nil(input_schema.validate_arguments(foo: "bar"))
        assert_raises(InputSchema::ValidationError) do
          input_schema.validate_arguments({ foo: 123 })
        end
      end

      test "to_h preserves user-supplied $schema given via string key" do
        # The initializer normalizes input through `JSON.parse(...,
        # symbolize_names: true)`, so a string-keyed `"$schema"` should
        # arrive at `schema_for_validation` the same as a symbol-keyed one.
        input_schema = InputSchema.new(
          {
            "$schema" => "https://json-schema.org/draft/2020-12/schema",
            "properties" => { "foo" => { "type" => "string" } },
            "required" => ["foo"],
          },
        )
        assert_equal "https://json-schema.org/draft/2020-12/schema", input_schema.to_h[:"$schema"]
        assert_nil(input_schema.validate_arguments(foo: "bar"))
      end

      test "missing_required_arguments returns an array of missing required arguments" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: ["message"])
        assert_equal ["message"], input_schema.missing_required_arguments({})
      end

      test "missing_required_arguments returns an empty array if no required arguments are missing" do
        input_schema = InputSchema.new(properties: { message: { type: "string" } }, required: ["message"])
        assert_equal([], input_schema.missing_required_arguments({ message: "Hello, world!" }))
      end

      test "valid schema initialization" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_equal(
          {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            type: "object",
            properties: { foo: { type: "string" } },
            required: ["foo"],
          },
          schema.to_h,
        )
      end

      test "invalid schema raises argument error" do
        assert_raises(ArgumentError) do
          InputSchema.new(properties: { foo: { type: "invalid_type" } }, required: ["foo"])
        end
      end

      test "rejects a draft-04-only boolean exclusiveMinimum under the 2020-12 dialect" do
        # SEP-2106 validates tool schemas against the JSON Schema 2020-12 metaschema,
        # where `exclusiveMinimum` must be a number. The draft-04 boolean form (deprecated since draft-06)
        # is rejected at construction, matching the Python SDK's `jsonschema` validator selection.
        error = assert_raises(ArgumentError) do
          InputSchema.new(properties: { age: { type: "integer", minimum: 0, exclusiveMinimum: true } })
        end
        assert_includes error.message, "Invalid JSON Schema"
      end

      test "accepts the 2020-12 numeric exclusiveMinimum form" do
        assert_nothing_raised do
          InputSchema.new(properties: { age: { type: "integer", exclusiveMinimum: 0 } })
        end
      end

      test "schema without required arguments is valid" do
        assert_nothing_raised do
          InputSchema.new(properties: { foo: { type: "string" } })
        end
      end

      test "validate arguments with valid data" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_nil(schema.validate_arguments({ foo: "bar" }))
      end

      test "validate arguments with invalid data" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_raises(InputSchema::ValidationError) do
          schema.validate_arguments({ foo: 123 })
        end
      end

      test "validate arguments with valid data when additionalProperties set to nil (default)" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_nil(schema.validate_arguments({ foo: "bar", extra: 123 }))
      end

      test "validate arguments with valid data when additionalProperties set to true (default)" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"], additionalProperties: true)
        assert_nil(schema.validate_arguments({ foo: "bar", extra: 123 }))
      end

      test "validate arguments with invalid data when additionalProperties set to false" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"], additionalProperties: false)
        assert_raises(InputSchema::ValidationError) do
          schema.validate_arguments({ foo: "bar", extra: 123 })
        end
      end

      test "unexpected errors bubble up from validate_arguments" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])

        JSONSchemer::Schema.any_instance.stubs(:validate).raises("unexpected error")

        assert_raises(RuntimeError) do
          schema.validate_arguments(foo: "bar")
        end
      end

      test "accepts schemas with $ref references" do
        schema = InputSchema.new(
          properties: {
            foo: { type: "string" },
          },
          definitions: {
            bar: { type: "string" },
          },
          required: ["foo"],
        )
        assert_includes schema.to_h.keys, :definitions
      end

      test "accepts schemas with $ref string key and includes $ref in to_h" do
        schema = InputSchema.new({
          "properties" => {
            "foo" => { "$ref" => "#/definitions/bar" },
          },
          "definitions" => {
            "bar" => { "type" => "string" },
          },
        })
        assert_equal "#/definitions/bar", schema.to_h[:properties][:foo][:$ref]
      end

      test "accepts schemas with $ref symbol key and includes $ref in to_h" do
        schema = InputSchema.new({
          properties: {
            foo: { :$ref => "#/definitions/bar" },
          },
          definitions: {
            bar: { type: "string" },
          },
        })
        assert_equal "#/definitions/bar", schema.to_h[:properties][:foo][:$ref]
      end

      test "keeps the object root type while accepting 2020-12 composition keywords" do
        # Per SEP-2106, an input schema root must stay `type: "object"` but may use
        # the full 2020-12 vocabulary below the root.
        schema = InputSchema.new(
          "$defs": { name: { type: "string", minLength: 1 } },
          properties: {
            name: { "$ref": "#/$defs/name" },
            value: { oneOf: [{ type: "string" }, { type: "integer" }] },
          },
          if: { properties: { value: { type: "integer" } } },
          then: { required: ["name"] },
          allOf: [{ properties: { extra: { type: "boolean" } } }],
        )

        assert_equal "object", schema.to_h[:type]
        assert schema.to_h.key?(:"$defs")
        assert schema.to_h.key?(:if)
        assert schema.to_h.key?(:allOf)
      end

      test "== compares two input schemas with the same properties, required fields" do
        schema1 = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        schema2 = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_equal schema1, schema2

        schema3 = InputSchema.new(properties: { bar: { type: "string" } }, required: ["bar"])
        refute_equal schema1, schema3

        schema4 = InputSchema.new(properties: { foo: { type: "string" } }, required: ["bar"])
        refute_equal schema1, schema4

        schema5 = InputSchema.new(properties: { bar: { type: "string" } }, required: ["foo"])
        refute_equal schema1, schema5

        schema6 = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"], additionalProperties: false)
        refute_equal schema1, schema6
      end

      test "format keyword is not enforced (legacy behavior)" do
        schema = InputSchema.new(
          properties: { email: { type: "string", format: "email" } },
          required: ["email"],
        )
        assert_nil(schema.validate_arguments(email: "not_an_email"))
      end

      test "invalid pattern raises ArgumentError, not RegexpError" do
        error = assert_raises(ArgumentError) do
          InputSchema.new(properties: { id: { type: "string", pattern: "[" } })
        end
        assert_includes error.message, "Invalid JSON Schema"
      end

      test "Symbol values in arguments are treated as strings" do
        schema = InputSchema.new(properties: { foo: { type: "string" } }, required: ["foo"])
        assert_nil(schema.validate_arguments(foo: :bar))
      end
    end
  end
end
