# frozen_string_literal: true

require_relative "schema"

module MCP
  class Tool
    class OutputSchema < Schema
      class ValidationError < StandardError; end

      def validate_result(result)
        errors = fully_validate(result)
        if errors.any?
          raise ValidationError, "Invalid result: #{errors.join(", ")}"
        end
      end
    end
  end
end
