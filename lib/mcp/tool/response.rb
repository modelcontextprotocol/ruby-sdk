# frozen_string_literal: true

module MCP
  module Tool
    class Response
      attr_reader :content, :is_error

      def initialize(content, is_error = false)
        @content = content
        @is_error = is_error
      end

      def to_h
        { content:, isError: is_error }.compact
      end
    end
  end
end
