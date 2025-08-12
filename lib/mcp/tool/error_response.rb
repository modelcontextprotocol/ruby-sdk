# frozen_string_literal: true

module MCP
  class Tool
    class ErrorResponse
      def initialize(content) = super(content, error: true)
    end
  end
end
