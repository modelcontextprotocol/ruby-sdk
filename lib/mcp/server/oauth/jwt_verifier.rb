# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "mcp/client/oauth/discovery"
require_relative "token_verifier"

# This file is autoloaded only when `JWTVerifier` is referenced, so the `jwt` dependency does not affect users of other verifiers.
begin
  require "jwt"
rescue LoadError
  raise LoadError, "The 'jwt' gem is required to use MCP::Server::OAuth::JWTVerifier. Add it to your Gemfile: gem 'jwt'"
end

module MCP
  class Server
    module OAuth
      # Verifies JWT access tokens locally: signature (via a JWKS endpoint, a static JWKS document, or a single key), `iss`, `aud`, `exp`, and `nbf`.
      #
      #
      #   verifier = MCP::Server::OAuth::JWTVerifier.new(
      #     resource_metadata: metadata, # the ProtectedResourceMetadata this server publishes
      #     jwks_uri: "https://as.example.com/.well-known/jwks.json",
      #   )
      #
      # `aud` is checked against the document's `resource`, the canonical resource URL spec-conformant authorization servers
      # put into `aud` via the RFC 8707 `resource` parameter, and `iss` against the document's authorization server, of which
      # there must be exactly one: this verifier holds one key set, so it verifies the tokens of one issuer.
      #
      # `alg: none` is refused whatever `algorithms:` says, and HMAC and asymmetric algorithms cannot share one allowlist, which defeats HS256 key-confusion attacks:
      # a token symmetrically signed with the public key bytes never meets an HMAC verifier holding that key. The default allowlist contains only asymmetric algorithms.
      # Pass `algorithms: ["HS256"]` together with `key: shared_secret` only when the authorization server genuinely issues HMAC-signed tokens, and understand
      # that anyone holding the secret can mint tokens.
      class JWTVerifier < TokenVerifier
        # Raised when the JWKS endpoint cannot be fetched or parsed. Deliberately
        # not an `OAuth::Error`: an unreachable key set is an internal failure
        # (HTTP 500), not a problem with the client's token.
        class JWKSFetchError < StandardError; end

        DEFAULT_ALGORITHMS = ["RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512", "EdDSA"].freeze

        HMAC_ALGORITHM_PATTERN = /\AHS\d+\z/i.freeze
        private_constant :HMAC_ALGORITHM_PATTERN

        # Minimum seconds between JWKS refetches triggered by an unknown `kid`, so a stream of forged tokens cannot hammer the JWKS endpoint.
        JWKS_REFETCH_COOLDOWN = 30

        # The RFC 7519 NumericDate claims the jwt gem compares with the clock under the `verify_expiration` and
        # `verify_not_before` options passed in `decode`; `iat` joins the list only if its verification is ever enabled.
        NUMERIC_DATE_CLAIMS = ["exp", "nbf"].freeze
        private_constant :NUMERIC_DATE_CLAIMS

        def initialize(resource_metadata:, jwks_uri: nil, jwks: nil, key: nil, algorithms: DEFAULT_ALGORITHMS, leeway: 0, jwks_cache_ttl: 300, jwks_max_stale: 3600, open_timeout: 5, read_timeout: 5)
          super()

          issuer = issuer_from(resource_metadata)
          audience = resource_from(resource_metadata)
          require_expected_claim!(:issuer, issuer)
          require_expected_claim!(:audience, audience)
          require_non_negative_number!(:leeway, leeway)
          require_non_negative_number!(:jwks_cache_ttl, jwks_cache_ttl)
          require_non_negative_number!(:jwks_max_stale, jwks_max_stale)
          require_positive_number!(:open_timeout, open_timeout)
          require_positive_number!(:read_timeout, read_timeout)

          key_sources = [jwks_uri, jwks, key].compact
          raise ArgumentError, "exactly one of jwks_uri, jwks, or key is required" unless key_sources.size == 1

          if jwks_uri && !Client::OAuth::Discovery.secure_url?(jwks_uri)
            raise ArgumentError, "jwks_uri must use https (http is allowed only on loopback): #{jwks_uri.inspect}"
          end

          @issuer = issuer
          @audience = audience
          @jwks_uri = jwks_uri
          @static_jwks = jwks && deep_symbolize(jwks)
          @key = key
          @algorithms = validate_algorithms!(algorithms, key)
          @leeway = leeway
          @jwks_cache_ttl = jwks_cache_ttl
          @jwks_max_stale = jwks_max_stale
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @cached_jwks = nil
          @jwks_fetched_at = nil
          @kid_refetch_at = nil
          @refetch_failed_at = nil
          @state_mutex = Mutex.new
          @fetch_mutex = Mutex.new
        end

        def verify(token)
          validate_time_claims!(token)
          claims, _header = decode(token)

          access_token_from_claims(token, claims, resource: @audience)
        rescue JWT::ExpiredSignature
          raise InvalidTokenError, "Token expired"
        rescue JWT::ImmatureSignature
          raise InvalidTokenError, "Token not yet valid"
        rescue JWT::InvalidIssuerError
          raise InvalidTokenError, "Invalid issuer"
        rescue JWT::InvalidAudError
          raise InvalidTokenError, "Invalid audience"
        rescue JWT::DecodeError
          # Covers malformed tokens, signature mismatches, disallowed algorithms (including `alg: none`), missing required claims,
          # and unknown key IDs. The generic message is deliberate: it goes into the `WWW-Authenticate` header, and detailing why
          # verification failed would only help an attacker probe.
          raise InvalidTokenError, "Invalid token"
        end

        private

        def decode(token)
          options = {
            algorithms: @algorithms,
            iss: @issuer,
            verify_iss: true,
            aud: @audience,
            verify_aud: true,
            verify_expiration: true,
            verify_not_before: true,
            # `verify_expiration` alone lets a token without `exp` through, and a token that never expires cannot be aged out.
            # Spec-conformant access tokens always carry `exp` (RFC 9068 requires it).
            required_claims: ["exp"],
            leeway: @leeway,
          }

          if @key
            JWT.decode(token, @key, true, options)
          elsif @static_jwks
            JWT.decode(token, nil, true, options.merge(jwks: @static_jwks))
          else
            JWT.decode(token, nil, true, options.merge(jwks: jwk_loader))
          end
        end

        # The jwt gem calls `to_i` on `exp` and `nbf` while verifying, so a claim of the wrong type raises inside the gem
        # instead of failing the token. The unverified payload is inspected first: a claim that is neither a finite number
        # nor a digit string makes the token invalid, the same answer `expiry_from_claims` gives an introspection response.
        def validate_time_claims!(token)
          payload, = JWT.decode(token, nil, false)
          raise InvalidTokenError, "Invalid token" unless payload.is_a?(Hash)

          NUMERIC_DATE_CLAIMS.each do |name|
            value = payload[name]
            next if value.nil? || (value.is_a?(Numeric) && value.finite?) || (value.is_a?(String) && value.match?(/\A\d+\z/))

            raise InvalidTokenError, "Malformed #{name} claim"
          end
        end

        # `none` is never acceptable, and HMAC must not share an allowlist with asymmetric algorithms: an attacker who picks `alg`
        # would otherwise sign with the public key bytes as the HMAC secret. A String key can only be an HMAC secret,
        # so it is refused for asymmetric algorithms at construction rather than failing every verification later, and a `JWT::JWK`
        # is refused outright because the decode path would reject every token signed by it.
        def validate_algorithms!(algorithms, key)
          if key.is_a?(JWT::JWK::KeyBase)
            raise ArgumentError, "key must be an OpenSSL::PKey or an HMAC secret String; pass a JWK through jwks: { keys: [jwk.export] }"
          end

          list = Array(algorithms).map(&:to_s)
          raise ArgumentError, "algorithms must name at least one signature algorithm" if list.empty?

          if list.any? { |algorithm| algorithm.casecmp?("none") }
            raise ArgumentError, "algorithms must not include none: unsigned tokens would be accepted"
          end

          hmac, asymmetric = list.partition { |algorithm| algorithm.match?(HMAC_ALGORITHM_PATTERN) }

          if hmac.any? && asymmetric.any?
            raise ArgumentError, "algorithms must not mix HMAC (#{hmac.join(", ")}) with asymmetric algorithms (#{asymmetric.join(", ")})"
          end
          if key.is_a?(String) && hmac.empty?
            raise ArgumentError, "key must be an OpenSSL::PKey for asymmetric algorithms; a String key is an HMAC secret and needs an HS* allowlist"
          end

          list
        end

        # Loader for the `jwt` gem's `jwks:` option. The gem invokes it once per decode and again with `kid_not_found: true` when
        # the token's `kid` is not in the returned set, which is the signal that the authorization server may have rotated its keys.
        def jwk_loader
          lambda do |options|
            load_jwks(options)
          end
        end

        # Refreshes the JWKS cache without performing network I/O under a lock other verifications wait on: only cache-state reads
        # and swaps are synchronized, one thread fetches at a time, and the remaining threads keep verifying against the previous key
        # set in the meantime. A failed refresh also falls back to that set, so a flaky JWKS endpoint degrades to slightly stale keys
        # instead of taking verification down, but only for `jwks_max_stale` seconds past the TTL: beyond that the failure surfaces,
        # so a key set the authorization server retired cannot stay trusted indefinitely. A failed unknown-`kid` refetch starts
        # the cooldown all the same, or the endpoint would be retried on every such token while it is down.
        def load_jwks(options)
          # The key set and its fetch time are read as one snapshot and judged together: a refresh another thread completes
          # in the meantime must not lend its fetch time to the set this thread is holding.
          cached, fetched_at, refetch = @state_mutex.synchronize { [@cached_jwks, @jwks_fetched_at, refetch_required?(options)] }
          unless refetch
            # A refresh that failed moments ago is not retried yet, and keys past the stale bound are not served meanwhile.
            raise JWKSFetchError, "JWKS endpoint could not be fetched" if cached && stale_beyond_bound?(fetched_at)

            return cached
          end

          if @fetch_mutex.try_lock
            begin
              fresh = fetch_jwks
              @state_mutex.synchronize do
                @cached_jwks = fresh
                @jwks_fetched_at = monotonic_now
                @refetch_failed_at = nil
                @kid_refetch_at = monotonic_now if options[:kid_not_found]
              end

              fresh
            rescue JWKSFetchError
              @state_mutex.synchronize do
                @refetch_failed_at = monotonic_now
                @kid_refetch_at = monotonic_now if options[:kid_not_found]
              end
              raise if cached.nil? || stale_beyond_bound?(fetched_at)

              cached
            ensure
              @fetch_mutex.unlock
            end
          elsif cached && !stale_beyond_bound?(fetched_at)
            cached
          else
            # Cold start, or a cached set past its stale bound, while another thread performs the fetch: wait for that fetch
            # instead of failing the request with an empty or outdated key set. A fetch time that moved means the refresh succeeded,
            # and its set is served the way the fetching thread serves it; an unchanged one means the refresh failed,
            # and the set it left behind is judged by the bound.
            @fetch_mutex.synchronize {}
            fetched, refreshed_at = @state_mutex.synchronize { [@cached_jwks, @jwks_fetched_at] }
            if fetched.nil? || (refreshed_at == fetched_at && stale_beyond_bound?(refreshed_at))
              raise JWKSFetchError, "JWKS endpoint could not be fetched"
            end

            fetched
          end
        end

        # An unknown `kid` refetches immediately (the usual key-rotation case) but at most once per cooldown window, so forged tokens with
        # random `kid`s cannot turn every request into a JWKS fetch. Outside of a `kid` miss, the cache is refreshed only when the TTL lapses.
        def refetch_required?(options)
          return true if @cached_jwks.nil?

          if options[:kid_not_found]
            return @kid_refetch_at.nil? || monotonic_now - @kid_refetch_at >= JWKS_REFETCH_COOLDOWN
          end
          # A refresh that just failed is not retried on every request while the endpoint stays down.
          return false if @refetch_failed_at && monotonic_now - @refetch_failed_at < JWKS_REFETCH_COOLDOWN

          monotonic_now - @jwks_fetched_at >= @jwks_cache_ttl
        end

        # Whether a key set fetched at `fetched_at` has outlived its TTL by more than `jwks_max_stale`, the point past which
        # a refresh failure is no longer bridged with the stale keys.
        def stale_beyond_bound?(fetched_at)
          monotonic_now - fetched_at > @jwks_cache_ttl + @jwks_max_stale
        end

        def fetch_jwks
          uri = URI.parse(@jwks_uri)
          request = Net::HTTP::Get.new(uri.request_uri, { "Accept" => "application/json" })
          body = "".dup

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
            http.request(request) do |response|
              unless response.is_a?(Net::HTTPOK)
                raise JWKSFetchError, "JWKS endpoint responded with status #{response.code}"
              end

              response.read_body do |chunk|
                body << chunk
                if body.bytesize > MAX_UPSTREAM_RESPONSE_BYTES
                  raise JWKSFetchError, "JWKS response exceeded #{MAX_UPSTREAM_RESPONSE_BYTES} bytes"
                end
              end
            end
          end

          parsed = JSON.parse(body, symbolize_names: true)
          raise JWKSFetchError, "JWKS endpoint returned a non-object JSON document" unless parsed.is_a?(Hash)
          # A document without a `keys` array would replace a good cache with one that verifies nothing.
          raise JWKSFetchError, "JWKS endpoint returned a document without a keys array" unless parsed[:keys].is_a?(Array)
          # So would a set with a member the jwt gem cannot turn into a key: the gem rejects the whole set, and unlike an unknown `kid`
          # that rejection never triggers a refetch, so the document counts as a failed refresh instead of replacing the cache.
          unless parsed[:keys].all? { |key| key.is_a?(Hash) }
            raise JWKSFetchError, "JWKS endpoint returned a key that is not a JSON object"
          end

          begin
            JWT::JWK::Set.new(parsed)
          rescue JWT::JWKError => e
            raise JWKSFetchError, "JWKS endpoint returned a key set that cannot be loaded: #{e.message}"
          end

          parsed
        rescue JSON::ParserError
          raise JWKSFetchError, "JWKS endpoint returned invalid JSON"
        rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse, Net::ProtocolError => e
          # A connection-level failure is the same event as an HTTP error from the caller's point of view: the key set could not be refreshed,
          # and `load_jwks` decides whether the cached one still bridges the gap.
          raise JWKSFetchError, "JWKS endpoint could not be fetched: #{e.class}"
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # The `jwt` gem's JWKS handling expects symbol keys; user-supplied static documents commonly arrive as parsed JSON with string keys.
        def deep_symbolize(jwks)
          JSON.parse(JSON.generate(jwks), symbolize_names: true)
        end
      end
    end
  end
end
