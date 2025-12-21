# frozen_string_literal: true

module MCP
  module Content
    class Text
      attr_reader :text, :annotations

      def initialize(text, annotations: nil)
        @text = text
        @annotations = annotations
      end

      def to_h
        { text: text, annotations: annotations, type: "text" }.compact
      end
    end

    class Image
      attr_reader :data, :mime_type, :annotations

      def initialize(data, mime_type, annotations: nil)
        @data = data
        @mime_type = mime_type
        @annotations = annotations
      end

      def to_h
        { data: data, mime_type: mime_type, annotations: annotations, type: "image" }.compact
      end
    end
  end
end
