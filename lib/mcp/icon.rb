# frozen_string_literal: true

module MCP
  class Icon
    SUPPORTED_THEMES = ["light", "dark"]

    attr_reader :mime_type, :sizes, :src, :theme

    def initialize(mime_type: nil, sizes: nil, src: nil, theme: nil)
      raise ArgumentError, 'The value of theme must specify "light" or "dark".' if theme && !SUPPORTED_THEMES.include?(theme)

      @mime_type = mime_type
      @sizes = sizes
      @src = src
      @theme = theme
    end

    def to_h
      { mimeType: mime_type, sizes: sizes, src: src, theme: theme }.compact
    end
  end
end
