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
  #
  # Wherever an `Icon` is accepted (`Server.new(icons:)` and the `icons` of a tool, prompt, resource, or resource template),
  # a Hash is accepted too and converted through `Icon.from`, so it is checked the same way.
  class Icon
    SUPPORTED_THEMES = ["light", "dark"].freeze

    # The keys `from` accepts in a Hash: the keyword names of `new` and the wire name `mimeType`,
    # as Symbols or Strings.
    HASH_KEYWORDS = {
      "src" => :src,
      "mimeType" => :mime_type,
      "mime_type" => :mime_type,
      "sizes" => :sizes,
      "theme" => :theme,
    }.freeze
    private_constant :HASH_KEYWORDS

    class << self
      # Returns `value` when it is already an `Icon`, builds one from a Hash, and refuses anything else.
      def from(value)
        return value if value.is_a?(Icon)

        unless value.is_a?(Hash)
          raise ArgumentError, "An icon must be an MCP::Icon or a Hash (got #{value.class})."
        end

        keywords = {}
        value.each do |key, member|
          unless key.is_a?(Symbol) || key.is_a?(String)
            raise ArgumentError, "An icon Hash key must be a Symbol or a String (got #{key.class})."
          end

          keyword = HASH_KEYWORDS[key.to_s]
          unless keyword
            raise ArgumentError, "An icon Hash may only hold src, mimeType (or mime_type), sizes, and theme (got #{key.inspect})."
          end
          raise ArgumentError, "An icon Hash gives #{keyword} twice." if keywords.key?(keyword)

          keywords[keyword] = member
        end

        new(**keywords)
      end

      # Converts the `icons` argument of a server, tool, prompt, resource, or resource template: `nil` stays `nil`,
      # each element of an Array goes through `from` into a frozen Array, and anything else is refused.
      # The frozen Array keeps a later `<<` on a reader from adding an element these checks never saw.
      def from_list(value)
        return if value.nil?

        unless value.is_a?(Array)
          raise ArgumentError, "icons must be nil or an Array of MCP::Icon or Hash (got #{value.class})."
        end

        icons = value.each_with_index.map do |icon, index|
          from(icon)
        rescue ArgumentError => e
          raise ArgumentError, "icons[#{index}]: #{e.message}"
        end

        icons.freeze
      end
    end

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
