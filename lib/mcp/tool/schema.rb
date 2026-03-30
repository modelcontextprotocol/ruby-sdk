# frozen_string_literal: true

require "json-schema"

module MCP
  class Tool
    class Schema
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
        @schema
      end

      private

      def fully_validate(data)
        JSON::Validator.fully_validate(to_h, data)
      end

      def validate_schema!
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
    end
  end
end
