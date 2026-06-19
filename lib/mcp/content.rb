# frozen_string_literal: true

module MCP
  module Content
    class Text
      attr_reader :text, :annotations, :meta

      def initialize(text, annotations: nil, meta: nil)
        @text = text
        @annotations = annotations
        @meta = meta
      end

      def to_h
        { text: text, annotations: annotations, _meta: meta, type: "text" }.compact
      end
    end

    class Image
      attr_reader :data, :mime_type, :annotations, :meta

      def initialize(data, mime_type, annotations: nil, meta: nil)
        @data = data
        @mime_type = mime_type
        @annotations = annotations
        @meta = meta
      end

      def to_h
        { data: data, mimeType: mime_type, annotations: annotations, _meta: meta, type: "image" }.compact
      end
    end

    class Audio
      attr_reader :data, :mime_type, :annotations, :meta

      def initialize(data, mime_type, annotations: nil, meta: nil)
        @data = data
        @mime_type = mime_type
        @annotations = annotations
        @meta = meta
      end

      def to_h
        { data: data, mimeType: mime_type, annotations: annotations, _meta: meta, type: "audio" }.compact
      end
    end

    class EmbeddedResource
      attr_reader :resource, :annotations, :meta

      def initialize(resource, annotations: nil, meta: nil)
        @resource = resource
        @annotations = annotations
        @meta = meta
      end

      def to_h
        { resource: resource.to_h, annotations: annotations, _meta: meta, type: "resource" }.compact
      end
    end
  end
end
