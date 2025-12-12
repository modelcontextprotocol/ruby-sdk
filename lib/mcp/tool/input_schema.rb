# frozen_string_literal: true

require_relative "schema"

module MCP
  class Tool
    class InputSchema < Schema
      class ValidationError < StandardError; end

      def missing_required_arguments?(arguments)
        missing_required_arguments(arguments).any?
      end

      def missing_required_arguments(arguments)
        return [] unless schema[:required].is_a?(Array)

        (schema[:required] - arguments.keys.map(&:to_s))
      end

      def validate_arguments(arguments)
        errors = fully_validate(arguments)
        if errors.any?
          raise ValidationError, "Invalid arguments: #{errors.join(", ")}"
        end
      end
    end
  end
end
