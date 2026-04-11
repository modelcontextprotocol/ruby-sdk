# frozen_string_literal: true

module MCP
  class Resource
    class Contents
      attr_reader :uri, :mime_type, :meta

      def initialize(uri:, mime_type: nil, meta: nil)
        @uri = uri
        @mime_type = mime_type
        @meta = meta
      end

      def to_h
        { uri: uri, mimeType: mime_type, _meta: meta }.compact
      end
    end

    class TextContents < Contents
      attr_reader :text

      def initialize(text:, uri:, mime_type:, meta: nil)
        super(uri: uri, mime_type: mime_type, meta: meta)
        @text = text
      end

      def to_h
        super.merge(text: text)
      end
    end

    class BlobContents < Contents
      attr_reader :data

      def initialize(data:, uri:, mime_type:, meta: nil)
        super(uri: uri, mime_type: mime_type, meta: meta)
        @data = data
      end

      def to_h
        super.merge(blob: data)
      end
    end
  end
end
