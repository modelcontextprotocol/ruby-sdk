# frozen_string_literal: true

module MCP
  class Tool
    class Response
      NOT_GIVEN = Object.new.freeze

      attr_reader :content

      def initialize(content, deprecated_error = NOT_GIVEN, error: false)
        if deprecated_error != NOT_GIVEN
          warn("Passing `error` with the 2nd argument of `Response.new` is deprecated. Use keyword argument like `Response.new(content, error: error)` instead.", uplevel: 1)
          error = deprecated_error
        end

        @content = content
        @error = error
      end

      def error?
        !!@error
      end

      def to_h
        { content:, isError: error? }.compact
      end
    end
  end
end
