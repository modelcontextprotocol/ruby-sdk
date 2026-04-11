# frozen_string_literal: true

module MCP
  class Tool
    class Response
      NOT_GIVEN = Object.new.freeze

      attr_reader :content, :structured_content, :meta

      def initialize(content = nil, deprecated_error = NOT_GIVEN, error: false, structured_content: nil, meta: nil)
        if deprecated_error != NOT_GIVEN
          warn("Passing `error` with the 2nd argument of `Response.new` is deprecated. Use keyword argument like `Response.new(content, error: error)` instead.", uplevel: 1)
          error = deprecated_error
        end

        @content = content || []
        @error = error
        @structured_content = structured_content
        @meta = meta
      end

      def error?
        !!@error
      end

      def to_h
        { content: content, isError: error?, structuredContent: @structured_content, _meta: meta }.compact
      end
    end
  end
end
