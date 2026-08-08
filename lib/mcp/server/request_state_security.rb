# frozen_string_literal: true

require "json"
require "openssl"

module MCP
  class Server
    # Opt-in protection for the SEP-2322 `requestState` echo. The opaque continuation string leaves the server,
    # sits in the client's hands, and comes back as client-controlled input, so it must be treated like
    # any other untrusted data. Sealing encrypts the state with AES-256-GCM (clients cannot read it) and binds
    # a claims envelope that unsealing verifies fail-closed:
    #
    # - `exp`: a TTL window (re-sealed each round)
    # - `m` / `t`: the originating method and target (tool/prompt name or resource URI)
    # - `a`: a digest of the originating arguments, so the state only resumes the same call with the same inputs
    # - `aud`: an optional audience, so tokens cannot cross servers sharing a key
    #
    # Pass an instance via `Server.new(request_state_security:)` and the seal/unseal happens transparently;
    # handlers keep reading plaintext through `server_context.request_state`. Without it, the state crosses
    # the wire exactly as the handler wrote it (the author's responsibility, matching the Python SDK's low-level Server).
    # The key must be shared across workers in multi-process
    #
    # deployments; a per-process random key makes retries that land on another worker fail with an invalid-state error,
    # forcing clients to restart the flow.
    #
    # The token format is `v1.<base64url(iv || ciphertext || tag)>`, with the version prefix bound as GCM associated data,
    # following the Python SDK's `AESGCMRequestStateCodec`.
    class RequestStateSecurity
      class InvalidStateError < StandardError; end

      VERSION_PREFIX = "v1."
      KEY_BYTES = 32
      IV_BYTES = 12
      TAG_BYTES = 16
      DEFAULT_TTL = 300

      def initialize(key:, ttl: DEFAULT_TTL, audience: nil)
        unless key.is_a?(String) && key.bytesize == KEY_BYTES
          raise ArgumentError, "key must be a #{KEY_BYTES}-byte String"
        end
        unless ttl.is_a?(Numeric) && ttl.positive?
          raise ArgumentError, "ttl must be a positive number of seconds"
        end

        @key = key.dup.force_encoding(Encoding::BINARY).freeze
        @ttl = ttl
        @audience = audience
      end

      # Seals a plaintext state into an opaque token bound to the originating request.
      def seal(state, method:, target:, arguments_digest:)
        claims = {
          v: 1,
          exp: Time.now.to_i + @ttl,
          m: method,
          t: target,
          a: arguments_digest,
          aud: @audience,
          s: state,
        }.compact

        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @key
        iv = cipher.random_iv
        cipher.auth_data = VERSION_PREFIX
        ciphertext = cipher.update(JSON.generate(claims)) + cipher.final

        VERSION_PREFIX + base64url_encode(iv + ciphertext + cipher.auth_tag)
      end

      # Unseals a client-echoed token and verifies every claim, failing closed with
      # `InvalidStateError` on tampering, expiry, or a claims mismatch.
      def unseal(sealed, method:, target:, arguments_digest:)
        unless sealed.is_a?(String) && sealed.start_with?(VERSION_PREFIX)
          raise InvalidStateError, "malformed token"
        end

        blob = base64url_decode(sealed.delete_prefix(VERSION_PREFIX))
        raise InvalidStateError, "malformed token" if blob.bytesize < IV_BYTES + TAG_BYTES

        iv = blob.byteslice(0, IV_BYTES)
        tag = blob.byteslice(-TAG_BYTES, TAG_BYTES)
        ciphertext = blob.byteslice(IV_BYTES, blob.bytesize - IV_BYTES - TAG_BYTES)

        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @key
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = VERSION_PREFIX
        plaintext = begin
          cipher.update(ciphertext) + cipher.final
        rescue OpenSSL::Cipher::CipherError
          raise InvalidStateError, "authentication failed"
        end

        claims = begin
          JSON.parse(plaintext, symbolize_names: true)
        rescue JSON::ParserError
          raise InvalidStateError, "malformed claims"
        end

        verify!(claims, method: method, target: target, arguments_digest: arguments_digest)
        claims[:s]
      end

      private

      def verify!(claims, method:, target:, arguments_digest:)
        raise InvalidStateError, "unsupported version" unless claims[:v] == 1
        raise InvalidStateError, "expired" unless claims[:exp].is_a?(Integer) && Time.now.to_i <= claims[:exp]
        raise InvalidStateError, "method mismatch" unless claims[:m] == method
        raise InvalidStateError, "target mismatch" unless claims[:t] == target
        raise InvalidStateError, "arguments mismatch" unless claims[:a] == arguments_digest
        raise InvalidStateError, "audience mismatch" unless claims[:aud] == @audience
        raise InvalidStateError, "missing state" unless claims[:s].is_a?(String)
      end

      def base64url_encode(data)
        [data].pack("m0").tr("+/", "-_").delete("=")
      end

      def base64url_decode(encoded)
        padded = encoded.tr("-_", "+/")
        padded += "=" * ((4 - padded.length % 4) % 4)
        padded.unpack1("m0")
      rescue ArgumentError
        raise InvalidStateError, "malformed token"
      end
    end
  end
end
