# frozen_string_literal: true

require "test_helper"
require "mcp/client/mcp_param_headers"

module MCP
  class Client
    class McpParamHeadersTest < Minitest::Test
      def test_scan_collects_declarations_from_properties
        scan = McpParamHeaders.scan({
          "type" => "object",
          "properties" => {
            "region" => { "type" => "string", "x-mcp-header" => "Region" },
            "priority" => { "type" => "integer", "x-mcp-header" => "Priority" },
            "verbose" => { "type" => "boolean", "x-mcp-header" => "Verbose" },
            "plain" => { "type" => "string" },
          },
        })

        assert(scan[:valid])
        assert_equal(
          [
            { path: ["region"], header_name: "Region", type: "string" },
            { path: ["priority"], header_name: "Priority", type: "integer" },
            { path: ["verbose"], header_name: "Verbose", type: "boolean" },
          ],
          scan[:declarations],
        )
      end

      def test_scan_collects_nested_declarations_and_symbol_keys
        scan = McpParamHeaders.scan({
          type: "object",
          properties: {
            options: {
              type: "object",
              properties: {
                region: { type: "string", "x-mcp-header": "Region" },
              },
            },
          },
        })

        assert(scan[:valid])
        assert_equal([{ path: ["options", "region"], header_name: "Region", type: "string" }], scan[:declarations])
      end

      def test_scan_accepts_number_typed_declarations
        scan = McpParamHeaders.scan({
          "type" => "object",
          "properties" => { "float_val" => { "type" => "number", "x-mcp-header" => "FloatVal" } },
        })

        assert(scan[:valid])
        assert_equal("number", scan[:declarations].first[:type])
      end

      def test_scan_rejects_an_annotation_at_the_schema_root
        scan = McpParamHeaders.scan({ "type" => "object", "x-mcp-header" => "Root" })

        refute(scan[:valid])
        assert_includes(scan[:reason], "statically reachable")
      end

      def test_scan_rejects_annotations_under_non_reachable_keywords
        ["oneOf", "items", "$defs"].each do |keyword|
          nested = { "type" => "string", "x-mcp-header" => "Hidden" }
          sub = keyword == "$defs" ? { "entry" => nested } : [nested]
          scan = McpParamHeaders.scan({ "type" => "object", keyword => sub })

          refute(scan[:valid], "expected the annotation under #{keyword} to invalidate the schema")
        end
      end

      def test_scan_rejects_empty_and_non_string_annotations
        ["", 42].each do |annotation|
          scan = McpParamHeaders.scan({
            "type" => "object",
            "properties" => { "value" => { "type" => "string", "x-mcp-header" => annotation } },
          })

          refute(scan[:valid])
          assert_includes(scan[:reason], "non-empty string")
        end
      end

      def test_scan_rejects_non_token_annotation_names
        ["has space", "colon:name", "日本語", "line\nbreak"].each do |annotation|
          scan = McpParamHeaders.scan({
            "type" => "object",
            "properties" => { "value" => { "type" => "string", "x-mcp-header" => annotation } },
          })

          refute(scan[:valid], "expected #{annotation.inspect} to be rejected")
          assert_includes(scan[:reason], "RFC 9110")
        end
      end

      def test_scan_rejects_non_primitive_declaring_properties
        [{ "type" => "object" }, { "type" => "array" }, {}].each do |extra|
          scan = McpParamHeaders.scan({
            "type" => "object",
            "properties" => { "value" => extra.merge("x-mcp-header" => "Value") },
          })

          refute(scan[:valid])
          assert_includes(scan[:reason], "primitive-typed")
        end
      end

      def test_scan_rejects_case_insensitively_duplicated_names
        scan = McpParamHeaders.scan({
          "type" => "object",
          "properties" => {
            "one" => { "type" => "string", "x-mcp-header" => "Region" },
            "two" => { "type" => "string", "x-mcp-header" => "REGION" },
          },
        })

        refute(scan[:valid])
        assert_includes(scan[:reason], "case-insensitively unique")
      end

      def test_primitive_to_string_conversions
        assert_equal("us-west1", McpParamHeaders.primitive_to_string("us-west1"))
        assert_equal("true", McpParamHeaders.primitive_to_string(true))
        assert_equal("false", McpParamHeaders.primitive_to_string(false))
        assert_equal("42", McpParamHeaders.primitive_to_string(42))
        assert_equal("42", McpParamHeaders.primitive_to_string(42.0))
        assert_equal("3.14159", McpParamHeaders.primitive_to_string(3.14159))
        assert_nil(McpParamHeaders.primitive_to_string(2**53 + 1))
        assert_nil(McpParamHeaders.primitive_to_string(Float::INFINITY))
        assert_nil(McpParamHeaders.primitive_to_string({ "nested" => true }))
      end

      def test_encode_value_passes_safe_ascii_through
        assert_equal("us-west1", McpParamHeaders.encode_value("us-west1"))
        assert_equal("SELECT * FROM users", McpParamHeaders.encode_value("SELECT * FROM users"))
      end

      def test_encode_value_wraps_unsafe_values_in_the_base64_sentinel
        {
          "" => "",
          "Hello, 世界" => "Hello, 世界",
          " padded " => " padded ",
          "\tindented" => "\tindented",
          "line1\nline2" => "line1\nline2",
          "line1\r\nline2" => "line1\r\nline2",
          "=?base64?Zm9v?=" => "=?base64?Zm9v?=",
        }.each do |raw, decoded|
          encoded = McpParamHeaders.encode_value(raw)

          assert_match(/\A=\?base64\?.*\?=\z/, encoded, "expected #{raw.inspect} to be wrapped")
          payload = encoded.delete_prefix("=?base64?").delete_suffix("?=")
          assert_equal(decoded, payload.unpack1("m0").force_encoding(Encoding::UTF_8))
        end
      end

      def test_build_mirrors_declared_arguments_into_prefixed_headers
        declarations = [
          { path: ["region"], header_name: "Region", type: "string" },
          { path: ["priority"], header_name: "Priority", type: "integer" },
          { path: ["method_val"], header_name: "Method", type: "string" },
        ]

        headers = McpParamHeaders.build(declarations, { "region" => "us-west1", priority: 42, "method_val" => "test-method" })

        assert_equal(
          {
            "Mcp-Param-Region" => "us-west1",
            "Mcp-Param-Priority" => "42",
            "Mcp-Param-Method" => "test-method",
          },
          headers,
        )
      end

      def test_build_omits_null_absent_and_non_primitive_values
        declarations = [
          { path: ["null_val"], header_name: "NullVal", type: "string" },
          { path: ["absent"], header_name: "Absent", type: "string" },
          { path: ["object_val"], header_name: "ObjectVal", type: "string" },
        ]

        headers = McpParamHeaders.build(declarations, { "null_val" => nil, "object_val" => { "a" => 1 } })

        assert_empty(headers)
      end

      def test_build_reads_nested_paths
        declarations = [{ path: ["options", "region"], header_name: "Region", type: "string" }]

        headers = McpParamHeaders.build(declarations, { "options" => { "region" => "us-east1" } })

        assert_equal({ "Mcp-Param-Region" => "us-east1" }, headers)
      end

      def test_build_omits_values_that_cannot_be_represented_as_utf_8
        declarations = [{ path: ["blob"], header_name: "Blob", type: "string" }]
        binary = (+"\xff\xfe").force_encoding(Encoding::ASCII_8BIT)

        headers = McpParamHeaders.build(declarations, { "blob" => binary })

        assert_empty(headers)
      end
    end
  end
end
