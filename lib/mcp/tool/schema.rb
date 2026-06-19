# frozen_string_literal: true

require "digest"
require "json_schemer"

module MCP
  class Tool
    class Schema
      # Metaschema validation depends only on schema content, so a given schema
      # never needs to be validated more than once. Caching the result lets repeated
      # (e.g. dynamically rebuilt) schemas skip the costly traversal.
      class ValidationCache
        DEFAULT_MAX_SIZE = 1000

        def initialize(max_size: DEFAULT_MAX_SIZE)
          @max_size = max_size
          @entries = {}
          @mutex = Mutex.new
        end

        def validated?(key)
          @mutex.synchronize { @entries.key?(key) }
        end

        def store(key)
          @mutex.synchronize do
            @entries.delete(key)
            @entries[key] = true
            @entries.shift while @entries.size > @max_size
          end
        end

        def clear
          @mutex.synchronize { @entries.clear }
        end
      end
      VALIDATION_CACHE = ValidationCache.new

      # JSON Schema 2020-12 is the default dialect for MCP schema definitions
      # per MCP 2025-11-25 (SEP-1613). Note: emission only — runtime validation
      # is still performed against the JSON Schema draft-04 metaschema.
      JSON_SCHEMA_2020_12_URI = "https://json-schema.org/draft/2020-12/schema"

      DRAFT4_META_SCHEMA_URI = "http://json-schema.org/draft-04/schema#"

      def initialize(schema = {})
        @schema = JSON.parse(JSON.dump(schema), symbolize_names: true)
        @schema[:type] ||= "object"
        validate_schema!
      end

      def ==(other)
        other.is_a?(self.class) && @schema == other.instance_variable_get(:@schema)
      end

      def to_h
        return @schema if @schema.key?(:"$schema")

        { "$schema": JSON_SCHEMA_2020_12_URI }.merge(@schema)
      end

      private

      def stringify(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
        when Array
          obj.map { |v| stringify(v) }
        when Symbol
          obj.to_s
        else
          obj
        end
      end

      # Lazily built so a cache hit in `validate_schema!` avoids the schemer construction cost.
      # Memoized per Schema instance because schema content is fixed at construction,
      # so the compiled schemer is reusable across many `fully_validate` calls.
      #
      # `format: false` preserves the legacy behavior of the previous `json-schema` based implementation,
      # which did not enforce `format` keywords. `RegexpError` from a malformed `pattern` is re-raised as
      # `ArgumentError` so callers see the same exception class they used to.
      def schemer
        @schemer ||= JSONSchemer.schema(
          stringify(schema_for_validation),
          meta_schema: DRAFT4_META_SCHEMA_URI,
          format: false,
        )
      rescue RegexpError => e
        raise ArgumentError, "Invalid JSON Schema: #{e.message}"
      end

      def fully_validate(data)
        schemer.validate(stringify(data)).map { |validation_error| validation_error.fetch("error") }
      end

      def validate_schema!
        target = schema_for_validation

        # `max_nesting: false` because normalization uses `JSON.dump` (no nesting limit),
        # so the default `JSON.generate` limit would raise on a deeply nested schema that
        # the initializer already accepted.
        key = Digest::SHA256.hexdigest(JSON.generate(target, max_nesting: false))
        return if VALIDATION_CACHE.validated?(key)

        errors = schemer.validate_schema.map { |validation_error| validation_error.fetch("error") }
        if errors.any?
          raise ArgumentError, "Invalid JSON Schema: #{errors.join(", ")}"
        end

        VALIDATION_CACHE.store(key)
      end

      # `json_schemer` is pinned to the draft-04 metaschema, so strip top-level `$schema` before validation:
      # this preserves the legacy behavior of ignoring the advertised dialect URI when the SDK validates schemas.
      def schema_for_validation
        return @schema unless @schema.key?(:"$schema")

        copy = @schema.dup
        copy.delete(:"$schema")
        copy
      end
    end
  end
end
