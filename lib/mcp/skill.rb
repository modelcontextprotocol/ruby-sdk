# frozen_string_literal: true

module MCP
  # A skill entry as served by the Skills extension (SEP-2640): the verbatim `SKILL.md`
  # frontmatter plus the complete manifest of the skill's files. `skills/list` returns an
  # array of these and `skills/get` returns one; the shape is identical in both, so a host
  # that paged the listing never needs a follow-up call to complete an entry.
  #
  # The skill format itself (directory layout, frontmatter fields, naming rules, progressive
  # disclosure) belongs to the Agent Skills specification, which this extension delegates to
  # wholesale: https://agentskills.io/specification
  #
  # https://modelcontextprotocol.io/seps/2640-skills-extension
  class Skill
    # Marker taking the place of the `resources` manifest for a skill whose content is generated
    # per request, so no stable digest can be published. Such a skill offers no content integrity
    # and cannot be content-bound; hosts MAY decline to load it.
    DYNAMIC = "dynamic"

    # Every skill URI addresses the skill's `SKILL.md`, never its directory.
    SKILL_FILE = "SKILL.md"

    # Per-skill ceilings every conforming host accepts. Servers SHOULD stay within them; a skill
    # that exceeds either is not guaranteed to be loadable, which is what {#limit_violations} reports.
    MAX_RESOURCES = 512
    MAX_TOTAL_SIZE = 16 * 1024 * 1024

    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze

    # One file of a skill, as it appears in the entry's `resources` manifest.
    class Resource
      attr_reader :uri, :digest, :size

      # @param uri [String] the file's resource URI.
      # @param digest [String] SHA-256 of the file's raw bytes, as `sha256:<64 lowercase hex>`.
      # @param size [Integer] length in bytes of the same raw content the digest covers.
      def initialize(uri:, digest:, size:)
        raise ArgumentError, "Skill resource uri must be a non-empty String" unless uri.is_a?(String) && !uri.empty?

        unless digest.is_a?(String) && DIGEST_PATTERN.match?(digest)
          raise ArgumentError, "Skill resource digest must match sha256:<64 lowercase hex> (got #{digest.inspect})"
        end

        unless size.is_a?(Integer) && size >= 0
          raise ArgumentError, "Skill resource size must be a non-negative Integer (got #{size.inspect})"
        end

        @uri = uri
        @digest = digest
        @size = size
        freeze
      end

      class << self
        # Accepts a {Resource} or the `{uri:, digest:, size:}` Hash shape, with string or symbol keys.
        def from(value)
          return value if value.is_a?(Resource)

          unless value.is_a?(Hash)
            raise ArgumentError, "Skill resources must be #{Resource} or Hash entries (got #{value.class})"
          end

          new(uri: fetch(value, :uri), digest: fetch(value, :digest), size: fetch(value, :size))
        end

        private

        def fetch(hash, key)
          hash.key?(key) ? hash[key] : hash[key.to_s]
        end
      end

      def to_h
        { uri: @uri, digest: @digest, size: @size }
      end
    end

    # `name` repeats the URI's final skill-path segment, so it is recoverable from the URI alone
    # without reading frontmatter; `root` is the skill's root directory, the URI with the
    # `/SKILL.md` suffix removed and no trailing slash.
    attr_reader :uri, :frontmatter, :resources, :name, :root

    # @param uri [String] resource URI of the skill's `SKILL.md`.
    # @param frontmatter [Hash] the `SKILL.md` YAML frontmatter rendered verbatim as a JSON object.
    #   Every field the author wrote, not a curated subset; `name` and `description` are always present.
    # @param resources [Array, String] the skill's complete file manifest, or {DYNAMIC}.
    def initialize(uri:, frontmatter:, resources:)
      @uri = validate_uri!(uri)
      @root = @uri.delete_suffix("/#{SKILL_FILE}")
      @name = self.class.name_from_uri(@uri)
      @frontmatter = validate_frontmatter!(frontmatter)
      @resources = validate_resources!(resources)

      freeze
    end

    def dynamic?
      @resources == DYNAMIC
    end

    # Sum of the manifest's `size` values, the figure {MAX_TOTAL_SIZE} bounds. `nil` for a dynamic
    # skill, whose entry offers nothing to count.
    def total_size
      return if dynamic?

      @resources.sum(&:size)
    end

    # The SEP-2640 limits this skill exceeds, as human-readable strings. Empty for a conforming
    # skill and for a dynamic one, where the ceiling applies to what a host actually retrieves.
    def limit_violations
      return [] if dynamic?

      violations = []
      if @resources.size > MAX_RESOURCES
        violations << "#{@resources.size} resources exceeds the #{MAX_RESOURCES} per-skill limit"
      end
      if total_size > MAX_TOTAL_SIZE
        violations << "#{total_size} bytes exceeds the #{MAX_TOTAL_SIZE} per-skill limit"
      end
      violations
    end

    def to_h
      {
        uri: @uri,
        frontmatter: @frontmatter,
        resources: dynamic? ? DYNAMIC : @resources.map(&:to_h),
      }
    end

    class << self
      # Accepts a {Skill} or the `{uri:, frontmatter:, resources:}` Hash shape, with string or symbol keys.
      def from(value)
        return value if value.is_a?(Skill)

        raise ArgumentError, "Skills must be #{Skill} or Hash entries (got #{value.class})" unless value.is_a?(Hash)

        new(
          uri: fetch(value, :uri),
          frontmatter: fetch(value, :frontmatter),
          resources: fetch(value, :resources),
        )
      end

      # The skill name encoded in a skill URI: the final segment of the skill path, which the
      # extension requires to equal the frontmatter `name`.
      def name_from_uri(uri)
        path = uri.delete_suffix("/#{SKILL_FILE}")
        path = path.split("://", 2).last
        path.split("/").last
      end

      private

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end

    private

    def validate_uri!(uri)
      unless uri.is_a?(String) && uri.end_with?("/#{SKILL_FILE}")
        raise ArgumentError, "Skill uri must be the URI of the skill's #{SKILL_FILE} (got #{uri.inspect})"
      end

      raise ArgumentError, "Skill uri is missing a skill path: #{uri.inspect}" if self.class.name_from_uri(uri).to_s.empty?

      uri
    end

    def validate_frontmatter!(frontmatter)
      raise ArgumentError, "Skill frontmatter must be a Hash (got #{frontmatter.class})" unless frontmatter.is_a?(Hash)

      ["name", "description"].each do |field|
        value = frontmatter.key?(field.to_sym) ? frontmatter[field.to_sym] : frontmatter[field]
        raise ArgumentError, "Skill frontmatter is missing the required #{field.inspect} field" if value.nil?
      end

      declared = frontmatter.key?(:name) ? frontmatter[:name] : frontmatter["name"]
      if declared.to_s != name
        raise ArgumentError,
          "Skill frontmatter name #{declared.inspect} must equal the final segment of the skill path (#{name.inspect})"
      end

      frontmatter
    end

    def validate_resources!(resources)
      return DYNAMIC if resources == DYNAMIC

      unless resources.is_a?(Array)
        raise ArgumentError, "Skill resources must be an Array or #{DYNAMIC.inspect} (got #{resources.inspect})"
      end

      entries = resources.map { |entry| Resource.from(entry) }

      uris = entries.map(&:uri)
      raise ArgumentError, "Skill resources must list #{@uri} itself" unless uris.include?(@uri)

      duplicates = uris.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "Skill resources list #{duplicates.join(", ")} more than once" unless duplicates.empty?

      prefix = "#{root}/"
      outside = uris.reject { |uri| uri == @uri || uri.start_with?(prefix) }
      raise ArgumentError, "Skill resources fall outside #{root}: #{outside.join(", ")}" unless outside.empty?

      entries.freeze
    end
  end
end
