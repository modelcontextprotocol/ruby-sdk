# frozen_string_literal: true

module MCP
  class ResourceTemplate
    attr_reader :uri_template, :name, :title, :description, :icons, :mime_type, :meta

    def initialize(uri_template:, name:, title: nil, description: nil, icons: [], mime_type: nil, meta: nil)
      @uri_template = uri_template
      @name = name
      @title = title
      @description = description
      @icons = icons
      @mime_type = mime_type
      @meta = meta
    end

    def to_h
      {
        uriTemplate: uri_template,
        name: name,
        title: title,
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        mimeType: mime_type,
        _meta: meta,
      }.compact
    end
  end
end
