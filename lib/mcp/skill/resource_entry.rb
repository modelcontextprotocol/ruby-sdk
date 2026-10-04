# frozen_string_literal: true

require "digest"

module MCP
  class Skill
    # One file of a skill as its manifest lists it: `{ uri, digest, size }` (SEP-2640). The `digest` is
    # `sha256:` followed by 64 lowercase hex characters over the file's raw bytes, `size` is the byte length.
    # Only the shape is checked here; whether the URI lies under the skill's root is checked by `MCP::Skill`,
    # which knows the root.
    class ResourceEntry
      DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze

      # The keys `from` accepts in a Hash, as Symbols or Strings.
      HASH_KEYWORDS = { "uri" => :uri, "digest" => :digest, "size" => :size }.freeze
      private_constant :HASH_KEYWORDS

      class << self
        # Returns `value` when it is already a `ResourceEntry`, builds one from a Hash, and refuses anything else.
        def from(value)
          return value if value.is_a?(ResourceEntry)

          unless value.is_a?(Hash)
            raise ArgumentError, "A skill resource entry must be an MCP::Skill::ResourceEntry or a Hash (got #{value.class})."
          end

          keywords = {}
          value.each do |key, member|
            unless key.is_a?(Symbol) || key.is_a?(String)
              raise ArgumentError, "A skill resource entry Hash key must be a Symbol or a String (got #{key.class})."
            end

            keyword = HASH_KEYWORDS[key.to_s]
            unless keyword
              raise ArgumentError, "A skill resource entry Hash may only hold uri, digest, and size (got #{key.inspect})."
            end
            raise ArgumentError, "A skill resource entry Hash gives #{keyword} twice." if keywords.key?(keyword)

            keywords[keyword] = member
          end

          new(**keywords)
        end

        # Builds an entry from a server's wire Hash (String or Symbol keys), reading `uri`, `digest`, and `size` and
        # ignoring any other member a server may add; `from` refuses unknown members for local definitions instead.
        #
        # @api private
        def from_wire(value)
          return value if value.is_a?(ResourceEntry)
          raise ArgumentError, "A skill resource entry must be a Hash (got #{value.class})." unless value.is_a?(Hash)

          new(uri: wire_member(value, "uri"), digest: wire_member(value, "digest"), size: wire_member(value, "size"))
        end

        # Builds the entry for a file from the exact bytes the resource will serve, so an author never formats
        # a digest by hand: pass `File.binread` output for a binary file and UTF-8 text for a text file.
        def from_content(uri:, content:)
          unless content.is_a?(String)
            raise ArgumentError, "The value of content must be a String (got #{content.class})."
          end

          new(uri: uri, digest: "sha256:#{Digest::SHA256.hexdigest(content.b)}", size: content.bytesize)
        end

        private

        def wire_member(hash, key)
          value = hash[key]
          value.nil? ? hash[key.to_sym] : value
        end
      end

      attr_reader :uri, :digest, :size

      def initialize(uri:, digest:, size:)
        unless uri.is_a?(String) && Uri.structural?(uri)
          raise ArgumentError, "The value of uri must be a skill:// URI with non-empty path segments."
        end

        unless digest.is_a?(String) && digest.encoding.ascii_compatible? && DIGEST_PATTERN.match?(digest)
          raise ArgumentError, "The value of digest must be sha256: followed by 64 lowercase hex characters."
        end

        unless size.is_a?(Integer) && size >= 0
          raise ArgumentError, "The value of size must be a non-negative Integer (got #{size.class})."
        end

        @uri = -uri
        @digest = -digest
        @size = size
        freeze
      end

      def to_h
        { uri: uri, digest: digest, size: size }
      end

      def ==(other)
        other.is_a?(ResourceEntry) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash
        to_h.hash
      end
    end
  end
end
