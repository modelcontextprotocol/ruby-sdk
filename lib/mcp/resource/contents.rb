# frozen_string_literal: true

module MCP
  class Resource
    class Contents
      attr_reader :uri, :mime_type

      def initialize(uri:, mime_type: nil)
        @uri = uri
        @mime_type = mime_type
      end

      def to_h
        { uri: uri, mimeType: mime_type }.compact
      end
    end

    class TextContents < Contents
      attr_reader :text

      def initialize(text:, uri:, mime_type:)
        super(uri: uri, mime_type: mime_type)
        @text = text
      end

      def to_h
        super.merge(text: text)
      end
    end

    class BlobContents < Contents
      attr_reader :data

      def initialize(data:, uri:, mime_type:)
        super(uri: uri, mime_type: mime_type)
        @data = data
      end

      def to_h
        super.merge(blob: data)
      end
    end
  end
end
