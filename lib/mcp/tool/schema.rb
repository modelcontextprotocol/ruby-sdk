# frozen_string_literal: true

require "digest"
require "json-schema"

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
      # is still performed against the JSON Schema draft-04 metaschema because
      # the `json-schema` gem does not yet support 2020-12.
      JSON_SCHEMA_2020_12_URI = "https://json-schema.org/draft/2020-12/schema"

      attr_reader :schema

      def initialize(schema = {})
        @schema = JSON.parse(JSON.dump(schema), symbolize_names: true)
        @schema[:type] ||= "object"
        validate_schema!
      end

      def ==(other)
        other.is_a?(self.class) && schema == other.schema
      end

      def to_h
        return @schema if @schema.key?(:"$schema")

        { "$schema": JSON_SCHEMA_2020_12_URI }.merge(@schema)
      end

      private

      def fully_validate(data)
        JSON::Validator.fully_validate(schema_for_validation, data)
      end

      def validate_schema!
        target = schema_for_validation

        # `max_nesting: false` because normalization uses `JSON.dump` (no nesting limit),
        # so the default `JSON.generate` limit would raise on a deeply nested schema that
        # the initializer already accepted.
        key = Digest::SHA256.hexdigest(JSON.generate(target, max_nesting: false))
        return if VALIDATION_CACHE.validated?(key)

        gem_path = File.realpath(Gem.loaded_specs["json-schema"].full_gem_path)
        schema_reader = JSON::Schema::Reader.new(
          accept_uri: false,
          accept_file: ->(path) { File.realpath(path.to_s).start_with?(gem_path) },
        )
        metaschema_path = Pathname.new(JSON::Validator.validator_for_name("draft4").metaschema)
        # Converts metaschema to a file URI for cross-platform compatibility
        metaschema_uri = JSON::Util::URI.file_uri(metaschema_path.expand_path.cleanpath.to_s.tr("\\", "/"))
        metaschema = metaschema_uri.to_s
        errors = JSON::Validator.fully_validate(metaschema, target, schema_reader: schema_reader)
        if errors.any?
          raise ArgumentError, "Invalid JSON Schema: #{errors.join(", ")}"
        end

        VALIDATION_CACHE.store(key)
      end

      # The `json-schema` gem's draft-04 validator cannot resolve newer or unknown `$schema`
      # dialect URIs. Strip the top-level `$schema` before validation so a dialect URI
      # (whether SDK-injected by `to_h` or user-supplied) does not break the validator.
      def schema_for_validation
        return @schema unless @schema.key?(:"$schema")

        copy = @schema.dup
        copy.delete(:"$schema")
        copy
      end
    end
  end
end
