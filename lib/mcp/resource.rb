# frozen_string_literal: true

require_relative "resource/contents"
require_relative "resource/embedded"

module MCP
  class Resource
    attr_reader :uri, :name, :title, :description, :icons, :mime_type

    def initialize(uri:, name:, title: nil, description: nil, icons: [], mime_type: nil)
      @uri = uri
      @name = name
      @title = title
      @description = description
      @icons = icons
      @mime_type = mime_type
    end

    def to_h
      {
        uri: uri,
        name: name,
        title: title,
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        mimeType: mime_type,
      }.compact
    end
  end
end
