# typed: strict
# frozen_string_literal: true

module MCP
  class Resource
    attr_reader :uri, :name, :title, :description, :mime_type

    def initialize(uri:, name:, title: nil, description: nil, mime_type: nil)
      @uri = uri
      @name = name
      @title = title
      @description = description
      @mime_type = mime_type
    end

    def to_h
      {
        uri: uri,
        name: name,
        title: title,
        description: description,
        mimeType: mime_type,
      }.compact
    end
  end
end
