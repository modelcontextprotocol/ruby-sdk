# frozen_string_literal: true

module MCP
  # An icon attached to a server, tool, prompt, or resource, per the specification's `Icon` type:
  # https://modelcontextprotocol.io/specification/2026-07-28/basic#icons
  #
  # Each argument is checked against the schema's type, as the TypeScript and Python SDKs check theirs,
  # so an icon that would serialize into something a client rejects fails here instead. What a value means
  # is not judged: `src` may be any non-empty `String` (the schema types it as a URI, which an empty `String`
  # is not, and the specification allows an HTTP/HTTPS URL or a `data:` URI), and a size may be any `String`
  # (the specification expects `WxH` or `"any"`).
  class Icon
    SUPPORTED_THEMES = ["light", "dark"].freeze

    attr_reader :mime_type, :sizes, :src, :theme

    def initialize(mime_type: nil, sizes: nil, src:, theme: nil)
      unless src.is_a?(String) && !src.empty?
        raise ArgumentError, "The value of src must be a non-empty String (got #{src.class})."
      end

      unless mime_type.nil? || mime_type.is_a?(String)
        raise ArgumentError, "The value of mime_type must be a String (got #{mime_type.class})."
      end

      if (problem = sizes_problem(sizes))
        raise ArgumentError, "The value of sizes must be an Array of Strings such as [\"48x48\"] or [\"any\"] (#{problem})."
      end

      unless theme.nil? || SUPPORTED_THEMES.include?(theme)
        raise ArgumentError, 'The value of theme must specify "light" or "dark".'
      end

      @mime_type = mime_type
      @sizes = sizes
      @src = src
      @theme = theme
    end

    def to_h
      { mimeType: mime_type, sizes: sizes, src: src, theme: theme }.compact
    end

    private

    def sizes_problem(sizes)
      return if sizes.nil?
      return "got #{sizes.class}" unless sizes.is_a?(Array)

      index = sizes.index { |size| !size.is_a?(String) }

      "got #{sizes[index].class} inside the Array" if index
    end
  end
end
