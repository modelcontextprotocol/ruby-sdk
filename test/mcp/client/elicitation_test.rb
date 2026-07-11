# frozen_string_literal: true

require "test_helper"
require "mcp/client/elicitation"

module MCP
  class Client
    class ElicitationTest < Minitest::Test
      REQUESTED_SCHEMA = {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string", "default" => "John Doe" },
          "age" => { "type" => "integer", "default" => 30 },
          "score" => { "type" => "number", "default" => 95.5 },
          "status" => { "type" => "string", "enum" => ["active", "inactive", "pending"], "default" => "active" },
          "verified" => { "type" => "boolean", "default" => true },
        },
        "required" => [],
      }.freeze

      def test_apply_defaults_fills_all_omitted_fields
        content = Elicitation.apply_defaults(REQUESTED_SCHEMA)

        assert_equal(
          {
            "name" => "John Doe",
            "age" => 30,
            "score" => 95.5,
            "status" => "active",
            "verified" => true,
          },
          content,
        )
      end

      def test_apply_defaults_does_not_overwrite_provided_values
        content = Elicitation.apply_defaults(REQUESTED_SCHEMA, { "name" => "Alice", "verified" => false })

        assert_equal(
          {
            "name" => "Alice",
            "verified" => false,
            "age" => 30,
            "score" => 95.5,
            "status" => "active",
          },
          content,
        )
      end

      def test_apply_defaults_skips_properties_without_a_default
        schema = {
          "type" => "object",
          "properties" => {
            "name" => { "type" => "string", "default" => "John Doe" },
            "email" => { "type" => "string" },
          },
        }

        content = Elicitation.apply_defaults(schema)

        assert_equal({ "name" => "John Doe" }, content)
        refute(content.key?("email"))
      end

      def test_apply_defaults_applies_a_false_default
        schema = {
          "type" => "object",
          "properties" => {
            "verified" => { "type" => "boolean", "default" => false },
          },
        }

        content = Elicitation.apply_defaults(schema)

        assert_equal({ "verified" => false }, content)
      end

      def test_apply_defaults_supports_symbol_keyed_schemas_and_content
        schema = {
          type: "object",
          properties: {
            name: { type: "string", default: "John Doe" },
            age: { type: "integer", default: 30 },
          },
        }

        content = Elicitation.apply_defaults(schema, { age: 42 })

        assert_equal({ "age" => 42, "name" => "John Doe" }, content)
      end

      def test_apply_defaults_returns_content_when_schema_has_no_properties
        content = Elicitation.apply_defaults({ "type" => "object" }, { "name" => "Alice" })

        assert_equal({ "name" => "Alice" }, content)
      end
    end
  end
end
