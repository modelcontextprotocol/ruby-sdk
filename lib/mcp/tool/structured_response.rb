# frozen_string_literal: true

module MCP
  class Tool
    class StructuredResponse
      attr_reader :content, :is_error

      # @param structured_content [Hash] The structured content of the response, must be provided.
      # @param content [String, nil] The content array of the response, can be nil. If nil will generate a single element with structured content converted to JSON string.
      # @param is_error [Boolean] Indicates if the response is an error.
      def initialize(structured_content, content: nil, is_error: false)
        raise ArgumentError, "structured_content must be provided" if structured_content.nil?

        @structured_content = structured_content
        @content = content || [{ type: :text, text: @structured_content.to_json }]
        @is_error = is_error
      end

      def to_h
        { content:, structuredContent: @structured_content, isError: is_error }.compact
      end
    end
  end
end
