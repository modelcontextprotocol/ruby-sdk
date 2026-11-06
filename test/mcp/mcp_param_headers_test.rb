# frozen_string_literal: true

require "test_helper"

module MCP
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
      ["oneOf", "items", "contentSchema", "$defs"].each do |keyword|
        nested = { "type" => "string", "x-mcp-header" => "Hidden" }
        sub = case keyword
        when "$defs" then { "entry" => nested }
        when "contentSchema" then nested
        else [nested]
        end
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

    def test_decode_value_takes_values_without_the_full_sentinel_literally
      assert_equal("us-west1", McpParamHeaders.decode_value("us-west1"))
      assert_equal("SGVsbG8=", McpParamHeaders.decode_value("SGVsbG8="))
      assert_equal("=?base64?SGVsbG8=", McpParamHeaders.decode_value("=?base64?SGVsbG8="))
      assert_equal("SGVsbG8=?=", McpParamHeaders.decode_value("SGVsbG8=?="))
      assert_equal("=?base64?=", McpParamHeaders.decode_value("=?base64?="))
    end

    def test_decode_value_decodes_the_sentinel_payload_as_utf_8
      assert_equal("Hello", McpParamHeaders.decode_value("=?base64?SGVsbG8=?="))
      assert_equal("", McpParamHeaders.decode_value("=?base64??="))
      assert_equal(" padded ", McpParamHeaders.decode_value("=?base64?IHBhZGRlZCA=?="))
      assert_equal("=?base64?literal?=", McpParamHeaders.decode_value("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="))
      assert_equal(Encoding::UTF_8, McpParamHeaders.decode_value("=?base64?SGVsbG8sIOS4lueVjA==?=").encoding)
    end

    def test_decode_value_refuses_malformed_payloads
      [
        "=?base64?SGVsbG8?=", # missing padding
        "=?base64?SGVs!!!bG8=?=", # characters outside the alphabet
        "=?base64?SGVsbG9=?=", # non-zero trailing bits
        "=?base64?SGVsbG8= ?=", # whitespace inside the payload
        "=?base64?/w==?=", # a byte that is not UTF-8
      ].each do |value|
        assert_nil(McpParamHeaders.decode_value(value), value)
      end
    end

    def test_decode_value_refuses_bytes_outside_the_field_value_set
      non_ascii = (+"caf\xC3\xA9").force_encoding(Encoding::UTF_8)

      assert_nil(McpParamHeaders.decode_value(non_ascii))
      assert_nil(McpParamHeaders.decode_value(non_ascii.b))
      assert_nil(McpParamHeaders.decode_value("a\x01b"))
      assert_nil(McpParamHeaders.decode_value("a\nb"))
      assert_equal("a\tb", McpParamHeaders.decode_value("a\tb"))
    end

    def test_mismatch_accepts_agreeing_headers_and_pairs_absent_together
      declarations = [
        { path: ["region"], header_name: "Region", type: "string" },
        { path: ["priority"], header_name: "Priority", type: "integer" },
        { path: ["verbose"], header_name: "Verbose", type: "boolean" },
        { path: ["options", "zone"], header_name: "Zone", type: "string" },
      ]
      headers = {
        "Mcp-Param-Region" => "=?base64?IHBhZGRlZCA=?=",
        "Mcp-Param-Priority" => "42.0",
        "Mcp-Param-Verbose" => "true",
      }
      arguments = { "region" => " padded ", "priority" => 42, "verbose" => true, "options" => { "zone" => nil } }

      assert_nil(McpParamHeaders.mismatch(declarations, arguments) { |name| headers[name] })
    end

    def test_mismatch_names_the_header_and_the_argument_but_never_a_value
      declarations = [{ path: ["region"], header_name: "Region", type: "string" }]
      cases = {
        { "Mcp-Param-Region" => "us-east1" } => "Mcp-Param-Region header does not match the `region` argument",
        {} => "Mcp-Param-Region header is missing but the request body carries a `region` argument",
        { "Mcp-Param-Region" => "=?base64?SGVsbG8?=" } => "Mcp-Param-Region header carries a malformed Base64 value",
        # Two copies of the header joined by the HTTP server, or a value no conforming client sends unwrapped.
        { "Mcp-Param-Region" => "us-west1, us-west1" } => "Mcp-Param-Region header does not match the `region` argument",
        { "Mcp-Param-Region" => "us-west1é" } => "Mcp-Param-Region header holds a character that is not allowed in a field value",
      }

      cases.each do |headers, message|
        assert_equal(message, McpParamHeaders.mismatch(declarations, { "region" => "us-west1" }) { |name| headers[name] })
        refute_includes(message, "us-west1")
        refute_includes(message, "us-east1")
      end
    end

    def test_mismatch_refuses_a_header_whose_argument_is_absent_null_or_unrenderable
      declarations = [{ path: ["region"], header_name: "Region", type: "string" }]
      present = ->(_name) { "us-west1" }
      absent_message = "Mcp-Param-Region header is present but the request body carries no `region` argument"

      assert_equal(absent_message, McpParamHeaders.mismatch(declarations, {}, &present))
      assert_equal(absent_message, McpParamHeaders.mismatch(declarations, { "region" => nil }, &present))
      assert_equal(
        "Mcp-Param-Region header does not match the `region` argument",
        McpParamHeaders.mismatch(declarations, { "region" => { "nested" => true } }, &present),
      )
      assert_nil(McpParamHeaders.mismatch(declarations, { "region" => { "nested" => true } }) { |_name| nil })
    end

    def test_mismatch_compares_numbers_numerically_only_for_canonical_decimals
      integer = [{ path: ["priority"], header_name: "Priority", type: "integer" }]
      { "42" => true, "42.0" => true, "42.5" => false, "043" => false, " 42" => false, "0x2a" => false, "43" => false }
        .each do |header, agrees|
        message = McpParamHeaders.mismatch(integer, { "priority" => 42 }) { |_name| header }

        if agrees
          assert_nil(message, header)
        else
          assert_includes(message, "does not match", header)
        end
      end

      number = [{ path: ["ratio"], header_name: "Ratio", type: "number" }]
      assert_nil(McpParamHeaders.mismatch(number, { "ratio" => 0.5 }) { |_name| "0.50" })
      assert_includes(McpParamHeaders.mismatch(number, { "ratio" => 0.5 }) { |_name| "0.51" }, "does not match")
      # A string declaration never compares numerically, however numeric the values look.
      text = [{ path: ["code"], header_name: "Code", type: "string" }]
      assert_includes(McpParamHeaders.mismatch(text, { "code" => "42" }) { |_name| "42.0" }, "does not match")
      assert_nil(McpParamHeaders.mismatch(integer, { "priority" => 1 }) { |_name| "1.000000" })
      # A numeral past the bound is judged by byte equality alone, so only its exact rendering agrees.
      assert_nil(McpParamHeaders.mismatch(integer, { "priority" => 1 }) { |_name| "1.#{"0" * 62}" })
      assert_includes(McpParamHeaders.mismatch(integer, { "priority" => 1 }) { |_name| "1.#{"0" * 63}" }, "does not match")
    end

    def test_mismatch_takes_the_overlapping_sentinel_markers_literally
      declarations = [{ path: ["code"], header_name: "Code", type: "string" }]

      assert_nil(McpParamHeaders.mismatch(declarations, { "code" => "=?base64?=" }) { |_name| "=?base64?=" })
    end
  end
end
