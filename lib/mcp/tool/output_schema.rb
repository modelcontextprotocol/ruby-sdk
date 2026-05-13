# frozen_string_literal: true

require_relative "schema"

module MCP
  class Tool
    class OutputSchema < Schema
      class ValidationError < StandardError; end

      def validate_result(result)
        fully_validate!(result, "result")
      end
    end
  end
end
