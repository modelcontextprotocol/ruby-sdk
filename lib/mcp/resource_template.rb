# frozen_string_literal: true

module MCP
  class ResourceTemplate
    attr_reader :name, :title, :uri_template, :description, :mime_type, :annotations, :meta

    def initialize(uri_template:, name:, title: nil, description: nil, mime_type: nil, annotations: nil, meta: nil)
      @name = name
      @title = title
      @uri_template = uri_template
      @description = description
      @mime_type = mime_type
      @annotations = annotations
      @meta = meta || {}
    end

    def to_h
      {
        name: name,
        title: title,
        uriTemplate: uri_template,
        description: description,
        mimeType: mime_type,
        annotations: annotations&.to_h,
        _meta: meta.empty? ? nil : meta,
      }.compact
    end
  end
end
