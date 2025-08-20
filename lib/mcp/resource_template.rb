# typed: strict
# frozen_string_literal: true

module MCP
  class ResourceTemplate
    attr_reader :uri_template, :name, :title, :description, :mime_type

    def initialize(uri_template:, name:, title: nil, description: nil, mime_type: nil)
      @uri_template = uri_template
      @name = name
      @title = title
      @description = description
      @mime_type = mime_type
    end

    def to_h
      {
        uriTemplate: uri_template,
        name: name,
        title: title,
        description: description,
        mimeType: mime_type,
      }.compact
    end
  end
end
