# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class SchemaTest < ActiveSupport::TestCase
      setup do
        Schema::VALIDATION_CACHE.clear
      end

      test "validates a schema once and reuses the result for identical schemas" do
        JSON::Validator.expects(:fully_validate).once.returns([])

        schema = { properties: { validates_once: { type: "string" } } }
        InputSchema.new(schema)
        InputSchema.new(schema)
      end

      test "validates distinct schemas separately" do
        JSON::Validator.expects(:fully_validate).twice.returns([])

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

      test "a schema at the normalization depth limit is cached without a nesting error" do
        # The deepest schema the initializer can still normalize via JSON.dump/parse.
        # The cache key must tolerate the same depth; the default JSON.generate
        # nesting limit (100) is stricter than normalization and would raise here.
        schema = { properties: { leaf: { type: "string" } } }
        loop do
          candidate = { properties: { child: schema } }
          JSON.parse(JSON.dump(candidate))
          schema = candidate
        rescue JSON::NestingError
          break
        end

        JSON::Validator.stub(:fully_validate, []) do
          assert_nothing_raised do
            InputSchema.new(schema)
            InputSchema.new(schema)
          end
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
