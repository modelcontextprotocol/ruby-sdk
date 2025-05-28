# typed: strict
# frozen_string_literal: true

module ModelContextProtocol
  class Resource
    attr_reader :uri, :name, :description, :mime_type

    def initialize(uri:, name:, description:, mime_type:)
      @uri = uri
      @name = name
      @description = description
      @mime_type = mime_type
    end

    def to_h
      {
        uri: @uri,
        name: @name,
        description: @description,
        mimeType: @mime_type,
      }
    end
  end
end
