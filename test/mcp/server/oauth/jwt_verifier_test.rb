# frozen_string_literal: true

require "test_helper"
require "jwt"
require "openssl"
require "webmock/minitest"

module MCP
  class Server
    module OAuth
      class JWTVerifierTest < Minitest::Test
        ISSUER = "https://as.example.com"
        AUDIENCE = "https://mcp.example.com/mcp"
        JWKS_URI = "https://as.example.com/.well-known/jwks.json"
        METADATA = ProtectedResourceMetadata.new(resource: AUDIENCE, authorization_servers: [ISSUER])

        def setup
          @rsa_key = OpenSSL::PKey::RSA.new(2048)
          @jwk = JWT::JWK.new(@rsa_key, { use: "sig", alg: "RS256" })
          @jwks = { keys: [@jwk.export] }
        end

        def test_verifies_a_valid_token_and_maps_claims
          stub_jwks
          token = encode(claims)

          access_token = jwks_verifier.verify(token)

          assert_equal(token, access_token.token)
          assert_equal("client-1", access_token.client_id)
          assert_equal(["mcp:tools", "mcp:resources"], access_token.scopes)
          assert_equal(claims["exp"], access_token.expires_at)
          assert_equal("user-1", access_token.subject)
          assert_equal(ISSUER, access_token.issuer)
          assert_equal(AUDIENCE, access_token.audience)
          assert_equal(AUDIENCE, access_token.resource)
          assert_equal("user-1", access_token.claims["sub"])
        end

        def test_falls_back_to_azp_for_client_id
          stub_jwks
          token = encode(claims.tap { |c| c.delete("client_id") }.merge("azp" => "azp-client"))

          assert_equal("azp-client", jwks_verifier.verify(token).client_id)
        end

        def test_rejects_expired_token
          stub_jwks
          token = encode(claims.merge("exp" => Time.now.to_i - 60))

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          assert_equal("Token expired", error.message)
        end

        def test_rejects_token_not_yet_valid
          stub_jwks
          token = encode(claims.merge("nbf" => Time.now.to_i + 600))

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          assert_equal("Token not yet valid", error.message)
        end

        def test_leeway_tolerates_recent_expiry
          stub_jwks
          token = encode(claims.merge("exp" => Time.now.to_i - 5))

          verifier = jwks_verifier(leeway: 30)

          assert_equal("user-1", verifier.verify(token).subject)
        end

        def test_rejects_audience_mismatch
          stub_jwks
          token = encode(claims.merge("aud" => "https://other.example.com"))

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          assert_equal("Invalid audience", error.message)
        end

        def test_rejects_issuer_mismatch
          stub_jwks
          token = encode(claims.merge("iss" => "https://evil.example.com"))

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          assert_equal("Invalid issuer", error.message)
        end

        def test_rejects_alg_none
          stub_jwks
          token = JWT.encode(claims, nil, "none")

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          assert_equal("Invalid token", error.message)
        end

        def test_rejects_hs256_key_confusion
          stub_jwks
          forged = JWT.encode(claims, @rsa_key.public_key.to_pem, "HS256")

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(forged) }

          assert_equal("Invalid token", error.message)
        end

        def test_rejects_garbage_token
          stub_jwks

          assert_raises(InvalidTokenError) { jwks_verifier.verify("not.a.jwt") }
        end

        def test_rejects_token_without_exp
          stub_jwks
          token = encode(claims.tap { |c| c.delete("exp") })

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(token) }

          # A token the issuer forgot to expire would otherwise be valid forever.
          assert_equal("Invalid token", error.message)
        end

        def test_caches_jwks_across_verifications
          stub = stub_jwks
          verifier = jwks_verifier

          verifier.verify(encode(claims))
          verifier.verify(encode(claims))

          assert_requested(stub, times: 1)
        end

        def test_unknown_kid_triggers_one_refetch_with_cooldown
          rotated_key = OpenSSL::PKey::RSA.new(2048)
          rotated_jwk = JWT::JWK.new(rotated_key, { use: "sig", alg: "RS256" })
          stale_then_rotated = stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(keys: [@jwk.export]), headers: { "Content-Type" => "application/json" } },
            { body: JSON.generate(keys: [@jwk.export, rotated_jwk.export]), headers: { "Content-Type" => "application/json" } },
          )
          verifier = jwks_verifier

          verifier.verify(encode(claims))

          rotated_token = JWT.encode(claims, rotated_key, "RS256", { kid: rotated_jwk[:kid] })

          assert_equal("user-1", verifier.verify(rotated_token).subject)
          assert_requested(stale_then_rotated, times: 2)

          unknown_key = OpenSSL::PKey::RSA.new(2048)
          unknown_jwk = JWT::JWK.new(unknown_key, { use: "sig", alg: "RS256" })
          unknown_token = JWT.encode(claims, unknown_key, "RS256", { kid: unknown_jwk[:kid] })

          # Within the cooldown window an unknown kid must not trigger another fetch.
          assert_raises(InvalidTokenError) { verifier.verify(unknown_token) }
          assert_requested(stale_then_rotated, times: 2)
        end

        def test_jwks_endpoint_failure_is_not_an_invalid_token_error
          stub_request(:get, JWKS_URI).to_return(status: 500)

          error = assert_raises(JWTVerifier::JWKSFetchError) { jwks_verifier.verify(encode(claims)) }

          assert_equal("JWKS endpoint responded with status 500", error.message)
        end

        def test_stale_jwks_is_served_when_a_refresh_fails
          stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { status: 500 },
          )
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)

          # The TTL of zero forces a refresh, whose failure must fall back to the cached key set instead of failing the verification.
          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        end

        def test_rejects_oversized_jwks_response
          stub_request(:get, JWKS_URI).to_return(
            status: 200,
            body: "a" * (TokenVerifier::MAX_UPSTREAM_RESPONSE_BYTES + 1),
          )

          error = assert_raises(JWTVerifier::JWKSFetchError) { jwks_verifier.verify(encode(claims)) }

          assert_includes(error.message, "JWKS response exceeded")
        end

        def test_rejects_non_object_jwks_response
          stub_request(:get, JWKS_URI).to_return(status: 200, body: "[]")

          error = assert_raises(JWTVerifier::JWKSFetchError) { jwks_verifier.verify(encode(claims)) }

          assert_equal("JWKS endpoint returned a non-object JSON document", error.message)
        end

        def test_rejects_non_loopback_http_jwks_uri
          error = assert_raises(ArgumentError) do
            JWTVerifier.new(resource_metadata: METADATA, jwks_uri: "http://as.example.com/jwks.json")
          end

          assert_includes(error.message, "jwks_uri must use https")
        end

        def test_static_jwks_with_string_keys
          verifier = JWTVerifier.new(resource_metadata: METADATA, jwks: JSON.parse(JSON.generate(@jwks)))

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        end

        def test_static_key
          verifier = JWTVerifier.new(resource_metadata: METADATA, key: @rsa_key.public_key)
          token = JWT.encode(claims, @rsa_key, "RS256")

          assert_equal("user-1", verifier.verify(token).subject)
        end

        def test_hs256_requires_explicit_opt_in
          secret = "shared-secret"
          token = JWT.encode(claims, secret, "HS256")

          opted_in = JWTVerifier.new(resource_metadata: METADATA, key: secret, algorithms: ["HS256"])

          assert_equal("user-1", opted_in.verify(token).subject)
        end

        def test_requires_exactly_one_key_source
          assert_raises(ArgumentError) { JWTVerifier.new(resource_metadata: METADATA) }
          assert_raises(ArgumentError) do
            JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, key: "secret")
          end
        end

        def test_requires_the_resource_metadata_document
          # The jwt gem skips a check whose expected value is nil, so the expected `iss` and `aud` come from the published document,
          # never from a bare value that could be nil or empty.
          [nil, "", { resource: AUDIENCE }, 42].each do |metadata|
            error = assert_raises(ArgumentError, metadata.inspect) { JWTVerifier.new(resource_metadata: metadata, jwks_uri: JWKS_URI) }

            assert_includes(error.message, "resource_metadata must be a ProtectedResourceMetadata")
          end
        end

        def test_a_stand_in_document_must_hand_over_the_expected_member_shapes
          # A duck-typed document that answers the members with the wrong shapes fails by name, not with a `NoMethodError` deeper in.
          string_servers = Struct.new(:resource, :authorization_servers).new(AUDIENCE, ISSUER)
          error = assert_raises(ArgumentError) { JWTVerifier.new(resource_metadata: string_servers, jwks_uri: JWKS_URI) }

          assert_includes(error.message, "resource_metadata.authorization_servers must be an Array of Strings")

          symbol_resource = Struct.new(:resource, :authorization_servers).new(:mcp, [ISSUER])
          error = assert_raises(ArgumentError) { JWTVerifier.new(resource_metadata: symbol_resource, jwks_uri: JWKS_URI) }

          assert_includes(error.message, "resource_metadata.resource must be a String")
        end

        def test_takes_issuer_and_audience_from_the_resource_metadata
          stub_jwks
          verifier = JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI)

          access_token = verifier.verify(encode(claims))

          assert_equal(ISSUER, access_token.issuer)
          assert_equal(AUDIENCE, access_token.resource)
        end

        def test_a_document_naming_several_authorization_servers_is_refused
          # One key set verifies one issuer's tokens; a document advertising a second server would send clients for tokens
          # this verifier rejects.
          metadata = ProtectedResourceMetadata.new(resource: AUDIENCE, authorization_servers: [ISSUER, "https://as2.example.com"])

          error = assert_raises(ArgumentError) { JWTVerifier.new(resource_metadata: metadata, jwks_uri: JWKS_URI) }

          assert_includes(error.message, "one authorization server, and resource_metadata names 2")
        end

        def test_rejects_none_in_the_algorithm_allowlist
          ["none", "NONE"].each do |none|
            error = assert_raises(ArgumentError) do
              JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, algorithms: ["RS256", none])
            end

            assert_includes(error.message, "must not include none")
          end
        end

        def test_rejects_an_empty_algorithm_allowlist
          assert_raises(ArgumentError) { JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, algorithms: []) }
        end

        def test_rejects_mixing_hmac_with_asymmetric_algorithms
          # With both families allowed, an HS256 token signed with the public key bytes would verify against that key.
          error = assert_raises(ArgumentError) do
            JWTVerifier.new(resource_metadata: METADATA, key: @rsa_key.public_key, algorithms: ["RS256", "HS256"])
          end

          assert_includes(error.message, "must not mix HMAC")
        end

        def test_rejects_a_string_key_for_asymmetric_algorithms
          error = assert_raises(ArgumentError) do
            JWTVerifier.new(resource_metadata: METADATA, key: @rsa_key.public_key.to_pem)
          end

          assert_includes(error.message, "key must be an OpenSSL::PKey")
        end

        def test_rejects_a_jwk_object_as_the_key
          # The decode path cannot use a JWK handed in as `key:`, so accepting it would fail every verification instead of the setup.
          error = assert_raises(ArgumentError) do
            JWTVerifier.new(resource_metadata: METADATA, key: @jwk)
          end

          assert_includes(error.message, "pass a JWK through jwks:")
        end

        def test_accepts_an_array_aud_claim_that_names_the_audience
          stub_jwks

          assert_equal("user-1", jwks_verifier.verify(encode(claims.merge("aud" => ["https://other.example.com", AUDIENCE]))).subject)

          error = assert_raises(InvalidTokenError) { jwks_verifier.verify(encode(claims.merge("aud" => ["https://other.example.com"]))) }

          assert_equal("Invalid audience", error.message)
        end

        def test_failed_unknown_kid_refetch_starts_the_cooldown
          stub = stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { status: 500 },
          )
          verifier = jwks_verifier
          verifier.verify(encode(claims))

          unknown_key = OpenSSL::PKey::RSA.new(2048)
          unknown_jwk = JWT::JWK.new(unknown_key, { use: "sig", alg: "RS256" })
          unknown_token = JWT.encode(claims, unknown_key, "RS256", { kid: unknown_jwk[:kid] })

          assert_raises(InvalidTokenError) { verifier.verify(unknown_token) }
          assert_requested(stub, times: 2)

          # The refetch failed, but the endpoint must not be asked again for the next unknown kid within the cooldown.
          assert_raises(InvalidTokenError) { verifier.verify(unknown_token) }
          assert_requested(stub, times: 2)
        end

        def test_connection_failure_on_refresh_is_bridged_with_the_cached_jwks
          stub_request(:get, JWKS_URI).to_return(body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" }).then.to_raise(Errno::ECONNREFUSED)
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        end

        def test_a_concurrent_refresh_does_not_serve_keys_beyond_the_stale_bound
          stub_jwks
          verifier = jwks_verifier(jwks_cache_ttl: 0, jwks_max_stale: 0)
          verifier.verify(encode(claims))

          # Another thread holds the fetch lock, as one does in the middle of a refresh; the cached keys are past the bound,
          # so this request must wait for that refresh and then judge the outcome instead of falling back to them.
          fetch_mutex = verifier.instance_variable_get(:@fetch_mutex)
          holder = Thread.new { fetch_mutex.synchronize { sleep(0.2) } }
          sleep(0.02)

          assert_raises(JWTVerifier::JWKSFetchError) { verifier.verify(encode(claims)) }
        ensure
          holder&.join
        end

        def test_a_concurrent_refresh_serves_the_cached_keys_within_the_stale_bound
          stub_jwks
          verifier = jwks_verifier(jwks_cache_ttl: 0)
          verifier.verify(encode(claims))

          fetch_mutex = verifier.instance_variable_get(:@fetch_mutex)
          holder = Thread.new { fetch_mutex.synchronize { sleep(0.2) } }
          sleep(0.02)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        ensure
          holder&.join
        end

        def test_a_failed_refresh_is_not_retried_on_every_request
          stub = stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { status: 500 },
          )
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          3.times { assert_equal("user-1", verifier.verify(encode(claims)).subject) }

          # The first refresh fails and starts the cooldown; the cached keys serve until it lapses without another attempt.
          assert_requested(stub, times: 2)
        end

        def test_a_jwks_document_without_a_keys_array_does_not_replace_the_cache
          stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { body: JSON.generate(keys: "bad"), headers: { "Content-Type" => "application/json" } },
          )
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        end

        def test_a_bad_http_response_on_refresh_is_bridged_with_the_cached_jwks
          stub_request(:get, JWKS_URI).to_return(body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" }).then.to_raise(Net::HTTPBadResponse)
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
          assert_equal("user-1", verifier.verify(encode(claims)).subject)
        end

        def test_rejects_time_claims_of_the_wrong_type_as_invalid_tokens
          stub_jwks
          # The jwt gem refuses to encode these, so the tokens are assembled by hand and signed with the test key.
          [{ "exp" => true }, { "exp" => [] }, { "exp" => {} }, { "exp" => Time.now.to_i + 3600, "nbf" => true }].each do |overrides|
            error = assert_raises(InvalidTokenError, overrides.inspect) { jwks_verifier.verify(hand_signed(claims.merge(overrides))) }

            assert_match(/\AMalformed (exp|nbf) claim\z/, error.message)
          end
        end

        def test_rejects_non_finite_or_negative_numeric_options
          # `jwks_max_stale: nil` used to pass construction and then fail every cached verification on the `ttl + nil` arithmetic.
          [{ leeway: -1 }, { leeway: Float::INFINITY }, { jwks_cache_ttl: Float::NAN }, { jwks_max_stale: -1 }, { jwks_max_stale: nil }, { open_timeout: 0 }, { read_timeout: "5" }].each do |option|
            assert_raises(ArgumentError, option.inspect) { JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, **option) }
          end
        end

        def test_a_key_set_the_jwt_gem_cannot_load_does_not_replace_the_cache
          # The gem rejects a set with an unloadable member as a whole, and that rejection never triggers a refetch,
          # so such a document would otherwise fail every token until the TTL lapsed.
          stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { body: %({"keys":[{}]}), headers: { "Content-Type" => "application/json" } },
          )
          verifier = jwks_verifier(jwks_cache_ttl: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)
          assert_equal("user-1", verifier.verify(encode(claims)).subject)
          assert_equal(@jwks, verifier.instance_variable_get(:@cached_jwks))
        end

        def test_an_unloadable_key_set_on_a_cold_start_is_an_infrastructure_error
          [%({"keys":[{}]}), %({"keys":[{"kty":"FOO"}]}), %({"keys":["nope"]})].each do |body|
            stub_request(:get, JWKS_URI).to_return(body: body, headers: { "Content-Type" => "application/json" })

            assert_raises(JWTVerifier::JWKSFetchError, body) { jwks_verifier.verify(encode(claims)) }
          end
        end

        def test_a_retired_key_set_snapshot_is_not_served_after_another_thread_refreshed
          stub_jwks
          verifier = jwks_verifier(jwks_cache_ttl: 0, jwks_max_stale: 0)
          token = encode(claims)

          assert_equal("user-1", verifier.verify(token).subject)

          # Another thread rotates the cache to a set without this token's key at the very moment this thread finds
          # the fetch lock taken; the snapshot this thread holds is past the bound and must be judged by its own fetch time,
          # not by the refresh's.
          rotated = { keys: [JWT::JWK.new(OpenSSL::PKey::RSA.new(2048), { use: "sig", alg: "RS256" }).export] }
          verifier.instance_variable_set(:@jwks_fetched_at, verifier.send(:monotonic_now) - 10)
          taken_lock = Object.new
          taken_lock.define_singleton_method(:try_lock) do
            verifier.instance_variable_set(:@cached_jwks, rotated)
            verifier.instance_variable_set(:@jwks_fetched_at, verifier.send(:monotonic_now))
            false
          end
          taken_lock.define_singleton_method(:synchronize) { |&block| block.call }
          verifier.instance_variable_set(:@fetch_mutex, taken_lock)

          assert_raises(InvalidTokenError) { verifier.verify(token) }
        end

        def test_stale_jwks_is_not_served_beyond_the_stale_bound
          stub_request(:get, JWKS_URI).to_return(
            { body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" } },
            { status: 500 },
          )
          verifier = jwks_verifier(jwks_cache_ttl: 0, jwks_max_stale: 0)

          assert_equal("user-1", verifier.verify(encode(claims)).subject)

          # With no stale allowance, the TTL lapse plus a failed refresh surfaces as the infrastructure error it is.
          error = assert_raises(JWTVerifier::JWKSFetchError) { verifier.verify(encode(claims)) }

          assert_equal("JWKS endpoint responded with status 500", error.message)
        end

        private

        def claims
          @claims ||= {
            "iss" => ISSUER,
            "aud" => AUDIENCE,
            "exp" => Time.now.to_i + 3600,
            "sub" => "user-1",
            "client_id" => "client-1",
            "scope" => "mcp:tools mcp:resources",
          }
          @claims.dup
        end

        def encode(payload)
          JWT.encode(payload, @rsa_key, "RS256", { kid: @jwk[:kid] })
        end

        # `JWT.encode` validates claim types, so a token with a badly typed claim has to be assembled by hand.
        def hand_signed(payload)
          header = urlsafe(JSON.generate(alg: "RS256", kid: @jwk[:kid]))
          body = urlsafe(JSON.generate(payload))
          signing_input = "#{header}.#{body}"

          "#{signing_input}.#{urlsafe(@rsa_key.sign(OpenSSL::Digest.new("SHA256"), signing_input))}"
        end

        def urlsafe(bytes)
          [bytes].pack("m0").tr("+/", "-_").delete("=")
        end

        def jwks_verifier(leeway: 0, jwks_cache_ttl: 300, jwks_max_stale: 3600)
          JWTVerifier.new(resource_metadata: METADATA, jwks_uri: JWKS_URI, leeway: leeway, jwks_cache_ttl: jwks_cache_ttl, jwks_max_stale: jwks_max_stale)
        end

        def stub_jwks
          stub_request(:get, JWKS_URI).to_return(body: JSON.generate(@jwks), headers: { "Content-Type" => "application/json" })
        end
      end
    end
  end
end
