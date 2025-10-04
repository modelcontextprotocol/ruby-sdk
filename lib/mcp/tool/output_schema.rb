# frozen_string_literal: true

require "json-schema"

module MCP
  class Tool
    class OutputSchema
      class ValidationError < StandardError; end

      attr_reader :schema

      def initialize(schema = {})
        @schema = deep_transform_keys(JSON.parse(JSON.dump(schema)), &:to_sym)
        @schema[:type] ||= "object"
        validate_schema!
      end

      def ==(other)
        other.is_a?(OutputSchema) && schema == other.schema
      end

      def to_h
        @schema
      end

      def validate_result(result)
        errors = JSON::Validator.fully_validate(to_h, result)
        if errors.any?
          raise ValidationError, "Invalid result: #{errors.join(", ")}"
        end
      end

      private

      def deep_transform_keys(schema, &block)
        case schema
        when Hash
          schema.each_with_object({}) do |(key, value), result|
            if key.casecmp?("$ref")
              raise ArgumentError, "Invalid JSON Schema: $ref is not allowed in tool output schemas"
            end

            result[yield(key)] = deep_transform_keys(value, &block)
          end
        when Array
          schema.map { |e| deep_transform_keys(e, &block) }
        else
          schema
        end
      end

      def validate_schema!
        schema = to_h
        schema_reader = JSON::Schema::Reader.new(
          accept_uri: false,
          accept_file: ->(path) { path.to_s.start_with?(Gem.loaded_specs["json-schema"].full_gem_path) },
        )
        metaschema_path = Pathname.new(JSON::Validator.validator_for_name("draft4").metaschema)
        # Converts metaschema to a file URI for cross-platform compatibility
        metaschema_uri = JSON::Util::URI.file_uri(metaschema_path.expand_path.cleanpath.to_s.tr("\\", "/"))
        metaschema = metaschema_uri.to_s
        errors = JSON::Validator.fully_validate(metaschema, schema, schema_reader: schema_reader)
        if errors.any?
          raise ArgumentError, "Invalid JSON Schema: #{errors.join(", ")}"
        end
      end
    end
  end
end
