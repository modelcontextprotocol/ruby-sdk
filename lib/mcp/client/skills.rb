# frozen_string_literal: true

require "set"
require "digest"

module MCP
  class Client
    # One page of `skills/list`: `skills` is a frozen Array of `MCP::Skill`; `next_cursor`, `meta`, `ttl_ms`, and
    # `cache_scope` mirror the response members. Frozen on construction.
    ListSkillsResult = Struct.new(:skills, :next_cursor, :meta, :ttl_ms, :cache_scope, keyword_init: true) do
      def initialize(**kwargs)
        super(**kwargs)
        freeze
      end
    end

    # The entry `skills/get` returned for exactly the requested URI. Frozen on construction.
    GetSkillResult = Struct.new(:skill, :meta, :ttl_ms, :cache_scope, keyword_init: true) do
      def initialize(**kwargs)
        super(**kwargs)
        freeze
      end
    end

    # A skill file read and verified by `read_skill_resource`: `bytes` is the verified content as a frozen
    # binary-encoded String (the decoded `blob`, or the bytes of the `text`), `mime_type` is the server's
    # unverified display metadata (never a reason to pick an interpreter), `contents` is the raw frozen
    # `contents` Array, `skill` is the entry object the content was checked against, and `verified` is true:
    # the digest, size, and (for a `SKILL.md`) frontmatter matched. Every value is independent of the objects
    # it was built from, so mutating a source cannot change the result.
    SkillReadResult = Struct.new(:uri, :bytes, :mime_type, :contents, :skill, :verified, keyword_init: true) do
      def initialize(**kwargs)
        super(**kwargs)
        freeze
      end
    end

    # Client side of the Skills extension (SEP-2640), mixed into `MCP::Client`: `list_skills`, `get_skill`,
    # `read_skill_resource`, and `skills_capability`.
    #
    # Every call is admitted only after a handshake of the current connection advertised both the extension and
    # `resources`, as the SEP asks of clients. Entries the server returned are remembered per client instance,
    # bound to the connection: `connect` starts a new generation and forgets them. `read_skill_resource` checks
    # the content against the entry it resolved (size, SHA-256, and the frontmatter of a `SKILL.md`), withholds
    # content that does not match, and latches the skill so that no later read of it is sent on this connection,
    # which is what keeps a host from loading part of a tampered skill. `read_resource` stays the raw,
    # unverified way to fetch a skill file; `MCP::Skill.verify_resource` and `MCP::Skill.verify_frontmatter`
    # exist for hosts that go that way and then own the latching and ordering obligations themselves.
    module Skills
      # Fetches one page of the skills the server serves.
      #
      # @raise [SkillReadRefusedError] `:not_advertised` before any request is sent, `:connection_changed` when
      #   `connect` ran while the request was in flight (the page is discarded).
      # @raise [SkillEntryError] When the page is not a conformant `skills/list` result.
      def list_skills(cursor: nil, meta: nil, cancellation: nil)
        generation = @skills_state.admit(connected: connected?)
        params = cursor ? { cursor: cursor } : nil
        response = request(method: Methods::SKILLS_LIST, params: params, meta: meta, cancellation: cancellation)
        @skills_state.ensure_current!(generation)

        result = response.is_a?(Hash) ? response["result"] : nil
        raise SkillEntryError, "Response validation failed: missing or invalid `result`" unless result.is_a?(Hash)

        entries = result["skills"]
        raise SkillEntryError, "Response validation failed: `skills` is not an Array" unless entries.is_a?(Array)

        skills = entries.map { |entry| parse_skill_entry(entry) }
        uris = skills.map(&:uri)
        raise SkillEntryError, "Response validation failed: a skill URI is listed twice in one page" unless uris.uniq.size == uris.size

        @skills_state.install(generation, skills)
        ListSkillsResult.new(
          skills: skills.freeze,
          next_cursor: result["nextCursor"],
          meta: result["_meta"],
          ttl_ms: result["ttlMs"],
          cache_scope: result["cacheScope"],
        )
      end

      # Fetches the entry of one skill by the URI of its `SKILL.md`, listed or not.
      #
      # @raise [SkillReadRefusedError] `:not_advertised` or `:connection_changed`, as for `list_skills`.
      # @raise [SkillEntryError] When the result is not a conformant entry for exactly `uri`.
      def get_skill(uri:, meta: nil, cancellation: nil)
        check_skill_uri!(uri)

        generation = @skills_state.admit(connected: connected?)
        response = request(method: Methods::SKILLS_GET, params: { uri: uri }, meta: meta, cancellation: cancellation)
        @skills_state.ensure_current!(generation)

        result = response.is_a?(Hash) ? response["result"] : nil
        raise SkillEntryError, "Response validation failed: missing or invalid `result`" unless result.is_a?(Hash)

        skill = parse_skill_entry(result["skill"])
        raise SkillEntryError, "Response validation failed: skills/get answered for #{skill.uri.dump} instead of #{uri.dump}" unless skill.uri == uri

        @skills_state.install(generation, [skill])
        GetSkillResult.new(skill: skill, meta: result["_meta"], ttl_ms: result["ttlMs"], cache_scope: result["cacheScope"])
      end

      # Reads one file of a skill through `resources/read` and verifies it against the skill's entry before
      # returning it. The entry is `skill:` when given (for this read only), else the most specific remembered
      # skill that contains `uri`, never an enclosing one: when an enclosing skill lists `uri` as well the read is
      # refused as `:ambiguous`, since only the host knows which skill it is acting on, and a `SKILL.md` URI
      # resolves only to its own entry. A supporting file is read only after the skill's `SKILL.md` verified on
      # this instance.
      #
      # @raise [SkillReadRefusedError] Before anything is sent: `:not_advertised`, `:latched`, `:unknown_skill` (also
      #   for a URI longer than 8 KiB or deeper than 128 segments, an SDK limit), `:ambiguous` (an enclosing
      #   remembered skill lists `uri` too; pass `skill:` for the skill being acted on), `:dynamic` (no digests; use
      #   `read_resource` with `MCP::Skill.verify_frontmatter`), `:not_in_manifest`, `:skill_md_unverified`; on
      #   completion, `:connection_changed` or `:latched`.
      # @raise [SkillVerificationError] When the content does not match; the skill is latched for the connection.
      def read_skill_resource(uri:, skill: nil, meta: nil, cancellation: nil)
        check_skill_uri!(uri)
        raise ArgumentError, "The value of skill must be an MCP::Skill or nil (got #{skill.class})." unless skill.nil? || skill.is_a?(Skill)

        # A frozen copy, so a caller mutating its String during the read cannot change the URI that was verified.
        uri = -uri
        unless Skill::Uri.resolvable?(uri)
          # Refused before the ancestor roots are computed, which would cost time and memory quadratic in
          # the length of a URI that may come from model output; the message leaves the URI out for that reason.
          @skills_state.admit(connected: connected?)
          raise SkillReadRefusedError.new(
            "Skills call refused (unknown_skill): the URI is longer than #{Skill::Uri::MAX_RESOLVED_BYTES} bytes or deeper " \
              "than #{Skill::Uri::MAX_RESOLVED_SEGMENTS} segments, beyond what the client resolves",
            reason: :unknown_skill,
            uri: uri,
          )
        end

        candidates = Skill::Uri.candidate_skill_uris(uri)
        generation, entry, resource_entry = @skills_state.admit_read(uri, candidates, skill, connected: connected?)
        response = request(method: Methods::RESOURCES_READ, params: { uri: uri }, meta: meta, cancellation: cancellation)
        outcome = verify_skill_contents(entry, resource_entry, uri, response)
        bytes, mime_type, contents = @skills_state.complete_read(generation, uri, candidates, entry, explicit: !skill.nil?, outcome: outcome)

        SkillReadResult.new(uri: uri, bytes: bytes, mime_type: mime_type, contents: contents, skill: entry, verified: true)
      end

      # The Skills settings the current connection's handshake advertised, as a frozen Hash, or nil when
      # a Skills call would be refused with `:not_advertised`: not ready, not connected, or not advertised.
      # nil never means "read skill files raw instead".
      def skills_capability
        @skills_state.skills_capability(connected: connected?)
      end

      private

      def check_skill_uri!(uri)
        raise ArgumentError, "The value of uri must be a String (got #{uri.class})." unless uri.is_a?(String)
        return if uri.valid_encoding? && uri.encoding.ascii_compatible?

        raise ArgumentError, "The value of uri must be validly encoded in an ASCII-compatible encoding."
      end

      def parse_skill_entry(entry)
        Skill.from_entry(entry)
      rescue ArgumentError => e
        raise SkillEntryError, "Skill entry rejected: #{e.message}"
      end

      # Pure verification, run outside the state lock: exactly one content item for `uri` with exactly one of
      # `text` or `blob`, the size before decoding, the digest, and for the skill's own `SKILL.md` the frontmatter.
      # Returns `[:ok, bytes, mime_type, contents]` or `[:failed, error]`.
      def verify_skill_contents(entry, resource_entry, uri, response)
        result = response.is_a?(Hash) ? response["result"] : nil
        contents = result.is_a?(Hash) ? result["contents"] : nil
        item = contents.is_a?(Array) && contents.size == 1 ? contents.first : nil
        unless item.is_a?(Hash) && item["uri"] == uri
          return skill_verification_failure(:contents, uri, entry, "did not come back as exactly one content item")
        end

        text = item["text"]
        blob = item["blob"]
        unless (text.is_a?(String) && blob.nil?) || (blob.is_a?(String) && text.nil?)
          return skill_verification_failure(:contents, uri, entry, "did not carry exactly one of text or blob")
        end

        expected_size = resource_entry.size
        if text
          bytes = text.b
          return skill_verification_failure(:size, uri, entry, "has a different size than listed") unless bytes.bytesize == expected_size
        else
          # Checked before decoding so the manifest's size bounds the work: this is the base64 length of exactly `size` bytes.
          return skill_verification_failure(:size, uri, entry, "has a different size than listed") unless blob.length <= ((expected_size + 2) / 3) * 4

          bytes = begin
            blob.unpack1("m0")
          rescue ArgumentError
            return skill_verification_failure(:contents, uri, entry, "did not carry valid base64")
          end
          return skill_verification_failure(:size, uri, entry, "has a different size than listed") unless bytes.bytesize == expected_size
        end

        unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == resource_entry.digest
          return skill_verification_failure(:digest, uri, entry, "has a different digest than listed")
        end

        if uri == entry.uri
          begin
            Skill.verify_frontmatter(entry, bytes.dup.force_encoding(Encoding::UTF_8))
          rescue SkillVerificationError => e
            return [:failed, e]
          end
        end

        copy = begin
          Skill::Json.deep_freeze(Skill::Json.deep_dup(contents))
        rescue ArgumentError
          return skill_verification_failure(:contents, uri, entry, "came back nested too deeply to be the file listed")
        end

        mime_type = item["mimeType"]
        [:ok, bytes.freeze, mime_type.is_a?(String) ? mime_type.dup.freeze : nil, copy]
      end

      def skill_verification_failure(reason, uri, entry, detail)
        # URIs a server chose are shown with `dump`, which escapes everything outside printable ASCII (`inspect`
        # leaves bidirectional overrides as they are), so they cannot forge or reorder lines in a host's log.
        message = "Resource #{uri.dump} #{detail} by #{entry.uri.dump}"
        [:failed, SkillVerificationError.new(message, uri: uri, skill_uri: entry.uri, reason: reason)]
      end

      # Per-instance Skills state, bound to the connection. Every public method takes the one Mutex and none of
      # them calls another inside it (Ruby's Mutex is not reentrant); hashing, decoding, and parsing happen
      # outside, in the client methods above. No lock is ever held across I/O.
      class State
        def initialize
          @mutex = Mutex.new
          @generation = 0
          @ready = false
          @recorded = nil
          @index = {}
          @verified = {}.compare_by_identity
          @latched = Set.new
        end

        # A new connection is about to be established: forget everything and return the new generation.
        def begin_handshake
          @mutex.synchronize do
            @generation += 1
            @ready = false
            @recorded = nil
            @index = {}
            @verified = {}.compare_by_identity
            @latched = Set.new
            @generation
          end
        end

        # The handshake that started `generation` completed with `result`, the wire Hash `transport.connect`
        # returned; records a frozen copy of its capabilities, unless a newer handshake started meanwhile.
        # Capabilities nested too deeply to copy are recorded as none, so `connect` succeeds as it does without
        # Skills and every Skills call is refused.
        def handshake_completed(generation, result)
          capabilities = read_key(result, "capabilities")
          copy = begin
            capabilities.is_a?(Hash) ? Skill::Json.deep_freeze(Skill::Json.deep_dup(capabilities)) : nil
          rescue ArgumentError
            nil
          end
          @mutex.synchronize do
            next unless generation == @generation

            @ready = true
            @recorded = copy
          end
        end

        # The handshake that started `generation` raised; a stale failure changes nothing.
        def handshake_failed(generation)
          @mutex.synchronize do
            next unless generation == @generation

            @ready = false
            @recorded = nil
          end
        end

        def ready?
          @mutex.synchronize { @ready }
        end

        def admit(connected:)
          @mutex.synchronize do
            admit_or_refuse!(connected)
            @generation
          end
        end

        def ensure_current!(generation)
          @mutex.synchronize do
            refuse!(:connection_changed, nil, nil, "the connection changed while the request was in flight") unless generation == @generation
          end
        end

        # Resolves and checks a read before it is sent; returns the generation, the entry, and its resource entry.
        def admit_read(uri, candidates, explicit, connected:)
          @mutex.synchronize do
            admit_or_refuse!(connected)
            latched = candidates.find { |candidate| @latched.include?(candidate) }
            refuse!(:latched, uri, latched, "#{latched.dump} failed verification on this connection") if latched

            entry = resolve_entry(uri, candidates, explicit)
            refuse!(:dynamic, uri, entry.uri, "#{entry.uri.dump} is dynamic and lists no digests") if entry.dynamic?

            resource_entry = entry.resources.find { |candidate| candidate.uri == uri }
            refuse!(:not_in_manifest, uri, entry.uri, "#{uri.dump} is not listed by #{entry.uri.dump}") unless resource_entry
            if uri != entry.uri && !@verified.key?(entry)
              refuse!(:skill_md_unverified, uri, entry.uri, "#{entry.uri.dump} has not been read and verified on this connection yet")
            end

            [@generation, entry, resource_entry]
          end
        end

        # Remembers entries a catalog call returned; a replaced entry object loses its verified status.
        def install(generation, skills)
          @mutex.synchronize do
            refuse!(:connection_changed, nil, nil, "the connection changed while the request was in flight") unless generation == @generation

            skills.each do |skill|
              previous = @index[skill.uri]
              @verified.delete(previous) if previous && !previous.equal?(skill)
              @index[skill.uri] = skill
            end
          end
        end

        # Settles a read: discards a stale or newly latched completion, latches the skill on a failure, and
        # grants the entry object verified status after its own `SKILL.md` verified (an automatic read only
        # while the object is still current; an explicit read for the object the caller supplied).
        def complete_read(generation, uri, candidates, entry, explicit:, outcome:)
          @mutex.synchronize do
            refuse!(:connection_changed, uri, entry.uri, "the connection changed while the request was in flight") unless generation == @generation
            latched = candidates.find { |candidate| @latched.include?(candidate) }
            refuse!(:latched, uri, latched, "#{latched.dump} failed verification on this connection") if latched

            status, *values = outcome
            if status == :failed
              @latched << entry.uri
              raise values.first
            end

            if uri == entry.uri && (explicit || @index[entry.uri].equal?(entry))
              @verified[entry] = true
            end
            values
          end
        end

        def skills_capability(connected:)
          @mutex.synchronize do
            next unless admitted?(connected)

            read_key(read_key(@recorded, "extensions"), Skill::EXTENSION_ID)
          end
        end

        private

        def admit_or_refuse!(connected)
          return if admitted?(connected)

          refuse!(:not_advertised, nil, nil, "no handshake of this connection advertised the skills extension and resources")
        end

        def admitted?(connected)
          return false unless @ready && connected && @recorded.is_a?(Hash)

          settings = read_key(read_key(@recorded, "extensions"), Skill::EXTENSION_ID)
          settings.is_a?(Hash) && read_key(@recorded, "resources").is_a?(Hash)
        end

        def resolve_entry(uri, candidates, explicit)
          if explicit
            if Skill::Uri.manifest_uri?(uri) && uri != explicit.uri
              refuse!(:unknown_skill, uri, explicit.uri, "a SKILL.md URI resolves only to its own skill")
            end
            return explicit
          end

          if Skill::Uri.manifest_uri?(uri)
            entry = @index[uri]
            refuse!(:unknown_skill, uri, nil, "#{uri.dump} has not been listed or fetched on this connection; pass skill: or call get_skill") unless entry
            return entry
          end

          remembered = candidates.reverse_each.map { |candidate| @index[candidate] }.compact
          refuse!(:unknown_skill, uri, nil, "no remembered skill contains #{uri.dump}; pass skill: or call get_skill") if remembered.empty?

          # Only the most specific remembered skill containing `uri` is resolved automatically. The specification
          # resolves a read against the entry the host loaded the skill from, and only the host knows which skill
          # it is acting on, so an enclosing skill that lists the file (it lists its nested skills' files too) is
          # reached with `skill:` alone: never because the nested entry is dynamic or leaves the file out.
          entry = remembered.first
          return entry if entry.dynamic?

          enclosing = remembered.drop(1).select do |candidate|
            !candidate.dynamic? && candidate.resources.any? { |resource| resource.uri == uri }
          end
          unless enclosing.empty?
            refuse!(
              :ambiguous,
              uri,
              entry.uri,
              "#{uri.dump} is also listed by #{enclosing.map { |candidate| candidate.uri.dump }.join(" and ")}; " \
                "pass skill: for the skill being acted on",
            )
          end

          entry
        end

        def read_key(hash, key)
          return unless hash.is_a?(Hash)

          value = hash[key]
          value.nil? ? hash[key.to_sym] : value
        end

        def refuse!(reason, uri, skill_uri, detail)
          raise SkillReadRefusedError.new("Skills call refused (#{reason}): #{detail}", reason: reason, uri: uri, skill_uri: skill_uri)
        end
      end
    end
  end
end
