# frozen_string_literal: true

module MCP
  class Client
    # Base class of the errors the Skills extension (SEP-2640) raises on the client side, so a host can
    # rescue all of them at once. Messages carry request and skill URIs only, never content.
    class SkillError < StandardError; end

    # A `skills/list` or `skills/get` result the server returned is not a conformant skill entry
    # (wrong shape, a malformed digest, a resource outside the skill root, a duplicate URI within one page,
    # or a `skills/get` result for another URI). Nothing is remembered from such a result.
    class SkillEntryError < SkillError; end

    # The content a `resources/read` returned does not match the skill's manifest: `reason` is one of
    # `:contents` (not exactly one item for the requested URI with exactly one of `text` or `blob`,
    # an undecodable `blob`, or an item nested too deeply to copy), `:size`, `:digest`, `:parse` (the `SKILL.md`
    # frontmatter cannot be read), or `:frontmatter` (it differs from the entry). The skill is latched for
    # the life of the connection.
    class SkillVerificationError < SkillError
      attr_reader :uri, :skill_uri, :reason

      def initialize(message, uri:, skill_uri:, reason:)
        super(message)
        @uri = uri
        @skill_uri = skill_uri
        @reason = reason
      end
    end

    # A Skills call was refused before it was sent, or its completion was discarded because the connection
    # changed. `reason` is one of `:not_advertised`, `:connection_changed`, `:latched`, `:unknown_skill`,
    # `:dynamic`, `:not_in_manifest`, or `:skill_md_unverified`; later releases may add reasons, so treat
    # an unknown one as a refusal too. Nothing is latched by a refusal.
    class SkillReadRefusedError < SkillError
      attr_reader :uri, :skill_uri, :reason

      def initialize(message, reason:, uri: nil, skill_uri: nil)
        super(message)
        @reason = reason
        @uri = uri
        @skill_uri = skill_uri
      end
    end
  end
end
