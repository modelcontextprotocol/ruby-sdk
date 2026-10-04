# frozen_string_literal: true

require "digest"
require_relative "skill/resource_entry"
require_relative "skill/frontmatter"
require_relative "skill/directory"

module MCP
  # A skill as the Skills extension describes it (SEP-2640, `io.modelcontextprotocol/skills`): a `skill://`
  # URI naming its `SKILL.md`, the frontmatter of that file kept verbatim, either the list of its files
  # with their digests and sizes or the String `"dynamic"` for content generated per request, and the `_meta`
  # of the entry when it has one, passed through under the JSON rules of the frontmatter with no key acted on
  # (keys of the extension itself use the `io.modelcontextprotocol.skills/` prefix).
  #
  # Every check runs at construction, as `MCP::Icon` does, so a manifest a host may reject fails on
  # the server at definition time: the URI grammar, the frontmatter (`name` and `description`, `name` equal to
  # the last segment of the skill path, JSON-representable values), and the resource entries (under
  # the skill root, unique, the skill's own `SKILL.md` among them). A skill defined locally is also held to
  # the unreserved URI character set, the Agent Skills rules for `name` and `description`, and the SEP limits
  # (512 entries, 16 MiB); entries a client receives from a server are checked structurally only, because
  # a host MUST accept skills up to the limits and MAY accept larger ones, and the Agent Skills guidance for
  # clients is to load a skill whose name breaks a rule anyway. The files of a nested skill, its `SKILL.md`
  # included, are supporting files of the enclosing skill and appear in both manifests, as the specification
  # requires of a complete manifest.
  #
  # Instances are frozen value objects. Equality is identity: the client binds verified state to the exact
  # entry object it checked.
  #
  # https://github.com/modelcontextprotocol/ext-skills/blob/main/specification/stable/skills.mdx
  class Skill
    EXTENSION_ID = "io.modelcontextprotocol/skills"
    # SEP-2640 limits per skill: servers SHOULD NOT serve a skill beyond them, hosts MUST accept up to them.
    MAX_RESOURCES = 512
    MAX_TOTAL_SIZE = 16 * 1024 * 1024
    # The Agent Skills rules SEP-2640 requires of the last segment of a skill path, its `name`: lowercase
    # letters, digits, and single hyphens that neither lead nor trail, 64 characters at most. `description`
    # holds at most 1024 characters.
    NAME_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
    MAX_NAME_LENGTH = 64
    MAX_DESCRIPTION_LENGTH = 1024
    # The `resources` value of a skill whose files are generated per request and carry no digests.
    DYNAMIC = "dynamic"

    # `skill://` URI rules shared by the server and the client. URIs are plain Strings: nothing is decoded,
    # normalized, or joined, and `URI.parse` is never used.
    #
    # @api private
    module Uri
      extend self

      SCHEME = "skill://"
      MANIFEST = "SKILL.md"
      # RFC 3986 unreserved characters, the only ones a locally defined URI may use in a segment.
      LOCAL_SEGMENT = /\A[A-Za-z0-9._~-]+\z/.freeze
      # SDK limits (not protocol rules) on a URI the client resolves against its remembered skills. Resolution
      # considers every ancestor root, so without a bound one read would cost time and memory quadratic in
      # the length of a URI that may come from untrusted model output.
      MAX_RESOLVED_BYTES = 8 * 1024
      MAX_RESOLVED_SEGMENTS = 128

      # Whether `uri` is within the limits above; counts separators instead of splitting, so the check is linear.
      def resolvable?(uri)
        uri.bytesize <= MAX_RESOLVED_BYTES && uri.count("/") <= MAX_RESOLVED_SEGMENTS + 1
      end

      # The path segments of a `skill://` URI, or nil when it is not structurally valid: a String in
      # an ASCII-compatible encoding with at least one segment, none empty, none `.` or `..`.
      def segments(uri)
        return unless uri.is_a?(String) && uri.encoding.ascii_compatible? && uri.start_with?(SCHEME)

        parts = uri[SCHEME.length..-1].split("/", -1)
        return if parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }

        parts
      end

      def structural?(uri)
        !segments(uri).nil?
      end

      # The segments before `SKILL.md`, or nil when the URI does not name a `SKILL.md`.
      def skill_path(uri)
        parts = segments(uri)
        return unless parts && parts.length >= 2 && parts.last == MANIFEST

        parts[0...-1]
      end

      def manifest_uri?(uri)
        !skill_path(uri).nil?
      end

      def local_segments?(parts)
        parts.all? { |part| LOCAL_SEGMENT.match?(part) }
      end

      def root(skill_path)
        "#{SCHEME}#{skill_path.join("/")}"
      end

      # Whether `uri` lies under `root` at a segment boundary: `skill://ab/x` is not under `skill://a`.
      def under?(uri, root)
        uri.start_with?("#{root}/")
      end

      # The `SKILL.md` URIs of every skill whose root could contain `uri`, least specific first; for
      # a `SKILL.md` URI the last candidate is the URI itself.
      def candidate_skill_uris(uri)
        parts = segments(uri)
        return [] unless parts && parts.length >= 2

        directories = parts[0...-1]
        (1..directories.length).map { |count| "#{root(directories.first(count))}/#{MANIFEST}" }
      end
    end

    # JSON-value helpers for frontmatter and capability copies.
    #
    # @api private
    module Json
      extend self

      # The largest integer every JSON reader represents exactly (RFC 7493); beyond it JavaScript loses digits,
      # so two hosts would disagree about one frontmatter.
      MAX_SAFE_INTEGER = (2**53) - 1
      # The default nesting limit of `JSON.parse`, which the SDK's transports apply to a whole message. Restated
      # here so that a value from a transport parsing without one is refused instead of exhausting the stack.
      MAX_DEPTH = 100

      # A deep copy with String keys holding only JSON-representable values (String that JSON can encode, Integer within
      # the safe range, finite Float, true, false, nil, Array, Hash); refuses cycles, nesting beyond `MAX_DEPTH`, and keys
      # that collide once stringified.
      def normalize(value, path = {}.compare_by_identity)
        case value
        when String then normalize_string(value)
        when TrueClass, FalseClass, NilClass then value
        when Integer
          raise ArgumentError, "must hold integers within 2**53" unless value.abs <= MAX_SAFE_INTEGER

          value
        when Float
          raise ArgumentError, "must hold finite numbers" unless value.finite?

          value
        when Array
          raise ArgumentError, "must not be cyclic" if path.key?(value)

          refuse_depth!(path.size)
          path[value] = true
          result = value.map { |member| normalize(member, path) }
          path.delete(value)
          result
        when Hash
          raise ArgumentError, "must not be cyclic" if path.key?(value)

          refuse_depth!(path.size)
          path[value] = true
          result = {}
          value.each do |key, member|
            name = case key
            when String then normalize_string(key)
            when Symbol then normalize_string(key.to_s)
            else raise ArgumentError, "keys must be Strings or Symbols (got #{key.class})"
            end
            raise ArgumentError, "keys collide after stringification (#{name.dump})" if result.key?(name)

            result[name] = normalize(member, path)
          end
          path.delete(value)
          result
        else
          raise ArgumentError, "must be JSON-representable (got #{value.class})"
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |member| deep_freeze(member) }
        when Array
          value.each { |member| deep_freeze(member) }
        end
        value.freeze
      end

      # A deep copy of a value a transport returned; refuses nesting beyond `MAX_DEPTH` with an `ArgumentError`.
      def deep_dup(value, depth = 0)
        case value
        when Hash
          refuse_depth!(depth)
          value.each_with_object({}) { |(key, member), copy| copy[deep_dup(key, depth + 1)] = deep_dup(member, depth + 1) }
        when Array
          refuse_depth!(depth)
          value.map { |member| deep_dup(member, depth + 1) }
        when String then value.dup
        else value
        end
      end

      # Structural equality with Integer and Float kept distinct, Hash keys compared as sets, and Arrays in order.
      def equal?(expected, actual)
        case expected
        when Hash
          return false unless actual.is_a?(Hash) && expected.size == actual.size

          expected.all? { |key, member| actual.key?(key) && equal?(member, actual[key]) }
        when Array
          return false unless actual.is_a?(Array) && expected.size == actual.size

          expected.each_with_index.all? { |member, index| equal?(member, actual[index]) }
        when Float
          actual.is_a?(Float) && (expected == actual || (expected.nan? && actual.nan?))
        when Integer
          actual.is_a?(Integer) && expected == actual
        else
          expected.class.equal?(actual.class) && expected == actual
        end
      end

      private

      def refuse_depth!(depth)
        raise ArgumentError, "must not nest deeper than #{MAX_DEPTH} levels" if depth >= MAX_DEPTH
      end

      def normalize_string(value)
        raise ArgumentError, "must hold strings JSON can encode" unless utf8_encodable?(value)

        value.dup
      end

      # JSON carries UTF-8. `encode` hands a String already labeled UTF-8 back unchecked, so that case asks
      # `valid_encoding?` instead; a binary String with a byte beyond ASCII fails the conversion.
      def utf8_encodable?(value)
        return value.valid_encoding? if value.encoding == Encoding::UTF_8

        value.encode(Encoding::UTF_8)
        true
      rescue EncodingError
        false
      end
    end

    private_constant :Frontmatter

    class << self
      # The `capabilities.extensions` fragment advertising the extension, for a hand-built
      # `MCP::Server::Capabilities`; a server configured with `skills:` adds it itself.
      def capability
        { EXTENSION_ID => {} }
      end

      # Builds a skill from an entry a server returned (String or Symbol keys), under the structural rules only.
      #
      # @api private
      def from_entry(entry)
        raise ArgumentError, "A skill entry must be a Hash (got #{entry.class})." unless entry.is_a?(Hash)

        skill = allocate
        skill.__send__(
          :initialize_members,
          read_key(entry, "uri"),
          read_key(entry, "frontmatter"),
          read_key(entry, "resources"),
          meta: read_key(entry, "_meta"),
          local: false,
          file_records: nil,
        )
        skill
      end

      # Builds a locally defined skill that also carries the records `from_directory` serves files from.
      #
      # @api private
      def with_file_records(uri:, frontmatter:, resources:, file_records:, meta: nil)
        skill = allocate
        skill.__send__(:initialize_members, uri, frontmatter, resources, meta: meta, local: true, file_records: file_records)
        skill
      end

      # Checks fetched bytes against the entry for `uri` in `skill`'s manifest (size, then SHA-256), for hosts
      # that read skill files through `MCP::Client#read_resource` rather than `#read_skill_resource`. Pass
      # exactly the bytes received: `text.b` for a `text` item, the decoded `blob` otherwise. Raises
      # `MCP::Client::SkillReadRefusedError` when the skill is dynamic or does not list `uri`, and
      # `MCP::Client::SkillVerificationError` on a mismatch. Does not compare frontmatter: a `SKILL.md`
      # also needs `verify_frontmatter`.
      def verify_resource(skill, uri, bytes)
        check_skill_and_uri!(skill, uri)
        raise ArgumentError, "The value of bytes must be a String (got #{bytes.class})." unless bytes.is_a?(String)

        if skill.dynamic?
          raise Client::SkillReadRefusedError.new(
            "Skill #{skill.uri.dump} is dynamic and lists no digests to verify #{uri.dump} against",
            reason: :dynamic, uri: uri, skill_uri: skill.uri,
          )
        end

        entry = skill.resources.find { |candidate| candidate.uri == uri }
        unless entry
          raise Client::SkillReadRefusedError.new(
            "Resource #{uri.dump} is not listed by #{skill.uri.dump}",
            reason: :not_in_manifest, uri: uri, skill_uri: skill.uri,
          )
        end

        unless bytes.bytesize == entry.size
          raise Client::SkillVerificationError.new(
            "Resource #{uri.dump} does not have the size listed by #{skill.uri.dump}",
            uri: uri, skill_uri: skill.uri, reason: :size,
          )
        end

        unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == entry.digest
          raise Client::SkillVerificationError.new(
            "Resource #{uri.dump} does not have the digest listed by #{skill.uri.dump}",
            uri: uri, skill_uri: skill.uri, reason: :digest,
          )
        end

        true
      end

      # Compares the frontmatter of a fetched `SKILL.md` (its text) with `skill`'s entry field by field,
      # the host-side MUST of SEP-2640, which `verify_resource` does not cover. Raises
      # `MCP::Client::SkillVerificationError` with reason `:parse` or `:frontmatter`.
      def verify_frontmatter(skill, text)
        raise ArgumentError, "The value of skill must be an MCP::Skill (got #{skill.class})." unless skill.is_a?(Skill)
        raise ArgumentError, "The value of text must be a String (got #{text.class})." unless text.is_a?(String)

        actual = begin
          Frontmatter.load(text)
        rescue Frontmatter::Error => e
          raise Client::SkillVerificationError.new(
            "The frontmatter of #{skill.uri.dump} cannot be read",
            uri: skill.uri, skill_uri: skill.uri, reason: e.reason,
          )
        end

        unless Json.equal?(skill.frontmatter, actual)
          raise Client::SkillVerificationError.new(
            "The frontmatter of #{skill.uri.dump} differs from its entry",
            uri: skill.uri, skill_uri: skill.uri, reason: :frontmatter,
          )
        end

        true
      end

      # The file records of directory-backed skills keyed by URI, for the server's default resource reader.
      # A nested skill and its enclosing skill share the records of the nested files, so the same record
      # under the same URI is fine; two different records for one URI are not.
      #
      # @api private
      def file_map(skills)
        map = {}
        skills.each do |skill|
          records = skill.__send__(:file_records)
          next unless records

          records.each do |uri, record|
            existing = map[uri]
            next if existing == record
            raise ArgumentError, "The skill file #{uri} is served by more than one skill from different files." if existing

            map[uri] = record
          end
        end
        map.freeze
      end

      # The roots (`skill://<path>`) of the directory-backed skills among `skills`, for the server to tell
      # a read of an unserved file under one of them from an ordinary unknown resource.
      #
      # @api private
      def file_roots(skills)
        skills.select { |skill| skill.__send__(:file_records) }.map { |skill| Uri.root(skill.skill_path) }.uniq.freeze
      end

      private

      def read_key(hash, key)
        value = hash[key]
        value.nil? ? hash[key.to_sym] : value
      end

      def check_skill_and_uri!(skill, uri)
        raise ArgumentError, "The value of skill must be an MCP::Skill (got #{skill.class})." unless skill.is_a?(Skill)
        raise ArgumentError, "The value of uri must be a String (got #{uri.class})." unless uri.is_a?(String)
      end
    end

    attr_reader :uri, :skill_path, :name, :frontmatter, :resources

    # The `_meta` of the entry as a frozen Hash with String keys, or nil when the entry carries none.
    attr_reader :meta

    def initialize(uri:, frontmatter:, resources:, meta: nil)
      initialize_members(uri, frontmatter, resources, meta: meta, local: true, file_records: nil)
    end

    def dynamic?
      @resources == DYNAMIC
    end

    # The sum of the listed sizes, or nil for a dynamic skill; the hook for a host that declines large skills.
    def total_size
      @total_size
    end

    def to_h
      entry = { uri: uri, frontmatter: frontmatter, resources: dynamic? ? DYNAMIC : resources.map(&:to_h) }
      entry[:_meta] = meta if meta
      entry
    end

    private

    def file_records
      @file_records
    end

    def initialize_members(uri, frontmatter, resources, meta:, local:, file_records:)
      path = Uri.skill_path(uri)
      unless path
        raise ArgumentError, "The value of uri must be a skill://<path>/SKILL.md URI with non-empty path segments."
      end
      if local && !Uri.local_segments?(path)
        raise ArgumentError, "The value of uri may only use letters, digits, -, ., _, and ~ in its segments."
      end

      normalized = begin
        Json.normalize(frontmatter)
      rescue ArgumentError => e
        raise ArgumentError, "The value of frontmatter #{e.message}."
      end
      unless normalized.is_a?(Hash)
        raise ArgumentError, "The value of frontmatter must be a Hash (got #{frontmatter.class})."
      end
      ["name", "description"].each do |field|
        unless normalized[field].is_a?(String) && !normalized[field].empty?
          raise ArgumentError, "The value of frontmatter must hold a non-empty String under #{field}."
        end
      end
      unless normalized["name"] == path.last
        raise ArgumentError, "The frontmatter name must equal the last segment of the skill path."
      end
      check_agent_skills_rules!(normalized) if local

      @uri = -uri
      @skill_path = path.map { |segment| -segment }.freeze
      @frontmatter = Json.deep_freeze(normalized)
      @name = @frontmatter["name"]
      @resources = normalize_resources(resources, local)
      @total_size = dynamic? ? nil : @resources.sum(&:size)
      @meta = normalize_meta(meta)
      @file_records = file_records
      freeze
    end

    # The length is looked at first, so the pattern never runs over a long name.
    def check_agent_skills_rules!(frontmatter)
      name = frontmatter["name"]
      unless name.length <= MAX_NAME_LENGTH && NAME_PATTERN.match?(name)
        raise ArgumentError, "The frontmatter name must be 1 to #{MAX_NAME_LENGTH} lowercase letters, digits, " \
          "and single hyphens between them."
      end
      return if frontmatter["description"].length <= MAX_DESCRIPTION_LENGTH

      raise ArgumentError, "The frontmatter description must hold at most #{MAX_DESCRIPTION_LENGTH} characters."
    end

    def normalize_meta(meta)
      return if meta.nil?

      normalized = begin
        Json.normalize(meta)
      rescue ArgumentError => e
        raise ArgumentError, "The value of meta #{e.message}."
      end
      raise ArgumentError, "The value of meta must be a Hash (got #{meta.class})." unless normalized.is_a?(Hash)

      Json.deep_freeze(normalized)
    end

    def normalize_resources(resources, local)
      return DYNAMIC if resources == DYNAMIC

      unless resources.is_a?(Array)
        raise ArgumentError, "The value of resources must be \"dynamic\" or an Array of entries (got #{resources.class})."
      end

      root = Uri.root(@skill_path)
      seen = {}
      entries = resources.each_with_index.map do |value, index|
        entry = begin
          # A remote entry may carry members this SDK does not know; a local definition may not.
          local ? ResourceEntry.from(value) : ResourceEntry.from_wire(value)
        rescue ArgumentError => e
          raise ArgumentError, "resources[#{index}]: #{e.message}"
        end
        raise ArgumentError, "resources[#{index}]: The entry uri must lie under #{root.dump}." unless Uri.under?(entry.uri, root)
        if local && !Uri.local_segments?(Uri.segments(entry.uri))
          raise ArgumentError, "resources[#{index}]: The entry uri may only use letters, digits, -, ., _, and ~ in its segments."
        end
        raise ArgumentError, "resources[#{index}]: The entry uri is listed twice." if seen.key?(entry.uri)

        seen[entry.uri] = true
        entry
      end
      raise ArgumentError, "The value of resources must list the skill's own SKILL.md." unless seen.key?(@uri)

      if local
        raise ArgumentError, "The value of resources must hold at most #{MAX_RESOURCES} entries." if entries.size > MAX_RESOURCES
        if entries.sum(&:size) > MAX_TOTAL_SIZE
          raise ArgumentError, "The value of resources must list at most #{MAX_TOTAL_SIZE} bytes in total."
        end
      end

      entries.freeze
    end
  end
end
