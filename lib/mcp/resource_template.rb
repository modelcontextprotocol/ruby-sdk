# typed: strict
# frozen_string_literal: true

module MCP
  class ResourceTemplate
    attr_reader :uri_template, :name, :description, :mime_type, :to_h

    def initialize(uri_template:, name:, description: nil, mime_type: nil)
      @uri_template = uri_template
      @name = name
      @description = description
      @mime_type = mime_type

      @to_h = {
        uriTemplate: @uri_template,
        name: @name,
        description: @description,
        mimeType: @mime_type,
      }.compact.freeze

      freeze
    end
  end
end
