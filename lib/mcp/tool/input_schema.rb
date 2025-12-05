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

      def ==(other)
        other.is_a?(InputSchema) && properties == other.properties && required == other.required
      end

      def to_h
        { type: "object" }.tap do |hsh|
          hsh[:properties] = properties if properties.any?
          hsh[:required] = required if required.any?
        end
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
        check_for_refs!
        schema = to_h
        gem_path = File.realpath(Gem.loaded_specs["json-schema"].full_gem_path)
        schema_reader = JSON::Schema::Reader.new(
          accept_uri: false,
          accept_file: ->(path) { File.realpath(path.to_s).start_with?(gem_path) },
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

      def check_for_refs!(obj = properties)
        case obj
        when Hash
          if obj.key?("$ref") || obj.key?(:$ref)
            raise ArgumentError, "Invalid JSON Schema: $ref is not allowed in tool input schemas"
          end

          obj.each_value { |value| check_for_refs!(value) }
        when Array
          obj.each { |item| check_for_refs!(item) }
        end
      end
    end
  end
end
