# frozen_string_literal: true

module MCP
  class Tool
    class Response
      attr_reader :content, :error

      def initialize(content, error: false)
        @content = content
        @error = error
      end

      def to_h
        { content:, isError: error? }.compact
      end

      alias_method :error?, :error
    end
  end
end
