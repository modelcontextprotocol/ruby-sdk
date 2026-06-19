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

      # JSON Schema 2020-12 is the default dialect for MCP schema definitions per MCP 2025-11-25 (SEP-1613),
      # and SEP-2106 requires tool schemas to conform to the full 2020-12 vocabulary. Both emission and
      # runtime validation use this dialect. Because MCP mandates 2020-12, the SDK validates against it
      # regardless of any `$schema` a document embeds; for compliant schemas this is the same dialect
      # the Python SDK's `jsonschema.validate` resolves to.
      JSON_SCHEMA_2020_12_URI = "https://json-schema.org/draft/2020-12/schema"

      # Resource bounds for schema compilation, mirroring the TypeScript SDK's schema bounds (SEP-2106):
      # schemas may use the full JSON Schema 2020-12 vocabulary including composition keywords and `$ref`,
      # so adversarial documents must be rejected before they can cause excessive validation cost.
      # Only same-document references (starting with `#`) are accepted, so schema handling can never trigger network
      # or file access.
      MAX_SCHEMA_DEPTH = 64
      MAX_SUBSCHEMA_COUNT = 10_000

      # Reference keywords whose targets the SDK refuses to dereference. Both `$ref` and `$dynamicRef` may carry
      # an absolute URI under JSON Schema 2020-12, so a non-same-document value is an external reference.
      REFERENCE_KEYWORDS = [:"$ref", :"$dynamicRef"].freeze

      def initialize(schema = {})
        @schema = JSON.parse(JSON.dump(schema), symbolize_names: true)
        apply_default_root_type!
        validate_schema_bounds!
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

      # Root-type defaulting hook. The base class preserves the historical behavior of defaulting the root
      # to an object schema; `OutputSchema` overrides this because SEP-2106 allows any root schema there.
      def apply_default_root_type!
        @schema[:type] ||= "object"
      end

      # Enforces `MAX_SCHEMA_DEPTH` / `MAX_SUBSCHEMA_COUNT` and the same-document reference rule over
      # the whole schema document.
      def validate_schema_bounds!
        subschema_count = 0
        stack = [[@schema, 1]]

        until stack.empty?
          node, depth = stack.pop
          if depth > MAX_SCHEMA_DEPTH
            raise ArgumentError,
              "Invalid JSON Schema: nesting exceeds the maximum depth of #{MAX_SCHEMA_DEPTH}."
          end

          case node
          when Hash
            subschema_count += 1
            if subschema_count > MAX_SUBSCHEMA_COUNT
              raise ArgumentError,
                "Invalid JSON Schema: document exceeds the maximum of #{MAX_SUBSCHEMA_COUNT} subschema objects."
            end

            REFERENCE_KEYWORDS.each do |keyword|
              ref = node[keyword]
              next unless ref.is_a?(String) && !ref.start_with?("#")

              raise ArgumentError,
                "Invalid JSON Schema: only same-document #{keyword} (starting with '#') is supported, got #{ref.inspect}."
            end

            node.each_value { |child| stack << [child, depth + 1] }
          when Array
            node.each { |child| stack << [child, depth + 1] }
          end
        end
      end

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
      # Validated against the JSON Schema 2020-12 metaschema per SEP-2106, so `$defs`/`$ref` and
      # the rest of the 2020-12 vocabulary resolve natively.
      #
      # `format: false` preserves the legacy behavior of the previous `json-schema` based implementation,
      # which did not enforce `format` keywords. `RegexpError` from a malformed `pattern` is re-raised as
      # `ArgumentError` so callers see the same exception class they used to.
      def schemer
        @schemer ||= JSONSchemer.schema(
          stringify(schema_for_validation),
          meta_schema: JSON_SCHEMA_2020_12_URI,
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

      # Strip the top-level `$schema` before validation so the SDK always validates against
      # the 2020-12 metaschema (SEP-2106) regardless of any dialect URI a caller embedded in the document.
      def schema_for_validation
        return @schema unless @schema.key?(:"$schema")

        copy = @schema.dup
        copy.delete(:"$schema")
        copy
      end
    end
  end
end
