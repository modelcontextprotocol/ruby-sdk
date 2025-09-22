# frozen_string_literal: true

module MCP
  class Resource
    attr_reader :name, :title, :uri, :description, :mime_type, :annotations, :size, :meta

    def initialize(uri:, name:, title: nil, description: nil, mime_type: nil, annotations: nil, size: nil, meta: {})
      @name = name
      @title = title
      @uri = uri
      @description = description
      @mime_type = mime_type
      @annotations = annotations
      @size = size
      @meta = meta
    end

    def to_h
      {
        name: name,
        title: title,
        uri: uri,
        description: description,
        mimeType: mime_type,
        annotations: annotations&.to_h,
        size: size,
        _meta: meta,
      }.compact
    end
  end
end
