# frozen_string_literal: true

require "json-schema"

module MCP
  class Tool
    class Schema
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

      def fully_validate!(payload, label)
        errors = JSON::Validator.fully_validate(schema_for_validation, payload)
        if errors.any?
          raise self.class::ValidationError, "Invalid #{label}: #{errors.join(", ")}"
        end
      end

      def validate_schema!
        gem_path = File.realpath(Gem.loaded_specs["json-schema"].full_gem_path)
        schema_reader = JSON::Schema::Reader.new(
          accept_uri: false,
          accept_file: ->(path) { File.realpath(path.to_s).start_with?(gem_path) },
        )
        metaschema_path = Pathname.new(JSON::Validator.validator_for_name("draft4").metaschema)
        # Converts metaschema to a file URI for cross-platform compatibility
        metaschema_uri = JSON::Util::URI.file_uri(metaschema_path.expand_path.cleanpath.to_s.tr("\\", "/"))
        metaschema = metaschema_uri.to_s
        errors = JSON::Validator.fully_validate(metaschema, schema_for_validation, schema_reader: schema_reader)
        if errors.any?
          raise ArgumentError, "Invalid JSON Schema: #{errors.join(", ")}"
        end
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
