# frozen_string_literal: true

require "json-schema"

module MCP
  class Tool
    class InputSchema
      class ValidationError < StandardError; end

      attr_reader :properties, :required

      def initialize(properties: {}, required: [])
        @properties = properties
        @required = required.map(&:to_sym)
        validate_schema!
      end

      def to_h
        { type: "object", properties:, required: }
      end

      def missing_required_arguments?(arguments)
        missing_required_arguments(arguments).any?
      end

      def missing_required_arguments(arguments)
        (required - arguments.keys.map(&:to_sym))
      end

      def validate_arguments(arguments)
        errors = JSON::Validator.fully_validate(to_h, arguments)
        if errors.any?
          raise ValidationError, "Invalid arguments: #{errors.join(", ")}"
        end
      end

      private

      def validate_schema!
        schema = to_h
        begin
          schema_reader = JSON::Schema::Reader.new(
            accept_uri: false,
            accept_file: ->(path) { path.to_s.start_with?(Gem.loaded_specs["json-schema"].full_gem_path) },
          )
          metaschema = JSON::Validator.validator_for_name("draft4").metaschema
          errors = JSON::Validator.fully_validate(metaschema, schema, schema_reader: schema_reader)
          if errors.any?
            raise ArgumentError, "Invalid JSON Schema: #{errors.join(", ")}"
          end
        rescue StandardError => e
          raise ArgumentError, "Invalid JSON Schema: #{e.message}"
        end
      end
    end
  end
end
