# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class SchemaTest < ActiveSupport::TestCase
      setup do
        Schema::VALIDATION_CACHE.clear
      end

      test "validates a schema once and reuses the result for identical schemas" do
        JSONSchemer::Schema.any_instance.expects(:validate_schema).once.returns([])

        schema = { properties: { validates_once: { type: "string" } } }
        InputSchema.new(schema)
        InputSchema.new(schema)
      end

      test "validates distinct schemas separately" do
        JSONSchemer::Schema.any_instance.expects(:validate_schema).twice.returns([])

        InputSchema.new(properties: { distinct_a: { type: "string" } })
        InputSchema.new(properties: { distinct_b: { type: "string" } })
      end

      test "a cache hit still yields a usable, validated schema" do
        schema = { properties: { cache_hit: { type: "string" } }, required: ["cache_hit"] }
        InputSchema.new(schema)
        cached = InputSchema.new(schema)

        assert_equal(
          {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            type: "object",
            properties: { cache_hit: { type: "string" } },
            required: ["cache_hit"],
          },
          cached.to_h,
        )
        assert_nil(cached.validate_arguments(cache_hit: "value"))
        assert_raises(InputSchema::ValidationError) do
          cached.validate_arguments(cache_hit: 123)
        end
      end

      test "an invalid schema raises every time and is not cached" do
        invalid = { properties: { not_cached: { type: "invalid_type" } } }

        assert_raises(ArgumentError) { InputSchema.new(invalid) }
        assert_raises(ArgumentError) { InputSchema.new(invalid) }
      end

      test "a schema nested deeper than MAX_SCHEMA_DEPTH raises" do
        # SEP-2106 resource bounds: unbounded nesting would make downstream validation arbitrarily expensive.
        # Each wrapping adds two levels (the schema hash and its `properties` hash), so this is the smallest
        # nesting that exceeds MAX_SCHEMA_DEPTH.
        wrappings = Schema::MAX_SCHEMA_DEPTH / 2 + 1
        schema = { type: "string" }
        wrappings.times do
          schema = { type: "object", properties: { child: schema } }
        end

        error = assert_raises(ArgumentError) { InputSchema.new(schema) }
        assert_match(/maximum depth/, error.message)
      end

      test "a schema with more subschema objects than MAX_SUBSCHEMA_COUNT raises" do
        properties = {}
        (Schema::MAX_SUBSCHEMA_COUNT + 1).times do |i|
          properties[:"property_#{i}"] = { type: "string" }
        end

        error = assert_raises(ArgumentError) { InputSchema.new(properties: properties) }
        assert_match(/subschema/, error.message)
      end

      test "rejects a $ref pointing outside the schema document" do
        # SEP-2106 requires same-document `$ref` resolution only; a remote URI or a sibling file must never trigger network
        # or file access.
        error = assert_raises(ArgumentError) do
          InputSchema.new(properties: { foo: { "$ref": "https://example.com/schema.json#/defs/bar" } })
        end
        assert_match(/same-document/, error.message)

        assert_raises(ArgumentError) do
          InputSchema.new(properties: { foo: { "$ref": "other.json#/defs/bar" } })
        end
      end

      test "rejects a $dynamicRef pointing outside the schema document" do
        # 2020-12 allows `$dynamicRef` to carry an absolute URI too, so the same-document restriction must cover it as well as `$ref`.
        error = assert_raises(ArgumentError) do
          InputSchema.new(properties: { foo: { "$dynamicRef": "https://example.com/schema.json#meta" } })
        end
        assert_match(/same-document/, error.message)
        assert_match(/\$dynamicRef/, error.message)
      end

      test "accepts a same-document $ref" do
        assert_nothing_raised do
          InputSchema.new(
            "$defs": { bar: { type: "string" } },
            properties: { foo: { "$ref": "#/$defs/bar" } },
          )
        end
      end

      test "ValidationCache evicts the oldest entry beyond its max size" do
        cache = Schema::ValidationCache.new(max_size: 2)
        cache.store("a")
        cache.store("b")
        cache.store("c")

        refute cache.validated?("a")
        assert cache.validated?("b")
        assert cache.validated?("c")
      end

      test "ValidationCache#clear empties the cache" do
        cache = Schema::ValidationCache.new
        cache.store("a")
        cache.clear

        refute cache.validated?("a")
      end
    end
  end
end
